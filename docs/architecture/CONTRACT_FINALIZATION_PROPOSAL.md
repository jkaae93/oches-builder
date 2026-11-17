# 공통 Core 계약 확정을 위한 설계 제안 v0.1

상태: **사용자가 D01~D08의 권고 방향을 설계 기준으로 채택** · 2026-11-16. [ADR-016](adr/ADR-016-core-contract-baseline.md)에 채택 범위와 남은 조건을 기록한다. XPC는 우선 검증 후보이고 구체 크기·서명 바이트 등 후보값은 미확정이다. 이 문서는 [ARC-00](ARC-00.md) v0.1~v0.3, [ADR-014](adr/ADR-014-multi-client.md), ARC-06/07/09~15, [교차 계약](INTERFACE_CONTRACT_V1.md)과 [수용 사례](CONTRACT_ACCEPTANCE_MATRIX.md)를 기준으로 남은 설계 결정을 검토 가능하게 묶는다. 채택 범위는 ADR-016에 정의하며 실제 제품 동작이나 OS/Provider 지원을 주장하지 않는다. D05의 구체 필드·정규화·수치와 D02의 제품 지원은 검증 전 후보로 남는다.

## 1. 확정 범위와 원칙

목표는 Desktop/VS Code/Chrome에서 공통 Core를 호출할 때 객체의 소유자, 요청과 결과, 오류, 버전, 승인·인증, 중복과 복구의 의미를 하나로 정하는 것이다. **설계 확정**은 특정 대상과 동작을 문서상 검토 가능한 수준으로 선택하는 일이고 **제품 지원 승인**은 OS/Provider별 구현과 안전·정상·장애 시험에 근거한 별도 단계다. 한 단계를 완료해도 다른 단계의 완료나 G3 통과를 추론하지 않는다.

- 공통 도메인·정본·정책은 Core가 소유한다. ARC-03은 추천, ARC-04는 정의와 적용 계획, ARC-05는 계정/Capability, ARC-06은 시도·프로세스, ARC-07은 Task/DAG, ARC-08은 지식 유효성, ARC-09는 승인/평가, ARC-10은 정본/감사, ARC-11은 인증·Core API, ARC-12/13은 플랫폼 경계, ARC-15는 템플릿·인스턴스·검증 보고서를 담당한다. 클라이언트 초안과 Runtime 관측은 저장 정본과 구분한다.
- 제품이 목표로 삼은 Desktop·VS Code·Chrome은 모두 계약 대상이다. 실제 지원은 각 경계별 게이트에서 따로 판정한다. 특정 플랫폼의 현시점 미지원은 제품 목표 삭제가 아니다.
- 사용자가 보지 못한 외부 전송, 승인 우회, 인증정보 추출·복제, 자동 중복 실행을 허용하는 방향으로 빈칸을 채우지 않는다. 미지의 필수 의미·인증·집행은 UNKNOWN 또는 거부로 표현한다.

## 2. 확정이 필요한 결정 목록

