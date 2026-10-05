// Behavior of the real patched 0.8.0 modules; no daemon or live checkout mutation.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const [serviceArg, checkoutArg] = process.argv.slice(2);
if (!serviceArg || !checkoutArg) throw new Error("usage: workspace-git-identity.test.mjs <service candidate> <checkout candidate>");
const serviceFile = resolve(serviceArg), checkoutFile = resolve(checkoutArg);
const scratch = mkdtempSync(join(tmpdir(), "paseo-identity-"));
const probe = join(dirname(serviceFile), ".paseo-identity-behaviour.mjs");
const logger = { child() { return this; }, debug() {}, info() {}, warn(error, message) { throw new Error(message, { cause: error }); } };
const git = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
try {
    // Candidates import their sibling utility candidate until installer moves the pair.
    writeFileSync(probe, readFileSync(serviceFile, "utf8").replace('"../utils/checkout-git.js"', JSON.stringify(pathToFileURL(checkoutFile).href)));
    const { WorkspaceGitServiceImpl } = await import(pathToFileURL(probe));
    const { getCheckoutIdentity, getCheckoutStatus } = await import(pathToFileURL(checkoutFile));
    const { checkoutLiteFromGitSnapshot } = await import(pathToFileURL(join(dirname(serviceFile), "workspace-registry-model.js")));
    const { WorkspaceReconciliationService } = await import(pathToFileURL(join(dirname(serviceFile), "workspace-reconciliation-service.js")));
    const context = { paseoHome: join(scratch, ".paseo"), worktreesRoot: join(scratch, ".paseo", "worktrees"), logger };
    let statusCalls = 0;
    const service = Object.create(WorkspaceGitServiceImpl.prototype);
    Object.assign(service, context, { disposed: false, deps: {
        getCheckoutIdentity,
        getCheckoutStatus() { statusCalls++; throw new Error("identity read called full status"); },
    } });
    const repo = join(scratch, "repo");
    mkdirSync(repo); git(repo, "init", "-b", "main");
    git(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-m", "initial");
    git(repo, "remote", "add", "origin", "https://example.test/fixture/repo.git");
    const plain = join(scratch, "plain"); mkdirSync(plain);
    const external = join(scratch, "external"); git(repo, "worktree", "add", "-b", "external", external);
    const owned = join(context.worktreesRoot, "hash", "owned"); git(repo, "worktree", "add", "-b", "owned", owned);
    const fixtures = [plain, repo, external, owned];
    for (const cwd of fixtures) {
        const checkout = await service.getCheckout(cwd);
        assert.deepEqual(checkout, checkoutLiteFromGitSnapshot(cwd, await getCheckoutStatus(cwd, context)), `six-field parity: ${cwd}`);
        // Independent expected fields also detect a regression shared by both paths.
        assert.deepEqual(checkout, cwd === plain ? {
            cwd, isGit: false, currentBranch: null, remoteUrl: null, worktreeRoot: null,
            mainRepoRoot: null, isPaseoOwnedWorktree: false,
        } : {
            cwd, isGit: true, currentBranch: cwd === repo ? "main" : cwd === external ? "external" : "owned",
            remoteUrl: "https://example.test/fixture/repo.git", worktreeRoot: realpathSync(cwd),
            mainRepoRoot: cwd === repo ? null : realpathSync(repo), isPaseoOwnedWorktree: cwd === owned,
        });
    }
    const metadataFile = join(git(owned, "rev-parse", "--absolute-git-dir"), "paseo", "worktree.json");
    mkdirSync(dirname(metadataFile), { recursive: true });
    writeFileSync(metadataFile, JSON.stringify({ version: 1, baseRefName: "main", baseRef: "refs/heads/main" }));
    assert.deepEqual(await service.getCheckout(owned), checkoutLiteFromGitSnapshot(owned, await getCheckoutStatus(owned, context)));
    assert.equal((await service.getCheckout(owned)).isPaseoOwnedWorktree, true);
    // Also cover detached HEAD, missing remote, and an owned path with no default base.
    git(external, "checkout", "--detach");
    assert.deepEqual(await service.getCheckout(external), checkoutLiteFromGitSnapshot(external, await getCheckoutStatus(external, context)));
    const noBase = join(context.worktreesRoot, "other-hash", "no-base"); mkdirSync(noBase, { recursive: true });
    git(noBase, "init", "-b", "feature");
    git(noBase, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-m", "initial");
    assert.deepEqual(await service.getCheckout(noBase), checkoutLiteFromGitSnapshot(noBase, await getCheckoutStatus(noBase, context)));
    assert.equal((await service.getCheckout(noBase)).isPaseoOwnedWorktree, false);

    // Actual reconciliation timer and root watcher, with in-memory registries.
    // The repo project has no workspace/snapshot, so its identity must still be read.
    const projects = [{ projectId: "project", rootPath: repo, kind: "directory", projectKey: "stale", archivedAt: null }];
    const workspaces = [{ workspaceId: "missing", projectId: "project", cwd: join(scratch, "gone"), archivedAt: null }];
    const archived = []; const updatedProjects = []; const notifications = [];
    const timers = []; const events = [];
    const reconciliation = new WorkspaceReconciliationService({
        serverId: "fixture", logger, workspaceGitService: service,
        projectRegistry: { list: async () => projects, upsert: async p => { projects[0] = p; updatedProjects.push(p); } },
        workspaceRegistry: {
            list: async () => workspaces,
            archive: async (id, at) => { archived.push(id); workspaces.find(w => w.workspaceId === id).archivedAt = at; },
        },
        onWorkspacesChanged: ids => notifications.push(ids),
        clock: {
            setInterval: (fn, ms) => { timers.push({ fn, ms }); return { unref() {} }; },
            setTimeout: (fn, ms) => { events.push({ fn, ms }); return {}; },
            clearInterval() {}, clearTimeout() {},
        },
        watchProjectRoot: (_root, _options, onChange) => { events.push({ onChange }); return { close() {} }; },
    });
    await reconciliation.start();
    assert.equal(timers[0].ms, 300000);
    await timers[0].fn();
    assert.deepEqual(archived, ["missing"], "missing workspace archived on first five-minute tick");
    assert.equal(updatedProjects.length, 1, "snapshot-free project root refreshed on first full tick");
    assert.equal(projects[0].kind, "git");
    assert.deepEqual(notifications, [["missing"]]);
    // Exactly one event must observe a changed root; there is no sampling counter.
    const previousKey = projects[0].projectKey;
    git(repo, "remote", "set-url", "origin", "https://example.test/fixture/renamed.git");
    events.find(e => e.onChange).onChange("rename", ".git");
    const eventTimer = events.find(e => e.fn);
    assert.equal(eventTimer.ms, 100);
    await eventTimer.fn();
    assert.notEqual(projects[0].projectKey, previousKey, "first event immediately reconciles fresh identity");
    assert.equal(updatedProjects.length, 2);
    assert.equal(statusCalls, 0, "automatic full reconciliation and event call no full status");
    reconciliation.dispose();
    console.log("PASS checkout identity: six-field parity; snapshot-free root; full-status calls=0; first 5-minute archive; first event refresh");
} finally {
    rmSync(probe, { force: true }); rmSync(scratch, { recursive: true, force: true });
}
