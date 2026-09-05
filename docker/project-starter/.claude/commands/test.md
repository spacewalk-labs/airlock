테스트를 실행하고 실패를 분석한다.

1. `node_modules/` 없으면 `pnpm install`.
2. `pnpm test -- --run` (Vitest, watch 없이) 실행.
3. 인자로 `e2e` 가 주어졌거나 async Server Component·인증·라우팅 관련 변경이면
   `pnpm test:e2e` (Playwright) 도 실행한다.
   - Playwright 브라우저가 없으면 `pnpm exec playwright install --with-deps chromium` 안내.
4. 실패 시:
   - **테스트가 틀렸는지 / 코드가 틀렸는지 먼저 판정한다.** 테스트를 고쳐서 통과시키는 건
     코드가 맞다고 확인된 뒤에만 한다.
   - 실패 메시지를 정확히 읽고(추측 금지) 원인을 보고한다.
5. `skip`·`only` 로 실패를 치우지 않는다.
