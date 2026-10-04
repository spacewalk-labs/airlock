// [paseo-schedule-pending-batch] 같은 좌석의 pending 을 **한 턴에 묶어** 배달한다.
//
// 대상: @getpaseo/server .../schedule/service.js (claimPendingDelivery · tick 의 pending·due 순회)
//       선행: schedule-busy-pending-delivery.mjs → schedule-stale-due-run.mjs 가 **먼저** 적용돼 있어야 한다
//       (앵커가 그 둘의 산출물이고, append 재검증·null 반환을 그대로 쓴다).
//
// 문제 ①(턴당 1통): busy-pending 은 schedule **하나** 의 밀린 틱을 한 비트로 접는다. 그런데 session-delivery 는
//   메시지마다 one-shot schedule 을 만든다. 좌석이 idle 이 되면 tick 은 pending 하나를 실행하고, 그 run 은
//   수신 턴이 끝날 때까지 hasInFlightRun 을 잡으므로 **나머지는 다음 턴을 기다린다**. 턴이 10~20분이면
//   N통이 N턴, 수 시간이 된다. 실측(파일럿 박스 2026-10-03): 한 좌석에 동시 대기 15건, 다른 좌석 6건,
//   배달 지연 p50 1.3~2.3시간대.
// 문제 ②(비트 유실): pending 순회는 tick 시작 스냅샷으로 runSchedule 을 부른다. claim 이 비트를 지운 뒤
//   append 재검증이 거부(null)하면 runSchedule 은 조용히 return 하고 비트는 이미 없다 — 그 schedule 은
//   다음 cadence(배달 schedule 은 매시 정각)까지 선다.
//
// 처방:
//   · claimPendingDelivery 가 boolean 대신 **claim 직후의 레코드**를 돌려준다 — 실행은 낡은 스냅샷이 아니라
//     그 레코드로 한다(②의 주원인 제거).
//   · tick 은 idle 좌석의 pending 을 좌석별로 모은다(store.list() 순서 = createdAt 오름차순 유지).
//   · 좌석마다 runPendingBatch: 각자 claim·append(재검증). 거부되면 그 schedule 만 비트를 되세운다(②).
//     남은 것이 하나면 그 schedule 그대로, 여럿이면 각 fire body 를 이어 붙인 프롬프트로 **runner 한 번**.
//     결과는 각자의 run 에 기록한다 — schedule 마다 run 은 여전히 하나다.
//   · busy 로 되던져지면 각자 deferBusyRun(비트 복귀), 그 밖 오류는 각자 failed run.
//
// 하지 않는 것: 큐·영수증 서비스·steer 주입 · due(정각) 경로 변경 · manual run-now 의미 변경.
//
// 계약: argv[2] = 대상 schedule/service.js. stdout 1줄 + exit code.
//   exit 10 = 이미 패치(sentinel) → skip · 20 = 앵커 없음/중복/선행패치 부재 → 아무것도 안 쓰고 skip
//        (20 의 stdout 은 `SKIP:` 로 시작한다 — drift 테스트의 negative 단언이 그 토큰을 본다)
//   exit  0 = <대상>.paseo-new.mjs 후보 기록(install.sh 가 node --check·행동검사 후 mv) · 1 = 사용법/IO 오류
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-pending-batch.mjs <schedule/service.js>"); process.exit(1); }

const SENTINEL = "[paseo-schedule-pending-batch]";
// 선행 패치 둘이 적용됐다는 증거. 없으면 이 패치의 전제(재검증 append·pending 순회)가 깨진다.
const REQUIRES = ["// [paseo-schedule-pending] pending 은 due 보다 먼저", "return appended ? existing : null;"];

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }
if (!REQUIRES.every((text) => src.includes(text))) {
    console.log("SKIP:NO_ANCHOR:requires-schedule-busy-pending-delivery+schedule-stale-due-run");
    process.exit(20);
}

// ── ① claim 이 레코드를 돌려주고, 묶음 실행·비트 복원 헬퍼 ──────────────────────────────
const OLD_CLAIM = `    async claimPendingDelivery(scheduleId) {
        let claimed = false;
        await this.store.update(scheduleId, (current) => {
            if (current.pendingAgentDelivery !== true || current.status !== "active") {
                return current;
            }
            claimed = true;
            return { ...current, pendingAgentDelivery: false, updatedAt: this.now().toISOString() };
        });
        return claimed;
    }`;
