# 템플릿 그래프 의미 및 실행 경계 v1 — 설계 제안

상태: 구현 전 검토안 · 2026-11-16. ARC-00 v0.3, ARC-04/07/09/15와 [교차 계약](INTERFACE_CONTRACT_V1.md)의 누락된 논리 의미를 제안한다. 이 문서는 Provider, 플랫폼 또는 제품 Runtime의 특정 기능이 지원된다는 뜻이 아니다. v1 JSON Schema, 크기·정확한 직렬화 및 구현은 미확정이다. 설계 확정(Final, 2026-11-17): 크기·직렬화 규칙은 S4·S5·S6·S7로 확정. 정식 스키마 발행·구현은 제품게이트. 다음은 실행 전 검사해야 할 의미 계약이며 검증 불가 항목은 UNKNOWN과 실행 차단이다.

## 정본과 버전

TemplateVersion은 발행 후 불변 `(templateId,versionId,schemaVersion,graph,requirements,provenance)`이다. Instance는 생성 시 그래프 snapshot과 template 출처를 독립 복사해 `(instanceId,revision)`으로 식별하고 기존 TemplateVersion의 수정·삭제 표시가 인스턴스를 변경하지 않는다. definition 참조는 `(definitionId,revision)`으로 고정하고 인라인 정의도 같은 의미 버전을 갖는다. 사용자 수정은 instance revision을 증가시킨다. 정의, instance, 정책, 실행 환경의 Capability snapshot 또는 관련 승인 중 하나가 달라지면 이전 실행 검증은 stale이다. 버전이 아닌 불변 콘텐츠 해시를 사용한다 해도 출처와 권한은 별도 검사한다.

제품 형식은 `major.minor`, AgentDefinition의 의미 버전, Core protocol 버전, template 계열 versionId와 인스턴스 revision을 각각 별개로 보존한다. 지원하지 않는 major나 미지의 필수 의미는 `UNSUPPORTED_SCHEMA`/`UNKNOWN_SCHEMA_FEATURE`이며 적용·실행 불가다. 알 수 없는 선택 필드도 보존 가능성과 의미 안전성이 확인된 경우에만 보기/원본 그대로 내보내기 후보이며, 필드를 버리고 실행하지 않는다. Migration은 명시적 source/target 버전, 보존 불가 항목, 사용자 확인, 원본 및 과거 인스턴스 불변을 요구한다.

## 그래프와 타입

`Graph=(nodes,edges,externalInputs)`는 선언형 데이터다. 각 노드에는 `nodeId`(그래프 내 유일), `kind`, 버전 고정된 설정 또는 참조, 입력/출력 포트 목록, 필수 Capability 및 자원·권한 요구가 있다. 포트 ID는 해당 노드 및 방향 내 유일하고 `text`, `json`, `artifactRef`, `control`을 논리 타입으로 사용한다. `control`을 데이터로 전달하거나 다른 타입으로 묵시 변환하지 않는다. JSON 하위 구조가 명시되지 않은 경우 단순히 `json`이 같다는 이유만으로 의미 호환을 보장하지 않고 UNKNOWN으로 처리한다. 필수 입력은 호환되는 단일 데이터 출처 또는 명시적 외부 입력이어야 한다. externalInput 선언은 실제 값, 접근 권한이나 전송 승인을 증명하지 않는다.

`Edge=(kind,fromNode,fromPort,toNode,toPort)`는 양 끝이 존재하고 방향·kind·타입이 맞아야 한다. 다중 데이터 소스의 병합 의미가 정의되지 않았으면 UNKNOWN이고 단일 필수 입력에 둘 이상의 출처를 연결하지 않는다. 조건 실행, 반복과 서브그래프는 미래 확장 요구로 보관할 수 있지만 조건 언어·종료와 안전한 집행이 검증되기 전 v1 실행은 UNSUPPORTED/UNKNOWN이다. 무제한 반복과 순환 의존은 승인으로도 우회할 수 없다.

