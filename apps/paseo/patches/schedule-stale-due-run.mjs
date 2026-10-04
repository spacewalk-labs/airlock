// [paseo-schedule-stale-due] 실행 직전에 due 스냅샷을 **원자적으로 재검증**하고, tick 의 전체 재독을 한 번으로 줄인다.
//
// 대상: @getpaseo/server .../schedule/service.js (runSchedule · appendRunningRun · tick)
//       선행: schedule-busy-pending-delivery.mjs 가 **먼저** 적용돼 있어야 한다 (tick 을 이미 재작성했다).
//
// 문제 ①(중복 실행): tick 은 `setInterval(..., 1000)` 의 fire-and-forget 이라 **이전 tick 이 끝나기 전에
//   다음 tick 이 시작된다**(service.js 의 tickTimer). tick 은 `store.list()` 스냅샷으로 due 를 고르는데,
//   실행 직전에 그 스냅샷이 아직 유효한지 **재검증하지 않는다**. 스케줄 파일이 늘어 순회가 느려질수록
//   두 tick 이 같은 스케줄을 due 로 보고, `appendRunningRun` 이 **무조건** run 을 append 하므로
//   `maxRuns=1` 인데도 run 이 둘 생긴다.
//   실측(파일럿 박스, 2026-09-23): patrol-deliver 표본 415건 중 성공 run 2개가 21건, 실제 중복 수신 1건.
//   중복 run 은 session-delivery 의 영수증 판정을 `unavailable` 로 만든다(성공 run 2개 이상 = 불확실).
//
// 문제 ②(매초 전체 재독): tick 한 번이 `store.list()` 를 **두 번** 부른다. `list()` 는 디렉터리의
//   모든 JSON 을 읽고 파싱한다. 파일 2,760개면 초당 약 5,520회 readFile+parse 다.
//
// 처방:
//   · runSchedule 이 append 거부(null)를 받으면 **runner 를 부르지 않고 조용히 반환**한다.
//     없는 run 에 finishRun 을 부르지 않는다. busy/pending 의 의미는 건드리지 않는다.
//   · appendRunningRun 이 `store.update` 의 **원자 구간 안에서** 재검증한다 — 자동 실행은
//     status=active **AND** nextRunAt === runningRun.scheduledFor **AND** 그 시각에 만료·maxRuns
//     종료조건 미충족일 때만 append. 하나라도 어긋나면 append 하지 않고 null 을 반환한다.
//     manual(run-now)은 기존 의미 그대로 — 사람이 지금 보내라 한 것을 재검증으로 막지 않는다.
//   · 🔴 append 를 try 안으로 옮긴다. 0.8.0 은 append 가 try **밖**이라 append 가 던지면
//     `finally` 에 닿지 못해 `runningScheduleIds` 에 id 가 **영구히 남는다**(그 스케줄은 다시는 안 돈다).
//   · tick 의 두 번째 `store.list()` 를 첫 스냅샷 재사용으로 바꾼다.
//     🔴 이것은 ① 없이 단독으로 넣으면 **더 나쁘다** — 첫 순회에서 pending 을 실행하면 스냅샷이 낡고,
//     재사용이 잘못된 재실행을 허용한다. 그래서 둘은 **한 패치**이고 all-or-nothing 이다.
//
// 하지 않는 것: tick 전체 single-flight(무관한 스케줄까지 멈춘다) · 파싱 캐시/인메모리 인덱스
//   (생산자 쪽 상한·회수가 N 을 내리면 불필요하다).
//
// 계약: argv[2] = 대상 schedule/service.js. stdout 1줄 + exit code.
//   exit 10 = 이미 패치(sentinel) → skip · 20 = 앵커 없음/중복/선행패치 부재 → 아무것도 안 쓰고 skip
//        (20 의 stdout 은 `SKIP:` 로 시작한다 — drift 테스트의 negative 단언이 그 토큰을 본다)
//   exit  0 = <대상>.paseo-new.mjs 후보 기록(install.sh 가 node --check 후 mv) · 1 = 사용법/IO 오류
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-stale-due-run.mjs <schedule/service.js>"); process.exit(1); }