const NEW_CLAIM = `    // ${SENTINEL} claim 직후의 레코드를 돌려준다 — 실행은 tick 시작 스냅샷이 아니라 이것으로 한다.
    async claimPendingDelivery(scheduleId) {
        let claimed = null;
        await this.store.update(scheduleId, (current) => {
            if (current.pendingAgentDelivery !== true || current.status !== "active") {
                return current;
            }
            claimed = { ...current, pendingAgentDelivery: false, updatedAt: this.now().toISOString() };
            return claimed;
        });
        return claimed;
    }
    // ${SENTINEL} claim 뒤 append 가 거부되면 비트를 되세운다 — 안 그러면 다음 cadence(정각)까지 선다.
    async restorePendingDelivery(scheduleId) {
        await this.store.update(scheduleId, (current) => current.status === "active"
            ? { ...current, pendingAgentDelivery: true, updatedAt: this.now().toISOString() }
            : current);
    }
    // ${SENTINEL} 한 좌석의 pending 을 한 턴에. schedule 마다 자기 run 하나는 그대로다.
    // 한 건의 기록 오류(복원·결과 저장·실행 중 삭제)가 나머지 건의 배달·영수증·잠금 해제를 막지 않는다.
    async runPendingBatch(claimed, now) {
        const runs = [];
        try {
            for (const schedule of claimed) {
                this.runningScheduleIds.add(schedule.id);
                const runId = randomUUID();
                const runningRun = {
                    id: runId,
                    scheduledFor: schedule.nextRunAt ?? now.toISOString(),
                    startedAt: now.toISOString(),
                    endedAt: null,
                    status: "running",
                    agentId: null,
                    output: null,
                    error: null,
                };
                let scheduleWithRun = null;
                try {
                    scheduleWithRun = await this.appendRunningRun(schedule.id, runningRun, false);
                }
                catch (appendError) {
                    this.logger?.warn?.({ scheduleId: schedule.id, error: appendError instanceof Error ? appendError.message : String(appendError) }, "${SENTINEL} could not record run — pending kept");
                }
                if (scheduleWithRun) {
                    runs.push({ schedule: scheduleWithRun, runId });
                    continue;
                }
                try {
                    await this.restorePendingDelivery(schedule.id);
                }
                catch (restoreError) {
                    this.logger?.warn?.({ scheduleId: schedule.id, error: restoreError instanceof Error ? restoreError.message : String(restoreError) }, "${SENTINEL} could not restore pending bit");
                }
            }
            if (runs.length === 0) {
                return;
            }
            const lead = runs[0];
            const fired = runs.length === 1 ? lead.schedule : {
                ...lead.schedule,
                name: \`\${runs.length} pending deliveries\`,
                prompt: runs.map((run) => buildScheduleFireBody(run.schedule, run.runId)).join("\\n\\n"),
            };
            let result = null;
            let runError = null;
            try {
                result = await this.runner(fired, lead.runId);
            }
            catch (error) {
                runError = error;
            }
            for (const run of runs) {
                try {
                    if (!runError) {
                        await this.finishRun({
                            scheduleId: run.schedule.id,
                            runId: run.runId,
                            status: "succeeded",
                            agentId: result.agentId,
                            output: result.output,
                            error: null,
                            targetGone: false,
                            manual: false,
                        });
                    }
                    else if (runError.paseoScheduleTargetBusy === true) {
                        await this.deferBusyRun(run.schedule, run.runId);
                    }
                    else {
                        await this.finishRun({
                            scheduleId: run.schedule.id,
                            runId: run.runId,
                            status: "failed",
                            agentId: null,
                            output: null,
                            error: runError instanceof Error ? runError.message : String(runError),
                            targetGone: runError instanceof ScheduleTargetGoneError,
                            manual: false,
                        });
                    }
                }
                catch (recordError) {
                    // 그 schedule 이 실행 중 삭제됐거나 저장이 실패했다 — 그 건만 남기고 나머지 결과는 계속 기록한다.
                    this.logger?.warn?.({ scheduleId: run.schedule.id, error: recordError instanceof Error ? recordError.message : String(recordError) }, "${SENTINEL} could not record run result");
                }
            }
        }
        finally {
            for (const schedule of claimed) {
                this.runningScheduleIds.delete(schedule.id);
            }
        }
    }`;

// ── ② tick 의 pending 순회: 좌석별로 모아 한 번에 ──────────────────────────────────────
const OLD_LOOP = `            if (schedule.target.type !== "agent" || this.agentManager.hasInFlightRun(schedule.target.agentId)) {
                continue;
            }
            if (await this.claimPendingDelivery(schedule.id)) {
                await this.runSchedule({ ...schedule, pendingAgentDelivery: false }, now);
            }
        }`;
