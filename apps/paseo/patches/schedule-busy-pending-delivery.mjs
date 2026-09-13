// [paseo-schedule-pending] busy 인 좌석의 틱을 버리지 않고 **한 비트로 합쳐** idle 될 때 한 번 배달한다.
//
// 대상: @getpaseo/server .../schedule/service.js (executeSchedule · runSchedule · tick)
//       (짝: @getpaseo/protocol .../schedule/types.js 의 StoredScheduleSchema — 별도 패처
//        schedule-pending-delivery-schema.mjs. 스키마가 없으면 zod 가 필드를 벗겨 **재시작 뒤** 잊는다.
//        스키마만 있고 이 패치가 없으면 필드는 늘 false 라 무해하다. 그래서 순서 무관·부분 적용 안전.)
//
// 문제: agent 대상 schedule 이 발화할 때 좌석이 실행 중이면 `already has an active run` 으로 **run 을
//       실패로 기록하고 다음 cadence 로 넘어간다**(service.js executeSchedule). 그 틱은 영영 사라진다.
//   ① 실패 run 이 쌓여 `maxRuns` 를 갉아먹는다(countCompletedRuns 는 실패도 센다).
//   ② 총괄은 "시계를 받으려면 그 시각에 idle 이어야 한다"를 학습해 **일을 남긴 채 턴을 일찍 끝낸다**.
//      2026-09-13 파일럿 박스 실측: agent 대상 run 17건 중 5건(29%)이 정확히 이 오류. 어떤 총괄은
//      축자로 "시계가 실행 중인 턴에는 웨이크를 거부해, 08:55 첫 웨이크를 받도록 턴을 반환합니다"라고 썼다.
//
// 처방(합치기 = coalescing, 큐가 아니다):
//   · executeSchedule 이 busy 를 `ScheduleTargetBusyError` 로 구분해 던진다.
//   · runSchedule 이 그 오류를 잡으면 **실패 run 을 남기지 않는다** — 방금 append 한 running run 을 지우고
//     `pendingAgentDelivery: true` 만 세운 뒤 nextRunAt 을 다음 cadence 로 전진시킨다. maxRuns 소모 없음.
//   · 추가 due 가 또 busy 면 같은 비트에 합쳐진다(최대 1건 — 밀린 틱이 폭주하지 않는다).
//   · tick 이 매번 pending 을 먼저 본다. due 가 아니어도 좌석이 idle 이면 그때 **정확히 한 번** 실행한다.
//   · 실행 직전 비트를 지우고(claim) 다시 busy 면 비트를 되돌린다.
//   · pause 는 비트를 보존하고 drain 하지 않는다(resume 뒤 다음 tick 에 나간다). complete/expiry 는 비트를 지운다.
//   · 수동 run-now(manual)의 busy 는 그대로 오류다 — 사람이 지금 보내라고 한 것을 나중으로 미루지 않는다.
//
// 계약: argv[2] = 대상 schedule/service.js. stdout 1줄 + exit code.
//   exit 10 = 이미 패치(sentinel) → skip · 20 = 앵커 없음/중복(상류 drift) → 아무것도 안 쓰고 skip
//   exit  0 = <대상>.paseo-new.mjs 후보 기록(install.sh 가 node --check 후 mv) · 1 = 사용법/IO 오류
// all-or-nothing: 앵커 넷이 **모두** 정확히 1회일 때만 적용한다. 반쪽 적용은 pending 을 세우고
//   아무도 소비하지 않는 상태(= 조용한 틱 유실)를 만들 수 있어 지금보다 나쁘다.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-busy-pending-delivery.mjs <schedule/service.js>"); process.exit(1); }

const SENTINEL = "[paseo-schedule-pending]";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

// ── ① busy 를 구분되는 오류로 던진다 ────────────────────────────────────────────────
const OLD_BUSY_THROW = `            if (this.agentManager.hasInFlightRun(agent.id)) {
                throw new Error(\`Agent \${agent.id} already has an active run\`);
            }`;
const NEW_BUSY_THROW = `            if (this.agentManager.hasInFlightRun(agent.id)) {
                // ${SENTINEL} busy 는 실패가 아니라 "나중에" 다. runSchedule 이 pending 비트로 합친다.
                const busy = new Error(\`Agent \${agent.id} already has an active run\`);
                busy.paseoScheduleTargetBusy = true;
                throw busy;
            }`;

// ── ② runSchedule 의 catch 에서 busy 를 pending 으로 접는다 ─────────────────────────
const OLD_CATCH = `        catch (error) {
            await this.finishRun({
                scheduleId: schedule.id,
                runId,
                status: "failed",
                agentId: null,
                output: null,
                error: error instanceof Error ? error.message : String(error),
                targetGone: error instanceof ScheduleTargetGoneError,
                manual,
            });
        }`;
