# ADR-016: 공통 Core 계약 결정 기준

상태: **사용자 채택 — 설계 기준**, 2026-11-16. 기준: [계약 확정 제안 v0.1](../CONTRACT_FINALIZATION_PROPOSAL.md) D01~D08과 사용자 지시. 이는 설계 방향의 채택이며 OS·Provider 지원, 제품 구현·보안 시험·출시 승인을 의미하지 않는다. D02의 XPC는 아래 범위에서 검증을 우선할 후보이며 실증 전 무조건적인 운영 지원 결정이 아니다. ADR-014의 다른 항목의 승인 상태를 소급 변경하지 않는다.

## 결정

1. **D01:** 클라이언트별 별도 도메인 API가 아닌 공유 논리 Core의 명령·조회·이벤트 계약을 사용하며 transport adapter를 분리한다.
2. **D02:** macOS의 서명된 Desktop ↔ Core에서는 XPC peer 서명 요구사항을 **우선 검증할 후보**로 한다. 기존 Unix socket 후보와 병행 검토 후 정합한 배포·서비스 발견·서명과 OS별 양성/부정 시험 전 실제 지원으로 선언하지 않는다. Windows/Linux의 적합한 transport·신원 검사는 미결이다.
3. **D03:** Chrome의 Native Messaging `allowed_origins`와 Chrome 제공 caller origin을 정상 경로의 접근 제한·확장 식별에 사용한다. VS Code의 `publisher.name`, Workspace Trust와 Host 위치를 공식 플랫폼 경계로 사용한다. Core에서 개별 확장의 플랫폼 신원을 독립 증명하지 못하는 경우의 주체는 사용자 채택 [ADR-017](ADR-017-user-enrolled-client-key.md)의 설치별 등록키로 하며, Desktop의 요청별 승인·현재 권한·메시지 보호 조건을 적용한다. 등록키를 플랫폼이 증명한 확장으로 표시하지 않는다. 조건 미충족 시 해당 작업을 차단한다.
4. **D04:** 변경 시 기대 revision과 `(인증 주체, workspace, operation, requestId)` 범위의 멱등성 검사를 사용한다. 상태·관련 이벤트·요청 결과·감사는 동일한 로컬 트랜잭션에 결부한다는 요구를 유지하며 실제 내구성은 저장 엔진 시험으로 확인한다. 외부 CLI·파일과 DB는 단일 원자 작업이 아니다.
5. **D05:** Core wire는 versioned UTF-8 JSON 객체와 **RFC 8785 JCS + SHA-256 정규화**를 설계 기준으로 하며 protocol, template 교환, AgentDefinition 버전은 독립한다. 크기 상한 제안(envelope 256 KiB, 깊이 32, 문자열 64 KiB)과 operation별 세부 필드 스키마·교차 런타임 벡터 시험은 구현·검증 단계에서 확정한다. YAML은 템플릿 교환 입력 후보이며 Core wire 포맷이 아니다.
6. **D06:** 외부 실행 없이 Prepared attempt를 예약·저장 → 해당 attempt에 결부한 실행 승인 → start 직전 승인/Capability를 재확인한다. Provider 전송이 수반되면 별도 전송 승인이 필요하다. 새 시도는 새 attempt와 새 실행 승인이다.
7. **D07:** 연결 손실을 종료로 추정하지 않고 재인증 후 일관된 snapshot/cursor 또는 이벤트 복구를 수행한다. 외부 시작 여부가 불명확하면 Unknown/Blocked로 유지하고 자동 재시작하지 않는다.
8. **D08:** [제안서 §4](../CONTRACT_FINALIZATION_PROPOSAL.md)의 공통 논리 오류 분류와 호출자 동작을 사용한다. transport별 상태 코드·직렬화 세부는 해당 transport 선정 시 정의한다. 존재 여부·비밀을 불필요하게 공개하지 않는다.

