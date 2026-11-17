# 클라이언트 설치별 인증키와 Core 공통 인가 설계

2026-11-16 · **설계 결정 기준** · 제품 구현 및 OS·런타임 보안 시험 **NOT RUN**. 사용자 지시로 플랫폼 식별 + 설치별 비대칭 키 소유 증명 + Core 공통 인가 + 종단 보안 채널을 설계한다. [ADR-017](adr/ADR-017-user-enrolled-client-key.md)은 플랫폼이 개별 확장의 종단 신원을 증명하지 못하는 경우 사용자 등록키와 Desktop 요청별 승인을 채택하며, 확장–Core 간 기밀성·무결성은 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md) (`Noise_IK_25519_ChaChaPoly_SHA256`)를 따른다. 실제 OS·Chrome·VS Code 런타임 제품 시험 결과는 별도이다.

## 원칙과 주체

각 Desktop 설치, VS Code 설치 프로필, Chrome 확장 프로필을 별도의 등록 주체로 취급한다. 각각 고유한 비대칭 키쌍을 생성하고 Core에는 공개키와 지문만 등록한다. 배포물에 모든 설치가 공유하는 비밀키·API 키·인증 토큰을 하드코딩하지 않는다. 공개 제품 서명 인증서나 공개키는 비밀이 아니다. 하나의 키를 여러 플랫폼/프로필에서 공유하거나 동기화하지 않는다. Provider 로그인은 ARC-05 소유이며 인증키와 구분한다.

플랫폼 식별은 **어느 플랫폼 경로에서 누구라고 식별되는지**, 키 서명은 **등록된 개인키 보유**, Core 정책은 **해당 요청의 권한**을 각각 확인한다. 어느 한 단계도 다른 단계를 대체하지 않는다. 특히 키 보유는 무결한 확장, 실제 사용자 행위, 악성 동일 사용자 프로세스에 대한 격리 또는 OS 증명을 자동으로 뜻하지 않는다. 연결된 클라이언트가 침해되거나 서명 대리자로 악용되는 문제는 별도다.

## 플랫폼별 생성·보관

| 클라이언트 | 생성·보관 후보 | 실제 보장과 제한 |
|---|---|---|
| macOS Desktop | 서명된 앱이 Keychain을 통해 설치별 비대칭 키를 생성; 지원 기기에서는 P-256 Secure Enclave 키와 접근 제어를 우선 검토 | Apple 문서는 Secure Enclave 개인키를 평문으로 내보내지 않고 서명에 사용할 수 있다고 설명. 대상 기기, 접근 제어, 재설치, 업데이트 및 동일 사용자 타 앱 거부는 실제 제품 서명으로 시험 필요. 사용 불가·잠김 시 평문 fallback 없이 `KEY_UNAVAILABLE` |
| VS Code Extension | Extension Host에서 난수로 비대칭 키 생성 후 직렬화된 개인키를 `ExtensionContext.secrets`에 저장하는 후보. 공개키만 등록 | 공식 문서는 암호화된 secret, Desktop의 Electron safeStorage, 기기간 비동기화를 설명하고 Remote 가이드는 secrets가 클라이언트 측에 저장된다고 명시. 문자열을 읽어 서명하는 방식이므로 사용 중 메모리 노출 가능, 하드웨어 비추출 키·개별 확장의 악성 공유 Host 격리·동일 사용자 공격 방어를 보장하지 않음. OS 저장소 backend/약한 fallback은 대상 환경에서 확인하며 검증할 수 없으면 지원 보류. `workspaceState`/`globalState`에 비밀 금지 |
| Chrome Extension | Extension Service Worker에서 Web Crypto 비대칭 키를 생성하고 내보내기 불가 개인 `CryptoKey`의 IndexedDB 저장·복구를 우선 시험; 공개키만 Native Messaging으로 전달 | Chrome 문서는 Service Worker IndexedDB와 확장 origin 저장소 공유를 설명하지만 그 자체가 하드웨어 보호나 동일 사용자 공격에 대한 보호 보장은 아님. 키 지속성·복구·프로필 분리·비추출 속성의 Chrome 버전별 시험 필요. Extension 페이지 전체와 저장소가 공유되므로 접근 가능한 컴포넌트 침해/서명 대리 위험 존재. 미지원·소실 시 재등록; Content Script·페이지·`chrome.storage.sync`에 키 저장 금지 |

Chrome의 `extractable=false`는 API의 export/wrap 제한이며 하드웨어 보호, 동작 중 임의 코드의 서명 요청 방지 또는 OS 수준 비추출 증명이 아니다. VS Code SecretStorage의 암호화는 키가 손상되지 않았음을 보증하지 않는다. Web/원격 VS Code와 Windows/Linux의 실제 런타임 지원은 별도 대상별 검증 전 미지원(UNKNOWN)으로 취급한다. 정규화·서명 기준은 **RFC 8785 JCS UTF-8 + SHA-256**과 용도별 분리 키(서명: Secure Enclave P-256 또는 Ed25519, 채널: Noise IK X25519)로 고정한다.

