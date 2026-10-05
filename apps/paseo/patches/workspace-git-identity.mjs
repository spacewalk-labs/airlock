// Identity-only reconciliation backport for Paseo 0.8.0. AGPL-3.0-only.
// Pair contract: exit 0 writes two checked candidates, 10 already, 20 anchor drift.
import fs from "node:fs";
const [serviceFile, checkoutFile] = process.argv.slice(2);
if (!serviceFile || !checkoutFile) throw new Error("usage: workspace-git-identity.mjs <workspace-git-service.js> <checkout-git.js>");
const service = fs.readFileSync(serviceFile, "utf8");
const checkout = fs.readFileSync(checkoutFile, "utf8");
const marker = "// [paseo-checkout-identity]";
if (service.includes(marker) && checkout.includes(marker)) { console.log("ALREADY"); process.exit(10); }
const importAnchor = "getCheckoutShortstat, getCheckoutStatus, getCheckoutWorktreeState";
const depsAnchor = "        getCheckoutStatus,\n        getCheckoutShortstat,";
const callAnchor = "const status = await this.deps.getCheckoutStatus(normalizedCwd, {";
const utilityAnchor = "export async function getCheckoutStatus(cwd, context) {";
const statusEndAnchor = "// Workspace history stays complete;";
const statusStart = checkout.indexOf(utilityAnchor);
const statusEnd = checkout.indexOf(statusEndAnchor, statusStart);
const status = checkout.slice(statusStart, statusEnd);
const mainRootAnchor = "    const mainRepoRoot = facts.mainRepoRoot;";
const ownedAnchor = "    if (paseoWorktree.isPaseoOwnedWorktree && baseRef) {";
const ownedRootAnchor = "            mainRepoRoot: mainRepoRoot ?? worktreeRoot,";
const plainRootAnchor = "        mainRepoRoot: mainRepoRoot && resolve(mainRepoRoot) !== resolve(worktreeRoot) ? mainRepoRoot : null,";
const unique = (source, anchor) => source.split(anchor).length === 2;
if (![importAnchor, depsAnchor, callAnchor].every(a => unique(service, a)) ||
    !unique(checkout, utilityAnchor) || !unique(checkout, statusEndAnchor) ||
    ![mainRootAnchor, ownedAnchor, ownedRootAnchor, plainRootAnchor].every(a => unique(status, a)) || service.includes(marker) || checkout.includes(marker)) {
    console.log("SKIP:NO_OR_AMBIGUOUS_ANCHOR"); process.exit(20);
}
const helper = `${marker}
function normalizeCheckoutIdentity(inspected, mainRepoRoot, baseRef) {
    const isPaseoOwnedWorktree = Boolean(inspected.paseoWorktree.isPaseoOwnedWorktree && baseRef);
    return {
        isGit: true,
        repoRoot: inspected.worktreeRoot,
        mainRepoRoot: isPaseoOwnedWorktree
            ? mainRepoRoot ?? inspected.worktreeRoot
            : mainRepoRoot && resolve(mainRepoRoot) !== resolve(inspected.worktreeRoot) ? mainRepoRoot : null,
        currentBranch: inspected.currentBranch,
        remoteUrl: inspected.remoteUrl,
        isPaseoOwnedWorktree,
    };
}
export async function getCheckoutIdentity(cwd, context) {
    const inspected = await inspectCheckoutContext(cwd, context);
    if (!inspected) return { isGit: false };
    const mainRepoRoot = await getMainRepoRootFromCommonDir(cwd, inspected.gitCommonDir, context).catch(() => null);
    // Status only labels a Paseo worktree as owned when it has a base ref.
    // Ordinary checkouts do not need base resolution to establish their identity.
    const baseRef = inspected.paseoWorktree.isPaseoOwnedWorktree
        ? readPaseoWorktreeBaseRef(inspected.paseoWorktree.worktreeRoot) ?? (await resolveBaseRef(cwd, context))
        : null;
    return normalizeCheckoutIdentity(inspected, mainRepoRoot, baseRef);
}
`;
let nextStatus = status.replace(mainRootAnchor, mainRootAnchor + "\n    const identity = normalizeCheckoutIdentity(facts, mainRepoRoot, baseRef);")
    .replace(ownedAnchor, "    if (identity.isPaseoOwnedWorktree) {")
    .replace("    const worktreeRoot = facts.worktreeRoot;\n", "")
    .replace("    const paseoWorktree = facts.paseoWorktree;\n", "");
// Leave status-only fields and the owned base-ref display branch untouched.
for (const indent of ["            ", "        "]) {
    nextStatus = nextStatus.replace(indent + "isGit: true,\n", indent + "...identity,\n")
        .replace(indent + "repoRoot: worktreeRoot,\n", "")
        .replace(indent + "currentBranch,\n", "")
        .replace(indent + "remoteUrl,\n", "");
}
nextStatus = nextStatus.replace(ownedRootAnchor + "\n", "").replace(plainRootAnchor + "\n", "")
    .replace("            isPaseoOwnedWorktree: true,\n", "")
    .replace("        isPaseoOwnedWorktree: false,\n", "");
const nextService = service.replace(importAnchor, "getCheckoutShortstat, getCheckoutIdentity, getCheckoutStatus, getCheckoutWorktreeState")
    .replace(depsAnchor, "        getCheckoutIdentity,\n" + depsAnchor)
    .replace(callAnchor, marker + "\n        const status = await this.deps.getCheckoutIdentity(normalizedCwd, {");
fs.writeFileSync(checkoutFile + ".paseo-new.mjs", checkout.slice(0, statusStart) + helper + nextStatus + checkout.slice(statusEnd));
fs.writeFileSync(serviceFile + ".paseo-new.mjs", nextService);
console.log("PATCHED");
