# Capability, 버전 호환 및 Adapter 손실 계약 v1

상태: 논리 계약 제안 · 2026-11-16. ARC-04/05/06/11/15와 [공식 근거 매트릭스](COMPATIBILITY_EVIDENCE_V1.md)의 설계 경계다. 제품·Provider의 지원 선언이나 공식 스키마 채택은 아니다. 테스트된 제품 Adapter가 없으므로 제품 판정 상태는 supported/unsupported/unknown뿐이다. 문서 확인 여부와 제품 시험 여부는 상태가 아니라 evidence basis이며 현 제품의 검증된 supported 사례는 없다. 인증·약관·클라이언트별 집행은 Capability 이름의 일치로 추론하지 않는다.

## 구성요소별 Capability 계약

`CapabilitySnapshot`은 `snapshotId`, `installationId`, `providerName`, `cliVersion`, `adapterVersion`, `os/version/architecture`, `accountTypeOrUnknown`, `workspaceTrust`, `policyVersion`, `observedAt`, `evidenceRefs[]`, `entries[]`와 아래 정의된 전체 `scope`를 논리적으로 포함한다. 공개 식별자는 계정 비밀·토큰·원본 경로가 아니며 조회에도 workspace 권한이 필요하다. `entry`는 `capabilityId`, `scope`, `status(supported/unsupported/unknown)`, `basis(documented/experiment/policy)`, `evidenceRef`, `conditions`, `observedAt`, `recheckReason`을 갖는다. 상태는 사용자 편의를 위한 저장 문자열이 아닌 검증된 provenance로 뒷받침한다.

| Capability ID | 소비자와 검사할 의미 | `supported`가 되기 위한 최소 조건 | 미충족·예외 |
|---|---|---|---|
| `provider.install` | ARC-05/06: 선택한 실행 파일·버전 | 지정된 경로가 OS/공급자 신뢰 및 버전 검사 통과, Adapter가 해당 버전을 명시적으로 지원 | 실행 파일 경로·버전 불명은 unknown; 정적 버전 표시만으로 신뢰·실행 지원이 아님 |
| `auth.official` | ARC-05: 인증 상태 확인 및 사용 | 해당 공식 방식·계정 유형이 확인되고 연동 정책 및 실행 경로가 허용됨 | 타 앱 인증 파일 복사·비공식 토큰 추출 금지. 로그인 상태 unknown은 실행 차단 |
| `auth.accountIsolation` | ARC-05/06/07: 각 attempt의 계정 격리 | 특정 로그인 유형·OS·CLI에서 공식 지원 조건과 전역 상태의 영향을 실험으로 확인 | 디렉터리 분리만으로 모든 계정 격리 보장 금지. 미확인이면 격리 의존 동시 실행 차단 |
| `run.start` | ARC-06: 승인된 입력의 실행 | 공식 실행 경로·설정·권한 집행과 대상 버전이 확인되고 승인/전송 조건 충족 | 구성 검증과 신뢰 경계가 미완이면 unknown/차단. 실행 가능은 결과 성공이 아님 |
| `run.cancel` | ARC-06: 시도에 대한 취소 | 대상 OS/CLI의 수단과 실제 프로세스/자식 처리 및 종료 증거가 확인됨 | 수락만으로 종료로 표시 금지. 미확인이면 취소 보장은 unknown으로 표시 |
| `run.resume` | ARC-06: 종료 확인된 과거 시도의 공식 재개 | 특정 CLI·계정·세션·저장 상태에서 공식 지원 및 재개 의미 확인 | 기능 표시 자체는 중복 실행 안전성을 보장하지 않음. 승인된 새 attempt로만 재개 |
| `event.structured` | ARC-06/10: 표준화 이벤트 | 대상 버전의 정식 형식과 파서, 오류·미지 이벤트·잘림·중복 처리가 검증됨 | 미지 이벤트를 성공으로 변환 금지; 유실·누락과 원본/정규화 출처 보존 |
| `permission.enforce` | ARC-09/06: 특정 행위·대상의 실제 제한 | OS·Provider가 요청된 구체 권한 범위를 강제하고 우회 부정 대조가 통과함 | 사용자 확인이나 Webview 표시만으로 supported가 되지 않음. 불명확한 필수 위험 행위 차단 |
| `config.export` | ARC-04: 필드별 설정 계획·손실 | 해당 필드의 공식 포맷·의미와 대상 버전별 실제 손실/우선순위를 확인 | 필수 안전 속성의 LOSSY/UNSUPPORTED/UNKNOWN 차단. 선택 손실은 diff와 별도 승인 |
| `usage.measure` | ARC-09/10: 비용과 사용량 | 공식 출처의 측정 항목·단위·계정 유형·기간을 확인하고 실측 시 provenance 유지 | 사용량 unavailable을 0으로 표시 금지; Provider 추정과 실제 청구 분리 |
| `client.local` | ARC-11~13: 인증된 로컬 client/Core 연결 | 해당 OS·클라이언트의 peer 결부, 신뢰 UI·키·권한 강제 및 계약이 실제 검증됨 | 같은 UID/Origin/extension ID 또는 키 소유만으로 충분하지 않음 |
| `client.remoteWorkspace` | ARC-11/12: 원격 위치, URI·실행·데이터 이동 | 원격 Core·인가·workspace URI/authority·데이터 전송 경계 및 복구를 대상 환경에서 검증 | 미검증 SSH/WSL/컨테이너·웹 경로는 기능 비활성. 로컬 경로로 임의 변환 금지 |

