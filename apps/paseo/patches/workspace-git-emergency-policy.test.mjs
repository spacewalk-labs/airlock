// Candidate behaviour check: extract actual methods and overlay, avoiding service
// startup, filesystem watches, agent providers and installed dependency resolution.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const file = process.argv[2];
if (!file) throw new Error("usage: workspace-git-emergency-policy.test.mjs <candidate>");
const source = fs.readFileSync(file, "utf8");
const start = source.indexOf("// [paseo-emergency-git-policy]");
assert.ok(start >= 0, "candidate carries policy");
const policy = source.slice(start).replace("export const emergencyGitPolicyCounters", "const emergencyGitPolicyCounters");

async function scenario(env, expectedScale) {
    const calls = [];
    const fetches = [];
    class Service {
        refreshSnapshot(target, request, runGit) {
            calls.push({ self: this, target, request, runGit });
            return Promise.resolve({ fresh: true });
        }
        async runRepoFetch(target) { fetches.push({ self: this, target }); }
    }
    const context = vm.createContext({ WorkspaceGitServiceImpl: Service, process: { env } });
    vm.runInContext(policy, context);
    const counters = vm.runInContext("emergencyGitPolicyCounters", context);
    assert.equal(counters.scale, expectedScale);
    const service = new Service();
    const runGit = () => {};
    const targets = [{ latestSnapshot: { cached: 1 } }, { latestSnapshot: { cached: 2 } }];
    const reasons = ["watch", "git-metadata-watch", "working-tree-watch-fallback", "self-heal-forge-pr-status"];
    // Call refreshSnapshot directly as runWorkspaceRefreshLoop does for requests
    // queued before mitigation. No requestWorkspaceSnapshot wrapper is involved.
    for (let i = 0; i < 200; i++) {
        const target = targets[i % 2];
        const result = await service.refreshSnapshot(target, { reason: reasons[i % 4] }, runGit);
        if ((Math.floor(i / 2) + 1) % expectedScale !== 0) assert.equal(result, target.latestSnapshot);
        else assert.equal(result.fresh, true);
    }
    assert.equal(calls.length, 2 * Math.floor(100 / expectedScale), "per-target sampling avoids starvation");
    assert.ok(targets.every((target) => calls.filter((call) => call.target === target).length === Math.floor(100 / expectedScale)), "both alternating targets eventually admitted");
    assert.ok(calls.every((call) => call.runGit === runGit), "Git runner preserved");
    assert.equal(counters.backgroundSkipped, 200 - calls.length);
    // A skipped background event must never suppress explicit/cold/mutation work.
    for (const request of [
        { reason: "git-metadata-watch", force: true },
        { reason: "getSnapshot" },
        { reason: "external-state-change" },
        { reason: "refresh" },
        { reason: "open_project", force: true },
    ]) await service.refreshSnapshot(targets[0], request);
    await service.refreshSnapshot({ latestSnapshot: null }, { reason: "watch" });
    assert.equal(counters.explicitPassed, 6);
    assert.ok(calls.every((call) => call.self === service), "original receiver preserved");
    for (let i = 0; i < 80; i++) await service.runRepoFetch(targets[i % 2]);
    const expectedFetches = env.PASEO_BACKGROUND_GIT_PAUSE_FETCH === "1" ? 0 : 2 * Math.ceil(40 / expectedScale);
    assert.equal(fetches.length, expectedFetches);
    if (expectedFetches) assert.ok(targets.every((target) => fetches.some((call) => call.target === target)), "each repository discovers refs");
    assert.equal(counters.fetchSkipped, 80 - expectedFetches);
    assert.equal(counters.fetchAdmitted, expectedFetches);
    assert.ok(fetches.every((call) => call.self === service), "fetch receiver preserved");
}

await scenario({}, 20);
await scenario({ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: "100", PASEO_BACKGROUND_GIT_PAUSE_FETCH: "1" }, 100);
await scenario({ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: "10" }, 10);
await scenario({ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: "1" }, 1);
for (const invalid of ["0", "-1", "garbage", "1.5", ""]) {
    await scenario({ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: invalid }, 20);
}
console.log("OK: per-target 1/20 sampling; force/cold/direct/mutation preserved; separate fetch sampling; emergency pause; scale=1 restores");