| ID / 책임 | 대안 | 권고 후보 및 이유 | 정합·보류할 선행 사항 |
|---|---|---|---|
| D01 Core 프로토콜 / ARC-11 | 클라이언트별 API, 공유 논리 API | 공유 명령/조회/이벤트 계약과 transport adapter 분리. 오류·권한·상태의 중복 구현을 줄임 | 공개 스키마·문서 및 구현 팀 합의; `protocolVersion`은 template/Agent schema 버전과 분리 |
| D02 macOS transport / ARC-11/14 | Unix socket, XPC | 서명된 Desktop↔Core는 양방향 peer 요구사항을 적용할 수 있는 XPC를 우선 후보로 검증 | ARC-11 socket 후보 및 ADR-014와 다르므로 후속 ADR 결정이 필요. 배포 서명·Team ID·서비스 발견·최소 OS 및 live 연결 미검증 |
| D03 Extension 경로 / ARC-11~13 | 플랫폼 공식 경로, 독자 TCP API | Chrome의 `allowed_origins`·caller origin 및 Native Messaging, VS Code의 공식 ID·Workspace Trust·Host 위치를 각각 사용. 확장→Core는 별도 인가 경계 | Chrome Host 직접 실행의 출처 결부와 VS Code 공유/원격 Host의 개별 확장 신원은 미해결. 검증 전 해당 고위험 기능 출시는 차단; 정상 플랫폼 보호는 인정 |
| D04 mutation과 정본 / ARC-06/07/10/15 | 마지막 쓰기 우선, optimistic revision + idempotency | `expectedRevision`과 주체·workspace·operation 범위의 requestId를 함께 사용하고 ARC-10에서 전이·이벤트·결과·감사를 원자적으로 기록 | 실제 저장 엔진·동시성·durability는 미검증. 외부 CLI/파일과 DB는 한 트랜잭션이 아님 |
| D05 인코딩/호환 / ARC-04/11/15 | 버전 없는 wire, 버전된 JSON | v1 후보는 크기 제한된 UTF-8 JSON 객체와 `major.minor` 협상. 제품 wire schema·template exchange schema·Agent definition schema를 독립 버전으로 관리 | 정확한 JSON Schema, 숫자·필드 규칙과 서명 바이트는 §3 제안. YAML은 교환 입력일 뿐 Core wire가 아님 |
| D06 승인·시도 / ARC-06/09 | 실행 승인 전 임의 시도 ID, 사전 예약 뒤 승인 | `prepare`는 실행 승인 없이 Prepared attempt를 저장 → 해당 attempt에 실행 승인 → `start` 직전 유효성·외부 전송 승인 별도 검사 | 예약이 곧 프로세스 생성/Provider 전송이 아님. 재시도는 새 attempt·새 실행 승인. Provider 내부 강제 가능 여부는 별도 검증 |
| D07 복구·관측 / ARC-06/07/10/11 | 연결 유실 후 자동 재실행, 정본 snapshot·cursor 복구 | 연결 유실은 종료가 아님. 재인증·동일 시점 snapshot/cursor와 이후 이벤트로 동기화하고 미확인 시 Unknown/Blocked | 이벤트 완전 전달을 약속하지 않음. retention·access 철회·외부 프로세스 관찰은 후속 시험 필요 |
| D08 오류/정보 공개 / ARC-09/11 | 모듈별 임의 오류, 공통 오류 + 안전한 매핑 | 아래 §4의 원인 분류·호출자 행동을 통일하고 외부에는 비밀·대상 존재 여부를 불필요하게 노출하지 않음 | HTTP status 등 물리 매핑은 선정된 transport에서 정의. 모듈 세부 오류는 무작정 폐기하지 않음 |

위 표의 권고는 사용자에게 선택을 떠넘기기 위한 질문 목록이 아니라 설계 검토용 초안이다. 각 결정의 구현 가능 여부는 별도 증거로 판정하며, 신뢰 경계가 성립하지 않을 때 대체 후보를 자동으로 더 낮은 보안 수준으로 바꾸지 않는다.

## 3. API v1 후보: 연결, 데이터와 버전

### 3.1 인증 전과 후

1. **연결 전제:** Core endpoint 발견 및 bootstrap은 `protocol_major`, `minor_min/max`, 설치된 Core의 확인 가능한 식별 정보를 제시한다. bootstrap에서 업무 데이터·계정·workspace 내용, 실행/변경 권한을 내주지 않는다. peer 신원 및 Core 신원/권한 확인이 끝나기 전 `command`, `observe`, 민감 `snapshot`은 거부한다. `clientId`, origin, PID 또는 `publisher.name`은 그 자체로 인증 근거가 아니다.
2. **인증/협상:** transport에 적합한 상호 신원 검사를 적용하고 Core가 등록·회수·workspace 범위를 확인한다. 공통 major가 없으면 `VERSION_UNSUPPORTED`; 공통 major의 minor 구간이 겹치지 않아도 거부한다. 겹치면 그 중 가장 높은 minor를 택하고 양쪽이 지원하는 Capability 교집합만 사용한다. 선택한 version과 확인된 등록/정책 버전은 세션에 고정한다. 인증 자체가 실패하거나 검증되지 않으면 이후 교환 금지다.
3. **요청:** 인증된 channel/connection과 서버 정본에서 `actorId`, `clientId`, `workspaceId`, operation·권한을 도출/확인한다. client가 제시한 값이 정본과 다르면 거부하고, 서버는 다른 workspace의 존재를 응답에서 누출하지 않는다. `Content Script`·Webview·파일의 텍스트는 명령이나 승인으로 승격하지 않는다.

