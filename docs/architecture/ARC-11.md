# ARC-11 Multi-Client & Shared Core API

상태: 상세 설계 제안 v0.1 · 2026-11-16. ARC-00 v0.2, ADR-014, ARC-05~10 및 ARC-15를 기준으로 한다. 이 문서의 원문은 초안이다. 사용자는 후속 [ADR-016](adr/ADR-016-core-contract-baseline.md)의 D01~D08 설계 방향을 채택했다. 구현 및 OS별 보안 검증은 아직 없으며 제품 지원을 뜻하지 않는다.

## 1. 범위와 배포 전제
Core는 workspace의 정책·정본·실행 소유자이며 각 클라이언트는 인증된 명령과 읽기 투영만 가진다. 인증·인가·프로토콜·이벤트 전달은 이 문서, 정책 판단은 ARC-09, 프로세스는 ARC-06, 작업은 ARC-07, 원자적 기록은 ARC-10의 책임이다. Provider 로그인은 ARC-05이고 클라이언트 인증과 독립적이다. ARC-12/13은 각각 플랫폼 경계를 담당한다. 하나의 사용자·한 호스트·로컬 파일시스템별 단일 Core가 초기 후보이며 원격 다중 호스트와 TCP 노출은 미지원이다. 데스크톱 내장 배치라도 동일한 논리적 권한 검사를 거친다.

사용자 채택 [ADR-017](adr/ADR-017-user-enrolled-client-key.md)은 확장 요청의 주체를 `USER_ENROLLED_KEY`로 등록하고 Desktop의 요청별 승인을 요구한다. `PLATFORM_BOUND`는 플랫폼이 개별 확장의 동일 연결·키를 독립 증명하는 별도 수준이다. 이 둘을 혼동하지 않으며 아래의 앱 신원·종단 보호 요구는 선택된 수준에 필요한 Core/신뢰 UI 검증 및 메시지 무결성을 뜻한다. 플랫폼 경로의 실제 지원과 보안 집행은 별도다.

보안 모델은 관리자/root, 동일 OS 사용자로 임의 코드 실행이 가능한 악성 프로세스, 변조된 OS나 확장 자체의 완전한 장악을 방어한다고 주장하지 않는다. 동일 사용자 악성 프로세스는 가능한 한 peer identity·파일 보호·사용자 확인으로 방어하되 OS의 앱 신원 인증을 입증하지 못하면 해당 연결과 위험 작업을 비활성화한다. workspace 내용과 웹페이지, 설치된 다른 확장, 임의 로컬 사용자는 비신뢰다. 사용자 승인은 악성 클라이언트 식별을 대체하지 않는다.

