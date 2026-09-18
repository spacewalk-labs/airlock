// [paseo-acp-cross-provider-mode-default] Behaviour check for the applied patch.
//
//   node acp-cross-provider-mode-default.test.mjs <.../providers/generic-acp-agent.js>
//
// Slices the constructor's resolveCreateConfig override out of the *installed,
// patched* bundle and drives that text directly, so a patch that applied but
// reassembled wrongly fails here. Exit 0 = all scenarios pass.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: acp-cross-provider-mode-default.test.mjs <generic-acp-agent.js>"); process.exit(1); }
const src = fs.readFileSync(F, "utf8");

const a = src.indexOf("        const baseResolveCreateConfig = this.resolveCreateConfig;");
const b = src.indexOf("\n        this.command = options.command;", a);
if (a < 0 || b < 0) { console.error("추출 실패"); process.exit(1); }
const body = src.slice(a, b);

let baseCalls = 0;
const base = (input) => { baseCalls += 1; return { modeId: "base-default", featureValues: input.featureValues }; };
// The extracted text is constructor-body statements, not a function -- wrap it in
// one so `this` binds to a synthetic instance and `resolveCreateConfig` ends up
// where the constructor would have left it.
const build = new Function("fakeBaseResolveCreateConfig", `
  return function (options) {
    this.resolveCreateConfig = fakeBaseResolveCreateConfig;
${body}
  };
`)(base);

let fail = 0;
const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); if (!c) fail++; };

function makeInstance() {
    const instance = {};
    build.call(instance, {});
    return instance;
}

// ① 다른 공급자의 attended 부모, 모드 미지정 → 우회(모드 검증을 건너뛴다)
{
    baseCalls = 0;
    const instance = makeInstance();
    const result = instance.resolveCreateConfig({
        requestedMode: undefined,
        provider: "acp",
        unattended: false,
        featureValues: { x: 1 },
        parent: { provider: "claude", isUnattended: false },
    });
    ok(result.modeId === undefined && baseCalls === 0, "① attended 타 공급자 부모 + 모드 미지정 → base 를 건너뛰고 우회");
    ok(result.featureValues?.x === 1, "① featureValues 는 그대로 전달된다");
}

// ② 같은 공급자 부모 → base 로 위임(우회하지 않는다)
{
    baseCalls = 0;
    const instance = makeInstance();
    const result = instance.resolveCreateConfig({
        requestedMode: undefined,
        provider: "acp",
        unattended: false,
        featureValues: {},
        parent: { provider: "acp", isUnattended: false },
    });
    ok(baseCalls === 1 && result.modeId === "base-default", "② 같은 공급자 부모 → base 로 위임");
}

// ③ 부모가 unattended → base 로 위임(base 가 이미 그 경우를 처리한다)
{
    baseCalls = 0;
    const instance = makeInstance();
    instance.resolveCreateConfig({
        requestedMode: undefined,
        provider: "acp",
        unattended: false,
        featureValues: {},
        parent: { provider: "claude", isUnattended: true },
    });
    ok(baseCalls === 1, "③ unattended 부모 → base 로 위임 (base 의 우회를 가로채지 않는다)");
}

// ④ 명시적 모드가 있으면 항상 base 로 위임
{
    baseCalls = 0;
    const instance = makeInstance();
    instance.resolveCreateConfig({
        requestedMode: "plan",
        provider: "acp",
        unattended: false,
        featureValues: {},
        parent: { provider: "claude", isUnattended: false },
    });
    ok(baseCalls === 1, "④ requestedMode 지정 시 항상 base 로 위임");
}

// ⑤ 부모가 없으면(최상위 생성) base 로 위임
{
    baseCalls = 0;
    const instance = makeInstance();
    instance.resolveCreateConfig({
        requestedMode: undefined,
        provider: "acp",
        unattended: false,
        featureValues: {},
        parent: null,
    });
    ok(baseCalls === 1, "⑤ parent 없음 → base 로 위임");
}

console.log(fail === 0 ? "\n전부 통과" : `\n실패 ${fail}건`);
process.exit(fail === 0 ? 0 : 1);
