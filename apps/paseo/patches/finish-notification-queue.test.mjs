// [paseo-finish-queue] Behaviour check for the applied patch.
//
//   node finish-notification-queue.test.mjs <candidate agent/agent-prompt.js>
//
// 후보를 설치 트리 안(같은 디렉터리)에 임시 이름으로 두고 실제 setupFinishNotification 을 가짜
// agentManager 로 구동한다. 재는 것:
//   ① 부모가 idle 이면 알림이 즉시 간다 (기존 동작 유지)
//   ② 부모가 실행 중이면 알림이 **가지 않고**(= 턴을 끊지 않고) 큐에 쌓인다
//   ③ 부모 턴이 취소로 끝난 idle 에서는 drain 하지 않는다
//   ④ 부모 턴이 정상 완료로 idle 이 되면 쌓인 알림이 **한 통으로 한 번** 간다
//   ⑤ 이전 기동의 임대분(.leased)은 재전송하지 않고 uncertain 으로 옮긴다
//   ⑥ drain 이 idle 을 확인한 뒤·보내기 전에 새 턴이 열리면 그 턴을 **끊지 않고** 큐로 되돌린다 (v1 결함)
//   ⑦ 되돌린 알림은 그 턴의 정상 완료 뒤 **한 번** 나간다 — 그 사이 들어온 알림도 잃지 않는다
// Exit 0 = 전 시나리오 통과.
import { mkdtempSync, copyFileSync, rmSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: finish-notification-queue.test.mjs <agent-prompt.js candidate>"); process.exit(1); }
const probe = join(dirname(F), `.paseo-finish-queue-behaviour-${process.pid}.mjs`);
let home;
const cleanup = () => {
    try { rmSync(probe, { force: true }); } catch { /* best effort */ }
    if (home) { try { rmSync(home, { recursive: true, force: true }); } catch { /* best effort */ } }
};
const fail = (message) => { console.error("FAIL: " + message); cleanup(); process.exit(1); };
const tick = () => new Promise((resolve) => setTimeout(resolve, 30));
// 「일어나야 하는 일」은 고정 30ms 가 아니라 조건이 설 때까지 기다린다(최대 5초). drain 은 fire-and-forget 이라
// 부하 큰 박스(load 38 실측)에선 ack 의 rm 이 30ms 를 넘겨, 멀쩡한 패치를 설치기가 「행동 실패」로 버렸다.
// 「일어나면 안 되는 일」(보내지 않음·끊지 않음)은 tick 뒤에 그대로 본다.
const until = async (pred, ms = 5000) => { const end = Date.now() + ms; while (!pred() && Date.now() < end) await new Promise((r) => setTimeout(r, 10)); };

try {
    copyFileSync(F, probe);
    const mod = await import(probe);
    home = mkdtempSync(join(tmpdir(), "paseo-finish-queue-"));
    const agentsDir = join(home, "agents");
    const queueDir = join(home, "finish-notify-queue");
    const noop = () => {};
    const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };

    const PARENT = "aaaaaaaa-0000-4000-8000-000000000001";
    const CHILD1 = "bbbbbbbb-0000-4000-8000-000000000002";
    const CHILD2 = "cccccccc-0000-4000-8000-000000000003";
    const state = { [PARENT]: "idle", [CHILD1]: "idle", [CHILD2]: "idle" };
    const subs = [];
    const sent = [];        // [agentId, prompt]
    const replaced = [];    // replaceAgentRun 이 불렸나 = 끊었나
    const agentManager = {
        subscribe(cb, opts) { const row = { cb, id: opts?.agentId }; subs.push(row); return () => { row.dead = true; }; },
        getAgent: (id) => ({ id, lifecycle: state[id], provider: "codex", persistence: null }),
        hasInFlightRun: (id) => state[id] === "running",
        getLastAssistantMessage: async () => "done",
        tryRunOutOfBand: () => false,
        waitForAgentClose: async () => {},
        streamAgent(id, prompt) {
            if (state[id] === "running") throw new Error(`Agent ${id} already has an active run`);   // upstream 과 같은 거부
            sent.push([id, prompt]); return (async function* () {})();
        },
        async replaceAgentRun(id, prompt) { replaced.push(id); sent.push([id, prompt]); return (async function* () {})(); },
    };
    let onStorageGet = null;   // ⑥: drain 이 보내기 직전(get 호출)에 다른 전송이 턴을 연 상황을 만든다
    const agentStorage = { baseDir: agentsDir, get: async (id) => { if (onStorageGet) { const f = onStorageGet; onStorageGet = null; f(id); } return { id, archivedAt: null, title: id.slice(0, 4), labels: {} }; } };
    const emit = (id, event) => { for (const s of subs) if (!s.dead && (!s.id || s.id === id)) s.cb(event); };
    const setState = (id, lifecycle) => { state[id] = lifecycle; emit(id, { type: "agent_state", agent: { id, lifecycle } }); };
    const turnEnd = (id, type) => emit(id, { type: "agent_stream", agentId: id, event: { type } });
    const finish = async (child) => {
        mod.setupFinishNotification({ agentManager, agentStorage, childAgentId: child, callerAgentId: PARENT, logger });
        setState(child, "running");
        setState(child, "idle");
        await tick();
    };

    // ① 부모 idle → 즉시
    await finish(CHILD1);
    await until(() => sent.length === 1);
    if (sent.length !== 1 || sent[0][0] !== PARENT) fail(`① idle 부모에게 즉시 가지 않았다 (sent=${sent.length})`);

    // ② 부모 running → 끊지 않고 큐
    sent.length = 0;
    state[PARENT] = "running";
    await finish(CHILD2);
    await finish(CHILD1);
    if (sent.length !== 0 || replaced.length !== 0) fail(`② 실행 중 부모에게 보냈다/끊었다 (sent=${sent.length}, replaced=${replaced.length})`);
    if (!existsSync(join(queueDir, `${PARENT}.jsonl`))) fail("② 큐 파일이 없다");

    // ③ 취소로 끝난 idle → drain 금지
    turnEnd(PARENT, "turn_canceled");
    setState(PARENT, "idle");
    await tick();
    if (sent.length !== 0) fail("③ 취소 뒤 idle 에서 drain 했다");

    // ④ 정상 완료 idle → 한 통으로 한 번
    setState(PARENT, "running");
    turnEnd(PARENT, "turn_completed");
    setState(PARENT, "idle");
    await until(() => sent.length >= 1 && !existsSync(join(queueDir, `${PARENT}.jsonl`)) && !existsSync(join(queueDir, `${PARENT}.leased`)));
    await tick();
    if (sent.length !== 1) fail(`④ 정상 완료 뒤 배달이 ${sent.length}통 (기대 1)`);
    const prompt = JSON.stringify(sent[0][1]);
    if (!prompt.includes("2 queued child notifications")) fail("④ 두 알림이 한 통으로 묶이지 않았다");
    if (existsSync(join(queueDir, `${PARENT}.jsonl`)) || existsSync(join(queueDir, `${PARENT}.leased`))) fail("④ ack 뒤 큐가 남았다");
    setState(PARENT, "running"); turnEnd(PARENT, "turn_completed"); setState(PARENT, "idle"); await tick();
    if (sent.length !== 1) fail("④ 비운 큐가 다시 배달됐다");

    // ⑤ 이전 기동 임대분은 재전송하지 않는다
    writeFileSync(join(queueDir, `${PARENT}.leased`), JSON.stringify({ at: "x", body: "stale" }) + "\n");
    setState(PARENT, "running"); turnEnd(PARENT, "turn_completed"); setState(PARENT, "idle"); await tick();
    await until(() => readdirSync(queueDir).some((name) => name.startsWith(`${PARENT}.uncertain-`)));
    if (sent.length !== 1) fail("⑤ 이전 임대분을 재전송했다");
    if (!readdirSync(queueDir).some((name) => name.startsWith(`${PARENT}.uncertain-`))) fail("⑤ 임대분이 uncertain 으로 옮겨지지 않았다");

    // ⑥ idle 확인 뒤·보내기 전에 새 턴이 열린다 → 끊지 않고 큐로 되돌린다
    sent.length = 0; replaced.length = 0;
    state[PARENT] = "running";
    await finish(CHILD2);
    if (sent.length !== 0) fail("⑥ 준비: 실행 중 부모에게 보냈다");
    onStorageGet = (id) => { if (id === PARENT) state[PARENT] = "running"; };   // 사람 전송이 막 턴을 열었다
    turnEnd(PARENT, "turn_completed");
    state[PARENT] = "idle"; emit(PARENT, { type: "agent_state", agent: { id: PARENT, lifecycle: "idle" } });
    await tick();
    if (replaced.length !== 0) fail(`⑥ drain 이 막 열린 턴을 끊었다 (replaceAgentRun ${replaced.length}회)`);
    if (sent.length !== 0) fail(`⑥ 바쁜 부모에게 보냈다 (sent=${sent.length})`);
    await until(() => existsSync(join(queueDir, `${PARENT}.jsonl`)) && !existsSync(join(queueDir, `${PARENT}.leased`)));
    if (!existsSync(join(queueDir, `${PARENT}.jsonl`))) fail("⑥ 거부된 알림이 큐로 돌아오지 않았다");
    if (existsSync(join(queueDir, `${PARENT}.leased`))) fail("⑥ 임대가 남았다 — 다음 기동에 uncertain 으로 버려진다");

    // ⑦ 그 턴 중에 알림이 하나 더 들어오고, 정상 완료 뒤 둘이 한 통으로 한 번 나간다
    await finish(CHILD1);
    turnEnd(PARENT, "turn_completed");
    setState(PARENT, "idle");
    await until(() => sent.length >= 1 && !existsSync(join(queueDir, `${PARENT}.leased`)));
    await tick();
    if (sent.length !== 1 || replaced.length !== 0) fail(`⑦ 정상 완료 뒤 배달 ${sent.length}통·끊음 ${replaced.length}회 (기대 1·0)`);
    if (!JSON.stringify(sent[0][1]).includes("2 queued child notifications")) fail("⑦ 되돌린 알림과 새 알림이 함께 나가지 않았다(유실)");
    setState(PARENT, "running"); turnEnd(PARENT, "turn_completed"); setState(PARENT, "idle"); await tick();
    if (sent.length !== 1) fail("⑦ 같은 알림이 다시 나갔다");

    cleanup();
    console.log("OK: idle 즉시 · running 큐(끊지 않음) · 취소 뒤 보류 · 정상 완료 뒤 1통 · 임대분 재전송 없음 · 경합 시 끊지 않고 되돌림 · 되돌린 알림 유실 없음");
    process.exit(0);
} catch (error) {
    console.error("FAIL: " + (error && error.stack ? error.stack : String(error)));
    cleanup();
    process.exit(1);
}
