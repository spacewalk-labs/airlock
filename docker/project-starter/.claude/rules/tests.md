---
paths:
  - "tests/**"
  - "e2e/**"
  - "src/**/*.test.ts"
  - "src/**/*.test.tsx"
---
## Test Rules

### 어느 도구로 쓸지는 취향이 아니라 역량이다

| 대상 | 도구 | 이유 |
|---|---|---|
| Server Actions · 스키마 · 순수 로직 · 동기 컴포넌트 | **Vitest** (`src/**/*.test.ts(x)`) | 밀리초 단위 — 고치고 즉시 확인 |
| **async Server Component** · 인증 · 라우팅 · 폼 플로우 | **Playwright** (`e2e/*.spec.ts`) | Vitest 는 async Server Component 를 **렌더할 수 없다** |

`async` Server Component 를 Vitest 로 테스트하려 시도하지 말 것 — React 의 async 컴포넌트 지원이
테스트 러너에서 stable 이 아니라서 생기는 **역량 한계**이고, mock 으로 우회할 문제가 아니다.
Next 공식 가이드도 이 경우 E2E 를 권장한다.

### 규율

- **버그를 고치기 전에 그 버그를 재현하는 테스트를 먼저 쓴다.** 통과하면 고쳐진 것이고, 회귀를 막는다.
- 테스트가 구현 세부(클래스명·내부 상태)가 아니라 **사용자가 보는 것**을 검증하게 한다.
- 실패하는 테스트를 `skip`·`only`·주석처리로 치우지 않는다. 원인을 고치거나, 못 고치면 이유를 남긴다.
- 커버리지 숫자를 목표로 삼지 않는다. 깨지면 아픈 경로부터 덮는다.
- `pnpm test` 는 watch 없이(`--run`) 끝나야 한다 — CI·훅에서 매달리지 않게.
