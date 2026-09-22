// [paseo-resolve-by-id] archive·detach·reload 가 좌석을 **정확한 id 면 데몬에 직접 물어** 찾게 한다.
//
// 대상: @getpaseo/cli dist/commands/agent/{archive,detach,reload}.js — 세 파일 각각에 적용한다.
//
// 세 명령은 `fetchAgents({includeArchived:true})` 목록에서 id 를 찾는데 서버가 200건에서 자른다
// (session.js `limit ?? 200`, CLI 에 --page 없음) — 오래 멈춘 좌석은 그 밖으로 밀려 not found 가
// 된다. 완전한 id(UUID)면 `fetchAgent` 로 직접 조회해 목록을 건너뛴다(형제 stop·delete 와 같다).
// 접두어·이름은 데몬이 직접 못 풀어 예전대로 목록으로 떨어진다. 배경·제거 조건 = patches/README.md.
//
// 계약: argv[2] = 대상 {archive|detach|reload}.js. stdout 1줄 + exit code.
//   exit 10 = 이미 패치(sentinel) → skip · 20 = 앵커 없음/중복(상류 drift) → 아무것도 안 쓰고 skip
//   exit  0 = <대상>.paseo-new.mjs 후보 기록(install.sh 가 node --check 후 mv) · 1 = 사용법/IO
// all-or-nothing: 두 앵커 중 **정확히 하나**가 정확히 1회일 때만 적용한다. 반쪽 적용은 하지 않는다.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: agent-resolve-by-id.mjs <archive|detach|reload.js>"); process.exit(1); }

const SENTINEL = "[paseo-resolve-by-id]";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

// 완전한 agent id(UUID)일 때만 직접 조회한다. 접두어·이름은 목록으로 떨어진다.
const FASTPATH = (listBlock) => `        // ${SENTINEL} 완전한 id 는 데몬에 직접 물어 찾는다 — includeArchived 목록은
        // 서버에서 200건으로 잘려(--page 없음) 오래 멈춘 좌석이 그 밖으로 밀리기 때문이다.
        // stop·delete 가 이미 하는 것과 같다. 접두어·이름만 (capped) 목록으로 떨어진다.
        const directHit = /^[0-9a-fA-F-]{36}$/.test(agentIdArg)
            ? await client.fetchAgent({ agentId: agentIdArg }).catch(() => null)
            : null;
${listBlock}`;

// archive.js · reload.js — 동일한 3줄 블록. archive 는 뒤에서 agents.find 를 쓰므로 채워 둔다.
const ARCHIVE_RELOAD_OLD = `        const agentsPayload = await client.fetchAgents({ filter: { includeArchived: true } });
        const agents = agentsPayload.entries.map((entry) => entry.agent);
        const agentId = resolveAgentId(agentIdArg, agents);`;
const ARCHIVE_RELOAD_NEW = FASTPATH(`        let agents;
        let agentId;
        if (directHit && directHit.agent) {
            agents = [directHit.agent];
            agentId = directHit.agent.id;
        }
        else {
            const agentsPayload = await client.fetchAgents({ filter: { includeArchived: true } });
            agents = agentsPayload.entries.map((entry) => entry.agent);
            agentId = resolveAgentId(agentIdArg, agents);
        }`);

// detach.js — 2줄 변형. 뒤에서 목록을 다시 안 쓰므로 agentId 만 세운다.
const DETACH_OLD = `        const payload = await client.fetchAgents({ filter: { includeArchived: true } });
        const agentId = resolveAgentId(agentIdArg, payload.entries.map((entry) => entry.agent));`;
const DETACH_NEW = FASTPATH(`        let agentId;
        if (directHit && directHit.agent) {
            agentId = directHit.agent.id;
        }
        else {
            const payload = await client.fetchAgents({ filter: { includeArchived: true } });
            agentId = resolveAgentId(agentIdArg, payload.entries.map((entry) => entry.agent));
        }`);

const candidates = [
    [ARCHIVE_RELOAD_OLD, ARCHIVE_RELOAD_NEW],
    [DETACH_OLD, DETACH_NEW],
];

const matched = candidates.filter(([old]) => src.split(old).length - 1 === 1);
if (matched.length !== 1) {
    // 둘 다 없음(다른 파일·상류 변경) 또는 둘 다/중복 — 손대지 않는다.
    console.error("SKIP: anchors missing or ambiguous (upstream drift?)");
    process.exit(20);
}
const [[old, neu]] = matched;
// fast-path 는 `client.fetchAgent` 를 부른다 — 형제 stop·delete 가 이미 의존하는 안정 API 라
// 별도 확인을 두지 않는다(그 메서드 이름은 명령 파일 소스에 나타나지 않는다). 상류가 그 API 를
// 바꿨다면 위 앵커 블록도 함께 바뀌어 이 패처는 exit 20 으로 빠진다.
const out = src.replace(old, neu);
fs.writeFileSync(F + ".paseo-new.mjs", out);
console.log("PATCHED");
process.exit(0);
