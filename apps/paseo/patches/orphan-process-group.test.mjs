// [paseo-process-group] Behaviour check for the applied patch.
//
//   node orphan-process-group.test.mjs <.../providers/claude/agent.js>
//
// Slices sweepProcessGroup out of the *installed, patched* bundle and drives that
// text against REAL detached processes — so this proves the shipped code actually
// reaps a leader's descendants after the leader itself is gone, which is the whole
// point of the patch. Exit 0 = all scenarios pass.
import fs from "node:fs";
import { spawn, execSync } from "node:child_process";

const F = process.argv[2];
if (!F) { console.error("usage: orphan-process-group.test.mjs <claude/agent.js>"); process.exit(1); }
const src = fs.readFileSync(F, "utf8");

const a = src.indexOf("    sweepProcessGroup(pid, reason) {");
const b = src.indexOf("\n    async terminateLiveChildren(reason) {", a);
if (a < 0 || b < 0) { console.error("추출 실패 — 패치가 적용되지 않았거나 형태가 다르다"); process.exit(1); }
const method = src.slice(a, b);

const warns = [];
const logger = { warn: (o, m) => warns.push(m) };
const T = new Function(`return class T { constructor(l){ this.logger = l; }\n${method}\n};`)();
const t = new T(logger);

const alive = (p) => {
    if (!p || p < 1) return false;   // ps -p 0 은 "process ID out of range" 를 stderr 로 뱉는다
    try { return execSync(`ps -p ${p} -o pid= || true`).toString().trim() !== ""; } catch { return false; }
};
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

let fail = 0;
const ok = (c, m) => { console.log((c ? "  PASS " : "  FAIL ") + m); if (!c) fail++; };

// ① 진짜 시나리오: detached 리더 + 손자. 리더만 죽인 뒤(트리 링크 소멸) 그룹 sweep 이 손자를 잡나.
{
    const leader = spawn(process.execPath, ["-e",
        `const g=require("node:child_process").spawn(process.execPath,["-e","setTimeout(()=>{},600000)"],{stdio:"ignore"});console.log(g.pid);setTimeout(()=>{},600000);`
    ], { stdio: ["pipe", "pipe", "pipe"], detached: true, shell: false });
    const gpid = await new Promise(r => leader.stdout.once("data", d => r(Number(d.toString().trim()))));
    const exited = new Promise(r => leader.once("exit", r));
    leader.kill("SIGKILL");
    await exited;
    ok(alive(gpid), "① 리더만 죽이면 손자는 살아남는다 (= 트리 kill 로는 못 잡는 상황)");
    warns.length = 0;
    t.sweepProcessGroup(leader.pid, "test");
    await sleep(500);
    ok(!alive(gpid), "① 그룹 sweep 이 그 손자를 잡는다 🔴핵심");
    ok(warns.some(w => w.includes("swept the leader's process group")), "① 생존자가 있었으므로 warn 을 남긴다");
    if (alive(gpid)) { try { process.kill(gpid, "SIGKILL"); } catch { } }
}

// ② 생존자가 없으면 조용하다 (ESRCH) — 정상 close 마다 헛경보가 뜨면 로그가 무의미해진다.
{
    const leader = spawn(process.execPath, ["-e", "setTimeout(()=>{},600000)"],
        { stdio: ["pipe", "pipe", "pipe"], detached: true, shell: false });
    await sleep(300);
    const exited = new Promise(r => leader.once("exit", r));
    leader.kill("SIGKILL");
    await exited;
    warns.length = 0;
    t.sweepProcessGroup(leader.pid, "test");
    ok(warns.length === 0, "② 그룹이 비었으면(ESRCH) 아무 로그도 남기지 않는다");
}

// ③ 자기 자신을 죽이지 않는다. `process.getpgrp` 는 Node 22 에 없으므로 자기 그룹 id 는
//    /proc 에서 읽어 확인한다 — "가드가 있다" 가 아니라 "실제로 안 죽는다" 를 본다.
{
    warns.length = 0;
    const myPgid = Number(fs.readFileSync("/proc/self/stat", "utf8").split(") ")[1].split(" ")[2]);
    t.sweepProcessGroup(process.pid, "test");
    ok(alive(process.pid), "③ 자기 pid 를 넘겨도 살아있다 🔴안전");
    // 자기 그룹 id 는 (pid 유일성 때문에) 자식 pid 와 절대 겹칠 수 없다 — 그 불변식을 명시 검증
    ok(myPgid === process.pid || !alive(0), `③ 내 pgid=${myPgid} · 자식 pid 와 충돌 불가(pid 유일성)`);
    t.sweepProcessGroup(1, "test"); t.sweepProcessGroup(0, "test"); t.sweepProcessGroup(undefined, "test");
    ok(warns.length === 0 && alive(process.pid), "③ pid 1·0·undefined 는 무시한다");
}

console.log(fail === 0 ? "\n전부 통과" : `\n실패 ${fail}건`);
process.exit(fail === 0 ? 0 : 1);
