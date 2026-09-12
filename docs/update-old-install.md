# 옛 설치본을 최신으로 올리기

**이 문서가 필요한 경우**: 2026-08-21 이전에 Airlock 을 설치했거나, 업데이트 미리보기가
*"이 설치본은 지금 공개된 어떤 배포본과도 파일이 일치하지 않아…"* 라고 말할 때.

## 왜 따로 한 단계가 있나

공개 저장소의 이력은 2026-08-21 에 새로 시작했습니다. 그 전에 받은 파일은 지금 공개된 어떤
배포본과도 일치하지 않아서, `bin/airlock-update` 는 받은 배포본이 박스보다 **새것인지 옛것인지**
판단할 근거가 없습니다. 옛것을 덮어쓰는 사고를 막으려고 도구는 여기서 멈추고, 사람이 미리보기를
보고 `--from-unknown` 으로 확인해 줘야 진행합니다. **한 번 올리고 나면** 박스가 자기 배포본을
기록하므로 다음 업데이트부터는 이 플래그가 필요 없습니다.

## 순서

체크아웃에 `bin/airlock-update` 가 없으면(2026-08-22 이전 설치) 아래 `bash bin/airlock-update …`
대신 `curl -fsSL https://raw.githubusercontent.com/spacewalk-labs/airlock/main/bin/airlock-update | bash -s -- …`
로 같은 옵션을 넘깁니다.

**0. 백업.** 업데이트 도구가 되돌려 주는 것은 체크아웃(`~/workspace/airlock`)뿐입니다. 옛 박스에는
`bin/airlock-status` 가 없어서 **자동 롤백도 걸리지 않습니다.** 컨테이너나 VM 이면 스냅샷을 먼저
뜨세요. 설정도 따로 복사해 둡니다 — `airlock.toml` 은 git 이 추적하지 않습니다.

```bash
cp ~/workspace/airlock/airlock.toml ~/workspace/airlock/airlock.toml.before-update
```

Paseo 가 바뀌면 설치기가 Paseo 를 재시작하므로, 돌고 있는 에이전트 세션이 있으면 끊깁니다.
`paseo ls` 로 먼저 확인하세요.

**1. 미리보기.** 아무것도 바꾸지 않습니다.

```bash
bash bin/airlock-update --dry-run
```

볼 것: ① "파일이 일치하지 않아" 문구 ② 바뀔 파일 수 ③ 배포본에 없어 **그대로 남는** 파일
④ `airlock.toml 이 새 배포본의 설정 검사를 통과하지 못합니다` 가 있으면 2단계로.

**2. 설정 옮기기.** 설정 검사는 첫 오류에서 멈추므로, 고치고 1단계를 다시 돌려 오류가 없어질 때까지
반복합니다. 지금까지 확인된 것:

| 옛 설정 | 고칠 것 | 이유 |
|---|---|---|
| `[apps.markwand]` | 표 이름을 `[apps.fileview]` 로, `markserv_port` 줄은 삭제 (`filebrowser_port` 는 유지) | 2026-08-23 이름 변경. 검사기는 "오타면 지우라"고 하지만 **지우면 파일 뷰어가 꺼집니다** |
| `[apps.devterm]` 의 `public_port`·`redirect_port` | 두 줄 삭제 | devterm 은 이제 HTTPS(`https_port`)만 씁니다 |
| `paths.code_root`·`paths.mount_exclude`·`branding.logo` | 지워도 되고 둬도 됩니다 | 경고만 나고 설치는 됩니다 |

**3. 실행.**

```bash
bash bin/airlock-update --from-unknown
```

업데이트 전 상태를 자동 저장 커밋으로 남기고, 파일을 바꾸고, 설치기를 다시 돌립니다.
마지막에 `[airlock] done. Open: https://…` 가 나오면 끝입니다.

**4. 확인.**

```bash
python3 bin/airlock-status                 # verdict: OK, 종료 코드 0
bash bin/airlock-update --dry-run --json   # "available":false — 최신이고 감지기가 박스를 알아봄
sudo tailscale serve status                # 아래 "남는 것" 참고
```

그리고 **다른 기기**(휴대폰·노트북)에서 허브 주소를 한 번 여세요. 박스 안에서 자기 주소로 보낸
요청은 밖으로 나가지 않아서 그것만이 실제 확인입니다.

## 남는 것·바뀌는 것

- **배포본 파일을 직접 고쳐 썼다면 덮어씁니다.** 고친 내용은 `airlock-update: 업데이트 전 자동 저장`
  커밋에 남아 있으니 `git show <그 커밋> -- <파일>` 로 꺼낼 수 있습니다.
- **`collaborators` 는 셸급 앱(devterm·code-server·orca·paseo)에 들어가지 못합니다.** 옛 박스에서
  `install/render-nginx.sh` 등을 고쳐 협업 계정도 owner 처럼 쓰고 있었다면, 업데이트 뒤 그 계정은
  허브 앱만 씁니다.
- **옛 평문 포트 매핑이 남을 수 있습니다.** devterm 의 옛 `public_port`(기본 9900) 매핑은 새 설치기가
  자기 것으로 알아보지 못해 치우지 않습니다. `tailscale serve status` 에 설정에 없는 포트가 남아 있으면
  끕니다: `sudo tailscale serve --http=9900 off`.
- 배포본에서 빠진 옛 파일(`apps/markwand/` 등)은 지우지 않고 남깁니다. 설치에는 영향이 없습니다.

## 되돌리기

- 박스 전체: 0단계의 스냅샷을 복원합니다. 가장 확실합니다.
- 체크아웃만: 실행 로그의 `되돌리려면: git -C … reset --hard <커밋>` 을 치고, 백업한
  `airlock.toml` 을 되돌린 뒤 `bash install/airlock-install.sh` 를 다시 돌립니다. `/opt/airlock`·
  유닛·nginx 설정은 이 설치기가 다시 맞춥니다.

## 실측 한 건 (2026-09-13)

2026-07-29 에 설치한 Linux 박스(Ubuntu 24.04, LXC)를 이 순서대로 올렸습니다. 바뀐 파일 668개,
남은 옛 파일 20개, 설정 두 곳 수정(`markwand`, devterm 평문 포트), Paseo 0.1.110 → 0.2.5,
설치 약 1분 30초. 끝난 뒤 `airlock-status` 15 ok · 0 warn · 0 failed, 다른 기기에서 허브 200,
업데이트 감지 `available:false`.
