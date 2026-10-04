import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const patcher = new URL("./workspace-git-emergency-policy.mjs", import.meta.url);
const behaviour = new URL("./workspace-git-emergency-policy.test.mjs", import.meta.url);
const fixture = `export class WorkspaceGitServiceImpl {
    async refreshSnapshot(target, request, runRefreshGitCommand) {
        return target.latestSnapshot;
    }
    async runRepoFetch(target) {}
}
`;
const run = (script, file) => spawnSync(process.execPath, [script.pathname, file], { encoding: "utf8" });

test("patch candidate validates and reapplication leaves bytes intact", () => {
    const dir = mkdtempSync(join(tmpdir(), "paseo-git-policy-"));
    try {
        const file = join(dir, "service.mjs");
        writeFileSync(file, fixture);
        assert.equal(run(patcher, file).status, 0);
        assert.equal(readFileSync(file, "utf8"), fixture, "patcher never edits target");
        const candidate = file + ".paseo-new.mjs";
        const checked = spawnSync(process.execPath, ["--check", candidate], { encoding: "utf8" });
        assert.equal(checked.status, 0, checked.stderr);
        const result = run(behaviour, candidate);
        assert.equal(result.status, 0, result.stderr);
        const bytes = readFileSync(candidate, "utf8");
        assert.equal(run(patcher, candidate).status, 10);
        assert.equal(readFileSync(candidate, "utf8"), bytes);
        assert.equal(existsSync(candidate + ".paseo-new.mjs"), false);
    } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("missing or duplicate method anchors fail without writing", () => {
    const dir = mkdtempSync(join(tmpdir(), "paseo-git-policy-"));
    try {
        for (const source of [fixture.replace("async refreshSnapshot", "async changedSnapshot"), fixture + fixture]) {
            const file = join(dir, "service.mjs");
            writeFileSync(file, source);
            const result = run(patcher, file);
            assert.equal(result.status, 20, result.stderr);
            assert.match(result.stdout, /^SKIP:/);
            assert.equal(readFileSync(file, "utf8"), source);
            assert.equal(existsSync(file + ".paseo-new.mjs"), false);
        }
    } finally { rmSync(dir, { recursive: true, force: true }); }
});

const reconciliationPatcher = new URL("./workspace-reconciliation-emergency-policy.mjs", import.meta.url);
const reconciliationBehaviour = new URL("./workspace-reconciliation-emergency-policy.test.mjs", import.meta.url);
const reconciliationFixture = `export class WorkspaceReconciliationService {
    async reconcileObservedGitMetadata(mode = "metadata") {}
    async reconcileNow() {}
}
`;
test("reconciliation policy candidate, behaviour, idempotence and drift", () => {
    const dir = mkdtempSync(join(tmpdir(), "paseo-reconciliation-policy-"));
    try {
        const file = join(dir, "service.mjs");
        writeFileSync(file, reconciliationFixture);
        assert.equal(run(reconciliationPatcher, file).status, 0);
        assert.equal(readFileSync(file, "utf8"), reconciliationFixture);
        const candidate = file + ".paseo-new.mjs";
        const checked = spawnSync(process.execPath, ["--check", candidate], { encoding: "utf8" });
        assert.equal(checked.status, 0, checked.stderr);
        const result = run(reconciliationBehaviour, candidate);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(run(reconciliationPatcher, candidate).status, 10);
        rmSync(candidate);
        for (const drifted of [reconciliationFixture.replace("async reconcileNow", "async driftNow"), reconciliationFixture + reconciliationFixture]) {
            writeFileSync(file, drifted);
            assert.equal(run(reconciliationPatcher, file).status, 20);
            assert.equal(existsSync(candidate), false);
            assert.equal(readFileSync(file, "utf8"), drifted);
        }
    } finally { rmSync(dir, { recursive: true, force: true }); }
});