| 관계 | 출발 → 도착 | 의미·검사 | 실행에 미치는 효과 |
|---|---|---|---|
| `dependency` | Task 완료 → Task 시작의 control | 단방향 의존 DAG. 같은 작업 참조·중복·순환 거부 | 선행 Task의 ARC-09 검증된 성공 후에만 후행 Ready 후보. 권한은 전파하지 않음 |
| `data` | 출력 → 호환 입력 | 타입·방향·출처 revision·민감도 및 소비자 접근권 검사 | 데이터 흐름만으로 의존 순서를 생성하지 않는다. 필요한 순서가 별도 dependency에 없으면 실행 보류 |
| `roleBinding` | Task → Agent 정의 | 참조하는 Agent 정의와 Runtime Binding을 정확한 revision에 고정 | ARC-07이 배정 시 사용. 다중 Agent 선택의 의미 미확정이면 차단 |
| `toolRef` / `memoryRef` | Agent 또는 Task → Tool / Memory | 도구·메모리 참조와 해당 Capability/접근 정책 검사 | 도구 사용·원본 접근·외부 전송 승인이 자동으로 생기지 않음 |
| `evaluationRef` | Task → Evaluation | 평가 기준·대상 manifest와 evaluator 버전 고정 | 실제 Task 완료는 ARC-09 유효한 PASS 후에만 가능 |
| `approvalRef` | Task 또는 제안 행위 → Approval 요구 | 사용자 확인 대상·범위·버전·만료를 ARC-09 요청에 연결 | 그래프 노드 자체는 승인 증거가 아니며 Runtime은 실제 유효 승인 검증 |

## 노드별 책임·입출력·실패

| 종류 | 고정 입력 및 출력 | 소유·의미 | 실패·버전 영향 |
|---|---|---|---|
| Agent | ARC-04 정의 ref/인라인 revision, 역할·지침·포트·도구/권한; 결과는 선언된 출력 | ARC-04가 의미·Provider 변환, ARC-06이 실제 실행. 템플릿은 정의·요구만 참조 | 정의 누락/모르는 필수 의미 거부, Provider 변환의 필수 안전 속성 손실 차단; 정의 변경 시 검증 stale |
| Task | 목표·입력 참조·Agent binding·자원 상한·평가 요구; 결과는 attempt와 manifest 참조 | ARC-07이 작업/DAG·재시도, ARC-06이 시도, ARC-09가 평가를 소유 | missing input·상한·순환·충돌은 시작 차단; 실패/Unknown/중단은 구분 |
| Tool | 논리 capability ID·입출력·권한/대상 범위 | 실제 도구 구현·경로는 환경 binding과 공식 Provider/OS 계약에 남김. 템플릿은 실행 파일을 자동 선택하지 않음 | 필수 capability unsupported/unknown 또는 집행 미확인은 실행 차단; 자동 대체 금지 |
| Memory | ARC-08 memory/근거 ID·revision 및 선택 범위 | ARC-08이 유효성·선택을, ARC-10이 원본·인덱스 접근 수단을 소유 | 근거 변경·삭제·권한 철회는 stale/unknown; 저장된 기억이 사용자 전송 승인이나 작업 정본이 아님 |
| Evaluation | criterion·evaluator ID/version, Task/attempt/불변 artifact manifest와 환경 | ARC-09가 PASS/FAIL/INDETERMINATE, ARC-10이 결과 기록 | 버전 미일치·평가 근거 부족·저장 실패는 성공 차단. 기존 평가를 새 산출물에 재사용 금지 |
| Approval | 행위·대상·범위·대상 revision·유효기간 및 요청 주체 | ARC-09가 실제 결정을 발급·철회하며 ARC-11의 신뢰 UI를 통해 확인 | 노드는 사용자 결정이 아님. 미승인·철회·대상 변화·미집행은 실행 차단 |

위 표는 이 종류들을 **표현하고 안전하게 거부할 의미**를 정의한 것이다. Adapter별 Tool·메모리 전송·Evaluation·승인 집행이 구현 또는 검증됐다는 지원 목록이 아니다. GUI 편집기의 좌표·색상은 실행 권한과 분리한다.

## 검증 순서와 원자적 경계

