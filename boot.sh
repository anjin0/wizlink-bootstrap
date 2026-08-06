#!/usr/bin/env bash
# WizLink Bootstrap — 운영 서버 배포 진입 스크립트 (Rocky Linux / RHEL 계열)
#
# 필요:
#   - openssl
#   - curl 또는 wget
#   - python3 (Release JSON·manifest·archive 검증)
#   - sha256sum, tar
#   - Docker Engine과 Docker Compose plugin
#
# 사용:
#   ./boot.sh                         # 최초 설치(latest)
#   ./boot.sh install [v1.2.3]
#   ./boot.sh upgrade v1.2.3
#   ./boot.sh rollback v1.1.0
#   (실행 후 사이트 식별자 → 제품키를 순서대로 입력)
#
# 주요 환경변수(선택, 배포 동작용 — 식별자/제품키는 대화형 입력만):
#   BOOTSTRAP_REF=main
#   GHCR_USER=anjin0
#   DEPLOY_OWNER=anjin0  DEPLOY_REPO=wizlink-deploy
#   RELEASE_TAG=latest          # install에서만 사용; CLI tag가 우선
#   INSTALL_DIR=/opt/wizlink/releases
#   WIZLINK_HOME=/opt/wizlink
#   SKIP_DOCKER=0               # 1 이면 GHCR login 생략(검증 전용)
#   SKIP_RELEASE=0              # 1 이면 Release 다운로드·설치 생략(검증 전용)
#   VERBOSE=0                   # 1 이면 Bootstrap 상세 과정 표시

set -euo pipefail

BOOTSTRAP_OWNER="${BOOTSTRAP_OWNER:-anjin0}"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-wizlink-bootstrap}"
BOOTSTRAP_REF="${BOOTSTRAP_REF:-main}"
BOOTSTRAP_BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/${BOOTSTRAP_OWNER}/${BOOTSTRAP_REPO}/${BOOTSTRAP_REF}}"

DEPLOY_OWNER="${DEPLOY_OWNER:-anjin0}"
DEPLOY_REPO="${DEPLOY_REPO:-wizlink-deploy}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

GHCR_USER="${GHCR_USER:-anjin0}"

INSTALL_DIR="${INSTALL_DIR:-/opt/wizlink/releases}"
WIZLINK_HOME="${WIZLINK_HOME:-/opt/wizlink}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"
SKIP_RELEASE="${SKIP_RELEASE:-0}"
VERBOSE="${VERBOSE:-0}"
ACTION="install"
REQUESTED_TAG=""
CURRENT_VERSION=""
RELEASE_STAGE_DIR=""

die() {
  printf '\n[실패] %s\n' "$*" >&2
  exit 1
}

detail() {
  if [[ "${VERBOSE}" == "1" ]]; then
    printf '      %s\n' "$*"
  fi
}

step_done() {
  local current="$1"
  local total="$2"
  local label="$3"
  local result="${4:-완료}"
  printf '[%s/%s] %s ........ %s\n' \
    "${current}" "${total}" "${label}" "${result}"
}

usage() {
  cat <<'EOF'
사용법:
  boot.sh
  boot.sh install [vX.Y.Z]
  boot.sh upgrade vX.Y.Z
  boot.sh rollback vX.Y.Z

명령:
  install   WizLink를 처음 설치합니다. tag를 생략하면 안정 Release latest를 사용합니다.
  upgrade   설치된 WizLink를 지정한 상위 또는 동일 버전으로 갱신합니다.
  rollback  DB 호환성이 확인되는 지정한 하위 또는 동일 버전으로 되돌립니다.
EOF
}

semver_valid_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

