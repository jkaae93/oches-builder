# 설계 독립 재평가

2026-11-16 · 범위: ARC-00 및 현재 로컬 ARC/ADR·계약·수용 사례. `master` f45e306의 `docs/`는 Git 미추적 초안이다. 원래 척도의 5점은 검증 가능한 계약과 근거의 존재이며 구현 또는 제품 시험 합격을 의미하지 않는다. 아래는 후속 독립 검토자의 판단이다.

**이력:** 점수·Gate의 최신 정정은 [설계 평가 기준 정정 및 독립 재채점](REVIEW_DESIGN_CRITERIA_CORRECTED.md)을 따른다. 아래 90점 및 당시 UNKNOWN 문구는 당시 평가의 기록이며 최신 판정이 아니다.

| 범주 | 점수 | 가중 | 근거와 잔여 한계 |
|---|---:|---:|---|
| Requirements Coverage | 5/5 | 20 | [추적 RT-01~38](REQUIREMENTS_TRACEABILITY_V2.md#제품-목표와-판정-규칙), [기능 기준](REQUIREMENTS_ACCEPTANCE.md#추적과-수용-기준), [비교 기준](EVALUATION_OBSERVABILITY_SPEC.md#구성-비교개선의-판정-계약-후보): 목표·소유·시험 연결 |
| Architecture & Module Boundaries | 5/5 | 15 | [공통 및 C01~C08](INTERFACE_CONTRACT_V1.md#공통-의미와-책임), [X01~X24](CONTRACT_ACCEPTANCE_MATRIX.md): 책임·호출·오류·검증 조건. 전체 문서의 모순 부재는 아직 전수 확인하지 못함 |
| Extensibility & Compatibility | 5/5 | 15 | [Capability 계약](CAPABILITY_CONTRACT_V1.md), [ADR-016 D01/D05](adr/ADR-016-core-contract-baseline.md): 범위·버전·미지원/UNKNOWN 구분 |
| Security & Authentication | 4/5 | 12 | [설치별 등록·연결·중계](CLIENT_INSTALLATION_AUTH_DESIGN.md#서명-중계-및-명령-변조-경계), [macOS 후보](ARC-11-G3-MACOS-DESIGN.md): 확장 종단 신원, 신뢰 UI 및 서명 대리 방어 수단이 미결 |
| Reliability & Recovery | 4/5 | 8 | [저장·복구](SQLITE_STORAGE_RECOVERY_CONTRACT.md#오류와-복구), [실행](ARC-06.md): 장애·취소·Unknown 설계; [anchor·intent](RECOVERY_FRESHNESS_ANCHOR.md#역할과-후보-인터페이스)의 실행 가능한 신뢰 수단 미결 |
| Data & Memory Consistency | 4/5 | 8 | [ARC-08](ARC-08.md), [ARC-10](ARC-10.md), [복원·삭제](SQLITE_STORAGE_RECOVERY_CONTRACT.md#백업복원과-삭제): 정본·출처·삭제 구분; 복구 후 최신성 기준점 미결 |
| Verifiability & Observability | 4/5 | 8 | [평가](EVALUATION_OBSERVABILITY_SPEC.md#4-양성부정-대조와-판정-순서), [관측 완전성](OBSERVATION_COMPLETENESS_CONTRACT.md): 수용 사례 존재; OS별 독립 관측·완전성 수단 미선택 |
| Feasibility & Cost | 4/5 | 4 | [Provider·비용](PROVIDER_MVP_FEASIBILITY.md#비교-가능한-구현검증-계획-및-비용-불확실성-v02): 공식 경로·계획 가정·UNKNOWN 구분. 선택 경로와 전체 플랫폼의 실제 비용·실현 근거 미완 |
| **합계** | | **90/100** | 20+15+15+12+8+8+8+4 |

## 하드 게이트

G1 PASS: 요구사항·모듈·사례 추적. G2 UNKNOWN: 발견한 복원 세대 충돌은 수정했으나 전체 문서의 모순 부재 검토 미완. G3 UNKNOWN: 확장/Host 종단 신원과 인증된 복구 intent의 안전 수단 미결. G4 PASS: 공식 근거와 미검증 범위를 구분. G5 PASS: 논리 정본과 소유권 정의. G6 PASS: 장애·재시도·취소·불확실 복구 정책 정의. G7 PASS: 템플릿 검증·버전·신뢰 경계 정의. 이 PASS는 제품 실행의 성공을 뜻하지 않는다.

G8은 독립 검토자가 원문의 **핵심 기능 수용 기준과 검증 방법의 정의**에 대해 PASS로 판단했다. [비교 집계 양·부정 oracle](fixtures/PAIRED_COMPARISON_ORACLE.md)과 [비교 판정 계약](EVALUATION_OBSERVABILITY_SPEC.md#구성-비교개선의-판정-계약-후보)이 기능 검증의 제안 기준을 제공한다는 근거다. 반면 [직전 재평가](REVIEW_CLIENT_AUTH.md#hard-gate-및-견해-차이)는 대표 실제 작업 oracle 및 품질 목표 기준의 충분성이 불명이라 UNKNOWN으로 판단했다. 이 견해 차이는 해소되지 않았다. 어느 해석에서도 실제 작업 모집단·운영 임계치와 제품 시험은 미확정/NOT RUN이다.

**Verdict: CONDITIONAL.** 90점이더라도 G2/G3 UNKNOWN은 통과가 아니다. 이 검토는 제품의 보안·지원·운영 준비를 보증하지 않는다. 로컬 계약 테스트 32개 및 합성 JCS 일부 대조는 성공했지만 위 게이트의 제품 통합 검증을 대체하지 않는다.

## G2 후속 독립 대조

독립 검토자는 C01~C08 각각을 책임 ARC의 주요 인터페이스와 대조했다. C01은 ARC-03/15, C02는 ARC-15/04, C03은 ARC-04/05, C04는 ARC-07/06, C05는 ARC-06/10, C06은 ARC-08/10, C07은 ARC-09/07/10, C08은 ARC-11/12/13과 비교했다. 소유권·호출·오류·버전의 주요 계약은 대체로 정합하나 C08의 ARC-11 `channel binding` 표현이 검증된 보장처럼 읽힐 여지를 발견했다. [ARC-11 §3](ARC-11.md#3-api와-버전)에서 검증된 연결 객체와 암호학적 channel binding을 구분하고 미검증 경로의 위험 기능 차단을 명시했다. wire 상세 등 명확히 위임된 항목의 부재는 그 자체로 모순으로 보지 않았다.

수정 후 독립 검토자가 C08을 다시 대조했고, 지정된 8개 연결에서 검토한 소유권·호출 방향·오류·버전 계약의 구체적인 잔여 모순을 발견하지 못했다. 원문의 설계 정합성 기준에 따라 **G2 PASS**로 재판정한다. 이 판정 범위는 열거된 8개 연결의 문서 계약이며 모든 문서와 제품 구현의 무결성을 증명하지 않는다. 종단 중계 저항의 가능성과 강제는 별도 G3 문제로 UNKNOWN을 유지한다. 이 후속 판정이 위의 최초 G2 UNKNOWN을 대체한다.
