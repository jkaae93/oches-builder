# 플랫폼별 Capability 및 권한 매트릭스

상태: 상위 설계 가설, 2026-11-16. **가능**은 공식 플랫폼 API로 가능한 일반 기능이며 본 제품의 구현·배포 검증을 의미하지 않는다. **제한**은 조건부 또는 권한·설치 의존, **미검증**은 제품 연동 여부 미확정이다. 모든 기능은 Core의 클라이언트별 인증·권한 및 사용자 승인에 종속된다.

| 기능 | Desktop Flutter | VS Code Extension | Chrome MV3 | 권한·조건 |
|---|---|---|---|---|
| 설계·구성 편집 | 가능 목표, 구현 미검증 | 가능 목표, Webview/Host 경계 검증 | 가능 목표, Side Panel 가용 버전 검증 | 최소 표시 및 변경 승인 |
| Workspace 분석 | 제한: OS 접근 승인 | 제한: Workspace API·Trust, URI 및 원격 위치 | 제한: 웹페이지 자료만 직접 취급; 로컬 폴더는 Core 승인 필요 | 파일 접근 범위·신뢰와 민감정보 제외 |
| 웹페이지 컨텍스트 | 미검증 | 미검증 | 제한: 사용자 선택한 탭/허용 범위 | activeTab 또는 최소 host permission, Content Script; 사용자 확인과 전송 최소화 |
| CLI 탐지·공식 로그인 | 제한: Core 및 OS 권한 | 제한: Core가 실행되는 위치와 권한 | 제한: 브라우저 직접 실행 불가, Native Host/Core 필요 | 공식 Provider 인증, 토큰은 Extension에 전달 금지 |
| 작업 실행·취소 | 제한: 승인과 Capability | 제한: Workspace Trust, Core 위치·승인 | 제한: Native Host/Core 연결과 명시적 승인 | 클라이언트·workspace·행위·대상별 정책, 미확인 기능 차단 |
| 상태·로그 | 제한: Core/기록 권한 | 제한: Core 연결 및 원격 호스트 구분 | 제한: Core 연결, Worker 재시작 후 재조회 | 민감정보 최소화, 이벤트 누락 표시 |
| 기억·평가 | 제한: Core 권한 및 데이터 가용성 | 제한: workspace·연결 권한 | 제한: 명시적으로 허용된 범위 | 근거·출처, 사용자 데이터 전송 승인 |
| Desktop 없이 사용 | 해당 없음 | 미검증: 별도 Core 설치/수명주기 필요 | 미검증: 별도 Native Host/Core 설치 필요 | 배포·업데이트·프로세스 관리 검증 |
| 원격 SSH/WSL/컨테이너 | 미검증 | 제한: Extension Host 위치에 따라 파일·프로세스 환경이 달라짐 | 미검증: 로컬 브라우저와 원격 workspace는 별개 | 원격 경계, 데이터 이동, 신뢰 및 명시적 대상 선택 |

## 클라이언트 권한 모델
Core가 인증된 클라이언트별 정체성, workspace와 실행 위치, 허용 행위·대상·기간, 사용자 승인 및 Provider Capability를 함께 평가한다. 인증은 권한이 아니며 Desktop에도 무제한 접근을 자동 부여하지 않는다. 웹페이지의 텍스트·이벤트는 비신뢰 입력이고 사용자의 명시적 선택과 Core 정책 없이 실행 요청을 생성·승인할 수 없다. VS Code Webview 역시 Extension Host 메시지를 검증해야 하는 비신뢰 UI 경계다. 구체 자격증명·발급·폐기는 ARC-11~13의 제안 계약을 따르며 OS별 집행 가능성은 미검증이다.

## 공식 근거와 한계
- [VS Code Remote Extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions): Workspace Extension은 원격 Extension Host에서, Webview는 클라이언트에서 실행될 수 있다. 위치에 따른 파일·프로세스 차이는 제품 실험 필요.
- [Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust): 신뢰되지 않은 workspace의 기능 제한은 Extension이 집행해야 하며 UI 숨김만으로 충분하지 않다.
- [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging): Native Host 설치 및 허용된 Extension origin 등 플랫폼 연결 규칙을 제공한다. 이는 Core의 사용자 권한을 대체하지 않는다.
- [Chrome Side Panel](https://developer.chrome.com/docs/extensions/reference/api/sidePanel) 및 [Service Worker 수명주기](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle): UI와 비영구 백그라운드 환경을 설명한다. 지속 연결·복구는 제품 검증 필요.
- [Chrome 권한](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions), [Web Store 사용자 데이터 정책](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq): 권한·데이터 처리 조건은 배포 전 최신 정책과 실제 사용에 맞춰 검토한다.

## 후속 근거 매트릭스

Provider별 공식 기능과 Oches의 검증 여부를 구분하고 버전·계정 변경의 stale 규칙을 [지원 범위와 증거 매트릭스 v1](COMPATIBILITY_EVIDENCE_V1.md)에 정리했다. 매트릭스는 공식 문서의 일반 기능을 제품 지원으로 승격하지 않는다.