## 2. 연결·등록·권한 계약
- 사용자 채택된 ADR-016에 따라 macOS의 서명된 Desktop↔Core는 XPC를 우선 검증할 후보로 한다. Unix domain socket 또는 Windows named pipe는 OS별 추가 후보이며 v1 범위 밖이다(P1·P9, 2026-11-17 확정). OS 권한, peer credential과 실제 앱 신원 증명 지원을 OS별 검증한다. 단순 파일 권한, PID, Origin, Chrome extension ID 및 loopback은 클라이언트 인증에 충분하다고 간주하지 않는다. 네트워크 파일시스템, 원격 포워딩 및 localhost TCP는 지원하지 않는다.
- 최초 등록은 신뢰된 Desktop의 사용자 확인 화면에서 클라이언트 종류·식별자·workspace·권한을 명시한 단회 등록을 요구한다. Core는 검증 가능한 클라이언트 서명 공개키와 Noise static X25519 공개키를 등록하고 클라이언트는 개인키를 플랫폼 보안 저장소에서 생성·보관한다. 확장–Core 간 종단 기밀성과 무결성은 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md) (`Noise_IK_25519_ChaChaPoly_SHA256`)를 따르며, 인증은 RFC 8785 JCS 정규화 및 SHA-256 digest 기반 서버 nonce·프로토콜·대상 Core ID를 포함한 서명 검증, 인증 상태의 검증된 연결 결부 및 Core 신원 검증을 요구한다. 등록 자체의 신원 확인이나 안전한 개인키 저장 조건이 충족되지 않으면 평문 fallback 없이 등록을 거부한다. 비밀을 명령행 인자·로그·웹뷰·웹페이지로 전달하지 않는다.
- 등록 내역은 clientId, 공개키 지문, 설치 출처·검증 상태, OS 사용자, 허용 workspace·행위, 생성·만료·철회 시각, 인증 정책 버전을 갖는다. 공개키 보유만으로 앱 무결성을 증명하지 않는다. 신규 권한은 별도 사용자 확인, 만료·철회는 새 요청 즉시 거부, 키 교체는 기존 권한 회수 후 재등록한다. Core 재설치·신원 변경 시 클라이언트는 연결을 보류하고 사용자에게 다시 확인받는다. 감사 기록의 실패는 변경·실행 요청을 차단한다.
- 권한은 `workspace:read`, `workspace:write`, `observation:raw:read`, `diagnostics:read`, `template:read`, `template:write`, `run:request`, `run:observe`, `run:cancel`, `context:submit`, `approval:decide` 등 명시적 범위로 구분하며 기본은 거부다. 등록된 범위, workspace, 작업별 정책, 유효한 사용자 승인과 실제 강제 가능성의 교집합만 허용한다. Extension이나 Content Script는 다른 클라이언트의 승인 화면을 사칭하거나 승인 자체를 발급할 수 없다. 보안 수준을 증명한 신뢰 UI만 `approval:decide`를 받는다. 위험 작업 실행 중 철회 시 추가 요청은 즉시 거부하고 ARC-06에 취소를 요청하되 실제 중단 확인 전 완료를 주장하지 않는다.

## 3. API와 버전
요청 envelope는 `protocolMajor`, `protocolMinor`, `clientId`, `workspaceId`, `requestId`, `operation`, `payload`를 갖는 versioned UTF-8 JSON 객체(RFC 8785 JCS + SHA-256 정규화)이며 Core는 인증 상태를 검증된 연결 객체에 결부한다. 단순 연결 ID를 envelope에 담는 것만으로 암호학적 channel binding이 되지 않는다. `USER_ENROLLED_KEY` 경로는 설치키·Core 신원·요청 무결성·Desktop 승인과 [Noise IK 종단 보안 채널](EXTENSION_SECURE_CHANNEL.md)의 기밀성·4 KiB 버킷 패딩·범주형 오류 매핑을 요구하며, 실시간 중계를 막는다고 주장하지 않는다. 이 경로의 필수 조건을 확인할 수 없으면 해당 위험 기능을 차단한다. 결부 수단과 wire 필드는 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md#서명-중계-및-명령-변조-경계)와 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md)를 따른다. workspace 경로는 클라이언트가 보낸 절대 경로만 신뢰하지 않고 Core가 등록된 workspace 정본으로 해석한다. 인증 후 `hello`에서 지원 major와 minor 범위·capability를 교환한다. 공통 major가 없으면 `UNSUPPORTED`의 세부 유형 `VERSION_UNSUPPORTED`로 변경과 실행을 중단한다. 공통 major에서 지원 minor 범위가 겹치면 그중 가장 높은 공통 minor와 명시된 기능 교집합을 사용하고, 범위가 겹치지 않으면 거부하며 의미를 모르는 필수 필드는 거부한다. 스키마·프로토콜 버전은 Template schemaVersion과 독립적이다.

