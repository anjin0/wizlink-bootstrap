#!/usr/bin/env bash
# wizlink Bootstrap — 운영 서버 진입 스크립트 (Rocky Linux / RHEL 계열)
#
# 필요:
#   - openssl
#   - curl 또는 wget
#   - python3 (Release JSON·manifest·archive 검증)
#   - sha256sum, tar
#   - Docker Engine과 Docker Compose plugin
#
# 사용:
#   ./boot.sh
#   (실행 후 사이트 식별자 → 제품키를 순서대로 입력)
#
# 주요 환경변수(선택, 배포 동작용 — 식별자/제품키는 대화형 입력만):
#   BOOTSTRAP_REF=main
#   GHCR_USER=anjin0
#   DEPLOY_OWNER=anjin0  DEPLOY_REPO=wizlink-deploy
#   RELEASE_TAG=latest          # 또는 v1.2.3
#   INSTALL_DIR=./wizlink-release
#   WIZLINK_HOME=/opt/wizlink
#   SKIP_DOCKER=0               # 1 이면 GHCR login 생략(검증 전용)
#   SKIP_RELEASE=0              # 1 이면 Release 다운로드·설치 생략(검증 전용)

set -euo pipefail

BOOTSTRAP_OWNER="${BOOTSTRAP_OWNER:-anjin0}"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-wizlink-bootstrap}"
BOOTSTRAP_REF="${BOOTSTRAP_REF:-main}"
BOOTSTRAP_BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/${BOOTSTRAP_OWNER}/${BOOTSTRAP_REPO}/${BOOTSTRAP_REF}}"

DEPLOY_OWNER="${DEPLOY_OWNER:-anjin0}"
DEPLOY_REPO="${DEPLOY_REPO:-wizlink-deploy}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

GHCR_USER="${GHCR_USER:-anjin0}"

INSTALL_DIR="${INSTALL_DIR:-./wizlink-release}"
WIZLINK_HOME="${WIZLINK_HOME:-/opt/wizlink}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"
SKIP_RELEASE="${SKIP_RELEASE:-0}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
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

# --- 1) 대화형 입력 (인자/환경변수로 식별자·제품키를 받지 않음) ---
echo "wizlink Bootstrap"
echo