인증이나 청구 정책은 서로 독립이다. `auth.official=supported`가 subscription 동시 계정 격리 또는 비용 가용성을 뜻하지 않으며, `event.structured=supported`가 이벤트의 완전성·권한 집행·작업 성공을 뜻하지 않는다. 실험이 없는 제품 snapshot은 모두 UNKNOWN으로 처리한다.

## 범위 결부와 증거의 의미

스냅샷의 필수 `scope`는 `(installationId, executableIdentity, cliVersion, adapterVersion, os/version/architecture, accountRef, accountType, workspaceId, workspaceLocationAuthority, workspaceTrust, clientId, clientKind, negotiatedProtocolMajorMinor, policyVersion)`이다. accountRef는 ARC-05가 권한을 확인한 후 발급하는 Provider별 불투명 참조이고 자격증명이나 실제 계정 식별자가 아니다. workspaceLocationAuthority는 Core가 검증한 로컬/원격 위치·URI authority를 논리적으로 나타낸다. clientId·종류·protocol은 ARC-11의 인증 결과에 결부하고 클라이언트가 주장한 값만 신뢰하지 않는다. 가짜/손상된 scope·권한 없는 accountRef는 거부한다. 지정된 scope 항목을 모르거나 검증할 수 없다면 그 축에 의존하는 필수 기능은 UNKNOWN이며 전체 스냅샷을 다른 범위에 재사용하지 않는다.

`entry.scope`는 위 `scope`와 동일하거나 더 좁은 대상·행위의 부분 집합이다. 검사자는 각 필수 축이 현재 요청과 일치하고 문서/실험 증거의 조건을 벗어나지 않는지 확인한다. 어느 축이든 불일치 또는 누락이면 `STALE`/`UNKNOWN`, 새 scope의 snapshot과 필수 승인 확인 전 실행 불가다. 표면상 accountType이 같아도 accountRef가 다르면 같은 계정이 아니고, trust 값이 같아도 workspaceId/location authority가 다르면 같은 workspace가 아니다. 다른 Client나 protocol·정책으로 변경된 결과 역시 재검사한다. 가능한 재사용 최적화는 독립된 증거가 범위에 적용된다고 명시적으로 검증된 경우에만 허용하고, identity·권한·workspace 관련 확인을 생략하지 않는다.

