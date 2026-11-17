# 교차 모듈 계약 명세 v1 — 검토 제안

상태: 독립 설계 검토용 제안 · 2026-11-16. 기준은 ARC-00 v0.1~0.3, ARC-01~15, [교차 계약 지도](CROSS_MODULE_CONTRACTS.md)다. 이 문서는 논리 계약을 명시하며 새 wire format, 실제 제품 구현, 사용자 승인 또는 Provider 지원 사실을 뜻하지 않는다. 모순 발견 시 이 문서를 우선 적용하는 것으로 가정하지 않고 해당 소유 모듈과 합의 전 충돌로 기록한다. 아래 계약의 검증 결과는 `NOT RUN`이며 문서 예는 요구사항의 판정 기준이다.

## 공통 의미와 책임

- ARC-11이 호출 주체·workspace의 인증된 문맥을 부여하고 각 소유 모듈은 자기 객체의 읽기/변경 권한을 검사한다. client에서 제공한 ID·경로·역할 문자열 자체를 인증 근거로 삼지 않는다. 버전과 ID는 해당 정본의 범위 내에서만 비교한다.
- `RevisionRef=(objectId,revision)`, `SnapshotRef=(snapshotId,providerInstallationId,version,observedAt)`, `ApprovalRef=(approvalId,subject,taskId,attemptId,action,target,scope,revision,planDigest,issuedAt,expiresAt)`은 논리 레코드다. ARC-10 복원 세대 계약이 적용되는 정본의 `RevisionRef`는 추가로 `storeGeneration`을 포함하며 `(objectId,storeGeneration,revision)` 전체로 비교한다. 다른 저장소의 세대 정책은 해당 정본 소유자가 정의한다. 작업·시도가 아직 없는 적용 계획 등에서는 해당 식별자를 명시적으로 null로 두되 승인 종류별 필수 항목을 ARC-09가 정의한다. 승인 검증은 실제 행위·작업/시도·정규화 대상·범위·대상 revision·입력 또는 계획 digest와 시간 및 철회 상태를 대조한다. Provider/계정 자격증명은 어떤 레코드에도 넣지 않는다. ID를 아는 것만으로 접근 권한은 생기지 않는다.
- 읽기는 대상의 버전 또는 snapshot과 시점을 반환한다. 상태 변경에는 인증 문맥·`requestId`·기대 revision을 요구한다. ARC-10의 원자적 요청 정본이 가능한 범위에서 동일 주체·workspace·operation·requestId 및 동일 정규화 입력은 동일 결과, 다른 입력은 CONFLICT다. `requestId` 재사용이 외부 프로세스의 정확히 한 번 실행을 보장하지 않는다. 보존기간 만료는 IDEMPOTENCY_EXPIRED이며 자동 재시작하지 않는다.
- 오류는 `DENIED`(안전한 경우 `AUTH_FAILED` 세부 유형), `NOT_FOUND`, `INVALID_INPUT`(상세 유형 `INVALID_REFERENCE`, `PORT_MISMATCH` 포함), `CONFLICT`, `STALE`(예: `STALE_GENERATION`), `UNSUPPORTED`, `UNKNOWN`, `APPROVAL_REQUIRED`, `UNAVAILABLE`(예: `KEY_UNAVAILABLE`), `INDETERMINATE`를 논리 분류로 갖는다. 구현의 보안 정책이 존재 유무를 감춰야 하는 대상은 DENIED/NOT_FOUND를 외부에서 같은 응답으로 표현할 수 있으나 내부 감사에는 구별한다. `UNKNOWN`, `INDETERMINATE`, 저장 실패는 성공으로 변환하지 않는다. `UNAVAILABLE`의 자동 재시도는 부작용 없는 읽기만 가능하며 변경은 동일 requestId로 상태를 확인한 뒤 정책에 따라 처리한다.
- `stale`은 과거 기록 삭제가 아니라 현재 승인·실행 가능성 평가에 사용하지 못한다는 뜻이다. 사용자가 확인한 내용이나 외부 전송 범위가 바뀌면 기존 승인도 재사용할 수 없다. 프로젝트 식별자·환경·경로는 전송 승인 범위와 별도로 검사한다.