[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다. sudo로 실행하세요."
for command_name in openssl python3 sha256sum tar mktemp docker; do
  need_cmd "${command_name}"
done
docker compose version >/dev/null 2>&1 ||
  die "docker compose plugin이 필요합니다."

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
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# --- 2) Bootstrap 공개 저장소에서 .enc 다운로드 ---
GHCR_ENC_URL="${BOOTSTRAP_BASE_URL}/keys/${BASE_STRING}.ghcr.enc"
DEPLOY_ENC_URL="${BOOTSTRAP_BASE_URL}/keys/${BASE_STRING}.deploy.enc"
GHCR_ENC_FILE="${WORKDIR}/${BASE_STRING}.ghcr.enc"
DEPLOY_ENC_FILE="${WORKDIR}/${BASE_STRING}.deploy.enc"

info "Bootstrap: ${BOOTSTRAP_OWNER}/${BOOTSTRAP_REPO}@${BOOTSTRAP_REF}"
info "base_string: ${BASE_STRING}"
info "암호문 다운로드..."

download "${GHCR_ENC_URL}" "${GHCR_ENC_FILE}"
download "${DEPLOY_ENC_URL}" "${DEPLOY_ENC_FILE}"

[[ -s "${GHCR_ENC_FILE}" ]] || die "GHCR enc 파일이 비어 있습니다."
[[ -s "${DEPLOY_ENC_FILE}" ]] || die "Deploy enc 파일이 비어 있습니다."
if grep -qi '<html' "${GHCR_ENC_FILE}" 2>/dev/null; then
  die "GHCR enc 다운로드가 HTML을 반환했습니다 (경로·브랜치 확인)."
fi

# --- 3) openssl 복호화 ---
info "openssl 복호화..."
GHCR_TOKEN="$(decrypt_token "${GHCR_ENC_FILE}" "${PRODUCT_KEY}" | tr -d '\r\n')"
DEPLOY_TOKEN="$(decrypt_token "${DEPLOY_ENC_FILE}" "${PRODUCT_KEY}" | tr -d '\r\n')"

[[ -n "${GHCR_TOKEN}" ]] || die "GHCR_TOKEN 복호화 결과가 비어 있습니다."
[[ -n "${DEPLOY_TOKEN}" ]] || die "DEPLOY_TOKEN 복호화 결과가 비어 있습니다."
unset PRODUCT_KEY
info "token 복호화 완료(현재 Bootstrap 프로세스에서만 사용)"

AUTH_HDR=(-H "Authorization: Bearer ${DEPLOY_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# --- 4) GHCR 로그인 ---
if [[ "${SKIP_DOCKER}" != "1" ]]; then
  info "GHCR login (docker / ghcr.io / user=${GHCR_USER})..."
  printf '%s\n' "${GHCR_TOKEN}" |
    docker login ghcr.io -u "${GHCR_USER}" --password-stdin \
    || die "ghcr.io 로그인 실패"
  info "이미지 3종 pull은 검증된 bundle의 install.sh가 수행합니다."
else
  info "SKIP_DOCKER=1 — GHCR login 생략(일회용 검증 전용)"
fi
unset GHCR_TOKEN

# --- 5) wizlink-deploy Release 자산 다운로드 ---
if [[ "${SKIP_RELEASE}" != "1" ]]; then
  need_cmd python3

  if [[ "${RELEASE_TAG}" == "latest" ]]; then
    RELEASE_API="https://api.github.com/repos/${DEPLOY_OWNER}/${DEPLOY_REPO}/releases/latest"
  else
    RELEASE_API="https://api.github.com/repos/${DEPLOY_OWNER}/${DEPLOY_REPO}/releases/tags/${RELEASE_TAG}"
  fi

  info "Release 조회: ${DEPLOY_OWNER}/${DEPLOY_REPO} (${RELEASE_TAG})"
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
  VERSION="${TAG_NAME#v}"
  BUNDLE_NAME="wizlink-${VERSION}-linux-amd64-deploy"
  ARCHIVE_NAME="${BUNDLE_NAME}.tar.gz"
  info "Release tag: ${TAG_NAME}"

  if [[ ${#ASSET_IDS[@]} -eq 0 ]]; then
    die "Release 자산(assets)이 없습니다: ${DEPLOY_OWNER}/${DEPLOY_REPO} ${TAG_NAME}"
  fi

  mkdir -p "${INSTALL_DIR}"
  INSTALL_DIR="$(cd "${INSTALL_DIR}" && pwd)"
  info "자산 다운로드 → ${INSTALL_DIR}/"

  for i in "${!ASSET_IDS[@]}"; do
    name="${ASSET_NAMES[$i]}"
    url="${ASSET_URLS[$i]}"
    dest="${INSTALL_DIR}/${name}"
    info "  - ${name}"
    # private/public 공통: API asset URL + octet-stream
    download "${url}" "${dest}" \
      -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -H "X-GitHub-Api-Version: 2022-11-28"
    [[ -s "${dest}" ]] || die "다운로드된 파일이 비어 있습니다: ${dest}"
  done

  for required_asset in "${ARCHIVE_NAME}" SHA256SUMS manifest.json; do
    [[ -f "${INSTALL_DIR}/${required_asset}" ]] ||
      die "필수 Release 자산이 없습니다: ${required_asset}"
  done

  info "Release metadata와 checksum 계약 검증..."
  python3 - \
    "${INSTALL_DIR}/manifest.json" \
    "${INSTALL_DIR}/SHA256SUMS" \
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
    cd "${INSTALL_DIR}"
    sha256sum -c SHA256SUMS
  ) || die "Release 외부 checksum 검증에 실패했습니다."

  info "bundle archive 구조 검증..."
  python3 - "${INSTALL_DIR}/${ARCHIVE_NAME}" "${BUNDLE_NAME}" <<'PY'
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

  BUNDLE_ROOT="${INSTALL_DIR}/${BUNDLE_NAME}"
  if [[ -e "${BUNDLE_ROOT}" ]]; then
    info "기존 동일 version bundle 디렉터리를 검증된 archive로 교체: ${BUNDLE_ROOT}"
    rm -rf -- "${BUNDLE_ROOT}"
  fi
  tar -xzf "${INSTALL_DIR}/${ARCHIVE_NAME}" -C "${INSTALL_DIR}"
  [[ -x "${BUNDLE_ROOT}/install.sh" ]] ||
    die "bundle install.sh가 없거나 실행 가능하지 않습니다: ${BUNDLE_ROOT}/install.sh"
  [[ "$(<"${BUNDLE_ROOT}/VERSION")" == "${VERSION}" ]] ||
    die "bundle VERSION이 Release tag와 다릅니다."

  # 설치 디렉터리에 비밀 없는 출처 메타데이터만 기록한다.
  cat > "${INSTALL_DIR}/.release-info" <<EOF
repo=${DEPLOY_OWNER}/${DEPLOY_REPO}
tag=${TAG_NAME}
base_string=${BASE_STRING}
EOF

  unset DEPLOY_TOKEN
  AUTH_HDR=()
  info "Release 검증·압축 해제 완료: ${BUNDLE_ROOT}"
  info "bundle install.sh 실행(version=${VERSION}, home=${WIZLINK_HOME})"
  "${BUNDLE_ROOT}/install.sh" \
    --prod \
    --home-dir "${WIZLINK_HOME}" \
    --version "${VERSION}"
else
  info "SKIP_RELEASE=1 — Release 다운로드·설치 생략(일회용 검증 전용)"
fi

# --- 요약 ---
echo
info "완료"
echo "  base_string : ${BASE_STRING}"
if [[ "${SKIP_RELEASE}" != "1" ]]; then
  echo "  release     : ${TAG_NAME}"
  echo "  bundle      : ${BUNDLE_ROOT}"
  echo "  runtime     : ${WIZLINK_HOME}"
fi
