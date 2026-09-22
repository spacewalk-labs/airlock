// 패치된 archive·detach·reload 를 데몬 없이 돌려, 완전한 id 는 fetchAgent 로 직접 찾고
// (capped) 목록을 아예 안 보는지 — 접두어는 목록으로 떨어지는지 — 를 확인한다.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const patcher = path.join(here, "agent-resolve-by-id.mjs");
const inputs = process.argv.slice(2);
if (inputs.length !== 3) throw new Error("usage: test.mjs <archive.js> <detach.js> <reload.js>");

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "paseo-resolve-by-id-"));

function patch(srcFile, expected) {
    const original = fs.readFileSync(srcFile, "utf8");
    const file = path.join(temp, path.basename(srcFile));
    fs.writeFileSync(file, original);
    fs.rmSync(file + ".paseo-new.mjs", { force: true });
    const r = spawnSync(process.execPath, [patcher, file], { encoding: "utf8" });
    assert.equal(r.status, expected, r.stdout + r.stderr);
    assert.equal(fs.readFileSync(file, "utf8"), original, "패처가 원본을 건드렸다");
    if (expected !== 0) {
        assert.equal(fs.existsSync(file + ".paseo-new.mjs"), false);
        return original;
    }
    const cand = file + ".paseo-new.mjs";
    assert.equal(spawnSync(process.execPath, ["--check", cand]).status, 0, "후보가 유효 JS 가 아니다");
    return fs.readFileSync(cand, "utf8");
}

const UUID = "dd080d1d-cade-4e47-8226-6b0c94408626";
const AGENT = { id: UUID, status: "idle", archivedAt: null, cwd: "/x" };

// 목록을 부르면 실패로 표시하는 스텁 — 완전한 id 경로에서 목록이 안 쓰였음을 증명한다.
function makeClient(record) {
    const calls = { fetchAgent: 0, fetchAgents: 0, archiveAgent: 0, detachAgent: 0, refreshAgent: 0 };
    return {
        calls,
        client: {
            async fetchAgent({ agentId }) { calls.fetchAgent++; return agentId === record.id ? { agent: record } : null; },
            async fetchAgents() { calls.fetchAgents++; return { entries: [], pageInfo: { hasMore: true } }; },
            async archiveAgent(id) { calls.archiveAgent++; assert.equal(id, record.id); return { archivedAt: "T" }; },
            async detachAgent(id) { calls.detachAgent++; assert.equal(id, record.id); },
            async refreshAgent(id) { calls.refreshAgent++; assert.equal(id, record.id); return { agentId: id, timelineSize: 1 }; },
            async close() {},
        },
    };
}

function loadRun(patched, exportName) {
    const start = patched.indexOf(`export async function ${exportName}(`);
    const end = patched.indexOf("\n//# sourceMappingURL", start);
    assert.ok(start >= 0, `${exportName} 를 찾지 못했다`);
    const body = patched.slice(start, end < 0 ? undefined : end).replace("export async function", "async function");
    // resolveAgentId 는 접두어 경로에서만 쓰인다. 완전한 id 경로에서 호출되면 테스트를 깬다.
    let resolveCalls = 0;
    const ctx = {
        getDaemonHost: () => "local",
        connectToDaemon: null, // 케이스별로 주입
        resolveAgentId: (arg, list) => { resolveCalls++; const hit = list.find((a) => a.id.startsWith(arg)); return hit ? hit.id : null; },
        // 함수가 참조하는 모듈 스코프 스키마 상수 — 반환값 모양에만 쓰인다.
        archiveSchema: {}, reloadSchema: {}, detachSchema: {},
    };
    const fn = vm.runInNewContext(`(${body})`, ctx);
    return { fn, ctx, get resolveCalls() { return resolveCalls; } };
}

async function fullIdSkipsList(file, exportName, callName) {
    const patched = patch(file, 0);
    const stub = makeClient(AGENT);
    const holder = loadRun(patched, exportName);
    holder.ctx.connectToDaemon = async () => stub.client;
    await holder.fn(UUID, {});
    assert.equal(stub.calls.fetchAgent, 1, `${exportName}: 완전한 id 인데 fetchAgent 를 안 불렀다`);
    assert.equal(stub.calls.fetchAgents, 0, `${exportName}: 완전한 id 인데 capped 목록을 봤다`);
    assert.equal(holder.resolveCalls, 0, `${exportName}: 완전한 id 인데 resolveAgentId 로 떨어졌다`);
    assert.equal(stub.calls[callName], 1, `${exportName}: 실제 동작(${callName})이 그 id 로 실행되지 않았다`);
}

async function prefixUsesList(file, exportName) {
    const patched = patch(file, 0);
    const stub = makeClient(AGENT);
    // 목록에 한 건을 담아 접두어가 풀리게 한다.
    stub.client.fetchAgents = async () => { stub.calls.fetchAgents++; return { entries: [{ agent: AGENT }], pageInfo: { hasMore: false } }; };
    const holder = loadRun(patched, exportName);
    holder.ctx.connectToDaemon = async () => stub.client;
    await holder.fn("dd080d1", {}); // 7자 접두어 — UUID 정규식에 안 걸린다
    assert.equal(stub.calls.fetchAgent, 0, `${exportName}: 접두어인데 직접 조회를 시도했다`);
    assert.equal(stub.calls.fetchAgents, 1, `${exportName}: 접두어인데 목록을 안 봤다`);
    assert.equal(holder.resolveCalls, 1, `${exportName}: 접두어인데 resolveAgentId 를 안 썼다`);
}

const [archiveJs, detachJs, reloadJs] = inputs;
try {
    // fresh → 10(idempotent) → drift(20)
    for (const f of inputs) {
        const patched = patch(f, 0);
        assert.ok(patched.includes("[paseo-resolve-by-id]"));
        // 이미 패치된 것을 다시 넣으면 10
        const twice = path.join(temp, "twice-" + path.basename(f));
        fs.writeFileSync(twice, patched);
        fs.rmSync(twice + ".paseo-new.mjs", { force: true });
        assert.equal(spawnSync(process.execPath, [patcher, twice], { encoding: "utf8" }).status, 10);
    }
    // 앵커 없는 파일(형제 stop.js 모양) → 20
    const noAnchor = path.join(temp, "no-anchor.js");
    fs.writeFileSync(noAnchor, "export async function x(){ const a = await client.fetchAgent({agentId}); }\n//# sourceMappingURL=x\n");
    assert.equal(spawnSync(process.execPath, [patcher, noAnchor], { encoding: "utf8" }).status, 20);

    await fullIdSkipsList(archiveJs, "runArchiveCommand", "archiveAgent");
    await fullIdSkipsList(detachJs, "runDetachCommand", "detachAgent");
    await fullIdSkipsList(reloadJs, "runReloadCommand", "refreshAgent");

    await prefixUsesList(archiveJs, "runArchiveCommand");
    await prefixUsesList(detachJs, "runDetachCommand");
    await prefixUsesList(reloadJs, "runReloadCommand");

    console.log("PASS: 완전한 id 는 fetchAgent 로 직접 · capped 목록 우회 · 접두어는 목록 · idempotent · drift");
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