## C-01 Decision Engine → Template Registry

**소유:** ARC-15가 TemplateVersion, ARC-03이 Proposal, ARC-05가 CapabilitySnapshot. **방향:** ARC-03 `listTemplates(query,clientContext)`와 `getTemplate(templateId,versionId)` 읽기 → ARC-03 `propose(profileRevision,constraints,snapshotRef,candidates[])` → Proposal. 반환에는 각 templateId/versionId, 추천 근거, profile revision, snapshotRef, 생성 규칙 버전, 대안 및 불확실성이 포함된다. Registry는 추천·실행 결정을 하지 않는다.

**불변/실패:** 후보가 제거·접근 철회되면 NOT_FOUND/DENIED, Registry 오류면 UNAVAILABLE이다. Registry 후보가 없는 경우에는 빈 목록을 그대로 표시한다. ARC-03이 Registry 밖에서 독립 생성한 단일 기준선이 있으면 출처와 생성 규칙을 표시해 별도로 제시할 수 있으나, 생성·검증 근거가 없으면 존재하는 것처럼 위조하지 않는다. Profile, snapshot 또는 후보 버전이 변경된 추천은 stale이며 재평가해야 한다. Template Validator의 결과, 제안 수락, 설정 적용 승인, 실행 승인과 외부 전송 승인은 각각 별개다.

**수용 예 C01:** 동일한 profile과 후보를 사용하되 snapshot을 새 버전으로 바꾸면 이전 추천은 stale이고 이전 실행 승인으로 실행하지 않는다. 권한 없는 버전 조회는 내용이나 존재 여부를 누출하지 않는다. 현재 NOT RUN.

## C-02 Template Registry → Agent Definition

**소유:** ARC-15의 immutable TemplateVersion 및 프로젝트 Instance revision, ARC-04의 정의 의미·revision. 인스턴스 생성 시 참조하는 정확한 templateId/versionId의 그래프를 독립 복사하고 definitionId/revision 또는 인라인 정의를 고정한다. Registry의 validation 요청은 instance revision, 각 정의 revision, template schemaVersion, 정의 schemaVersion, snapshotRef, 정책 버전을 ARC-04/05/09에 전달한다. 보고서 역시 이 버전들을 모두 보존한다.

**불변/실패:** 삭제된 원본이 기존 인스턴스를 변경하지 않는다. 알 수 없는 major/필수 의미는 UNSUPPORTED 또는 UNKNOWN, 빠진 정의·참조는 INVALID_INPUT/INVALID_REFERENCE, 타입 불일치는 INVALID_INPUT/PORT_MISMATCH, 필수 Capability 미확인은 UNKNOWN이다. 정의·인스턴스·스냅샷·정책 어느 하나라도 달라지면 보고서는 stale이다. 새 버전이 예전 버전을 덮어쓰지 않는다. 상세 필드와 실험용 부분 스키마는 [ARC-04](ARC-04.md) v0.2와 [시제품 한계](contracts/EXPERIMENT_EVIDENCE.md)를 따른다.

**수용 예 C02:** rev 4를 검증한 직후 한 Agent 정의가 rev 5가 되면 rev 4 보고서로 실행하지 않고 해당 정의·포트를 다시 검증한다. missing ref와 모르는 필수 필드는 기존 인스턴스를 수정하지 않는다. 현재 NOT RUN.

## C-03 Agent Definition → Provider Capabilities

**소유:** ARC-04가 중립 정의·변환 계획, ARC-05가 설치·인증 상태·CapabilitySnapshot, ARC-06이 실행. `planExport(definitionRevision,installationId,accountRef,snapshotRef,targetVersion)`은 각 필드의 EXACT/LOSSY/UNSUPPORTED/UNKNOWN과 공식 근거, 적용 대상·diff, 대상 파일 revision과 planId를 반환한다. 일반 DB·Template·Extension에는 credential을 복사하지 않는다.

