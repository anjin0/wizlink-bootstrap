#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_SH="${REPO_ROOT}/boot.sh"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wizlink-bootstrap-test.XXXXXX")"
FIXTURE_DIR="${WORK_ROOT}/fixtures"
MOCK_BIN="${WORK_ROOT}/bin"
RELEASE_ROOT="${WORK_ROOT}/releases"
RUNTIME_ROOT="${WORK_ROOT}/runtime"
CALL_LOG="${WORK_ROOT}/calls.log"
VERSION="1.1.0"
TAG="v${VERSION}"
BUNDLE_NAME="wizlink-${VERSION}-linux-amd64-deploy"
PRODUCT_KEY="3LTP-6TV7-4B7X-R77E"

cleanup() {
  rm -rf -- "${WORK_ROOT}"
}
trap cleanup EXIT

fail() {
  printf '[boot-mode-test] 실패: %s\n' "$*" >&2
  exit 1
}

run_boot() {
  local action="$1"
  local output_file="${WORK_ROOT}/${action}.out"
  if ! python3 -c \
    'import sys, time; print("school.test", flush=True); time.sleep(0.2); print("3LTP6TV74B7XR77E", flush=True)' |
    script -qefc \
      "env PATH=${MOCK_BIN}:${PATH} FIXTURE_DIR=${FIXTURE_DIR} CALL_LOG=${CALL_LOG} INSTALL_DIR=${RELEASE_ROOT} WIZLINK_HOME=${RUNTIME_ROOT} BOOTSTRAP_BASE_URL=https://bootstrap.test SKIP_DOCKER=0 VERBOSE=0 bash ${BOOT_SH} ${action} ${TAG}" \
      /dev/null >"${output_file}"; then
    sed 's/^/  /' "${output_file}" >&2
    fail "${action} mock 실행이 실패했습니다."
  fi
}

run_boot_expect_failure() {
  local action="$1"
  local output_file="${WORK_ROOT}/${action}-staging-failure.out"
  if python3 -c \
    'import sys, time; print("school.test", flush=True); time.sleep(0.2); print("3LTP6TV74B7XR77E", flush=True)' |
    script -qefc \
      "env PATH=${MOCK_BIN}:${PATH} FIXTURE_DIR=${FIXTURE_DIR} CALL_LOG=${CALL_LOG} INSTALL_DIR=${RELEASE_ROOT} WIZLINK_HOME=${RUNTIME_ROOT} BOOTSTRAP_BASE_URL=https://bootstrap.test SKIP_DOCKER=0 VERBOSE=0 bash ${BOOT_SH} ${action} ${TAG}" \
      /dev/null >"${output_file}"; then
    fail "${action} 손상 Release 검증이 성공으로 끝났습니다."
  fi
}

expect_preflight_failure() {
  local action="$1"
  local tag="$2"
  local expected_message="$3"
  local output_file="${WORK_ROOT}/${action}-failure.out"

  if env PATH="${MOCK_BIN}:${PATH}" \
    WIZLINK_HOME="${RUNTIME_ROOT}" \
    bash "${BOOT_SH}" "${action}" "${tag}" >"${output_file}" 2>&1; then
    fail "${action} 사전 실패 검증이 성공으로 끝났습니다."
  fi
  grep -F "${expected_message}" "${output_file}" >/dev/null ||
    fail "${action} 실패 메시지가 예상과 다릅니다."
}

for command_name in openssl python3 sha256sum tar script; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "필수 테스트 명령이 없습니다: ${command_name}"
done

mkdir -p "${FIXTURE_DIR}/keys" "${MOCK_BIN}" "${RELEASE_ROOT}" "${RUNTIME_ROOT}"

printf 'ghcr-test-token\n' |
  openssl enc -aes-256-cbc -pbkdf2 -a \
    -pass "pass:${PRODUCT_KEY}" \
    -out "${FIXTURE_DIR}/keys/school.test.ghcr.enc"
printf 'deploy-test-token\n' |
  openssl enc -aes-256-cbc -pbkdf2 -a \
    -pass "pass:${PRODUCT_KEY}" \
    -out "${FIXTURE_DIR}/keys/school.test.deploy.enc"

mkdir -p "${FIXTURE_DIR}/${BUNDLE_NAME}"
printf '%s\n' "${VERSION}" >"${FIXTURE_DIR}/${BUNDLE_NAME}/VERSION"
for action_script in install upgrade rollback; do
  cat >"${FIXTURE_DIR}/${BUNDLE_NAME}/${action_script}.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s|%s\n' "$(basename "$0")" "$*" >>"${CALL_LOG}"
SCRIPT
  chmod 0755 "${FIXTURE_DIR}/${BUNDLE_NAME}/${action_script}.sh"
done

tar -czf "${FIXTURE_DIR}/${BUNDLE_NAME}.tar.gz" \
  -C "${FIXTURE_DIR}" "${BUNDLE_NAME}"