| 연산 | 권한 및 입력 | 결과와 오류 |
|---|---|---|
| `getCapabilities` | 인증·workspace 읽기 | 지원/미지원/unknown 및 근거와 만료 시각 |
| `command` | 행위별 권한, requestId, expectedRevision, 정책·승인 참조 | 소유 모듈의 결과 또는 `DENIED`, `APPROVAL_REQUIRED`, `CONFLICT`, `UNSUPPORTED`, `UNKNOWN`, `UNAVAILABLE` |
| `observe` | run:observe, scope, cursor | 순서 정보·다음 커서·유실 표시; `CURSOR_EXPIRED`면 정본 snapshot 조회 필요 |
| `snapshot` | workspace 읽기 | 권한에 맞는 현재 정본과 revision, snapshot 기준 cursor |
| `revokeClient` | 신뢰 UI와 관리 권한 | 등록 철회 감사 기록 후 기존 세션 폐쇄; 실패 시 성공으로 표시 금지 |

`requestId`는 인증 주체·workspace·operation에 한정하고 정규화 입력 해시와 결과를 ARC-10 원자 트랜잭션에 저장한다. 같은 입력 재시도는 기존 결과, 다른 입력은 `CONFLICT`다. 보존기간 이후 재시도는 `IDEMPOTENCY_EXPIRED`로 명시하며 새 ID로의 외부 실행 재시작을 자동 유도하지 않는다. 이벤트는 중복·누락될 수 있고 각 이벤트의 ID와 원본별 순서를 제공한다. 커서가 만료되거나 유실되면 snapshot을 다시 읽으며 재생만으로 누락 없음을 주장하지 않는다.

## 4. 상태·장애·동시성
클라이언트 상태는 Unregistered → PendingUserConfirmation → Active → Revoked/Expired이고 변경은 감사 기록과 함께 커밋한다. Core 시작 시 workspace별 배타적 소유권을 OS가 제공하는 잠금으로 획득·검증하고 실패하면 읽기 전용 진단 또는 종료한다. 잠금의 효과는 대상 파일시스템에서 검증 전 보장하지 않는다. 연결 단절은 실행 취소를 의미하지 않는다. 재연결 시 인증·권한을 다시 검사한 뒤 cursor에서 조회하고 누락이면 snapshot으로 복구한다. Core 장애 후 ARC-06의 Unknown 정책이 우선하며 실행을 자동 재시작하지 않는다. 각 명령의 버전 충돌, 승인 만료, 정책 변경은 변경 없이 오류를 반환한다.

## 5. 위협·검증과 완료 기준
| 위협 | 요구 대응 | 검증할 관찰 |
|---|---|---|
| 다른 OS 사용자 또는 임의 프로세스의 IPC 접근 | 사용자 전용 endpoint, peer 검증과 서명 인증 | 미등록 키·다른 사용자 요청 100% 거부 및 비밀 미노출 |
| 동일 사용자 프로세스가 등록 UI·키·Core를 교체 | 신뢰 UI 신원과 키 보호를 OS별 증명; 불가능하면 기능 비활성 | 교체·키 탈취 시나리오별 거부 또는 명시적 미지원; 완전 방어 주장 금지 |
| 웹페이지가 실행 또는 승인 요청 위조 | ARC-13 경계, Content Script 입력 비신뢰, 승인 권한 분리 | 웹 텍스트·메시지만으로 실행/승인 불가 |
| 오래된 승인·중복 요청·권한 철회 | 버전과 범위 재검사, 원자적 중복 판정 | 변경 없이 충돌/거부, 철회 후 새 작업 0건 |
| 연결 유실·중복 Core·구버전 | 재인증, cursor/snapshot, lock·버전 협상 | 이중 소유·무음 손실·자동 재실행 0건 |

설계 완료 조건은 ARC-05/06/07/09/10/12/13/15 교차 검토와 사용자 승인이다. 구현 지원 게이트는 각 대상 OS·버전의 인증·키 보관·서버 신원 검증, 변조·거부 시험 통과 및 증거 기록이다. 어느 하나라도 실패 또는 미실행이면 해당 클라이언트의 변경·실행 기능은 미지원이다. 공식 근거: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [VS Code Remote Extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions). Chrome allowlist는 Core 인증을 대체하지 않는다.

