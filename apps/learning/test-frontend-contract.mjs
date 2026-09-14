// apps/learning/test-frontend-contract.mjs — learning.html 을 브라우저 없이 잴 수 있는 것.
//
// 두 가지를 본다. 하나는 **없는 상태 키를 읽는 코드**, 다른 하나는 진행 중 적재를 문서
// 행으로 접는 결정이다.
//
// 첫 번째가 왜 필요한지는 실측이 답한다. `categoryDefinitions()` 가 `state.data.items` 를
// 읽었는데 이 앱의 상태에는 `data` 라는 키가 없다(`state.items` 다). JavaScript 는 그것을
// 오류로 만들지 않는다 — `undefined && …` 는 조용히 빈 배열이 되고, 그래서 **카테고리 칩
// 줄이 통째로 그려지지 않았다.** "카테고리는 이제 폴더 이름 그대로" 라고 적어 머지한
// 기능이 화면에 한 글자도 나오지 않은 채로 살아 있었고, 어떤 스위트도 그것을 몰랐다.
// 같은 오타가 이 단계의 큐 접기 코드에도 그대로 들어갔다 — 한 번 더 조용히.
//

// 20분짜리 적재의 4분째에 문서가 폴더에 들어오면 목록은 곧바로 그것을 보여 준다(목록은
// 폴더다). 그때 큐 카드도 그대로 떠 있으면 같은 것이 화면 두 자리에 있게 되고, 사용자는
// 자기가 기다리는 것이 **이미 도착했다**는 사실을 모른다. 카드가 그 행의 배지로 접히는
// 판정을 여기서 잰다.
//
// 화면을 못 여는 CI 에서 잴 수 있는 것이 이만큼이다. 행 높이와 배지가 앉는 자리는
// 브라우저로만 잡힌다 — #207 에서 세 번째 그리드 자식이 다음 줄로 떨어져 행이 52 →
// 96px 가 됐고, 그 종류는 어떤 노드 테스트도 보지 못한다.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const htmlPath = new URL('./frontend/learning.html', import.meta.url);
const html = fs.readFileSync(htmlPath, 'utf8');
const backendPath = new URL('./backend/airlock-learning.py', import.meta.url);
const backend = fs.readFileSync(backendPath, 'utf8');
const appManifestPath = new URL('./airlock-app.toml', import.meta.url);
const appManifest = fs.readFileSync(appManifestPath, 'utf8');
const skillPath = new URL('./skill/SKILL.md', import.meta.url);
const skill = fs.readFileSync(skillPath, 'utf8');
const installPath = new URL('./install.sh', import.meta.url);
const installScript = fs.readFileSync(installPath, 'utf8');
const timestampModulePath = new URL('./backend/timestamp_links.py', import.meta.url);
const sharedDocCss = fs.readFileSync(
  new URL('../../docker/student-harness/skills/share-docs/assets/doc.css', import.meta.url), 'utf8');
const sharedDocJs = fs.readFileSync(
  new URL('../../docker/student-harness/skills/share-docs/assets/doc.js', import.meta.url), 'utf8');

const newContractNames = [];
function contract(name, check) {
  check();
  newContractNames.push(name);
}

function pythonFunction(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `${signature} not found`);
  const indent = /(^|\n)([ ]*)[^\n]*$/.exec(source.slice(0, start + signature.length))[2];
  const tail = source.slice(start + signature.length);
  const next = tail.search(new RegExp(`\\n${indent}(?:def |class )`));
  return source.slice(start, next < 0 ? source.length : start + signature.length + next);
}

function javascriptFunction(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `${signature} not found`);
  const tail = source.slice(start + signature.length);
  const next = tail.indexOf('\n  function ');
  return source.slice(start, next < 0 ? source.length : start + signature.length + next);
}

// --- 1. 상태 키. 선언되지 않은 것을 읽으면 그 기능은 조용히 사라진다 ---
const stateStart = html.indexOf('\n  var state = {');
assert.ok(stateStart >= 0, 'state initialiser not found');
const stateEnd = html.indexOf('\n  };', stateStart);
assert.ok(stateEnd > stateStart, 'state initialiser end not found');
const stateBlock = html.slice(stateStart, stateEnd);
const declared = new Set(
  [...stateBlock.matchAll(/^ {4}([A-Za-z_$][\w$]*):/gm)].map((m) => m[1]),
);
assert.ok(declared.size > 10, `state initialiser parsed oddly: ${declared.size} keys`);
assert.ok(declared.has('items') && declared.has('ingestRequests'), 'known keys missing');

