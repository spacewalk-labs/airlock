// [paseo-finish-queue] 자식 좌석의 완료 알림이 부모의 **진행 중 턴을 끊지 않게** 줄 세운다.
//
// 대상: @getpaseo/server .../agent/agent-prompt.js (setupFinishNotification 의 notify)
//
// 문제: notifyOnFinish 알림은 guard 없는 sendPromptToAgent → replaceRunning:true → turn/interrupt 경로를
//       탄다. 부모(총괄)가 도구를 돌리는 중이면 그 턴이 잘리고 알림이 새 턴을 연다. 파일럿 박스 실측
//       (2026-09-13): 총괄 전사에서 turn_aborted 직후 1초 안에 finish 알림이 새 턴을 연 경우가 다수 —
//       총괄은 "긴 턴은 손해"를 배우고 턴을 짧게 끊는다.
//
// 처방 (알림만 바꾼다 — 사람·에이전트 직접 프롬프트의 교체 정책은 그대로):
//   · 부모가 idle 이면 지금처럼 즉시 보낸다.
//   · 부모가 실행 중이면 **보내지 않고 durable 큐**(<paseoHome>/finish-notify-queue/<parent>.jsonl)에 쌓는다.
//     큐 기록이 실패하면 interrupt 로 되돌아가지 않는다 — 알림을 버리고 error 로그를 남긴다(끊지 않는 쪽을 택한다).
//   · 부모별 drainer 하나가 부모 상태를 구독한다. 부모 턴이 **정상 완료**(turn_completed)로 idle 이 되면 쌓인 알림을
//     한 통으로 묶어 한 번 보낸다. 취소·실패로 끝난 idle 에서는 drain 하지 않는다 — 사람이 끊었을 수 있다.
//     그 뒤 정상 완료가 오면 그때 나간다.
//   · 배달은 **끊지 않는 경로로만**(replaceRunning:false). idle 확인 뒤 보내기 전에 다른 전송이 턴을 열었으면
//     거부되고 큐로 돌아가 그 턴의 정상 완료 뒤 나간다. (v1 은 여기서 replaceRunning:true 로 그 턴을 끊었다 — v2 가 고침,
//     v1 적용본은 drain 꼬리만 교체해 업그레이드한다.)
//   · 전달은 임대(.leased) → 보냄 → 삭제(ack). 보내다 죽어 임대가 남으면 다음 기동 때 **재전송하지 않고**
//     .uncertain 으로 옮겨 로그만 남긴다(중복 금지).
//   · 데몬 재시작 뒤 복구: 같은 부모에게 새 알림 구독이 걸리는 순간(= 부모가 자식을 또 부릴 때) drainer 가
//     다시 서고 기존 큐를 이어받는다. 총괄은 자식을 계속 부리므로 곧 복구된다(잔여 위험은 README).
//
// 계약: argv[2] = 대상 agent-prompt.js. exit 10 이미 적용(v2) · 20 앵커 없음/중복 · 0 후보 기록(신규 또는 v1→v2) · 1 IO 오류.
// all-or-nothing: 앵커 둘이 모두 정확히 1회일 때만.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: finish-notification-queue.mjs <agent/agent-prompt.js>"); process.exit(1); }
const SENTINEL = "[paseo-finish-queue]";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

