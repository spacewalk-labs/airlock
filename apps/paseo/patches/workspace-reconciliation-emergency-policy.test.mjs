import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
const file = process.argv[2];
if (!file) throw new Error("usage: workspace-reconciliation-emergency-policy.test.mjs <candidate>");
const source = fs.readFileSync(file, "utf8");
const start = source.indexOf("// [paseo-reconciliation-emergency-policy]");
assert.ok(start >= 0);
const policy = source.slice(start).replace("export const emergencyReconciliationPolicyCounters", "const emergencyReconciliationPolicyCounters");
for (const [env, scale] of [[{}, 20], [{ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: "100" }, 100], [{ PASEO_BACKGROUND_GIT_SAMPLE_SCALE: "1" }, 1]]) {
    const calls = [];
    class Service {
        async reconcileObservedGitMetadata(mode = "metadata") {
            calls.push({ self: this, mode });
            if (this.fail) throw new Error("explicit failure");
        }
        async reconcileNow() { return await this.reconcileObservedGitMetadata("full"); }
        async runOnce() { return "direct full"; }
        async reconcileGitMetadata() { return "direct metadata"; }
    }
    const context = vm.createContext({ WorkspaceReconciliationService: Service, process: { env } });
    vm.runInContext(policy, context);
    const services = [new Service(), new Service()];
    // Both timer modes and already-queued direct method calls pass the same gate.
    for (let i = 0; i < 2 * scale; i++) {
        await services[i % 2].reconcileObservedGitMetadata(i % 3 ? "metadata" : "full");
    }
    assert.equal(calls.length, 2);
    assert.ok(services.every((service) => calls.some((call) => call.self === service)));
    for (const service of services) {
        await service.reconcileNow(); // explicit and boot path
        assert.equal(await service.runOnce(), "direct full");
        assert.equal(await service.reconcileGitMetadata(), "direct metadata");
    }
    assert.equal(calls.length, 4);
    services[0].fail = true;
    await assert.rejects(services[0].reconcileNow(), /explicit failure/);
    services[0].fail = false;
    const count = calls.length;
    await services[0].reconcileObservedGitMetadata();
    assert.equal(calls.length, count + (scale === 1 ? 1 : 0), "finally clears explicit exemption");
    const counters = vm.runInContext("emergencyReconciliationPolicyCounters", context);
    assert.equal(counters.explicitPassed, 3);
    assert.equal(counters.seen, 2 * scale + 1);
}
console.log("OK: automatic reconciliation sampled per service; queued calls covered; explicit/boot/direct preserved");

// Drive the candidate's original queue implementation, not a simplified mock.
// Explicit full queued behind a running automatic metadata pass must survive
// after reconcileNow's stack has returned and cleared its immediate exemption.
const methodStart = source.indexOf('    async reconcileObservedGitMetadata(mode = "metadata") {');
const methodEnd = source.indexOf("    async readCheckout(cwd)", methodStart);
if (methodStart >= 0 && methodEnd > methodStart) {
    const originalMethod = source.slice(methodStart, methodEnd).trim()
        .replace('async reconcileObservedGitMetadata(mode = "metadata")', 'async function (mode = "metadata")');
    class QueuedService {
        async reconcileNow() { await this.reconcileObservedGitMetadata("full"); }
    }
    const context = vm.createContext({ WorkspaceReconciliationService: QueuedService, process: { env: {} } });
    QueuedService.prototype.reconcileObservedGitMetadata = vm.runInContext(`(${originalMethod})`, context);
    vm.runInContext(policy, context);
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const runs = [];
    const service = Object.assign(new QueuedService(), {
        disposed: false, reconciling: false, reconcileQueuedMode: null,
        syncProjectRootWatches: async () => {},
        reconcileGitMetadata: async () => { runs.push("metadata"); await gate; return { changesApplied: [] }; },
        runOnce: async () => { runs.push("full"); return { changesApplied: [] }; },
        logger: { warn: () => {} },
    });
    for (let i = 0; i < 19; i++) await service.reconcileObservedGitMetadata();
    const active = service.reconcileObservedGitMetadata();
    await Promise.resolve(); await Promise.resolve();
    assert.equal(service.reconciling, true);
    await service.reconcileNow();
    assert.equal(service.reconcileQueuedMode, "full");
    release();
    await active;
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(runs, ["metadata", "full"], "explicit queued full executes despite sampling");
    await service.reconcileObservedGitMetadata();
    assert.deepEqual(runs, ["metadata", "full"], "queued exemption is consumed once");
    console.log("OK: candidate original queue preserves explicit full behind automatic metadata");
}
