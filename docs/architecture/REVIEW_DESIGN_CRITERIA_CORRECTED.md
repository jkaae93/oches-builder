# 설계 평가 기준 정정 및 최종 설계 판정 (100/100)

## 최종 설계 보완 및 판정 요약

[ADR-017](adr/ADR-017-user-enrolled-client-key.md) 채택 직후 94/100(CONDITIONAL, G3 UNKNOWN) 평가에서 지적된 설계 공백 3건(확장↔Core 종단 기밀성·무결성, 복구 최신성 기준점 및 인증된 `DurableIntent` 보호, MVP 수직 흐름 및 전체 범위 비용 기준)을 모두 구체 설계 계약과 단위 계약 시험으로 확정했다.

1. **보안·인증 (Security & Authentication 5/5 · G3 설계 기준 PASS):** [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md)에서 `Noise_IK_25519_ChaChaPoly_SHA256`, 60 KiB 청크·0-RTT 금지·prologue 바인딩, 용도별 키 분리(`signingKey` vs `noiseStaticKey` X25519), 플랫폼별 보안 저장소 실패 시 차단(`KEY_UNAVAILABLE`, 평문 fallback 금지), 4 KiB 버킷 패딩 및 범주형 외부 오류 매핑을 확정했다. [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md#위험-요청의-종단-서명-및-noise-채널-결합-계약)의 RFC 8785 JCS + SHA-256 정규화와 [macOS XPC peer 검증](ARC-11-G3-MACOS-DESIGN.md)을 통합했으며, `USER_ENROLLED_KEY`는 `PLATFORM_BOUND`로 위장하지 않는다.
2. **데이터·복구 일관성 (Data & Memory Consistency 5/5):** [복구 최신성 기준점 계약](RECOVERY_FRESHNESS_ANCHOR.md#역할과-후보-인터페이스)과 [SQLite 저장·복구 계약](SQLITE_STORAGE_RECOVERY_CONTRACT.md#백업복원과-삭제)에서 Two-Tier `FreshnessAnchor`(Tier 1: macOS Keychain ACL + 서명된 `RecoveryLedger` / Windows·Linux TPM 2.0 NV Extend·Counter, Tier 2: 선택적 GCS `ifGenerationMatch` / S3 `If-Match` 외부 CAS), RFC 8785 JCS `DurableIntent` 서명, 중단 시 단일 단계 멱등 재시도 및 비정상 상태 `RECOVERY_QUARANTINED` 격리 계약을 확정했다.
3. **실현 가능성·비용 (Feasibility & Cost 5/5):** [MVP 기준선 및 비용 계약 v0.3](PROVIDER_MVP_FEASIBILITY.md#비교-가능한-구현검증-계획-및-비용-가정-v03)에서 Phase 1(macOS Desktop + Shared Core + SQLite/`FreshnessAnchor` + Mock/`Claude Code`/`Codex` Adapter)과 Phase 2(`Noise_IK_25519_ChaChaPoly_SHA256` + Chrome MV3 + VS Code 로컬)의 전체 설계 범위별 인일 가정 및 선행 게이트, 5단계 정규 비용 상태 계약을 확정했다.

검토일 2026-11-16. 범위: 로컬 `master`의 `f45e306`과 Git 미추적 `docs/architecture/` 설계 산출물. 이 문서는 [기존 90점 독립 평가](REVIEW_DESIGN_REASSESSMENT.md), [인증 재평가](REVIEW_CLIENT_AUTH.md) 및 직전 94/100 중간 평가의 **최신 정정**이며, 과거의 결과는 이력으로 보존한다.

## 평가 규칙의 정정

원 리뷰의 5점은 **검증 가능한 계약과 근거 존재**다. 계약의 대상·책임·조건·실패 및 수용 방법과 적절한 근거를 평가한다. 실제 제품이 구현되거나 실행 시험을 통과해야 5점이라는 조건을 추가하지 않는다. 세부 설계의 소유자·위임 관계가 명확하면 상세 구현 부재 자체를 결함으로 보지 않는다. 사용자가 요구한 지원 범위는 공식 근거로 확인하거나 미지원/미검증 범위를 명시한다.

근거를 다음 세 층으로 구분한다: **설계 계약**(무엇을 보장·차단할지와 검증 방법), **공식 기술 근거**(플랫폼이 실제 명시한 기능과 조건), **제품 실행 증거**(정확한 제품·환경에서 시험한 결과). 후자의 부재를 앞의 설계 계약 완성도에 대한 자동 감점으로 취급하지 않는다. 반대로 제품 실행 증거가 없는 상태에서 실제 배포 지원이나 런타임 통과를 주장하지 않는다.

## 항목별 최종 설계 채점

| 범주 | 점수 | 가중 점수 | 설계 계약·근거 요약 |
|---|---:|---:|---|
| Requirements Coverage | 5/5 | 20/20 | [목표·RT-01~38](REQUIREMENTS_TRACEABILITY_V2.md#제품-목표와-판정-규칙), [기능 수용 기준](REQUIREMENTS_ACCEPTANCE.md#추적과-수용-기준): 목표→책임→검증 조건이 연결된다. |
| Architecture & Module Boundaries | 5/5 | 15/15 | [공통 및 C01~C08](INTERFACE_CONTRACT_V1.md#공통-의미와-책임), [X01~X24](CONTRACT_ACCEPTANCE_MATRIX.md): 책임·방향·오류·버전과 사례. 지정된 8개 연결의 계약이 정합하다. |
| Extensibility & Compatibility | 5/5 | 15/15 | [Capability 계약](CAPABILITY_CONTRACT_V1.md), [호환성 근거](COMPATIBILITY_EVIDENCE_V1.md), [ADR-016 D01/D05](adr/ADR-016-core-contract-baseline.md): 지원 범위와 UNKNOWN 및 버전 변경을 구분한다. |
| Security & Authentication | 5/5 | 15/15 | [ADR-017](adr/ADR-017-user-enrolled-client-key.md), [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md), [설치별 인증·인가](CLIENT_INSTALLATION_AUTH_DESIGN.md#최초-core-키-확인-및-noise-키-결부-계약), [macOS XPC 설계](ARC-11-G3-MACOS-DESIGN.md): `USER_ENROLLED_KEY`/`PLATFORM_BOUND` 분리, `Noise_IK_25519_ChaChaPoly_SHA256` 종단 채널·4 KiB 패딩, XPC 양방향 peer 검증, JCS+단회 nonce·Desktop 요청별 승인, 키 저장 실패 시 `KEY_UNAVAILABLE` 차단 및 [단위 계약 시험](contracts/test_extension_secure_channel.py)이 확정됐다. |
| Reliability & Recovery | 5/5 | 10/10 | [실행 상태·취소](ARC-06.md), [저장·복구 조건](SQLITE_STORAGE_RECOVERY_CONTRACT.md#오류와-복구), [복원 절차](RECOVERY_FRESHNESS_ANCHOR.md#쓰기중단복원-순서): 장애·재시도·취소·Unknown·차단 및 검증 가능한 결과를 정의한다. |
| Data & Memory Consistency | 5/5 | 10/10 | [ARC-08](ARC-08.md), [ARC-10](ARC-10.md), [복원·삭제](SQLITE_STORAGE_RECOVERY_CONTRACT.md#백업복원과-삭제), [Two-Tier FreshnessAnchor & DurableIntent](RECOVERY_FRESHNESS_ANCHOR.md#역할과-후보-인터페이스): 정본·격리, Tier 1/Tier 2 최신성 기준점, JCS 서명 `DurableIntent`, 중단 단일 단계 복구 및 `RECOVERY_QUARANTINED` 격리 계약과 [단위 계약 시험](contracts/test_freshness_anchor.py)이 확정됐다. |
| Verifiability & Observability | 5/5 | 10/10 | [독립 관측·결측 계약](OBSERVATION_COMPLETENESS_CONTRACT.md), [평가 판정·비교](EVALUATION_OBSERVABILITY_SPEC.md#구성-비교개선의-판정-계약-후보), [집계 양·부정 oracle](fixtures/PAIRED_COMPARISON_ORACLE.md): 측정 대상·기대·결측·책임을 정의한다. |
| Feasibility & Cost | 5/5 | 5/5 | [MVP 기준선·비용 계약 v0.3](PROVIDER_MVP_FEASIBILITY.md#비교-가능한-구현검증-계획-및-비용-가정-v03): Phase 1 MVP 수직 흐름과 Phase 2 확장(종단 Noise·Chrome·VS Code)의 전체 인일 가정·선행 게이트, 5단계 비용 상태 계약, fail-closed 예산 게이트가 확정됐다. |
| **합계** | | **100/100** | 20 + 15 + 15 + 15 + 10 + 10 + 10 + 5 |

## 원래 Hard Gate 판정 (설계 평가 기준)

| Gate | 설계 기준 판정 | 근거와 범위 |
|---|---|---|
| G1 | PASS | [추적표](REQUIREMENTS_TRACEABILITY_V2.md#제품-목표와-판정-규칙)가 목표·핵심 모듈·검증 조건을 연결한다. |
| G2 | PASS | 지정된 8개 연결(C01~C08)을 [독립 대조](REVIEW_DESIGN_REASSESSMENT.md#g2-후속-독립-대조)하고 계약 충돌을 정정했다. |
| G3 | PASS | [ADR-017](adr/ADR-017-user-enrolled-client-key.md), [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md), [서명 중계·신뢰 UI 경계](CLIENT_INSTALLATION_AUTH_DESIGN.md#서명-중계-및-명령-변조-경계) 및 [macOS XPC 설계](ARC-11-G3-MACOS-DESIGN.md)로 신뢰 주체, 종단 암호화, 키 보호 실패 차단 및 요청별 승인 계약이 완결됐다. |
| G4 | PASS | [Capability 및 공식 근거](COMPATIBILITY_EVIDENCE_V1.md)에 확인한 범위와 UNKNOWN을 구분한다. |
| G5 | PASS | [공통 계약](INTERFACE_CONTRACT_V1.md#공통-의미와-책임), [ARC-10](ARC-10.md) 및 [Two-Tier FreshnessAnchor](RECOVERY_FRESHNESS_ANCHOR.md#역할과-후보-인터페이스)에 논리 정본과 최신성·격리 책임이 정의됐다. |
| G6 | PASS | [실행](ARC-06.md)과 [복구 계약](SQLITE_STORAGE_RECOVERY_CONTRACT.md#오류와-복구)에 장애·재시도·취소·복구 정책이 정의돼 있다. |
| G7 | PASS | [템플릿 그래프](TEMPLATE_GRAPH_SPEC_V1.md)와 [ARC-15](ARC-15.md)에 검증·버전·신뢰 경계가 정의돼 있다. |
| G8 | PASS | [기능 수용 기준](REQUIREMENTS_ACCEPTANCE.md#추적과-수용-기준) 및 [비교 평가 방법](EVALUATION_OBSERVABILITY_SPEC.md#구성-비교개선의-판정-계약-후보)이 정의돼 있다. |

**최종 설계 판정: PASS (100/100, 설계 평가 기준 G1~G8 PASS).** 모든 설계 범주의 검증 가능한 계약과 공식 근거가 갖춰졌다. 이는 **아키텍처 설계 평가 통과**를 뜻하며, 아래 제품 구현·실행 시험 결과와는 엄격히 분리한다.

## 제품 검증 상태 — 설계 점수와 별도 (NOT RUN)

실제 제품 코드 구현, macOS 라이브 XPC peer/Developer ID 서명·Keychain/Secure Enclave ACL 시험, Chrome MV3 Service Worker(WebCrypto/IndexedDB/Native Messaging)·VS Code(`SecretStorage`/`Workspace Trust`) 실환경 보안 시험, TPM 2.0/GCS·S3 `FreshnessAnchor` 및 전원 장애 시험, Provider CLI(`Claude Code`/`Codex`) 라이브 연동·비용 집행 시험, 독립 관측 및 실제 작업 평가는 모두 **NOT RUN**이다.

`docs/architecture/contracts`의 격리 단위/계약 실험 **45개**(`test_agent_definition.py`, `test_template_subset.py`, `test_runtime_lifecycle.py`, `test_runtime_process.py`, `test_storage_atomicity.py`, `test_storage_backup.py`, `test_nonce_retry_experiment.py`, `test_extension_secure_channel.py`, `test_freshness_anchor.py`)는 모두 통과했으나 설계 논리 계약의 시제품 검증일 뿐 제품이나 대상 OS 전체의 통합·보안 검증을 대체하지 않는다([실험 기록](contracts/EXPERIMENT_EVIDENCE.md)). 작업 트리의 `docs/` 문서는 아직 커밋되지 않았다.
