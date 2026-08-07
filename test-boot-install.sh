#!/usr/bin/env bash
set -Eeuo pipefail
# boot.sh mock 회귀 검증 — 실제 GitHub·GHCR·운영 runtime을 건드리지 않고
# 최초 설치 경로의 인증·Release 검증·wizlinkctl 인계 계약을 확인한다.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_SH="${REPO_ROOT}/boot.sh"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wizlink-boot-test.XXXXXX")"
WORK_ROOT="$(cd "${WORK_ROOT}" && pwd)"
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
  printf '[boot-install-test] 실패: %s\n' "$*" >&2
  exit 1
}

BOOT_ENV=(
  "PATH=${MOCK_BIN}:${PATH}"
  "FIXTURE_DIR=${FIXTURE_DIR}"
  "CALL_LOG=${CALL_LOG}"
  "INSTALL_DIR=${RELEASE_ROOT}"
  "WIZLINK_HOME=${RUNTIME_ROOT}"
  "BOOTSTRAP_BASE_URL=https://bootstrap.test"
  "SKIP_DOCKER=0"
  "VERBOSE=0"
)

# boot.sh는 제품키를 /dev/tty에서 cbreak로 읽으므로 pty가 필요하다. cbreak 전환은
# TCSAFLUSH라 대기 중인 입력을 버리므로, 프롬프트를 확인한 뒤에 값을 흘려 넣는다.
feed_boot() {
  local output_file="$1"
  shift
  : >"${output_file}"
  python3 "${FEEDER}" "${output_file}" 사이트 school.test 제품키 3LTP6TV74B7XR77E |
    script -qefc \
      "env $(printf '%q ' "${BOOT_ENV[@]}")bash ${BOOT_SH} $*" \
      /dev/null >"${output_file}"
}

run_boot() {
  local label="$1"
  shift
  local output_file="${WORK_ROOT}/${label}.out"
  if ! feed_boot "${output_file}" "$@"; then
    sed 's/^/  /' "${output_file}" >&2
    fail "${label} mock 실행이 실패했습니다."
  fi
}

run_boot_expect_failure() {
  local label="$1"
  shift
  if feed_boot "${WORK_ROOT}/${label}.out" "$@"; then
    fail "${label} 실패 검증이 성공으로 끝났습니다."
  fi
}

# 인증정보 입력 전에 거부되어야 하는 경우는 tty 없이 확인한다.
expect_preflight_failure() {
  local label="$1"
  local expected_message="$2"
  shift 2
  local output_file="${WORK_ROOT}/${label}.out"

  if env PATH="${MOCK_BIN}:${PATH}" \
    WIZLINK_HOME="${RUNTIME_ROOT}" \
    bash "${BOOT_SH}" "$@" >"${output_file}" 2>&1; then
    fail "${label} 사전 실패 검증이 성공으로 끝났습니다."
  fi
  grep -F "${expected_message}" "${output_file}" >/dev/null ||
    fail "${label} 실패 메시지가 예상과 다릅니다."
}

for command_name in openssl python3 sha256sum tar script; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "필수 테스트 명령이 없습니다: ${command_name}"
done

mkdir -p "${FIXTURE_DIR}/keys" "${MOCK_BIN}" "${RELEASE_ROOT}" "${RUNTIME_ROOT}"

FEEDER="${WORK_ROOT}/feed.py"
cat >"${FEEDER}" <<'PY'
import sys
import time

output_path = sys.argv[1]
pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))


