# ARC-11 G3: macOS 연결 신원·승인 설계 기준

2026-11-16 · **설계 결정 기준** (제품 구현 및 OS 실행 시험 **NOT RUN**). [ARC-11](ARC-11.md), [ARC-09](ARC-09.md), [신뢰 선택지](ARC-11-TRUST-OPTIONS.md), [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md) 및 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)의 확정 계약을 정리한다. 확인 환경 macOS 26.4 (25E246), 로컬 Xcode macOS SDK 헤더. OS 지원 하한과 실제 배포 실행 통과는 제품 시험 결과로 별도 관리한다.

## 위협과 범위

웹페이지·workspace·다른 확장 및 동일 사용자 프로세스의 위조, endpoint 선점, 재생, 승인 내용 교체, 철회 경합을 다룬다. OS/root 손상, 이미 침해된 서명 제품이나 같은 사용자의 완전한 화면 장악·접근성 권한 악용에 대한 완전 방어는 보장하지 않는다. Provider 인증은 공식 CLI가 소유하며 이 프로토콜로 전달하지 않는다. 신뢰 UI 피싱을 OS가 자동으로 막는다고 가정하지 않는다.

## 전송과 실행 중 상대 신원

- macOS 후보는 서명된 Desktop UI ↔ 서명된 Core의 **XPC 연결**이다. 양쪽에서 연결 사용 전 peer 서명 조건을 설정하고, 수신된 각 메시지에 적용되는 OS 검사를 요구한다. 로컬 SDK `xpc_connection_set_peer_code_signing_requirement`는 macOS 12.0 이상, `xpc_connection_set_peer_team_identity_requirement`는 14.4 이상으로 선언돼 있다. 후자는 호출 프로세스와 같은 Team ID와 지정 signing identifier를 요구한다. `NSXPCConnection.setCodeSigningRequirement`는 SDK상 macOS 13.0 이상이다. SDK 선언은 설치된 OS·배포 방식에서 실증한 결과가 아니다.
- 우선 후보는 각 방향에 대해 상대의 **정확한 signing identifier와 동일 Team ID**를 요구하는 `xpc_connection_set_peer_team_identity_requirement`다. 이 API의 Team ID는 인자가 아니라 호출 프로세스의 Team ID다. 제품 UI와 Core가 동일 팀의 실제 배포 서명이라는 전제가 필요하며 ad-hoc 서명은 정상 양성 대조로 인정하지 않는다. 필요하면 명시적 Apple 발급 anchor·Team ID·identifier를 포함한 코드 서명 requirement의 `xpc_connection_set_peer_code_signing_requirement`를 별도 대안으로 시험한다. 정확한 인증서 체인·배포 유형 및 회전 정책은 검증 후 확정한다.
- 각 연결에는 peer requirement 계열 중 **하나만** 설정하고 반환값을 확인한다. 헤더에 따르면 중복 설정은 프로그래밍 오류이며 listener 부적합 메시지는 drop, reply가 기대되면 `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`가 전달된다. 서버가 요청을 관측하지 못할 수도 있으므로 클라이언트 timeout을 실패로 처리한다. 설정 오류, 미지원 OS, peer 불일치, timeout, 연결 중단은 인증 실패/UNKNOWN으로 기록하고 민감 데이터·변경·실행을 차단한다. PID로 파일 경로를 검사해 XPC 상대 대신 인증하지 않는다. XPC 실제 배포·서비스 발견·양방향 적용은 양성 대조 실험 전 미확정이다.
- 이 XPC 경계는 [ADR-016 D02](adr/ADR-016-core-contract-baseline.md)가 macOS 서명 Desktop↔Core에서 우선 검증하도록 채택한 후보이며 Unix socket과의 비교 및 배포 시험은 미완료다. 경로 socket+UID만으로 같은 사용자 프로세스를 분별하지 못한다는 기존 실험 결과는 유지한다. TCP localhost/CORS/Origin은 인증으로 취급하지 않는다.

## 등록·연결·승인 호출 순서