// v2 (drain-no-replace): v1 의 drain 은 kick() 의 idle 확인 뒤 **replaceRunning:true** 로 보냈다. 그 사이(큐 파일
// rename·read 몇 ms)에 사람·에이전트 전송이 새 턴을 열면 알림이 그 턴을 끊었다 — 이 패치가 막으려던 바로 그 동작.
// v2 는 끊지 않는 경로(startAgentRun replaceRunning:false → 바쁘면 streamAgent 가 거부)로만 보내고, 거부되면
// 큐로 되돌린다. 되돌림은 read-then-write 가 아니라 append 라서 그 사이 들어온 알림을 덮어쓰지 않고, 묶을 때
// `at` 순으로 정렬한다. v1 이 이미 적용된 파일은 이 꼬리만 갈아 끼운다(업그레이드) — 그래서 rc=10 판정은
// SENTINEL 이 아니라 DRAIN_MARK 로 한다.
const DRAIN_MARK = "[paseo-finish-queue:drain-no-replace]";
const DRAIN_TAIL_V1 = `    const bodies = text.split("\\n").filter(Boolean).map((line) => {
        try { return JSON.parse(line).body; } catch { return null; }
    }).filter((body) => typeof body === "string" && body.length > 0);
    if (bodies.length === 0) {
        await finishQueueFs.rm(leased, { force: true });
        return;
    }
    const combined = bodies.length === 1
        ? bodies[0]
        : \`\${bodies.length} queued child notifications (held while this agent was running):\\n\\n\` + bodies.join("\\n\\n---\\n\\n");
    try {
        await sendPromptToAgent({
            agentManager,
            agentStorage,
            agentId: callerAgentId,
            prompt: formatSystemNotificationPrompt(combined),
            unarchive: false,
            logger,
        });
        await finishQueueFs.rm(leased, { force: true });
    }
    catch (error) {
        // 보내기 자체가 실패 — 큐 앞으로 되돌려 다음 정상 완료에 다시 시도한다.
        const rest = await finishQueueFs.readFile(queued, "utf8").catch(() => "");
        await finishQueueFs.writeFile(queued, text + rest, { mode: 0o600 });
        await finishQueueFs.rm(leased, { force: true });
        logger.error({ err: error, callerAgentId }, "[paseo-finish-queue] draining finish notifications failed; requeued");
    }
}`;
const DRAIN_TAIL_V2 = `    const rows = text.split("\\n").filter(Boolean).map((line) => {
        try { return JSON.parse(line); } catch { return null; }
    }).filter((row) => row && typeof row.body === "string" && row.body.length > 0);
    rows.sort((a, b) => String(a.at).localeCompare(String(b.at)));
    const bodies = rows.map((row) => row.body);
    if (bodies.length === 0) {
        await finishQueueFs.rm(leased, { force: true });
        return;
    }
    const combined = bodies.length === 1
        ? bodies[0]
        : \`\${bodies.length} queued child notifications (held while this agent was running):\\n\\n\` + bodies.join("\\n\\n---\\n\\n");
    try {
        // ${DRAIN_MARK} 끊지 않는 경로로만 보낸다. kick() 뒤에 새 턴이 열렸으면 streamAgent 가
        // "already has an active run" 으로 거부하고, 알림은 큐로 돌아가 그 턴이 정상 완료된 뒤 나간다.
        const record = await agentStorage.get(callerAgentId);
        if (record?.archivedAt) {
            await finishQueueFs.rm(leased, { force: true });
            return;
        }
        await ensureAgentLoaded(callerAgentId, { agentManager, agentStorage, logger });
        await startAgentRun(agentManager, callerAgentId, formatSystemNotificationPrompt(combined), logger, { replaceRunning: false });
        await finishQueueFs.rm(leased, { force: true });
    }
    catch (error) {
        // append 로 되돌린다 — read-then-write 는 그 사이 enqueue 된 알림을 덮어쓴다. 순서는 drain 때 at 으로 복원한다.
        await finishQueueFs.appendFile(queued, text, { mode: 0o600 });
        await finishQueueFs.rm(leased, { force: true });
        if (/already has an active run/.test(String(error?.message ?? ""))) {
            logger.info({ callerAgentId }, "${SENTINEL} caller started a new run during drain — requeued, not interrupted");
        }
        else {
            logger.error({ err: error, callerAgentId }, "${SENTINEL} draining finish notifications failed; requeued");
        }
    }
}`;

const OLD_IMPORT = `import { getParentAgentIdFromLabels } from "@getpaseo/protocol/agent-labels";`;
const NEW_IMPORT = `import { getParentAgentIdFromLabels } from "@getpaseo/protocol/agent-labels";
// ${SENTINEL} durable per-parent queue for finish notifications
import { promises as finishQueueFs } from "node:fs";
import finishQueuePath from "node:path";
const FINISH_QUEUE_DRAINERS = new Map();
function finishQueueDir(agentStorage) {
    const base = agentStorage && typeof agentStorage.baseDir === "string" ? agentStorage.baseDir : null;
    if (!base) {
        return null;
    }
    return finishQueuePath.join(finishQueuePath.dirname(base), "finish-notify-queue");
}
function finishQueueFile(dir, agentId, suffix) {
    return finishQueuePath.join(dir, \`\${agentId}.\${suffix}\`);
}
async function enqueueFinishNotification({ agentStorage, callerAgentId, body }) {
    const dir = finishQueueDir(agentStorage);
    if (!dir) {
        throw new Error("finish queue directory unavailable");
    }
    await finishQueueFs.mkdir(dir, { recursive: true, mode: 0o700 });
    const row = JSON.stringify({ at: new Date().toISOString(), body }) + "\\n";
    await finishQueueFs.appendFile(finishQueueFile(dir, callerAgentId, "jsonl"), row, { mode: 0o600 });
}
async function drainFinishQueue({ agentManager, agentStorage, callerAgentId, logger }) {
    const dir = finishQueueDir(agentStorage);
    if (!dir) {
        return;
    }
    const queued = finishQueueFile(dir, callerAgentId, "jsonl");
    const leased = finishQueueFile(dir, callerAgentId, "leased");
    try {
        // 이전 기동에서 보내다 죽은 임대분은 다시 보내지 않는다 — 중복보다 명시적 유실이 낫다.
        await finishQueueFs.rename(leased, finishQueueFile(dir, callerAgentId, \`uncertain-\${Date.now()}\`));
        logger.warn({ callerAgentId }, "${SENTINEL} leased finish notifications from a previous run marked uncertain (not re-sent)");
    }
    catch (error) {
        if (error?.code !== "ENOENT") {
            logger.warn({ err: error, callerAgentId }, "${SENTINEL} could not inspect leased finish notifications");
        }
    }
    try {
        await finishQueueFs.rename(queued, leased);
    }
    catch (error) {
        if (error?.code !== "ENOENT") {
            logger.error({ err: error, callerAgentId }, "${SENTINEL} could not lease queued finish notifications");
        }
        return;
    }
    const text = await finishQueueFs.readFile(leased, "utf8");
${DRAIN_TAIL_V2}
function ensureFinishQueueDrainer({ agentManager, agentStorage, callerAgentId, logger }) {
    if (FINISH_QUEUE_DRAINERS.has(callerAgentId)) {
        return;
    }
    let lastTerminal = null;
    let draining = false;
    const kick = () => {
        if (draining || agentManager.hasInFlightRun(callerAgentId)) {
            return;
        }
        draining = true;
        void drainFinishQueue({ agentManager, agentStorage, callerAgentId, logger })
            .catch((error) => logger.error({ err: error, callerAgentId }, "${SENTINEL} drain crashed"))
            .finally(() => { draining = false; });
    };
    const unsubscribe = agentManager.subscribe((event) => {
        if (event.type === "agent_state") {
            if (event.agent.lifecycle === "closed") {
                FINISH_QUEUE_DRAINERS.get(callerAgentId)?.();
                FINISH_QUEUE_DRAINERS.delete(callerAgentId);
                return;
            }
            // 정상 완료로 idle 이 된 때만 내보낸다. 취소·실패 뒤 idle 은 사람이 끊었을 수 있다.
            if (event.agent.lifecycle === "idle" && lastTerminal === "turn_completed") {
                kick();
            }
            return;
        }
        const type = event.event?.type;
        if (type === "turn_completed" || type === "turn_canceled" || type === "turn_failed") {
            lastTerminal = type;
        }
    }, { agentId: callerAgentId, replayState: false });
    FINISH_QUEUE_DRAINERS.set(callerAgentId, unsubscribe);
    // 재시작 복구: 이미 idle 이고 큐가 남아 있으면 지금 한 번 시도한다(임대분은 uncertain 처리).
    const snapshot = agentManager.getAgent(callerAgentId);
    if (snapshot && snapshot.lifecycle === "idle") {
        kick();
    }
}`;