**불변/실패:** 공식 형식과 대상 버전에 대한 근거 및 검증이 없으면 EXACT를 주장하지 않는다. 필수 권한·안전 속성의 LOSSY/UNSUPPORTED/UNKNOWN은 적용 및 실행 차단이다. 선택적 손실은 범위·대상·버전에 결부한 적용 승인을 요구한다. 승인 후 파일·Adapter·snapshot 변경 시 STALE/CONFLICT, 부분 파일 쓰기는 Partial 또는 Unknown이며 성공으로 보고하지 않는다. Provider의 실제 변환·계정 격리는 미검증이다.

**수용 예 C03:** 허용 경로 제한이 Provider에 표현되지 않으면 사용자 확인만으로 손실을 승인 처리하거나 내보내지 않는다. 현재 NOT RUN.

## C-04 Orchestrator → Runtime / Session

**소유:** ARC-07은 Run·DAG·Task, ARC-06은 ExecutionAttempt·프로세스 관찰. Scheduler가 `prepare(taskId,taskRevision,runId,dagVersion,instanceRevision,binding,snapshotRef)`를 실행 승인 없이 호출해 Prepared attemptId를 예약·저장한다. 예약은 외부 프로세스 생성·Provider 전송을 일으키지 않는다. 이후 ARC-09에서 해당 attempt에 결부된 실행 승인을 발급받고 `start(preparedRef,executionApprovalRef,transferApprovalRef?,requestId)`가 유효한 준비·실행 승인·최신 capability와 시작 기록을 확인한다. 시작이 외부 전송을 수반하면 `transferApprovalRef`가 필수이며 수신자·입력 digest·목적·범위와 집행 가능성을 ARC-09에서 별도로 재검증한다. 전송 여부나 집행이 unknown이면 차단한다. 구성 적용·외부 전송 승인은 실행 승인과 별도다. ARC-06은 실제 수명주기를, ARC-07은 이를 작업 상태와 별도로 해석한다.

**불변/실패:** 준비 실패는 프로세스 생성 금지, 상태 기록 실패는 새 시작 금지다. 시작 결과가 불명이면 attempt Unknown, Task Blocked이며 자동 재시작 금지다. cancel 수락은 종료가 아니고 정상 종료가 취소와 경합하면 확인된 관찰 결과를 기록한다. Runtime Succeeded는 Task Succeeded가 아니며 ARC-09 평가를 기다린다. 재개는 Provider 지원·정책 확인과 승인 후 별도 시도다.

**수용 예 C04:** `Starting → CancelRequested → (생성 관찰) → CancelRequested → Cancelled`에서 생성 직후 종료를 요청하고 최종 종료 전 취소 완료로 표시하지 않는다. 시작 여부 미확인 상태에서는 같은 요청을 재전송해도 새 자식을 만들지 않는다. 현재 제품 시험 NOT RUN.

## C-05 Session Manager → Storage / Event Log

**소유:** 상태 의미는 ARC-06/07, 상태·이벤트·요청 결과의 내구성 계약은 ARC-10. `commitTransition(attemptId,expectedRevision,nextState,events,requestId)`의 응답은 새 revision과 durable event cursor를 반환한다. 상태·관련 이벤트·중복 결과는 동일 로컬 트랜잭션에서 함께 커밋하거나 실패한다. `appendObservation`은 관측 원본·시각·식별자를 남기되 누락 없는 수집을 주장하지 않는다.

