// 2026-10-04: 405/423 traced Git calls came from automatic reconciliation,
// which rereads all projects/workspaces via getCheckout, bypassing snapshots.
// Sample only the automatic envelope; explicit/boot reconcileNow and direct
// runOnce/reconcileGitMetadata keep their existing behavior. Candidate contract
// matches workspace-git-emergency-policy.mjs (0 candidate,10 already,20 drift).
import fs from "node:fs";
import { renderBackgroundGitScale } from "./background-git-policy-source.mjs";
const file = process.argv[2];
if (!file) throw new Error("usage: workspace-reconciliation-emergency-policy.mjs <workspace-reconciliation-service.js>");
const source = fs.readFileSync(file, "utf8");
const sentinel = "// [paseo-reconciliation-emergency-policy]";
if (source.includes(sentinel)) { console.log("ALREADY"); process.exit(10); }
const anchors = [
    "export class WorkspaceReconciliationService",
    '    async reconcileObservedGitMetadata(mode = "metadata") {',
    "    async reconcileNow() {",
];
if (anchors.some((anchor) => source.split(anchor).length - 1 !== 1)) {
    console.log("SKIP:NO_OR_AMBIGUOUS_ANCHOR"); process.exit(20);
}
const policy = `
${sentinel}
${renderBackgroundGitScale("emergencyReconciliation")}
const emergencyReconciliationSeen = new WeakMap();
const emergencyReconciliationExplicit = new WeakMap();
const emergencyReconciliationPendingExplicitFull = new WeakSet();
export const emergencyReconciliationPolicyCounters = { scale: emergencyReconciliationScale, seen: 0, skipped: 0, admitted: 0, explicitPassed: 0 };
const emergencyReconciliationOriginalObserved = WorkspaceReconciliationService.prototype.reconcileObservedGitMetadata;
const emergencyReconciliationOriginalNow = WorkspaceReconciliationService.prototype.reconcileNow;
WorkspaceReconciliationService.prototype.reconcileObservedGitMetadata = async function (mode = "metadata") {
    // An explicit full request queued behind automatic work keeps its exemption
    // after reconcileNow returns. Consume it only when the queued run can start.
    if (mode === "full" && !this.reconciling && emergencyReconciliationPendingExplicitFull.has(this)) {
        emergencyReconciliationPendingExplicitFull.delete(this);
        emergencyReconciliationPolicyCounters.explicitPassed++;
        return emergencyReconciliationOriginalObserved.call(this, mode);
    }
    if ((emergencyReconciliationExplicit.get(this) ?? 0) > 0) {
        emergencyReconciliationPolicyCounters.explicitPassed++;
        return emergencyReconciliationOriginalObserved.call(this, mode);
    }
    const seen = (emergencyReconciliationSeen.get(this) ?? 0) + 1;
    emergencyReconciliationSeen.set(this, seen);
    emergencyReconciliationPolicyCounters.seen++;
    if (seen % emergencyReconciliationScale !== 0) {
        emergencyReconciliationPolicyCounters.skipped++;
        return;
    }
    emergencyReconciliationPolicyCounters.admitted++;
    return emergencyReconciliationOriginalObserved.call(this, mode);
};
WorkspaceReconciliationService.prototype.reconcileNow = async function () {
    emergencyReconciliationExplicit.set(this, (emergencyReconciliationExplicit.get(this) ?? 0) + 1);
    try {
        const result = await emergencyReconciliationOriginalNow.call(this);
        if (this.reconciling && this.reconcileQueuedMode === "full") {
            emergencyReconciliationPendingExplicitFull.add(this);
        }
        return result;
    }
    finally {
        const depth = (emergencyReconciliationExplicit.get(this) ?? 1) - 1;
        if (depth === 0) emergencyReconciliationExplicit.delete(this);
        else emergencyReconciliationExplicit.set(this, depth);
    }
};
`;
fs.writeFileSync(file + ".paseo-new.mjs", source + policy);
console.log("PATCHED");