1. 사용자가 OS에서 직접 실행한 서명된 Desktop 신뢰 UI가 배포된 Core에 연결하고 **서로의 live XPC peer requirement를 먼저 통과**한다. UI 자체 표시만으로 사용자가 진짜 앱을 판별할 수 있다는 보장은 없으므로 설치 출처·서명·시스템 UI와 위장 대조를 별도로 검증한다. Core 설치 전 UI·Core의 신뢰 시작점은 서명 배포 및 사용자 설치 경로에 의존한다.
2. 신규 클라이언트는 미등록 상태로 요청한다. UI는 Core에서 직접 읽은 후보의 검증 결과, 종류, workspace 정본, 최소 권한과 만료를 표시한다. Core는 UI가 XPC 검증을 통과한 제품 UI인지 확인하고 단회 등록 트랜잭션을 준비한다. 확장 ID 또는 클라이언트가 주장한 문자열만 표시해 신원을 입증하지 않는다. Chrome의 플랫폼 확인 Extension ID 또는 VS Code의 publisher.name을 각각 플랫폼 범위의 식별 근거로 기록한다. Host→Core의 개별 확장 결부를 확인할 수 없으면 플랫폼 증명으로 표시하지 않으며, [ADR-017](adr/ADR-017-user-enrolled-client-key.md)의 사용자 등록키 조건이 충족될 때만 해당 수준으로 등록한다.
3. UI에서 사용자 확인 후 Core가 등록 ID·실제 검증된 신원·공개키(사용 시)·정책 버전·권한·workspace·만료·감사를 한 트랜잭션으로 저장한다. 실패하면 등록하지 않는다. Core 재설치/신원 불일치, 권한 확대, 키 교체는 기존 권한 철회 또는 보류 후 별도 재등록한다. 동의 버튼의 요청은 검증된 UI 세션에서만 수락한다.
4. 매 연결에 양방향 peer 조건 적용 후 프로토콜 버전과 임의 연결 ID를 교환한다. 키 증명이 필요한 경우 각 측이 OS 난수 challenge를 만들고, 상대는 역할 구분 문자열, 프로토콜 버전, 두 nonce, 연결 ID, 양쪽 등록 ID/키 지문, 만료를 포함한 명확한 길이 접두 인코딩에 서명한다. Core는 단일 사용 nonce의 발급·소비를 원자적으로 처리하고 중복·만료·재시작 후 미확인 값을 거부한다. 이 메시지의 연결 ID는 암호학적 XPC channel binding을 자동으로 뜻하지 않는다. **OS가 검증한 연결 객체에 handshake 상태를 보관하고 동일 객체에서만 사용한다**는 조건과 relay 저항은 실제 XPC 시험이 필요하다. 보안성 입증 전 키 서명이나 이 설계만으로 G3 통과를 주장하지 않는다.
5. 요청은 Core 정본 workspace ID, operation, 정규화된 대상·내용 해시, expectedRevision, client ID, 정책 버전, request ID를 묶는다. 위험 작업은 UI가 신뢰된 Core에서 직접 받은 동일 내용을 표시하고 짧은 만료의 단회 승인을 Core에 보낸다. Core는 실행 직전 등록 상태·권한·revision·정책·승인 범위 및 만료를 원자적으로 확인·소비하고 감사와 작업 예약을 함께 기록한다. 상이하면 `DENIED`/`APPROVAL_REQUIRED`/`CONFLICT`, 감사 실패는 `UNAVAILABLE`이며 부작용을 시작하지 않는다.
6. 철회는 정책 버전 증가와 등록 철회를 커밋한 후 신규 요청을 거부한다. 이미 실행 중인 작업은 ARC-06 취소를 요청하고 확인 전 중단 성공을 표시하지 않는다. 파일 심볼릭 링크 교체·외부 CLI 부작용은 DB 트랜잭션만으로 해결되지 않으므로 안전한 파일 핸들 기반 적용, 실행 직전 재검사 및 작업 격리의 OS별 검증이 필요하다. 이를 보장할 수 없는 동작은 차단한다.

## 키·확장·배포 경계

키는 별도 제품 서명 및 entitlement에 연결된 Keychain/Secure Enclave 후보를 검토하되 동일 사용자 다른 프로세스에 대한 접근·내보내기·서명 대리 오용을 실증하기 전 보호를 주장하지 않는다. 접근 불가·잠김·실패 시 평문 파일 fallback 없이 차단한다. Secure Enclave 가용성, 재설치·백업·회전과 사용자 상호작용 정책은 미정이다.

