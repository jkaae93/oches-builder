# Chrome·VS Code 확장 식별과 Core 인가 경계

2026-11-16 · **설계 결정 기준** (실제 배포·OS 실행 시험 **NOT RUN**). [ARC-11](ARC-11.md), [ARC-12](ARC-12.md), [ARC-13](ARC-13.md), [G3 macOS 설계](ARC-11-G3-MACOS-DESIGN.md), [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md) 및 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)와 함께 확장–Core 경계 계약을 구성한다. 플랫폼이 제공하는 식별·접근 제한을 정상 보안 기능으로 사용하되, 별도 프로세스와 Core까지 보장이 전이된다고 가정하지 않는다.

## Chrome 정상 흐름과 별도 경계

1. 사용자가 설치한 Oches Extension의 Service Worker가 `nativeMessaging` 권한으로 `runtime.connectNative`를 호출한다. Chrome은 설치된 Native Host manifest의 `allowed_origins`와 호출 Extension origin을 대조한다. 허용 목록은 정확한 `chrome-extension://<id>/`만 사용하고 와일드카드를 넣지 않는다. Chrome은 허용된 호출자 origin을 Host의 첫 인자로 전달하고 Host와 stdio로 프레임을 교환한다. **Chrome이 정상 실행한 경로에서 이는 플랫폼이 제공하는 접근 제한과 호출 Extension 식별**이다. Host는 첫 인자를 정확히 비교하고 허용 목록 외 값·누락·잘못된 형식을 거부한다. 이 값은 메시지 본문에서 재정의하지 않는다.
2. Side Panel의 사용자 동작과 Content Script 자료는 구별한다. Worker는 Chrome이 제공한 sender의 확장 ID, tab/frame/document 정보 및 현재 상태, 메시지 유형·크기·스키마를 확인한다. 페이지가 제공한 문자열을 sender로 인정하지 않는다. Content Script 입력은 데이터이며 임의 실행, 권한 부여 또는 사용자 승인으로 변환하지 않는다. 외부 메시지 수신은 기본 비활성화하고 필요한 경우만 `externally_connectable` 및 외부 sender ID/origin을 별도 허용한다. 개인 데이터 및 페이지 내용은 최소 범위로 사용한다.
3. Host는 정해진 명령과 프레임만 처리하고 OS가 검증한 Core 연결을 연다. Core는 등록 범위·workspace·revision·요청 ID·정책을 검증하고 위험한 작업은 신뢰 UI의 별도 승인을 요구한다. 허용된 Extension 식별, 사용자 의도, Host 프로세스 신원, Core 인가는 서로 다른 확인이다. Provider 토큰을 전달하지 않는다.
4. 직접 Host 실행 시 임의 프로세스는 origin 인자와 stdin을 스스로 지정할 수 있다. 따라서 **첫 인자는 Chrome이 제공한 정상 실행이라는 전제 아래 식별 근거이며, 인자 문자열만으로 그 전제를 증명하지 않는다**. Host→Core XPC 서명 검증은 Host 바이너리를 검증할 뿐 Chrome 기동 및 개별 Extension을 자동 입증하지 않는다. 사용자가 채택한 ADR-017에서는 이를 플랫폼 증명이라고 표시하지 않고 사용자 등록키·신뢰 UI의 요청별 승인 및 데이터 보호 조건을 적용한다. 제품 배포 지원은 해당 조건의 검증 전 보류한다.

## VS Code 정상 흐름과 별도 경계

VS Code Extension의 manifest `publisher`와 `name`으로 구성된 `publisher.name`은 공식 설치·조회·관리 식별자다. Marketplace publisher 검증과 사용자의 설치 출처 확인은 공급자 판단에 도움이 되며, 별도의 OS 프로세스 단위 서명이나 개별 메시지의 암호학적 발신자 증명은 아니다. Extension 실행은 VS Code Extension Host에서 이뤄지고 로컬 Node, 원격 Node, 웹 Host가 존재한다. 다른 확장과 Host를 공유할 수 있으므로 Host PID/서명만으로 Oches Extension의 요청을 증명하지 않는다.

1. 사용자는 확인한 publisher.name의 확장을 설치·실행한다. 확장은 공식 `workspace.isTrusted`와 workspace URI를 확인한다. Restricted Mode에서는 위험한 명령을 숨기는 것만으로 충분하지 않으므로 호출 시점에도 차단한다. Webview 입력은 스키마·상태·크기·허용 명령을 검증하고 workspace 내용은 비신뢰 데이터로 취급한다.
2. 정당한 확장은 Core에 기능/등록 요청을 하고, Core는 식별자·설치 출처 확인 결과와 OS/Host 실행 위치를 구별해 기록한다. 허용 권한은 workspace와 행위별로 제한하고 위험 요청은 신뢰 UI 승인과 ARC-11 정책을 거친다. `publisher.name` 문자열이나 Workspace Trust만으로 Core가 원격 호출자의 확장 신원을 독립적으로 검증했다고 표기하지 않는다.
3. 로컬과 SSH/WSL/Dev Container의 Host·workspace·Core 위치를 각각 표시한다. 원격 연결은 명시적 등록 및 별도 신뢰 경계와 전송 검증이 필요하다. 검증 전 원격 실행은 미지원이며 로컬 경로·인증을 원격으로 자동 전달하지 않는다.

