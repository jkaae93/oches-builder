# 구현 전 설계 보완과 독립 평가 — 90/100

검토일: 2026-11-16. 대상은 로컬 작업 트리의 ARC-00 v0.1~v0.3, 관련 ARC/ADR 및 이 문서가 참조하는 설계 제안이다. 기존 [80점 평가](REVIEW_80.md)를 기준으로 제품 구현 없이 문서 계약·공식 근거·수용 조건을 보완했다. 원 프로토콜의 5점은 **검증 가능한 계약과 근거의 존재**를 뜻하며 제품 구현·시험 PASS와 구분한다. 기존 `docs/`는 Git 미추적 로컬 초안이다.

이 문서는 작성 당시의 판정을 보존한 기록이다. G8의 원문 기준에 대한 후속 해석과 독립 검토자의 차이는 [설치별 인증 재평가](REVIEW_CLIENT_AUTH.md#hard-gate-및-견해-차이)를 참조한다. 어느 해석에서도 제품 평가·출시 준비는 미입증이다.

## 점수 및 근거

| 항목 | 점수 / 5 | 가중 점수 | 이번 판단의 근거와 한계 |
|---|---:|---:|---|
| Requirements Coverage | 5 | 20/20 | [추적 v0.2](REQUIREMENTS_TRACEABILITY_V2.md): 목표→RT-01~38→ARC→시험·증거와 기존 R-01~12 역방향 매핑. [비기능 기준](NON_FUNCTIONAL_ACCEPTANCE_V1.md): 접근성·성능·결측·권한 수용 조건. 사용자 승인과 제품 시험은 미완료 |
| Architecture & Module Boundaries | 5 | 15/15 | [계약 v1](INTERFACE_CONTRACT_V1.md) C01~C08, [수용 사례](CONTRACT_ACCEPTANCE_MATRIX.md) X01~X24, [그래프 명세](TEMPLATE_GRAPH_SPEC_V1.md): 소유·방향·입출력·오류·버전·경합·검증 기준. 실제 통합 및 소유자 합의는 미완료 |
| Extensibility & Compatibility | 5 | 15/15 | [Capability 계약](CAPABILITY_CONTRACT_V1.md): 계정·workspace·클라이언트·OS·버전·정책 범위의 유효성, 손실과 CV01~18. [공식 근거](COMPATIBILITY_EVIDENCE_V1.md)는 문서 일반 기능과 Oches UNKNOWN 분리. 실제 Adapter·Provider 지원은 미검증 |
| Security & Authentication | 4 | 12/15 | [ARC-09](ARC-09.md)·[ARC-11](ARC-11.md), [신뢰 경계](ARC-11-TRUST-OPTIONS.md): 승인·위조 예외·실패 시 차단과 제한적 부정 대조. live peer·키 보호·신뢰 UI의 실제 강제 미검증 |
| Reliability & Recovery | 4 | 8/10 | [ARC-06](ARC-06.md)·[ARC-07](ARC-07.md) 및 [실험 한계](contracts/EXPERIMENT_EVIDENCE.md): 상태·취소·Unknown·저장 실패 설계, 단일 통제 시제품. 실제 Provider·제품 장애 복구 미검증 |
| Data & Memory Consistency | 4 | 8/10 | [ARC-08](ARC-08.md)·[ARC-10](ARC-10.md): 정본·출처·불변 snapshot·삭제 권한 경계. 실제 저장·백업·복구와 법적 보존 충돌 미확정 |
| Verifiability & Observability | 4 | 8/10 | [평가·관측 명세](EVALUATION_OBSERVABILITY_SPEC.md), [fixture v0.3 입력](fixtures/RWT_INPUT_CONTRACT_V03.md): 독립 관측·결측·사람 판정·부정 대조. 실제 관측기·평가자·대표 데이터셋 미검증 |
| Feasibility & Cost | 4 | 4/5 | [후보·비용 계획](PROVIDER_MVP_FEASIBILITY.md): 경로별 제약·실패·불확실성. 인일·비용은 가정이며 실제 CLI 수직 흐름 NOT RUN |
| **합계** | | **90/100** | 20 + 15 + 15 + 12 + 8 + 8 + 8 + 4 |

요구사항 5점은 품질 독립 리뷰어가 목표-계약-기준의 양방향 근거와 비기능 후보 기준을 확인한 판단이다. 아키텍처·확장성 5점은 호환성 독립 리뷰어가 C/X·TG·CV 계약과 예외/범위 결부를 검토한 판단이며, 품질 독립 리뷰어도 재대조 후 원 척도에서 두 항목의 5점을 인정했다. 보안 4점은 별도 보안 리뷰에서 예외·의존성 검토 수준으로 판단했으며 제품 안전성의 입증이 아니다.

## Mandatory Hard Gates

| Gate | 판정 | 근거·한계 |
|---|---|---|
| G1 | PASS | 추적표가 목표·요구·소유 모듈·사례를 연결. 수용 조건의 사용자 승인·제품 합격을 의미하지 않음 |
| G2 | UNKNOWN | 주요 논리 경계와 발견된 순서 충돌을 문서상 보완했으나 소유자 합의·전체 실제 상호운용 미검증 |
| G3 | UNKNOWN | 동일 UID/서명 identifier만으로 신원 보증 불가. OS live peer·정상 서명 양성·키·승인 강제 미검증 |
| G4 | PASS | 각 조합이 검증되었거나 UNKNOWN/미지원으로 명시된다는 기준. 특정 기능이 실제 지원된다는 뜻 아님 |
| G5 | PASS | Task/Attempt·템플릿/인스턴스·상태/기억의 논리 정본과 책임 식별. 물리적 내구성의 시험 합격 아님 |
| G6 | PASS | 장애·재시도·취소·Unknown·복구 **정책 설계** 존재. 실제 복구 성공 보장 아님 |
| G7 | PASS | 템플릿 검증·버전 불변·신뢰 경계·별도 승인 설계. 실제 파서·권한 집행 검증 아님 |
| G8 | UNKNOWN | 후보 판정/비기능 임계치는 미승인이고 제품·대표 작업·독립 안전 관측·사람 평가 미실행 |

**Review Verdict: CONDITIONAL.** 90점이어도 G2·G3·G8 UNKNOWN은 통과가 아니며 모든 Gate PASS, 제품 안전성 또는 출시 준비를 주장할 수 없다. 원래 F-01의 실제 인증·집행 입증, F-03의 Provider 연동 및 비용 실증, 실제 저장·데이터 보호와 운영 평가의 잔여 검증을 유지한다. 기존 고위험으로 기록된 우려를 시험 없이 해결된 결함으로 바꾸지 않는다.

## 이번 검증과 한계

로컬 Markdown 상대 링크, 추적 RT-01~38/N01~23, X01~24, CV01~18, TG-01~10의 번호 유일성 및 연속성, 제안 fixture v0.3의 메타데이터·정답 필드 일치, 가중합을 정적 확인했다. 이는 링크 대상의 의미적 타당성이나 모델·제품 동작을 증명하지 않는다. 새 X/CV/TG/N 사례는 전부 설계 기준이며 NOT RUN이다. v0.3의 읽기 전용 Git tree metadata는 제안이며 하네스·접근 관측·사람 판정은 미실행이다. 다른 세션이 발견한 RWT-01의 파일만으로 Git 추적 상태를 추론할 수 없는 공백은 v0.3에서 명시적 입력 계약을 제안해 보완했다.

이번 목표에서는 제품 실행·구현, 유료 모델 호출, 사용자 인증 변경, GitHub Projects 상태 변경, 커밋·푸시를 하지 않았다. 보안·Provider 공식 문서에 대한 일반적 확인과 별개로 실제 앱 정체성·공식 GUI 연동 허용·Provider 데이터 이동·OS별 권한 강제의 검증은 후속 과제다.