semver_compare() {
  python3 - "$1" "$2" <<'PY'
import re
import sys


def parse(value):
    match = re.fullmatch(
        r"([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?",
        value,
    )
    if not match:
        raise SystemExit(f"잘못된 SemVer: {value}")
    core = tuple(int(part) for part in match.group(1, 2, 3))
    prerelease = match.group(4)
    return core, None if prerelease is None else prerelease.split(".")


def compare_identifiers(left, right):
    for left_part, right_part in zip(left, right):
        if left_part == right_part:
            continue
        left_numeric = left_part.isdigit()
        right_numeric = right_part.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_part) < int(right_part) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_part < right_part else 1
    return (len(left) > len(right)) - (len(left) < len(right))


left_core, left_pre = parse(sys.argv[1])
right_core, right_pre = parse(sys.argv[2])
if left_core != right_core:
    print(-1 if left_core < right_core else 1)
elif left_pre is None and right_pre is None:
    print(0)
elif left_pre is None:
    print(1)
elif right_pre is None:
    print(-1)
else:
    print(compare_identifiers(left_pre, right_pre))
PY
}

activate_release_dir() {
  local staged_dir="$1"
  local release_dir="$2"

  if [[ ! -e "${release_dir}" ]]; then
    mv -- "${staged_dir}" "${release_dir}"
    return
  fi

  [[ -d "${release_dir}" && ! -L "${release_dir}" ]] ||
    die "기존 Release 경로가 디렉터리가 아닙니다: ${release_dir}"
  python3 - "${staged_dir}" "${release_dir}" <<'PY'
import ctypes
import os
import sys

AT_FDCWD = -100
RENAME_EXCHANGE = 2
staged_dir = os.fsencode(sys.argv[1])
release_dir = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
]
renameat2.restype = ctypes.c_int
if renameat2(AT_FDCWD, staged_dir, AT_FDCWD, release_dir, RENAME_EXCHANGE) != 0:
    error_number = ctypes.get_errno()
    raise OSError(
        error_number,
        f"Release 디렉터리 원자 교체 실패: {os.strerror(error_number)}",
    )
PY
}

parse_cli() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  if [[ "$#" -gt 0 ]]; then
    ACTION="$1"
    shift
  fi

  case "${ACTION}" in
    install)
      [[ "$#" -le 1 ]] || { usage >&2; exit 2; }
      if [[ "$#" -eq 1 ]]; then
        REQUESTED_TAG="$1"
        RELEASE_TAG="${REQUESTED_TAG}"
      fi
      ;;
    upgrade | rollback)
      [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
      REQUESTED_TAG="$1"
      RELEASE_TAG="${REQUESTED_TAG}"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  if [[ -n "${REQUESTED_TAG}" ]] && ! semver_valid_tag "${REQUESTED_TAG}"; then
    die "명시한 Release tag는 vX.Y.Z 형식이어야 합니다: ${REQUESTED_TAG}"
  fi
  if [[ -z "${REQUESTED_TAG}" && "${RELEASE_TAG}" != "latest" ]] &&
    ! semver_valid_tag "${RELEASE_TAG}"; then
    die "Release tag는 vX.Y.Z 형식이어야 합니다: ${RELEASE_TAG}"
  fi
  if [[ "${ACTION}" != "install" && "${RELEASE_TAG}" == "latest" ]]; then
    die "${ACTION}에는 명시적 Release tag가 필요합니다."
  fi
}

read_env_value() {
  local key="$1"
  local env_file="$2"
  sed -nE "s/^${key}=(.*)$/\1/p" "${env_file}" | tail -n 1
}

