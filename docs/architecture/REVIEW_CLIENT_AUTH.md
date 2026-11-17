# 설치별 클라이언트 인증 설계 재평가

검토 대상: [설치별 인증키 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md), ARC-09/11~13, ADR-016 및 [이전 90점 평가](REVIEW_90.md). 2026-11-16. 설계 문서와 상대 링크를 대조했으며 실제 제품·OS·Provider 통합 시험은 하지 않았다.

**이력:** 제품 시험 미실행과 설계 평가 기준을 혼합한 점수·Gate 설명은 [최신 정정 평가](REVIEW_DESIGN_CRITERIA_CORRECTED.md)로 대체한다. 아래는 당시 판단과 견해 차이의 기록이다.

| 항목 | 점수 | 가중 점수 | 근거 및 한계 |
|---|---:|---:|---|
| Requirements Coverage | 5/5 | 20/20 | [추적표](REQUIREMENTS_TRACEABILITY_V2.md)와 기존 기준. 후보 기준의 실제 승인·제품 시험은 별개 |
| Architecture & Module Boundaries | 5/5 | 15/15 | [모듈 계약](INTERFACE_CONTRACT_V1.md), ARC-11/12/13의 플랫폼 식별·키·인가 역할. 실제 상호운용 미검증 |
| Extensibility & Compatibility | 5/5 | 15/15 | [Capability 계약](CAPABILITY_CONTRACT_V1.md)과 플랫폼별 조건 및 UNKNOWN. 실제 Adapter·저장소 호환은 미검증 |
| Security & Authentication | 4/5 | 12/15 | [설치별 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)는 최초 등록·키 소유·인가·철회·오류·실패를 구분한다. 실제 클라이언트 신원 결부·키 보호·신뢰 UI/권한 집행은 NOT RUN |
| Reliability & Recovery | 4/5 | 8/10 | 키 소실·회수·재등록과 실패 시 차단 설계. 실제 중단·경합·복구는 NOT RUN |
| Data & Memory Consistency | 4/5 | 8/10 | 공개키/권한과 감사의 소유·저장 경계가 있으나 실제 트랜잭션·보존·복구는 미검증 |
| Verifiability & Observability | 4/5 | 8/10 | 정상·위조·재생·철회 양부정 사례가 있으나 제품 경로의 독립 관측·시험은 NOT RUN |
| Feasibility & Cost | 4/5 | 4/5 | 공식 플랫폼 저장 수단의 조건과 한계 조사. 설치·운영·실제 비용과 Provider 흐름 미검증 |
| **합계** | | **90/100** | 이전 점수 유지; 변경된 설계만으로 해당 점수 범주의 5점 근거가 늘어난 것은 아님 |

## Hard Gate 및 견해 차이

G1/G4/G5/G6/G7은 기존과 동일하게 설계 또는 미검증 명시 관점 PASS다. G2는 전체 계약 합의·실제 상호운용을 아직 확인하지 못해 UNKNOWN, G3는 플랫폼별 최초 등록·키 보호·live peer·권한 강제 및 공격 대조가 미실행이라 UNKNOWN이다. 점수 90이어도 전체 판정은 CONDITIONAL이다.

G8의 원문은 **핵심 기능의 수용 기준과 검증 방법이 정의됨**이다. [요구사항 수용 기준](REQUIREMENTS_ACCEPTANCE.md)의 기능별 기준·방법은 존재하나, [ARC-00](ARC-00.md)이 제시한 구성 품질 비교·개선 목표에 대한 실제 작업 oracle과 충분한 합격 기준은 확정되지 않았다. 이 목표를 판정하는 데 현재 후보 기준이 충분한지 확인되지 않아 G8은 **UNKNOWN**으로 보수적으로 기록한다. 미실행이나 미승인 자체를 설계 정의 여부의 실패로 취급하지 않는다. 앞선 설계 관점 PASS 해석과 독립 검토의 UNKNOWN 견해는 이 충분성 판단의 차이다. 운영 평가 결과는 NOT RUN이며 출시 준비는 미입증이다.

## 독립 검토에서 바로잡은 문서 모호성

- 구 키 철회와 새 키 활성화의 순서: 기존 등록 철회·세션/권한 회수 후 새 등록한다. 중단 시 자동 복원·동시 활성은 금지하고 새 사용자 확인이 필요하다. 실행 중인 외부 작업은 취소 요청과 실제 종료 확인을 구분한다.
- `KEY_UNAVAILABLE`은 `UNAVAILABLE`, `AUTH_FAILED`는 안전한 공개 범위에서 `DENIED`의 세부 유형으로 정규화한다. Core의 nonce 저장소가 범위·연결에 결부된 nonce를 원자적으로 소비하며 불명 상태를 거부하도록 명시했다.

위 보완은 논리 계약의 정정이다. 키 접근 통제, 중복·철회 경합이나 제품 보안이 검증됐다는 주장으로 사용하지 않는다. 이 검토에서 문서 상대 링크를 확인했으며 새로운 제품/플랫폼 보안 시험은 수행하지 않았다. docs/는 Git 미추적 로컬 상태다.

후속 독립 검토에서 ARC-10 복원 세대와 공통 `RevisionRef`/오류 분류의 누락을 발견해 해당 제안을 맞췄다. G2는 실제 시험의 부재만이 아니라 다른 계약 전체의 모순 부재와 소유 범위 검토가 완료되지 않아 UNKNOWN이다. G3도 실제 시험 부재만이 아니라 Host 종단 신원·서명 중계와 복구 원장의 인증된 intent 수단이 미결이어서 UNKNOWN이다. 이 변경 후 전체 범주의 독립 재채점은 수행되지 않았으므로 이전 90은 잠정 참고값이다.