bundle_sha="$(sha256sum "${FIXTURE_DIR}/${BUNDLE_NAME}.tar.gz" | awk '{print $1}')"
cat >"${FIXTURE_DIR}/manifest.json" <<EOF
{
  "version": "${VERSION}",
  "architecture": "linux/amd64",
  "bundle": "${BUNDLE_NAME}.tar.gz",
  "bundle_sha256": "${bundle_sha}",
  "images": {
    "backend": "ghcr.io/anjin0/wizlink-backend:${VERSION}",
    "nginx": "ghcr.io/anjin0/wizlink-nginx:${VERSION}",
    "nettool": "ghcr.io/anjin0/wizlink-nettool:${VERSION}"
  },
  "wizcollector": {
    "version": "${VERSION}",
    "architecture": "linux/amd64"
  }
}
EOF
manifest_sha="$(sha256sum "${FIXTURE_DIR}/manifest.json" | awk '{print $1}')"
cat >"${FIXTURE_DIR}/SHA256SUMS" <<EOF
${bundle_sha}  ${BUNDLE_NAME}.tar.gz
${manifest_sha}  manifest.json
EOF
cat >"${FIXTURE_DIR}/release.json" <<EOF
{
  "tag_name": "${TAG}",
  "assets": [
    {"id": 1, "name": "${BUNDLE_NAME}.tar.gz", "url": "https://assets.test/archive"},
    {"id": 2, "name": "SHA256SUMS", "url": "https://assets.test/checksums"},
    {"id": 3, "name": "manifest.json", "url": "https://assets.test/manifest"}
  ]
}
EOF

cat >"${MOCK_BIN}/id" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo 0
else
  /usr/bin/id "$@"
fi
SCRIPT

cat >"${MOCK_BIN}/docker" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  echo "Docker Compose test"
  exit 0
fi
if [[ "${1:-}" == "login" ]]; then
  cat >/dev/null
  echo "Login Succeeded"
  exit 0
fi
exit 1
SCRIPT

cat >"${MOCK_BIN}/curl" <<'SCRIPT'
#!/usr/bin/env bash
output=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --connect-timeout | --max-time | -H)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

case "${url}" in
  */keys/school.test.ghcr.enc) source_file="${FIXTURE_DIR}/keys/school.test.ghcr.enc" ;;
  */keys/school.test.deploy.enc) source_file="${FIXTURE_DIR}/keys/school.test.deploy.enc" ;;
  */releases/tags/*) source_file="${FIXTURE_DIR}/release.json" ;;
  https://assets.test/archive) source_file="${FIXTURE_DIR}/wizlink-1.1.0-linux-amd64-deploy.tar.gz" ;;
  https://assets.test/checksums) source_file="${FIXTURE_DIR}/SHA256SUMS" ;;
  https://assets.test/manifest) source_file="${FIXTURE_DIR}/manifest.json" ;;
  *) echo "unexpected URL: ${url}" >&2; exit 1 ;;
esac

if [[ -n "${output}" ]]; then
  cp "${source_file}" "${output}"
else
  printf '%s\n' "$(<"${source_file}")"
fi
SCRIPT
chmod 0755 "${MOCK_BIN}/id" "${MOCK_BIN}/docker" "${MOCK_BIN}/curl"

run_boot install
printf 'WIZLINK_ENV=production\n' >"${RUNTIME_ROOT}/.env"
run_boot install
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.1.0\n' >"${RUNTIME_ROOT}/.env"
run_boot install
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.0.0\n' >"${RUNTIME_ROOT}/.env"
run_boot upgrade
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.2.0\n' >"${RUNTIME_ROOT}/.env"
run_boot rollback
expect_preflight_failure install "v1.0.0" "install로 버전을 변경할 수 없습니다"
expect_preflight_failure upgrade "${TAG}" "낮은 버전으로 upgrade할 수 없습니다"
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.0.0\n' >"${RUNTIME_ROOT}/.env"
expect_preflight_failure rollback "${TAG}" "높은 버전으로 rollback할 수 없습니다"

mapfile -t calls <"${CALL_LOG}"
[[ "${calls[0]}" == "install.sh|--prod --home-dir ${RUNTIME_ROOT} --version ${VERSION}" ]] ||
  fail "install 인자 전달이 다릅니다: ${calls[0]:-없음}"
[[ "${calls[1]}" == "install.sh|--prod --home-dir ${RUNTIME_ROOT} --version ${VERSION}" ]] ||
  fail "부분 install 복구 인자 전달이 다릅니다: ${calls[1]:-없음}"
[[ "${calls[2]}" == "install.sh|--prod --home-dir ${RUNTIME_ROOT} --version ${VERSION}" ]] ||
  fail "동일 버전 install 재실행 인자 전달이 다릅니다: ${calls[2]:-없음}"
[[ "${calls[3]}" == "upgrade.sh|${VERSION} --home-dir ${RUNTIME_ROOT}" ]] ||
  fail "upgrade 인자 전달이 다릅니다: ${calls[3]:-없음}"
[[ "${calls[4]}" == "rollback.sh|${VERSION} --home-dir ${RUNTIME_ROOT}" ]] ||
  fail "rollback 인자 전달이 다릅니다: ${calls[4]:-없음}"

release_info="${RELEASE_ROOT}/${VERSION}/.release-info"
grep -Fx "mode=rollback" "${release_info}" >/dev/null ||
  fail "최종 실행 mode가 Release metadata에 없습니다."
if grep -E 'token|3LTP|6TV7|4B7X|R77E' "${release_info}" >/dev/null; then
  fail "Release metadata에 비밀정보가 기록됐습니다."
fi

printf 'preserved\n' >"${RELEASE_ROOT}/${VERSION}/preserved.marker"
printf '{}\n' >"${FIXTURE_DIR}/manifest.json"
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.2.0\n' >"${RUNTIME_ROOT}/.env"
run_boot_expect_failure rollback
[[ -f "${RELEASE_ROOT}/${VERSION}/preserved.marker" ]] ||
  fail "검증 실패가 기존 Release 보관본을 훼손했습니다."

printf '[boot-mode-test] install/upgrade/rollback mock 검증 완료\n'
