---
name: secret-manage
description: API 키·토큰·비밀번호를 코드나 채팅에 남기지 않고, bws(Bitwarden Secrets Manager) 금고에 넣어 실행 순간에만 꺼내 쓰게 돕는다. 키를 새 프로그램에 물릴 때·유출이 의심될 때 쓴다.
---

# 시크릿 관리 (secret-manage)

키를 **코드·파일·채팅에 절대 남기지 않고**, 금고(`bws`)에 넣어 **실행하는 순간에만** 꺼내 쓰는 걸
돕는 스킬입니다. 원칙 한 줄: **"비밀은 금고에, 쓸 때만 꺼낸다."**

> ⚠️ **절대 규칙:** 실제 키·토큰 **값**을 채팅창에 출력하거나 파일·깃·로그에 적지 않습니다.
> 항상 **이름(참조)** 으로만 다룹니다. `bws run` 이 값을 눈에 안 띄게 주입합니다.

## 언제

- 새 서비스(OpenAI·지도·DB 등) 키를 프로그램에 물릴 때
- "키를 어디 둬야 하냐"는 물음이 나올 때
- `.env` 평문 파일이나 채팅에 키가 적혀 있는 걸 발견했을 때(→ 금고로 옮기고 폐기)

## 먼저 확인 (사람이 한 번)

`bws`는 **액세스 토큰**으로 금고에 붙습니다. 이 토큰과 프로젝트는 **웹에서 사람이** 한 번 만듭니다
(화면·본인확인 필요): <https://vault.bitwarden.com/#/sm> → Secrets Manager 활성화 → 프로젝트 만들기 →
대화형 **머신 계정(읽기 전용)** → **액세스 토큰 발급(한 번만 표시)**.
기존 키는 사람이 Bitwarden 웹에서 직접 이관하고, 에이전트는 절차·이름·실행만 검증합니다.

> ⚠️ 여기는 **Password Manager의 '컬렉션'이 아니라 Secrets Manager의 '프로젝트'** 입니다(가장 흔한 혼동).
> 실제 값을 웹에서 관리하므로 대화형 `bws`에는 읽기 권한만 줍니다. CI는 이 토큰을 재사용하지 않고
> **별도 배포용 읽기 전용 머신 계정**을 써서 폐기·감사 범위를 분리합니다.

발급받은 토큰은 **평문으로 두지 말고 OS 보안 저장소**에 넣습니다:

```bash
# 맥 Keychain (한 번만) — 값은 화면에 그대로 안 남게 주의
security add-generic-password -a "$USER" -s BWS_ACCESS_TOKEN -w
# 셸 열 때 꺼내 주입 (.zshrc 등)
export BWS_ACCESS_TOKEN="$(security find-generic-password -a "$USER" -s BWS_ACCESS_TOKEN -w)"

# Ubuntu/headless (한 번만): GPG 키가 없으면 먼저 `gpg --full-generate-key`
sudo apt-get install -y pass gnupg
pass init "<본인-GPG-키-ID>"
pass insert k-ai/bws-access-token
# Ubuntu 현재 셸에 주입
export BWS_ACCESS_TOKEN="$(pass show k-ai/bws-access-token)"
```

## 설치 확인 (에이전트가 대신 가능)

```bash
command -v bws >/dev/null || brew install bitwarden/tap/bws   # 맥. 최신법은 공식 문서
bws --version
[ -n "$BWS_ACCESS_TOKEN" ] && echo "토큰 준비됨" || echo "먼저 BWS_ACCESS_TOKEN 설정 필요"
```

## Cloudflare 자동화 토큰 — 첫 발급은 웹에서 금고로 바로

- `BWS_ACCESS_TOKEN`은 **Bitwarden 금고를 여는 열쇠**입니다. 대화형 셸에서는 OS 보안 저장소,
  무인 CI에서는 별도 읽기 전용 토큰을 GitHub Actions Secret에 두며 평문 파일에는 두지 않습니다.
- `CLOUDFLARE_API_TOKEN`은 **Cloudflare DNS·Tunnel 자동화 열쇠**라 Bitwarden 금고 안에 둡니다.
- 첫 발급은 강의 「도메인 준비」 §4.0대로 사람이 Cloudflare에서 최소권한 토큰을 만들고,
  채팅·`내정보.txt`를 거치지 않은 채 Bitwarden의 **Name=`CLOUDFLARE_API_TOKEN` /
  Value=실제 토큰**으로 바로 저장합니다.
- `cloudflared tunnel login`은 별도의 브라우저 승인 흐름입니다. 이 API 토큰을 그 명령에 붙여넣지 않습니다.

## 키 넣기·이관 — 실제 값은 사람이 웹에서 직접

새 키를 금고에 넣거나 `.env` 평문을 옮길 때, 사람이 Bitwarden 웹에서
**Name=환경변수 이름 / Value=실제 값**을 직접 저장합니다. 에이전트는 값을 받거나 출력하지 않고,
이름 확인·실행 검증·원본 삭제 절차만 안내합니다.

```bash
# 사람이 웹에서 저장을 끝낸 뒤, 이름만 검증
bws run --no-inherit-env -- printenv | grep -oE '^[A-Z0-9_]+' | sort -u
```

> `bws secret create` 공식 문법은 `VALUE`를 명령행 인자로 받아 `ps`에 보일 수 있습니다.
> 따라서 초보자 기본 흐름에서는 실제 값을 에이전트에게 넘기지 않고 Bitwarden 웹에 바로 저장합니다.

## 쓰기 — 실행할 때만 키 주입

```bash
# 금고의 키들을 환경변수로 넣은 채로 프로그램 실행 (디스크에 .env 안 남김)
bws run -- python app.py
bws run -- npm run dev

# 잘 들어갔는지 이름만 확인 (기존 셸 환경변수도 제외)
bws run --no-inherit-env -- printenv | grep -oE '^[A-Z0-9_]+' | sort -u
```

시크릿의 **키 이름이 곧 환경변수 이름**입니다. 웹에서 `OPENAI_API_KEY`로 지었으면 코드에서
`os.environ["OPENAI_API_KEY"]` 로 바로 씁니다.

## 안전수칙 (에이전트가 항상 지킴)

- **키 값을 채팅·로그·커밋에 절대 남기지 않습니다.** 이름(참조)으로만.
- `.env` 평문을 만들면 반드시 `.gitignore`. 공유는 **키 이름만** 담은 `.env.example`.
- **액세스 토큰 = 프로젝트 열쇠** → 대화형 셸은 OS 보안 저장소, CI는 읽기 전용 Actions Secret. 평문 파일 금지.
- 유출 의심 → 웹에서 **즉시 폐기(revoke)** 후 재발급.
- 채팅·코드·파일에서 실제 키를 발견하면 → **금고로 옮기고, 노출된 키는 폐기**하도록 안내.

## 출력

```
금고 상태: bws 설치 ✔ / 토큰 ✔
확인한 키 이름: GEMINI_API_KEY, CLOUDFLARE_API_TOKEN   ← 이름만, 값 아님
실행: bws run -- <명령>
```
