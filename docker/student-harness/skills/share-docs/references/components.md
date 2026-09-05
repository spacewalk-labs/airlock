# 디자인 토큰과 공유 컴포넌트

이 문서는 `assets/doc.css`와 `assets/doc.js`를 사용하는 페이지의
계약입니다. 새 페이지는 기존 HTML을 복사하지 말고, 먼저 실제 공유 자산의
셀렉터를 확인합니다.

## 목차

- [디자인 토큰](#디자인-토큰)
- [공유 컴포넌트 계약](#공유-컴포넌트-계약)
- [다이어그램과 코드](#다이어그램과-코드)
- [글자 크기 컨트롤 (opt-in)](#글자-크기-컨트롤-opt-in)
- [목차 기본 접힘 (opt-in)](#목차-기본-접힘-opt-in)
- [퀴즈](#퀴즈)
- [렌더 검증](#렌더-검증)

```bash
rg -n '\.stat-band|\.landing-card|\.essay-tabs|\.doc-quiz' \
  ~/.claude/skills/share-docs/assets/doc.css
```

## 디자인 토큰

페이지 CSS에서는 raw 색이나 자체 팔레트 대신 `--doc-*` 토큰을 사용합니다. 토큰은
`doc.css` 안에 있으므로 옛 토큰 CSS 를 따로 부르지 않습니다
(`doc-contract-lint` 의 `old-token-css` 가 ERROR 로 잡습니다).
팔레트의 실제 값은 `assets/doc.css` 맨 위 `:root` 가 정본입니다.

| 역할 | 토큰 |
|---|---|
| 배경과 표면 | `--doc-bg`, `--doc-surface`, `--doc-surface-soft`, `--doc-surface-hover` |
| 텍스트 | `--doc-text`, `--doc-muted`, `--doc-subtle` |
| 선 | `--doc-border`, `--doc-border-muted`, `--doc-border-strong` |
| 강조 | `--doc-accent`, `--doc-accent-hover`, `--doc-accent-bg`, `--doc-accent-border` |
| 상태 | `--doc-success*`, `--doc-warning*`, `--doc-danger*` |
| 글꼴 | `--doc-font-sans`, `--doc-font-mono`, `--doc-fs-*`, `--doc-lh-*`, `--doc-fw-*` |
| 간격과 형태 | `--doc-sp-*`, `--doc-r-*`, `--doc-shadow-*` |

정보, 이유, 강조와 정상 상태는 블루 계열을 사용합니다. amber는 주의·보류,
red는 실패·위험에만 사용합니다. 한 화면에서 강한 상태색을 여러 개 장식처럼
쓰지 않습니다.

규율은 다음과 같습니다.

- 페이지 `<style>`과 `style=`에 `#hex`, `rgb()`, `hsl()`을 새로 만들지
  않습니다. 데이터 시각화와 증거용 색은 범례가 있을 때만 예외입니다.
- Tailwind 팔레트, 보라·청록, 옛 teal/green을 들여오지 않습니다.
- 이모지를 nav, 섹션 제목, 칩의 장식으로 사용하지 않습니다.
- 공유 클래스와 같은 이름을 페이지 CSS에서 재정의하지 않습니다. 페이지
  고유 레이아웃은 문서별 prefix를 붙입니다.
- sticky nav와 탭은 한 줄을 유지하고, 넘치면 가로 스크롤합니다.
- 페이지 `<style>`의 허용 범위와 클래스 이름 규칙은
  [`authoring.md`](authoring.md#페이지-style의-클래스-이름)가 정본입니다.

```bash
rg -n '#[0-9a-fA-F]{6}|rgb\(|hsl\(' page.html
rg -n 'slate|#0f172a|#2563eb|#8b5cf6|#0f766e|#446b3b' page.html
```

첫 명령은 근거가 기록된 데이터 시각화 예외만, 둘째 명령은 결과가 없어야
합니다.

## 공유 컴포넌트 계약

| 컴포넌트 | 용도 | 핵심 클래스 |
|---|---|---|
| 문서 메타 | 대상·작성일·SoT, 한 줄 요약 | `.doc-meta`, `.lead`, `.doc-footer` |
| 의미 박스 | 정보·이유·상태 | `.note`, `.why`, `.case`, `.ok`, `.caution`, `.warn` |
| 비교 | 변경 전후 두 칸 | `.before-after` |
| 카드와 수치 | 진입점, 반복 정보, 수치 요약 | `.landing-card`, `.doc-card`, `.stat-band` |
| 상태와 출처 | 상태 badge, 레포 라벨 | `.chip[data-tone]`, `.repo-tag` |
| 상단 통합도 | 페이지 핵심 도식 1회 | `.hero-diagram` |
| 이미지 증거 | 도면·화면·그래프와 설명 | `.fig` |
| 선택형 본문 | essay·RCA pane 전환 | `.essay-tabs`, `.rca-tabs` |
| 추가 참조 | 자주 열지 않는 부록 | `<details><summary>` |
| 사용자 결정 | 입력, 결과 복사 | `.decision-form`, `.commit-bar` |
| 커스텀 목차 | 카탈로그형 정보 구조 | `.doc-layout`, `.toc-rail` |
| 연작 이동 | 여러 장으로 나뉜 문서 | `.doc-series`, `.doc-series-nav` |
| 이해 점검 | 보기 셔플·채점·해설 | `.doc-quiz` |

### Callout과 전후 비교

```html
<div class="note"><span class="label">정보</span> 설명</div>
<div class="why"><span class="label">이유</span> 설명</div>
<div class="case"><span class="label">핵심</span> 설명</div>
<div class="ok"><span class="label">정상</span> 설명</div>
<div class="caution"><span class="label">주의</span> 설명</div>
<div class="warn"><span class="label">실패</span> 설명</div>

<div class="before-after">
  <div class="before"><h4>변경 전</h4><p>...</p></div>
  <div class="after"><h4>변경 후</h4><p>...</p></div>
</div>
```

단순 강조에는 `.case`를 사용하고, amber와 red는 실제 상태에만 씁니다.

### 통계, 카드, 칩

`.stat-band`의 자식은 반드시 `.stat`이고 값은 `<b>`, 라벨은 `<span>`입니다.
`<strong>`만 넣으면 계약 셀렉터가 적용되지 않습니다.

```html
<div class="stat-band">
  <div class="stat"><b>27</b><span>오류</span></div>
  <div class="stat"><b>96%</b><span>통과율</span></div>
</div>

<div class="landing-cards">
  <div class="landing-card" data-jump="pane-summary">
    <div class="card-num">01</div>
    <h4>요약</h4>
    <p>핵심 결과를 먼저 봅니다.</p>
  </div>
</div>

<span class="chip" data-tone="accent">진행 중</span>
<span class="chip" data-tone="warning">확인 필요</span>
<span class="chip" data-tone="danger">실패</span>
<span class="chip" data-tone="muted">보류</span>
<span class="repo-tag">PlanReview</span>
```

상단 통합도는 한 페이지에 한 번만 사용합니다.

```html
<div class="hero-diagram">
  <pre class="mermaid">flowchart LR
    A[입력] --> B[검증] --> C[결과]
  </pre>
</div>
```

`data-jump`는 목적지를 표시하는 마크업일 뿐 공유 JavaScript가 클릭 동작을
주입하지는 않습니다. 카드를 링크로 만들거나 페이지의 탭 스크립트에서
`pane-summary` 이동을 명시적으로 구현합니다.

추가 참조는 별도 카드나 탭 대신 네이티브 `<details>`를 우선합니다.

```html
<details>
  <summary>재현 로그 보기</summary>
  <pre><code>...</code></pre>
</details>
```

### 탭

`.essay-tabs`는 CSS의 `body > .essay-tabs` 셀렉터가 적용되도록 `<body>`의
직접 자식으로 둡니다. 버튼의 `data-target`과 `aria-controls`는 pane `id`와
같아야 하며 활성 pane에만 `data-active`를 둡니다.

```html
<body>
  <nav class="essay-tabs" role="tablist" aria-label="문서 보기">
    <button role="tab" data-target="pane-summary" aria-controls="pane-summary"
            aria-selected="true"><span class="num">1</span>요약</button>
    <button role="tab" data-target="pane-detail" aria-controls="pane-detail"
            aria-selected="false"><span class="num">2</span>상세</button>
  </nav>
  <main class="doc">
    <section class="essay-pane" id="pane-summary" data-active role="tabpanel">...</section>
    <section class="essay-pane" id="pane-detail" role="tabpanel">...</section>
  </main>
</body>
```

🔴 **탭은 공유 `doc.js`가 맡지 않습니다** — 퀴즈·결정폼·목차·테마와 달리 런타임이 없어
페이지 스크립트를 직접 답니다(`aria-selected`와 `data-active`를 함께 갱신). 복사해 쓸 골격은
[`authoring.md`](authoring.md#오류문제-분석-rca-2탭)에 있습니다.

### Figure

```html
<figure class="fig">
  <img src="img/evidence.jpg" alt="증거가 드러나는 이미지 설명">
  <figcaption><strong>제목.</strong> 무엇을 봐야 하는지 설명합니다.</figcaption>
</figure>
```

좁은 이미지는 `.fig-narrow`를 함께 사용합니다. 이미지·오버레이 작성 절차는
[`authoring.md`](authoring.md)를 따릅니다.

### 목차

일반 문서는 별도 마크업 없이 `doc.js`가 `h2`와 `h3`에서 우측 플로팅
목차를 만듭니다. 커스텀 정보 구조가 필요한 카탈로그만 `.toc-rail`을 사용합니다.
이때 rail과 본문을 반드시 `.doc-layout` grid 안에 함께 둡니다.

자동 목차는 `h2`와 `h3` 합계가 3개 이상일 때만 생깁니다. 기존
`.cat-toc`, `.toc-rail`, `.toc`, `#doc-toc`가 있거나 `<body data-no-toc>`이면
자동 주입을 건너뜁니다.

```html
<main class="doc">
  <h1>...</h1>
  <div class="doc-meta">...</div>
  <p class="lead">...</p>
  <div class="doc-layout">
    <nav class="toc-rail" aria-label="문서 목차">...</nav>
    <div class="doc-content">...</div>
  </div>
</main>
```

### 연작 (여러 장으로 나뉜 문서)

한 주제를 여러 파일로 나눴다면 **"지금 몇 장이고 다음이 어디인가"는 장식이 아니라 읽기의
전제**입니다. 없으면 독자는 2장에서 멈춥니다. 그래서 문서 유형과 직교하는 공유 컴포넌트로
둡니다 — `report`든 `runbook`이든 그대로 붙입니다.

```html
<body data-no-toc>            <!-- 자체 사이드 목차가 있을 때만. 없으면 그냥 <body> -->
  <nav class="doc-series" aria-label="챕터">
    <a class="home" href="index.html">📘 {연작 제목}</a>
    <a class="ch" href="01-....html"><span class="n">1</span>{장 제목}</a>
    <a class="ch" href="02-....html" aria-current="page"><span class="n">2</span>{장 제목}</a>
  </nav>
  <main class="doc">
    ...
    <nav class="doc-series-nav">
      <a class="prev" href="01-....html"><span class="dir">← 이전</span><span class="ttl">1장 · {제목}</span></a>
      <a class="next" href="03-....html"><span class="dir">다음 →</span><span class="ttl">3장 · {제목}</span></a>
    </nav>
  </main>
```

- 현재 장은 **`aria-current="page"`** 로 표시합니다. 클래스가 아니라 접근성 속성이 상태의
  정본입니다 — 스크린리더도 같은 사실을 읽습니다.
- prev/next에는 **제목까지** 적습니다. "다음 →"만으로는 갈지 말지 정할 수 없습니다.
- 자체 사이드 목차(`.book-toc` 등)를 쓰는 연작은 `<body data-no-toc>`을 **반드시** 답니다.
  안 달면 공유 플로팅 목차와 겹쳐 둘 다 못 읽습니다(14장짜리 연작에서 실제로 겹친 적이 있습니다).
- **연작은 새 템플릿 유형이 아닙니다.** 주 유형(`report`·`runbook`) 위에 이 두 절을 얹습니다.

`.toc-rail`을 `.doc` 바로 아래에 두면 별도 열이 생기지 않아 본문과 겹칩니다.
1,200px 이상 넓은 화면에서
`toc.getBoundingClientRect().right < content.getBoundingClientRect().left`
인지 확인합니다. 짧은 문서는 본문 상단의 일반 `<nav>`로 충분합니다.

### 사람에게 답을 받는 문서 (decision form)

결정·미결·피드백처럼 **독자가 골라서 돌려줘야** 끝나는 문서에 씁니다.
`doc.js`가 저장·복원·상태문구·Markdown 생성·클립보드 폴백을 전부 맡으므로
**페이지 JavaScript는 0줄**입니다.

```html
<section class="dec" data-decision="tpl-set" data-title="템플릿 유형 세트">
  <h3><span class="tag">01</span> 몇 종을 만드나</h3>
  <p>{맥락 — 왜 정해야 하고 무엇이 걸려 있나}</p>
  <div class="decision-form">
    <h4>선택</h4>
    <label class="opt">
      <input type="radio" name="tpl-set" value="{복사본에 그대로 들어갈 문구}" checked>
      <strong>{선택지}</strong> — {귀결} <span class="rec">권고</span>
    </label>
    <label class="opt">
      <input type="radio" name="tpl-set" value="{...}">
      <strong>{대안}</strong> — {귀결}
    </label>
    <label class="fld">
      <span>메모</span>
      <textarea name="tpl-set-note" placeholder=""></textarea>
    </label>
  </div>
</section>

<div class="commit-bar" data-decisions>
  <button type="button" class="primary" data-act="copy-md">Markdown 복사</button>
  <button type="button" class="secondary" data-act="download-json">JSON</button>
  <button type="button" class="clear" data-act="reset">권고안으로</button>
</div>
```

계약은 다음과 같습니다.

- **`data-decisions`가 스위치입니다.** `.commit-bar`에 이 속성이 있을 때만 런타임이
  붙습니다. 자기 스크립트를 가진 옛 문서와 이중 바인딩을 피하려는 opt-in이므로,
  **새 문서는 항상 붙이고 자체 JS는 쓰지 않습니다.**
- 항목은 `.dec[data-decision="<name>"]`이고, `<name>`이 그대로 radio의 `name`입니다.
  메모는 `<name>-note`입니다. 제목은 `data-title`, 없으면 `h3` 텍스트입니다.
- `value`는 **복사본에 그대로 실릴 문구**입니다. "(a)"·"1번" 같은 표시는 넣지
  않습니다 — 답을 받은 쪽이 그것만 보고 실행할 수 있어야 합니다.
- 권고안에 `checked`와 `<span class="rec">권고</span>`를 함께 답니다. 둘은 같이
  움직입니다(초기화가 `.rec` 기준으로 되돌립니다).
- `.status`·`#md-output`·`#toast`는 없으면 자동 생성됩니다. 직접 두면 그쪽을 씁니다.
- 버튼은 `data-act`로 식별합니다(`copy-md`·`download-json`·`reset`). `id`로 잡던
  옛 방식(`#copy-md`/`#btn-copy`)은 쓰지 않습니다. 라벨에 이모지를 넣지 않습니다.

> **왜 공유 자산인가.** 이 컴포넌트는 CSS만 2026-07-17에 승격되고 JS는 페이지마다
> 다시 쓰였습니다. 그 결과 id·라벨·초기화 문구·클립보드 폴백이 제각각으로 갈렸고,
> **폼을 가졌는데 회신 버튼이 없는 문서**까지 나왔습니다 — 물어만 보고 답을 못 받는
> 문서입니다. 런타임을 공유 계층으로 올려 그 갈래를 없앴습니다.
> (실측 수치는 모집단·제외조건과 함께 `assets/doc.js` 상단 주석이 정본입니다.)

검증은 실제로 눌러 봅니다 — 선택을 바꿔 `.status` 문구가 바뀌는지, `Markdown 복사`가
평문 HTTP(테일넷 내부 링크)에서도 성공 토스트를 내는지, 새로고침 뒤 선택이 남는지.

## 다이어그램과 코드

### Mermaid

흐름도와 시퀀스는 다음처럼 작성합니다.

```html
<pre class="mermaid">
flowchart LR
  A[원본] --> B[검증]
  B --> C[출판]
</pre>
```

렌더 후 본문에 `Syntax error`가 없는지 확인합니다. 한국어 라벨, 괄호,
`①`, 화살표 같은 문자가 파싱을 깨뜨리면 문법을 단순화하고, 계속 불안정하면
순수 ASCII로 바꿉니다.

```js
import { chromium } from 'playwright';
const browser = await chromium.launch();
const page = await (await browser.newContext()).newPage();
await page.goto('http://127.0.0.1:8000/page.html', {waitUntil: 'networkidle'});
await page.waitForTimeout(1500);
const ok = await page.$eval('body', el => !el.innerText.includes('Syntax error'));
console.log(ok ? 'OK' : 'FAILED');
await browser.close();
```

### ASCII

박스는 `+`, `-`, `|`만으로 그립니다. 박스그리기 문자 `┌─│┘`, 가운데점,
이모지는 폰트 fallback에서 폭이 달라져 정렬되지 않습니다. 한글과 일반 화살표는
표시폭 2칸으로 셉니다.

```python
import unicodedata

def display_width(text):
    return sum(
        2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        for char in text
    )

def pad_right(text, width):
    return text + " " * (width - display_width(text))
```

손으로 칸 수를 맞추거나 `len()`으로 검증하지 않습니다. 세로선이 끊겨
보이면 문서별 prefix를 붙인 선택자에서 해당 도식의 `line-height`만
조정할 수 있습니다.

### `<pre>` 안 리터럴 태그

코드 예시의 `<table>`, `<div>`, `<a:br>`는 반드시 `&lt;table&gt;`처럼
이스케이프합니다. 브라우저는 `<pre>` 안에서도 이들을 실제 태그로 파싱합니다.

```html
<pre><code>&lt;table&gt;
  &lt;tr&gt;&lt;td&gt;예시&lt;/td&gt;&lt;/tr&gt;
&lt;/table&gt;</code></pre>
```

태그 수나 글자 수 검사만으로는 누출을 찾지 못합니다. 렌더된 DOM도 검사합니다.

```js
pane.querySelectorAll('pre table, pre thead').length // 0
[...pane.querySelectorAll('h2,p')]
  .filter(element => /mono/i.test(getComputedStyle(element).fontFamily)).length // 0
```

## 글자 크기 컨트롤 (opt-in)

긴 문서를 화면에서 오래 읽는 페이지는 `<head>`에 다음 한 줄을 선언합니다.
그러면 상단바 테마 버튼 왼쪽에 `A−` `100%` `A+`가 생깁니다.

```html
<meta name="doc-fontsize" content="on">
```

- **opt-in인 이유**: `doc.js`는 모든 발행본이 공유하므로, 켜는 판단은
  문서 쪽에 둡니다. 선언하지 않은 문서는 지금까지와 완전히 같습니다
  (`--doc-fs-scale` 미정의 → fallback 1).
- 배율은 0.85~1.6, 0.1 단위이고 `100%`를 누르면 기본으로 돌아옵니다.
- 저장은 `localStorage`의 `doc-fontscale` 하나입니다 — **그 브라우저에만**
  남고(디바이스별), 문서 사이에는 공통입니다. 테마 토글과 같은 결입니다.
- 페이지에 별도 스크립트·스타일을 만들지 않습니다. 배율은 `html`과 `body`
  양쪽에 걸려 `rem` 기반 제목과 px 기반 본문이 함께 커집니다.

## 목차 기본 접힘 (opt-in)

플로팅 목차는 본문 위에 떠 있어, 글자 크기를 키우면 본문 오른쪽을 가립니다.
화면에서 길게 읽는 문서는 접힌 채로 시작하게 선언합니다.

```html
<meta name="doc-toc-default" content="collapsed">
```

- 선언하지 않은 문서는 지금까지와 같이 펼친 상태로 시작합니다.
- 사용자가 한 번이라도 접거나 펴면 **그 선택이 이깁니다**
  (`localStorage`의 `doc-toc-collapsed`가 있으면 meta보다 우선).

## 퀴즈

상세 기술, 원리 설명, `explain-diff`에는 이해 점검을 붙입니다.
페이지는 마크업만 제공하며 보기 셔플, 키보드 선택, 채점, 해설 표시,
`aria-live` 점수는 `doc.js`가 처리합니다.

```html
<section class="doc-quiz">
  <h2 class="doc-quiz-title">이해 점검</h2>
  <p class="doc-quiz-sub">핵심 메커니즘을 확인합니다.</p>
  <ol class="doc-quiz-list">
    <li class="doc-q">
      <p class="doc-q-stem">공유 컴포넌트를 바꾸어야 할 때 수정할 곳은?</p>
      <ul class="doc-q-opts">
        <li>각 페이지의 inline style</li>
        <li data-correct>공유 doc.css</li>
        <li>브라우저 개발자 도구</li>
      </ul>
      <p class="doc-q-explain">
        여러 페이지가 재사용하는 계약은 공유 자산에서 한 번 수정합니다.
      </p>
    </li>
  </ol>
</section>
```

각 문항은 `.doc-q`, 질문은 `.doc-q-stem`, 보기는 `.doc-q-opts` 바로 아래
`<li>`, 정답은 정확히 하나의 `data-correct`, 해설은 `.doc-q-explain`으로
작성합니다. 페이지별 채점 스크립트나 고정 보기 번호를 추가하지 않습니다.

### 오답(distractor)에 정답만큼 공을 들입니다

보기 셔플은 **위치** 단서만 없애고 **길이** 단서는 그대로 남깁니다. 실측
2026-08-01, learning 레포의 발행본 20건을 재보니 문항의 거의 전부에서
정답이 최장 보기였고 흔히 오답의 2배였습니다 — 내용을 몰라도 "가장 긴 것"을
고르면 맞는, 이해 점검이 아니라 길이 맞히기였습니다.

- **길이와 구체성을 맞춥니다.** 오답도 정답과 같은 어절 수·같은 문형으로
  씁니다. 정답에만 조건절이나 부연을 달지 않습니다. 눈금: 정답이 최장 오답의
  1.5배를 넘지 않고, 정답이 최장인 문항이 과반이 되지 않게 합니다.
- **오답은 그럴듯한 오해에서 만듭니다** — ① 문서가 반박한 통념, ② 인접 개념
  혼동(비슷하지만 다른 층·다른 단위), ③ 반쯤 맞지만 조건이 틀린 서술,
  ④ 원인과 결과를 뒤집은 서술. 넷 다 "그렇게 생각할 만한" 것이어야 합니다.
- **대충 만든 흔적 = 금지 양식**: 명백한 헛소리·농담 보기, "모두 해당"/"없음",
  정답에만 문서의 고유 용어를 쓰는 패턴, 오답에만 `항상`·`절대`를 붙이는 패턴,
  어순만 바꾼 중복 보기.
- **자기점검**: 문항을 다 쓴 뒤 **질문을 가리고 보기만** 봅니다. 어느 것이
  정답인지 보이면 다시 씁니다.

## 렌더 검증

- 좁은 화면과 넓은 화면에서 sticky 행이 두 줄로 쌓이거나 본문을 가리지
  않는지 확인합니다.
- 탭의 `aria-selected`, pane의 `data-active`, `aria-controls`가 일치하는지
  확인합니다.
- Mermaid 오류, `<pre>` DOM 누출, 목차와 본문 overlap이 없는지 확인합니다.
- 퀴즈는 보기 순서가 바뀌어도 정답·오답·해설·점수가 올바른지 키보드와
  포인터로 각각 확인합니다.