## 최초 등록

1. 사용자가 신뢰할 수 있는 Desktop UI에서 등록을 시작한다. UI↔Core는 macOS 기준 양방향 `xpc_connection_set_peer_team_identity_requirement` 등 선택된 OS transport peer 조건을 먼저 통과한다. 제품 서명·Team ID 검증이 확인되지 않거나 UI 위장 위험이 해소되지 않으면 등록을 진행하지 않고 차단한다.
2. 클라이언트는 플랫폼에서 새 설치 서명키(`signingKey`)와 Noise static X25519 키(`noiseStaticKey`)를 별도 용도로 생성하고 공개키·알고리즘·설치 식별 후보를 전달한다. Chrome의 정상 `connectNative` 경로는 `allowed_origins`와 Chrome 제공 caller origin을 확인하고, VS Code는 설치된 `publisher.name`, Workspace Trust, Host/workspace 위치를 구분해 확인한다. 플랫폼이 전달한 신원과 자체 주장 문자열을 구분해 기록한다. Chrome 직접 Host 실행의 인자 위조 및 VS Code 공유 Host의 다른 확장 위장은 플랫폼 식별만으로 해소되지 않는다.
3. Core는 등록 ID·Core ID·클라이언트 유형·플랫폼 식별 증거·양쪽 서명/Noise 공개키 지문·요청 workspace 및 권한·만료·랜덤 nonce를 RFC 8785 JCS로 정규화해 묶은 단회 challenge를 발급한다. 클라이언트는 해당 설치 서명 개인키로 서명해 소유를 증명한다. 검증 UI에는 Core가 직접 확인한 값과 확인 불가 항목을 표시한다. **공개키 증명은 최초 사용자의 상대방 확인을 대체하지 않는다**. 최초 등록 가로채기 또는 위조 UI 방어가 보장되지 않으면 등록을 보류한다.
4. 사용자가 승인하면 Core는 challenge의 단회성·서명·플랫폼 증거·등록 중복 및 유효 시각을 재검사하고 `clientId`, `signingKey`/`noiseStaticKey`와 각 `keyId`·알고리즘, 플랫폼 유형·증거 수준, workspace와 권한, 정책 버전, 생성·만료·철회 상태, 감사 이벤트를 ARC-10 트랜잭션으로 저장한다. UI가 표시한 범위와 저장할 범위는 동일 JCS 정규화 digest로 결부한다. 부분 실패는 등록 취소다. 등록 요청만으로 `approval:decide`를 부여하지 않는다.

### 최초 Core 키 확인 및 Noise 키 결부 계약

Core 서명 공개키와 Core Noise static 공개키를 확장에 처음 고정하는 과정은 제품 서명이 확인된 Desktop↔Core XPC 경로와 확장의 표시 경로가 각각 신뢰할 수 있다는 전제 하에 **사용자 대조 + 양방향 키 결부**로 수행한다.