표준 `status`는 supported/unsupported/unknown 세 가지다. `basis=documented` 또는 공식 문서 링크만으로 Oches 실행에 필요한 필수 조건 모두가 증명되지는 않는다. 예를 들어 출처 문서가 기능을 설명해도 현재 구현·버전·권한 집행이 미실험이면 `status=unknown`, 문서 근거는 보존한다. `VERIFIED_IN_OCHES`는 별도 status가 아니라 특정 scope에서 제품 실험의 성공을 나타내는 근거 분류로만 기록한다. 그마저 약관·안전 통제 등 다른 필수 조건을 독립적으로 만족해야 supported가 된다.

## 유효성·전파 및 오류 계약

최종 사용 가능 조건은 요청 기능의 **Provider × Adapter × OS × 계정 × workspace trust × client × 정책/집행** 교집합이다. 하나라도 필수 항목이 unsupported면 UNSUPPORTED, 그렇지 않고 하나라도 unknown/stale이면 UNKNOWN/STALE이며, 나머지 모두 supported이고 유효한 별도 승인까지 충족되어야 ARC-06의 start 후보가 된다. unsupported/unknown이 어떤 구성요소에서 왔는지와 증거 시각을 사용자에게 표시하되 존재 여부·계정의 민감한 세부사항은 노출하지 않는다.

다음 중 하나가 바뀌면 관련 snapshot 및 이를 참조한 Proposal/ValidationReport/ExportPlan/Approval의 적용 가능성을 재검토한다: CLI·Adapter·OS 버전/실행 파일 신원, 인증 유형·계정 참조, workspace trust/위치, 정책·권한, client/protocol, 템플릿·정의 revision. 모든 객체를 자동 삭제하지 않고 provenance를 보존하며, 실행 직전 실제 비교할 수 없는 항목은 unknown으로 차단한다. CLI 문서가 바뀐 사실을 실시간 감지한다는 뜻은 아니며 출시 전과 오류 보고 시 근거를 재확인한다. 새로운 snapshot은 이전 실행 이력을 변경하지 않는다.

## 직렬화·변환·마이그레이션

1. Protocol major 불일치, 미지의 template/Agent major, 의미를 모르는 필수 필드는 **실행 불가**다. 동일 major라도 필드를 알 수 없으면 의미를 잃는 변환·실행을 거부한다. 보기/원문 보존 가능성은 파서 안전성 및 데이터 정책을 별도로 검사한다. Version negotiation은 인증을 대체하지 않는다.
2. 변환 계획은 `(sourceDefinitionRevision,templateInstanceRevision,sourceSchemaVersion,targetProviderVersion,adapterVersion,snapshotId,policyVersion,targetFileVersion)`을 고정한다. 각 필드에 `EXACT`, `LOSSY`, `UNSUPPORTED`, `UNKNOWN`과 대상·근거·영향을 기록한다. `EXACT`는 형식만 파싱된 것이 아니라 해당 목표 의미가 동등하다는 대상 버전별 공식 근거 및 검증 결과가 있어야 한다.
3. 필수 안전·권한 속성은 EXACT 외의 모든 결과에서 적용/실행을 차단한다. 선택적 속성의 LOSSY만 사용자에게 diff·손실·대상 버전을 보여 주고 별도 적용 승인을 받을 수 있으며 실행·전송 승인을 자동으로 발급하지 않는다. 정규화 중 조용한 필드 삭제·권한 완화는 허용하지 않는다.
4. Migration은 원본 templateVersion 및 프로젝트 instance를 보존하고 새 후보·변경점·데이터 손실을 표시한다. 원본 콘텐츠를 바꾸거나 불명확한 필수 필드를 생략해 자동 저장하지 않는다. 원본 검증 오류·정책 변경·동시 수정·저장 실패는 새 버전 생성 성공이 아니다.

## 설계 검토용 대응표와 판정 사례

