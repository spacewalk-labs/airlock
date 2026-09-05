---
paths:
  - "src/**"
---
## Source Code Rules

- Server Components 우선. `"use client"` 는 상호작용이 필요할 때만
- 스타일은 Tailwind CSS 만. 인라인 `style` 금지
- 컴포넌트는 함수 선언(`function`) 방식
- 새 패키지 설치 전 이유 + 대안 설명
- 부수효과(fetch·상태변경)를 컴포넌트 트리 여러 층에 흩뿌리지 말고 경계에 모은다

### Next API 는 외우지 말고 읽는다

동적 API 가 Promise 인지, 미들웨어 파일명이 무엇인지 같은 세부는 **버전마다 바뀐다.**
`node_modules/next/dist/docs/` 의 해당 문서를 열어 확인한다 — 설치된 버전과 일치하는 정본이다.
기억으로 쓰면 낡은 API 를 쓰게 된다.

### 검증

변경 후 `pnpm typecheck && pnpm lint && pnpm test` 통과 확인. 소스를 바꾼 턴은 Stop 훅이 이를 잠근다.
