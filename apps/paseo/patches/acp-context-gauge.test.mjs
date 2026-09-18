// [paseo-acp-context-gauge] Behaviour check for the applied patch.
//
//   node acp-context-gauge.test.mjs <.../providers/acp-agent.js>
//
// Slices handleUsageUpdate/handlePromptResponse and handleConfigOptionUpdate
// out of the *installed, patched* bundle and drives that text directly against
// a synthetic harness, so a patch that applied but reassembled wrongly fails
// here. Exit 0 = all scenarios pass.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: acp-context-gauge.test.mjs <acp-agent.js>"); process.exit(1); }
const src = fs.readFileSync(F, "utf8");

function slice(startMarker, endMarker) {
    const a = src.indexOf(startMarker);
    if (a < 0) throw new Error("marker not found: " + startMarker);
    const b = src.indexOf(endMarker, a);
    if (b < 0) throw new Error("end marker not found after " + startMarker + ": " + endMarker);
    return src.slice(a, b);
}

const usageMethods = slice(
    "    handleUsageUpdate(update) {",
    "\n    wrapTimeline(",
);
// The extracted slice ends wherever the next method after handlePromptResponse
// happens to be -- pin that assumption explicitly so upstream renaming it is a
// loud extraction failure here, not a silent short/long slice.
if (!src.includes("\n    wrapTimeline(")) {
    throw new Error("handlePromptResponse is no longer followed by wrapTimeline -- update the end marker");
}

const configModesMethod = slice(
    "    handleConfigOptionUpdate(update) {",
    "\n    handleSessionInfoUpdate(",
);

let fail = 0;
const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); if (!c) fail++; };

// ── handleUsageUpdate / handlePromptResponse ────────────────────────────────
function mapACPUsage(usage) {
    if (!usage) return undefined;
    return { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens };
}
const UsageHarness = new Function("mapACPUsage", `
  return class T {
    constructor() { this.provider = "acp"; this.currentTurnUsage = {}; this.activeForegroundTurnId = "t1"; }
    finishTurn(_event) {}
    synthesizeCanceledToolCalls() {}
${usageMethods}
  };
`)(mapACPUsage);
{
    const t = new UsageHarness();
    const events = t.handleUsageUpdate({ used: 100, size: 1000 });
    ok(events.length === 1 && events[0].type === "usage_updated", "① usage_update → usage_updated 이벤트 1건");
    ok(events[0].usage.contextWindowUsedTokens === 100 && events[0].usage.contextWindowMaxTokens === 1000,
        "① 게이지 필드가 채워진다");
    ok(t.currentTurnUsage.contextWindowUsedTokens === 100, "① currentTurnUsage 에도 반영된다");

    const withCost = t.handleUsageUpdate({ used: 200, size: 1000, cost: { currency: "USD", amount: 0.5 } });
    ok(withCost[0].usage.totalCostUsd === 0.5, "② USD 비용은 totalCostUsd 로 반영된다");

    t.handlePromptResponse({ usage: { inputTokens: 50, outputTokens: 10 } }, "t1");
    ok(t.currentTurnUsage.contextWindowUsedTokens === 200 && t.currentTurnUsage.contextWindowMaxTokens === 1000,
        "③ 턴 종료 응답이 게이지 필드를 지우지 않는다 (병합, 덮어쓰기 아님)");
    ok(t.currentTurnUsage.inputTokens === 50 && t.currentTurnUsage.outputTokens === 10,
        "③ 턴 종료 응답의 토큰 수는 반영된다");

    const missingFields = t.handleUsageUpdate({});
    ok(Array.isArray(missingFields) && missingFields.length === 0, "④ used/size 없는 update는 조용히 무시된다");
}

// ── handleConfigOptionUpdate: mode-list preservation ────────────────────────
const ConfigHarness = new Function("deriveModesFromACP", "deriveCurrentConfigValue", `
  return class T {
    constructor(modes) {
      this.provider = "acp";
      this.defaultModes = [];
      this.configOptions = [];
      this.availableModes = modes;
      this.currentMode = null;
      this.currentModel = null;
      this.thinkingOptionId = null;
    }
    transformConfigOptions(x) { return x; }
    runtimeInfo() { return {}; }
${configModesMethod}
  };
`)(
    // deriveModesFromACP(defaultModes, null, configOptions) -- called with modeState=null,
    // matching handleConfigOptionUpdate's real call site. No mode state to read from.
    () => ({ modes: [], currentModeId: null }),
    (_configOptions, category) => (category === "model" ? "gpt-5" : null),
);
{
    const existing = [{ id: "plan", label: "Plan" }];
    const t = new ConfigHarness(existing);
    const events = t.handleConfigOptionUpdate({ configOptions: [] });
    ok(t.availableModes === existing, "⑤ 모델만 바뀐 config_option_update 는 모드 목록을 지우지 않는다");
    ok(events.some((e) => e.type === "model_changed"), "⑤ 모델 변경 이벤트는 그대로 나간다");
    ok(!events.some((e) => e.type === "mode_changed"), "⑤ 모드가 안 바뀌었으니 mode_changed 는 없다");
}

console.log(fail === 0 ? "\n전부 통과" : `\n실패 ${fail}건`);
process.exit(fail === 0 ? 0 : 1);
