# 최초 OS·CLI 수직 흐름: MVP 기준선 및 비용 계약

상태: **설계 결정 기준** · 확인일 2026-11-16 (실제 Provider 호출 및 제품 시험 **NOT RUN**). 제품 구현, 로그인, 인증 변경, 모델 호출 또는 실제 Provider 연동 시험은 수행하지 않았다. 지원 상태는 공식 문서, 이 기기의 `--version`/`--help` 관찰, Oches 제품 시험을 분리한다. 모든 사용자 계정·세션·자격증명의 실제 상태는 조회하거나 기록하지 않았다.

## 관찰한 환경과 후보

이 기기는 macOS 26.4 (25E246), arm64다. `claude --version`은 2.1.296, `codex --version`은 codex-cli 0.155.1을 반환했다. 두 실행 파일 경로가 존재하고 `file`에서 arm64 Mach-O로 관찰됐다. 이는 설치·명령행 도움말의 관찰이며 공급자 서명·설치 출처·인증·유료 이용 가능성·프로젝트 신뢰·실제 실행 기능의 검증이 아니다.

| 후보 | 공식 문서와 로컬 도움말에서 확인한 진입점 | 주요 제약·불확실성 | Oches 지원 판정 |
|---|---|---|---|
| macOS + Claude Code 2.1.296 | [프로그램 실행 문서](https://code.claude.com/docs/en/headless)는 비대화형 모드의 JSON 및 stream-json, 세션 메타데이터를 설명. 로컬 `--help`는 `-p`, `--output-format`, `--resume`, `--permission-prompts`를 표시 | 로컬 도움말은 비대화형·stdout 비TTY에서 workspace trust 대화상자를 건너뛰며 검증 실패 설정이 조용히 무시될 수 있다고 명시. 종료 코드 0도 백그라운드 작업 완료 보장이 아니다. Oches의 신뢰 판단·설정 유효성·실제 승인 집행 별도 검증 필요 | UNKNOWN |
| macOS + Codex CLI 0.155.1 | [비대화형 문서](https://learn.chatgpt.com/docs/non-interactive-mode)는 `codex exec --json` 이벤트와 세션 resume을 설명. 로컬 `codex exec --help`에도 JSONL·resume·sandbox 옵션이 표시 | 로컬 도움말의 `--trust`는 설정을 지속시킬 수 있고 `--ephemeral`과도 별개다. 신뢰 변경 옵션을 자동 사용하지 않는다. 실제 이벤트·취소·재개·계정 격리는 미시험 | UNKNOWN |
| Windows/Linux + 양 CLI | 플랫폼 공식 지원 범위·의존성은 각 Provider 최신 문서 및 선택한 버전에서 다시 확인 | 현재 대상 OS가 없어 설치·실행·보안·복구 미시험 | UNKNOWN |

### MVP 수직 흐름 기준 아키텍처

- **Phase 1 MVP 기준선:** **macOS arm64 + Flutter Desktop + Shared Local Core** (양방향 XPC `xpc_connection_set_peer_team_identity_requirement` + Keychain/Secure Enclave) + **SQLite (`WAL` + `synchronous=FULL` + Tier 1 `LOCAL_KEYCHAIN_SEALED_ANCHOR` + 서명된 `DurableIntent`)** + **제어된 Mock Adapter(`C`) 및 Claude Code CLI (`claude -p --output-format stream-json`) 1차 Adapter**.
- **대조 및 Phase 2 확장:** **Codex CLI (`codex exec --json`)**를 2차 비교 Adapter로 검증하며, **Chrome MV3 Extension(Native Messaging)** 및 **VS Code Extension**은 [ADR-017](adr/ADR-017-user-enrolled-client-key.md) 설치별 키 + [Noise IK 종단 보안 채널](EXTENSION_SECURE_CHANNEL.md) (`Noise_IK_25519_ChaChaPoly_SHA256`) + Desktop 요청별 승인 계약 위에서 Phase 2 클라이언트로 통합한다. Windows/Linux 및 원격 VS Code Host는 별도 OS·원격 검증 완료 전 지원 대상에 포함하지 않는다.
- 이 선정은 두 도구의 보안·품질·비용 우월성 주장이 아니라, 로컬 설치·공식 machine-readable 출력·취소/중단 검증 순서의 확정 기준이다. 정책 검증 또는 안전한 실행 게이트가 충족되지 않으면 해당 실행을 차단하고 대조 경로(`C` 또는 `B`)의 실패 증거를 기록한다.

## 비대화형 신뢰 경계

`claude -p`는 trust 대화상자를 생략할 수 있으므로 Oches는 CLI의 대화상자에 신뢰 검사를 위임하지 않는다. 인가된 workspace·정규화된 경로·사용자가 확인한 입력·안전한 설정 출처를 제품이 먼저 검증하고, 설정 무시·권한 집행 여부를 확인할 수 없으면 위험 작업을 차단한다. `codex exec --trust`처럼 신뢰를 영구 저장하거나 승인/샌드박스를 우회하는 옵션은 자동 사용하지 않는다. 로그의 명령과 환경 변수는 비밀정보를 제외한다. 이러한 제품 측 게이트는 설계 요구사항이지 구현 검증된 통제가 아니다.

CLI의 `--resume`, JSONL, 권한 플래그 및 상태 출력이 실제 계정·버전에서 정상 동작하고 중단·복구가 안전한지는 각각 미검증이다. 문서의 JSON 이벤트나 금액 필드가 모든 인증 방식과 모든 실패 시나리오에서 제공된다고 가정하지 않는다. 특히 이벤트 스트림 단절, 출력 파싱 오류, 백그라운드 작업 및 종료 코드와 실제 작업 완료는 별도로 판정한다.

## 수직 흐름 검증 순서와 중단 조건

각 단계에서 OS·CLI 경로/버전·공식 문서 확인일·계정 **유형**·제품/Adapter 버전·정책·승인 범위·증거를 기록하되 토큰, 쿠키, 원본 사용자 데이터는 기록하지 않는다. 금전 지출·외부 데이터 전송이 발생하기 전 사용자 확인을 받고, 인증 변경이 필요하면 명시적 승인을 먼저 받는다.

| 단계 | 사전 조건과 관찰 | 통과 조건 / 중단 조건 |
|---|---|---|
| 0. 제품 선행 게이트 | 최초 OS/CLI 선택, 공식 연동 정책, ARC-11 앱 신원·키 보호, Core/Adapter 구현 및 테스트 환경 준비 | 하나라도 미확인·실패면 NOT RUN/BLOCKED. CLI가 설치됐다는 사실만으로 진행하지 않음 |
| 1. 프로젝트 분석 | 격리된 비밀 없는 fixture, 승인된 경로와 데이터 범위 | 허가 범위 밖 읽기·전송 0건. 신뢰·설정 유효성 확인 불가면 차단 |
| 2. 추천·구성 | 단일 Agent 기준선, 현재 Capability snapshot, 변경 diff | 모든 추천에 근거·대안; unknown 필수 기능 차단. 구성 및 실행 승인은 별개 |
| 3. 시작·관찰 | 명시적 실행 승인, 시간/시도 상한, ARC-10 시도 기록 후 ARC-06 호출 | 이벤트 및 종료를 기록. 0 exit만으로 결과 검증·백그라운드 종료·작업 성공을 가정하지 않음 |
| 4. 취소·중단·재개 | 시험 전 취소·재개 지원을 공식 경로와 실제 버전에서 확인 | 취소 요청과 확인 구분; 상태 불명은 Unknown·Blocked, 자동 재시작 금지. 재개는 지원과 승인 확인 후 새 시도로 연결 |
| 5. 복구·평가 | 의도적 연결 손실/저장 실패는 별도 격리 환경에서 수행 | 상태/이벤트 일관성, 유실 표시, 중복 요청 차단과 평가 근거 확인. 제품 구현이 없으면 NOT RUN |

현재 0~5는 **NOT RUN**이다. 로컬 도움말·SQLite 라이브러리 단위 실험은 제품의 수직 흐름, 실제 공식 인증, OS 신원 확인, 사용자 승인 집행, 장애 복구를 증명하지 않는다.

## 비용·시간·사용량 측정 계약

작업·시도 단위로 `attemptId`, 시작/종료 시각, wall-clock 경과, Provider/도구·버전, 모델(확인된 경우), 인증/과금 유형(사용자 확인된 범위), 입력·출력·캐시 토큰(공식 필드가 있으면), 금액·통화·측정 출처·산출 시각·가격표 버전, 데이터 수집 여부와 실패/취소 상태를 ARC-09/10 정본 계약으로 기록한다. API 키나 토큰 자체는 기록하지 않는다.

1. 비용·사용량 측정 상태는 **`AUTHORITATIVE_BILLING`**(권위 있는 청구액), **`PROVIDER_REPORTED_ESTIMATE`**(Provider가 출력한 추정값), **`RATE_TABLE_ESTIMATE`**(공식 사용량과 검증 요율표로 계산한 추정값), **`SUBSCRIPTION_INCLUDED`**(구독 포함 사용량 — 증분 청구 0으로 자동 단정 금지), **`UNKNOWN`**(미제공·파싱 실패·통화 불명; 0으로 대체 금지) 다섯 가지 정규 상태로 구분해 저장하고 UI에 출처와 기간을 표시한다.
2. Claude의 [비용 안내](https://code.claude.com/docs/en/costs)는 세션 비용을 추정치로 설명하며, Pro/Max/Ultra의 포함 사용량에는 세션 금액이 청구액으로 적합하지 않다고 구분한다. [Codex 인증 안내](https://learn.chatgpt.com/docs/auth)는 API 키 인증의 API 과금과 ChatGPT 플랜 포함 사용량을 구분한다. 계정별 실제 가용 데이터는 실행 전 미검증이다.
3. 요율에 의한 계산(`RATE_TABLE_ESTIMATE`)은 **공식 제공 사용량과 해당 계약·모델·시점의 요율이 모두 확인된 경우에만** 한다. 단위와 캐시 입력 중복을 먼저 확인하고, 해당될 때 `미캐시 입력 × 입력 단가 + 캐시 입력 × 캐시 단가 + 출력 × 출력 단가 + 별도 도구 비용`으로 계산한다. 환율·계약 할인·세금·캐시 쓰기/도구 비용 등 누락 요소가 있으면 추정 불완전으로 표시한다. 실제 청구액(`AUTHORITATIVE_BILLING`)으로 단정하지 않는다.
4. 로컬 도움말의 Claude `--max-budget-usd`는 API 호출의 금액 제한으로 표기돼 있다. 이를 구독 전체 금액의 강제 상한이나 다른 Provider에 공통으로 보장하지 않는다. 비용 상한 집행이 확인되지 않으면 실행 시간·시도 횟수의 별도 상한과 사용자 확인을 적용하고, 필요한 통제가 실제로 강제되지 않으면 해당 실행을 막는다(fail-closed budget gate).
5. 비교 실험은 동일 fixture·모델·권한·시도 횟수·도구·자원 한도로 단일 Agent 기준선과 후보를 비교한다. wall-clock, 성공·실패·미실행·판정 불가와 사용량 가용 비율을 모두 분모와 함께 기록한다. 예약 없이 미수집 항목을 제외한 평균으로 실패를 가리지 않는다. 운영 비용·지연·성공률의 합격 임계치는 데이터와 사용자 승인 전 미정이다.

## 잔여 위험과 확인 근거

- [Claude Code 인증](https://code.claude.com/docs/en/authentication)과 [Codex 인증](https://learn.chatgpt.com/docs/auth)은 공식 로그인 경로를 설명한다. 외부 GUI의 연동 권리, 서로 다른 계정의 격리 및 공급자 정책은 별도 검증이다.
- [Claude 프로그램 실행](https://code.claude.com/docs/en/headless)은 JSON/stream-json과 결과 메타데이터를 설명하고, 비대화형 백그라운드 명령의 종료 코드만으로 완료를 추정할 수 없는 예를 든다. 버전별 검증 필요.
- [Codex 비대화형 모드](https://learn.chatgpt.com/docs/non-interactive-mode)는 JSONL 이벤트 예와 resume을 제시한다. 이벤트에 포함되지 않은 데이터·금액을 역추정해 채우지 않는다.
- 앱 신원·키 보호, CLI 버전별 공식 이벤트, 취소·재개, 사용자 승인 집행, 산출물·데이터 전송, 장애 복구 및 실제 비용의 **제품 실행 시험**은 모두 **NOT RUN**이다. 설계 평가 점수와 Gate 판정은 [설계 평가 기준 정정 및 독립 재채점](REVIEW_DESIGN_CRITERIA_CORRECTED.md)에서 제품 시험 결과와 분리해 관리한다.

<a id="비교-가능한-구현검증-계획-및-비용-불확실성-v02"></a>
## 비교 가능한 구현·검증 계획 및 비용 가정 v0.3

다음 숫자는 견적이나 약속이 아니라 **1명 전일 작업일 기준의 설계 범위별 계획 가정**이다. 코드가 없는 현재 설계 기준이며 종단 보안 채널·최신성 기준점·확장 경계를 모두 반영해 Phase 1 MVP와 Phase 2 확장을 분리한다. 실제 일정·청구액·사용량을 관측한 증거는 아니며, 각 단계는 선행 게이트를 충족하지 못하면 후속 실행을 진행하지 않는다.

| 단계 / 작업 묶음 | 낮음 / 기준 / 높음 인일 | 선행 게이트 및 범위·불확실성 |
|---|---:|---|
| Phase 1-A. macOS 신뢰 경계(XPC·Keychain·승인 UI) | 8 / 15 / 30 | 양방향 `xpc_connection_set_peer_team_identity_requirement`, Keychain/Secure Enclave, Desktop 승인 UI, 철회/재생 대조. 배포 서명·Team ID 실증 전 위험 기능 차단 |
| Phase 1-B. SQLite 저장·`FreshnessAnchor`·복구 격리 | 12 / 22 / 38 | SQLite `WAL` + `synchronous=FULL`, 30일 멱등+tombstone, Tier 1 `LOCAL_KEYCHAIN_SEALED_ANCHOR` + 서명된 `DurableIntent` `RecoveryLedger` + `RECOVERY_QUARANTINED`, 장애/중단 주입 |
| Phase 1-C. 제어 Mock(`C`) + 1차 Claude(`A`) / 2차 Codex(`B`) Adapter | 10 / 20 / 38 | `C`로 선행 상태·취소·장애 검증 후, `A`(Claude `stream-json`) 및 `B`(Codex `exec --json`) 공식 연동·취소·비용 상태 수집 구현 |
| Phase 1-D. 추천·정의·템플릿·평가·Desktop UX 수직 흐름 | 16 / 30 / 50 | 단일 기준선·템플릿 검증·명시적 승인·고정 과제(`real-tasks-v0.3`) 비교 평가·독립 관측 수집 |
| **Phase 1 MVP 합계 (macOS Desktop + Core + CLI A/B)** | **46 / 87 / 156 인일** | 순수 산술 합산이며 일정 확약 아님. 병렬 인력·외부 배포 심사·장애 재설계 기간 미포함 |
| Phase 2-A. 종단 보안 채널(`Noise_IK_25519_ChaChaPoly_SHA256`) + 설치키 | 8 / 14 / 24 | [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md) (`Noise_IK_25519_ChaChaPoly_SHA256`, 60 KiB 청크·4 KiB 패딩·0-RTT 차단·JCS transcript), 상호운용 test vector·철회/relay 대조 |
| Phase 2-B. Chrome MV3 Extension + Native Messaging Host | 6 / 12 / 22 | `allowed_origins`·caller origin 검증, WebCrypto 비추출 키 + IndexedDB, Service Worker 재시작·오류 매핑, Web Store 심사 제외 |
| Phase 2-C. VS Code Extension (로컬 Workspace Host) | 6 / 12 / 22 | `publisher.name`·`workspace.isTrusted`, `SecretStorage` (`safeStorage` 검증·`basic_text` 차단), Webview 경계. 원격 SSH/WSL/Container 및 Windows/Linux는 별도 범위 |
| **Phase 2 확장 합계 (Noise + Chrome + VS Code 로컬)** | **20 / 38 / 68 인일** | Phase 1-A/B 게이트 통과 후 착수. Tier 2 외부 CAS anchor(`EXTERNAL_OBJECT_CAS_ANCHOR`)·Windows/Linux·원격 Host는 별도 산정 |
| **전체 목표(Phase 1 + Phase 2) 합계** | **66 / 125 / 224 인일** | 위험 간 상관관계가 있으므로 상한 합산은 통계적 신뢰구간이 아님 |

위 계획은 종단 신원(`Noise IK` + `ADR-017`), 복구 최신성 기준점(`FreshnessAnchor` + `DurableIntent`), Primary/Secondary CLI Adapter(`A`/`B`/`C`) 및 Chrome·VS Code 로컬 확장의 전체 설계 범위를 빠짐없이 포함한다. Windows/Linux OS 포팅, 원격 VS Code Host, Tier 2 외부 CAS 운영은 별도 대상별 검증 범위로 구분한다. Phase 1 보안·저장·Adapter 계약이 성립하지 않으면 Phase 2 확장을 시작하지 않는다.

### 경로별 대안과 실패 시 조치

| 경로 | 재사용과 추가 비용 | 실패·제약 | 결과 |
|---|---|---|---|
| A. macOS + Claude 비대화형 | 설치·도움말·공식 machine-readable 형식 관찰; 검증용 Adapter와 신뢰·설정 검사가 필요 | trust 대화 생략, 설정 무시, 인증·승인 강제·실제 이벤트가 불명 | 사용자의 첫 실험 후보로 제안; 0~5의 어느 게이트라도 미충족이면 실행 중단 |
| B. macOS + Codex 비대화형 | 동일 Core 계약 재사용 목표; 별도 이벤트·승인·취소 Adapter와 정책 검증 필요 | 자동 `--trust` 사용 금지, 세션/계정·샌드박스·이벤트 불명 | A 실패 시 대조 후보로 시험. A/B를 기능상 동등하다고 간주하지 않음 |
| C. 제어된 가짜 Adapter | 별도 사용자 계정·외부 청구 없이 상태·취소·장애를 재현 가능 | 공식 CLI 로그인·권한·비용·지원 여부를 입증하지 못함 | 제품 통합 개발의 선행 시험에 사용. A/B 수직 흐름 통과 증거가 될 수 없음 |

계획의 순서: 우선 위 신뢰 경계와 C로 실패 경로를 검증하고, 별도로 공식 연동 정책·선택 계정의 조건을 확인한 다음에만 A 또는 B로 진행한다. A/B의 이벤트·상태 해석이 불가능하거나 필수 권한을 집행할 수 없으면 다른 경로를 자동 채택하지 않고 설계와 테스트 결과를 갱신한다.

### 운영 비용에 대한 계산 예와 중단 게이트

고정 실험 조건의 작업 수를 `N`, 평균 미캐시 입력·캐시 입력·출력 토큰을 각각 `I`, `C`, `O`, 확인된 공식 단가를 각각 `rI`, `rC`, `rO`라고 하면 예상 API 비용은 `N × (I×rI + C×rC + O×rO) + 확인된 별도 도구 비용`이다. `I`, `C`, `O`의 단위와 중복 포함 여부 및 단가의 단위(예: 백만 토큰당)를 맞춰야 한다. 특정 계정의 포함 사용량·할인·세금·요율·통화 중 하나라도 없으면 해당 구성 요소와 총액은 **unknown**이다. 구독의 작업별 증분 청구액은 제공 근거 없이는 위 계산으로 대체하지 않는다.

예를 들어 `N=100`, 각 작업의 **미캐시 입력** 20,000·캐시 입력 5,000·출력 2,000 토큰은 **부하 가정**일 뿐 실측이 아니다. 미캐시와 캐시가 서로 배타적이라는 전제에서 총량은 각각 2,000,000·500,000·200,000 토큰이며, 실제 금액은 대상 계정의 공식 요율을 확인하기 전 산출하지 않는다. 사용량과 금액은 기준선·후보 각각의 실패·취소·판정 불가를 포함하여 수집하며 제공되지 않은 회차의 비율도 보고한다. 가격표가 바뀌면 금액을 원래 요율·시각과 분리해 기록한다.

### 비용 집계의 불변 조건

- Provider 원본의 입력 토큰이 캐시 입력을 포함하는지 adapter가 해당 버전의 공식 의미를 확인한다. 포함한다면 `미캐시 입력 = 전체 입력 - 캐시 입력`이며, 캐시 입력이 전체보다 크거나 의미가 불명하면 계산을 거부한다. 별도로 제공된 미캐시·캐시 수치를 다시 빼지 않는다.
- 추정치에는 단가 유형, 통화, 모델, 적용 시각, 수집 범위, 캐시 쓰기·도구·세금 등의 누락 항목과 계산식 버전을 함께 둔다. 통화가 다른 금액은 출처·환율·기준 시각을 확인하기 전 합산하지 않는다. 집계에 미제공 회차가 있으면 알려진 금액과 미제공 건수만 표시하고 총액을 확정하지 않는다.
- 동일 attempt의 중복 이벤트는 Provider가 보장하는 식별자와 범위가 확인될 때만 제거한다. 누적 사용량과 증분 사용량의 의미가 불명하면 둘을 합산하지 않고 unknown으로 남긴다. 취소 뒤 지연 청구나 정정은 별도의 근거와 개정 시각으로 반영하며 과거 추정값을 청구액으로 덮어쓰지 않는다.
- 같은 API 가격표에도 처리 방식·모델·지역에 따라 다른 요율이 존재할 수 있다. 예시의 토큰량만으로 특정 요율을 선택하지 않는다. [OpenAI 공식 API 가격](https://developers.openai.com/api/docs/pricing) 및 [API 크레딧과 ChatGPT 사용 한도 구분](https://developers.openai.com/api/docs/guides/chatgpt-api-credits)은 계정별 실제 청구액의 증거가 아니다.
- 수용 사례: 총 입력에 캐시 포함/별도 제공, 불가능한 음수, 단가 누락, 서로 다른 통화, 실패한 attempt의 미수집 사용량, 누적 이벤트 중복, 사후 정정을 각각 주입한다. 정확한 금액이나 unknown 및 출처가 표시되어야 한다. **제품 시험 NOT RUN**이다.
- 구독 계정도 포함 사용량 이후 유료 usage credits를 사용할 수 있으므로 `subscription`을 곧바로 `증분 비용 0`으로 해석하지 않는다. Claude Code의 공식 안내는 플랜·조직·인증 방식에 따라 사용량과 크레딧 지출 경로가 다르다고 설명한다. 다만 계정별 설정과 개별 attempt의 청구액을 이 문서만으로 알 수 없으므로, 확인된 청구 근거가 없으면 금액은 unknown으로 유지한다. [Claude Code 비용 안내](https://code.claude.com/docs/en/costs)

최초 외부 호출 전에는 공식 허용 경로, 전송할 합성 데이터, 작업당 상한, 비용 발생 방식과 중단 기준을 확인한다. 공식 도구가 비용 상한을 해당 계정에서 강제할 수 없다면 시간·횟수 제한만으로 금액 통제를 주장하지 않는다. 지출 예산을 강제하거나 확인할 수 없는 필수 조건은 BLOCKED로 남기고 외부 호출을 자동 시작하지 않는다. 단계별 실측 결과로 인일·토큰·실패율의 가정을 갱신하되, 추정값과 관측값을 별도 열로 보존한다.
