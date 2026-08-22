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
import fs from 'node:fs';
import vm from 'node:vm';

const htmlPath = new URL('./frontend/learning.html', import.meta.url);
const html = fs.readFileSync(htmlPath, 'utf8');

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

// --- 2. 진행 중 적재를 문서 행으로 접는 결정 ---
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

console.log('learning frontend contract: ok');
