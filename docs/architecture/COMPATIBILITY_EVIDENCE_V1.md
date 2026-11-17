# Provider·플랫폼 지원 범위와 증거 매트릭스 v1

상태: 설계 검토용 조사 · 확인일 2026-11-16. 아래 `문서 확인`은 **공식 문서가 기술한 일반 기능**이지 Oches가 해당 기능을 안전하게 연동했다는 뜻이 아니다. 확인일의 문서는 장래의 모든 버전에 대한 보증이 아니다. 대상 계정의 이용 권리·공식 외부 GUI 연동 허용, 설치 출처, OS·CLI 버전별 동작은 확인된 별도 증거가 없다면 UNKNOWN이다. 로그인, 사용자 키체인 변경, 모델 호출 또는 제품 실행을 하지 않았다.

## 용어와 판정

1. `DOCUMENTED`: 해당 공식 문서에서 조건부 기능과 출처를 확인했다. 명시된 버전 범위가 없으면 버전 보장으로 확대하지 않는다.
2. `VERIFIED_IN_OCHES`: Oches의 고정 OS·CLI·Adapter·계정 유형과 설정에서 기대 및 부정 대조가 통과하고 재현 증거가 있어야 한다. **현재 사례 없음.**
3. `UNSUPPORTED`: 해당 버전의 공식 명세 또는 제품 정책으로 지원하지 않는 것이 확인된 경우다. 검증하지 못한 것은 UNKNOWN이지 UNSUPPORTED가 아니다.
4. `UNKNOWN`: 확인할 근거·해당 환경·실행 통제·승인 중 하나라도 없거나 근거가 만료됐다. 필수 Capability가 UNKNOWN이면 실행을 차단하며 추가 승인만으로 이를 supported로 바꾸지 않는다. 선택적 Capability는 상실 기능·대안을 표시하고 자동 전환하지 않는다.

로컬 후보 관찰값(설치·도움말만): macOS 26.4 arm64, Claude Code 2.1.296과 Codex CLI 0.155.1. 사용자 계정, 서명·배포 출처, 관리 정책이나 실제 작동은 조회하지 않았다. [기존 후보 기록](PROVIDER_MVP_FEASIBILITY.md).

## Provider × 기능 × 증거와 허용 결론