const SENTINEL = "[paseo-schedule-stale-due]";
// 선행 패치가 tick 을 재작성했다는 증거. 없으면 앵커가 원본 0.8.0 모양이라 이 패치의 전제가 깨진다.
const REQUIRES = "// [paseo-schedule-pending] pending 은 due 보다 먼저";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }
if (!src.includes(REQUIRES)) { console.log("SKIP:NO_ANCHOR:requires-schedule-busy-pending-delivery"); process.exit(20); }

// ── ① 거부를 받으면 실행하지 않는다 + append 를 try 안으로 ─────────────────────────────
const OLD_RUN = `        const scheduleWithRun = await this.appendRunningRun(schedule.id, runningRun);
        try {
            const result = await this.runner(scheduleWithRun, runId);`;
const NEW_RUN = `        try {
            // ${SENTINEL} append 는 try 안에 둔다 — 밖에 두면 append 가 던질 때 finally 에 닿지
            // 못해 runningScheduleIds 에 id 가 영구히 남고, 그 스케줄은 다시는 돌지 않는다.
            let scheduleWithRun;
            try {
                scheduleWithRun = await this.appendRunningRun(schedule.id, runningRun, manual);
            }
            catch (appendError) {
                // ${SENTINEL} append 가 던졌으면 이 run 은 **파일에 없다**. 바깥 catch 로 흘리면
                // 존재하지 않는 run 에 finishRun 을 불러 유령 run 을 만든다. 여기서 끝낸다.
                this.logger?.warn?.({ scheduleId: schedule.id, error: appendError instanceof Error ? appendError.message : String(appendError) }, "${SENTINEL} could not record run — skipping this tick");
                return;
            }
            if (!scheduleWithRun) {
                // ${SENTINEL} 재검증에서 거부됨 = 이 due 스냅샷은 이미 낡았다(다른 tick 이 먼저 돌았거나
                // pause/complete/만료로 갔다). 없는 run 에 finishRun 을 부르지 않고 조용히 물러난다.
                return;
            }
            const result = await this.runner(scheduleWithRun, runId);`;

// ── ② 원자 구간 안에서 재검증한다 ─────────────────────────────────────────────────────
const OLD_APPEND = `    async appendRunningRun(scheduleId, runningRun) {
        const updated = await this.store.update(scheduleId, (schedule) => ({
            ...schedule,
            updatedAt: runningRun.startedAt,
            runs: [...schedule.runs, runningRun],
        }));
        return requireSchedule(updated, scheduleId);
    }`;
const NEW_APPEND = `    // ${SENTINEL} tick 의 due 스냅샷은 실행 시점에 이미 낡았을 수 있다(재진입 tick). 파일을 쥔
    // 원자 구간 안에서 다시 보고, 어긋나면 append 하지 않는다 — 이것이 maxRuns 를 실제로 지키는 자리다.
    async appendRunningRun(scheduleId, runningRun, manual) {
        let appended = false;
        const updated = await this.store.update(scheduleId, (schedule) => {
            if (manual !== true) {
                const stale = schedule.status !== "active"
                    || schedule.nextRunAt !== runningRun.scheduledFor
                    || shouldCompleteSchedule(schedule, new Date(runningRun.startedAt));
                if (stale) {
                    return schedule;
                }
            }
            appended = true;
            return {
                ...schedule,
                updatedAt: runningRun.startedAt,
                runs: [...schedule.runs, runningRun],
            };
        });
        const existing = requireSchedule(updated, scheduleId);
        return appended ? existing : null;
    }`;

// ── ③ 같은 tick 에서 전체를 두 번 읽지 않는다 ─────────────────────────────────────────
const OLD_LIST = `        for (const schedule of await this.store.list()) {`;
const NEW_LIST = `        // ${SENTINEL} 같은 tick 에서 전체 디렉터리를 두 번 읽지 않는다. 위 pending 순회가 만든
        // 변화는 아래 ②의 원자 재검증이 잡는다 — 그래서 이 재사용은 ②와 한 몸이다.
        for (const schedule of schedules) {`;

const anchors = [
    ["run-append", OLD_RUN, NEW_RUN],
    ["append-revalidate", OLD_APPEND, NEW_APPEND],
    ["tick-single-list", OLD_LIST, NEW_LIST],
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
