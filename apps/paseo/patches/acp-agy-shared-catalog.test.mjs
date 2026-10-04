// [paseo-acp-agy-shared-catalog] Behaviour check for the applied patch.
//
//   node acp-agy-shared-catalog.test.mjs <.../agent/provider-registry.js>
//
// Slices wrapClientProvider and the custom-ACP createBaseClient out of the
// *patched* bundle and drives that text with stub clients, so a patch that
// applied but reassembled wrongly fails here. Exit 0 = all scenarios pass.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: acp-agy-shared-catalog.test.mjs <provider-registry.js>"); process.exit(1); }
const src = fs.readFileSync(F, "utf8");

const slice = (start, end) => {
    const a = src.indexOf(start);
    const b = a < 0 ? -1 : src.indexOf(end, a);
    if (a < 0 || b < 0) { console.error("추출 실패: " + start.trim()); process.exit(1); }
    return src.slice(a, b);
};

const wrapText = slice("function wrapClientProvider(", "\nfunction ");
const wrapClientProvider = new Function(`${wrapText}\nreturn wrapClientProvider;`)();

const baseText = slice("                createBaseClient: (logger) => {", "\n                contract:");
class GenericACPAgentClient { constructor(options) { this.options = options; } }
class Other extends GenericACPAgentClient {}
const makeCreateBaseClient = (providerId) => new Function(
    "GenericACPAgentClient", "CursorACPAgentClient", "KimiACPAgentClient", "KiroACPAgentClient", "TraeACPAgentClient",
    "providerId", "override", "command",
    `return ({ ${baseText.trim().replace(/,\s*$/, "")} }).createBaseClient;`,
)(GenericACPAgentClient, Other, Other, Other, Other, providerId, {}, ["x"]);

let fail = 0;
const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); if (!c) fail++; };

// ① agy 는 host 키를 받는다
{
    const client = makeCreateBaseClient("agy")({});
    ok(client instanceof GenericACPAgentClient, "① agy 는 여전히 GenericACPAgentClient");
    ok(typeof client.getCatalogCacheKey === "function" && await client.getCatalogCacheKey({}) === "host", "① agy 카탈로그 키 = host");
}

// ② 다른 generic ACP 공급자는 작업공간별 그대로
{
    const client = makeCreateBaseClient("my-acp")({});
    ok(client.getCatalogCacheKey === undefined, "② agy 가 아닌 generic ACP 는 키가 없다(작업공간별 유지)");
}

// ③ 래퍼가 키를 넘긴다
{
    const inner = { provider: "acp", capabilities: {}, async getCatalogCacheKey() { return "host"; } };
    const wrapped = wrapClientProvider("agy", inner, [], [], false);
    ok(await wrapped.getCatalogCacheKey?.({}) === "host", "③ wrapClientProvider 가 inner 의 키를 넘긴다");
}

// ④ 키 없는 inner 는 래퍼에서도 없다
{
    const wrapped = wrapClientProvider("x", { provider: "acp", capabilities: {} }, [], [], false);
    ok(wrapped.getCatalogCacheKey === undefined, "④ 키 없는 inner → 래퍼도 undefined(작업공간별)");
}

process.exit(fail === 0 ? 0 : 1);