원본 관찰 읽기와 진단 읽기는 별도 권한이다. `workspace:read` 또는 `run:observe`만으로 원본 관찰 본문이나 진단을 반환하지 않는다. 진단은 원본 읽기 권한을 포함하지 않는다. 권한 없는 요청은 본문 없이 DENIED를 반환하며 ARC-10 삭제 중·삭제 실패 데이터는 삭제 상태에 맞게 접근을 차단한다. V-13과 V-16은 권한 교차 접근, 삭제 실패 및 백업 복원 후 삭제 재적용을 검증한다.

`snapshot`은 권한 검사 후 ARC-10의 동일한 일관된 읽기 시점에서 상태 revision과 그 상태에 반영된 마지막 durable event cursor를 함께 반환해야 한다. 클라이언트는 그 cursor **이후**의 이벤트를 요청하고 eventId로 중복을 제거한다. 이 경계가 보장되지 않으면 snapshot은 `UNAVAILABLE`로 반환하며 완전한 재동기화를 주장하지 않는다. snapshot 중 발생한 변경, 커서 보존 만료와 권한 철회가 경합하는 시험에서 상태 누락 0건을 요구한다. 실제 저장 엔진이 이 일관성을 제공하는지는 미검증이다.

## 확장 플랫폼 식별 보충

Chrome의 Native Messaging allowlist와 Chrome이 Host에 전달하는 caller origin은 정상 Chrome 경로의 접근 제한·Extension 식별이다. VS Code의 `publisher.name`은 공식 설치·관리 식별자다. 각 플랫폼에서 제공한 식별을 사용하되 Host 직접 실행, 공유 Host와 Core 연결까지 신원이 결부되는지 별도 검증한다. 정상 흐름·인가·오류·시험은 [확장 신원 경계](EXTENSION_IDENTITY_BOUNDARIES.md)를 따른다.

## 채택된 계약 기준 · ADR-016 및 ADR-017

사용자는 [ADR-016](adr/ADR-016-core-contract-baseline.md)의 D01~D08 및 [ADR-017](adr/ADR-017-user-enrolled-client-key.md)의 설치별 등록키·Desktop 요청별 승인 모델을 설계 기준으로 채택했다. macOS Desktop↔Core는 양방향 `xpc_connection_set_peer_team_identity_requirement`를, 확장↔Core는 `Noise_IK_25519_ChaChaPoly_SHA256` 종단 보안 채널과 RFC 8785 JCS + SHA-256 정규화를 설계 기준으로 확정했다. 실제 OS·브라우저·IDE 배포 및 제품 실행 보안 시험은 **NOT RUN**이다. Chrome/VS Code의 플랫폼 식별과 Core 결부는 ADR-016/017의 공식 근거와 [확장 신원 경계](EXTENSION_IDENTITY_BOUNDARIES.md)를 따른다.

## 설치별 키 인증 및 종단 채널 계약

플랫폼 식별, 설치별 비대칭 키 소유 증명, Noise IK 종단 암호화 채널, Core 공통 인가는 서로 독립적으로 적용한다. 플랫폼별 키 보관, 최초 등록·교체·복구 및 미검증 경계는 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)와 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md)를 따른다. 공유 비밀의 배포물 내 하드코딩과 키 저장 실패 시 평문 fallback은 금지한다. 이는 설계 기준의 확정이며 실제 제품 구현 및 플랫폼 실행 시험은 별도다.

## 설계 동결 · 2026-11-17

P1·P2·P11 확정. D01~D08·Noise IK·XPC 계약 유지. socket/pipe·원격·Windows/Linux는 v1 범위 밖. snapshot 일관성의 저장 엔진 실증은 제품게이트. 정본은 [설계 확정 기록 §6](DESIGN_FINALIZATION.md).
