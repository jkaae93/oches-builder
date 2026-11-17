# 복구 최신성 기준점 계약

상태: **설계 결정 기준** · 2026-11-16 · ARC-10 소유 · 제품 구현 및 대상 OS 시험 **NOT RUN**. [저장·복구 계약](SQLITE_STORAGE_RECOVERY_CONTRACT.md)의 삭제·철회 원장, rollback 탐지 및 승인된 복구 intent 보호 계약을 확정한다. 로컬 기본 모드는 사용자 데이터의 서버 업로드나 계정 사용을 전제하지 않는다.

## 보장 범위와 한계

DB와 함께 복원되거나 삭제될 수 있는 파일, DB 내부 hash chain, 서명만으로는 과거의 유효한 상태가 최신인지 증명할 수 없다. 별도 기준점이 원장 전체를 복원할 수 있게 하지도 않는다. 신뢰할 수 있는 최신 기준점과 원장 양쪽이 일치하고 서명이 검증되지 않으면 `RECOVERY_QUARANTINED` 상태로 전환해 과거 데이터의 노출·권한 복구·위험한 실행을 차단한다. 관리자 권한 또는 OS 자체가 손상된 공격자에 대한 방어는 로컬 모드의 보장 범위가 아니다.

Apple은 `ThisDeviceOnly` 항목이 같은 기기 백업에 복원될 수 있으며 다른 기기로 이전되지 않는다고 설명한다. 따라서 로컬 기본 모드는 macOS Keychain 항목의 접근 제어·별도 `RecoveryLedger`·서명된 `DurableIntent`의 조합으로 단조 진행을 추적하되, 전체 디스크+Keychain 이미지를 동시에 과거로 되돌리는 공격에 대해서는 선택적 Tier 2 외부 CAS anchor로 방어 범위를 구분한다. [Apple 접근성](https://developer.apple.com/documentation/Security/restricting-keychain-item-accessibility), [Keychain 동기화](https://developer.apple.com/documentation/security/ksecattrsynchronizable)

<a id="역할과-후보-인터페이스"></a>
## 역할과 Two-Tier `FreshnessAnchor` 인터페이스

- ARC-10은 workspace별 순번(`sequence`), 이전 digest(`previousHeadDigest`), 사건 유형·대상 digest, 최소 필요한 삭제/철회 내용으로 구성된 append-only `RecoveryLedger`를 SQLite DB 디렉터리 밖의 별도 보호 위치에 관리한다. 원장의 기밀성과 무결성, 대상 식별자의 민감성 및 보존 기간은 ARC-09 정책을 따른다. 비밀이나 삭제된 본문은 포함하지 않는다.
- 별도 `FreshnessAnchor`는 `(workspaceId, epoch, sequence, headDigest, storeGeneration)`을 보관한다. `read()`는 인증된 현재 값 또는 `UNAVAILABLE`/`UNKNOWN`을 반환한다. `advance(expected, next)`는 동일 `epoch`에서 `next.sequence == expected.sequence + 1` 및 `next.previousHeadDigest == expected.headDigest`를 원자적으로 비교·갱신하거나 충돌·실패를 반환한다. `epoch` 교체는 기존 세대 폐기와 Desktop 신뢰 UI의 명시적 복구 절차를 요구한다.

### Tier 1 — 기본 로컬 모드 (`LOCAL_KEYCHAIN_SEALED_ANCHOR` / `LOCAL_TPM_NV_ANCHOR`)

- **macOS (`LOCAL_KEYCHAIN_SEALED_ANCHOR`):** Core는 SQLite DB 파일과 분리된 전용 Keychain 항목(앱 코드 서명 ACL 및 `ThisDeviceOnly` 접근 제어 적용)에 최신 단조 anchor 레코드 `(workspaceId, epoch, sequence, headDigest, storeGeneration)`를 봉인해 보관하고, SQLite DB 디렉터리 외부의 별도 append-only `RecoveryLedger` 파일에 Core의 Keychain/Secure Enclave `intentSigningKey`로 서명된 사건 연쇄를 기록한다.
- **Windows / Linux (`LOCAL_TPM_NV_ANCHOR`):** 지원 장치에서 TPM 2.0 NV Extend/Counter(`TPM2_NV_Extend` / NV Counter index, 단일 writer 및 OS NV 인가 정책 적용)를 우선 사용하며, 미지원 환경에서는 OS 보안 저장소 + 별도 서명 `RecoveryLedger`를 사용한다. [TCG TPM 2.0 명령 명세 §31.8~31.9](https://trustedcomputinggroup.org/wp-content/uploads/TPM-Rev-2.0-Part-3-Commands-01.38.pdf), [TCG TPM 2.0 구조 §37.2.6.5](https://trustedcomputinggroup.org/wp-content/uploads/TPM-2.0-1.83-Part-1-Architecture.pdf)
- **Tier 1 위협 경계:** 로컬 모드는 의도치 않은/부분적 DB 파일 교체, 오래된 백업 복원, 비승인 원장 변조를 탐지하고 차단한다. OS/root 권한 공격자가 전체 머신의 디스크와 Keychain/보안 저장소 이미지를 동시에 과거 시점으로 되돌리는 전면적 시스템 rollback까지 방어한다고 주장하지 않으며, 해당 위협 방어가 필요한 환경은 Tier 2를 사용한다.
- **Keychain/TPM 저장 실패 시:** 평문 파일 fallback이나 자동 TPM 초기화(`Initialize`)를 금지하며 즉시 `UNAVAILABLE`/`RECOVERY_QUARANTINED`로 차단한다. [Microsoft TPM 초기화 안내](https://learn.microsoft.com/en-us/windows/security/hardware-security/tpm/initialize-and-configure-ownership-of-the-tpm)

### Tier 2 — 선택적 외부 CAS 모드 (`EXTERNAL_OBJECT_CAS_ANCHOR`)

- 전체 머신 이미지 rollback 탐지가 필요한 경우 사용자가 명시적으로 선택할 수 있는 옵션이며, 로컬 기본 모드에는 네트워크 의존성을 추가하지 않는다.
- Google Cloud Storage의 `ifGenerationMatch`(세대 불일치 시 412 실패) 또는 Amazon S3의 `If-Match`(ETag 불일치 시 쓰기 거부) 조건부 쓰기를 사용해 신뢰 서비스/버킷에 최소 서명 anchor envelope `(workspaceIdHash, epoch, sequence, headDigest, signature)`만 저장한다. [Google Cloud Storage 조건](https://docs.cloud.google.com/storage/docs/request-preconditions), [Amazon S3 조건부 쓰기](https://docs.aws.amazon.com/AmazonS3/userguide/conditional-writes.html)
- ETag/generation은 동시성 CAS 수단이지 사건 정당성의 증명이 아니므로, 갱신 대상은 반드시 Core `intentSigningKey` 서명과 `sequence == expected + 1` 및 이전 `headDigest` 일치를 검증한 뒤 조건부 갱신한다.
- 외부 모드에는 원문·비밀·삭제 본문을 전송하지 않으며, 안정적 digest의 연결 가능성과 비용·보존 정책을 사용자에게 안내한다. 오프라인·권한 거부·412/409·객체 삭제·갱신 결과 불명 시 현재 head를 안전하게 재조회·대조할 때까지 정상 복원과 위험 동작을 차단한다.

### 로컬 TPM 연동 세부의 동작 규율

- `TPM2_NV_Extend`를 사용할 때 논리 `(workspaceId, epoch, sequence, headDigest)`와 Extend 해시를 혼동하지 않는다. workspace/epoch별 보호 index에 초기 zero digest부터 **승인된 서명 `DurableIntent`의 정확한 RFC 8785 JCS 바이트**를 순서대로 `H(이전 값 || intentBytes)`로 확장해 `anchorDigest`를 산출하며, 응답 유실 시에는 단일 writer 배타 접근이 입증된 상태에서 직전 digest 또는 정확히 1회 확장한 기대 digest와 일치하는 경우에만 완료로 간주하고 그 외에는 `RECOVERY_QUARANTINED`로 격리한다.
- TPM NV Counter를 병행·사용하는 경우 아래 중단 상태 대조 규칙을 적용하며, counter 숫자만으로 분기나 서명 없는 원장을 승인하지 않는다.

| 재시작 관찰 (TPM Counter 모드) | 처리 |
|---|---|
| 신뢰 가능한 anchor와 완전한 원장 head·counter가 일치 | 서명·승인 및 DB/파생물 반영을 확인하고 미완료 삭제를 계속 추적 |
| counter가 원장보다 앞서거나 비정상 종료 후 예상 밖 값 | 승인된 유일 head를 증명할 수 없으면 `RECOVERY_QUARANTINED`; 원장을 임의로 앞으로 옮기지 않음 |
| 원장이 anchor보다 앞섬 | 아래 `DurableIntent` 서명·승인 체인·단일 단계 조건이 모두 입증된 경우만 1회 재시도; 불명이면 `RECOVERY_QUARANTINED` |
| 같은 counter의 다른 head, index 소실·재생성 또는 장치 교체 | rollback/분기 가능성으로 `RECOVERY_QUARANTINED`; 숫자가 같다는 이유로 신뢰하지 않음 |

## 쓰기·중단·복원 순서

1. 단일 workspace writer가 새 삭제/철회/복원 사건을 기존 원장 head에 결부해 내구성 있게 준비·기록한다. 관련 데이터의 신규 읽기·사용은 먼저 막고 사건이 완료되기 전에는 삭제·철회 완료를 반환하지 않는다.
2. Core는 서명된 `DurableIntent`를 `RecoveryLedger`에 기록한 뒤 `FreshnessAnchor.advance(expected, next)`를 수행한다. anchor 성공을 확인하고 관련 DB 상태·인덱스·캐시·백업 파생 데이터 삭제를 완료한 후에만 `COMPLETE`를 반환한다. DB·원장·anchor는 단일 OS/하드웨어 트랜잭션이 아니므로 아래 인증된 `DurableIntent` 규약에 따라 재시작 후 조정한다.
3. anchor와 원장이 같으면 무결성 및 DB 반영 상태를 확인한다. 원장이 정확히 한 사건 앞서는 경우 hash 연결만으로 사건의 진위나 사용자 승인을 신뢰하지 않고, 아래 `DurableIntent` 서명과 신뢰 UI 승인 체인이 모두 입증된 경우에만 차단 상태에서 anchor 갱신을 1회 재시도한다. 그 증거가 없거나 결과를 확인할 수 없으면 자동 갱신하지 않고 `RECOVERY_QUARANTINED`로 격리한다.
4. 백업 manifest에는 snapshot 당시의 `(epoch, sequence, headDigest, storeGeneration)`을 포함한다. 복원 시 현재 anchor와 복원본을 비교하고, 최신 `RecoveryLedger`에서 snapshot 이후 사건을 검증·재적용한다. 연속된 원장이나 검증 가능한 현재 상태가 없으면 격리를 유지한다. 백업 사본 자체의 삭제 완료 여부도 별도로 추적한다.
5. anchor 분실, 새 기기 이전 또는 전체 시스템 복원으로 최신성을 증명할 수 없으면 `RECOVERY_QUARANTINED`를 유지하고 사용자에게 데이터 복구 범위와 제한을 알린다. 새 `epoch` 시작은 기존 데이터가 삭제·철회 정책을 준수한다는 증명이 아니므로 Desktop 신뢰 UI의 명시적 사용자 확인 없이 격리를 해제하지 않는다. 외부로 이미 유출된 사본의 물리적 삭제는 보장하지 않는다.

## 인증된 `DurableIntent`와 중단 복구 계약

1. **생성 및 원자적 커밋:** 모든 삭제·철회·백업 복원 전이에 대해 ARC-09는 검증된 Desktop 신뢰 UI에서 결정한 승인(`approvalId`, actor, workspace, 행위·대상 digest, 정책 버전, 만료, 등록 세대)을 발급하고 서명된 승인 체인에 기록한다. ARC-10은 해당 승인이 유효한 동안 권한을 재검사하고, RFC 8785 JCS로 정규화된 `DurableIntent` 레코드(`intentId, workspaceId, epoch, sequence, previousHeadDigest, action, targetDigest, approvalId, policyVersion, storeGeneration, issuedAt`)를 만든다. 원문·자격증명은 넣지 않는다. `approvalId` 소비, intent 레코드, `INTENT_COMMITTED` 감사 항목은 메인 SQLite DB(`WAL` + `synchronous=FULL`)의 단일 트랜잭션에서 원자적으로 커밋한다.
2. **서명 및 `RecoveryLedger` 기록:** DB 커밋 후 Core는 전용 OS 보호 `intentSigningKey`(Keychain/Secure Enclave, 일반 DB·백업·로그 복사 금지)로 canonical `DurableIntent` 바이트에 서명(`keyId`, 알고리즘, JCS 버전 포함)하고, DB 디렉터리 밖의 append-only `RecoveryLedger`에 추가한 뒤 `FreshnessAnchor.advance(expected, next)`를 호출한다. 서명은 Core가 해당 내용을 발행했다는 증거이며, 침해된 Core 자체를 방어한다고 주장하지 않는다. [NIST 디지털 서명 정의](https://csrc.nist.gov/glossary/term/digital_signature)
3. **DB 커밋과 서명·원장 기록 사이 중단 처리(Fail-Closed):** 재시작 시 메인 SQLite DB에 `INTENT_COMMITTED` 행이 있으나 서명된 `RecoveryLedger` 항목이나 `FreshnessAnchor` 진행이 없는 경우, Core는 **서명 없는 DB 행을 단독으로 신뢰해 사후 서명하지 않는다**. 대신 해당 `approvalId`가 검증된 신뢰 Desktop UI 세션의 서명된 승인 체인에 실재하고 현재 정책·대상·만료가 일치하는지 독립 검증하며, 독립 검증이 불가능하거나 하나라도 불일치하면 workspace를 즉시 `RECOVERY_QUARANTINED` 상태로 전환해 Desktop UI에서의 명시적 사용자 재승인을 요구한다.
4. **단일 단계 멱등 재시도 및 격리 조건:**
   - **재시도 허용(유일한 경우):** `ledger.sequence == anchor.sequence + 1` 이고 `ledger.previousHeadDigest == anchor.headDigest` 이며, 해당 `DurableIntent`의 `intentSigningKey` 서명과 발급 당시 정책 키·승인 체인이 모두 유효할 때만 Core는 차단 상태에서 `FreshnessAnchor.advance(expected, next)`를 재시도한다.
   - **즉시 `RECOVERY_QUARANTINED` 격리 조건:** (a) 분기(같은 `sequence`에 서로 다른 `headDigest` 또는 이전 `headDigest` 불일치), (b) `ledger.sequence - anchor.sequence > 1` 간격, (c) `anchor.sequence > ledger.sequence` (DB/원장 rollback 징후), (d) 알 수 없거나 철회된 `intentSigningKey` 서명, (e) `FreshnessAnchor.read()`가 `UNAVAILABLE`/`UNKNOWN`이거나 anchor 누락. 격리 상태에서는 모든 읽기·쓰기·실행·외부 전송을 차단한다.
5. **응답 유실 및 완료 조건:** 서명 후 anchor 응답 유실 시 `FreshnessAnchor.read()`로 인증 조회해 현재 head가 새 intent와 같으면 갱신 완료로 판정하고, 이전 head이면 위 단일 단계 조건 하에 동일 서명 intent만 재시도한다. DB 상태 반영과 인덱스·캐시·백업 각각의 삭제 완료를 확인하기 전에는 ARC-10 `COMPLETE`를 반환하지 않는다. 전송 인증 nonce 저장소와 `intentId` 중복 검사는 별도로 관리한다.

## 검증 계약 및 상태

- 양성·음성 대조: DB만 과거로 복원(rollback 감지), 원장과 DB 동시 복원, 기준점까지 전체 복원, DB 커밋과 서명 사이 강제 종료(서명 없는 DB 행 단독 신뢰 거부), 서명 후 anchor 응답 유실(단일 단계 멱등 재시도), 위조/분기/순서 변경(`gap > 1`, same seq 다른 digest), 다중 writer 경합, anchor 분실/누락 시 `RECOVERY_QUARANTINED` 전환을 검증한다.
- `FreshnessAnchor`의 CAS 전이, 서명된 `DurableIntent` 검증, 단일 단계 복구 및 `RECOVERY_QUARANTINED` Fail-Closed 불변식은 [계약 시제품 테스트](contracts/test_freshness_anchor.py)로 단위 검증한다. 대상 OS(macOS Keychain ACL, TPM 2.0 하드웨어, GCS/S3 연동)에서의 실제 제품·전원 장애 시험은 **NOT RUN**이다. hash chain 자체는 변조 흔적 근거이지 승인 증명이 아니다. [NIST hash chain 정의](https://csrc.nist.gov/glossary/term/Hash_chain)