check_runtime_state() {
  local env_file="${WIZLINK_HOME}/.env"
  local runtime_environment comparison target_version

  if [[ ! -f "${env_file}" ]]; then
    [[ "${ACTION}" == "install" ]] ||
      die "${ACTION}할 WizLink 운영 설치를 찾지 못했습니다: ${env_file}"
    return
  fi

  runtime_environment="$(read_env_value WIZLINK_ENV "${env_file}")"
  [[ "${runtime_environment}" == "production" ]] ||
    die "운영 설치만 ${ACTION}할 수 있습니다: WIZLINK_ENV=${runtime_environment:-없음}"
  CURRENT_VERSION="$(read_env_value WIZLINK_VERSION "${env_file}")"

  if [[ "${ACTION}" == "install" ]]; then
    if [[ -z "${CURRENT_VERSION}" ]]; then
      detail "부분 설치 복구: .env에 WIZLINK_VERSION이 없어 install 재실행을 허용합니다."
      return
    fi
    [[ "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
      die "현재 WIZLINK_VERSION이 올바르지 않습니다: ${CURRENT_VERSION}"
    if [[ "${RELEASE_TAG}" != "latest" && "${RELEASE_TAG#v}" != "${CURRENT_VERSION}" ]]; then
      die "install로 버전을 변경할 수 없습니다: ${CURRENT_VERSION} -> ${RELEASE_TAG#v}. upgrade를 사용하세요."
    fi
    return
  fi

  [[ "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
    die "현재 WIZLINK_VERSION이 올바르지 않습니다: ${CURRENT_VERSION:-없음}"
  target_version="${RELEASE_TAG#v}"
  comparison="$(semver_compare "${target_version}" "${CURRENT_VERSION}")"
  if [[ "${ACTION}" == "upgrade" && "${comparison}" -lt 0 ]]; then
    die "낮은 버전으로 upgrade할 수 없습니다: ${CURRENT_VERSION} -> ${target_version}"
  fi
  if [[ "${ACTION}" == "rollback" && "${comparison}" -gt 0 ]]; then
    die "높은 버전으로 rollback할 수 없습니다: ${CURRENT_VERSION} -> ${target_version}"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' 이(가) 필요합니다."
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# --- HTTP download (curl preferred, wget fallback) ---
download() {
  local url="$1"
  local out="$2"
  shift 2
  local -a extra=("$@")

  if have_cmd curl; then
    curl -fsSL --connect-timeout 30 --max-time 300 \
      "${extra[@]}" -o "$out" "$url" \
      || die "다운로드 실패: $url"
  elif have_cmd wget; then
    # wget: extra headers as --header=...
    local -a wh=()
    local i=0
    while [[ $i -lt ${#extra[@]} ]]; do
      if [[ "${extra[$i]}" == "-H" ]]; then
        wh+=(--header="${extra[$((i + 1))]}")
        i=$((i + 2))
      else
        i=$((i + 1))
      fi
    done
    wget -q "${wh[@]}" -O "$out" "$url" || die "다운로드 실패: $url"
  else
    die "curl 또는 wget 이 필요합니다."
  fi
}

# Authenticated GET to stdout (for API JSON)
http_get() {
  local url="$1"
  shift
  local -a extra=("$@")
  if have_cmd curl; then
    curl -fsSL --connect-timeout 30 --max-time 120 "${extra[@]}" "$url"
  elif have_cmd wget; then
    local -a wh=()
    local i=0
    while [[ $i -lt ${#extra[@]} ]]; do
      if [[ "${extra[$i]}" == "-H" ]]; then
        wh+=(--header="${extra[$((i + 1))]}")
        i=$((i + 2))
      else
        i=$((i + 1))
      fi
    done
    wget -q "${wh[@]}" -O - "$url"
  else
    die "curl 또는 wget 이 필요합니다."
  fi
}

decrypt_token() {
  local enc_file="$1"
  local product_key="$2"
  printf '%s\n' "${product_key}" |
    openssl enc -d -aes-256-cbc -pbkdf2 -a \
      -pass stdin \
      -in "${enc_file}" 2>/dev/null \
    || die "복호화 실패: ${enc_file} (제품키·파일 확인)"
}

parse_cli "$@"

# --- 1) 대화형 입력 (인자/환경변수로 식별자·제품키를 받지 않음) ---
case "${ACTION}" in
  install) ACTION_LABEL="설치" ;;
  upgrade) ACTION_LABEL="업그레이드" ;;
  rollback) ACTION_LABEL="롤백" ;;
esac

echo "WizLink ${ACTION_LABEL}를 시작합니다."
echo

[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다. sudo로 실행하세요."
for command_name in openssl python3 sha256sum tar mktemp mv docker sed tail; do
  need_cmd "${command_name}"
done
docker compose version >/dev/null 2>&1 ||
  die "docker compose plugin이 필요합니다."
check_runtime_state

mapfile -t BOOTSTRAP_INPUT < <(python3 - <<'PY'
import re
import sys
import termios
import tty


def read_required(terminal_input, terminal_output, prompt):
    while True:
        terminal_output.write(f"{prompt}: ")
        terminal_output.flush()
        value = terminal_input.readline().strip()
        if value:
            return value
        terminal_output.write("입력값이 비어 있습니다. 다시 입력하세요.\n")


def format_product_key(characters):
    groups = [
        "".join(characters[index : index + 4])
        for index in range(0, len(characters), 4)
    ]
    formatted = "-".join(groups)
    if len(characters) in (4, 8, 12):
        formatted += "-"
    return formatted


def read_product_key(terminal_input, terminal_output, prompt):
    input_fd = terminal_input.fileno()

    while True:
        characters = []
        original_settings = termios.tcgetattr(input_fd)
        terminal_output.write(f"{prompt}: ")
        terminal_output.flush()

        try:
            tty.setcbreak(input_fd)
            while True:
                character = terminal_input.read(1)

                if character in ("\r", "\n"):
                    break
                if character == "\x03":
                    raise KeyboardInterrupt
                if character == "\x04":
                    if not characters:
                        raise EOFError
                    break
                if character in ("\x7f", "\b"):
                    if characters:
                        previous_value = format_product_key(characters)
                        characters.pop()
                        current_value = format_product_key(characters)
                        erase_count = len(previous_value) - len(current_value)
                        terminal_output.write("\b \b" * erase_count)
                        terminal_output.flush()
                    continue
                if (
                    len(characters) >= 16
                    or not character.isascii()
                    or not character.isalnum()
                ):
                    continue

                uppercase_character = character.upper()
                characters.append(uppercase_character)
                terminal_output.write(uppercase_character)
                if len(characters) in (4, 8, 12):
                    terminal_output.write("-")
                terminal_output.flush()
        finally:
            termios.tcsetattr(input_fd, termios.TCSADRAIN, original_settings)
            terminal_output.write("\n")
            terminal_output.flush()

        if len(characters) == 16:
            return format_product_key(characters)
        terminal_output.write(
            "제품키는 영문자와 숫자 16자리여야 합니다. 다시 입력하세요.\n"
        )


try:
    with open(
        "/dev/tty", "r", encoding="utf-8", buffering=1
    ) as terminal_input:
        with open(
            "/dev/tty", "w", encoding="utf-8", buffering=1
        ) as terminal_output:
            while True:
                site_id = read_required(
                    terminal_input, terminal_output, "사이트 식별자"
                )
                if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", site_id):
                    break
                terminal_output.write(
                    f"사이트 식별자 형식이 올바르지 않습니다: {site_id}\n"
                )
            product_key = read_product_key(
                terminal_input, terminal_output, "제품키"
            )
except (KeyboardInterrupt, EOFError):
    print("입력이 취소되었습니다.", file=sys.stderr)
    raise SystemExit(130)
except OSError as error:
    print(f"터미널 입력을 열 수 없습니다: {error}", file=sys.stderr)
    raise SystemExit(1)

print(site_id)
print(product_key)
PY
)

[[ "${#BOOTSTRAP_INPUT[@]}" -eq 2 ]] ||
  die "사이트 식별자와 제품키 입력을 완료하지 못했습니다."
BASE_STRING="${BOOTSTRAP_INPUT[0]}"
PRODUCT_KEY="${BOOTSTRAP_INPUT[1]}"
unset BOOTSTRAP_INPUT

WORKDIR="$(mktemp -d /tmp/wizlink-bootstrap.XXXXXX)"
cleanup() {
  unset PRODUCT_KEY GHCR_TOKEN DEPLOY_TOKEN
  if [[ -n "${RELEASE_STAGE_DIR}" && -d "${RELEASE_STAGE_DIR}" ]]; then
    rm -rf -- "${RELEASE_STAGE_DIR}"
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# --- 2) Bootstrap 공개 저장소에서 .enc 다운로드 ---
GHCR_ENC_URL="${BOOTSTRAP_BASE_URL}/keys/${BASE_STRING}.ghcr.enc"
DEPLOY_ENC_URL="${BOOTSTRAP_BASE_URL}/keys/${BASE_STRING}.deploy.enc"
GHCR_ENC_FILE="${WORKDIR}/${BASE_STRING}.ghcr.enc"
DEPLOY_ENC_FILE="${WORKDIR}/${BASE_STRING}.deploy.enc"

detail "Bootstrap: ${BOOTSTRAP_OWNER}/${BOOTSTRAP_REPO}@${BOOTSTRAP_REF}"
detail "사이트 식별자: ${BASE_STRING}"
detail "암호화된 배포 인증정보 다운로드"

download "${GHCR_ENC_URL}" "${GHCR_ENC_FILE}"
download "${DEPLOY_ENC_URL}" "${DEPLOY_ENC_FILE}"

[[ -s "${GHCR_ENC_FILE}" ]] || die "GHCR enc 파일이 비어 있습니다."
[[ -s "${DEPLOY_ENC_FILE}" ]] || die "Deploy enc 파일이 비어 있습니다."
if grep -qi '<html' "${GHCR_ENC_FILE}" 2>/dev/null; then
  die "GHCR enc 다운로드가 HTML을 반환했습니다 (경로·브랜치 확인)."
fi

# --- 3) openssl 복호화 ---
GHCR_TOKEN="$(decrypt_token "${GHCR_ENC_FILE}" "${PRODUCT_KEY}" | tr -d '\r\n')"
DEPLOY_TOKEN="$(decrypt_token "${DEPLOY_ENC_FILE}" "${PRODUCT_KEY}" | tr -d '\r\n')"

[[ -n "${GHCR_TOKEN}" ]] || die "GHCR_TOKEN 복호화 결과가 비어 있습니다."
[[ -n "${DEPLOY_TOKEN}" ]] || die "DEPLOY_TOKEN 복호화 결과가 비어 있습니다."
unset PRODUCT_KEY

AUTH_HDR=(-H "Authorization: Bearer ${DEPLOY_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# --- 4) GHCR 로그인 ---
if [[ "${SKIP_DOCKER}" != "1" ]]; then
  DOCKER_LOGIN_LOG="${WORKDIR}/docker-login.log"
  if ! printf '%s\n' "${GHCR_TOKEN}" |
    docker login ghcr.io -u "${GHCR_USER}" --password-stdin \
      >"${DOCKER_LOGIN_LOG}" 2>&1; then
    sed 's/^/      /' "${DOCKER_LOGIN_LOG}" >&2
    die "GHCR 로그인에 실패했습니다."
  fi
  if [[ "${VERBOSE}" == "1" ]]; then
    sed 's/^/      /' "${DOCKER_LOGIN_LOG}"
  fi
else
  detail "SKIP_DOCKER=1 — GHCR login 생략(일회용 검증 전용)"
fi
unset GHCR_TOKEN
step_done 1 4 "배포 인증 확인"

# --- 5) wizlink-deploy Release 자산 다운로드 ---
if [[ "${SKIP_RELEASE}" != "1" ]]; then
  need_cmd python3

  if [[ "${RELEASE_TAG}" == "latest" ]]; then
    RELEASE_API="https://api.github.com/repos/${DEPLOY_OWNER}/${DEPLOY_REPO}/releases/latest"
  else
    RELEASE_API="https://api.github.com/repos/${DEPLOY_OWNER}/${DEPLOY_REPO}/releases/tags/${RELEASE_TAG}"
  fi

  detail "Release 조회: ${DEPLOY_OWNER}/${DEPLOY_REPO} (${RELEASE_TAG})"
  RELEASE_JSON="${WORKDIR}/release.json"
  http_get "${RELEASE_API}" "${AUTH_HDR[@]}" > "${RELEASE_JSON}" \
    || die "Release API 호출 실패 (토큰·저장소·태그 확인)"

  mapfile -t ASSET_LINES < <(
    python3 - "${RELEASE_JSON}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
tag = data.get("tag_name", "")
print(f"TAG\t{tag}")
assets = data.get("assets") or []
if not assets:
    sys.exit(0)
for a in assets:
    # API asset URL (auth + Accept: octet-stream 필요)
    print(f"ASSET\t{a['id']}\t{a['name']}\t{a['url']}")
PY
  )

  TAG_NAME=""
  declare -a ASSET_IDS=()
  declare -a ASSET_NAMES=()
  declare -a ASSET_URLS=()

  for line in "${ASSET_LINES[@]:-}"; do
    IFS=$'\t' read -r kind a b c <<<"${line}"
    case "${kind}" in
      TAG) TAG_NAME="${a}" ;;
      ASSET)
        ASSET_IDS+=("${a}")
        ASSET_NAMES+=("${b}")
        ASSET_URLS+=("${c}")
        ;;
    esac
  done

  [[ -n "${TAG_NAME}" ]] || die "Release 태그명을 얻지 못했습니다."
  [[ "${TAG_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
    die "Release tag가 지원하는 SemVer 형식이 아닙니다: ${TAG_NAME}"
  if [[ "${RELEASE_TAG}" != "latest" && "${TAG_NAME}" != "${RELEASE_TAG}" ]]; then
    die "조회된 Release tag가 요청과 다릅니다: 요청=${RELEASE_TAG}, 응답=${TAG_NAME}"
  fi
  VERSION="${TAG_NAME#v}"
  if [[ "${ACTION}" == "install" && -n "${CURRENT_VERSION}" && "${VERSION}" != "${CURRENT_VERSION}" ]]; then
    die "install로 버전을 변경할 수 없습니다: ${CURRENT_VERSION} -> ${VERSION}. upgrade를 사용하세요."
  fi
  BUNDLE_NAME="wizlink-${VERSION}-linux-amd64-deploy"
  ARCHIVE_NAME="${BUNDLE_NAME}.tar.gz"
  step_done 2 4 "릴리스 확인" "${TAG_NAME}"

  if [[ ${#ASSET_IDS[@]} -eq 0 ]]; then
    die "Release 자산(assets)이 없습니다: ${DEPLOY_OWNER}/${DEPLOY_REPO} ${TAG_NAME}"
  fi

  mkdir -p "${INSTALL_DIR}"
  INSTALL_DIR="$(cd "${INSTALL_DIR}" && pwd)"
  RELEASE_DIR="${INSTALL_DIR}/${VERSION}"
  RELEASE_STAGE_DIR="$(mktemp -d "${INSTALL_DIR}/.${VERSION}.XXXXXX")"
  chmod 0750 "${RELEASE_STAGE_DIR}"
  detail "Release 자산 다운로드: ${RELEASE_DIR}/"

  declare -A SEEN_ASSET_NAMES=()
  for i in "${!ASSET_IDS[@]}"; do
    name="${ASSET_NAMES[$i]}"
    url="${ASSET_URLS[$i]}"
    [[ -n "${name}" && "${name}" != "." && "${name}" != ".." && "${name}" != */* ]] ||
      die "안전하지 않은 Release 자산명입니다: ${name:-없음}"
    [[ -z "${SEEN_ASSET_NAMES[$name]:-}" ]] ||
      die "중복된 Release 자산명입니다: ${name}"
    SEEN_ASSET_NAMES["$name"]=1
    dest="${RELEASE_STAGE_DIR}/${name}"
    detail "다운로드: ${name}"
    # private/public 공통: API asset URL + octet-stream
    download "${url}" "${dest}" \
      -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -H "X-GitHub-Api-Version: 2022-11-28"
    [[ -s "${dest}" ]] || die "다운로드된 파일이 비어 있습니다: ${dest}"
  done

  for required_asset in "${ARCHIVE_NAME}" SHA256SUMS manifest.json; do
    [[ -f "${RELEASE_STAGE_DIR}/${required_asset}" ]] ||
      die "필수 Release 자산이 없습니다: ${required_asset}"
  done

  detail "Release metadata와 checksum 계약 검증"
  python3 - \
    "${RELEASE_STAGE_DIR}/manifest.json" \
    "${RELEASE_STAGE_DIR}/SHA256SUMS" \
    "${VERSION}" \
    "${ARCHIVE_NAME}" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
checksums_path = Path(sys.argv[2])
expected_version = sys.argv[3]
expected_archive = sys.argv[4]

with manifest_path.open(encoding="utf-8") as stream:
    manifest = json.load(stream)

expected_images = {
    "backend": f"ghcr.io/anjin0/wizlink-backend:{expected_version}",
    "nginx": f"ghcr.io/anjin0/wizlink-nginx:{expected_version}",
    "nettool": f"ghcr.io/anjin0/wizlink-nettool:{expected_version}",
}
if manifest.get("version") != expected_version:
    raise SystemExit("manifest version이 Release tag와 다릅니다.")
if manifest.get("architecture") != "linux/amd64":
    raise SystemExit("manifest architecture가 linux/amd64가 아닙니다.")
if manifest.get("bundle") != expected_archive:
    raise SystemExit("manifest bundle 이름이 Release tag와 다릅니다.")
if manifest.get("images") != expected_images:
    raise SystemExit("manifest 이미지 세트가 Release version과 다릅니다.")
wizcollector = manifest.get("wizcollector") or {}
if wizcollector.get("version") != expected_version:
    raise SystemExit("manifest Wizcollector version이 Release tag와 다릅니다.")
if wizcollector.get("architecture") != "linux/amd64":
    raise SystemExit("manifest Wizcollector architecture가 linux/amd64가 아닙니다.")

checksums = {}
for raw_line in checksums_path.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", raw_line)
    if not match:
        raise SystemExit("SHA256SUMS 형식이 올바르지 않습니다.")
    digest, name = match.groups()
    if "/" in name or name in checksums:
        raise SystemExit("SHA256SUMS 파일명이 안전하지 않거나 중복됩니다.")
    checksums[name] = digest.lower()

if set(checksums) != {expected_archive, "manifest.json"}:
    raise SystemExit("SHA256SUMS 자산 목록이 예상과 다릅니다.")
if manifest.get("bundle_sha256", "").lower() != checksums[expected_archive]:
    raise SystemExit("manifest와 SHA256SUMS의 bundle checksum이 다릅니다.")
PY
  (
    cd "${RELEASE_STAGE_DIR}"
    sha256sum --quiet -c SHA256SUMS
  ) || die "Release 외부 checksum 검증에 실패했습니다."

  detail "bundle archive 구조 검증"
  python3 - "${RELEASE_STAGE_DIR}/${ARCHIVE_NAME}" "${BUNDLE_NAME}" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

archive_path = sys.argv[1]
expected_root = sys.argv[2]

with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit("bundle archive가 비어 있습니다.")
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"안전하지 않은 archive 경로: {member.name}")
        if not path.parts or path.parts[0] != expected_root:
            raise SystemExit(f"예상 bundle root 밖의 경로: {member.name}")
        if member.issym() or member.islnk() or member.isdev() or member.isfifo():
            raise SystemExit(f"지원하지 않는 archive 항목: {member.name}")
PY

  STAGED_BUNDLE_ROOT="${RELEASE_STAGE_DIR}/${BUNDLE_NAME}"
  tar -xzf "${RELEASE_STAGE_DIR}/${ARCHIVE_NAME}" -C "${RELEASE_STAGE_DIR}"
  ACTION_SCRIPT="${STAGED_BUNDLE_ROOT}/${ACTION}.sh"
  [[ -x "${ACTION_SCRIPT}" ]] ||
    die "bundle ${ACTION}.sh가 없거나 실행 가능하지 않습니다: ${ACTION_SCRIPT}"
  [[ "$(<"${STAGED_BUNDLE_ROOT}/VERSION")" == "${VERSION}" ]] ||
    die "bundle VERSION이 Release tag와 다릅니다."

  # Release 디렉터리에 비밀 없는 출처 메타데이터만 기록한다.
  cat > "${RELEASE_STAGE_DIR}/.release-info" <<EOF
repo=${DEPLOY_OWNER}/${DEPLOY_REPO}
tag=${TAG_NAME}
base_string=${BASE_STRING}
mode=${ACTION}
EOF

  if [[ -e "${RELEASE_DIR}" ]]; then
    detail "기존 동일 version Release를 검증된 보관본과 원자 교체: ${RELEASE_DIR}"
  fi
  if ! activate_release_dir "${RELEASE_STAGE_DIR}" "${RELEASE_DIR}"; then
    die "검증된 Release 디렉터리 전환에 실패했습니다: ${RELEASE_DIR}"
  fi
  if [[ -d "${RELEASE_STAGE_DIR}" ]]; then
    rm -rf -- "${RELEASE_STAGE_DIR}"
  fi
  RELEASE_STAGE_DIR=""
  BUNDLE_ROOT="${RELEASE_DIR}/${BUNDLE_NAME}"
  ACTION_SCRIPT="${BUNDLE_ROOT}/${ACTION}.sh"

  unset DEPLOY_TOKEN
  AUTH_HDR=()
  step_done 3 4 "배포 파일 다운로드 및 검증"
  echo
  printf 'WizLink %s %s 작업을 시작합니다.\n' "${VERSION}" "${ACTION_LABEL}"
  if [[ "${ACTION}" == "rollback" ]]; then
    printf '데이터베이스는 되돌리지 않으며, 현재 DB와의 호환성 검사를 통과해야 합니다.\n'
  fi
  echo

  case "${ACTION}" in
    install)
      "${ACTION_SCRIPT}" \
        --prod \
        --home-dir "${WIZLINK_HOME}" \
        --version "${VERSION}"
      ;;
    upgrade | rollback)
      "${ACTION_SCRIPT}" "${VERSION}" \
        --home-dir "${WIZLINK_HOME}"
      ;;
  esac
else
  detail "SKIP_RELEASE=1 — Release 다운로드·배포 생략(일회용 검증 전용)"
fi

# --- 요약 ---
echo
if [[ "${SKIP_RELEASE}" != "1" ]]; then
  step_done 4 4 "WizLink 서비스 ${ACTION_LABEL}"
  echo
  printf 'WizLink %s %s가 완료되었습니다.\n' "${VERSION}" "${ACTION_LABEL}"
  if [[ -n "${CURRENT_VERSION}" ]]; then
    printf '버전 변경: %s -> %s\n' "${CURRENT_VERSION}" "${VERSION}"
  fi
  printf '설치 경로: %s\n' "${WIZLINK_HOME}"
  printf 'Release 경로: %s\n' "${RELEASE_DIR}"
  printf '사이트 식별자: %s\n' "${BASE_STRING}"
else
  echo "Bootstrap 검증이 완료되었습니다."
fi