## 플랫폼 식별과 실제 신원 결부

Chrome은 정상 Native Messaging 경로에서 manifest의 정확한 `allowed_origins`를 검사하고 호출 확장 origin을 Host에 전달한다. 이는 그 경로의 플랫폼 식별·접근 제한이다. Host를 OS에서 직접 실행할 수 있는 경우 임의 프로세스가 같은 인자/stdin을 지정할 수 있으므로 문자열만으로 실제 Chrome 호출임을 Core가 독립 증명하지 못한다. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

VS Code의 `publisher.name`은 확장의 공식 설치·조회 식별자이고 Workspace Trust는 프로젝트 신뢰 제어다. 하지만 Extension Host는 VS Code 수준의 권한으로 여러 확장을 실행할 수 있으므로 Host의 프로세스 신원만으로 호출한 개별 확장을 자동 식별한다고 가정하지 않는다. [VS Code Extension API](https://code.visualstudio.com/api/references/vscode-api), [Extension runtime security](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security).

Apple XPC의 peer 요구사항은 **상대 실행 프로세스의 서명 요구사항**을 확인하는 수단이다. 이것만으로 Chrome 내 어떤 확장이 메시지를 보냈는지나 공유 VS Code Host 내부의 개별 확장을 증명하는지에 대한 보장은 위 자료에서 확인되지 않았다. 이는 모든 가능한 방식이 불가능하다는 판정이 아니다. [Apple XPC peer 요구사항](https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_code_signing_requirement%28_%3A_%3A%29).

## 검증 게이트와 미결

- G2의 문서 정합성은 채택된 D01~D08과 ARC-04~15의 객체 소유·API·오류·버전·시도/승인 순서 및 X01~24·FC01~10을 전수 대조해 재판정한다. 후보로 남긴 항목은 확정된 값으로 간주하지 않는다.
- G3의 설계 판정과 제품 시험은 분리한다. 설계 기준에서는 macOS 양방향 XPC `xpc_connection_set_peer_team_identity_requirement`, [ADR-017](ADR-017-user-enrolled-client-key.md)의 사용자 등록키, [Noise IK 종단 보안 채널](../EXTENSION_SECURE_CHANNEL.md) 및 Desktop 요청별 승인·실패 시 차단 계약을 확정한다(**설계 게이트 G3 PASS**). 반대로 macOS의 올바르게 서명된 양성·다른 팀/ad-hoc·Host 직접 실행·공유 Host/원격·키/서명 교체·철회·재생 등 실제 제품 대조는 **NOT RUN**이며, Windows/Linux는 별도 OS 설계·시험 전 지원 **UNKNOWN**이다.
- G8의 수용 기준 정의와 제품 시험 결과는 구분한다. 제품·OS·Provider 테스트 미실행은 NOT RUN이며 이 ADR 채택이 통과를 뜻하지 않는다.

설계 기준과 별도로, 실제 OS·제품 환경에서의 XPC 배포/서비스 발견, Keychain/WebCrypto/SecretStorage 보호, Provider 실제 인증·권한 집행, 제품 구현 wire schema 및 지원 버전 시험은 **NOT RUN**이다. 제품의 해당 고위험 기능 지원은 제품 시험 게이트를 통과하기 전 보류한다.

## 설치별 인증키 및 종단 채널 보충

플랫폼 식별, 설치별 비대칭 키 소유 증명, Noise IK 종단 보안 채널(`Noise_IK_25519_ChaChaPoly_SHA256`), RFC 8785 JCS + SHA-256 정규화, Core 공통 인가 계약은 [설치별 인증 설계](../CLIENT_INSTALLATION_AUTH_DESIGN.md)와 [종단 보안 채널 설계](../EXTENSION_SECURE_CHANNEL.md)를 따른다. 이는 설계 기준의 확정이며 제품 구현 및 OS별 실행 검증 완료를 뜻하지 않는다.