// 🔴 코드만 훑는다. 주석·문자열·정규식 리터럴 안의 `state.x` 는 코드가 아니고, 거기서
// 실패하는 게이트는 "주석을 고쳐서 통과시키는" 우회를 부른다(적대검증이 세 형태를 짚었다).
// 완전한 렉서를 쓰지는 않는다 — 이 파일 하나를 위해 파서를 들이는 값이 안 나온다.
function stripNonCode(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')          // 블록 주석
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1 ')        // 줄 주석 (URL 의 `://` 는 남긴다)
    .replace(/'(?:\\.|[^'\\\n])*'/g, "''")        // 작은따옴표 문자열
    .replace(/"(?:\\.|[^"\\\n])*"/g, '""');       // 큰따옴표 문자열
}

// 앞에 점이 있으면 우리 `state` 가 아니다 — `window.history.state.learningView` 처럼.
// `?.` 도 읽는다.
const STATE_READ_RE = /(?<![.\w$])state\??\.([A-Za-z_$][\w$]*)/g;
const code = stripNonCode(html);
const read = [...code.matchAll(STATE_READ_RE)].map((m) => m[1]);
const unknown = [...new Set(read.filter((name) => !declared.has(name)))].sort();
assert.deepEqual(
  unknown, [],
  `learning.html reads state keys that the initialiser does not declare: ${unknown.join(', ')}`
  + ' — JavaScript will not raise on these, the feature just never renders',
);

// 양성 대조군: 이 검사가 실제로 잡는가. 없으면 위의 "없음" 은 측정이 아니다.
function undeclaredIn(source) {
  return [...stripNonCode(source).matchAll(new RegExp(STATE_READ_RE.source, 'g'))]
    .map((m) => m[1])
    .filter((name) => !declared.has(name));
}

// 양성 대조군: 코드에 심으면 잡힌다.
assert.ok(
  undeclaredIn('state.thisKeyDoesNotExist;').length === 1,
  'the undeclared-state-key scan does not fire on a planted reference',
);
assert.ok(undeclaredIn('state?.alsoUndeclared;').length === 1, 'optional chaining is missed');
// 음성 대조군: 코드가 아닌 자리에 있으면 잡지 않는다. 여기서 잡으면 사람이 주석을
// 고쳐서 게이트를 통과시키게 되고, 그 순간 게이트는 잡음이 된다.
assert.equal(undeclaredIn('// state.inLineComment\n').length, 0, 'line comment');
assert.equal(undeclaredIn('/* state.inBlockComment */').length, 0, 'block comment');
assert.equal(undeclaredIn('var s = "state.inString";').length, 0, 'double-quoted string');
assert.equal(undeclaredIn("var s = 'state.inString';").length, 0, 'single-quoted string');
assert.equal(undeclaredIn('window.history.state.learningView;').length, 0, 'history.state');

// 🔴 못 잡는 것을 적어 둔다. 이것은 렉서가 아니라 본문 검색이라, 아래 형태는 지나간다.
// 게이트가 무엇을 안 보는지 모르면 "통과했으니 없다" 로 읽게 된다.
//   · state["bracketAccess"]   · const { destructured } = state
//   · 템플릿 리터럴 안의 `${state.x}` 는 잡지만, 백틱 문자열 안의 예시 텍스트도 잡는다
//   · 런타임에 키를 만드는 쓰기(`state.newKey = 1`)도 미선언으로 잡는다 — 의도한 것이다.
//     `searchTimer` 가 정확히 그 모양으로 선언 없이 살아 있었다.

