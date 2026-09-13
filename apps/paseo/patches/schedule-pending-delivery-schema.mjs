// [paseo-schedule-pending-schema] StoredSchedule 에 `pendingAgentDelivery` 를 추가한다.
//
// 대상: @getpaseo/protocol .../schedule/types.js (StoredScheduleSchema)
// 짝:   patches/schedule-busy-pending-delivery.mjs (server 쪽 동작). 이 스키마 패치가 없으면 zod object 가
//       모르는 키를 **조용히 벗겨** 저장되지 않는다 — 데몬 재시작 뒤 pending 이 사라져 그 틱을 다시 잃는다.
//       반대로 이 패치만 있고 server 패치가 없으면 필드는 늘 기본값(false)이라 무해하다. 순서 무관.
//
// 계약: argv[2] = 대상 types.js. exit 10 이미 적용 · 20 앵커 없음/중복 · 0 후보 기록 · 1 IO 오류.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: schedule-pending-delivery-schema.mjs <schedule/types.js>"); process.exit(1); }

const SENTINEL = "[paseo-schedule-pending-schema]";

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read 실패: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const OLD = `    maxRuns: z.number().int().positive().nullable(),
    runs: z.array(ScheduleRunSchema),
});`;
const NEW = `    maxRuns: z.number().int().positive().nullable(),
    // ${SENTINEL} busy 인 좌석 때문에 못 보낸 틱 하나를 합쳐 두는 비트. 옛 저장본에는 없으므로 optional
    // 이고, 기본값 false 로 읽는다(스키마만 있고 server 패치가 없으면 늘 false — 동작 변화 없음).
    pendingAgentDelivery: z.boolean().optional().default(false),
    runs: z.array(ScheduleRunSchema),
});`;

if (!src.includes(OLD)) { console.log("NO_ANCHOR:stored-schedule"); process.exit(20); }
if (src.split(OLD).length - 1 !== 1) { console.log("AMBIGUOUS:stored-schedule"); process.exit(20); }

try { fs.writeFileSync(F + ".paseo-new.mjs", src.replace(OLD, NEW)); }
catch (err) { console.error("write 실패: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