const NEW_LOOP = `            if (schedule.target.type !== "agent" || this.agentManager.hasInFlightRun(schedule.target.agentId)) {
                continue;
            }
            // ${SENTINEL} 바로 실행하지 않고 좌석별로 모은다 — 하나를 실행하면 그 턴 동안 나머지가 막힌다.
            const group = pendingByAgent.get(schedule.target.agentId) ?? [];
            group.push(schedule);
            pendingByAgent.set(schedule.target.agentId, group);
        }
        for (const group of pendingByAgent.values()) {
            const agentId = group[0].target.agentId;
            // tick 은 겹쳐 돈다(setInterval fire-and-forget). 한 좌석의 묶음은 claim 부터 배달 끝까지 한 tick 이
            // 소유한다 — 안 그러면 겹친 tick 이 남은 건을 먼저 보내 묶음이 갈리고 순서가 뒤집힌다.
            if (this.agentManager.hasInFlightRun(agentId) || this.pendingBatchAgents?.has(agentId)) {
                continue;
            }
            (this.pendingBatchAgents ??= new Set()).add(agentId);
            try {
            const claimed = [];
            for (const schedule of group) {
                // 한 건의 claim 저장 오류가 앞서 claim 한 건을 버려두지 않게 — 그 건만 건너뛴다(비트는 디스크에 남아 다음 tick).
                try {
                    const fresh = await this.claimPendingDelivery(schedule.id);
                    if (fresh) {
                        claimed.push(fresh);
                    }
                }
                catch (claimError) {
                    this.logger?.warn?.({ scheduleId: schedule.id, error: claimError instanceof Error ? claimError.message : String(claimError) }, "${SENTINEL} could not claim pending delivery");
                }
            }
            if (claimed.length > 0) {
                await this.runPendingBatch(claimed, now);
            }
            }
            finally {
                this.pendingBatchAgents.delete(agentId);
            }
        }`;

// 순회 직전에 모음 그릇을 선언한다 — pending 순회의 머리 주석 바로 뒤.
const OLD_HEAD = `        // [paseo-schedule-pending] pending 은 due 보다 먼저, due 여부와 무관하게 본다 — 좌석이 idle 이 된 그 순간이 배달 시점이다.
        for (const schedule of schedules) {
            if (schedule.pendingAgentDelivery !== true || schedule.status !== "active") {`;
const NEW_HEAD = `        // [paseo-schedule-pending] pending 은 due 보다 먼저, due 여부와 무관하게 본다 — 좌석이 idle 이 된 그 순간이 배달 시점이다.
        const pendingByAgent = new Map(); // ${SENTINEL}
        for (const schedule of schedules) {
            if (schedule.pendingAgentDelivery !== true || schedule.status !== "active") {`;

// ── ③ due 순회도 묶음 소유 중인 좌석을 건너뛴다 ──────────────────────────────────────
// 겹친 tick 의 due 경로가 claim 중인 좌석의 건(이미 claim 됐거나 아직 pending 인 것)을 먼저 보내면
// 묶음이 갈리고 순서가 뒤집힌다. 소유가 풀리면(배달 끝) 다음 tick 이 평소대로 본다.
const OLD_DUE = `        for (const schedule of schedules) {
            if (schedule.status !== "active" || !schedule.nextRunAt) {
                continue;
            }
            if (this.runningScheduleIds.has(schedule.id)) {
                continue;
            }`;
const NEW_DUE = `        for (const schedule of schedules) {
            if (schedule.status !== "active" || !schedule.nextRunAt) {
                continue;
            }
            if (this.runningScheduleIds.has(schedule.id)) {
                continue;
            }
            if (schedule.target.type === "agent" && this.pendingBatchAgents?.has(schedule.target.agentId)) {
                continue; // ${SENTINEL}
            }`;

const anchors = [
    ["claim", OLD_CLAIM, NEW_CLAIM],
    ["due-skip-owned-seat", OLD_DUE, NEW_DUE],
    ["pending-head", OLD_HEAD, NEW_HEAD],
    ["pending-loop", OLD_LOOP, NEW_LOOP],
];

const missing = anchors.filter(([, oldText]) => !src.includes(oldText)).map(([name]) => name);
if (missing.length) { console.log("SKIP:NO_ANCHOR:" + missing.join(",")); process.exit(20); }
const ambiguous = anchors
    .filter(([, oldText]) => src.split(oldText).length - 1 !== 1)
    .map(([name]) => name);
if (ambiguous.length) { console.log("SKIP:AMBIGUOUS:" + ambiguous.join(",")); process.exit(20); }

let out = src;
for (const [, oldText, newText] of anchors) out = out.replace(oldText, newText);

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("write 실패: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