// --- 2. 적재 버튼은 확인 계획 없이 곧바로 실행 요청을 보낸다 ---
contract('ingest-submit-without-confirmation', () => {
  const composer = javascriptFunction(html, '  function makeIngestComposer(');
  const run = javascriptFunction(html, '  function runIngest(');
  assert.match(composer, /addEventListener\("click", runIngest\)/,
    '적재 버튼이 즉시 실행 함수로 이어져야 한다');
  assert.match(run, /apiUrl\("ingest\/run"\)/);
  assert.match(run, /body: JSON\.stringify\(\{ url: url \}\)/);
  assert.match(run, /\.catch\(function \(error\)[\s\S]*showToast\([\s\S]*true\)/,
    '서버의 접수 거절은 확인창 대신 오류 토스트로 알려야 한다');
  assert.doesNotMatch(html, /apiUrl\("ingest\/plan"\)|makeIngestSheet|ingestPlan/,
    '계획 확인 시트 경로가 프론트엔드에 남아 있다');
});

// --- 3. 큐 등록 직후 되돌리기는 같은 취소 경로를 쓰고, 시작되면 물러난다 ---
contract('ingest-undo-cancels-queued-run', () => {
  const run = javascriptFunction(html, '  function runIngest(');
  const show = javascriptFunction(html, '  function showIngestUndo(');
  const hideStarted = javascriptFunction(html, '  function hideStartedIngestUndo(');
  const snackbar = javascriptFunction(html, '  function makeIngestUndo(');
  const cancel = javascriptFunction(html, '  function cancelIngest(');
  const row = javascriptFunction(html, '  function makeIngestRow(');
  assert.match(html, /var INGEST_UNDO_MS = 8000;/, '되돌리기 시간은 약 8초여야 한다');
  assert.match(run, /showIngestUndo\(payload\)/);
  assert.match(show, /state\.ingestUndo = \{ id: id \}/);
  assert.match(show, /window\.setTimeout\([\s\S]*INGEST_UNDO_MS\)/);
  assert.match(hideStarted, /current\.status !== "queued"[\s\S]*clearIngestUndo\(\)/,
    'running이 되면 되돌리기 스낵바를 치워야 한다');
  assert.match(snackbar, /"되돌리기"/);
  assert.match(snackbar, /clearIngestUndo\(\);\s*cancelIngest\(id\);/,
    '되돌리기 버튼이 기존 취소 함수를 호출해야 한다');
  assert.match(cancel, /apiUrl\("ingest\/" \+ encodeURIComponent\(id\) \+ "\/cancel"\)/);
  assert.match(row, /status === "running"[\s\S]*"중지"/,
    '시작된 적재는 카드의 중지 버튼으로 이어져야 한다');
});

// --- 4. 진행 중 적재를 문서 행으로 접는 결정 ---
const start = html.indexOf('// TESTABLE:INGEST_BADGE_START');
const end = html.indexOf('// TESTABLE:INGEST_BADGE_END');
assert.ok(start >= 0 && end > start, 'ingest badge markers missing');

const source = html.slice(start, end)
  + '\nthis.api = { ingestStatusIsActive, ingestDocumentIndex, ingestCardVisible,'
  + ' ingestBadgeLabel, ingestBadgeLong };';
const context = {};
vm.runInNewContext(source, context);
const api = context.api;

// --- 무엇이 "진행 중" 인가 ---
for (const status of ['queued', 'running', 'cancelling']) {
  assert.equal(api.ingestStatusIsActive(status), true, status);
}
for (const status of ['done', 'failed', 'cancelled', '', null, undefined]) {
  assert.equal(api.ingestStatusIsActive(status), false, String(status));
}

// --- 색인: 진행 중이면서 이미 문서를 남긴 것만 ---
const requests = [
  { id: 1, status: 'running', document: 'ai/attention.md' },
  { id: 2, status: 'running' },                              // 아직 저장 전
  { id: 3, status: 'done', document: 'ai/older.md' },        // 끝났다 — 배지 아님
  { id: 4, status: 'queued', document: 'ml/next.md' },
  null,
];
const index = api.ingestDocumentIndex(requests);
assert.deepEqual(Object.keys(index).sort(), ['ai/attention.md', 'ml/next.md']);
assert.equal(index['ai/attention.md'].id, 1);
// vm 컨텍스트가 만든 객체는 프로토타입이 다른 렐름의 것이라 deepEqual 로는 못 맞댄다.
assert.equal(Object.keys(api.ingestDocumentIndex(null)).length, 0);
assert.equal(Object.keys(api.ingestDocumentIndex(undefined)).length, 0);

// --- 카드를 그리나 ---
// 🔴 **문서가 도착해도 카드는 남는다.** 한 판은 접었다가 적대검증에서 뒤집혔다: 그 카드가
//    그 적재의 중지 버튼과 로그 버튼이 있는 유일한 자리이고, 접으면 4분째부터 20분째까지
//    취소도 진단도 안 되는 구간이 된다. 그리고 접는 판정을 전체 목록으로 하는데 화면은
//    거른 목록을 그리므로, 검색어 하나에 행과 카드가 **둘 다** 사라졌다.
assert.equal(
  api.ingestCardVisible({ status: 'running', document: 'ai/attention.md' }), true);
assert.equal(api.ingestCardVisible({ status: 'running' }), true);
assert.equal(api.ingestCardVisible({ status: 'queued' }), true);
assert.equal(api.ingestCardVisible({ status: 'cancelling' }), true);

// 실패한 적재도 카드로 남는다 — 배지는 진행 중일 때만 붙으므로, 접으면 실패가 안 보인다.
assert.equal(
  api.ingestCardVisible({ status: 'failed', document: 'ai/attention.md' }), true);

// 끝난 적재는 애초에 큐에 없다.
assert.equal(
  api.ingestCardVisible({ status: 'done', document: 'ai/attention.md' }), false);
assert.equal(api.ingestCardVisible(null), false);

// --- 배지 문구 ---
// 🔴 데스크톱의 날짜 칸은 90px 이고 ellipsis 다. 경과까지 넣으면 124~133px 이 되어
//    **하필 경과가 잘린다** — 유일하게 변하는 부분이라 "돌고 있다" 를 보여 주는 것이
//    그것인데(적대검증 실측). 짧은 쪽이 칸에 들어가고, 긴 쪽은 자리가 넉넉한 모바일 메타
//    줄과 적재 카드가 보여 준다.
assert.equal(api.ingestBadgeLabel(), '다듬는 중');
assert.ok(api.ingestBadgeLabel().length <= 6, '날짜 칸에 들어갈 길이여야 한다');

// `ingestElapsed` 는 "경과 4분" 을 준다. 긴 쪽에서는 "다듬는 중 · 경과 4분" 이 되어
// 같은 말을 두 번 하게 되므로 접두어를 걷는다.
assert.equal(api.ingestBadgeLong('경과 4분'), '다듬는 중 · 4분');
assert.equal(api.ingestBadgeLong('경과 12초'), '다듬는 중 · 12초');
assert.equal(api.ingestBadgeLong('경과 정보 없음'), '다듬는 중 · 정보 없음');
assert.equal(api.ingestBadgeLong(''), '다듬는 중');
assert.equal(api.ingestBadgeLong(null), '다듬는 중');
// 단계 이름은 화면에 나오지 않는다 — `document_saved` 는 우리 말이다.
assert.ok(!api.ingestBadgeLong('경과 4분').includes('document_saved'));

// --- 3. 앱 안 읽기 응답에만 씌우는 문서 셸 ---
contract('reader-shell-injection-boundary', () => {
  const libraryDoc = pythonFunction(backend, '    def _library_doc(');
  const publishedDoc = pythonFunction(backend, '    def _published_doc(');
  assert.match(libraryDoc, /inject_reader_shell\(body, reader_context\(relative\)\)/,
    '/read 응답이 reader shell을 통과하지 않는다');
  assert.doesNotMatch(publishedDoc, /inject_reader_shell|LEARNING_READER_SHELL/,
    '/doc 미러에 reader shell이 섞였다');
  assert.match(backend, /if path\.startswith\("\/read\/"\):[\s\S]*?_library_doc/);
  assert.match(backend, /<!-- LEARNING_READER_SHELL -->/);

  for (const [action, icon, label] of [
    ['back', '←', '목록'],
    ['copy-link', '🔗', '링크 복사'],
    ['copy-markdown', '📋', '내용 복사'],
    ['font-down', '−', '글자 작게'],
    ['font-up', '＋', '글자 크게'],
    ['theme', '☾', '테마'],
    ['star', '☆', '별표'],
    ['more', '⋯', '더보기'],
  ]) {
    const escapedAction = action.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const button = new RegExp(
      `<button[^>]+data-reader-action="${escapedAction}"[^>]+title="${escapedLabel}"`
      + `[^>]+aria-label="${escapedLabel}"[^>]*>${icon}</button>`,
    );
    assert.match(backend, button, `${action} 도구가 아이콘과 접근 가능한 이름을 함께 가져야 한다`);
  }
  assert.match(backend, /learning-reader-transcript-note/);
  assert.match(backend, /자동 자막 생성이 기반입니다\. 단어나 용어가 흔들릴 수 있습니다\./);
  assert.match(backend, /querySelector\("blockquote"\)[\s\S]*?자동\\s\*자막[\s\S]*?q\.hidden=true/);
});

// --- 4. 원본 Markdown 본문 복사와 평문 HTTP 폴백 ---
contract('reader-markdown-copy', () => {
  const markdownBody = pythonFunction(backend, 'def markdown_body(');
  const markdownDoc = pythonFunction(backend, '    def _markdown_doc(');
  assert.match(markdownBody, /SAVE\.frontmatter_bounds\(blob\)/,
    '프론트매터 경계는 저장 헬퍼와 같아야 한다');
  assert.match(markdownBody, /lines\[end \+ 1:\]/,
    '닫는 프론트매터 울타리 다음부터 반환해야 한다');
  assert.match(markdownDoc, /safe_relative\(relative/);
  assert.match(markdownDoc, /repo_path\(paths\["repo"\], relative/);
  assert.match(markdownDoc, /text\/markdown; charset=utf-8/);
  assert.match(backend, /\/api\/markdown\//);
  assert.match(backend, /data-reader-action="copy-markdown"/);
  assert.match(backend, /fetch\(root\(\)\+"api\/markdown\/"\+c\.markdownPath\)/);
  assert.match(backend, /copyText\(await r\.text\(\)\)/);
  assert.match(backend, /navigator\.clipboard[\s\S]*?document\.execCommand\("copy"\)/,
    'navigator.clipboard가 없는 HTTP 경로에 execCommand 폴백이 필요하다');
  assert.match(backend, /toast\("내용을 복사했습니다"\)/,
    '내용 복사 성공은 토스트로 알려야 한다');
  assert.match(backend, /toast\("링크를 복사했습니다"\)/,
    '링크 복사 성공은 토스트로 알려야 한다');
});

// --- 5. 글자 크기와 테마 저장 계약 ---
contract('reader-preferences-persistence', () => {
  assert.match(backend, /F=\[1,1\.1,1\.25,1\.4,1\.6\]/,
    '글자 크기는 합의한 다섯 단계여야 한다 — 공용 배율(`--doc-fs-scale`)과 같은 단위(배수)로 센다');
  assert.match(backend, /setProperty\("--doc-fs-scale"/,
    '글자 크기는 이 리더만의 변수가 아니라 공용 문서 CSS 의 배율 훅을 돌려야 한다');
  assert.match(backend, /T=\["auto","light","dark"\]/,
    '테마 어휘는 공용 문서 자산의 것이어야 한다 — 리더가 자기 어휘를 따로 두지 않는다');
  assert.match(backend, /setAttribute\("data-theme",theme\)/,
    '테마 적용은 공용 규약인 `data-theme` 여야 한다');
  assert.doesNotMatch(backend, /data-learning-reader-theme=dark/,
    '리더가 들고 있던 자체 다크 팔레트는 남아 있으면 안 된다 — 테마 주인은 공용 자산 하나다');
  assert.match(backend, /FK="doc-fontscale"/, '배율 저장 키는 공용 문서 뷰어와 같아야 한다');
  assert.match(backend, /TK="doc-theme"/, '테마 저장 키는 공용 문서 뷰어와 같아야 한다');
  assert.match(backend, /localStorage\.getItem\(k\)/);
  assert.match(backend, /localStorage\.setItem\(k,v\)/);
  assert.match(backend, /learning-reader-font-value[^>]+title="글자 크기"[^>]+aria-label="글자 크기">100%/);
});

// --- 6. 나만 / 회사 / 인터넷 공유 시트 ---
contract('reader-share-levels', () => {
  for (const [value, label] of [['private', '나만'], ['company', '회사'], ['internet', '인터넷']]) {
    assert.match(backend, new RegExp(`data-share-level="${value}"[^>]*>${label}</button>`));
  }
  assert.match(backend, /root\(\)\+"api\/publish"/,
    '회사 공유는 Learning publish_path 라우트를 재사용해야 한다');
  assert.match(backend, /root\(\)\+"api\/unpublish"/);
  assert.match(backend, /"\/publish\/api\/publish-public"/);
  assert.match(backend, /"\/publish\/api\/public-set-expiry"/);
  assert.match(backend, /"\/publish\/api\/public-revoke"/);
  assert.match(backend, /ttl_hours:720/);
  assert.match(backend, /mode:gated\?"gated":"open"/);
  assert.match(backend, /id="learning-reader-password-enabled" type="checkbox"/,
    '비밀번호는 체크되지 않은 상태가 기본이어야 한다');
  assert.match(backend, /data-share-publish>인터넷 공유 시작<\/button>/);
  assert.match(backend, /if\(v==="internet"\)return level\(v\)/,
    '인터넷 세그먼트는 옵션을 먼저 보여 주고 즉시 공개하면 안 된다');
  assert.match(backend, /querySelector\("\[data-share-publish\]"\)\.onclick=publishInternet/,
    '비밀번호를 고른 뒤 실행할 명시적인 공개 버튼이 필요하다');
  assert.match(backend, /root\(\)\+"api\/public-share"/,
    '공개 URL과 slug는 다른 브라우저에서도 회수할 수 있게 서버에 남겨야 한다');
  assert.match(backend, /def read_public_shares\(/);
  assert.match(backend, /if path == "\/api\/public-share":[\s\S]*?set_public_share/);
  assert.match(backend, /public-shares\.json/);
  assert.match(backend, /"publicShare": public_share/);
  assert.match(backend, /링크를 회수해도 이미 받은 사람의 사본은 남습니다/);
  assert.match(backend, /learning-reader-share-url/);
  assert.match(backend, /data-share-copy/);
});

// --- 7. 목록에는 공유 액션이 없고 상태만 남는다 ---
contract('list-share-action-removed', () => {
  assert.ok(!html.includes('data-share-path'), '목록 행에 공유 액션 data attribute가 남아 있다');
  assert.ok(!html.includes('share-button'), '목록 행의 공유 버튼 클래스가 남아 있다');
  assert.match(html, /if \(published\) copy\.appendChild\(el\("span", "shared-badge", "공유 중"\)\)/);
  const docHref = html.slice(html.indexOf('  function docHref('), html.indexOf('  function publishCandidates('));
  assert.ok(docHref.indexOf('return "read/"') < docHref.indexOf('return "doc/"'),
    '앱 안 문서는 발행 여부와 무관하게 /read를 우선해야 한다');
});

// --- 8. 목록과 읽기 화면은 한 테마 선택을 공유한다 ---
contract('list-theme-shares-reader-key', () => {
  assert.match(html, /href="\/assets\/airlock-tokens\.css"/,
    '목록은 디자인 토큰 정본을 직접 읽어야 한다');
  for (const [alias, token] of [
    ['ink', 'ink'], ['ink2', 'body'], ['ink3', 'mute'], ['bg', 'canvas'],
    ['sf', 'surface-1'], ['sep', 'hairline'], ['fill', 'surface-2'],
    ['tint', 'primary'], ['on-tint', 'on-primary'], ['yellow', 'warning'], ['red', 'danger'],
  ]) {
    assert.match(html, new RegExp(`--${alias}: var\\(--airlock-${token}\\)`));
  }
  assert.match(html, /var THEME_STORAGE_KEY = "learning-reader-theme"/);
  // 앱 셸은 아직 자기 키를 읽는다(허브 테마 정본은 별도 카드). 리더는 공용 키를 쓰면서
  // 이 키에 미러해, 문서에서 바꾼 테마가 목록에도 반영되는 동작을 잃지 않는다.
  assert.match(backend, /AK="learning-reader-theme"/);
  assert.match(backend, /put\(AK,LABEL\[theme\]\)/);
  // 반대 방향도 같은 짝이어야 한다 — 목록에서 고른 테마가 문서에 가지 않으면 반쪽이다.
  assert.match(html, /var DOC_THEME_KEY = "doc-theme"/);
  assert.match(html, /localStorage\.setItem\(DOC_THEME_KEY, theme\.toLowerCase\(\)\)/);
  assert.match(html, /var THEMES = \["Auto", "Light", "Dark"\]/);
  for (const theme of ['Auto', 'Light', 'Dark']) {
    assert.match(html, new RegExp(`el\\("button", "theme-button", theme\\)`));
    assert.ok(html.includes(`"${theme}"`));
  }
  assert.match(html, /theme === "Auto" \? "system" : theme\.toLowerCase\(\)/);
  assert.ok(!/#0f766e/i.test(html), '옛 청록 tint가 남아 있다');
});

// --- 9. 제품 이름은 Learning 하나다 ---
contract('learning-name-only', () => {
  const oldTitle = ['Learning', 'Library'].join(' ');
  const oldSlug = ['learning', 'manager'].join('-');
  assert.match(html, /<title>Learning<\/title>/);
  assert.match(html, /state\.archiveView \? "보관함" : "Learning"/);
  assert.ok(!html.includes(oldTitle));
  assert.ok(!backend.includes(oldSlug), '백엔드의 제품 표기가 아직 옛 이름이다');
  const migrationMentions = [...appManifest.matchAll(new RegExp(oldSlug, 'g'))];
  assert.equal(migrationMentions.length, 1,
    '이식 경위를 설명하는 airlock-app.toml 주석 하나만 옛 이름을 보존해야 한다');
  assert.ok(appManifest.includes(`${oldSlug} (docs/design/learning-app-redesign.md)`));
});

// --- 10. 실패 카드는 기계 상태 대신 닫힌 실패 코드를 사람 말로 번역한다 ---
contract('ingest-failure-card-human', () => {
  const start = html.indexOf('// TESTABLE:INGEST_FAILURE_START');
  const end = html.indexOf('// TESTABLE:INGEST_FAILURE_END');
  assert.ok(start >= 0 && end > start, 'ingest failure markers missing');
  const failureContext = {};
  vm.runInNewContext(
    html.slice(start, end)
      + '\nthis.api = { INGEST_FAILURE_MESSAGES, ingestFailureMessage, ingestFailureTimeline };',
    failureContext,
  );
  const failureApi = failureContext.api;
  const codes = [
    'tool-missing', 'rate-limited', 'video-unavailable', 'metadata-invalid',
    'no-subs', 'subtitle-unreadable', 'transcript-write-failed',
  ];
  assert.deepEqual([...Object.keys(failureApi.INGEST_FAILURE_MESSAGES)].sort(), [...codes].sort());
  assert.equal(failureApi.ingestFailureMessage({ reason: 'rate-limited' }),
    '유튜브가 잠시 요청을 막았습니다. 자막이 없어서가 아닙니다.');
  assert.equal(failureApi.ingestFailureMessage({ reason: 'no-subs' }),
    '이 영상은 자막이 없어 적재할 수 없습니다.');
  assert.doesNotMatch(
    failureApi.ingestFailureMessage({ reason: 'no-completion-marker', error: 'CLI가 exit 0으로 끝났습니다' }),
    /exit\s+0/i,
  );
  for (const reason of codes) {
    const lines = [...failureApi.ingestFailureTimeline({ reason })];
    assert.ok(lines.length >= 2 && lines.length <= 3, `${reason}: 단계가 2~3줄이어야 한다`);
    assert.match(lines.at(-1), /실패$/);
  }

  const rowRenderer = javascriptFunction(html, '  function makeIngestRow(');
  assert.match(rowRenderer, /ingestFailureMessage\(entry\)/);
  assert.match(rowRenderer, /ingestFailureTimeline\(entry\)/);
  assert.match(rowRenderer, /"다시 하기"/);
  assert.match(rowRenderer, /el\("details", "ingest-details"\)/);
  assert.match(rowRenderer, /el\("summary", "", "자세히"\)/);
  assert.match(rowRenderer, /"원본 로그"/);
  assert.match(rowRenderer, /"✕"/);
  assert.match(rowRenderer, /state\.dismissedIngest\.add\(entry\.id\)/);
  assert.doesNotMatch(rowRenderer, /exit_code|exit \+|deleteIngest|\/delete/,
    '실패 카드 본문이 기계 종료값을 노출하거나 닫기에서 DB를 지운다');
  const subtitle = javascriptFunction(html, '  function pageSubtitle(');
  assert.match(subtitle, /!state\.dismissedIngest\.has\(entry\.id\)/,
    '닫은 실패 카드는 목록 부제의 실패 건수에서도 빠져야 한다');
});

// --- 11. 다시 하기는 새 retry_of 행으로 카드를 교체하고 DB 이력은 남긴다 ---
contract('retry-replaces-card-without-deleting-history', () => {
  const retry = javascriptFunction(html, '  function retryIngest(');
  const recent = pythonFunction(backend, '    def recent(');
  const retryBackend = pythonFunction(backend, 'def retry_ingest(');
  assert.match(retryBackend, /QUEUE\.enqueue\(/);
  assert.match(retryBackend, /retry_of=attempt_id/);
  assert.match(recent, /WHERE NOT EXISTS/);
  assert.match(recent, /retry\.retry_of = current\.id/);
  assert.match(retry, /state\.dismissedIngest\.add\(id\)/);
  assert.match(retry, /state\.ingestRequests\.unshift\(Object\.assign\(\{\}, previous, payload\)\)/);
  assert.doesNotMatch(retry, /deleteIngest|\/delete/);
});

// --- 12. 저장된 sub-note가 있으면 읽기 셸이 같은 각주를 더하지 않는다 ---
contract('reader-transcript-note-single', () => {
  const start = backend.indexOf('function annotate()');
  const end = backend.indexOf('if(document.readyState===', start);
  assert.ok(start >= 0 && end > start, 'reader annotate function missing');
  const annotate = backend.slice(start, end);
  const guard = annotate.indexOf('document.querySelector("p.sub-note, p.learning-reader-transcript-note")');
  const append = annotate.indexOf('document.createElement("p")');
  assert.ok(guard >= 0 && append > guard,
    '기존 저장 각주를 확인한 뒤에만 런타임 각주를 만들어야 한다');
});

// --- 13. 옛 문서와 새 문서는 같은 공유 퀴즈 자산을 받는다 ---
contract('reader-quiz-shared-assets', () => {
  assert.match(skill, /## 이해 점검/);
  assert.match(
    skill,
    /<section class="doc-quiz">[\s\S]*?<ol class="doc-quiz-list">[\s\S]*?<li class="doc-q">[\s\S]*?<p class="doc-q-stem">[\s\S]*?<ul class="doc-q-opts">[\s\S]*?<li data-correct>[\s\S]*?<p class="doc-q-explain">/,
    '새 문서 퀴즈가 공유 컴포넌트 DOM 계약을 따라야 한다',
  );
  assert.match(skill, /오답에도 정답만큼 공을 들인다/);
  assert.match(backend, /READER_SHARED_CSS = '<link rel="stylesheet" href="\.\.\/_assets\/doc\.css">'/);
  assert.match(backend, /READER_SHARED_JS = '<script type="module" src="\.\.\/_assets\/doc\.js"><\/script>'/);
  assert.match(sharedDocCss, /var\(--doc-fs-scale, 1\)/,
    'Learning의 배율 훅은 공개 share-docs 자산의 실제 계약이어야 한다');
  assert.match(sharedDocCss, /\.doc-quiz\{/,
    'Learning의 퀴즈 마크업은 공개 share-docs CSS에 실제로 있어야 한다');
  assert.match(sharedDocJs, /const THEME_KEY='doc-theme'/,
    'Learning의 테마 키는 공개 share-docs JS의 실제 계약이어야 한다');
  assert.match(sharedDocJs, /const FS_KEY='doc-fontscale'/,
    'Learning의 배율 키는 공개 share-docs JS의 실제 계약이어야 한다');
  assert.match(sharedDocJs, /querySelectorAll\('\.doc-quiz'\)/,
    'Learning의 퀴즈 마크업은 공개 share-docs JS가 실제로 처리해야 한다');
  const inject = pythonFunction(backend, 'def inject_reader_shell(');
  assert.match(inject, /doc\\\.css/);
  assert.match(inject, /doc\\\.js/);
  assert.match(inject, /shared_assets \+ READER_SHELL_STYLE/);
  const getRoute = pythonFunction(backend, '    def do_GET(');
  assert.match(getRoute, /re\.fullmatch\(r"\/read\/\(\?:\.\*\/\)\?_assets\/\(\[\^\/\]\+\)"/);
  assert.match(getRoute, /return self\._published_asset\(unquote\(read_asset\.group\(1\)\)\)/);
  assert.match(installScript, /backend\/timestamp_links\.py/,
    '새 백엔드 모듈은 설치 산출물에도 들어가야 한다');
  const probe = String.raw`
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("learning_backend", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
plain = b'<html><head></head><body><section class="doc-quiz"></section></body></html>'
existing = (b'<html><head><link rel="stylesheet" href="/_assets/doc.css">'
            b'<script type="module" src="/_assets/doc.js"></script></head><body></body></html>')
rendered = module.inject_reader_shell(plain, {"videoUrl": None}).decode()
preserved = module.inject_reader_shell(existing, {"videoUrl": None}).decode()
print(json.dumps({"plain_css": rendered.count("doc.css"),
                  "plain_js": rendered.count("doc.js"),
                  "existing_css": preserved.count("doc.css"),
                  "existing_js": preserved.count("doc.js")}))
`;
  const result = spawnSync('python3', ['-c', probe, fileURLToPath(backendPath)], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    plain_css: 1, plain_js: 1, existing_css: 1, existing_js: 1,
  }, '누락 자산은 한 번 붙고 기존 자산은 중복되지 않아야 한다');
});

// --- 14. 타임스탬프 링크는 저장 원문이 아니라 읽기 응답에서 결정적으로 만든다 ---
contract('reader-timestamp-links', () => {
  const probe = String.raw`
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("timestamp_links", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
html = '''<div class="doc-meta">1:02:03</div>
<h3>00:03:19 — 제목</h3><p><code>9:46</code></p>
<a href="https://example.invalid">0:01:00</a><p title="0:04:00">속성</p>
<details class="transcript"><p>0:05:00</p></details>'''
linked, count = module.link_timestamps(html, "https://youtu.be/video_ID-1")
again, second_count = module.link_timestamps(linked, "https://youtu.be/video_ID-1")
print(json.dumps({"linked": linked, "count": count, "again": again,
                  "second_count": second_count}, ensure_ascii=False))
`;
  const result = spawnSync('python3', ['-c', probe, fileURLToPath(timestampModulePath)], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  const measured = JSON.parse(result.stdout);
  assert.equal(measured.count, 2);
  assert.equal(measured.second_count, 0);
  assert.equal(measured.again, measured.linked, '후처리는 두 번 적용해도 같아야 한다');
  assert.match(measured.linked, /watch\?v=video_ID-1&t=199s[^>]*>00:03:19<\/a>/);
  assert.match(measured.linked, /watch\?v=video_ID-1&t=586s[^>]*>9:46<\/a>/);
  assert.match(measured.linked, /doc-meta">1:02:03<\/div>/);
  assert.match(measured.linked, /<a href="https:\/\/example\.invalid">0:01:00<\/a>/);
  assert.match(measured.linked, /title="0:04:00"/);
  assert.match(measured.linked, /transcript"><p>0:05:00<\/p>/);
  const reader = pythonFunction(backend, '    def _library_doc(');
  assert.match(reader, /inject_reader_shell\(body, reader_context\(relative\)\)/);
  assert.ok(!skill.includes('href="https://www.youtube.com/watch?v=<id>'),
    '집필 모델에게 타임스탬프 링크 조립을 맡기면 안 된다');
});

// --- 15. 검색은 돋보기로 열고 적재 입력과 동시에 나타나지 않는다 ---
contract('search-toggle-single-input', () => {
  const header = javascriptFunction(html, '  function makeHeader(');
  const close = javascriptFunction(html, '  function closeSearch(');
  assert.match(header, /data-search-toggle/);
  assert.match(header, /aria-pressed", String\(state\.searchOpen\)/);
  assert.match(header, /if \(state\.searchOpen\) header\.appendChild\(search\)/);
  assert.match(header, /if \(!state\.archiveView && !state\.searchOpen\) header\.appendChild\(makeIngestComposer\(\)\)/,
    '검색 입력과 적재 입력은 동시에 렌더되면 안 된다');
  assert.match(header, /data-search-close/);
  assert.match(header, /state\.query = input\.value;[\s\S]*?syncCurrentListHistory\(\);[\s\S]*?render\(\);/,
    '검색 입력은 대기 타이머 없이 목록을 즉시 다시 그려야 한다');
  assert.match(close, /state\.searchOpen = false/);
  assert.match(close, /state\.query = ""/);
  assert.match(html, /event\.key === "Escape" && state\.searchOpen[\s\S]*?closeSearch\(\)/);
});

assert.deepEqual(newContractNames, [
  'ingest-submit-without-confirmation',
  'ingest-undo-cancels-queued-run',
  'reader-shell-injection-boundary',
  'reader-markdown-copy',
  'reader-preferences-persistence',
  'reader-share-levels',
  'list-share-action-removed',
  'list-theme-shares-reader-key',
  'learning-name-only',
  'ingest-failure-card-human',
  'retry-replaces-card-without-deleting-history',
  'reader-transcript-note-single',
  'reader-quiz-shared-assets',
  'reader-timestamp-links',
  'search-toggle-single-input',
]);

console.log('learning frontend contract: ok');