const NEW_CATCH = `        catch (error) {
            // ${SENTINEL} 좌석이 실행 중이어서 못 보낸 것은 실패가 아니다 — 실패 run 을 남기면
            // maxRuns 를 갉고, 총괄에게 "그 시각에 idle 이어야 시계를 받는다"를 가르친다.
            if (error && error.paseoScheduleTargetBusy === true && !manual) {
                await this.deferBusyRun(schedule, runId);
            }
            else {
                await this.finishRun({
                    scheduleId: schedule.id,
                    runId,
                    status: "failed",
                    agentId: null,
                    output: null,
                    error: error instanceof Error ? error.message : String(error),
                    targetGone: error instanceof ScheduleTargetGoneError,
                    manual,
                });
            }
        }`;

// ── ③ pending 을 접는 헬퍼 + tick 이 pending 을 먼저 소비 ───────────────────────────
const OLD_TICK = `    async tick() {
        const now = this.now();
        const schedules = await this.store.list();
        for (const schedule of schedules) {
            if (schedule.status !== "active" || !schedule.nextRunAt) {
                continue;
            }
            if (this.runningScheduleIds.has(schedule.id)) {
                continue;
            }`;
const NEW_TICK = `    // ${SENTINEL} busy 로 못 보낸 틱을 **한 비트**로 접는다. 실패 run 도, 밀린 큐도 만들지 않는다.
    async deferBusyRun(schedule, runId) {
        const now = this.now();
        const updated = await this.store.update(schedule.id, (current) => {
            const runs = current.runs.filter((run) => run.id !== runId);
            if (current.status !== "active") {
                // pause/complete 로 간 사이라면 비트를 세우지 않는다 — 나중에 유령 배달이 된다.
                return { ...current, runs, updatedAt: now.toISOString() };
            }
            const after = new Date(current.nextRunAt ?? now.toISOString());
            let nextRunAt = computeNextRunAt(current.cadence, after);
            while (nextRunAt.getTime() <= now.getTime()) {
                nextRunAt = computeNextRunAt(current.cadence, nextRunAt);
            }
            return {
                ...current,
                runs,
                pendingAgentDelivery: true,
                nextRunAt: nextRunAt.toISOString(),
                updatedAt: now.toISOString(),
            };
        });
        requireSchedule(updated, schedule.id);
        this.logger?.info?.({ scheduleId: schedule.id }, "${SENTINEL} target busy — delivery pending until idle");
    }
    // 실행 직전에 비트를 지운다(claim). 다시 busy 면 catch 가 같은 비트를 되세운다.
    async claimPendingDelivery(scheduleId) {
        let claimed = false;
        await this.store.update(scheduleId, (current) => {
            if (current.pendingAgentDelivery !== true || current.status !== "active") {
                return current;
            }
            claimed = true;
            return { ...current, pendingAgentDelivery: false, updatedAt: this.now().toISOString() };
        });
        return claimed;
    }
    async tick() {
        const now = this.now();
        const schedules = await this.store.list();
        // ${SENTINEL} pending 은 due 보다 먼저, due 여부와 무관하게 본다 — 좌석이 idle 이 된 그 순간이 배달 시점이다.
        for (const schedule of schedules) {
            if (schedule.pendingAgentDelivery !== true || schedule.status !== "active") {
                continue;
            }
            if (this.runningScheduleIds.has(schedule.id) || shouldCompleteSchedule(schedule, now)) {
                continue;
            }
            if (schedule.target.type !== "agent" || this.agentManager.hasInFlightRun(schedule.target.agentId)) {
                continue;
            }
            if (await this.claimPendingDelivery(schedule.id)) {
                await this.runSchedule({ ...schedule, pendingAgentDelivery: false }, now);
            }
        }
        for (const schedule of await this.store.list()) {
            if (schedule.status !== "active" || !schedule.nextRunAt) {
                continue;
            }
            if (this.runningScheduleIds.has(schedule.id)) {
                continue;
            }`;

// ── ④ 종료·만료는 비트를 지운다 (유령 배달 금지) ────────────────────────────────────
const OLD_COMPLETE = `function completeSchedule(schedule, now) {`;
const NEW_COMPLETE = `function completeSchedule(schedule, now) {
    // ${SENTINEL} 끝난 schedule 의 pending 은 배달되지 않는다 — 비트를 남기면 재시작 뒤 유령이 된다.
    schedule = { ...schedule, pendingAgentDelivery: false };`;

const anchors = [
    ["busy-throw", OLD_BUSY_THROW, NEW_BUSY_THROW],
    ["run-catch", OLD_CATCH, NEW_CATCH],
    ["tick", OLD_TICK, NEW_TICK],
    ["complete", OLD_COMPLETE, NEW_COMPLETE],
];

const missing = anchors.filter(([, oldText]) => !src.includes(oldText)).map(([name]) => name);
if (missing.length) { console.log("NO_ANCHOR:" + missing.join(",")); process.exit(20); }
const ambiguous = anchors
    .filter(([, oldText]) => src.split(oldText).length - 1 !== 1)
    .map(([name]) => name);
if (ambiguous.length) { console.log("AMBIGUOUS:" + ambiguous.join(",")); process.exit(20); }

let out = src;
for (const [, oldText, newText] of anchors) out = out.replace(oldText, newText);

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("write 실패: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