## 오류와 검증 계획

허용되지 않은 Chrome ID는 Chrome 접근 거부, Host의 origin 누락·불일치 및 이상 프레임은 연결 중단, sender/schema 오류는 요청 거부한다. VS Code Restricted Mode에서는 명령 직접 호출도 거부한다. Core의 권한 부족은 `DENIED`, 사용자 확인 필요는 `APPROVAL_REQUIRED`, 버전 충돌은 `CONFLICT`, 신원 결부 미검증은 `UNKNOWN`/지원 보류로 구분한다. 취소·연결 유실은 작업 종료를 의미하지 않는다.

| 시험 | 기대 결과 | 현재 상태 |
|---|---|---|
| 허용 Chrome 확장 및 미허용 확장 | 정상 Native Port 연결·정확한 origin 전달 / Chrome에서 미허용 거부 | NOT RUN |
| 웹페이지·Content Script 위조, 외부 메시지 | sender 및 문서 확인, 데이터만 전달; 실행·승인 거부 | NOT RUN |
| Host 직접 실행·origin 위조·Host 교체 | Core 등록/고위험 작업 거부 또는 입증된 사용자 승인 경로만 허용 | NOT RUN; 기동 결부 UNKNOWN |
| VS Code 설치된 publisher.name, 다른 확장, 공유 Host | 올바른 설치 식별과 인가; 다른 확장의 위조 및 무단 중계 거부 | NOT RUN; 프로세스 단위 결부 UNKNOWN |
| Restricted Mode의 직접 명령 호출과 Trust 변경 | 표시 여부와 무관하게 위험 행위 거부 및 권한 재검사 | NOT RUN |
| 로컬·SSH·WSL·Container | 실행 위치별 명시, 승인되지 않은 원격 Core 연결 거부 | NOT RUN |

공식 근거: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) (allowlist·첫 인자), [Chrome Message Passing](https://developer.chrome.com/docs/extensions/develop/concepts/messaging) (sender 및 외부 통신), [VS Code Publishing Extensions](https://code.visualstudio.com/api/working-with-extensions/publishing-extension), [Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host), [Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust). Microsoft의 [공식 GitHub 문서](https://github.com/microsoft/vscode-docs/blob/main/api/advanced-topics/extension-host.md)는 로컬/원격/웹 Host 구분을 설명한다. 확인일 2026-11-16. 기능 문서의 보장과 이 문서의 제품 보안 제안·미실험 항목을 구분한다.

## 신원 결부의 선택지와 제품 효과

| 선택지 | 확인 가능한 주체 | 제품 효과·제약 | 설계 상태 |
|---|---|---|---|
| A. 플랫폼별 검증 가능한 발신 증거 | OS/플랫폼이 제공하고 Core가 동일 연결·키에 검증할 수 있는 개별 확장 | 기존 ARC-11 인증과 최소 권한 적용. 증거 형식·발급자·수명·실패와 Host 중계를 다루는 구체 API가 필수 | Chrome Native Messaging과 VS Code 공식 문서에서 해당 종단 증거를 아직 찾지 못함; UNKNOWN |
| B. 설치별 키 + Desktop 사용자 확인 | 등록된 키 보유 및 신뢰 UI에서 승인한 요청 범위 | 사용자가 확장을 선택·등록하고 변경/실행을 Desktop에서 승인한다. Core는 신원을 `사용자가 등록한 키`로 표시하며 개별 확장 증명이라고 부르지 않는다. 중계는 남고 요청 변조·재생과 무관한 범위 변경은 서명·승인 결부로 거부한다 | 사용자가 [ADR-017](adr/ADR-017-user-enrolled-client-key.md) 설계 기준을 채택. 실제 플랫폼 지원은 별도 검증 |
| C. 결부 불명 시 차단 | 확인할 수 없는 주체 | 비밀·민감 읽기·등록·변경·실행 금지; 사용자는 신뢰 UI에서 이유와 가능한 복구 경로를 본다 | 현재 문서의 실패 정책. 이것만으로 확장 기능 제공 목표 완료를 주장하지 않음 |

B는 완전한 확장 무결성이나 악성 동일 사용자에 대한 방어가 아니라, 신뢰 주체를 **사용자 확인 설치키로 변경하는 제품 선택**이다. 사용자가 이 모델과 Desktop 요청별 승인을 채택했으며 ADR-016 D03의 해당 조건을 ADR-017로 변경했다. 안전 분석에는 등록된 키 오용, 정당 요청 실시간 중계, Desktop 승인 UI 위장 및 승인 피로를 포함해야 한다. 플랫폼별 실제 지원과 공식 보증의 추가 확인은 별개다.

B의 등록·호출·데이터 범위·종단 채널(`Noise_IK_25519_ChaChaPoly_SHA256`)·신뢰 가정의 확정 계약은 [ADR-017](adr/ADR-017-user-enrolled-client-key.md)과 [종단 보안 채널 설계](EXTENSION_SECURE_CHANNEL.md)를 따른다. 설계 계약은 확정되었으며 실제 플랫폼별 배포 및 런타임 시험은 **NOT RUN**이다.
