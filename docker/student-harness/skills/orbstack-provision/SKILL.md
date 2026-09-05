---
name: orbstack-provision
description: 홈서버(맥=OrbStack)에 작업·배포용 리눅스 머신을 표준 절차로 만든다. 이름·아키텍처·CPU/RAM(soft 공유)·디스크·설치 앱을 사용자와 상의해 확정하고, 결과를 infra 레포 machines/에 아카이브한다.
---

# OrbStack 머신 프로비저닝 (orbstack-provision)

맥(OrbStack)에 우분투 **작업/배포용 머신**을 표준대로 만드는 스킬입니다. 회사 `lxd-provision`의 철학을
학생용으로 옮긴 것 — **즉시 만들지 말고 부족한 걸 상의**, **표준 이탈은 확인**, **사실을 아카이브**.

> ⚠️ **즉시 만들지 않습니다.** 아래 항목을 사용자와 **하나씩 확정**한 뒤 실행합니다. 이미 명시한 값은 건너뜀.

## 0. 환경 조사 (읽기 전용)

OS·아키텍처·메모리·디스크 여유·OrbStack/Tailscale/Airlock/`gh` 설치 상태를 먼저 확인. 미확인은 추측 없이 "확인 필요".

## 1. 상의해 확정할 것 (부족하면 계속 물어봄)

| 항목 | 디폴트/제안 | 상의 포인트 |
|---|---|---|
| **머신 이름** | `airlock`(1인) / `airlock-<이름>`(2인) | 임의 결정 금지 — 후보 제시 후 선택 |
| **아키텍처** | 감지값(arm64 권장, amd64=Rosetta) | orca 쓰면 amd64. 다른 값 요구 시 재확인 |
| **CPU·메모리** | 목적별 제안(문서·개발=낮음 / 자동화 여러 개=중간) | **OrbStack은 CPU·RAM도 하드 예약이 아니라 호스트와 탄력 공유(soft)** 임을 설명. "몇 코어 고정" 요구 시 "표준은 soft인데 하드가 맞냐" 확인 |
| **디스크 예산** | 여유 기반 보수적(예 ~80GB), 하드 쿼터 아님 | 여유 전체 자동 점유 금지 |
| **설치 앱** | 기본 세트(무거운 orca·code-server는 처음엔 빼기) | 범주별 확인 |

## 2. 표준 이탈이면 확인 (맹종·조용한 바꿔치기 금지)

다음은 그냥 진행하지 말고 **"표준은 X인데 요청은 Y — Y로 갈까요? 영향은 Z"** 로 확인:
CPU/RAM **하드 예약** 요구 · 회사 레포 **clone** 시도 · **Public** 레포 · 디스크 과다 점유 · 시크릿을 파일로 저장 · 표준 폴더 구조 이탈.

## 3. 실행 (승인 후, 단계별 검증)

```bash
# 예: 헬퍼 스크립트(레포)가 머신 생성 → base 패키지 → tailscale up --ssh → 스톡 설치까지
AIRLOCK_MACHINE=<이름> bash docker/orbstack-machine-setup.sh
orb -m <이름> systemctl --user status 'airlock-*'   # 상태 확인
```
- 각 단계 출력 확인. **실패 시 강행하지 말고** 부분 자원 정리(`orb delete <이름>` 등) 여부를 사용자에게 확인.
- 시크릿(예: `TS_AUTHKEY`)은 **값 노출 금지** — 금고에서 주입([`secret-manage`](../secret-manage/SKILL.md)).

## 3-1. 재부팅 생존 확인 (머신을 만들었으면 여기까지가 한 세트)

머신은 떴는데 **맥이 재부팅되면 통째로 안 돌아오는** 상태가 흔합니다. OrbStack 은 GUI 앱이라
데스크톱 세션 위에서만 살고, 세션이 없으면 SSH 로 들어가도 `orb` 를 실행할 자리가 없습니다.
**두 겹을 확인하고, 비어 있으면 채웁니다**:

```bash
sysadminctl -autologin status                # ① → Automatic login user: <계정>  (is OFF. 면 사람이 켜야 함)
orb config set app.start_at_login true       # ② 에이전트가 직접 켤 수 있음
sudo sfltool dumpbtm | grep -ci orbstack     # ② 검증 — 0 이면 미등록 (sudo 필수: 없으면 권한거부로 0)
orb list                                     # 머신 상태(지금 켜져 있나 — 자동기동 증거 아님)
```

- ②는 **CLI 로 됩니다**(실측: 0건 → 2건). `osascript` 로 로그인 항목을 넣으려 하면 자동화 권한 창이
  화면에 떠 **명령이 멈추니** 쓰지 마세요.
- ①은 **CLI 로 켜는 표준 명령(`sysadminctl -autologin set`)이 실측에서 `error:22` 로 실패**했습니다
  (macOS 15.1.1 · Apple Silicon, 종료코드는 0). 게다가 `autoLoginUser` 만 써 놓고 `/etc/kcpassword`
  는 못 만들어 **절반만 걸린 상태**로 남습니다. `is OFF.` 면 사용자에게 시스템 설정에서 켜 달라고
  하고 멈추세요. FileVault 가 `On` 이어도 마찬가지입니다(재부팅 시 락아웃).
  → 우회 경로와 근거 = 2강 보강자료 「맥미니 무인운영」 §1-2.
- **`orb list` 의 `running` 은 자동 기동의 증거가 아닙니다** — 지금 켜져 있다는 뜻일 뿐입니다.
  재부팅 후에도 스스로 오는지는 아래 실측으로만 압니다.
- 복구 경로도 함께 확인: 맥 호스트 SSH 진입이 되는지(게스트가 죽으면 **거기서만** 살릴 수 있음),
  `~/.orbstack/bin/orb start <이름>` 이 그 계정으로 도는지.
- **재부팅 실측 없이 "생존한다"고 보고하지 마세요.** 사용자 동의를 받아 한 번 재부팅하고,
  아무것도 손대지 않은 채 입구가 200 인지로 판정합니다.

## 4. 아카이브 (작업의 일부 — 이걸 해야 완료)

본진 표준인 **`~/workspace/infra/` 레포**(강의 "본진 만들기" 레시피에서 1회 세팅)의 `machines/<host>.md`에
**머신 이름·arch·자원 설정(soft 명시)·Tailscale 노드·주소·설치 앱**, 그리고 **재부팅 복구 절차**(맥 호스트
진입 방법 + `~/.orbstack/bin/orb start <이름>`)를 기록하고 커밋·push. 미확인은 "확인 필요"로.
아직 infra 레포가 없으면 그 레시피부터 안내합니다.

## 출력

```
머신: <이름> (arch, soft CPU/RAM, ~NGB 예산) 생성·검증 완료
아카이브: machines/<host>.md 갱신·push
```

> 배포용 머신이면 이어서 **웹서비스 배포 표준**(Cloudflare Tunnel + 게이트웨이 + GitHub self-hosted runner + `deploy` 스킬)으로 연결합니다.
