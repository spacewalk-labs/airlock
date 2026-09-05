# templates — 빈 파일에서 시작하지 않기 위한 골격

문서를 만들 때 흰 화면부터 시작하지 마세요. 골격 하나를 복사해서 채웁니다.

🔴 **새 문서는 `base.html` + `snippets/` 로 만듭니다.** 회사 정본이 2026-08-31 에 유형별
템플릿을 없앴습니다 — 고르는 비용과 빈칸이 문서를 경직시켰고, 골격은 어차피 같았습니다.
아래 네 개(`report`·`decision`·`runbook`·`catalog`)는 **옛 판**입니다. 이미 쓰고 계시면
그대로 두셔도 되지만, 새로 시작할 때는 고르지 마세요.

- [`base.html`](base.html) — 여기서 시작합니다. 유형을 고르지 않습니다.
- [`snippets/decision.html`](snippets/decision.html) — 답을 받아야 할 때 붙입니다.
- [`snippets/quiz.html`](snippets/quiz.html) — 이해 점검을 붙일 때.

**클래스명과 속성(`data-decisions`·`data-correct` 등)은 바꾸지 마십시오** — `doc.js` 가
그 이름으로 찾습니다. 새 클래스에는 문서 고유 접두사를 붙입니다(`.xx-step`).

설치 후 실제 경로:

```
~/.claude/skills/share-docs/templates/   # base + snippets/ + 옛 판 4개 + 이 문서
~/.claude/skills/share-docs/assets/      # doc.css · doc.js · doc-print.css
```

## 옛 판 — 유형별 템플릿 4종 (새 문서에는 쓰지 않습니다)

유형을 가르는 축은 하나입니다 — **이 문서를 다 읽은 사람이 무엇을 하게 되나.**
그 답이 다르면 맨 위에 오는 것과 끝맺는 방식이 달라지고, 나머지 골격은 같습니다.

| 템플릿 | 독자의 마지막 행동 | 언제 | 맨 위에 오는 것 |
|---|---|---|---|
| [`report.html`](report.html) | **읽고 납득** | 조사·진단·실측·설계 기록 | 결론 한 줄 + 수치 |
| [`decision.html`](decision.html) | **고르고 회신** | 결정·미결·피드백·제안 승인 | 정할 것의 목록 |
| [`runbook.html`](runbook.html) | **따라 실행** | 절차·가이드·설치 문서 | 언제 쓰는 문서인지 |
| [`catalog.html`](catalog.html) | **다음 문서로 이동** | 색인·허브·목록 | 무엇이 어디 있나 |

억지로 끼워 맞추지 않습니다 — **판단이 안 서면 고르지 말고 `base.html`** 로 시작하세요.

## 쓰는 법 — 공통

아래 "쓰는 법"·"발행 전 인라인"은 `base.html` 이든 옛 판 4종이든 똑같이 적용됩니다.

1. 골격 하나와 **`assets/` 의 `doc.css` · `doc.js` 를 문서 폴더로 같이 복사**합니다.
   **파일명은 영문·숫자·하이픈으로** 짓습니다 — 발행 링크(slug)가 파일명에서 나오는데,
   한글은 전부 떨어져 나가 `doc-ee2814` 같은 뜻 없는 주소가 됩니다.
   ```bash
   mkdir -p ~/workspace/myproject/docs && cd $_
   cp ~/.claude/skills/share-docs/templates/report.html mydoc.html
   cp ~/.claude/skills/share-docs/assets/doc.css ~/.claude/skills/share-docs/assets/doc.js .
   ```
2. `{중괄호}` 를 전부 채우거나 지웁니다. 남은 게 없는지 확인:
   ```bash
   grep -nE '\{[^{}]{0,80}\}' mydoc.html
   ```
   🔴 **첫 글자를 한글로 좁히지 마세요.** `\{[가-힣]…` 로 잡으면 `{1. 무엇을 어떻게 쟀나}` 같은
   **섹션 제목**과 `{YYYY-MM-DD}` · `{N}` · 빈 칸 `{}` 를 통째로 놓칩니다.
   🔴 **반드시 인라인(4번) 전 원본에서만 돌립니다.** 인라인한 뒤에는 `doc.css`·`doc.js` 의
   중괄호가 전부 잡혀 **0 줄이 될 수 없습니다** — 채우지 않은 `report.html` 실측으로
   **인라인 전 47줄 → 인라인 후 211줄**입니다. 원본에서 잡힌 줄을 하나씩 보며
   **0 이 될 때까지** 채운 뒤 인라인하세요.
