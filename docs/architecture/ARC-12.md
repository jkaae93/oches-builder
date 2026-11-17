# ARC-12 VS Code Extension Architecture

상태: 상세 설계 제안 v0.1 · 2026-11-16. 구현 및 플랫폼 검증 전이다.

## 책임과 경계
Extension Host는 VS Code 명령·Workspace Trust와 URI를 다루고 Webview는 표시와 사용자 입력만 다룬다. 공통 정책·정본은 ARC-11 Core, 실행은 ARC-06, 승인 판단은 ARC-09 소유다. Webview에는 Core credential이나 Provider 자격증명을 주지 않는다. 메시지는 Host가 sender·schema·크기·상태를 확인하고 임의 명령, 경로, HTML 실행을 거부한다. Webview에는 CSP, 제한된 자원과 nonce를 적용하고 프로젝트 텍스트를 명령이 아닌 데이터로 렌더링한다.

## 위치·권한·실패
초기 검증 후보는 Desktop VS Code의 로컬 workspace와 동일 호스트 Core다. `workspace.isTrusted`가 false이면 프로젝트 분석·설정 적용·실행·전송을 거부하고 읽기 가능한 안내만 표시한다. Trust 자체는 Core 인증이나 실행 sandbox가 아니다. workspace URI·실행 위치·Core ID를 UI와 요청에 표시하고 Core 등록 workspace와 일치시킨다. SSH/WSL/Container, VS Code Web 및 로컬↔원격 Core 연결은 지원 미검증으로 비활성한다. 원격 extension host의 Node 프로세스는 원격에서 실행될 수 있으므로 로컬 파일 경로와 CLI 위치를 추정하지 않는다.

Host는 ARC-11의 version negotiation, 권한·승인·requestId와 expectedRevision을 사용한다. 연결 손실 시 실행 상태를 추측하지 않고 재인증·cursor 복구 또는 snapshot 조회한다. UI 재시작은 재실행을 야기하지 않는다. 지원 대상의 URI 정규화, 링크 경계와 저장 충돌은 ARC-02/04 및 Core가 재검증한다.

## 검증 기준
제한 모드에서 분석·실행 요청 0건, 악성 Webview 메시지 거부, workspace 교체·Trust 철회 후 권한 재검사, 인증키 미노출, cursor 만료 시 snapshot 복구, 원격 환경에서 미지원 안내를 확인한다. VS Code 버전별 검증·사용자 승인 전 제품 지원 미확정. 공식 근거: [Workspace Trust API](https://code.visualstudio.com/api/extension-guides/workspace-trust), [Remote Extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions).

## 확장 식별과 Core 연결

VS Code 공식 `publisher.name`은 설치·관리 식별자로 사용한다. Workspace Trust는 workspace 위험 제어에 적용하고 명령 직접 호출 시에도 검사한다. 공유 Extension Host의 OS 신원은 개별 확장의 신원을 자동 증명하지 않으므로 Core에 대한 결부는 별도 검증한다. 정상 흐름과 원격 경계는 [확장 신원 경계](EXTENSION_IDENTITY_BOUNDARIES.md)를 따른다.

VS Code 공식 문서는 Extension Host가 VS Code와 같은 권한으로 파일·네트워크·프로세스에 접근할 수 있다고 설명한다. 따라서 `publisher.name` 또는 Host의 프로세스 신원만으로 다른 확장이 서명 요청·명령을 중계하지 못한다고 가정하지 않는다. 로컬·원격 Host와 Core 사이의 각 구간을 구분하고, 개별 주체의 신원 및 무결성을 확인하지 못하는 구간에서는 위험 기능을 보류한다. [VS Code Extension runtime security](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security)

## 설치별 인증키

설치별 키의 SecretStorage 후보와 이 저장소가 제공하지 않는 프로세스 격리·비추출 보장, 원격 client-side 저장 범위는 [설치별 인증 설계](CLIENT_INSTALLATION_AUTH_DESIGN.md)를 따른다. `publisher.name`과 Workspace Trust만으로 Core 인가를 대신하지 않는다.