### 3.2 공통 envelope 후보

- 공통 요청 필드: `protocolMajor`/`protocolMinor`(협상 값), `requestId`(불투명 고유 ID), `operation`(등록된 상수), `workspaceId`(Core 정본 대상), `payload`(operation별 객체), `expectedRevision`(변경 대상이 이미 있는 경우 필수), `approvalRefs`(해당 행위에 필요한 것만). authenticated session·actor는 클라이언트 본문이 아닌 검증된 연결 문맥에서 얻는다. `clientId`는 헤더 표시 용도로 전달할 수 있지만 서버가 검증 문맥과 비교한다. 신규 객체 생성에 기대 revision이 적용되지 않으면 필드 생략과 operation별 생성 전제를 명시한다.
- 응답 필드: `requestId`, `result`의 `ok` 또는 `error` 한 가지, 정본 `revision` 또는 불변 버전(해당할 때), 선택적 감사 가능한 안전한 `correlationId`. `error`는 `code`, 비밀 없는 설명, 호출자가 취할 수 있는 행동, 명시적으로 안전한 세부 유형을 가진다. 금액·토큰·원문 파일·인증정보·내부 경로는 무조건 로그/응답에 실어 보내지 않는다.
- JSON은 UTF-8, 한 객체 안 중복 키와 비유한 수를 거부한다. 정수는 IEEE-754 안전 범위 안에서만 wire 숫자로 쓰고 revision·커서 등 그 범위를 넘을 수 있는 식별자는 부호 없는 10진 문자열로 직렬화하는 안을 제안한다. 생성기와 소비자가 타입을 조용히 변환하지 않는다. **의미 보존·미지 필드 정책은 operation별 공개 스키마가 정의될 때 최종 확정**한다. 알 수 없는 필수 의미는 `UNSUPPORTED`/`UNKNOWN`으로 변경·실행 차단이다.
- `requestId`의 재사용 판정은 operation 종류와 `expectedRevision`·승인 참조·정규화 payload를 포함한다. 정규화·digest 후보는 명시적으로 버전 고정된 JSON Canonicalization Scheme과 SHA-256이며, 중복 키·표현 불가 숫자 거부, 문자열/배열 순서, 필드 생략과 `null`, domain separation을 사전에 고정해야 한다. `JCS` 적용 전 입력을 조용히 변형하거나 권한에서 배제하지 않는다. 정확한 signed byte format, 알고리즘 변경과 test vector는 ARC-09/11이 별도 합의하기 전 **UNKNOWN**이다. [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)

  JCS 후보 검증 시 RFC 8785의 요구를 그대로 적용한다. 파싱 과정에서 중복 property가 이미 사라진 뒤 검증하면 안 된다. 문자열은 JCS가 Unicode 정규화를 수행하지 않으므로 원래 code point를 보존한다. 화면상 유사한 서로 다른 문자열은 자동으로 같다고 취급하지 않으며 경로의 파일시스템별 동등성 검사는 별도다. 숫자는 IEEE 754 이중 정밀도 표현 제약과 반올림을 고려하고 정확한 큰 정수 식별자·revision은 명시적 문자열 형식 후보로 다룬다. property 정렬은 UTF-16 코드 단위 기준이며 배열 순서는 바꾸지 않는다. 단순 키 정렬이나 언어별 기본 JSON 직렬화를 JCS로 취급하지 않는다. 위는 RFC 기준을 후보에 적용하기 위한 제약이지 D05의 정규화 채택 결정은 아니다.

  교차 구현 수용 사례는 중복 키(escape 후 같은 이름 포함), 분해/조합 Unicode, 비 BMP property 이름, 안전 정수 범위 경계, 음수 0, `null`과 생략, 서로 다른 배열 순서 및 domain/version 변경을 포함한다. 서로 같은 서명 바이트여야 하는 경우와 반드시 거부하거나 달라야 하는 경우를 독립 test vector에 고정한다. 서로 다른 런타임의 양·음성 대조 및 제품 검증은 **NOT RUN**이다.

  **기본 파서 부정 대조, 2026-11-16:** 격리된 명령에서 Node v25.9.0의 `JSON.parse('{"role":"read","role":"write"}')`와 Python 3.9.6의 `json.loads`는 모두 마지막 `write`만 남겼다. 같은 입력 숫자 `9007199254740993`은 Node에서 `9007199254740992`로 반올림됐고 Python은 정수를 그대로 보존했다. Node에서 조합형 `é`와 분해형 `e`+결합 악센트의 문자열 동등성도 false였다. 재현은 `python3 docs/architecture/contracts/observe_json_parsers.py`; Node가 PATH에 필요하다. [실험 코드](contracts/observe_json_parsers.py)는 실제 관측값을 출력한다. 이는 기본 파서 단계에서 중복과 숫자 표현 차이가 발생할 수 있다는 실험이지 JCS 구현 또는 Oches 제품의 검증이 아니다. 따라서 중복은 원본을 읽는 단계에서 거부하고, 범위를 넘는 정수의 표현 계약을 채택·서명하기 전 확정해야 한다. 입력은 합성 데이터만 사용했다.

  **제한된 후보 비교:** Python `rfc8785==0.1.4`와 Node `canonicalize==5.1.0`을 임시 환경에 설치해 [비교 스크립트](contracts/compare_jcs_candidates.py)를 실행했다. 중첩 객체, 조합/분해 문자열, 비 BMP 속성 정렬, 안전 정수와 음수 0을 포함한 합성 값 4건과 RFC 8785 §3.2.2의 숫자 배열 예제 1건의 출력 바이트가 일치했고, 숫자 예제는 RFC의 고정 결과와도 일치했다. 재현 시 두 버전을 별도 환경에 설치하고 `JCS_NODE_MODULE`에 Node 모듈 경로를 지정한다. 다른 입력의 공통 구현 오류, 전체 RFC vector, 잘못된 raw JSON·중복 키·큰 정수 입력, 보안성, 서명 및 제품 UI/Core 간 해석은 이 비교로 검증되지 않는다. 전면 JCS 적합성 및 제품 시험은 NOT RUN이다.

  같은 격리 비교에서 두 라이브러리 모두 독립 surrogate, NaN, 양의 Infinity를 포함한 **메모리 객체** 3건을 거부했다. 이는 원본 JSON 파서의 중복 키 처리나 실제 Core 입력 검증을 검사한 결과가 아니다. [RFC 8785 §3.2.2](https://www.rfc-editor.org/rfc/rfc8785#section-3.2.2)는 이 값들의 거부를 요구한다.
- 크기/깊이/시간 제한은 실제 정수값을 확정하기 전 무제한을 허용하지 않는다. 제안 예: Core envelope 최대 256 KiB, JSON 최대 중첩 32, 문자열 최대 64 KiB. Chrome Native Host 응답의 공식 상한은 1 MB이고 Extension→Host는 64 MiB이므로 제안 양방향 envelope는 그보다 작다. 수치는 위협·호환성 테스트와 사용자 검토 전 계약 확정치가 아니다. 큰 이벤트/파일은 범위 검사된 별도 페이지/참조로만 취급하고, 대용량·깊이 초과는 부작용 없이 `INVALID_INPUT`을 반환한다. 공식 [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

### 3.3 버전별 의미

major가 변경되면 필수 필드·명령 의미의 호환을 가정하지 않는다. 같은 major에서 minor의 상호 지원 구간과 독립 Capability를 협상하고 필수 의미를 모르면 차단한다. optional 표기만으로 알 수 없는 필드가 안전하다고 추정하지 않는다. `TemplateVersion`, `instanceRevision`, `AgentDefinition.schemaVersion`, `CapabilitySnapshot`과 Core protocol은 서로 독립적이다. 디스크 migration은 원본 보존·차이 표시·승인·실패 복구를 요구하며 이전 client가 새 스키마를 읽지 못하면 읽기/쓰기 동작을 명시적으로 차단한다.

## 4. 오류·재시도·정본 계약

| 논리 코드 | 의미·외부 응답 | 호출자 동작 / 안전 속성 |
|---|---|---|
| `INVALID_INPUT` | 구문/필수 필드/크기 실패. `INVALID_REFERENCE`, `PORT_MISMATCH`는 안전한 경우에만 세부 유형 | 정본과 외부 부작용 무변경. 수정한 내용은 새 요청으로 제출 |
| `DENIED` | 인증·인가 또는 공개하면 안 되는 대상 | 동일 응답으로 타 workspace의 존재를 노출하지 않음. 같은 요청 반복으로 권한 우회하지 않음 |
| `VERSION_UNSUPPORTED`, `UNSUPPORTED` | 공통 protocol major/minor 부재 또는 지원하지 않는 명확한 기능 | 자동 downgrade·의미 손실 변환 금지; 버전/기능의 안전한 대안 안내 |
| `UNKNOWN`, `INDETERMINATE` | 신원·필수 Capability·집행·결과를 확인할 수 없음 | 지원/실패/성공으로 환산하지 않음. 위험 행위 차단, 결과 확인 전 자동 재시작 금지 |
| `APPROVAL_REQUIRED` | 해당 작업·대상·범위·버전에 유효한 별도 승인이 필요 | ARC-09에서 새 실행/전송/적용 승인을 구별, 사용자·신뢰 UI를 통해 발급 |
| `CONFLICT`, `STALE` | 기대 revision·정책·Capability·승인 또는 같은 requestId의 입력 불일치 | 정본을 다시 읽고 차이를 표시. 사용자가 변경할 때 새로운 기대 revision과 새 요청 사용 |
| `UNAVAILABLE`, `CURSOR_EXPIRED` | 저장/인증/연결 불가 또는 이벤트 cursor 범위 만료 | 안전한 읽기만 정책에 따른 재조회. 변경은 같은 requestId 결과 확인; cursor 만료는 정합 snapshot으로 복구 |
| `IDEMPOTENCY_EXPIRED` | 요청 결과의 보존기간이 지남 | 자동 새 ID·외부 실행 재시작 금지. 작업/attempt 정본과 관찰을 대조한 뒤 사용자 판단 |

ARC-10의 proposed 보존 기준에 따라 request 결과는 최소 30일, 만료 표시(tombstone)는 workspace 생애 동안 보존한다. 이 값은 기존 문서의 **제안**이며 제품 구현·복구 성능 보장이 아니다. 로그 접근은 raw 관찰과 진단을 다른 권한으로 구별한다. 인증·승인 소비, state/event/request 결과를 하나의 로컬 트랜잭션에서 기록하는 것은 목표 계약이며 실제 DB에 대해 장애 시험 전 성립을 가정하지 않는다.

## 5. 모듈 간 확정 대상과 순서

| 연결 / 호출 방향 | 고정할 입력 → 결과 | 정본, 오류 및 실패시 영향 | 확인 사례 |
|---|---|---|---|
| ARC-03 → ARC-15 | Profile revision·제약·Capability snapshot + 정확한 template/version 후보 → Proposal과 근거 | Registry는 템플릿, ARC-03은 추천. 후보 없음과 독립 단일 기준선을 구별; 변경 시 stale | C01, X01~03 |
| ARC-15 → ARC-04 → ARC-05/06 | instance revision·definition version·snapshot·정책 → Validator/MappingReport | ARC-04가 정의·변환, ARC-15가 템플릿/인스턴스, ARC-05가 capability. 필수 권한 손실·unknown 차단 | C02~03, X04~09, CV01~18 |
| ARC-07 → ARC-06 → ARC-09 | Run/Task/DAG revision → prepare의 Prepared attemptId → 해당 attempt 실행 승인 → start | 외부 전송이면 수신자·내용 digest에 별도 승인. 저장 실패·승인 없음·불명확한 Capability는 spawn 0 | C04, X10~12 |
| ARC-06/07 → ARC-10 | expectedRevision·requestId·state/events → 새 revision·event cursor | Task는 ARC-07, attempt는 ARC-06, 저장 기록은 ARC-10 정본. 외부 프로세스 생성은 별도 원자 경계 | C05, X13~15 |
| ARC-08 → ARC-10 / ARC-06 | task revision·권한·근거 version → ContextSelection과 전송 preview | 지식 유효성 ARC-08, 데이터 접근 ARC-10. 권한 철회/출처 삭제 시 stale, 전송 승인은 별도 | C06, X16~18 |
| ARC-07 → ARC-09 → ARC-10 | task revision·attemptId·불변 artifact manifest·criteria/evaluator version → 평가 PASS/FAIL/INDETERMINATE | ARC-09가 판정, ARC-10이 정본, ARC-07이 정확한 snapshot에 한해 성공 전이. 가변 workspace 파일은 DB와 원자적이지 않음 | C07, X19~21 |
| Desktop/Extension → ARC-11 | 플랫폼 식별·검증된 연결·workspace/권한·protocol → 인증된 command/snapshot/events | ARC-11은 client 인가, ARC-12/13은 플랫폼 제약. UI/Content Script는 별도 권한을 부여하지 못함 | C08, X22~24 |

### 실행·취소·재시도 수용 흐름

`prepare(taskRevision, instanceRevision, binding, snapshot)`는 호출자 권한과 사전 조건을 확인하고 **외부 실행 승인 없이** `Prepared` attemptId를 예약·기록한다. 그 다음 ARC-09가 요청 내용·범위·대상 revision 및 그 attempt에 결부된 실행 승인을 발급한다. 외부 Provider 전송을 수반하면 별도 전송 승인도 필요하다. `start(preparedRef, executionApprovalRef, transferApprovalRef?, requestId)`는 즉시 재검증하고 `Starting` 및 감사 기록을 커밋한 뒤에만 실제 spawn한다. 시작 여부가 불명확하면 attempt `Unknown`·Task `Blocked`, `requestId` 중복만으로 새 process를 만들지 않는다. 취소 요청은 수락과 종료 확인을 분리하고, 정상 종료가 경합하면 확인된 실제 결과를 반영한다. 재시도는 이전 종료 확인과 정책 허용 후 **새 attempt 예약 및 새 실행 승인**이 필요하다. `Runtime Succeeded`는 Task 평가 통과를 의미하지 않는다.

## 6. 클라이언트별 정상 경로와 미해결 경계

### Desktop ↔ Core
macOS에서 서명된 Desktop/Core 사이 live XPC peer requirement는 우선 **후보**다. 해당 OS/배포의 양방향 peer 신원, trusted UI, 키 보호·회전과 실제 접근 제어가 검증되기 전 위험 행위 출시를 막는다. 실제 배포 서명된 양성 대조, 다른 Team/identifier·ad-hoc·endpoint 위장 부정 대조, 재설치/업데이트와 권한 철회 시험이 필요하다. Windows/Linux transport·키 보호는 각 OS의 별도 계약과 검증을 요구한다. [macOS 보안 후보](ARC-11-G3-MACOS-DESIGN.md).

### Chrome ↔ Native Host ↔ Core
Chrome이 정상 경로로 시작할 때, manifest `allowed_origins`는 호출 가능한 확장을 제한하고 Chrome이 첫 인자로 전달한 origin은 이 경로의 호출 확장 식별 근거다. Worker는 브라우저가 제공한 sender/tab/frame/document와 형식을 검증하고 웹페이지 내용은 데이터로 취급한다. Content Script에서 온 텍스트는 실행 승인으로 인정하지 않는다. Host가 서명 검증된 Core와 통신하는 경로에서도 **Host 직접 실행의 위조된 인자/stdin을 Chrome이 보낸 신원으로 인정하지 않는다**. 실제 기동 결부 또는 별도 인증/인가가 충족되지 않으면 위험 요청을 거부한다. [확장 식별 경계](EXTENSION_IDENTITY_BOUNDARIES.md), [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Chrome 메시지 보안](https://developer.chrome.com/docs/extensions/develop/concepts/messaging).

### VS Code ↔ Core
`publisher.name`은 공식 설치·조회 식별자로 쓰고 `workspace.isTrusted`는 작업공간 신뢰 검사에 쓴다. 확장이 보이는 메뉴를 숨기는 것에 그치지 않고 모든 위험 명령 호출 시 trust와 Core 권한을 재검증한다. Extension Host의 OS 신원만으로 공유 Host 내부의 개별 확장 신원을 증명하지 않는다. Core가 신뢰할 수 있는 연결·workspace·주체 결부를 검증하지 못하면 위험 요청을 거부한다. 원격 SSH/WSL/Container는 Host와 Core의 위치·URI authority 및 데이터 이동을 명시·인가·검증하기 전 미지원이다. [VS Code Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust), [원격 확장](https://code.visualstudio.com/api/advanced-topics/remote-extensions).

공통 사용자 흐름은 플랫폼 기능의 정상 보호(Chrome allowlist, VS Code ID/Trust)와 Core의 workspace·operation·승인 검사를 함께 사용한다. ID 문자열 하나가 개발자의 의도, 현재 요청의 무결성, 사용자의 승인, Core 접근권을 모두 증명한다고 주장하지 않는다. 실제 Extension→Core 인가·기동 결부는 **미검증**이며 미지원 상태에서 고위험 작업을 우회해 열지 않는다.

## 7. 동시성·불확실성·복구

- 같은 주체/workspace/operation/requestId와 같은 정규화 입력은 보존 범위 내 동일 결과. 다른 입력·기대 revision은 `CONFLICT`. 레코드의 부재가 곧 외부 프로세스 미생성을 뜻하지 않으며, `Starting` 전후 장애는 ARC-06의 `Unknown` 규칙이 우선한다.
- 클라이언트 단절은 프로세스 종료나 취소를 뜻하지 않는다. 재연결 시 인증·권한을 다시 검사하고 동일 읽기 snapshot에서 상태 revision과 durable cursor를 함께 반환한다. 이후 이벤트의 중복을 ID로 제거한다. cursor 만료·유실은 오류와 불완전성을 표시하고 권한별 snapshot을 다시 읽는다. 상태/cursor의 일관 시점을 제공할 수 없으면 `UNAVAILABLE`이다.
- 취소와 정상 종료가 경합하면 실제 종료 관찰로 분기하고, 저장이 불가능한 경우 종료를 성공으로 단정하지 않는다. 시작 의도를 저장할 수 없다면 새 process는 만들지 않는다. 이미 실행 중 저장이 실패하면 감독을 유지하고 추가 시작을 중단한다.
- 평가된 파일과 DB는 원자적이지 않다. ARC-10이 안정적인 불변 snapshot을 확인하지 못하면 평가·Task 성공은 `INDETERMINATE`/`Blocked`다. workspace 파일이 변경되면 과거 snapshot의 성공 이력과 현재 파일의 상태를 구분한다. 삭제/권한 철회 후 무단 재주입하지 않는다.

## 8. 계약 검토와 실제 제품 검증의 완료 조건

### 설계 검토 완료 — 구현 전 점검 가능

1. D01~D08 각각의 채택·미채택·조건부 제안을 문서에 기록하고 소유 ARC/ADR의 정본 및 버전을 지정한다. D02의 XPC와 ARC-11의 socket은 확정 없이 동시 채택했다고 표현하지 않는다.
2. 공통 envelope·operation별 필드·오류 매핑·버전·승인 바인딩, XPC/Native/VS Code 각 연결 경계, 상태 및 mutation 원자성/비원자성을 계약 소유 모듈들이 교차 대조한다. 특히 requestId와 operationId의 scope·같은 요청의 입력 비교·tombstone, `prepare→승인→start`, Task↔attempt 및 snapshot/cursor의 책임이 충돌하지 않아야 한다.
3. [교차 사례](CONTRACT_ACCEPTANCE_MATRIX.md) X01~X24, [Capability 사례](CAPABILITY_CONTRACT_V1.md), 템플릿 그래프 사례 및 §9의 클라이언트 보안 사례마다 사전 조건·입력·소유자·기대 상태/오류·정본과 실제 부작용의 독립 관찰 경로를 연결한다. 미구현 경계의 결과는 `NOT RUN`으로 둔다.
4. 대안·트레이드오프, 현재 미지원 범위, 근거 버전·확인일, 구현 의존성과 판단자를 남기고 관련 문서의 오래된 상위 표현은 역사적 문구인지 새 계약으로 대체되는지 명시한다. 새로운 ADR/계약은 사용자에게 검토 가능한 제안으로 제공하고 승인 여부를 사실로 추정하지 않는다.

### 실제 기능·보안 지원 게이트 — 구현/시험 필요

해당 OS/버전·인증 방식·client의 정상 양성, 동일 사용자 위장·허용되지 않은 확장·Host 직접 실행·공유 Host/원격·승인 만료/변경/재생·키/서명 교체 등 부정 대조를 제품 경로에서 시험한다. 사용자에게 표시한 대상과 실제 요청이 일치하고, 승인·감사 실패 및 권한 철회 시 새 위험 부작용이 발생하지 않는지 독립적으로 관찰한다. 중복 시작·취소 경합·storage 실패·snapshot/cursor 유실·재시작도 격리 환경에서 시험한다. 정확한 OS/CLI/Adapter/version·출처·판정자·실패를 기록한다. 미실행/관측 불가는 PASS가 아니다.

## 9. 검토자가 바로 판정할 계약 사례

| ID | 사전 상태 및 행위 | 설계가 요구하는 판정 | 실제 상태 |
|---|---|---|---|
| FC-01 | 공통 major는 같고 양쪽 minor 구간이 겹치지 않음 | `VERSION_UNSUPPORTED`, 업무 명령/전송·저장 변경 0 | NOT RUN |
| FC-02 | 같은 주체/requestId로 기대 revision을 바꿔 동일 operation 재시도 | `CONFLICT`, 새 process·파일 변경 0 | NOT RUN |
| FC-03 | 위험 작업의 해당 attempt 실행 승인은 있으나 외부 전송 승인이 없음 | start 거부, process/전송 0 | NOT RUN |
| FC-04 | `Starting` 기록 뒤 process 생성 여부가 미확인 | `Unknown`/`Blocked`, 요청 재전송으로 신규 spawn 0 | NOT RUN |
| FC-05 | Chrome 허용 Extension 정상 호출 및 미허용 Extension 호출 | 전자는 Chrome이 Host에 origin 전달, 후자는 Chrome이 차단; Core 권한은 별도 검사 | NOT RUN |
| FC-06 | 다른 프로세스가 Host를 직접 실행하며 정상 Extension origin을 인자로 위조 | 인자만으로 등록/위험 행위 인가 금지; 검증 가능한 기동 결부 또는 별도 적절한 승인 전 거부 | NOT RUN |
| FC-07 | VS Code 미신뢰 workspace에서 숨겨진 명령을 API로 직접 호출 | 명령 내부에서 trust/권한 검사해 거부; 사용자 파일 변경 0 | NOT RUN |
| FC-08 | 동일 snapshot/cursor 읽기 사이 이벤트 저장 또는 cursor 만료 | 일치하는 상태/cursor와 이후 이벤트, 또는 명시적 만료·정합 snapshot; 누락 없는 척하지 않음 | NOT RUN |
| FC-09 | 진단 권한만 가진 client가 raw 원문을 요청 | 별도 raw 권한 부재 시 거부; 본문/대상 존재 불필요 공개 0 | NOT RUN |
| FC-10 | 인증·키·서명 또는 Provider 집행 근거가 미확인 | 해당 범위 UNKNOWN, 사용자 확인만으로 supported/실행 허용하지 않음 | NOT RUN |

이 문서는 G2/G3/G8의 PASS 판정 문서가 아니다. 논리 계약 검토의 미결 항목이 해결되고 문서 사이의 모순 부재가 확인되면 **구현 전에도 G2를 재판정할 수 있다.** G3의 안전 구조는 선정한 위협 모델과 지원 게이트의 검토가 필요하고 실제 집행 검증은 별개다. G8은 설계된 수용 기준의 충분성과 실제 시험 통과를 분리해 재판정한다. 점수·프로젝트 상태 변경은 이 문서의 목적이 아니다.
