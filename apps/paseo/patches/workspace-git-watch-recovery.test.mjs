// [paseo-watch-recovery] Behaviour check for the applied patch.
//
//   node workspace-git-watch-recovery.test.mjs <candidate workspace-git-service.js>
//
// 후보 파일을 **설치된 server 트리 안에** 임시 이름으로 두고(그 자리에서만 상대·bare import 가 풀린다)
// 패치된 두 메서드를 가짜 `this` 로 직접 구동한다. 서비스 전체를 띄우지 않는 이유: 이 패치가 바꾸는 것은
// "다음 타이머를 몇 ms 뒤에 거느냐" 뿐이고, 그것은 setTimeout 에 넘어간 값으로 정확히 잴 수 있다.
//   ① 복구 예약이 3번에서 멈추지 않고 30→60→120→240→300→300… 으로 계속된다
//   ② 강등 폴링이 조용한 회차마다 두 배로 늘어 60초에서 멈춘다
//   ③ 무언가 바뀐 회차 뒤에는 5초로 돌아간다
//   ④ 감시가 복구되면(subscription 이 생기면) 폴링을 더 예약하지 않는다
// Exit 0 = 전 시나리오 통과.
import { copyFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: workspace-git-watch-recovery.test.mjs <workspace-git-service.js candidate>"); process.exit(1); }

const probe = join(dirname(F), ".paseo-watch-recovery-behaviour-test.mjs");
const fail = (message) => { console.error("FAIL: " + message); rmSync(probe, { force: true }); process.exit(1); };

try {
    copyFileSync(F, probe);
    const { WorkspaceGitServiceImpl } = await import(probe);
    const proto = WorkspaceGitServiceImpl.prototype;

    // setTimeout 을 가로채 예약된 간격과 콜백만 기록한다 — 실제로 기다리지 않는다.
    const realSetTimeout = globalThis.setTimeout;
    let scheduled = [];
    globalThis.setTimeout = (fn, ms) => { scheduled.push({ fn, ms }); return { fake: true }; };

    // ── ① 복구는 포기하지 않는다 ────────────────────────────────────────────────────
    const watch = { closed: false, subscription: null, recovery: { timer: null, attemptCount: 0 } };
    const recoveryDelays = [];
    for (let i = 0; i < 7; i += 1) {
        scheduled = [];
        proto.scheduleWorkingTreeWatchRecovery.call({}, watch);
        if (scheduled.length !== 1) fail(`① ${i + 1}번째 복구가 예약되지 않았다 — 시도 횟수로 포기했다`);
        recoveryDelays.push(scheduled[0].ms);
        watch.recovery.timer = null;      // 타이머가 돌아 복구에 실패한 상태
    }
    const wantRecovery = [30000, 60000, 120000, 240000, 300000, 300000, 300000];
    if (JSON.stringify(recoveryDelays) !== JSON.stringify(wantRecovery)) {
        fail(`① 복구 간격 ${JSON.stringify(recoveryDelays)} (기대 ${JSON.stringify(wantRecovery)})`);
    }

    // ── ②③④ 강등 폴링 간격 ───────────────────────────────────────────────────────────
    const ws = { latestFingerprint: "a", latestGit: { isGit: true } };
    let change = false;
    const target = {
        cwd: "/w", closed: false, fallbackPolling: false, fallbackPollTimer: null,
        subscription: null, repoRoot: "/w", workspaceKeys: new Set(["k"]),
    };
    const self = {
        disposed: false,
        workingTreeWatchTargets: new Map([["/w", target]]),
        workspaceTargets: new Map([["k", ws]]),
        refreshWorkspaceTarget: async (t) => { if (change) t.latestFingerprint += "!"; },
        notifyWorkingTreeConsumers: () => {},
        scheduleWorkspaceObservationSetup: () => {},
        logger: { warn: () => {} },
    };
    scheduled = [];
    proto.startWorkingTreeWatchFallback.call(self, target, "watcher_setup_failed");
    if (scheduled.length !== 1 || scheduled[0].ms !== 5000) fail(`② 첫 폴링이 5초가 아니다 (${scheduled[0]?.ms})`);
    const pollDelays = [];
    const tick = async () => {
        const { fn } = scheduled.shift();
        await fn();
        if (scheduled.length) pollDelays.push(scheduled[0].ms);
    };
    for (let i = 0; i < 6; i += 1) await tick();          // 조용한 회차 6번
    const wantQuiet = [10000, 20000, 40000, 60000, 60000, 60000];
    if (JSON.stringify(pollDelays) !== JSON.stringify(wantQuiet)) {
        fail(`② 조용한 회차 간격 ${JSON.stringify(pollDelays)} (기대 ${JSON.stringify(wantQuiet)})`);
    }
    change = true; await tick(); change = false;          // 바뀐 회차
    if (pollDelays.at(-1) !== 5000) fail(`③ 변화 뒤 간격이 5초로 안 돌아왔다 (${pollDelays.at(-1)})`);

    target.subscription = { recovered: true };              // 감시 복구
    const before = scheduled.length;
    const { fn } = scheduled.shift(); await fn();
    if (scheduled.length !== before - 1) fail("④ 감시가 복구됐는데 폴링을 또 예약했다");
    if (target.fallbackPolling !== false) fail("④ 복구 뒤 fallbackPolling 이 내려가지 않았다");

    globalThis.setTimeout = realSetTimeout;
    rmSync(probe, { force: true });
    console.log("OK: 복구 무기한(300초 캡) · 조용한 폴링 60초 캡 · 변화 시 5초 복귀 · 복구 뒤 폴링 중단");
    process.exit(0);
} catch (error) {
    console.error("FAIL: " + (error && error.stack ? error.stack : String(error)));
    rmSync(probe, { force: true });
    process.exit(1);
}
