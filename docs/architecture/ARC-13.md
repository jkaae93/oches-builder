# ARC-13 Chrome Extension Architecture

상태: 상세 설계 제안 v0.1 · 2026-11-16. 구현, Web Store 심사 및 플랫폼 지원은 미검증이다.

## 경계와 데이터 흐름
사용자가 선택한 페이지의 콘텐츠는 비신뢰다. Content Script → Service Worker → Native Messaging Host → ARC-11 Core 방향으로 제한된 데이터 제안만 전달한다. Side Panel은 선택 내용·출처·전송 범위를 표시한다. 페이지는 Core, Provider, 승인 API에 직접 접근할 수 없고 페이지 텍스트를 명령·승인으로 해석하지 않는다. 호스트 manifest의 extension ID allowlist는 Chrome 접속 제한이지 Host/Core 상호 인증이 아니다. ARC-11 등록과 인증을 별도로 만족해야 한다. localhost 연결은 미지원이다.

페이지 수집은 사용자 명시 동작 및 최소 권한을 전제로 하고 범위·출처·시간을 표시한다. 민감 정보 자동 탐지는 완전하지 않다. 외부 Provider 전송은 별도 정책 평가와 사용자 승인 후에만 가능하다. Content Script가 보낸 문서·프레임·탭 정보와 메시지 스키마·크기를 Worker에서 확인하고 출처를 위조할 수 있는 페이지 입력은 불신한다. Host는 정해진 operation만 허용하며 쉘 문자열이나 페이지 제공 실행 파일 경로를 실행하지 않는다.

## 계약과 복구
Chrome Native Messaging은 JSON UTF-8에 32비트 native-endian 길이 프레임을 사용한다. 공식 제한은 Host→Chrome 메시지 1 MB, Chrome→Host 64 MiB이며 제품은 더 작은 제한을 두고 넘는 입력을 거부한다. 구체 상한은 W1·P7(256 KiB)로 확정([설계 확정 기록](DESIGN_FINALIZATION.md)). Worker 종료나 port 단절은 실행 종료가 아니다. 재연결 시 ARC-11 재인증과 cursor/snapshot을 사용한다. 메시지 중복은 requestId 계약에 따르며 승인과 외부 실행을 자동 반복하지 않는다. 권한 철회·탭 이동·문서 변경 시 선택 내용을 stale로 표시하고 다시 선택한다.

## 검증 기준
허용되지 않은 extension 및 위조 메시지 거부, 웹페이지의 직접 실행·승인 0건, 프레임 크기·잘못된 JSON 거부, 수집·전송 승인 분리, Worker 종료 및 cursor 만료 복구, Native Host 교체·키 도용에 대한 ARC-11 게이트를 시험한다. Chrome 버전·OS·설치·스토어 정책은 별도 확인 전 미지원이다. 공식 근거: [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Message passing security](https://developer.chrome.com/docs/extensions/develop/concepts/messaging).

## Native Messaging 호출자 식별

Chrome은 정상 Native Messaging 요청에 manifest `allowed_origins`를 적용하고 호출 Extension origin을 Host 첫 인자로 전달한다. Host는 이를 정확히 검사하며 플랫폼 경계의 식별·접근 제한으로 사용한다. 직접 실행한 Host의 인자는 위조 가능하므로 Chrome 기동 여부 및 Core와의 연결은 별도 검증한다. 정상 흐름과 부정 대조는 [확장 신원 경계](EXTENSION_IDENTITY_BOUNDARIES.md)를 따른다.

Content Script는 Native Messaging API를 직접 호출할 수 없고 Worker를 거친다. Worker는 Chrome이 제공한 `sender.origin` 또는 `sender.url`, tab/frame 및 문서 식별자를 확인하고 메시지 스키마·크기·허용 동작을 제한한다. 페이지가 payload에 기입한 origin·탭 ID·승인 여부는 신뢰하지 않는다. 선택을 승인한 뒤 탭 이동·문서 교체 또는 식별 불명 시 이전 내용을 stale로 취급하고 재선택한다. Chrome은 Content Script가 신뢰하지 않는 페이지와 renderer를 공유할 수 있으므로 sender 검사와 payload 검증을 권고한다. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

`connectNative`의 port 단절은 해당 연결 인증 상태를 폐기하고, 새 port에서는 재인증한다. `sendNativeMessage`는 메시지마다 새 Host 프로세스를 기동하고 첫 응답 외 메시지를 버리므로 지속 세션의 연결 상태나 전체 이벤트 전달에 사용하지 않는다. 두 방식의 종료는 ARC-06 작업 종료를 의미하지 않는다. 이 동작은 플랫폼 명세에 근거한 설계이며 제품의 실제 종단 인증은 NOT RUN이다.

## 설치별 인증키

Chrome 프로필별 키를 Service Worker Web Crypto와 IndexedDB로 보관하는 후보를 검증한다. 정상 Native Messaging origin 확인, 키 소유 증명, Core 인가는 별개이며 상세·제한은 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)를 따른다. 비추출 속성은 악성 확장 코드의 서명 대리를 막는다는 보장이 아니다.

## 설계 동결 · 2026-11-17

P2·P7 확정. 스토어 심사·런타임 보안 실증은 제품게이트. 정본은 [설계 확정 기록 §6](DESIGN_FINALIZATION.md).
