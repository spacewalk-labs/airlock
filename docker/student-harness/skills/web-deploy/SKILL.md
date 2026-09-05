---
name: web-deploy
description: 내 private 레포의 웹서비스를 홈서버에 표준으로 배포한다 — 배포용 OrbStack 머신 + GitHub self-hosted 러너 + Cloudflare Tunnel/게이트웨이 연결. push하면 자동 배포. 시작 전 서비스·포트·도메인을 상의한다.
---

# 웹서비스 배포 (web-deploy)

내 private GitHub 레포의 웹서비스를 **홈서버에 올려 내 도메인으로 공개**하는 표준입니다. `main`에 push하면
**홈서버 안의 GitHub 러너**가 알아서 빌드·재시작합니다 — 인바운드 개방·고정 IP 불필요.

> **전제(이미 되어 있어야 함):** 홈서버 본진 · Tailscale · **[도메인 준비]의 Cloudflare Tunnel + 게이트웨이**.
> 아직이면 그 챕터부터. ⚠️ **self-hosted 러너는 PRIVATE 레포에서만**(공개 레포는 위험).

## 표준 그림

```
git push main → GitHub Actions → 홈서버 안 self-hosted 러너(배포용 OrbStack 머신)
  → 빌드·재시작 → 게이트웨이(127.0.0.1:80) → cloudflared 터널 → https://<앱>.<내도메인>
```

## 먼저 상의해 확정 (부족하면 물어봄)

- **서비스 이름 / 서브도메인** — 예 `app.내도메인.com`.
- **포트** — 앱이 리슨할 로컬 포트(예 8000).
- **빌드·재시작 방법** — systemd `--user` 유닛 / `docker compose` 등.
- **배포용 머신** — **개발용과 분리**된 OrbStack 머신 권장([`orbstack-provision`](../orbstack-provision/SKILL.md)).

## 순서

1. **배포용 머신 준비** — `orbstack-provision`으로 배포 전용 머신(개발과 분리).
2. **self-hosted 러너 등록** — 레포 `Settings → Actions → Runners → New self-hosted runner`. 등록 토큰은
   **화면에만**(값 노출 금지) — 러너를 **배포용 머신 안**에 설치하고 `svc.sh`로 상시 실행. 라벨 예: `self-hosted, home`.
3. **`.github/workflows/deploy.yml` 추가** — `on: push(main)` → `runs-on: [self-hosted, home]` → 체크아웃 →
   `deploy.sh`(빌드·재시작). (템플릿은 강의 [웹서비스 배포] 챕터에 있습니다.)
4. **게이트웨이 배선** — `<앱>.<내도메인>` 호스트를 앱 포트로 보내는 서버 블록/route 추가(터널은 [도메인 준비]에서 이미).
5. **검증** — `main`에 작은 커밋을 push → Actions 초록 체크 → 바깥(폰 LTE)에서 `curl -s -o /dev/null -w '%{http_code}' https://<앱>.<내도메인>/` = **200**.

## 시크릿

- 러너 등록 토큰·앱 API 키는 **값을 파일·채팅·커밋에 남기지 않기**. 앱 시크릿은 [`secret-manage`](../secret-manage/SKILL.md)
  금고(bws)에서 주입, GitHub 쪽 값이 꼭 필요하면 **레포 Secrets**에.
- CI의 `BWS_ACCESS_TOKEN`은 대화형 `personal-reader` 토큰을 재사용하지 않습니다. 배포 전용 **`deploy-reader` 읽기 머신 계정**으로
  새 토큰을 발급해 private 레포의 GitHub Actions Secret에 넣고 해당 workflow step의 `env`로만 주입합니다.
  `~/.bws.env`·러너 `.env`·systemd `EnvironmentFile` 같은 평문 파일을 만들지 않습니다.
- 새 서브도메인·DNS·Tunnel을 API로 관리할 때는 금고의 `CLOUDFLARE_API_TOKEN`을 `bws run`으로
  주입합니다. 없으면 값을 요구하지 말고 「도메인 준비」 §4.0의 발급·금고 저장부터 안내합니다.

## 아카이브

배포가 서면 infra 레포 `services/<서비스>/`에 **도메인·포트·재시작법·러너 정보**를 런북으로 기록(값 아닌 참조).

## 출력

```
배포: <서비스> → https://<앱>.<내도메인>/ (Actions 초록 · 200 확인)
러너: 배포용 머신에 상시 · 런북: services/<서비스>/ 기록
```