1. Desktop은 양방향 XPC peer 조건이 설정된 연결에서 Core 서명 공개키·Core Noise static 공개키(`coreNoiseStaticKey`)·버전·새 등록 세션·만료를 가져온다. 사용자가 별도로 연 확장은 새 설치 서명 공개키(`clientSigningKey`)·새 Noise static 공개키(`clientNoiseStaticKey`)와 요청 workspace·권한을 포함한 등록 요청을 만든다. 양측은 버전·용도 구분, 등록 세션과 단회 nonce, Core ID/서명키 지문/`coreNoiseStaticKey` 지문, 확장 서명키 지문/`clientNoiseStaticKey` 지문, 플랫폼 유형, workspace, 요청 권한과 만료를 포함한 **동일 RFC 8785 JCS 등록 transcript**의 SHA-256 digest를 각각 계산·표시한다. Desktop은 검증 가능한 플랫폼 증거와 확인 불가 사항을 따로 표시한다. 확장은 비교한 정확한 Core 서명 공개키·`coreNoiseStaticKey`와 transcript를 등록 완료 전 임시 보관한다.
2. 확장은 같은 JCS transcript digest와 단회 nonce에 설치 서명 개인키로 서명해 소유를 증명한다. 사용자가 두 표시값·대상·권한을 확인한 뒤 Core는 세션·만료·정확한 양쪽 키·PoP 서명·플랫폼 증거·사용자 확인을 재검증하고 nonce 소비·등록(서명키 및 Noise static 키 결부)·권한·감사를 하나의 트랜잭션으로 저장한다. UI에 표시한 정보가 요청 또는 저장 내용과 다르면 취소한다. 등록 완료 응답은 커밋 이후 Core가 용도·버전·세션·nonce·양쪽 서명키/Noise 키 지문·`clientId`·workspace·권한·결과와 transcript digest를 묶어 서명한다.
3. 확장은 서명 유효 여부만 확인하지 않고 **사용자가 대조한 임시 Core 서명 공개키**로 등록 완료 응답을 검증한다. 응답의 세션·nonce·양쪽 키·workspace·권한·digest·결과가 자신이 대조한 transcript 및 최초 요청과 정확히 일치하고 만료되지 않아야 Core 서명 공개키와 `coreNoiseStaticKey`를 고정한다. 불일치·재생·세션 교차는 거부한다. 등록 완료는 과거 커밋의 증거이며 현재 권한 활성의 증거는 아니다. 응답 유실 시 같은 비교 세션과 임시 Core 키에 결부된 상태 조회를 수행하되, 확장이 생성한 예측 불가능한 새 nonce와 현재 등록·철회 상태를 Core가 서명한 응답에 포함해야 한다. 확장은 해당 nonce·세션·키·현재 상태 및 유효기간을 검증하고, 조회 불가·철회·불일치면 활성으로 표시하지 않는다. 확인할 수 없으면 키를 고정하지 않고 재등록한다. 다른 키를 자동 신뢰하지 않는다. 매 명령의 인가는 Core가 현재 등록 상태를 다시 확인한다.
4. 비교 코드는 사람의 확인을 돕지만, 공격자가 두 표시 화면을 위조·조작하거나 사용자가 공격자의 화면을 신뢰하면 최초 신원을 보장하지 못한다. 정당한 양쪽의 메시지를 악성 Host가 그대로 실시간 relay하면 표시값이 일치해도 relay 자체는 탐지되지 않는다. 짧은 비교 코드에는 시도 횟수 제한 및 만료를 적용한다. 코드 일치는 Chrome/VS Code 개별 확장 무결성 또는 악성 Host 저항을 증명하지 않으므로, 등록 이후 실제 쓰기·실행·외부 전송은 반드시 Desktop 신뢰 UI의 요청별 승인과 [Noise IK 종단 보안 채널](EXTENSION_SECURE_CHANNEL.md)을 거친다. 필요한 신뢰 경계가 확인되지 않으면 등록과 위험 기능을 보류한다.
5. 허용 대상의 공개키(서명키 또는 Noise static 키) 변경·설치 재설정·Core 재설치 시 기존 등록을 보류하고 같은 절차와 명시적 사용자 확인을 다시 거친다. 사용자 승인만으로 미확인 플랫폼 신원을 검증된 것으로 승격하지 않는다. Windows/Linux·원격 Host의 동등한 신뢰 UI 경로는 대상별 실증 전 미지원으로 차단한다.