| 사례 | 입력 / 조건 | 판정 가능한 기대 결과 | 대상 구현 시험 |
|---|---|---|---|
| CV01 | Provider 문서에 JSON 스트림만 기술, Adapter 실험 없음 | `DOCUMENTED`, 제품 `event.structured=unknown`; 실행 성공으로 보지 않음 | NOT RUN |
| CV02 | 정확히 같은 installation·CLI에서 계정 유형만 변경 | 계정 관련 snapshot과 이전 실행 가능성 stale; 다른 유형의 인증·비용·격리 재확인 | NOT RUN |
| CV03 | 필수 권한 필드가 LOSSY, 사용자 확인 있음 | 지원 불가 또는 UNKNOWN; 사용자 확인으로 적용·실행 불가 | NOT RUN |
| CV04 | 선택적 display 필드 LOSSY, 모든 필수 필드 EXACT | 손실 diff·별도 적용 승인 후 계획의 버전이 그대로인 경우에만 적용 후보 | NOT RUN |
| CV05 | 승인 후 파일 또는 Provider/Adapter version 변경 | CONFLICT/STALE; 새로운 계획과 승인 전 파일 무변경 | NOT RUN |
| CV06 | `client.remoteWorkspace=unknown`, local 경로와 remote URI가 비슷함 | 원격 지원 추론 금지, 위치 명시 및 원격 위험 행위 차단 | NOT RUN |
| CV07 | JSON 포트는 양측에 있으나 하위 schema/의미 미확인 | 타입 이름 일치만으로 EXACT라고 표시하지 않음; unknown/차단 | NOT RUN |
| CV08 | 임의 Provider 문서 링크·최신 버전 없는 과거 결과 | evidence 범위·날짜와 해당 버전의 불일치를 명시하고 unsupported가 아닌 unknown | NOT RUN |
| CV09 | 이전 시도에서 resume 지원, 현재 계정/버전 변경 | stale·정책 재평가, 기존 attempt의 자동 재시작 금지 | NOT RUN |
| CV10 | Provider의 비용 필드 누락 또는 통화 불명 | 비용 unknown; 0·다른 계정의 요율·청구액으로 대체하지 않음 | NOT RUN |
| CV11 | 같은 계정 유형이나 다른 accountRef를 사용 | 이전 계정 snapshot을 재사용하지 않고 새 범위 확인; 미검증이면 UNKNOWN | NOT RUN |
| CV12 | trust가 같지만 workspaceId 또는 URI authority만 변경 | 이전 workspace 권한/지원 결과를 자동 재사용하지 않고 새 범위 확인 | NOT RUN |
| CV13 | 동일 workspace에서 clientId 또는 clientKind만 변경 | 기존 인증·권한·capability 결과를 그대로 적용하지 않고 새 client 범위 검증 | NOT RUN |
| CV14 | protocol major/minor 또는 Core 정책 버전만 변경 | 조건을 재협상하고 영향받은 이전 계획·승인을 stale로 표시 | NOT RUN |
| CV15 | executableIdentity 또는 CLI/Adapter/OS 버전만 변경 | 영향받는 증거를 stale로 표시하고 필수 기능 재확인 전 실행 차단 | NOT RUN |
| CV16 | scope의 accountRef, trust 또는 peer identity를 확인할 수 없음 | unknown/거부이며 같은 이름·종류·경로만으로 다른 snapshot을 선택해 실행하지 않음 | NOT RUN |
| CV17 | 인가된 동일 scope에서 모든 축과 version 고정, 증거와 정책 유효 | 필수 조건의 교집합을 정확히 평가하고 범위 밖 정보 노출 없이 결과 반환 | NOT RUN |
| CV18 | evidence는 공식 문서만 있고 현재 Oches의 실행/강제 검증 없음 | `basis=documented`, 실제 필수 지원 상태 unknown; 문서 존재를 verified 또는 자동 실행으로 승격 금지 | NOT RUN |

이 항목들은 독립 관측과 제품/Adapter를 대상으로 실행하기 전 문서상 기준이다. 공식 문서의 일반 기능 확인 및 수용 기준의 존재만으로 G2/G3/G8, 보안·법적 적합성, 실제 지원을 통과시키지 않는다.
