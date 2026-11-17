# 계약 시제품 실험 기록 v0.1

검증일: 2026-11-16. 이 디렉터리는 설계 계약을 시험하기 위한 시제품이며 제품 Registry, Provider Adapter, 실행 엔진 또는 배포 코드가 아니다. [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12/)의 `$schema`와 제품 제안의 `schemaVersion`은 별개다. 수치 상한은 실험용이며 제품에서 승인된 설정이 아니다.

## 실행 방법과 실제 관찰

macOS 26.4 (25E246), Python 3.9.6, jsonschema 4.25.1, rfc8785 0.1.4. 격리된 Python 가상환경에 설치 후 다음 명령을 실행했다.

```sh
python -m pip install 'jsonschema==4.25.1' 'rfc8785==0.1.4'
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s docs/architecture/contracts -v
```

결과: 45개 unittest 메서드 통과. `test_rejections`는 13개 입력 변형, `test_fail_closed_cases`는 12개 변형, `test_process_crash_before_commit`은 3개 중단 지점을 subtest로 검사한다.

## 검증 범위

- AgentDefinition 시험 스키마가 ARC-15 예시 및 유효 포트·권한을 수용한다. 필수 필드 누락, 알 수 없는 버전·속성·포트 타입, 공백 역할, 잘못된 상한, 중복 tool·포트 ID, 잘못된 타입, 불완전한 permission을 거부한다. 바이트 상한, UTF-8 오류, 중복 JSON 키와 비유한 수를 별도 파서 실험으로 거부한다.
- Agent 노드만 있는 그래프 시험은 유효한 텍스트 포트 연결을 수용하고 중복 노드, 없는 노드·포트, 포트 타입 불일치, 같은 입력의 중복 연결, 미지원 버전·노드, JSON 포트의 미확정 상세 호환성 및 그래프 순환을 거부한다.
- Runtime 유한 상태 모델에서 취소 경합, 시작 전 취소, Unknown 자동 재시작 금지, 실제 종료 확인 전 취소 완료 금지, 관측된 상태 해소, 앱 종료와 외부 프로세스 종료 구분 및 네 종료 상태의 불변성을 검사했다. 이 모델은 실제 프로세스를 시작하거나 감독하지 않는다.
- 별도 supervisor 시제품은 Python 자식 프로세스의 시작 전 기록, 취소 요청·종료 대기, DB 오류 시 프로세스 미생성을 시험했다. 복구 시험은 시작 중 상태를 수동으로 만들어 Unknown으로 설정했으며 앱 강제 종료나 실제 Provider 재연결은 시험하지 않았다.
- 임시 SQLite DELETE/WAL + `synchronous=FULL`에서 상태 변경·이벤트·요청 기록의 동시 갱신 충돌, 같은 요청의 동시 반복 및 다른 입력 충돌, 세 쓰기 지점의 프로세스 강제 종료 뒤 미커밋 데이터 복구, snapshot/cursor 일관성, 백업 후 삭제 부활 부정 대조, 그리고 `test_nonce_retry_experiment.py`의 다중 프로세스 단회 nonce 소비·중복 요청 재조회·실행 1회 제한을 검사했다. 프로세스 중단은 전원 장애 시험이 아니다.
- `test_extension_secure_channel.py`에서 `EXTENSION_SECURE_CHANNEL.md` 및 `ADR-017`의 JCS transcript 양키 결부, 0-RTT 차단, static key/prologue 불일치 거부, 청크 순서·태그 변조 및 미완결 스트림 차단, 4 KiB 버킷 패딩, 키 철회·보안 저장소 실패(`KEY_UNAVAILABLE`) 및 `USER_ENROLLED_KEY`의 Desktop 요청별 승인 결합을 상태 머신 모델로 검증했다(실제 암호 라이브러리·Chrome/VS Code/macOS 런타임 시험은 아님).
- `test_freshness_anchor.py`에서 `RECOVERY_FRESHNESS_ANCHOR.md`의 `FreshnessAnchor` CAS 전이, 서명된 `DurableIntent` 검증, 응답 유실·단일 단계 중단 복구(`RECOVERED_ACTIVE`) 및 서명 없는 DB 행·rollback·분기(`fork`)·간격(`gap > 1`)·철회 키·기준점 누락 시 `RECOVERY_QUARANTINED` Fail-Closed 전환을 검증했다(실제 Keychain/TPM/GCS/S3 연동 시험은 아님).

## 한계와 실패 시 해석

시제품 상한·권한 표현은 실험을 위한 제안으로 ARC-04/15의 채택된 형식이 아니다. Agent-only 데이터 연결 검사는 실행 순서를 부여하지 않는다. 필수 입력은 그래프 연결 또는 `externalInputs` 선언이 있어야 하지만 선언만으로 실제 값이나 사용자 승인이 존재한다고 증명하지 않는다. 템플릿 전체 스키마, Task/Approval 등 노드, YAML, Provider Capability, 권한·승인 강제, 거대·깊은 입력의 자원 격리, 임의 텍스트의 비밀 탐지, 실제 Adapter 및 UI는 시험하지 않았다. supervisor의 취소 사례는 통제된 단일 프로세스이며 자식 트리, 정상 종료·취소 경합 및 실제 CLI 종료 의미를 검증하지 않는다. JSON 구조가 유효해도 실행할 수 있다는 뜻이 아니다. 파서의 최대 중첩 깊이 안전 처리도 입증하지 않는다.

SQLite 시험은 단일 macOS와 임시 로컬 파일시스템의 소규모 사례다. 다른 파일시스템·OS, 전원 차단, 전체 디스크, 손상, 백업·마이그레이션, cursor 만료·권한 철회, 실제 제품 트랜잭션과 외부 프로세스 생성은 시험하지 않았다. 세 쓰기가 원자적이어도 외부 CLI와 DB 사이의 정확히 한 번 실행을 보증하지 않는다. 이 시험만으로 G2 PASS 또는 제품 데이터 복구 보장을 주장하지 않는다.
