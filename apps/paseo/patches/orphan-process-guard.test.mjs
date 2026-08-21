// [paseo-orphan-guard] Behaviour check for the applied patch.
//
//   node orphan-process-guard.test.mjs <.../providers/claude/agent.js>
//
// It does NOT test a copy of the logic: it slices adoptSpawnedChild/terminateLiveChildren
// out of the *installed, patched* bundle and drives that text against fake children, so a
// patch that applied but reassembled wrongly fails here. Exit 0 = all scenarios pass.
import fs from "node:fs";
const F = process.argv[2];
if (!F) { console.error("usage: orphan-process-guard.test.mjs <claude/agent.js>"); process.exit(1); }
const src = fs.readFileSync(F, "utf8");
// 출하본에서 두 메서드 본문을 그대로 잘라낸다 (사본 아님)
const a = src.indexOf("    adoptSpawnedChild(child) {");
const b = src.indexOf("\n    async ensureQuery() {", a);
if (a < 0 || b < 0) { console.error("추출 실패"); process.exit(1); }
const methods = src.slice(a, b);

const killed = [];
const terminateWithTreeKill = async (child) => { killed.push(child.pid); child.exitCode = 0; return "terminated"; };
const warns = [];
const logger = { warn: (o, m) => warns.push(m) };

const T = new Function("terminateWithTreeKill", `
  return class T {
    constructor(){ this.agentId="a1"; this.logger=arguments[0]; this.closed=false; this.childProcess=null; this.liveChildProcesses=new Set(); }
${methods}
  };`)(terminateWithTreeKill);

const mkChild = (pid) => { const h={}; return { pid, once:(e,f)=>{h[e]=f;}, fire:(e)=>h[e]&&h[e]() }; };
const t = new T(logger);
let fail = 0;
const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); if (!c) fail++; };

const c1 = mkChild(101); t.adoptSpawnedChild(c1);
ok(t.liveChildProcesses.size === 1 && t.childProcess === c1, "① 열린 세션: 자식 채택");

const c2 = mkChild(102); t.adoptSpawnedChild(c2);
ok(t.liveChildProcesses.size === 2, "② 덮어쓰기: 이전 자식이 Set 에 남는다 (상류는 여기서 유실)");
ok(warns.some(w => w.includes("live child was replaced")), "② 덮어쓰기 warn 발생");

c1.fire("exit");
ok(t.liveChildProcesses.size === 1 && !t.liveChildProcesses.has(c1), "③ exit 이벤트 → Set 에서 제거");

await t.terminateLiveChildren("session_close");
ok(killed.join() === "102" && t.liveChildProcesses.size === 0 && t.childProcess === null, "④ close: 살아있는 자식 전부 kill + 정리");

killed.length = 0; warns.length = 0;
await t.terminateLiveChildren("session_close");
ok(killed.length === 0 && warns.length === 0, "⑤ 죽일 게 없으면 조용히 반환 (정상 close 소음 없음)");

t.closed = true; const c3 = mkChild(103); t.adoptSpawnedChild(c3);
ok(killed.join() === "103" && t.liveChildProcesses.size === 0, "⑥ close 이후 도착한 자식 → 저장 대신 즉시 kill 🔴핵심");
ok(warns.some(w => w.includes("arrived after close")), "⑥ 지각 도착 warn 발생");

const c4 = mkChild(104); c4.pid = 104;
const t2 = new T(logger); t2.adoptSpawnedChild(c4); killed.length = 0;
await t2.terminateLiveChildren("query_restart");
ok(killed.join() === "104", "⑦ query_restart 도 같은 경로로 회수");

console.log(fail === 0 ? "\n전부 통과" : `\n실패 ${fail}건`);
process.exit(fail === 0 ? 0 : 1);
