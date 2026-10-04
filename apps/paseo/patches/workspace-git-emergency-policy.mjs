// Temporary operator-box overload mitigation, 2026-10-04. Reduce work before Git,
// including already-queued refresh loops, not the process scheduler: cached watcher/self-heal requests admit one in 20;
// background fetch also admits one in 20 (separate counter). Forced, cold and external-state-change reads still run.
// PASEO_BACKGROUND_GIT_SAMPLE_SCALE=1 restores normal cadence at next daemon start.
// Emergency: scale=100 plus PASEO_BACKGROUND_GIT_PAUSE_FETCH=1 pauses fetch entirely.
// Same candidate/exit contract as workspace-git-watch-recovery.mjs. Remove this
// overlay when metadata fanout/observation demand is fixed upstream.
import fs from "node:fs";
import { renderBackgroundGitScale } from "./background-git-policy-source.mjs";

const file = process.argv[2];
if (!file) {
    console.error("usage: workspace-git-emergency-policy.mjs <workspace-git-service.js>");
    process.exit(1);
}
const source = fs.readFileSync(file, "utf8");
const sentinel = "// [paseo-emergency-git-policy]";
if (source.includes(sentinel)) { console.log("ALREADY"); process.exit(10); }
const anchors = [
    "export class WorkspaceGitServiceImpl",
    "    async refreshSnapshot(target, request, runRefreshGitCommand) {",
    "    async runRepoFetch(target) {",
];
if (anchors.some((anchor) => source.split(anchor).length - 1 !== 1)) {
    console.log("SKIP:NO_OR_AMBIGUOUS_ANCHOR");
    process.exit(20);
}

// Append at module scope so the original methods and their calling convention
// remain intact. Tests drive these installed methods without starting a daemon.
const policy = `
${sentinel}
${renderBackgroundGitScale("emergencyGit")}
const emergencyGitPauseFetch = process.env.PASEO_BACKGROUND_GIT_PAUSE_FETCH === "1";
export const emergencyGitPolicyCounters = {
    scale: emergencyGitScale, backgroundSeen: 0, backgroundSkipped: 0,
    backgroundAdmitted: 0, explicitPassed: 0, fetchSeen: 0, fetchSkipped: 0, fetchAdmitted: 0,
};
const emergencyGitSnapshotSeen = new WeakMap();
const emergencyGitFetchSeen = new WeakMap();
const emergencyGitOriginalRequest = WorkspaceGitServiceImpl.prototype.refreshSnapshot;
const emergencyGitOriginalFetch = WorkspaceGitServiceImpl.prototype.runRepoFetch;
WorkspaceGitServiceImpl.prototype.refreshSnapshot = async function (target, request, runRefreshGitCommand) {
    const background = !request.force && !!target.latestSnapshot &&
        (request.reason === "watch" || request.reason?.includes("watch") || request.reason?.startsWith("self-heal-"));
    if (background) {
        emergencyGitPolicyCounters.backgroundSeen++;
        const seen = (emergencyGitSnapshotSeen.get(target) ?? 0) + 1;
        emergencyGitSnapshotSeen.set(target, seen);
        if (seen % emergencyGitScale !== 0) {
            emergencyGitPolicyCounters.backgroundSkipped++;
            return Promise.resolve(target.latestSnapshot);
        }
        emergencyGitPolicyCounters.backgroundAdmitted++;
    } else emergencyGitPolicyCounters.explicitPassed++;
    return emergencyGitOriginalRequest.call(this, target, request, runRefreshGitCommand);
};
WorkspaceGitServiceImpl.prototype.runRepoFetch = async function (target) {
    emergencyGitPolicyCounters.fetchSeen++;
    const seen = (emergencyGitFetchSeen.get(target) ?? 0) + 1;
    emergencyGitFetchSeen.set(target, seen);
    if (emergencyGitPauseFetch || (seen - 1) % emergencyGitScale !== 0) {
        emergencyGitPolicyCounters.fetchSkipped++;
        return;
    }
    emergencyGitPolicyCounters.fetchAdmitted++;
    return emergencyGitOriginalFetch.call(this, target);
};
`;
fs.writeFileSync(file + ".paseo-new.mjs", source + policy);
console.log("PATCHED");
