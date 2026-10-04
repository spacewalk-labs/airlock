// [paseo-watch-recovery] 강등된 working-tree 감시가 **영구 5초 폴링**이 되지 않게 한다 — 상류 #3056 이식.
//
// 대상: @getpaseo/server .../server/workspace-git-service.js
// 상류: getpaseo/paseo 8ffe7c75d "Keep the daemon responsive when file watching fails (#3056)".
//       상수·이름을 상류와 같게 둔다 — 상류 버전을 채택할 때 이 오버레이를 그대로 걷으면 된다.
//
// 문제: 파일 감시 등록이 10초(WORKSPACE_GIT_WATCHER_SUBSCRIBE_TIMEOUT_MS)를 넘기면 그 워크스페이스는
//   `startWorkingTreeWatchFallback` 으로 **5초마다** 새로고침한다 — 1회 = git 명령 4개(status·merge-base·
//   diff·ls-files). 복구 시도는 **3번(30·60·120초)에서 포기**하고(WATCH_RECOVERY_MAX_ATTEMPTS),
//   그 뒤로는 데몬이 재시작될 때까지 5초 폴링이 계속된다. 데몬 부팅 직후처럼 잠깐 붐빌 때 한 번
//   타임아웃이 나면 그 워크스페이스는 영구 부하원이 된다.
//   파일럿 박스 실측(2026-09-25): git 새로고침 1위가 `working-tree-watch-fallback` 610회/30초 창,
//   git 스케줄러(동시 8·초당 64) 큐 최고 552, 대기 최대 56초. 상류 주석이 같은 결론이다:
//     "Giving up permanently leaves polling as the only behaviour until a daemon restart,
//      which kills running agents. Back off, but keep trying."
//
// 처방(상류 그대로, working-tree 경로만 — repo-metadata 경로는 부하 증거가 없어 손대지 않는다):
//   ① 복구를 포기하지 않는다: min(30s × 2^min(n-1, 4), 300s) 간격으로 계속 시도한다.
//   ② 강등 폴링을 늦춘다: 새로고침 뒤 스냅샷 지문이 그대로면(조용한 회차) 다음 간격을 두 배로,
//      60초에서 멈춘다. 무언가 바뀌면 5초로 돌아간다. 새로고침이 던지면 refreshWorkspaceTarget 이
//      삼키고 지문이 그대로라 조용한 회차로 읽힌다 — 계속 실패하는 레포가 5초마다 두드리지 않게 하는,
//      상류가 의도한 결과다.
//
// 계약: argv[2] = 대상 workspace-git-service.js. stdout 1줄 + exit code.
//   exit 10 = 이미 패치(sentinel) → skip · 20 = 앵커 없음/중복(상류 drift) → 아무것도 안 쓰고 skip
//        (20 의 stdout 은 `SKIP:` 로 시작한다 — drift 테스트의 negative 단언이 그 토큰을 본다)
//   exit  0 = <대상>.paseo-new.mjs 후보 기록(install.sh 가 node --check 후 mv) · 1 = 사용법/IO 오류
// all-or-nothing: 앵커 넷이 **모두** 정확히 1회일 때만 적용한다.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: workspace-git-watch-recovery.mjs <workspace-git-service.js>"); process.exit(1); }

const SENTINEL = "[paseo-watch-recovery]";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

// ── 상수 (상류와 같은 이름·값) ─────────────────────────────────────────────────────
const OLD_POLL_CONST = `const DEGRADED_GIT_POLL_INTERVAL_MS = 5000;`;
const NEW_POLL_CONST = `const DEGRADED_GIT_POLL_INTERVAL_MS = 5000;
// ${SENTINEL} 조용한 강등 폴링의 간격 상한(상류 #3056).
const DEGRADED_GIT_POLL_MAX_INTERVAL_MS = 60000;`;

const OLD_RECOVERY_CONST = `const WATCH_RECOVERY_MAX_ATTEMPTS = 3;`;
const NEW_RECOVERY_CONST = `const WATCH_RECOVERY_MAX_ATTEMPTS = 3;
// ${SENTINEL} Giving up permanently leaves polling as the only behaviour until a daemon
// restart, which kills running agents. Back off, but keep trying. (상류 #3056 — working-tree 경로에만 적용)
const WATCH_RECOVERY_MAX_DELAY_MS = 300000;
const WATCH_RECOVERY_MAX_BACKOFF_STEPS = 4;`;