Chrome의 Native Messaging은 Chrome이 Host를 별도 프로세스로 실행하고 stdio로 통신하며 manifest의 `allowed_origins`는 와일드카드가 없다. 이를 이용한 브라우저 측 접근 제약은 Core↔Host XPC 인증과 별개다. 임의 프로세스가 Host를 직접 실행해 위조 stdin/인자를 주거나, 정상 확장이 비신뢰 페이지 메시지를 중계할 수 있다. Host가 자신을 Core에 인증하는 것만으로 Extension/사용자 의도가 입증되지 않는다. Chrome이 시작한 정상 흐름에서는 Chrome의 allowlist와 전달한 caller origin이 Extension 접근 제어 및 식별 근거다. 다만 직접 실행에서는 동일 문자열이 위조 가능하므로 실행 출처를 Core에 결부하는 보장은 별도 검증한다. 검증 미완료인 고위험 기능은 제품 지원 게이트에서 보류한다. 자세한 흐름은 [확장 신원 경계](EXTENSION_IDENTITY_BOUNDARIES.md)를 따른다.

VS Code 확장 코드는 보통 여러 확장이 공유하는 Extension Host에서 실행되므로 Host 서명은 개별 Oches 확장의 신원 증명이 아니다. Workspace Trust는 workspace 실행 위험에 대한 조건이지 확장 신원 인증이 아니다. VS Code가 제공하는 publisher.name은 설치·관리 식별자로 사용한다. 독립 프로세스 신원 증명과 동일시하지 않고 Core에 연결된 요청과의 결부는 별도 검증한다. 고위험 기능의 제품 지원은 해당 검증과 승인 게이트에 따른다. SSH/WSL/Dev Containers 원격 Host는 별도 호스트 신원·경계가 필요하며 미지원이다.

Developer ID/배포 서명, notarization, hardened runtime, XPC service 배치·발견, Chrome manifest 설치 권한 및 업데이트 시 Team ID/identifier·키 유지/교체, 롤백과 버전 호환을 제품 배포 형태별로 실증한다. 업데이트 후 identity 변경 시 자동 신뢰하지 않는다. 서명된 제품 양성 대조가 없으면 통과 판정하지 않는다.

## 검증과 판정

| 항목 | 설계 계약 상태 | 제품 양성·부정 대조 | 제품 시험 판정 |
|---|---|---|---|
| UID·identifier 단독 | 동일 UID 및 ad-hoc 식별자 위조 가능 기존 실험 | 해당 단독 방식은 거부 | **FAIL: 단독 인증안** |
| XPC live peer·양방향 | `xpc_connection_set_peer_team_identity_requirement` 양방향 적용 및 실패 시 차단 계약 확정 | 올바른 팀·identifier 양성, 다른 팀/ad-hoc·가짜 Core·교체·동일 UID 음성, 각 방향 검사 | **설계 PASS / 제품 NOT RUN** |
| 키 보호·사용 제한 | 서명키 Secure Enclave/Keychain + X25519 Data Protection Keychain ACL, 실패 시 `KEY_UNAVAILABLE` | 서명 제품 양성, 다른 서명·동일 UID 프로세스 내보내기/서명 오용·잠김·회전 | **설계 PASS / 제품 NOT RUN** |
| 최초 등록·승인·철회·재생 | JCS transcript·단회 nonce·Desktop XPC 승인·Noise IK 종단 채널 계약 확정 | 위조 UI, relay, nonce 동시 재생, 변경 revision/권한, 철회와 실행 경합, 충돌·복구 | **설계 PASS / 제품 NOT RUN** |
| Chrome/VS Code 단위 신원 | ADR-017 `USER_ENROLLED_KEY` + Noise IK 종단 암호화·4 KiB 패딩 + Desktop 요청별 승인 확정 | 직접 Host 실행, 다른 확장·페이지 위조, VS Code 공유 Host 및 원격 구분 | **설계 PASS / 제품 NOT RUN** (원격 Host 미지원) |
| Windows/Linux | 플랫폼별 별도 OS transport·키 보호 설계 및 실증 필요 (초기 MVP 범위 외) | ARC-11 소유자가 named pipe/Unix peer identity, 키 보호 및 배포별 양·부정 대조 정의 | **대상 OS 미확정 / NOT RUN** |

공식 근거: [Apple XPC 변경 이력](https://developer.apple.com/documentation/updates/xpc) (2024년 3월 peer requirement), [Apple XPC peer 요구사항 예제](https://developer.apple.com/documentation/browserenginekit/using-xpc-to-communicate-with-browser-extensions), [Apple Keychain 접근 그룹](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [VS Code Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust). 2026-11-16 확인. 실제 설치 SDK 헤더의 availability는 해당 SDK의 관찰값이며 공식 문서만으로 제품 보안을 인증하지 않는다.
