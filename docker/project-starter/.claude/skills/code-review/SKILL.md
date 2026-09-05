---
name: code-review
description: Rob Pike 단순성 원칙으로 코드를 진단하고 데이터 중심 리팩토링을 제안한다 — 과도한 추상화, 조건문 비대, 부수효과 분산, 추측성 최적화, 룩업 테이블로 치환 가능한 반복 계산을 잡는다. MUST TRIGGER; 코드 리뷰 요청, "이 코드 복잡한가", "리팩토링 해줘", "오버엔지니어링인지 봐줘", PR 올리기 전 자기검토. Do NOT use for; 버그 원인 진단(그건 일반 디버깅), 보안 취약점 스캔(security-guidance 플러그인), 포맷팅(ESLint).
---

# Code Review — Rob Pike 단순성 진단

## 역할

Rob Pike 의 단순성 원칙으로 코드를 진단한다. 감정·위트·은유 없이 객관적이고 구조화된 텍스트로만 응답한다.

## 진단 기준 5개

**Over_Abstraction** — 1~2회 사용을 위해 불필요한 레이어(HOC, 커스텀 훅, 유틸 클래스)를 만들었는가?
예: 한 곳에서만 쓰이는 wrapper 함수, 과도한 제너릭.

**Control_Flow_Bloat** — 데이터 구조 개선으로 제거 가능한 조건문/분기가 과도하게 많은가?
예: 타입별 if/else 체인, 룩업 테이블로 대체 가능한 switch-case.

**Side_Effect_Scatter** — 부수효과(API 호출, 상태 변경, 파일 I/O)가 여러 계층에 분산되어 있는가?
예: 컴포넌트 안에 fetch 로직, 유틸 함수 안에 전역 상태 변경.

**Premature_Optimization** — 측정 없이 성능을 가정하여 복잡도를 높였는가?
예: 실사용 데이터 없는 캐싱, 불필요한 `useMemo`, 미성숙한 lazy loading.

**Missing_Lookup** — 런타임 반복 계산을 정적 Map/테이블/상수로 치환 가능한가?
예: 문자열 비교 분기 → 객체 맵, 반복 파싱 → 빌드타임 상수.

## 출력 형식

반드시 아래 형식으로만 응답한다. 인사말·부연 설명 생략.

```
### 1. Rule_Violation_Report
Over_Abstraction: [True/False] - (사유 1줄)
Control_Flow_Bloat: [True/False] - (사유 1줄)
Side_Effect_Scatter: [True/False] - (사유 1줄)
Premature_Optimization: [True/False] - (사유 1줄)
Missing_Lookup: [True/False] - (사유 1줄)

### 2. Complexity_Analysis
Target_Logic: (문제 함수/블록 명시)
Issue: (왜 오버엔지니어링인지)
Resolution_Strategy: (간소화 방향)

### 3. Data_Driven_Refactoring
Applied_Rule: (적용 원칙)
Before:
(원본 코드)
After:
(리팩토링된 코드)
Diff_Summary: (변경 전후 핵심 차이 1-2줄)
```

## 대상 선택

인자로 코드·파일·범위가 주어지면 그것을, 없으면 **이번 변경분**(`git diff` + staged + untracked)을 대상으로 한다.

## 주의

- **True 를 만들기 위해 억지 판정하지 않는다** — 5개 모두 False 가 정상적인 결과일 수 있다.
- 제안한 After 코드는 **타입이 맞아야 한다**. 확신 없으면 `pnpm typecheck` 로 확인한다.
- 리팩토링을 실제로 적용할지는 사용자가 결정한다. 자동 적용하지 않는다.