const OLD_SEND = `        await sendPromptToAgent({
            agentManager,
            agentStorage,
            agentId: callerAgentId,
            prompt: formatSystemNotificationPrompt(body),
            unarchive: false,
            logger,
        });
    }
    function notifySafely(reason) {`;
const NEW_SEND = `        // ${SENTINEL} 부모가 실행 중이면 끊지 않고 줄 세운다. 큐가 실패해도 interrupt 로 되돌아가지 않는다.
        if (agentManager.hasInFlightRun(callerAgentId)) {
            try {
                await enqueueFinishNotification({ agentStorage, callerAgentId, body });
                ensureFinishQueueDrainer({ agentManager, agentStorage, callerAgentId, logger });
                logger.info({ childAgentId, callerAgentId, reason }, "${SENTINEL} caller running — finish notification queued");
            }
            catch (error) {
                logger.error({ err: error, childAgentId, callerAgentId, reason }, "${SENTINEL} could not queue finish notification; dropped instead of interrupting");
            }
            return;
        }
        await sendPromptToAgent({
            agentManager,
            agentStorage,
            agentId: callerAgentId,
            prompt: formatSystemNotificationPrompt(body),
            unarchive: false,
            logger,
        });
    }
    // ${SENTINEL} 재시작 뒤에도 이 부모의 남은 큐를 이어받는다.
    try {
        ensureFinishQueueDrainer({ agentManager, agentStorage, callerAgentId, logger });
    }
    catch (error) {
        logger.warn({ err: error, callerAgentId }, "${SENTINEL} could not attach finish queue drainer");
    }
    function notifySafely(reason) {`;

if (src.includes(DRAIN_MARK)) { console.log("ALREADY"); process.exit(10); }
if (src.includes(SENTINEL)) {
    // v1 적용본 → drain 꼬리만 v2 로 교체. 앵커가 없거나 중복이면 손대지 않는다(20).
    const n = src.split(DRAIN_TAIL_V1).length - 1;
    if (n !== 1) { console.log(n === 0 ? "NO_ANCHOR:v1-drain-tail" : "AMBIGUOUS:v1-drain-tail"); process.exit(20); }
    try { fs.writeFileSync(F + ".paseo-new.mjs", src.replace(DRAIN_TAIL_V1, DRAIN_TAIL_V2)); }
    catch (err) { console.error("write 실패: " + String(err)); process.exit(1); }
    console.log("UPGRADED:v1->v2");
    process.exit(0);
}
const anchors = [["import", OLD_IMPORT, NEW_IMPORT], ["notify-send", OLD_SEND, NEW_SEND]];
const missing = anchors.filter(([, o]) => !src.includes(o)).map(([n]) => n);
if (missing.length) { console.log("NO_ANCHOR:" + missing.join(",")); process.exit(20); }
const ambiguous = anchors.filter(([, o]) => src.split(o).length - 1 !== 1).map(([n]) => n);
if (ambiguous.length) { console.log("AMBIGUOUS:" + ambiguous.join(",")); process.exit(20); }
let out = src;
for (const [, o, n] of anchors) out = out.replace(o, n);
try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("write 실패: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