정상 양성 외에 양쪽 중 한쪽의 공개키 변경, 다른 세션·만료·재생, 위조 등록 완료 응답, Host의 양방향 relay 및 두 UI 위장을 시험한다. Desktop↔Core의 macOS 표준 경계는 Apple XPC peer requirement(`xpc_connection_set_peer_team_identity_requirement`)를 사용한다. [Apple XPC 안내](https://developer.apple.com/documentation/browserenginekit/using-xpc-to-communicate-with-browser-extensions). 위 등록 비교의 실제 제품 구현 및 플랫폼 시험은 **NOT RUN**이다.

### 주체별 권한 및 사용자 표시 계약

아래 표는 지원을 선언하는 표가 아니라, 검증된 증거에 따라 Core가 적용할 **최대 권한**이다. 어떤 증거도 부족한 요청은 기본 거부다. `표시`는 토큰·원본 로그·비공개 프로젝트 데이터의 공개를 허용하지 않는다.

| 확인된 주체·경로 | 허용 가능한 최대 동작 | 사용자 표시 및 실패 |
|---|---|---|
| OS가 검증한 제품 Desktop↔Core 경로, 신뢰 UI 조건 충족 | 해당 workspace의 명시된 관리·승인 요청. 실제 쓰기/실행은 정책과 각 행위의 승인 필요 | 제품·workspace·대상·권한·부작용 표시. 서명 조건/연결 검증 실패 시 승인·위험 작업 거부 |
| 사용자 등록·키 소유·Core 신원 또는 해당 행위의 필수 메시지 보호 조건 불명 | 등록 상태를 외부에 노출하지 않는 일반 오류만 반환. 키 보유만으로 읽기·변경·실행 권한 부여 금지 | `클라이언트 신원 확인 불가`; 미검증 ID를 검증된 제품명으로 표시하지 않음 |
| Chrome 정상 allowlist/origin 또는 VS Code publisher.name과 사용자 등록 키 확인, 개별 확장 종단 증명 미확인 | `USER_ENROLLED_KEY`로 분류. 등록·서명·Core 신원·보호된 Desktop UI·종단 기밀성 및 요청별 승인 등 ADR-017 조건을 만족할 때만 해당 범위 요청 처리 | `사용자가 등록한 키`와 플랫폼 식별의 검증 수준을 따로 표시. 조건 미충족 시 해당 행위 보류 |
| 등록·플랫폼·Core 종단 신원과 메시지 무결성이 해당 경로에서 확인된 확장 | 등록된 최소 workspace 범위의 요청만 전달. 변경·실행·전송은 ARC-09의 별도 승인 및 집행 조건 필요; `approval:decide`는 부여하지 않음 | 검증된 증거 수준과 요청 workspace·권한을 표시. 철회·만료·불일치 시 새 명령 거부 |
| Content Script·웹페이지·Webview 메시지 | 해당 확장/Host에 대한 비신뢰 데이터 제안만 가능; Core 자격·승인·직접 실행 권한 없음 | 출처·선택 내용·데이터 전송 범위를 표시하고 문서 변경 시 stale 처리 |

Chrome의 allowlist와 caller origin은 정상 Chrome 경로에서의 식별 근거이고, OS에서 Host를 직접 실행할 때 그 문자열은 위조 가능하다. VS Code 공식 문서는 Extension Host가 VS Code와 같은 권한으로 실행된다고 설명한다. 따라서 어느 경로도 플랫폼 ID 문자열을 개별 확장의 Core 종단 신원으로 자동 승격하지 않는다. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [VS Code Extension runtime security](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security)

이 표는 안전한 요청 처리의 설계 조건이며, 사용자 목표인 Desktop·VS Code·Chrome 지원을 폐기하지 않는다. 현재 각 플랫폼에서 이 조건을 충족하는 실제 신원·키 보호·UI 수단과 운영 지원 여부는 별도로 검증해야 한다. 제품의 표시 문구·권한 집행 및 공격 대조는 NOT RUN이다.

#### Core 신원 결부 판정의 입력과 책임

Core의 ARC-11 Authenticator는 신뢰 수준을 `USER_ENROLLED_KEY` 또는 `PLATFORM_BOUND`로 구별한다. 공통 입력은 등록된 client/key의 PoP, 현재 등록·범위, Core 신원과 메시지 무결성이다. `PLATFORM_BOUND`는 추가로 OS/플랫폼이 확인한 확장 식별과 동일 연결·키의 결부 증거를 요구한다. `USER_ENROLLED_KEY`는 사용자 확인 등록 transcript, 등록키 증명과 신뢰 Desktop UI를 요구하며 플랫폼 발신 증명을 주장하지 않는다. 각 검증 결과는 출처·종류·정책 버전·범위·생성/만료·검증 주체·연결 참조를 포함한다. 클라이언트 payload의 자체 서술이나 Host가 임의로 만든 `verified=true`는 증거가 아니다.

인증자는 각 수준의 필수 증거가 유효하고 동일 등록·workspace·키에 결부된 경우에만 해당 수준을 반환한다. `USER_ENROLLED_KEY`를 `PLATFORM_BOUND`나 개별 확장 무결성 증명으로 승격하지 않는다. 누락·만료·검증 주체 불명·서로 다른 키면 거부하며 실패 세부 정보는 승인된 감사에만 기록한다. ARC-09는 이 수준과 등록 범위·현재 정책·Desktop의 행위별 승인 및 실제 권한 강제 가능성의 교집합을 인가한다. nonce·서명·정책/등록 상태는 소비·요청 기록과 경합하지 않도록 앞 절의 트랜잭션을 따른다. 판단 결과와 표시 가능한 신뢰 수준은 클라이언트가 아닌 Core가 반환한다.

현재 Chrome의 caller origin과 VS Code publisher.name에서 Core가 독립 검증할 동일 연결·키 결부 증거를 얻는 공식 수단은 확인되지 않았다. 공식적으로 제공되지 않는 증명 객체를 가정해 `PLATFORM_BOUND`로 만들지 않는다. 대신 사용자가 채택한 ADR-017의 `USER_ENROLLED_KEY` 경로는 등록·신뢰 UI·요청별 승인·기밀성 및 집행 조건을 모두 만족할 때만 허용한다. 신뢰 UI 확인은 플랫폼 증명으로 승격되지 않는다. 실제 플랫폼별 배포·검증 시험은 미완료다.

## 재연결·요청 인가

Core와 클라이언트가 각각 상대의 신뢰된 transport 신원/등록 Core ID를 확인하고, 역할·프로토콜 버전·양측 nonce·Core ID·clientId·keyId·연결 ID·만료를 포함한 domain-separated challenge를 교환한다. 클라이언트는 비밀이 아니라 서명을 보내고 Core는 등록 공개키로 검증한다. Core 측 신원은 검증된 transport와 등록된 Core 신원에 근거한다. 연결 ID를 단순 메시지로 교환하는 것 자체를 암호학적 채널 바인딩이라 부르지 않는다. OS가 검증한 연결 객체에 인증 상태를 결부하고 중계·재연결 시험을 통과해야 한다. Core의 재생 방지 저장소가 clientId·keyId·등록 및 검증된 연결 범위에 묶인 nonce의 발급·소비 상태를 원자적으로 기록한다. 같은 nonce의 동시 요청은 하나만 성공하고, 만료·중복·다른 연결·재시작 후 상태 불명은 거부한다.

매 명령은 등록 활성 상태, 클라이언트/연결 결부, workspace, operation, 정책 버전, requestId, expectedRevision과 입력 digest를 Core에서 검증한다. 권한은 허용 capability ∩ 클라이언트 범위 ∩ workspace 범위 ∩ 현재 ARC-09 정책 ∩ 필요한 사용자 승인으로 계산한다. 위험 행위의 승인은 신뢰 UI만 수행하고 작업·시도·행위·대상·계획 digest·만료를 결부한다. 저장소 갱신 및 감사 실패 시 부작용을 시작하지 않는다. 외부 CLI 및 파일과 DB는 단일 트랜잭션이 아니므로 ARC-09/06의 재검증·Unknown 규칙을 따른다.

### 서명 중계 및 명령 변조 경계

연결 수립 시의 단회 서명은 그 이후 모든 명령의 내용 무결성을 자동으로 보장하지 않는다. Core와 클라이언트 사이의 각 구간은 인증된 상대와 메시지 무결성을 제공해야 하며, Chrome/VS Code의 Host를 거치는 경우 Host가 인증을 종료하는지, 확장까지 종단 간에 보호되는지 명시적으로 구분한다. Host가 임의 challenge에 대한 서명을 확장에 요청할 수 있다면, nonce와 연결 객체를 확인해도 실시간 중계를 일반적으로 배제할 수 없다. ADR-017은 relay 자체의 탐지·차단을 보장하지 않는 사용자 등록키 신뢰 모델을 채택한다. 그 대신 요청 변조 방지·Core 신원·신뢰 Desktop의 범위별 승인 및 민감 데이터의 종단 기밀성 등 해당 행위의 필수 조건을 확인할 수 없으면 그 행위를 지원하지 않는다.

각 위험 명령의 승인 digest는 operation·workspace·대상·기대 revision·입력과 만료를 명확한 버전의 정규화 규칙으로 결부한다. 동일 표현의 중복 키·미지원 필드·정규화 불일치는 거부한다. 승인 UI가 표시한 의미와 Core가 실행하는 의미가 같아야 하며 transport의 무결성 검증, 현재 정책·등록 상태 확인 및 필요 승인 재검사를 대체하지 않는다. 서명 또는 digest가 포함됐다는 이유만으로 최초 사용자 확인이나 악성 클라이언트 방어를 주장하지 않는다.

[RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html)는 OAuth DPoP의 소유 증명과 재생 위험을 다루며 본 로컬 프로토콜의 구현 규격은 아니다. [RFC 9266](https://www.rfc-editor.org/rfc/rfc9266.html)의 TLS exporter는 특정 TLS 연결을 위한 channel binding으로, XPC나 Native Messaging의 임의 연결 ID가 동등한 기능을 제공한다는 근거가 아니다. 선택 transport별 종단 신원과 무결성의 실제 검증은 NOT RUN이다.

### 위험 요청의 종단 서명 및 Noise 채널 결합 계약

다음은 Host가 신뢰할 수 없는 중계자일 때 도청·변조를 방지하는 **확정 설계 기준**이며 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md) (`Noise_IK_25519_ChaChaPoly_SHA256`)와 RFC 8785 JCS + SHA-256 정규화 위에서 동작한다. 서명과 암호화 채널 자체는 신뢰된 Core 발견, 확장의 무결성 또는 실시간 relay 방지의 대체물이 아니며 Desktop의 요청별 승인과 함께 적용한다.

1. 확장은 신뢰된 등록 절차로 확인한 Core 서명 공개키, Core Noise static X25519 공개키와 `coreId`를 고정한다. Core 키 교체·유실 또는 등록의 진위 불명은 자동 수락하지 않고 신뢰 UI를 통한 재등록으로 보류한다.
2. 등록 후 모든 확장↔Core 통신은 [Noise IK 종단 보안 채널](EXTENSION_SECURE_CHANNEL.md) 안에서 수행한다(0-RTT 금지, prologue에 `protocolMajor`, suite, `coreId`, `clientId`, `enrollmentGeneration`, 역할 바인딩). Core가 채널 내부에서 발급한 단회 challenge에는 `coreId`·등록 `clientId`/`keyId`·예측 불가능한 nonce·용도·만료와 현재 세션 범위를 포함하고 JCS 정규화 후 Core가 서명해 확장에 전달한다. 확장은 고정된 Core 서명 공개키와 용도·대상을 검증한다. Host가 가짜 Core challenge를 대체하면 Noise handshake 및 Core 서명 검증 단계에서 거부한다.
3. 승인 전 제안 단계에서 확장은 버전·용도, Core/client/key ID, 새 challenge, workspace, 행위·대상·기대 revision과 전체 계획의 JCS SHA-256 digest를 포함해 설치 서명키로 서명한다. 이 digest에는 아직 발급되지 않은 `approvalRef`와 인증 nonce를 넣지 않는다. Core는 서명과 입력을 검증해 사용자에게 대상·권한·부작용을 표시하고 ARC-09가 그 계획과 필요한 작업/시도에 결부된 승인을 발급한다. ARC-06 실행은 승인 없이 `prepare`한 attempt에 대해 승인을 받은 뒤 `start`하는 기존 C04 순서를 따른다. 제안 및 prepare는 외부 프로세스 생성이나 Provider 전송을 하지 않는다.
4. 최종 실행은 별도 용도와 **새 단회 challenge**를 사용한다. 확장이 Core/client/key ID, workspace, operation, `requestId`, 기대 revision, 정책/발급된 승인 참조(`approvalRef`)와 전체 실행 입력 JCS digest를 서명한다. 서명자는 임의 Host가 제공한 raw bytes의 서명 API를 노출하지 않고 허용 메시지 종류·필수 필드·출처·현재 UI 상태를 검사한다. Core는 Noise 채널 인증 상태·등록 서명키·수신 payload에서 재계산한 JCS digest·현재 정책·revision과 승인 범위·철회를 확인한다. 이 출처 검사가 확장 침해나 공유 Host를 막는다는 보장은 없으므로 Desktop 신뢰 UI의 요청별 승인 없이는 실행하지 않는다.
5. Core는 최종 challenge의 nonce 소비, 해당 승인 소비와 상태/감사·요청 결과를 ARC-10의 같은 트랜잭션에서 처리한다. 저장/감사 실패나 내용 불일치는 실행 금지다. 외부 효과는 DB 트랜잭션과 원자적이지 않으며 기동 결과가 불명이면 Unknown으로 유지한다.
6. 응답이 유실된 후에는 이미 소비한 서명을 재사용하지 않는다. 새 challenge로 현재 주체를 인증하고 해당 결과의 현재 읽기 권한을 확인한 뒤 같은 범위의 `requestId`를 조회한다. 동일한 논리 입력의 기존 결과가 있으면 당시 사용한 승인이 소비·만료됐거나 현재 revision이 바뀌었더라도 **새 부작용 없이 결과만** 반환한다. 승인의 철회와 결과 읽기 권한의 철회는 별도로 판정하며 읽기 권한이 없으면 결과를 노출하지 않는다. 기존 요청이 없을 때만 현재 revision 및 승인 유효·미소비를 확인하고 nonce·승인 소비와 요청 생성/상태·감사를 직렬화한다. nonce·연결 식별자·서명·인증 시각은 멱등 입력 비교에서 제외하되 기대 revision·계획 및 승인 참조 등 행위의 의미를 바꾸는 필드는 포함한다. 입력이 달라지면 `CONFLICT`, 요청 결과가 만료되면 `IDEMPOTENCY_EXPIRED`, 외부 시작 여부가 불명이면 `Unknown`이다. 동시 동일 `requestId`는 하나만 최초 요청으로 기록되고 외부 시작도 한 번을 초과하지 않아야 한다.
   기존 결과 반환 분기에서도 새 challenge nonce는 유효·미소비 상태를 원자적으로 확인하고 **결과를 내보내기 전에 소비**한다. 같은 증명의 동시 재생은 하나만 성공한다. nonce 소비의 커밋이 실패하거나 결과가 불명이면 응답을 공개하지 않고, 클라이언트는 또 다른 challenge로 재인증한다. 이 nonce 소비는 기존 실행 승인이나 부작용을 다시 소비·실행하지 않는다. 최초 요청과 재조회가 경합하면 직렬화된 요청 정본을 기준으로 결과 또는 진행 중/Unknown을 반환한다.
7. Host는 유효 요청을 실시간 전달하거나 전달을 중단·지연할 수 있다. 민감한 읽기 응답과 오류는 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md)의 Noise IK 암호화, 4 KiB 버킷 패딩 및 범주형 외부 오류 매핑으로 보호한다. 정당 확장이 침해되거나 서명 대리로 악용되는 경우와 신뢰 UI 위장은 Desktop의 요청별 승인·최소 권한으로 제한하며, 신뢰 UI 또는 채널/키 저장 보호가 확인되지 않으면 해당 위험 경로를 차단한다.

