// [paseo-schedule-pending-batch] Behaviour check for the applied patch.
//
//   node schedule-pending-batch.test.mjs <candidate schedule/service.js>
//
// busy-pending 테스트와 같은 방식이다 — 후보를 설치된 server 트리 안에 임시 이름으로 두고 실제
// ScheduleService 를 스텁 좌석으로 구동한다(executeSchedule·startAgentRun 은 실물).
//   ① 한 좌석에 one-shot 셋이 busy 로 pending 이 된다 (run 0)
//   ② idle 이 되면 **한 번의** 배달로 셋이 다 나간다 — 프롬프트에 셋이 생성 순서대로 들어 있고,
//      schedule 마다 run 은 정확히 하나·succeeded 다 (session-delivery receipt 계약)
//   ③ 그 뒤 tick 을 더 돌려도 중복 배달이 없다
//   ④ claim 뒤 append 가 거부되면 비트가 되살아나고, 다음 idle tick 에 배달된다
//   ⑤ 한 건의 비트 복원이 실패해도 나머지는 같은 턴에 배달되고 실행 잠금이 남지 않는다
//   ⑥ 실행 중 한 schedule 이 삭제돼도 나머지 건의 성공 run 은 기록된다
//   ⑦ 둘째 claim 이 저장 오류로 던져도 첫째·셋째는 그 턴에 나가고, 둘째는 다음 tick 에 나간다
//   ⑧ claim 도중 tick 이 겹쳐도 묶음이 갈리지 않고 생성 순서대로 한 턴에 나간다
//   ⑨ ⑧ 과 같되 nextRunAt 이 지나 겹친 tick 의 due 경로까지 도는 시각이어도 같다
// Exit 0 = 전 시나리오 통과.
import { mkdtempSync, copyFileSync, rmSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-pending-batch.test.mjs <schedule/service.js candidate>"); process.exit(1); }

const probe = join(dirname(F), ".paseo-pending-batch-behaviour-test.mjs");
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

    home = mkdtempSync(join(tmpdir(), "paseo-sched-batch-"));
    const noop = () => {};
    const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };
    let busy = true;
    let duringRun = null;
    const delivered = [];
    const emptyIterator = async function* () {};
    const agentManager = {
        getAgent: () => ({ id: AGENT, lifecycle: busy ? "running" : "idle" }),
        hasInFlightRun: () => busy,
        tryRunOutOfBand: () => false,
        steerOrReplaceActiveTurn: async () => ({ status: "no_active_turn" }),
        replaceAgentRun: async (id, prompt) => { delivered.push(prompt); return emptyIterator(); },
        streamAgent: (id, prompt) => { delivered.push(prompt); return emptyIterator(); },
        waitForAgentEvent: async () => { if (duringRun) await duringRun(); return { status: "idle", permission: null, lastMessage: "ok" }; },
    };
    const service = new ScheduleService({
        paseoHome: home, logger, agentManager,
        agentStorage: { get: async (id) => ({ id, archivedAt: null }) },
        workspaceService: {}, createAgent: async () => ({}), sessionManager: {},
    });
    const base = Date.now();
    const at = (ms) => { service.now = () => new Date(base + ms); };
    const all = () => {
        const dir = join(home, "schedules");
        return readdirSync(dir).filter((name) => name.endsWith(".json"))
            .map((name) => JSON.parse(readFileSync(join(dir, name), "utf8")));
    };
    const byName = (name) => all().find((s) => s.name === name);
    const text = (prompt) => typeof prompt === "string" ? prompt : JSON.stringify(prompt);

    at(0);
    for (const name of ["m1", "m2", "m3"]) {
        at(["m1", "m2", "m3"].indexOf(name) * 10);
        await service.create({
            name, prompt: `body-${name}`, cadence: { type: "every", everyMs: 3600000 },
            target: { type: "agent", agentId: AGENT }, maxRuns: 1,
        });
    }

    at(3600000); await service.tick();
    for (const s of all()) {
        if (s.pendingAgentDelivery !== true || s.runs.length !== 0) fail(`① ${s.name} 이 pending 이 아니거나 run 이 있다`);
    }
    if (delivered.length !== 0) fail("① busy 인데 배달됐다");

    busy = false;
    at(3600500); await service.tick();
    if (delivered.length !== 1) fail(`② idle 뒤 배달 ${delivered.length}회 (기대 1회 — 한 턴에 묶여야 한다)`);
    const body = text(delivered[0]);
    const order = ["body-m1", "body-m2", "body-m3"].map((part) => body.indexOf(part));
    if (order.some((i) => i < 0)) fail("② 묶음 프롬프트에 빠진 메시지가 있다");
    if (!(order[0] < order[1] && order[1] < order[2])) fail("② 묶음 프롬프트의 순서가 생성 순서와 다르다");
    for (const s of all()) {
        if (s.runs.length !== 1 || s.runs[0].status !== "succeeded") fail(`② ${s.name} 의 run 이 정확히 하나·succeeded 가 아니다`);
        if (s.pendingAgentDelivery !== false) fail(`② ${s.name} 에 비트가 남았다`);
        if (!body.includes(`run=${s.runs[0].id}`)) fail(`② ${s.name} 의 run id 가 프롬프트에 없다`);
    }

    at(3601000); await service.tick();
    at(3602000); await service.tick();
    if (delivered.length !== 1) fail(`③ 중복 배달 (${delivered.length}회)`);

    // ④ claim 뒤 append 거부 → 비트 복원
    busy = true;
    at(3700000);
    await service.create({
        name: "m4", prompt: "body-m4", cadence: { type: "every", everyMs: 3600000 },
        target: { type: "agent", agentId: AGENT }, maxRuns: 1,
    });
    at(7300000); await service.tick();
    if (byName("m4").pendingAgentDelivery !== true) fail("④ 준비: m4 가 pending 이 아니다");
    busy = false;
    const realAppend = service.appendRunningRun.bind(service);
    service.appendRunningRun = async () => null;
    at(7300500); await service.tick();
    service.appendRunningRun = realAppend;
    let m4 = byName("m4");
    if (m4.pendingAgentDelivery !== true) fail("④ append 거부 뒤 비트가 사라졌다 — 다음 정각까지 선다");
    if (m4.runs.length !== 0) fail("④ 거부된 append 가 run 을 남겼다");
    if (delivered.length !== 1) fail("④ 거부됐는데 배달됐다");
    at(7301000); await service.tick();
    m4 = byName("m4");
    if (delivered.length !== 2 || m4.runs.length !== 1 || m4.runs[0].status !== "succeeded") fail("④ 복원된 비트가 다음 tick 에 배달되지 않았다");
    if (text(delivered[1]).includes("pending deliveries")) fail("④ 한 건인데 묶음 머리말이 붙었다");

    const pendingTrio = async (names, createAt, busyAt) => {
        busy = true;
        for (const [i, name] of names.entries()) {
            at(createAt + i * 10);
            await service.create({
                name, prompt: `body-${name}`, cadence: { type: "every", everyMs: 3600000 },
                target: { type: "agent", agentId: AGENT }, maxRuns: 1,
            });
        }
        at(busyAt); await service.tick();
        for (const name of names) if (byName(name).pendingAgentDelivery !== true) fail(`준비: ${name} 이 pending 이 아니다`);
        busy = false;
    };

    // ⑤ 둘째 건 append 거부 + 그 복원이 저장 오류로 실패
    await pendingTrio(["r1", "r2", "r3"], 7400000, 11000000);
    const r2id = byName("r2").id;
    const appendReal = service.appendRunningRun.bind(service);
    const restoreReal = service.restorePendingDelivery.bind(service);
    service.appendRunningRun = async (id, ...rest) => id === r2id ? null : appendReal(id, ...rest);
    service.restorePendingDelivery = async () => { throw new Error("injected store failure"); };
    const before5 = delivered.length;
    at(11000500); await service.tick();
    service.appendRunningRun = appendReal;
    service.restorePendingDelivery = restoreReal;
    if (delivered.length !== before5 + 1) fail(`⑤ 복원 실패가 나머지 배달을 막았다 (배달 ${delivered.length - before5}회)`);
    const body5 = text(delivered[delivered.length - 1]);
    if (!body5.includes("body-r1") || !body5.includes("body-r3") || body5.includes("body-r2")) fail("⑤ 묶음 내용이 r1·r3 이 아니다");
    for (const name of ["r1", "r3"]) {
        const s = byName(name);
        if (s.runs.length !== 1 || s.runs[0].status !== "succeeded") fail(`⑤ ${name} 의 run 이 하나·succeeded 가 아니다`);
    }
    if (service.runningScheduleIds.size !== 0) fail(`⑤ 실행 잠금이 남았다 (${service.runningScheduleIds.size}건)`);

    // ⑥ 실행 중 첫 건 삭제
    await pendingTrio(["d1", "d2", "d3"], 11100000, 14700000);
    const d1id = byName("d1").id;
    duringRun = async () => { duringRun = null; await service.delete(d1id); };
    const before6 = delivered.length;
    at(14700500); await service.tick();
    if (delivered.length !== before6 + 1) fail(`⑥ 묶음 배달이 ${delivered.length - before6}회`);
    if (byName("d1")) fail("⑥ 준비: d1 이 삭제되지 않았다");
    for (const name of ["d2", "d3"]) {
        const s = byName(name);
        if (s.runs.length !== 1 || s.runs[0].status !== "succeeded") fail(`⑥ 삭제된 이웃 때문에 ${name} 의 성공이 기록되지 않았다`);
    }
    if (service.runningScheduleIds.size !== 0) fail(`⑥ 실행 잠금이 남았다 (${service.runningScheduleIds.size}건)`);

    // ⑦ 둘째 claim 저장 오류
    await pendingTrio(["c1", "c2", "c3"], 14800000, 18400100);
    const c2id = byName("c2").id;
    const claimReal = service.claimPendingDelivery.bind(service);
    service.claimPendingDelivery = async (id) => { if (id === c2id) throw new Error("injected claim failure"); return claimReal(id); };
    const before7 = delivered.length;
    at(18400500); await service.tick();
    service.claimPendingDelivery = claimReal;
    if (delivered.length !== before7 + 1) fail(`⑦ claim 오류가 앞선 claim 의 배달을 막았다 (배달 ${delivered.length - before7}회)`);
    const body7 = text(delivered[delivered.length - 1]);
    if (!body7.includes("body-c1") || !body7.includes("body-c3") || body7.includes("body-c2")) fail("⑦ 묶음 내용이 c1·c3 이 아니다");
    if (byName("c2").pendingAgentDelivery !== true) fail("⑦ claim 실패한 c2 의 비트가 사라졌다");
    at(18401000); await service.tick();
    const c2 = byName("c2");
    if (c2.runs.length !== 1 || c2.runs[0].status !== "succeeded") fail("⑦ c2 가 다음 tick 에 배달되지 않았다");
    for (const name of ["c1", "c3"]) if (byName(name).runs.length !== 1) fail(`⑦ ${name} 의 run 이 하나가 아니다`);

    // ⑧ 둘째 claim 이 저장된 직후 다른 tick 이 끼어든다
    await pendingTrio(["o1", "o2", "o3"], 18500000, 22100100);
    const o2id = byName("o2").id;
    const claimReal8 = service.claimPendingDelivery.bind(service);
    let overlapped = false;
    service.claimPendingDelivery = async (id) => {
        const claimedRow = await claimReal8(id);
        if (id === o2id && !overlapped) { overlapped = true; await service.tick(); }
        return claimedRow;
    };
    const before8 = delivered.length;
    at(22100500); await service.tick();
    service.claimPendingDelivery = claimReal8;
    if (!overlapped) fail("⑧ 준비: 겹친 tick 이 일어나지 않았다");
    if (delivered.length !== before8 + 1) fail(`⑧ 겹친 tick 이 묶음을 갈랐다 (배달 ${delivered.length - before8}회)`);
    const body8 = text(delivered[delivered.length - 1]);
    const order8 = ["body-o1", "body-o2", "body-o3"].map((part) => body8.indexOf(part));
    if (order8.some((i) => i < 0) || !(order8[0] < order8[1] && order8[1] < order8[2])) fail("⑧ 묶음이 전량·생성 순서가 아니다");
    for (const name of ["o1", "o2", "o3"]) {
        const s = byName(name);
        if (s.runs.length !== 1 || s.runs[0].status !== "succeeded") fail(`⑧ ${name} 의 run 이 하나·succeeded 가 아니다`);
    }

    // ⑨ due 시각이 지난 뒤의 겹친 tick
    await pendingTrio(["p1", "p2", "p3"], 22200000, 25800100);
    const latest = Math.max(...["p1", "p2", "p3"].map((name) => Date.parse(byName(name).nextRunAt) - base));
    const p2id = byName("p2").id;
    const claimReal9 = service.claimPendingDelivery.bind(service);
    let overlapped9 = false;
    service.claimPendingDelivery = async (id) => {
        const claimedRow = await claimReal9(id);
        if (id === p2id && !overlapped9) { overlapped9 = true; await service.tick(); }
        return claimedRow;
    };
    const before9 = delivered.length;
    at(latest + 500); await service.tick();
    service.claimPendingDelivery = claimReal9;
    if (!overlapped9) fail("⑨ 준비: 겹친 tick 이 일어나지 않았다");
    if (delivered.length !== before9 + 1) fail(`⑨ 겹친 tick 의 due 경로가 묶음을 갈랐다 (배달 ${delivered.length - before9}회)`);
    const body9 = text(delivered[delivered.length - 1]);
    const order9 = ["body-p1", "body-p2", "body-p3"].map((part) => body9.indexOf(part));
    if (order9.some((i) => i < 0) || !(order9[0] < order9[1] && order9[1] < order9[2])) fail("⑨ 묶음이 전량·생성 순서가 아니다");
    for (const name of ["p1", "p2", "p3"]) {
        const s = byName(name);
        if (s.runs.length !== 1 || s.runs[0].status !== "succeeded") fail(`⑨ ${name} 의 run 이 하나·succeeded 가 아니다`);
    }

    cleanup();
    console.log("OK: 좌석당 pending 한 턴 묶음 · 순서 · schedule 마다 run 1 · 중복 없음 · 거부 시 비트 복원 · 한 건 오류 격리(복원·삭제·claim) · 겹친 tick 묶음 소유(pending·due)");
    process.exit(0);
} catch (error) {
    console.error("FAIL: " + (error && error.stack ? error.stack : String(error)));
    cleanup();
    process.exit(1);
}
