# WizLink 설치 안내 (`boot.sh`)

`boot.sh`는 운영 서버에 WizLink를 **처음 설치**할 때 한 번 실행하는 스크립트입니다.
사이트 식별자와 제품키로 배포 권한을 확인한 뒤 해당 버전의 설치 파일을 내려받아 설치합니다.

설치가 끝나면 서버에 `wizlinkctl` 명령이 생깁니다. **업그레이드·롤백·제거·상태 확인은
`boot.sh`를 다시 받지 않고 `wizlinkctl`로** 합니다.

## 준비물

- Rocky Linux / RHEL 계열 서버 (`linux/amd64`)
- `root` 권한 (`sudo`)
- Docker Engine과 Docker Compose plugin
- `openssl`, `python3`, `sha256sum`, `tar`, 그리고 `curl` 또는 `wget`
- 배포 담당자에게 받은 **사이트 식별자**와 **제품키**

## 설치

```bash
curl -fsSLo /tmp/boot.sh \
  https://raw.githubusercontent.com/anjin0/wizlink-bootstrap/main/boot.sh

sudo bash /tmp/boot.sh            # 최신 안정 버전
sudo bash /tmp/boot.sh v1.2.3     # 특정 버전
```

실행하면 두 값을 차례로 물어봅니다.

1. **사이트 식별자** — 배포 담당자에게 받은 값
2. **제품키** — 영문·숫자 16자리. 입력하는 동안 `XXXX-XXXX-XXXX-XXXX` 형태로 표시됩니다.

두 값은 명령 인자나 환경변수로 받지 않습니다. 반드시 화면에서 직접 입력해야 합니다.

설치 중에는 진행 상황이 `[1/4] ~ [4/4]`로 표시되고, 완료되면 설치 버전과 경로가 출력됩니다.

## 설치 직후 할 일: 수집기 기동

트래픽 수집기는 설치되지만 **자동으로 시작되지 않습니다.** 설치 시점에는 등록된 장비가 없어
수집할 대상이 없기 때문입니다. 웹 화면에서 장비 등록을 마친 뒤 기동하세요.

```bash
sudo wizlinkctl collector start    # 기동 (재부팅 후 자동 시작 포함)
sudo wizlinkctl collector status   # 기동 상태와 health 확인
sudo wizlinkctl collector stop     # 중지 (재부팅 후에도 멈춘 상태 유지)
```

## 설치 후 운영

```bash
sudo wizlinkctl status            # 현재 버전, 컨테이너, 수집기, 최근 배포 이력
sudo wizlinkctl upgrade v1.3.0    # 상위 버전으로 갱신
sudo wizlinkctl rollback v1.2.3   # 이전 버전으로 복귀
sudo wizlinkctl uninstall         # 제거
```

업그레이드와 롤백은 수집기 버전도 함께 바꾸지만 **기동 여부는 그대로 둡니다.** 돌고 있었으면
새 버전으로 계속 돌고, 멈춰 있었으면 멈춘 채로 남습니다.

`boot.sh`에 `install` / `upgrade` / `rollback` 같은 하위 명령을 붙이는 예전 방식은 더 이상
동작하지 않습니다. 그렇게 실행하면 `wizlinkctl`을 쓰라는 안내와 함께 중단됩니다.

## 다시 실행해야 할 때

- **설치가 중간에 실패했을 때**: 같은 버전으로 다시 실행하면 됩니다. 기존 설정, 비밀번호,
  데이터베이스는 그대로 보존됩니다.
- **`wizlinkctl` 명령을 찾을 수 없을 때**: 현재 설치된 것과 **같은 버전**으로 다시 실행하면
  복구됩니다. 현재 버전은 `grep WIZLINK_VERSION /opt/wizlink/.env`로 확인합니다.
- **버전을 바꾸고 싶을 때**: `boot.sh`로는 바꿀 수 없습니다. `wizlinkctl upgrade` 또는
  `wizlinkctl rollback`을 사용하세요.

## 설치 위치 변경

기본값은 서비스 홈 `/opt/wizlink`이고, 내려받은 설치 파일은 `/opt/wizlink/releases/`에
버전별로 보관됩니다. 다른 경로를 쓰려면 환경변수로 지정합니다.

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `WIZLINK_HOME` | `/opt/wizlink` | 서비스 홈 디렉터리 |
| `INSTALL_DIR` | `$WIZLINK_HOME/releases` | 버전별 설치 파일 보관 위치 |
| `VERBOSE` | `0` | `1`이면 진행 과정을 자세히 표시 |

```bash
sudo WIZLINK_HOME=/data/wizlink bash /tmp/boot.sh
```

## 문제가 생기면

`VERBOSE=1`로 다시 실행해 상세 로그를 남긴 뒤, 화면에 출력된 `[실패]` 메시지와 함께
배포 담당자에게 전달해 주세요.

- **사이트 식별자·제품키 오류**: 인증정보를 내려받지 못했거나 복호화에 실패한 경우입니다.
  두 값을 다시 확인하세요.
- **GHCR 로그인 실패**: 서버에서 `ghcr.io`로 나가는 네트워크가 열려 있는지 확인하세요.
- **버전을 바꿀 수 없다는 메시지**: 이미 설치된 서버입니다. `wizlinkctl upgrade`를 사용하세요.