검증은 정상 요청 외에 signed digest와 payload 불일치, 다른 Core·workspace·operation 대체, nonce 동시 재사용, 0-RTT 삽입, 서명 전 raw 요청 위조, 실시간 relay, 응답 도청·변조 및 신뢰 UI 위장을 포함한다. 논리 채널·키 결부 계약은 [계약 시제품 테스트](contracts/test_extension_secure_channel.py)와 [nonce 재시도 실험](contracts/test_nonce_retry_experiment.py)으로 검증하며, 실제 OS·플랫폼 제품 시험은 **NOT RUN**이다. [RFC 9421](https://www.rfc-editor.org/rfc/rfc9421.html)은 HTTP 메시지 서명의 구성요소 범위·본문 digest 검증·재생 위험을 설명하는 참고 자료이며 이 로컬 프로토콜의 wire 규격은 아니다. [RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html)는 클라이언트 실행 환경의 악성 코드가 비추출 키를 간접 사용할 수 있음을 설명한다.

제안 challenge도 검증 후 단회 소비하고 동일 제안의 중복 표시·승인 생성을 막는 제안 ID(`proposalId` = RFC 8785 JCS 정규화 제안의 SHA-256 또는 Core 발급 단회 UUIDv7)를 기록한다. 승인 대기 중 제안 challenge가 만료돼도 이미 검증·기록된 제안의 유효기간과는 별개이며, 실행에는 반드시 새로운 challenge와 현재 유효한 승인이 필요하다. 제안 상태의 저장·감사 실패나 중복 처리 상태 불명은 사용자에게 승인 성공으로 표시하지 않는다. 제안 단회성과 실행 분리 상태 전이의 실제 제품 구현 시험은 NOT RUN이다.

## 만료·철회·교체·복구

- 등록·승인·세션 만료는 별개이며 구체 유효기간은 정책 미정. 만료된 등록은 재등록 또는 사용자 확인을 거친 갱신만 허용한다.
- 사용자 철회는 등록 상태와 정책 버전을 원자적으로 변경·감사하고 기존 세션을 종료하며 새 명령을 거부한다. 실행 중 작업은 취소를 요청하고 실제 중단을 확인하기 전 완료로 표시하지 않는다.
- 키 교체는 기존 등록을 먼저 철회하고 기존 세션 및 권한을 회수한 뒤, 새 키를 생성·사용자 확인·재등록한다. 구 키 철회 이후 등록 실패·중단 시 둘 다 활성화하지 않으며 새 키로의 자동 롤백이나 자동 승인은 금지한다. 구 키의 진행 중 명령은 철회 이후 Core의 권한 재검사를 통과하지 못하며 이미 실행된 외부 작업은 취소 요청 후 실제 종료를 확인한다. 구/신 키 동시 활성은 허용하지 않는다. 손상 의심 시 구 키 서명만으로 권한을 이전하지 않는다.
- Extension 제거·브라우저 프로필 삭제·SecretStorage 소실·앱 재설치 후 키가 없거나 달라지면 기존 등록을 복구한 것으로 간주하지 않는다. 새 키와 사용자 확인으로 재등록하고 남은 구 등록을 철회한다. Core 재설치·Core 키/서명 변경도 자동 신뢰하지 않고 원인을 표시하고 재확인한다. 백업 복제나 Settings Sync로 같은 개인키를 여러 설치에서 사용하는 것은 지원하지 않는다.
- `KEY_UNAVAILABLE`은 `UNAVAILABLE`의 세부 유형으로 호출자에게 키 잠김·소실 등 적절한 복구가 필요함을 표시한다. `AUTH_FAILED`는 내부 감사에서 원인을 구분하고 외부에는 `DENIED`의 세부 유형 또는 존재 여부를 감춘 동등 응답으로 매핑한다. `DENIED`/`APPROVAL_REQUIRED`/`CONFLICT`/`UNAVAILABLE`을 구분하되 비밀을 오류에 넣지 않는다. 키 보관 실패에 평문 fallback하지 않고, 인증 실패시 재등록을 자동 승인하거나 무한 재시도하지 않는다. 시간 불명·감사 실패·등록 유실은 fail closed다.

## 공격 대조와 판정

| 사례 | 기대 동작 | 현재 |
|---|---|---|
| 각 플랫폼의 정상 신규 키·등록·재연결 | 정확한 플랫폼 식별과 사용자 확인 후 해당 공개키 서명만 허용 | NOT RUN |
| 허용되지 않은 Chrome ID·Host 직접 실행 origin 위조 | Chrome은 비허용 확장을 거부; 직접 실행 위조는 키만이 아닌 기동/연결 신뢰 및 인가 시험으로 거부 | NOT RUN; 직접 기동 결부 UNKNOWN |
| 다른 VS Code 확장의 공유 Host·SecretStorage 접근/서명 대리 | 공식 식별과 별도 Core 권한이 우회되지 않아야 함; 격리 미증명 시 기능 지원 보류 | NOT RUN; 공유 Host 경계 UNKNOWN |
| 공개키 대체·가짜 UI/Core·연결 중 relay | 최초 확인·양방향 신원 및 검증된 종단 결부 불일치 거부; 실시간 서명 대리/Host 중계가 차단되는지는 별도 검증 | NOT RUN |
| 정상 challenge를 악성 Host가 실시간 전달하거나 승인된 명령을 변경 | 검증된 종단 보호·명령 digest/승인 결부로 거부; 제공할 수 없는 경계는 위험 기능 차단 | NOT RUN |
| nonce 중복/동시 요청·범위/revision 변경·철회 경합 | 단회 사용과 최신 정책 집행, 부작용 중복 없음 | NOT RUN |
| 결과 응답 유실 후 새 challenge로 재조회, 같은 새 proof 동시 재생 | 현재 읽기 권한이 있을 때 기존 결과만 반환; 동일 proof는 최대 한 번만 허용, 시작 추가 0. nonce 저장 실패 시 결과 미노출 | NOT RUN |
| 키 분실·백업 복제·업데이트·잠금·약한 저장 backend | 자동 권한 복구/평문 fallback 거부, 재등록·보류 안내 | NOT RUN |
| 구 키 철회 후 새 키 등록 중 중단·실패 또는 구/신 키 동시 요청 | 구 키 거부, 미등록 신 키 거부, 자동 롤백·동시 활성 0; 사용자 확인 뒤 새 키만 활성 | NOT RUN |

**G3 설계 기준은 PASS**(ADR-017 설치별 키 + Desktop XPC 양방향 peer 검증·요청별 승인 + Noise IK 종단 보안 채널 + 실패 시 차단 계약 확정)이며, **실제 제품 구현 및 OS·브라우저·IDE 런타임 보안 시험은 NOT RUN**이다. 기존 UID/파일 권한 실험과 아래의 격리된 키 복제·서명 실험은 제품의 실제 OS 런타임 검증을 대체하지 않는다.

공식 근거: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Chrome 확장 저장소](https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies), [Chrome Worker 생명주기](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle), [VS Code 저장소 및 SecretStorage](https://code.visualstudio.com/api/extension-capabilities/common-capabilities), [VS Code Remote와 secrets](https://code.visualstudio.com/api/advanced-topics/remote-extensions), [Microsoft VS Code 비밀 저장 구현](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/secrets/electron-browser/secretStorageService.ts), [Apple Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave). 확인일 2026-11-16. GitHub main 구현은 변경될 수 있으며 특정 배포 버전의 증거가 아니다.

## 2026-11-16 공식 근거 및 격리 대조 추가

W3C [Web Cryptography 권고안](https://www.w3.org/TR/webcrypto-1/)은 `CryptoKey`의 structured clone 및 IndexedDB 사용 모델을 설명한다. [Web Cryptography Level 2 초안](https://www.w3.org/TR/2025/WD-WebCryptoAPI-20250422/)은 비추출 키도 `postMessage` 등으로 다른 보안 경계에 공유될 수 있으며 공유된 키의 사용을 원본이 사후 철회할 수 없다고 경고한다. 따라서 Chrome 후보는 키 바이트 비노출만 검사해서는 안 된다. extension-origin 페이지 간 키 객체의 전달 및 서명 요청을 금지하고, 침해 시 Core에서 해당 등록 공개키를 철회한다. `extractable=false`가 메시지 전달 자체를 차단한다거나 하드웨어 격리를 증명한다고 주장하지 않는다. 서비스 워커와 패널 등은 같은 확장 origin의 저장소를 공유하므로 W3C의 위협과 함께 확인해야 한다.

임시 Node.js v25.9.0 메모리 실험에서 P-256 비추출 개인 `CryptoKey`를 `structuredClone`한 결과 복사본도 `extractable=false`, PKCS#8 export 거부였지만 복사본으로 만든 서명은 원래 공개키 검증을 통과했다. 별도 키 파일·브라우저·인증정보는 사용하지 않았다. **Node 객체 복제만 시험**했으며 Chrome origin 간 전달·IndexedDB·OS 보호·Oches 제품은 NOT RUN이다. 기존 `verify-key-possession-boundaries.py` 재실행에서도 정당 키 서명 검증, 타 키/변조 거부와 동일 서명의 재검증 및 같은 사용자 `0600` 파일 키 사용을 재현했다. 이는 비추출/서명 검증만으로 사용 제한·재생 방지가 되지 않는다는 부정 대조이지 제품 재생 방지 PASS가 아니다.

### 후속 증거 요구

- Chrome: 격리된 테스트 프로필과 테스트 Extension 둘을 대상으로 정상 allowlist/미허용 ID, caller origin, native host 직접 실행, 비추출 키의 IndexedDB 재시작 복구·프로필 격리·복제 및 비신뢰 메시지에 의한 서명 대리를 확인한다. 사용자의 설치·설정을 변경하지 않는 별도 시험에서 실행한다.
- VS Code: 격리된 테스트 프로필에서 정상/다른 확장·공유 Host, SecretStorage의 성공/실패·원격 접속에서 실제 secret 접근 경로 및 다른 확장의 서명 대리 가능성을 시험한다. 제품 문서에서 소유 증명이 확장 무결성이나 단독 Host 격리를 의미한다고 적지 않는다.
- Desktop: 실제 Developer ID 서명 양성, 타 팀/ad-hoc 음성, 양방향 XPC peer·가짜 Core·키 접근·등록 UI 위장을 검증한다. 사용자 Keychain과 실제 인증을 변경하는 실험은 수행하지 않았다.
- 공통: 발급·소비 DB가 원자적임을 실험하고 재생·동시 요청·크래시·등록 철회/정책 변경 경합·연결 교체 및 키 교체 이후 구 키 거부를 확인한다. nonce 확인과 외부 파일/CLI 부작용을 하나의 원자 트랜잭션으로 단정하지 않는다. 증거에는 테스트 빌드/OS/버전, 기대와 실제, 양성·음성 대조, 로그의 비밀 제거, NOT RUN 사유를 남긴다.

위는 제품 실행 검증 계획이지 현재 실행 완료된 제품 시험 결과가 아니다. 악성 동일 사용자와 공유 Extension Host 방어는 제공 플랫폼과 배포 구성의 실효성이 확인될 때만 범위를 주장하며, 설계 기준(G3 설계 게이트: PASS)과 별도로 **실제 OS·제품 실행 시험은 NOT RUN**으로 유지한다.
