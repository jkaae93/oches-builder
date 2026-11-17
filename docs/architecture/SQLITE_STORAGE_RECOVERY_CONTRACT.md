# SQLite 저장·복구 계약 후보

2026-11-16 · **설계 결정 기준** · 소유: ARC-10. [ARC-10](ARC-10.md)의 상태·기록·삭제 및 snapshot 계약을 확정한다(SQLite `WAL` + `synchronous=FULL` + 30일 멱등성 보존 및 workspace 수명 tombstone + Two-Tier `FreshnessAnchor` + 서명된 `DurableIntent` + `RECOVERY_QUARANTINED` 격리). 실제 제품 구현, 파일시스템 전원 장애 내구성 및 대상 OS 실행 시험은 **NOT RUN**이다.

## 경계와 전제

- workspace마다 로컬 Core가 소유하는 DB를 두고 작업·승인 상태, 정규화 이벤트, 요청 결과, blob manifest를 정본으로 관리한다. 실제 사용자 프로젝트 파일은 이 DB의 소유물이 아니다. CLI 실행과 사용자 파일 변경은 DB 트랜잭션에 포함되지 않는다.
- 각 연결에서 `foreign_keys=ON`, `synchronous=FULL`을 설정하고 값을 확인한다. DB는 `journal_mode=WAL` 설정 결과가 실제 `wal`인지 확인한다. 지원 설정이 적용되지 않으면 쓰기와 실행을 막는다. 설정은 연결별 적용 범위에 주의한다.
- 여러 호스트에서 네트워크 파일시스템의 같은 WAL DB에 직접 접근하는 구성을 지원하지 않는다. 원격 workspace는 로컬 Core/저장소의 위치와 데이터 이동을 별도 검증하기 전 UNKNOWN이다. WAL에는 단일 writer와 긴 reader로 인한 checkpoint 지연 제약이 있다. [SQLite WAL](https://www.sqlite.org/wal.html)
- SQLite는 WAL + FULL의 내구성을 명시하지만, 실제 VFS·파일시스템·하드웨어의 sync 동작과 전원 장애 내구성은 별도 검증이 필요하다. NORMAL은 전원 장애 때 커밋이 유실될 수 있어 이 후보의 대체 설정으로 자동 전환하지 않는다. [SQLite PRAGMA synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)
- 하나의 원자적 전이를 구성하는 상태·이벤트·요청 결과·승인 소비는 동일한 DB 파일에 둔다. WAL에서 별도 `ATTACH` DB들을 하나의 트랜잭션으로 변경하더라도 각 DB는 개별적으로만 원자적이며 전체 파일 집합의 원자성은 보장되지 않는다. 별도 원장·anchor·blob은 장애 복구 절차로 조정한다. [SQLite WAL 제약](https://www.sqlite.org/wal.html)

## 변경과 실행의 경계

1. Core는 actor·workspace·operation·requestId와 정규화된 입력, 기대 revision을 검사한다. 권한 및 승인 소비는 상태 전이·이벤트·요청 결과와 같은 DB 트랜잭션에서 재검사한다. 하나라도 실패하면 모두 실패한다.
2. 동일 범위의 requestId와 같은 입력은 기존 결과를 반환한다. 입력이 다르면 충돌이다. 결과 보존 30일 이후에도 workspace 수명 동안 tombstone을 두어 `IDEMPOTENCY_EXPIRED`를 반환한다. 해당 tombstone이 유실된 복원본에서 과거 요청을 안전하게 중복 판정할 수 없다면 자동 재실행을 금지한다. 보존값은 ARC-10의 미승인 제안이다.
3. 시작 기록이 커밋된 후 CLI를 기동한다. 커밋과 기동 사이 또는 기동과 관측 사이의 중단은 실제 실행 여부가 불명일 수 있다. 재시작 시 Unknown으로 표시하고 확인 없는 자동 재실행을 금지한다. DB 원자성은 외부 효과의 정확히 한 번 실행을 보장하지 않는다.
4. 이벤트 cursor는 workspace, 저장소 세대와 위치에 결부하고 권한을 재검사한다. 삭제·복원 또는 보존 만료로 이어 읽을 수 없으면 gap/만료를 명시하고 재동기화한다. 다른 workspace의 cursor는 거부한다.

## 백업·복원과 삭제

SQLite Online Backup API로 일관된 DB snapshot을 만들고, 그 snapshot이 참조하는 불변 blob을 별도 manifest의 digest와 길이로 검사해 함께 보관한다. snapshot 생성부터 blob 복사 완료까지 참조 blob의 GC를 pin하거나 정지한다. blob의 동시 삭제, pin 또는 무결성을 확인할 수 없으면 백업 완료로 표시하지 않는다. 실행 중 DB 본 파일만 복사해 WAL 상태가 포함됐다고 가정하지 않는다. [SQLite Online Backup API](https://www.sqlite.org/backup.html)

복원은 격리된 위치에서 스키마 버전, `integrity_check`, `foreign_key_check`, manifest/blob 및 접근권한을 확인한 뒤 게시한다. `integrity_check`는 외래 키 위반을 검출하지 않으므로 두 검사가 모두 필요하다. [SQLite integrity_check](https://www.sqlite.org/pragma.html#pragma_integrity_check)

오래된 백업은 이후 삭제된 데이터를 다시 포함할 수 있다. 복원 전 snapshot 이후의 삭제 및 철회 기록은 [최신성 기준점 계약](RECOVERY_FRESHNESS_ANCHOR.md)에 따라 DB 디렉터리 밖의 별도 append-only 서명 `RecoveryLedger`와 Two-Tier `FreshnessAnchor`(로컬 Keychain/TPM 또는 선택적 외부 CAS)로 검증·재적용한다. 원장 또는 기준점이 일치하지 않거나 최신성·`DurableIntent` 서명을 증명할 수 없으면 즉시 `RECOVERY_QUARANTINED` 상태로 격리해 데이터 노출과 정상 복원을 차단하고 Desktop 신뢰 UI 복구 절차로 넘긴다. 백업을 사용할 수 없게 되거나 사용자 통제 밖 사본이 존재하면 삭제 완료를 단정하지 않는다. 논리 삭제가 SSD 등에서 물리적 복구 불가를 보장하지도 않는다.

## 복원 세대와 모듈 간 재동기화

복구 소유자는 ARC-10이다. 복원 대상은 쓰기·실행·외부 전송이 차단된 격리 상태로 열고, 기존 실행을 중지 요청하되 실제 종료 확인 전까지 계속 실행 중일 가능성을 표시한다. 복원 전에 실행된 프로세스나 외부 효과를 DB 복원으로 되돌렸다고 가정하지 않는다. 복원된 정본을 게시하기 전 새로운 예측 불가능한 `storeGeneration`을 발급하고 DB에 내구성 있게 기록한다. 이 값은 복원 이전 snapshot에 있던 값을 그대로 쓰지 않으며, 이전 세대와의 우연한 중복은 암호학적으로 무시할 수 있도록 충분한 난수를 사용한다. 생성·저장 실패 시 게시하지 않는다.

| 경계 | 세대 변경 시 계약 |
|---|---|
| ARC-10 → ARC-06/07 실행·작업 | 이전 세대의 진행 중·시작 불명 시도는 Unknown으로 표시하고 자동 재실행하지 않는다. 별도 관측으로 외부 프로세스의 신원과 상태를 확인해야 한다. 작업 성공 이력은 복원 시점의 기록이라는 사실을 표시하며 복원 이후 외부 산출물의 현재 상태를 뜻하지 않는다. |
| ARC-10 → ARC-09/11 권한·승인 | 백업 속 미사용 승인, 세션, nonce와 등록 권한을 현재 유효하다고 복원하지 않는다. 신뢰할 수 있는 현재 철회·정책 원장과 비교할 수 없으면 특권 기능을 차단하고 신원 재등록 및 새 승인을 요구한다. 이전 키가 여전히 OS에 존재한다는 사실은 기존 인가의 유효성을 뜻하지 않는다. |
| ARC-10 → ARC-08 Context/Memory | 파생 인덱스와 캐시는 복원 세대와 출처·접근권한을 재검사하기 전 주입하지 않는다. 최신 삭제·철회 이력과 대조가 불가능하면 관련 데이터는 격리한다. |
| ARC-10 → ARC-09 평가/산출물 | manifest와 blob 무결성 및 접근권한을 재검증하고 이전 평가를 과거 snapshot의 증거로만 취급한다. 현재 사용자 파일과 평가 snapshot의 일치 여부가 불명이면 현재 산출물 성공을 새로 주장하지 않는다. |
| ARC-10 → 클라이언트 | cursor와 revision은 세대를 포함한 쌍으로 비교한다. 이전 세대 cursor와 변경 요청은 `STALE_GENERATION`으로 거부하고 권한 확인된 새 snapshot을 요구한다. revision 숫자가 우연히 같아도 같은 상태가 아니다. |

이 규칙은 단독으로 rollback 감지의 완전한 해법이 아니다. 정당한 복원 경로를 우회해 DB 파일 전체를 과거 사본으로 교체하면 DB 안의 세대 값도 되돌아갈 수 있다. [최신성 기준점 계약](RECOVERY_FRESHNESS_ANCHOR.md)은 Two-Tier `FreshnessAnchor`(`LOCAL_KEYCHAIN_SEALED_ANCHOR`/`LOCAL_TPM_NV_ANCHOR` 및 선택적 `EXTERNAL_OBJECT_CAS_ANCHOR`)와 서명된 `DurableIntent`의 단일 단계 검증 및 실패 시 `RECOVERY_QUARANTINED` 격리를 정의한다. 각 Tier의 위협 경계(로컬 모드는 부분 교체·과거 백업 탐지, 전체 머신 이미지 rollback 방어는 Tier 2 선택)에 따라 최신성을 입증할 수 없으면 차단 조건을 해제하지 않는다.

## 오류와 복구

| 조건 | 계약 |
|---|---|
| 쓰기 경합 `BUSY` | 제한된 시간 동안만 재시도하고 실패를 반환한다. 외부 효과를 자동 재실행하지 않는다. |
| `BUSY_SNAPSHOT` | 기존 읽기 트랜잭션을 폐기하고 새 snapshot에서 권한·revision·입력을 모두 재검사한다. 기존 판단을 그대로 덮어쓰지 않는다. [SQLite result codes](https://www.sqlite.org/rescode.html#busy_snapshot) |
| `FULL`/`IOERR` | 현재 전이를 실패 또는 결과 불명으로 기록·표시하고 새 실행을 막는다. 성공 응답을 추측하지 않는다. 저장 공간 확보 후 무결성과 결과를 확인한다. |
| `CORRUPT`, WAL 손실 의심 | 원본을 보존하고 RecoveryRequired로 전환한다. 격리 복사본 진단 및 검증된 백업 복원만 허용한다. 자동 초기화·원본 삭제는 금지한다. |
| 장시간 reader 또는 WAL 증가 | reader 수명과 checkpoint 진행을 진단하고 제한 초과 시 안전하게 작업을 중단한다. 진행 중 snapshot이나 WAL을 임의 삭제하지 않는다. |
| migration 실패·중단 | 이전 백업을 보존하고 새 실행을 중지한다. 버전 및 검증이 불명확한 DB의 자동 downgrade를 금지한다. |
| 승인 철회와 실행 경합 | 같은 DB 내 승인 소비와 철회는 직렬화한다. 이미 시작된 외부 프로세스의 취소 요청과 실제 종료 확인을 구별한다. |

## 검증 계획 및 현재 증거

| 사례 | 기대 결과 | 상태 |
|---|---|---|
| 온라인 snapshot 후 추가 커밋 | 백업의 상태와 이벤트가 같은 이전 시점을 가리킴 | 격리 SQLite 실험 PASS |
| 백업 후 원본 삭제 | 구 백업에서 데이터가 되살아남을 재현하여 별도 삭제 원장의 필요성 확인 | 격리 SQLite 부정 대조 PASS; 삭제 원장은 NOT RUN |
| 외래 키 위반 | integrity_check의 ok와 별도로 foreign_key_check가 위반 검출 | 격리 SQLite 실험 PASS |
| 크기 제한에서 쓰기 실패 | 같은 트랜잭션의 상태 변경이 남지 않음 | 격리 SQLite 실험 PASS; 실제 디스크 고갈·전원 장애가 아님 |
| 커밋 전후 프로세스 강제 종료, 외부 CLI 기동 경합, restore·삭제 원장 유실 | 부분 커밋과 근거 없는 성공·자동 재실행·삭제 데이터 노출 0건 | 제품 NOT RUN |
| sync 실패·실제 전원 장애, 긴 reader, 복원 blob 유실, migration 중단 | 무결성·복구 상태를 확인하고 불명 시 차단 | 대상 OS/파일시스템 NOT RUN |
| 이전 백업 복원 후 같은 revision/cursor/승인 재사용, 실행 중 프로세스 생존 | 이전 세대 변경·인가 거부, 작업 Unknown, 현재 snapshot 재조회 | 제품 NOT RUN |
| 복원 경로를 우회한 DB 전체 rollback과 최신 anchor 유실 | `FreshnessAnchor` 및 서명 `DurableIntent` 대조로 rollback 탐지 또는 `RECOVERY_QUARANTINED` 격리 | 논리 계약 [단위 실험](contracts/test_freshness_anchor.py) PASS; OS·하드웨어 제품 시험 NOT RUN |

격리 실험은 [test_storage_backup.py](contracts/test_storage_backup.py)와 [test_freshness_anchor.py](contracts/test_freshness_anchor.py)이며 임시 DB/메모리 모델을 사용한다. RPO/RTO, 백업 빈도·보관 수와 저장 용량은 업무 요구·대상 환경·실측이 없어 미정이다. 단위 실험의 통과가 제품 내구성이나 실제 하드웨어 삭제 보증을 뜻하지 않는다.
