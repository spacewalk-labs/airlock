// [paseo-schedule-pending] Behaviour check for the applied patch.
//
//   node schedule-busy-pending-delivery.test.mjs <candidate schedule/service.js>
//
// 후보 파일을 **설치된 server 트리 안에** 임시 이름으로 두고(그 자리에서만 상대 import 가 풀린다)
// 실제 ScheduleService 를 스텁 좌석으로 구동한다. 문법이 아니라 **동작**을 재는 것이 목적이다:
//   ① 좌석이 busy 면 실패 run 을 남기지 않고 pendingAgentDelivery 만 세운다 (maxRuns 를 갉지 않는다)
//   ② 다시 busy 여도 비트는 하나로 합쳐진다 (밀린 큐가 생기지 않는다)
//   ③ 좌석이 idle 이 되면 due 가 아니어도 그 tick 에 **정확히 한 번** 배달한다
//   ④ 그 뒤 tick 을 더 돌려도 중복 배달이 없다
//
// 🔴 짝 패치(protocol StoredScheduleSchema)가 먼저 적용돼 있어야 한다 — 없으면 zod 가 pendingAgentDelivery
// 를 벗겨 ①이 재시작을 못 견딘다. 그래서 이 테스트는 스키마 지원을 **먼저 확인하고 없으면 실패**한다
// (fail-closed: 설치기는 service 패치를 적용하지 않고 오늘 동작을 유지한다).
// Exit 0 = 전 시나리오 통과.
import { mkdtempSync, copyFileSync, rmSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-busy-pending-delivery.test.mjs <schedule/service.js candidate>"); process.exit(1); }

const scheduleDir = dirname(F);                       // .../server/schedule
const probe = join(scheduleDir, ".paseo-pending-behaviour-test.mjs");
// bare specifier(@getpaseo/protocol)는 **설치 트리 안에서만** 풀린다 — 그래서 shim 도 그 안에 둔다.
const shim = join(scheduleDir, ".paseo-pending-schema-shim.mjs");
const AGENT = "11111111-2222-4333-8444-555555555555";
let home;
const fail = (message) => { console.error("FAIL: " + message); cleanup(); process.exit(1); };
function cleanup() {
    try { rmSync(probe, { force: true }); } catch { /* best effort */ }
    try { rmSync(shim, { force: true }); } catch { /* best effort */ }
    if (home) { try { rmSync(home, { recursive: true, force: true }); } catch { /* best effort */ } }
}

try {
    // ── 짝 패치 확인 — 스키마가 필드를 벗기면 pending 은 재시작을 못 견딘다 ────────────────
    writeFileSync(shim, 'export { StoredScheduleSchema } from "@getpaseo/protocol/schedule/types";\n');
    const { StoredScheduleSchema } = await import(shim);
    const parsed = StoredScheduleSchema.parse({
        id: "s", name: null, prompt: "p", cadence: { type: "every", everyMs: 60000 },
        target: { type: "agent", agentId: AGENT }, status: "active",
        createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
        nextRunAt: null, lastRunAt: null, pausedAt: null, expiresAt: null, maxRuns: null,
        pendingAgentDelivery: true, runs: [],
    });
    if (parsed.pendingAgentDelivery !== true) {
        fail("protocol StoredScheduleSchema 가 pendingAgentDelivery 를 벗긴다 — 스키마 패치를 먼저 적용할 것");
    }

    copyFileSync(F, probe);
    const { ScheduleService } = await import(probe);

    home = mkdtempSync(join(tmpdir(), "paseo-sched-pending-"));
    const noop = () => {};
    const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };
    let busy = true;
    const delivered = [];
    // 0.8.0's agent-target executeSchedule() no longer calls agentManager.runAgent()
    // directly (that path now only serves the new-agent target). It goes through the
    // shared startAgentRun() helper (agent/agent-prompt.js, imported live by the
    // patched service.js -- not stubbed here, so this drives the REAL helper):
    // ensureAgentLoaded() -> getAgent() (present, so it returns immediately) ->
    // tryRunOutOfBand() (false, so it proceeds) -> steerOrReplaceActiveRun() (status
    // is neither "steered" nor "replaced", so it falls through) -> startOrReplaceRun(),
    // which is where busy actually forks the call: replaceAgentRun() when
    // hasInFlightRun() is true, streamAgent() otherwise. executeSchedule() does not
    // await the iterator draining (that runs in a fire-and-forget background
    // promise) -- it awaits waitForAgentEvent() right after the call returns, so
    // that call is the real "delivered" signal, not drain completion.
    const emptyIterator = async function* () {};
    const agentManager = {
        getAgent: () => ({ id: AGENT, lifecycle: busy ? "running" : "idle" }),
        hasInFlightRun: () => busy,
        tryRunOutOfBand: () => false,
        steerOrReplaceActiveTurn: async () => ({ status: "no_active_turn" }),
        replaceAgentRun: async (id) => { delivered.push(id); return emptyIterator(); },
        streamAgent: (id) => { delivered.push(id); return emptyIterator(); },
        waitForAgentEvent: async () => ({ status: "idle", permission: null, lastMessage: "ok" }),
    };
    const service = new ScheduleService({
        paseoHome: home, logger, agentManager,
        agentStorage: { get: async (id) => ({ id, archivedAt: null }) },
        workspaceService: {}, createAgent: async () => ({}), sessionManager: {},
    });
    await service.create({
        name: "behaviour", prompt: "p", cadence: { type: "every", everyMs: 60000 },
        target: { type: "agent", agentId: AGENT }, maxRuns: 3,
    });
    const stored = () => {
        const dir = join(home, "schedules");
        const file = readdirSync(dir).find((name) => name.endsWith(".json"));
        return JSON.parse(readFileSync(join(dir, file), "utf8"));
    };
    const base = Date.now();
    const at = (ms) => { service.now = () => new Date(base + ms); };

    at(120000); await service.tick();
    let current = stored();
    if (current.pendingAgentDelivery !== true) fail("① busy 인데 pendingAgentDelivery 가 서지 않았다");
    if (current.runs.length !== 0) fail(`① busy 가 run 을 남겼다 (${current.runs.length}건) — maxRuns 를 갉는다`);
    if (delivered.length !== 0) fail("① busy 인데 배달됐다");

    at(240000); await service.tick();
    current = stored();
    if (current.pendingAgentDelivery !== true || current.runs.length !== 0) fail("② 두 번째 busy 가 비트를 합치지 않았다");

    busy = false;
    at(250000); await service.tick();   // due 가 아닌 시각 — pending 이 스스로 끌고 간다
    current = stored();
    if (delivered.length !== 1) fail(`③ idle 이 된 뒤 배달이 ${delivered.length}건 (기대 1)`);
    if (current.pendingAgentDelivery !== false) fail("③ 배달 뒤 비트가 남아 있다");
    if (!current.runs.some((run) => run.status === "succeeded")) fail("③ 성공 run 이 기록되지 않았다");

    at(260000); await service.tick();
    if (delivered.length !== 1) fail(`④ 같은 pending 이 다시 배달됐다 (${delivered.length}건)`);

    cleanup();
    console.log("OK: busy→pending 1비트 · 합치기 · idle 1회 배달 · 중복 없음");
    process.exit(0);
} catch (error) {
    console.error("FAIL: " + (error && error.stack ? error.stack : String(error)));
    cleanup();
    process.exit(1);
}