def wait_for_prompt(marker, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with open(output_path, encoding="utf-8", errors="replace") as stream:
                if marker in stream.read():
                    return
        except OSError:
            pass
        time.sleep(0.05)
    raise SystemExit(f"프롬프트 대기 시간이 초과됐습니다: {marker}")


for prompt_marker, value in pairs:
    wait_for_prompt(prompt_marker)
    time.sleep(0.2)
    print(value, flush=True)

# 마지막 입력이 소비될 때까지 pty stdin을 열어 둔다.
time.sleep(3)
PY

printf 'ghcr-test-token\n' |
  openssl enc -aes-256-cbc -pbkdf2 -a \
    -pass "pass:${PRODUCT_KEY}" \
    -out "${FIXTURE_DIR}/keys/school.test.ghcr.enc"
printf 'deploy-test-token\n' |
  openssl enc -aes-256-cbc -pbkdf2 -a \
    -pass "pass:${PRODUCT_KEY}" \
    -out "${FIXTURE_DIR}/keys/school.test.deploy.enc"

# bundle에는 boot.sh가 인계하는 wizlinkctl만 있으면 된다.
# install.sh 호출 규약은 wizlinkctl 소관이라 boot.sh 검증 범위가 아니다.
mkdir -p "${FIXTURE_DIR}/${BUNDLE_NAME}"
printf '%s\n' "${VERSION}" >"${FIXTURE_DIR}/${BUNDLE_NAME}/VERSION"
cat >"${FIXTURE_DIR}/${BUNDLE_NAME}/wizlinkctl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'wizlinkctl|%s\n' "$*" >>"${CALL_LOG}"
SCRIPT
chmod 0755 "${FIXTURE_DIR}/${BUNDLE_NAME}/wizlinkctl"

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
  */releases/latest | */releases/tags/*) source_file="${FIXTURE_DIR}/release.json" ;;
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

# 1) 빈 서버 최초 설치 — tag 없이 latest, tag 명시 두 경로
run_boot install-latest
run_boot install-tag "${TAG}"
# 2) .env는 생겼지만 버전 기록 전에 중단된 부분 설치 복구
printf 'WIZLINK_ENV=production\n' >"${RUNTIME_ROOT}/.env"
run_boot install-partial "${TAG}"
# 3) 동일 버전 재실행(wizlinkctl 복구 경로)
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.1.0\n' >"${RUNTIME_ROOT}/.env"
run_boot install-same "${TAG}"

expected="wizlinkctl|install --release-dir ${RELEASE_ROOT}/${VERSION} --version ${VERSION} --home-dir ${RUNTIME_ROOT} --site school.test"
mapfile -t calls <"${CALL_LOG}"
[[ "${#calls[@]}" -eq 4 ]] ||
  fail "wizlinkctl 호출 횟수가 다릅니다: ${#calls[@]}"
for call in "${calls[@]}"; do
  [[ "${call}" == "${expected}" ]] ||
    fail "wizlinkctl 인계 인자가 다릅니다: ${call}"
done

# 4) 버전 변경은 boot.sh가 아니라 wizlinkctl upgrade의 몫이다.
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.0.0\n' >"${RUNTIME_ROOT}/.env"
expect_preflight_failure version-change "wizlinkctl upgrade" "${TAG}"

# 5) 옛 사용법(하위 명령)은 wizlinkctl로 안내하고 거부한다.
expect_preflight_failure legacy-upgrade "wizlinkctl upgrade" upgrade "${TAG}"
expect_preflight_failure legacy-rollback "wizlinkctl rollback" rollback "${TAG}"

release_info="${RELEASE_ROOT}/${VERSION}/.release-info"
grep -Fx "mode=install" "${release_info}" >/dev/null ||
  fail "Release metadata에 install mode가 없습니다."
grep -Fx "site=school.test" "${release_info}" >/dev/null ||
  fail "Release metadata에 사이트 식별자가 없습니다."
if grep -E 'token|3LTP|6TV7|4B7X|R77E' "${release_info}" >/dev/null; then
  fail "Release metadata에 비밀정보가 기록됐습니다."
fi

# 6) 검증 실패가 기존 보관본을 훼손하지 않는다.
printf 'preserved\n' >"${RELEASE_ROOT}/${VERSION}/preserved.marker"
printf '{}\n' >"${FIXTURE_DIR}/manifest.json"
printf 'WIZLINK_ENV=production\nWIZLINK_VERSION=1.1.0\n' >"${RUNTIME_ROOT}/.env"
run_boot_expect_failure corrupt-manifest "${TAG}"
[[ -f "${RELEASE_ROOT}/${VERSION}/preserved.marker" ]] ||
  fail "검증 실패가 기존 Release 보관본을 훼손했습니다."

printf '[boot-install-test] boot.sh 최초 설치 mock 검증 완료\n'