1. 제한된 입력 크기·깊이·리소스 검사와 안전한 파싱을 수행한다. JSON 중복 키, 비유한 수, YAML의 실행형 태그·외부 참조, 미검증 alias는 거부한다. 구체 상한·허용 YAML 부분집합은 S5·S6으로 확정(2026-11-17 Final). 원본 사용자의 데이터에 비밀이 있을 수 있으므로 자동 탐지만으로 안전한 내보내기를 보장하지 않는다.
2. 지원하는 `schemaVersion`, 필수 속성·종류, ID 유일성과 참조 대상, 포트 방향·유형 및 연결 수를 검사한다. 누락 참조는 `INVALID_REFERENCE`, 타입 불일치는 `PORT_MISMATCH`이며 둘은 외부 오류 분류 `INVALID_INPUT`의 세부 유형이다.
3. Task 의존 DAG, 데이터와 의존 순서 일치, 상한 및 자원 충돌을 검증한다. 공유 쓰기가 충돌할 때는 안전한 격리·직렬화 또는 충돌 해소가 검증되기 전 병렬 시작하지 않는다. 사용자의 일반적 확인은 실제 충돌 통제를 대체하지 않는다.
4. ARC-05/06의 최신 snapshot과 요구 Capability를 비교하고 각 필수 요구가 supported인지 확인한다. 의미 등가성·강제 가능성이 모호하면 unknown이다. ARC-09의 정책·승인과 실제 집행 가능성은 별도로 판정한다.
5. ARC-15는 인스턴스 revision, 정의 revision, snapshot과 정책 버전에 결부된 보고서를 반환한다. ARC-07은 승인·검증된 정확한 revision의 작업 DAG를 작성하며 ARC-06에 요청 직전 동일 버전·승인·환경을 재검증한다. 로컬 저장과 외부 프로세스 생성은 원자적이지 않으므로 Unknown의 자동 재실행은 금지한다.

## 문서 수준 수용 사례와 증거

| ID | 입력·사전 조건 | 검증 가능한 기대 결과 | 상태 |
|---|---|---|---|
| TG-01 | 동일 templateVersion에서 두 프로젝트 인스턴스를 만들고 한쪽만 수정 | 다른 인스턴스와 원본 해시/revision 유지 | NOT RUN |
| TG-02 | 위 표의 각 노드와 관계를 문서 validator에 입력 | 노드의 소유 모듈·필수 버전·요구를 반환하며 unknown을 supported로 바꾸지 않음 | NOT RUN |
| TG-03 | 포트 누락·타입 불일치·순환·필수 입력 미연결 | INVALID_REFERENCE/PORT_MISMATCH/INVALID_INPUT, 정본 수정 및 실행 0 | NOT RUN |
| TG-04 | 데이터 연결만 있고 필요한 Task dependency가 없음 | 순서 추론 없이 실행 보류. 실행 계획과 상태의 독립 기록 | NOT RUN |
| TG-05 | 병렬 Task가 같은 파일을 쓸 수 있고 격리 증거 없음 | 일반 승인과 별개로 병렬 시작 0; 안전한 직렬화/격리 검증 후 재검사 | NOT RUN |
| TG-06 | revision 4 승인 후 Tool 또는 Memory 요구를 revision 5로 변경 | 이전 report/승인은 stale, 재검증·필요 승인 전 실행 0 | NOT RUN |
| TG-07 | 악성 입력·중복 키·unknown 필수 노드·YAML alias | 안전 파싱/의미 검사에서 거부, 가져오기만으로 명령 실행 0 | NOT RUN |
| TG-08 | Task와 Evaluation에 서로 다른 artifact/criteria 버전 | Task 성공 전이 거부 또는 INDETERMINATE | NOT RUN |
| TG-09 | 유한 반복·조건·서브그래프를 지원 여부 확인 전 실행 | UNSUPPORTED/UNKNOWN 및 실행 차단. 표현 자체의 보관·보기는 안전 검토 결과에 따름 | NOT RUN |
| TG-10 | 보고서 검증 뒤 Provider 버전과 실행 대상이 달라짐 | 필수 Capability와 실제 행위/승인 범위를 다시 확인하며 미확인 시 차단 | NOT RUN |

Agent-only 입력과 제한된 그래프에 대한 시제품 사례만 [실험 증거](contracts/EXPERIMENT_EVIDENCE.md)에 별도로 기록했다. TG-01~10의 전체 제품 시험을 대체하지 않는다. 공식 Provider 기능은 [지원 범위 증거](COMPATIBILITY_EVIDENCE_V1.md)로 분리하며 이 문서의 논리 의미는 Provider 공식 문서의 주장으로 돌리지 않는다.
