코드 품질을 검사한다.

1. `pnpm lint` 실행 (ESLint flat config 직접 호출 — Next 16 은 `next lint` 를 제거했다).
2. `pnpm typecheck` 실행 (`tsc --noEmit`) — 린트는 타입 검사를 대신하지 않는다.
3. `pnpm format:check` 스크립트가 있으면 실행, 없으면 건너뛴다.
4. 문제 발견 시:
   - 자동 수정 가능한 항목을 분류한다.
   - `pnpm lint --fix` 로 자동 수정할지 사용자에게 묻는다.
   - 타입 에러는 자동 수정 대상이 아니다 — 원인을 보고한다.
5. 모든 검사 통과 시 결과를 알려준다.
