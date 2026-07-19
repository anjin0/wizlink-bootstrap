#!/usr/bin/env bash
# wizlink Bootstrap — 운영 서버 진입 스크립트 (Rocky Linux / RHEL 계열)
#
# 필요:
#   - openssl
#   - curl 또는 wget
#   - python3 (Release JSON 파싱)
#   - docker 또는 podman (이미지 pull 시)
#
# 사용:
#   ./boot.sh pen.go.kr
#   ./boot.sh pen.go.kr 'XXXX-XXXX-XXXX-XXXX'
#   BASE_STRING=pen.go.kr PRODUCT_KEY='...' ./boot.sh
#
# 주요 환경변수(선택):
#   BOOTSTRAP_REF=main
#   GHCR_USER=anjin0
#   GHCR_IMAGE=ghcr.io/anjin0/wizlink:latest
#   DEPLOY_OWNER=anjin0  DEPLOY_REPO=wizlink-deploy
#   RELEASE_TAG=latest          # 또는 v1.2.3
#   INSTALL_DIR=./wizlink-release
#   SKIP_DOCKER=0               # 1 이면 login/pull 생략
#   SKIP_RELEASE=0              # 1 이면 Release 다운로드 생략
#   WIZLINK_ENV_FILE=./.wizlink-bootstrap.env

set -euo pipefail

BOOTSTRAP_OWNER="${BOOTSTRAP_OWNER:-anjin0}"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-wizlink-bootstrap}"
BOOTSTRAP_REF="${BOOTSTRAP_REF:-main}"
BOOTSTRAP_BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/${BOOTSTRAP_OWNER}/${BOOTSTRAP_REPO}/${BOOTSTRAP_REF}}"

DEPLOY_OWNER="${DEPLOY_OWNER:-anjin0}"
DEPLOY_REPO="${DEPLOY_REPO:-wizlink-deploy}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

GHCR_USER="${GHCR_USER:-anjin0}"
GHCR_IMAGE="${GHCR_IMAGE:-ghcr.io/anjin0/wizlink:latest}"

INSTALL_DIR="${INSTALL_DIR:-./wizlink-release}"
WIZLINK_ENV_FILE="${WIZLINK_ENV_FILE:-./.wizlink-bootstrap.env}"
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
  openssl enc -d -aes-256-cbc -pbkdf2 -a \
    -pass pass:"${product_key}" \
    -in "${enc_file}" 2>/dev/null \
    || die "복호화 실패: ${enc_file} (제품키·파일 확인)"
}

prompt_if_empty() {
  local varname="$1"
  local prompt="$2"
  local silent="${3:-0}"
  local current="${!varname:-}"
  if [[ -n "${current}" ]]; then
    return 0
  fi
  if [[ "${silent}" == "1" ]]; then
    read -r -s -p "${prompt}: " current
    echo
  else
    read -r -p "${prompt}: " current
  fi
  printf -v "${varname}" '%s' "${current}"
}

container_cli() {
  if have_cmd docker; then
    echo docker
  elif have_cmd podman; then
    echo podman
  else
    echo ""
  fi
}

# --- 1) 입력 ---
BASE_STRING="${1:-${BASE_STRING:-}}"
PRODUCT_KEY="${2:-${PRODUCT_KEY:-}}"

prompt_if_empty BASE_STRING "기준 문자열(base_string) 예: pen.go.kr"
prompt_if_empty PRODUCT_KEY "제품키" 1

BASE_STRING="$(echo -n "${BASE_STRING}" | tr -d '[:space:]')"
PRODUCT_KEY="$(echo -n "${PRODUCT_KEY}" | tr -d '\r\n')"

[[ -n "${BASE_STRING}" ]] || die "기준 문자열이 비어 있습니다."
[[ -n "${PRODUCT_KEY}" ]] || die "제품키가 비어 있습니다."

if [[ ! "${BASE_STRING}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "기준 문자열 형식이 올바르지 않습니다: ${BASE_STRING}"
fi

need_cmd openssl

WORKDIR="$(mktemp -d /tmp/wizlink-bootstrap.XXXXXX)"
cleanup() {
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

export GHCR_TOKEN
export DEPLOY_TOKEN
export WIZLINK_BASE_STRING="${BASE_STRING}"

umask 077
cat > "${WIZLINK_ENV_FILE}" <<EOF
# generated by wizlink boot.sh — do not commit
export WIZLINK_BASE_STRING='${BASE_STRING}'
export GHCR_TOKEN='${GHCR_TOKEN}'
export DEPLOY_TOKEN='${DEPLOY_TOKEN}'
export GHCR_USER='${GHCR_USER}'
export GHCR_IMAGE='${GHCR_IMAGE}'
export DEPLOY_OWNER='${DEPLOY_OWNER}'
export DEPLOY_REPO='${DEPLOY_REPO}'
export RELEASE_TAG='${RELEASE_TAG}'
export INSTALL_DIR='${INSTALL_DIR}'
EOF
chmod 600 "${WIZLINK_ENV_FILE}"
info "복호화 완료 → ${WIZLINK_ENV_FILE}"

AUTH_HDR=(-H "Authorization: Bearer ${DEPLOY_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# --- 4) GHCR 로그인 (+ 선택적 pull) ---
if [[ "${SKIP_DOCKER}" != "1" ]]; then
  CLI="$(container_cli)"
  if [[ -z "${CLI}" ]]; then
    info "docker/podman 없음 — GHCR login/pull 생략 (SKIP_DOCKER=1 과 동일)"
  else
    info "GHCR login (${CLI} / ghcr.io / user=${GHCR_USER})..."
    echo "${GHCR_TOKEN}" | "${CLI}" login ghcr.io -u "${GHCR_USER}" --password-stdin \
      || die "ghcr.io 로그인 실패"

    if [[ -n "${GHCR_IMAGE}" ]]; then
      info "이미지 pull: ${GHCR_IMAGE}"
      "${CLI}" pull "${GHCR_IMAGE}" || die "이미지 pull 실패: ${GHCR_IMAGE}"
    fi
  fi
else
  info "SKIP_DOCKER=1 — GHCR login/pull 생략"
fi

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
  info "Release tag: ${TAG_NAME}"

  if [[ ${#ASSET_IDS[@]} -eq 0 ]]; then
    die "Release 자산(assets)이 없습니다: ${DEPLOY_OWNER}/${DEPLOY_REPO} ${TAG_NAME}"
  fi

  mkdir -p "${INSTALL_DIR}"
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

  # 설치 디렉터리에 메타 기록
  cat > "${INSTALL_DIR}/.release-info" <<EOF
repo=${DEPLOY_OWNER}/${DEPLOY_REPO}
tag=${TAG_NAME}
base_string=${BASE_STRING}
EOF

  info "Release 다운로드 완료 (${#ASSET_IDS[@]}개 파일)"
else
  info "SKIP_RELEASE=1 — Release 다운로드 생략"
fi

# --- 요약 ---
echo
info "완료"
echo "  base_string : ${BASE_STRING}"
echo "  env 파일    : ${WIZLINK_ENV_FILE}"
echo "  GHCR_IMAGE  : ${GHCR_IMAGE}"
if [[ "${SKIP_RELEASE}" != "1" ]]; then
  echo "  INSTALL_DIR : ${INSTALL_DIR}"
fi
echo
echo "후속 예:"
echo "  source ${WIZLINK_ENV_FILE}"
echo "  cd ${INSTALL_DIR} && ls -la"