| Provider / 기능 | 공식 자료에서 확인한 범위 | Oches에서 확인하지 못한 사항과 안전한 결론 |
|---|---|---|
| Claude Code / 로그인 | [인증](https://code.claude.com/docs/en/authentication)은 개인·팀·Console·클라우드 방식 및 일부 다중 계정 설정을 설명한다. 설정 디렉터리를 분리해도 Console의 특정 로그인 종류는 분리되지 않는 예외를 명시한다. | 외부 GUI 이용 조건, 사용자 계정의 인증 상태, 전역 설정·동시 계정 및 세션별 격리 UNKNOWN. 계정 변경이나 로그인을 자동 수행하지 않는다. |
| Claude Code / 실행과 출력 | [프로그램 실행](https://code.claude.com/docs/en/headless)은 비대화형 CLI와 구조화·스트림 출력, 세션 메타데이터를 설명한다. | 설치된 버전·계정의 각 이벤트 의미·유실·백그라운드 작업과 Oches Adapter 파서는 UNKNOWN. JSON 출력 자체를 작업 성공 근거로 쓰지 않는다. |
| Claude Code / 중단 | 같은 공식 문서는 특정 비대화형 실행의 SIGTERM과 SIGINT가 서로 다른 종료 의미를 갖는다고 설명한다. | macOS/Windows/Linux의 신호·자식 트리·권한 정책 및 선택 버전에서 실제 동작 UNKNOWN. 취소 수락은 종료가 아니며 공식 문서만으로 Oches의 안전한 취소를 주장하지 않는다. |
| Codex CLI / 로그인 | [공식 인증](https://developers.openai.com/codex/auth/)은 ChatGPT와 API 키의 인증·과금 경로를 구분하고 CLI/확장의 로그인 캐시 공유를 설명한다. | 특정 계정·워크스페이스, 다른 동시 계정의 격리 및 외부 GUI 정책 UNKNOWN. 로그인과 로그아웃은 다른 공식 클라이언트에도 영향을 미칠 수 있으므로 자동 수행하지 않는다. |
| Codex CLI / 실행과 이벤트 | [비대화형](https://developers.openai.com/codex/noninteractive/)은 JSONL 이벤트, 출력 스키마, 인증·재개 예를 문서화한다. | 이벤트 완전성·버전별 스키마·취소·복구·정확히 한 번 실행 및 Oches Adapter UNKNOWN. 인증 파일을 추출하거나 재사용하지 않는다. |
| Antigravity / 인증 | [공식 인증 문서](https://antigravity.google/docs/install?tab=cli)는 CLI 인증과 환경별 경로를 설명한다. | 로컬 설치 여부, 현재 지원 버전·계정 격리·외부 GUI 연동·CLI 실행/이벤트/권한 UNKNOWN. 특정 계정·버전의 지원을 문서만으로 확정하지 않는다. |

Claude의 비대화형 trust 확인 생략 가능성과 Codex의 설정 변경 옵션 등 **로컬 버전에 국한된 도움말 관찰**은 [수직 흐름 검증안](PROVIDER_MVP_FEASIBILITY.md)을 따른다. Claude의 SIGTERM·SIGINT 결과는 공식 문서의 제품 일반 설명이며 현재 Oches/OS 조합의 실험 증거가 아니다. Provider가 제공하는 구독 포함 사용량·추정 비용·실제 청구액을 혼동하지 않고 출처가 없으면 unknown으로 기록한다.

## 클라이언트 × 경계 × 예외

| 경계 | 공식 자료의 범위 | Oches 결정·미검증 |
|---|---|---|
| Desktop ↔ Core | OS 소켓/프로세스 기술 자체가 앱 신원을 보증하지 않는다는 점은 [보안 시제품](ARC-11-TRUST-OPTIONS.md)에 별도로 기록 | ARC-11 인증·인가·live peer/키 보호 검증 전 변경·실행 미지원. Desktop이라는 이유로 무제한 권한 부여 금지 |
| VS Code local/remote | [Remote Extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions)는 local UI/remote workspace Host와 URI별 접근 차이를 설명한다. [Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust)는 제한 모드 API를 설명한다. | 초기 로컬 후보 외 SSH/WSL/Container/Web은 미검증으로 비활성화. trust UI 표시나 Host 위치만으로 Core 인증·파일 권한 확보를 가정하지 않는다. |
| Chrome MV3 ↔ Native Host | [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)은 등록 Host, extension ID allowlist, JSON framing과 방향별 크기 제한을 설명한다. Content Script는 직접 native API를 호출하지 못한다. | Host manifest·ID만으로 Core 또는 OS 프로세스 신원을 보증하지 않는다. Host 설치/무결성·사용자 권한·store 심사 미검증. |
| Chrome Worker 수명 | [Worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)은 Worker 종료 가능성과 버전별 차이를 설명한다. | 종료는 작업 취소가 아니며 ARC-11 재인증·cursor/snapshot으로 상태를 다시 얻는다. 최소 Chrome 버전 및 실제 재접속은 미검증. |

## 증거의 유효기간과 변경 영향

각 Capability 판정은 최소 `(Provider, 설치 식별자, CLI/Adapter 버전, OS/버전, 인증 유형, 문서 URL·확인일, 조건, 관찰 방법·증거, 상태)`를 식별한다. 정책이 versioned snapshot으로 유지되더라도 사용자 계정 유형·관리 정책·설치 경로·CLI/Adapter·OS 또는 관련 공식 문서가 바뀌면 대상 결과를 stale로 표시한다. 일반 문서 갱신 여부를 실시간으로 알 수 없으므로 출시 전과 실패 보고 시에도 문서를 재검토한다. 세션 ID·계정 ID·자격증명이나 민감 원문은 증거에 넣지 않는다.

## 구현 전 검토 가능한 수용 기준

| ID | 설정·변경 | 기대되는 문서 수준 판정 | 구현 시험 상태 |
|---|---|---|---|
| CP-01 | 문서에서 이벤트 출력만 확인, 실행/취소 미시험 | event 형식 DOCUMENTED; Oches event·cancel은 UNKNOWN | NOT RUN |
| CP-02 | 설치 CLI 또는 Adapter가 바뀜 | 기존 snapshot stale, 필수 실행 Capability를 새로 확인할 때까지 차단 | NOT RUN |
| CP-03 | 계정 디렉터리 분리만 확인, 로그인 유형의 예외 존재 | account isolation VERIFIED로 승격 금지 | NOT RUN |
| CP-04 | VS Code 원격 URI를 로컬 절대 경로로 변경 | location/authority 불일치로 분석·실행 차단; URI 경계를 재확인 | NOT RUN |
| CP-05 | Chrome Worker 종료 및 Host 연결 상실 | 실행 종료로 추정 금지, 재인증과 cursor 또는 snapshot 복구 | NOT RUN |
| CP-06 | 공식 도구의 기능 지원과 외부 GUI 이용 권한을 혼동 | 별도 약관·연동 검토가 없으면 제품 지원 UNKNOWN | NOT RUN |
| CP-07 | 구독 사용량 또는 과금 금액이 제공되지 않음 | 비용 0이 아니라 unknown; 가격으로 역산해 청구액이라 단정하지 않음 | NOT RUN |

이 문서의 출처는 제품 사용 허가·법률 자문이나 API 동작 시험이 아니다. 필수 기능이 미확인이면 G4는 미검증 명시 관점에서만 평가하며 G2/G3/G8의 실제 통합·안전·평가 검증을 통과시킨 것으로 해석하지 않는다.

Capability별 지원 조건·스냅샷 무효화·변환 손실·버전 마이그레이션과 CV01~18의 수용 기준은 [Capability 계약 v1](CAPABILITY_CONTRACT_V1.md)을 따른다. 제품 시험은 NOT RUN이다.