3. 브라우저로 **파일을 직접 열어** 확인합니다(같은 폴더의 `doc.css`·`doc.js` 를 그대로 읽습니다).
4. **발행 전에 CSS·JS 를 문서 안에 넣습니다** — 아래 절.

## 발행 전에 CSS·JS 를 문서 안에 넣기 (중요)

발행본은 **파일 하나로 자기완결**이어야 합니다(`../SKILL.md` "순서" 1번). 작업 중에는
`<link rel="stylesheet" href="doc.css">` 로 편하게 두고, **발행할 파일만** 아래로 한 번
말아 넣으세요. 스타일·목차·복사 버튼이 통째로 죽는 사고가 여기서 갈립니다.

```bash
python3 - <<'PY'
import base64, mimetypes, pathlib, re
src = pathlib.Path('mydoc.html')           # 작업 중인 문서
out = pathlib.Path('mydoc.pub.html')       # 발행할 단일 파일
base, html = src.parent, src.read_text(encoding='utf-8')

# 🔴 한 번에 훑습니다. css 를 먼저 넣고 다시 훑으면 넣은 내용 안의 예시 태그까지 건드립니다.
TAG = re.compile(r'<link\b[^>]*?rel="stylesheet"[^>]*?>'
                 r'|<script\b[^>]*?\bsrc="[^"]*"[^>]*?>\s*</script>'
                 r'|<img\b[^>]*?\bsrc="[^"]*"[^>]*?>', re.I)

def repl(m):
    tag = m.group(0)
    ref = re.search(r'\b(?:href|src)="([^"]*)"', tag)
    f = base / ref.group(1) if ref else None
    if not (f and f.is_file()): return tag             # data: · http: 는 그대로 둡니다
    low = tag.lower()
    if low.startswith('<link'):
        return '<style>\n' + f.read_text(encoding='utf-8').replace('</style', '<\\/style') + '\n</style>'
    if low.startswith('<script'):
        return '<script type="module">\n' + f.read_text(encoding='utf-8').replace('</script', '<\\/script') + '\n</script>'
    ct = mimetypes.guess_type(f.name)[0] or 'image/png'
    data = 'data:%s;base64,%s' % (ct, base64.b64encode(f.read_bytes()).decode())
    return re.sub(r'(\bsrc=)"[^"]*"', lambda k: k.group(1) + '"' + data + '"', tag, count=1)

out.write_text(TAG.sub(repl, html), encoding='utf-8')
print(out, out.stat().st_size, 'bytes')
PY
```

- 만들어진 `mydoc.pub.html` 을 **브라우저로 열어** 스타일이 살아 있는지 보고 발행합니다.
- **문서를 고칠 때마다 다시 돌립니다.** 원본만 고치고 옛 발행본을 올리면 조용히 옛 내용이 나갑니다.
- 에디터로 해도 됩니다 — `<link ...>` 줄을 `<style>` + `doc.css` 내용으로, `<script src=...>`
  줄을 `<script type="module">` + `doc.js` 내용으로 바꾸면 같은 결과입니다.

> 📌 **발행 앱이 대신 해 주는 경우도 있습니다.** Airlock 의 `publish` 는 스냅샷을 만들 때
> 문서가 참조하는 **로컬** css·js·img 를 안으로 넣어 줍니다. 다만 그 자산이
> **발행 폴더 안에 실제 파일로** 있어야 하고, 폴더 밖을 가리키는 심링크는 (의도적으로) 거부합니다.
> 거부돼도 **발행은 성공하고 스타일만 빠집니다** — 조용히 깨집니다. 그래서 위처럼 **미리 넣어
> 두는 쪽이 안전**하고, 그 파일은 메일·USB 로 보내도 그대로 열립니다.
> 어느 쪽을 택하든 발행 후 **공개 URL 을 직접 열어** 스타일이 살아 있는지 눈으로 확인하세요.