// ── ① 복구를 포기하지 않는다 ────────────────────────────────────────────────────────
const OLD_SCHEDULE = `    scheduleWorkingTreeWatchRecovery(target) {
        if (target.closed ||
            target.subscription ||
            target.recovery.timer ||
            target.recovery.attemptCount >= WATCH_RECOVERY_MAX_ATTEMPTS) {
            return;
        }
        target.recovery.attemptCount += 1;
        const delayMs = WATCH_RECOVERY_BASE_DELAY_MS * 2 ** (target.recovery.attemptCount - 1);`;
const NEW_SCHEDULE = `    scheduleWorkingTreeWatchRecovery(target) {
        // ${SENTINEL} 시도 횟수로 멈추지 않는다 — 간격만 300초에서 캡한다.
        if (target.closed ||
            target.subscription ||
            target.recovery.timer) {
            return;
        }
        target.recovery.attemptCount += 1;
        const delayMs = Math.min(WATCH_RECOVERY_BASE_DELAY_MS *
            2 ** Math.min(target.recovery.attemptCount - 1, WATCH_RECOVERY_MAX_BACKOFF_STEPS), WATCH_RECOVERY_MAX_DELAY_MS);`;

// ── ② 조용한 회차마다 강등 폴링 간격을 늘린다 ───────────────────────────────────────
const OLD_POLL = `        target.fallbackPolling = true;
        const { cwd } = target;
        const poll = async () => {
            target.fallbackPollTimer = null;
            if (target.closed || this.workingTreeWatchTargets.get(target.cwd) !== target) {
                return;
            }
            await Promise.all(Array.from(target.workspaceKeys, async (workspaceKey) => {
                const workspaceTarget = this.workspaceTargets.get(workspaceKey);
                if (!workspaceTarget) {
                    return;
                }
                await this.refreshWorkspaceTarget(workspaceTarget, {`;
const NEW_POLL = `        target.fallbackPolling = true;
        // ${SENTINEL} 연속으로 아무것도 안 바뀐 회차 수 — 다음 간격을 정한다.
        target.fallbackPollQuietTickCount = 0;
        const { cwd } = target;
        const poll = async () => {
            target.fallbackPollTimer = null;
            if (target.closed || this.workingTreeWatchTargets.get(target.cwd) !== target) {
                return;
            }
            const changes = await Promise.all(Array.from(target.workspaceKeys, async (workspaceKey) => {
                const workspaceTarget = this.workspaceTargets.get(workspaceKey);
                if (!workspaceTarget) {
                    return false;
                }
                // ${SENTINEL} 새로고침 전후의 스냅샷 지문으로 "바뀌었나"를 잰다(상류 refreshDegradedPollTarget).
                const fingerprintBefore = workspaceTarget.latestFingerprint;
                await this.refreshWorkspaceTarget(workspaceTarget, {`;

const OLD_RESCHEDULE = `                if (target.repoRoot === null && workspaceTarget.latestGit?.isGit === true) {
                    workspaceTarget.observationSetupComplete = false;
                    this.scheduleWorkspaceObservationSetup(workspaceTarget);
                }
            }));
            this.notifyWorkingTreeConsumers(target);
            if (!target.closed && (target.subscription === null || target.repoRoot === null)) {
                target.fallbackPollTimer = setTimeout(poll, DEGRADED_GIT_POLL_INTERVAL_MS);
            }`;
const NEW_RESCHEDULE = `                if (target.repoRoot === null && workspaceTarget.latestGit?.isGit === true) {
                    workspaceTarget.observationSetupComplete = false;
                    this.scheduleWorkspaceObservationSetup(workspaceTarget);
                }
                return workspaceTarget.latestFingerprint !== fingerprintBefore;
            }));
            this.notifyWorkingTreeConsumers(target);
            if (!target.closed && (target.subscription === null || target.repoRoot === null)) {
                // ${SENTINEL} 바뀐 게 있으면 5초로 되돌리고, 조용하면 두 배씩 늘려 60초에서 멈춘다.
                target.fallbackPollQuietTickCount = changes.some(Boolean)
                    ? 0
                    : target.fallbackPollQuietTickCount + 1;
                target.fallbackPollTimer = setTimeout(poll, Math.min(DEGRADED_GIT_POLL_MAX_INTERVAL_MS,
                    DEGRADED_GIT_POLL_INTERVAL_MS * 2 ** target.fallbackPollQuietTickCount));
            }`;

const anchors = [
    ["poll-const", OLD_POLL_CONST, NEW_POLL_CONST],
    ["recovery-const", OLD_RECOVERY_CONST, NEW_RECOVERY_CONST],
    ["schedule-recovery", OLD_SCHEDULE, NEW_SCHEDULE],
    ["fallback-poll", OLD_POLL, NEW_POLL],
    ["fallback-reschedule", OLD_RESCHEDULE, NEW_RESCHEDULE],
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