**불변/실패:** 버전 충돌은 무변경 CONFLICT. 저장 실패로 시작 기록을 남길 수 없으면 새 프로세스 금지. 이미 실행 중 저장 실패면 감독을 유지하고 추가 실행을 중단한다. process 생성은 DB commit과 원자적이지 않으므로 재기동 후 신원을 확인할 수 없으면 Unknown이다. snapshot의 상태 revision과 cursor는 동일한 읽기 스냅샷에서 얻고 만료된 cursor는 snapshot으로 복구한다.

복원 시 세대 변경, 과거 revision·cursor 거부, 실행 불확실성, 승인 재검사와 데이터 격리는 [ARC-10 SQLite 후보의 복원 세대 계약](SQLITE_STORAGE_RECOVERY_CONTRACT.md#복원-세대와-모듈-간-재동기화)을 따른다. 이 계약과 [최신성 기준점](RECOVERY_FRESHNESS_ANCHOR.md)은 설계 후보이며 강제 rollback을 탐지할 anchor 구현과 실증은 미결이다.

**수용 예 C05:** 기록 커밋 전후 및 spawn 직후 종료를 각각 주입한다. 기록은 부분 커밋되지 않아야 하며 spawn 여부 불명은 Unknown이고 중복 외부 실행 0건이어야 한다. 단일 macOS 임시 DB 시제품의 관찰 범위는 [실험 증거](contracts/EXPERIMENT_EVIDENCE.md)를 따르며 제품 테스트는 NOT RUN.

## C-06 Context Builder → Memory Store

**소유:** ARC-08은 MemoryEntry의 유효성과 ContextSelection, ARC-10은 접근 가능한 원본·파생 인덱스·버전. `selectContext(taskRevision,actor,workspace,policyVersion,budget)`는 항목 ID/revision, 근거 ID/revision, 출처·선택 이유·제외 사유와 전송 미리보기를 반환한다. 이를 기록해도 전송은 발생하지 않는다.

**불변/실패:** 원본 삭제·변경, 권한 철회, 정책 변경 또는 근거의 최신 여부 미확인이면 선택 결과를 stale/unknown으로 표시하고 관련 항목의 주입을 차단한다. 예산 초과는 명시적인 제외·부분 결과이지 누락 없는 완전 결과가 아니다. 인덱스 재생성 시 정본을 덮어쓰지 않으며 권한·근거가 없는 항목은 복원하지 않는다. 외부 전송은 별도 승인과 ARC-06의 실행 직전 검증이 필요하다.

**수용 예 C06:** 선택 후 근거 접근권이 철회되면 예전 Selection과 승인으로 Provider에 해당 근거를 전송하지 않는다. 현재 NOT RUN.

## C-07 Evaluation Engine → Task / Artifacts

**소유:** ARC-07의 Task revision 및 attempt ID 참조, ARC-06의 ExecutionAttempt 의미·상태, ARC-10의 불변 참조/manifest 및 기록, ARC-09의 판정. 평가 요청은 taskId/revision, attemptId, artifactManifestId와 항목별 버전/해시, criteriaId/version, evaluatorId/version, 환경 참조를 포함한다. 응답은 PASS/FAIL/INDETERMINATE, 실제 측정값·미측정 사유·원본 근거·평가 버전을 포함한다.

**불변/실패:** 존재하지 않거나 변경 중인 산출물, 무결성 불일치, 평가기 실패와 근거 부족은 INDETERMINATE. 같은 Task/attempt/manifest/criteria 버전의 유효한 PASS를 ARC-10에 기록한 뒤에만 ARC-07이 Succeeded로 전이한다. 사람이 승인한 수동 평가는 주체·사유와 대상 버전을 별도로 기록하며 자동 측정으로 표시하지 않는다. 평가 대상은 ARC-10이 무결성 확인 후 보관한 불변 blob 또는 동등한 불변 snapshot이다. ARC-07의 성공 전이는 해당 불변 manifest·Task revision·attempt·기준 버전에 묶이고 동일 DB 트랜잭션에서 유효 PASS 참조를 검사한다. 사용자 workspace의 가변 파일과 DB는 원자적이지 않다. 가변 파일을 안정적으로 snapshot할 수 없거나 참조 무결성을 검증하지 못하면 INDETERMINATE/Blocked다. 평가 후 workspace 파일이 바뀌어도 과거 snapshot의 평가는 이력을 보존하지만 새 파일 버전의 성공으로 표시하지 않으며, 최신 파일에 대한 완전한 변경 감지가 보장되지 않으면 최신 성공 여부는 unknown이다. 데이터셋 대표성·실제 안전 관측 및 운영 합격치는 미정이다.

**수용 예 C07:** Task A의 성공 평가 후 파일이 바뀌거나 Task B가 같은 PASS를 제시하면 두 결과 모두 해당 새 대상의 PASS로 사용하지 않는다. 현재 NOT RUN.

## C-08 Desktop / VS Code / Chrome → Shared Core

**소유:** ARC-11이 인증·인가·공통 API, ARC-12/13은 각 플랫폼 경계, ARC-01이 UI 표시. 연결 시 clientId·OS와 workspace 위치·protocol major/minor·등록된 권한을 제시한다. 클라이언트의 OS·경로·위치는 검증되지 않은 주장이다. Core는 플랫폼 신원이 종단 증명된 `PLATFORM_BOUND`와 사용자가 확인한 설치키 `USER_ENROLLED_KEY`를 구별한다. 후자는 [ADR-017](adr/ADR-017-user-enrolled-client-key.md)의 등록·서명·Desktop 요청별 승인·기밀성·현재 권한을 요구하며 플랫폼 증명으로 표시하지 않는다. 필수 증거가 없으면 해당 행위를 거부한다. Desktop·Extension의 편집 초안은 정본이 아니다. Core가 각 명령을 소유 모듈에 전달한다. Content Script·Webview는 비신뢰 입력이며 단독으로 승인·실행 권한을 발행하지 못한다.

**불변/실패:** 공통 major가 없으면 변경·실행 차단, 미지원 위치 또는 선택된 신뢰 수준의 필수 신원이 unknown이면 UNSUPPORTED/UNKNOWN이다. 개별 확장 플랫폼 증명이 없다는 이유만으로 ADR-017의 `USER_ENROLLED_KEY` 수준을 자동 거부하지 않지만, 해당 수준의 등록·Core 신원·요청별 승인·필요한 보호 조건은 모두 충족해야 한다. 연결 유실은 실행 종료가 아니다. 재인증 뒤 cursor로 이어 읽거나 만료면 정합 snapshot을 읽는다. VS Code 원격 Host와 로컬 브라우저의 경로·실행 위치가 같다고 가정하지 않는다. 서버 신원·등록·키 보호는 실제 대상 OS에서 검증하기 전 변경·실행 미지원이다.

**수용 예 C08:** Chrome Worker 재시작 또는 VS Code 연결 중단 뒤 재연결 시 진행 중인 attemptId를 조회하며 신규 start를 자동 호출하지 않는다. 취소 수락 직후 종료로 표시하지 않는다. 현재 NOT RUN.

## 설계 심사와 남은 경계

C01~C08은 각각 소유권·방향·입출력·버전·오류·보안·수용 예를 다룬다. 승인된 정식 직렬화/상태 코드, Agent 외 모든 노드·포트, Provider별 Adapter 매핑, 실시간 권한 집행, OS 인증, 개별 예의 실제 테스트와 사용자 승인은 남아 있다. 부분 시제품 통과 또는 이 문서 자체는 G2/G3/G8을 PASS로 만들지 않는다. 관련 증거와 한계는 [REVIEW_80](REVIEW_80.md), [검증 계획](VERIFICATION_PLAN.md)에 기록한다.

각 경계의 독립 관측, 양성·부정 대조, 사전 상태와 불변 결과는 [계약 수용 사례](CONTRACT_ACCEPTANCE_MATRIX.md) X01~X24에 정리했다. 모든 제품 시험은 NOT RUN이다.