### 인쇄(PDF)로도 낼 거라면

`doc-print.css` 를 인쇄 전용으로 하나 더 걸면 A4 조판이 정돈됩니다(선택).

```html
<link rel="stylesheet" href="doc.css">
<link rel="stylesheet" href="doc-print.css" media="print">
```

### Mermaid 다이어그램만 예외

`<pre class="mermaid">` 는 그릴 때 **인터넷에서 라이브러리를 받아옵니다.** 오프라인이면
다이어그램만 안 뜨고 페이지는 정상입니다. 완전한 오프라인 자기완결이 필요하면
Mermaid 대신 **인라인 SVG** 를 쓰세요.

## 섞어 쓰십시오 — 템플릿은 배타적이지 않습니다

실제 문서는 한 유형에 딱 떨어지지 않습니다. **조사 결과를 보고하면서 그 자리에서 결정을
받는** 문서, **절차서인데 앞부분이 진단**인 문서가 흔합니다. 고르지 못해 멈추지 말고
**주 유형 하나로 시작한 뒤 필요한 절을 가져다 붙입니다.**

| 섞는 조합 | 어떻게 |
|---|---|
| 보고 + 결정 | `report` 로 시작 → 끝에 `decision` 의 `.dec` 항목들과 `.commit-bar[data-decisions]` 를 붙임 |
| 진단 + 절차 | `report` 로 원인까지 쓰고 → `runbook` 의 "절차·완료 확인·되돌리기" 를 이어 붙임 |
| 색인 + 보고 | `catalog` 의 `.landing-cards` 를 `report` 위에 두어 긴 문서의 진입점으로 씀 |
| 무엇이든 + 이해 점검 | `report` 의 `.doc-quiz` 블록을 그대로 옮김 |
| 무엇이든 + 근거 시각화 | `report` 의 figure·막대·Mermaid 예시를 그대로 옮김 |
| 여러 장으로 나눈 문서 | `doc.css` 의 `.doc-series`(상단 장 목록)·`.doc-series-nav`(끝의 이전/다음). 링크만으로 동작합니다 |

지킬 것은 두 가지입니다.

- **주 유형의 "맨 위" 는 유지합니다.** 결정을 받는 문서면 정할 것이 위에, 보고면 결론이 위에.
  섞는다고 첫 화면이 흐려지면 섞은 값이 없습니다.
- **가져온 절의 클래스명과 속성을 바꾸지 않습니다**(`.dec` · `data-decisions` · `data-correct` 등).
  `doc.js` 가 그 이름으로 찾습니다. 이름을 바꾸면 폼과 퀴즈가 조용히 죽습니다.

## 지우면 안 되는 것

빠져도 **화면은 멀쩡해 보여서** 사고를 눈치채기 어려운 것들입니다.

- `<script type="module" src="doc.js"></script>` — 없으면 목차·테마 토글·메모지·복사
  버튼·퀴즈가 **한꺼번에** 사라집니다. 개별 기능이 아니라 기능군이 죽습니다.
- `og:title` / `og:description` — 없으면 링크를 채팅에 붙였을 때 미리보기 없는 맨 URL이 됩니다.
- `decision.html` 의 `.commit-bar[data-decisions]` — 없으면 독자가 고른 답을 돌려줄 방법이
  사라집니다. 물어만 보고 답할 길이 없는 문서가 이 유형의 대표적 실패입니다.

## 페이지에 직접 CSS 를 쓸 때

페이지 `<style>` 은 특수 레이아웃·SVG·인쇄처럼 `doc.css` 가 못 맡는 것에만 씁니다.

- 색은 **`--doc-*` 토큰**을 쓰고 색을 새로 발명하지 않습니다(다크 모드가 같이 따라옵니다).
- 새 클래스에는 **문서 고유 접두사**를 붙입니다(`.xx-step`). `doc.css` 가 이미 쓰는 이름
  (`.step` `.toc` `.btn` `.pill` `.card` …)을 자손 셀렉터로 부분 재정의하면 레이아웃이
  조용히 깨집니다.
