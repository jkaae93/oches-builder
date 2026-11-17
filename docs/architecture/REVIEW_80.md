# 아키텍처 검토 후속 평가 · 80/100

검토일 2026-11-16. 로컬 작업 트리와 Architecture Review Protocol v1.0을 기준으로 기존 [75점 평가](REVIEW_75.md) 및 후속 증거를 다시 대조했다. 설계 작업과 호환성·품질·보안의 독립 검토를 분리했다. 이 점수는 설계 수준 평가이며 실제 Provider 연동, 제품 인증·권한 집행, 복구 또는 출시 가능성의 통과를 의미하지 않는다.

## 가중 평가

| 항목 | 점수 / 5 | 가중 점수 | 근거 및 미검증 |
|---|---:|---:|---|
| Requirements Coverage | 4 | 16/20 | [요구사항과 수용 기준](REQUIREMENTS_ACCEPTANCE.md) R-01~12; 실제 작업의 대표성·운영 합격치 미승인 |
| Architecture & Module Boundaries | 4 | 12/15 | [교차 계약](CROSS_MODULE_CONTRACTS.md), [실험](contracts/EXPERIMENT_EVIDENCE.md); 전체 모듈의 실제 통합 미검증 |
| Extensibility & Compatibility | 4 | 12/15 | [ARC-04](ARC-04.md) v0.2, [ARC-15](ARC-15.md) v0.2, Agent-only 부분 스키마 부정 시험; Provider와 전체 노드 미검증 |
| Security & Authentication | 4 | 12/15 | [ARC-11](ARC-11.md), [macOS 신원 실험](MACOS_IDENTITY_EXPERIMENT.md): 위조 식별자·서명과 실패 제약을 검토. live peer·키 보호는 미검증 |
| Reliability & Recovery | 4 | 8/10 | [Runtime·SQLite 실험](contracts/EXPERIMENT_EVIDENCE.md); 단일 통제 프로세스 및 임시 DB, 실제 CLI·제품·전원 장애 미검증 |
| Data & Memory Consistency | 4 | 8/10 | [ARC-10](ARC-10.md), 동일 snapshot/cursor의 단일 경합 실험; 실제 저장소, 삭제·백업 복구 미검증 |
| Verifiability & Observability | 4 | 8/10 | [검증 계획](VERIFICATION_PLAN.md), [실제 과제 oracle](fixtures/REAL_TASK_ORACLE.md), 시제품의 양성·부정 대조; 독립 안전 관측기·실제 모델·사람 평가 미검증 |
| Feasibility & Cost | 4 | 4/5 | [첫 OS·CLI와 비용 검증안](PROVIDER_MVP_FEASIBILITY.md)은 후보별 예외·의존성·실패 조건 및 불확실한 인일·비용 가정을 비교한다. 인일은 실측이 아니고 Provider 수직 흐름은 NOT RUN |
| **합계** | | **80/100** | Σ(가중치 × 점수 / 5) |

보안 독립 리뷰어와 호환성 리뷰어는 예외·제약·의존성 검토라는 원래 4점 기준에 따라 보안 4/5가 타당하다고 별도 판단했다. 호환성·품질 리뷰어는 비용 v0.2의 예외·의존성 및 시나리오를 검토하고 실현 가능성·비용 4/5를 별도 판단했다. 품질 리뷰어의 이전 전체 77점은 보안 항목을 이전 3점으로 유지한 합계이며, 보안 전문 리뷰어의 후속 4점 판단과 합친 종합 산정은 위 80점이다. 4점은 실증된 보안·실제 비용이 아니라 **예외·제약·의존성의 설계 검토**다.

## Hard Gates와 판정

G1 PASS, G2 UNKNOWN, G3 UNKNOWN, G4 PASS, G5 PASS, G6 PASS, G7 PASS, G8 UNKNOWN. PASS인 G1/G5~G7은 논리적 추적·소유권·정책 설계의 판정이지 해당 기능의 제품 검증 합격이 아니다. G4는 검증하지 않은 지원 범위를 미검증으로 표시한 기준이다. UNKNOWN은 통과가 아니며 판정은 **CONDITIONAL**이다.

G2는 실제 전체 직렬화/노드/Adapter 상호운용 검증 부재, G3는 서명된 양성 대조·live peer 결합·신뢰 UI·키 보호 및 집행 실험 부재, G8은 대표성 있는 실제 작업·독립 안전 관측·사람 승인·운영 합격치 부재로 UNKNOWN이다. 비용 및 인일 수치는 근거 없는 확정 견적이 아니라 가정이며 Provider GUI 연동 허용·계정 격리·제품 실행·실제 비용은 미검증이다.

## 검증 기록

[계약 시제품 검증](contracts/EXPERIMENT_EVIDENCE.md)은 Agent 정의·제한된 그래프, Runtime 전이 모델, 단일 자식 프로세스, 임시 SQLite 거래 및 특정 snapshot/cursor 경합을 시험한다. 이 범위 밖 실행·보안·복구를 보증하지 않는다. [평가 oracle](fixtures/REAL_TASK_ORACLE.md)은 고정된 실제 Git 파일의 정답과 모의 부정 대조를 확인하며 제품 안전 관측이나 실사용 품질 시험이 아니다. CLI 인증 변경, 유료 모델 호출, 사용자 파일 수정, Projects 상태 변경은 하지 않았다. 아키텍처 `docs/`는 Git 미추적 초안이다.

### 최종 재현 및 추가 보안 근거

계약 시제품 테스트 28개, 고정 Git 정답 및 모의 부정 대조 10개와 잘못된 형식 부정 대조 7개, 임시 코드 서명 및 임시 키 경계 시험을 각각 재실행해 통과했다. 문서의 로컬 상대 링크 94개와 가중 점수 합계 80도 점검했다. 서로 다른 임시 실행 파일의 동일 ad-hoc 식별자, 서명의 재생 가능성 및 동일 사용자 프로세스의 0600 키 접근을 확인했다. [신뢰 경계 선택지](ARC-11-TRUST-OPTIONS.md)에서 양성 대조·live IPC·키 보호·nonce 저장 등의 NOT RUN 조건을 유지한다. 테스트 통과는 명시된 시제품 범위에만 적용한다.
