// [paseo-schedule-stale-due] Behaviour check for the applied patch.
//
//   node schedule-stale-due-run.test.mjs <candidate schedule/service.js>
//
// 후보 파일을 **설치된 server 트리 안에** 임시 이름으로 두고(그 자리에서만 상대·bare import 가 풀린다)
// 실제 ScheduleService 를 스텁 좌석으로 구동한다. 문법이 아니라 **동작**을 잰다:
//   ① 정상 due 1회가 그대로 배달되고 one-shot 이 completed 로 간다 (**회귀 방지**)
//   ② 낡은 due 스냅샷으로 runSchedule 을 부르면 append 되지 않는다 (nextRunAt 불일치) ← **본 결함**
//   ③ pause 된 스케줄의 낡은 스냅샷도 거부된다 ← **본 결함**
//   ④ manual(run-now)은 재검증에 막히지 않는다
//   ⑤ 거부된 실행은 유령 run(running 잔재)을 남기지 않는다
//
// 🔴 ①의 겹친 tick 은 **재진입 경쟁을 재현하지 못한다** — 동기 실행에서는 tick 의 기존
// `runningScheduleIds` 가드가 먼저 걸려 패치 전에도 통과한다. 실제 데몬에서 재진입이 낳는 것은
// "실행 시점에 디스크와 어긋난 due 스냅샷"이고, 그것을 직접 재현하는 것이 ②·③ 이다.
// 패치 전 대조 실측(2026-09-23): ② FAIL(run append 됨) · ③ FAIL(pause 무시하고 run 1건).
//
// 🔴 선행 패치(schedule-busy-pending-delivery)가 먼저 적용돼 있어야 한다 — 이 패치의 tick 앵커가
// 그 패치의 결과물이다. 없으면 패처가 exit 20 이라 여기까지 오지 않는다.
// Exit 0 = 전 시나리오 통과.
import { mkdtempSync, copyFileSync, rmSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-stale-due-run.test.mjs <schedule/service.js candidate>"); process.exit(1); }

const scheduleDir = dirname(F);
const probe = join(scheduleDir, ".paseo-stale-due-behaviour-test.mjs");
const AGENT = "11111111-2222-4333-8444-555555555555";
let home;
const fail = (message) => { console.error("FAIL: " + message); cleanup(); process.exit(1); };
function cleanup() {
    try { rmSync(probe, { force: true }); } catch { /* best effort */ }
    if (home) { try { rmSync(home, { recursive: true, force: true }); } catch { /* best effort */ } }
}

try {
    copyFileSync(F, probe);
    const { ScheduleService } = await import(probe);

    home = mkdtempSync(join(tmpdir(), "paseo-sched-stale-"));
    const noop = () => {};
    const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };
    const delivered = [];
    const emptyIterator = async function* () {};
    // 좌석은 늘 idle — 이 테스트가 재는 것은 busy 경로가 아니라 due 재검증이다.
    const agentManager = {
        getAgent: () => ({ id: AGENT, lifecycle: "idle" }),
        hasInFlightRun: () => false,
        tryRunOutOfBand: () => false,
        steerOrReplaceActiveTurn: async () => ({ status: "no_active_turn" }),
        replaceAgentRun: async (id) => { delivered.push(id); return emptyIterator(); },
        streamAgent: (id) => { delivered.push(id); return emptyIterator(); },
        waitForAgentEvent: async () => ({ status: "idle", permission: null, lastMessage: "ok" }),
    };
    const makeService = () => new ScheduleService({
        paseoHome: home, logger, agentManager,
        agentStorage: { get: async (id) => ({ id, archivedAt: null }) },
        workspaceService: {}, createAgent: async () => ({}), sessionManager: {},
    });
    const service = makeService();
    const dir = join(home, "schedules");
    const stored = () => {
        const file = readdirSync(dir).find((name) => name.endsWith(".json"));
        return JSON.parse(readFileSync(join(dir, file), "utf8"));
    };
    const base = Date.now();
    const at = (ms) => { service.now = () => new Date(base + ms); };

    // ── 준비: one-shot(maxRuns=1) — session-delivery 가 만드는 그 모양 ────────────────
    await service.create({
        name: "patrol-deliver:stale-due-probe", prompt: "p",
        cadence: { type: "every", everyMs: 60000 },
        target: { type: "agent", agentId: AGENT }, maxRuns: 1,
    });

    // ── ① 정상 경로 회귀 방지: 겹친 tick 을 돌려도 결과는 정확히 1회 배달 ────────────────
    // (이 검사는 패치 전에도 통과한다 — 위 🔴 참고. 여기서는 패치가 정상 배달을 깨지 않았음을 잰다.)
    at(120000);
    await Promise.all([service.tick(), service.tick()]);
    let current = stored();
    const succeeded = current.runs.filter((run) => run.status === "succeeded");
    if (current.runs.length !== 1) {
        fail(`① 재진입 tick 이 run 을 ${current.runs.length}건 남겼다 (기대 1) — maxRuns=1 이 뚫렸다`);
    }
    if (succeeded.length !== 1) fail(`① 성공 run 이 ${succeeded.length}건 (기대 1)`);
    if (delivered.length !== 1) fail(`① 배달이 ${delivered.length}건 (기대 1) — 중복 수신이다`);
    if (current.status !== "completed") fail(`① one-shot 이 completed 로 가지 않았다 (${current.status})`);

    // ── ② 본 결함: 낡은 스냅샷(nextRunAt 불일치)은 append 되지 않는다 ────────────────
    const stale = { ...current, status: "active", nextRunAt: new Date(base + 1).toISOString() };
    const before = stored().runs.length;
    at(300000);
    await service.runSchedule(stale, new Date(base + 300000));
    if (stored().runs.length !== before) fail("② 낡은 nextRunAt 스냅샷이 run 을 append 했다");
    if (delivered.length !== 1) fail(`② 낡은 스냅샷이 배달됐다 (${delivered.length}건)`);

    // ── ⑤ 거부는 유령 run 을 남기지 않는다 ────────────────────────────────────────────
    if (stored().runs.some((run) => run.status === "running")) {
        fail("⑤ 거부된 실행이 running run 을 남겼다");
    }

    // ── ③ 본 결함: pause 된 대상의 낡은 스냅샷도 거부된다 ────────────────────────────
    const service2 = makeService();
    service2.now = () => new Date(base + 400000);
    const second = await service2.create({
        name: "patrol-deliver:paused-probe", prompt: "p",
        cadence: { type: "every", everyMs: 60000 },
        target: { type: "agent", agentId: AGENT }, maxRuns: 1,
    });
    const snapshot = JSON.parse(JSON.stringify(second));
    await service2.pause(second.id);
    const deliveredBefore = delivered.length;
    await service2.runSchedule(snapshot, new Date(base + 460000));
    const pausedRow = JSON.parse(readFileSync(join(dir, `${second.id}.json`), "utf8"));
    if (pausedRow.runs.length !== 0) fail(`③ pause 된 스케줄이 run 을 ${pausedRow.runs.length}건 남겼다`);
    if (delivered.length !== deliveredBefore) fail("③ pause 된 스케줄이 배달됐다");

    // ── ④ manual 은 재검증에 막히지 않는다 ────────────────────────────────────────────
    await service2.runSchedule(snapshot, new Date(base + 470000), { manual: true });
    const manualRow = JSON.parse(readFileSync(join(dir, `${second.id}.json`), "utf8"));
    if (manualRow.runs.length !== 1) {
        fail(`④ manual 실행이 막혔다 (runs=${manualRow.runs.length}, 기대 1) — 사람이 지금 보내라 한 것이다`);
    }
    if (delivered.length !== deliveredBefore + 1) fail("④ manual 실행이 배달되지 않았다");

    cleanup();
    console.log("OK: 정상 1회 배달 유지 · 낡은 스냅샷·pause 거부 · manual 통과 · 유령 run 없음");
    process.exit(0);
} catch (error) {
    console.error("FAIL: " + (error && error.stack ? error.stack : String(error)));
    cleanup();
    process.exit(1);
}
