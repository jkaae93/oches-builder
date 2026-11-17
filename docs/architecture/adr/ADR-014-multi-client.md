# ADR-014: 멀티 클라이언트와 공유 로컬 Core

상태: 제안 · 2026-11-16 · 기준: ARC-00 v0.1, ADR-001~013. 기존 결정을 전면 교체하지 않는다. 검증과 사용자 승인 전이며 제품 지원을 보장하지 않는다.

## Context
Flutter Desktop 외에 VS Code와 Chrome을 공식 배포 대상으로 추가한다. 세 클라이언트의 수명주기, 권한, 파일·프로세스 접근은 다르다. VS Code Remote는 확장 실행 위치와 사용자 컴퓨터가 다를 수 있고, Chrome은 직접 로컬 CLI를 실행하지 않는다.

## Problem
도메인 로직과 실행 상태를 일관되게 제공하면서 각 클라이언트·웹 콘텐츠의 권한을 제한하고 Desktop 없이 Extension을 사용할 가능성을 검증해야 한다.

## Considered Alternatives
| 대안 | 장점 | 단점·운영 복잡도 | 보안 위험 | 상대 개발 비용 |
|---|---|---|---|---|
| Shared Local Core + Multiple Clients | 단일 상태·정책·Adapter, UI 독립 | 별도 Core 설치·수명주기·버전 호환 관리 | 로컬 API 노출, 클라이언트 인증·권한 분리 필요 | 중~높음: Core/API와 설치 필요 |
| Desktop Companion App | 기존 Flutter 패키징과 관리 흐름 재사용 | Extension 기능에 Desktop 설치·실행 의존, 백그라운드 UX 필요 | Companion API와 브라우저 연결 공격면 | 중간: 설치 단순화와 앱 결합 |
| Independent Extension Runtimes | 클라이언트별 독립, 단일 프로세스 간단 | 중복 로직·상태 충돌·인증/버전 분기; Chrome은 별도 native 구성 필수 | 독립 정책 편차 및 충돌 증가 | 높음: 플랫폼별 중복 구현·검증 |
| Hybrid | 공통 도메인/정책을 유지하고 배포·연결 방식을 플랫폼에 맞춤 | 프로세스 토폴로지·원격·업데이트 매트릭스 복잡 | 서로 다른 transport의 동일 정책 집행 검증 필요 | 높음: 공통 Core와 배포 변형 |

## Decision
**Hybrid: 공통 논리 Core + 플랫폼별 호스팅/연결**을 권장한다. Desktop은 Core를 함께 배포·관리하는 후보이고, VS Code는 Desktop UI 없이 별도 Core 설치 또는 Extension이 관리하는 Core에 연결하는 후보이며, Chrome은 설치된 Native Messaging Host를 통해 Core에 연결하는 후보이다. 하나의 Core가 반드시 항상 떠 있거나 Desktop과 별도 OS 프로세스여야 한다는 결정은 하지 않는다. Desktop 없는 사용은 목표이며 패키징·설치·업데이트 및 권한 검증 전 확정 기능이 아니다. 원격 VS Code는 로컬과 원격 실행 위치를 명시하고 초기 지원 범위를 정하지 않는다.

Chrome의 Native Messaging을 초기 검증 우선 경로로 선택한다. Host manifest의 `allowed_origins`는 Chrome 확장 ID를 제한하지만 호스트 파일·OS 사용자·내부 Core 연결의 무결성이나 사용자 권한을 단독으로 보증하지 않는다. Native Messaging Host와 Core 사이에도 인증·권한 검사를 둔다. localhost는 보조 대안이며 단순 Origin 검사, CORS, loopback 주소만으로 인증하지 않는다. 포트 선점, 악성 로컬 프로세스, CSRF/DNS rebinding, 확장 외 웹페이지 요청을 위협 모델에서 검증한다. 보안 성질을 충족하지 못하면 노출하지 않는다.

## Rationale
공통 도메인·상태·정책의 중복을 줄이면서 클라이언트별 제약과 설치 방식을 분리한다. 독립 Runtime들의 동기화 비용과 Desktop 강제 의존을 완화한다. Native Messaging은 Chrome의 명시적 설치·허용 목록 경로를 활용하되 추가 인증·승인을 대체하지 않는다.

## Trade-offs
Core 배포·버전 협상·인증과 다중 OS 패키징이 복잡해진다. Native Host 설치가 필요하며 MV3 Service Worker 종료에 대한 재연결·이벤트 복구가 필요하다. 원격 워크스페이스와 로컬 Chrome의 실행 위치 혼동을 사용자에게 명시해야 한다.

## Consequences
ARC-11은 Core API·인증/권한, ARC-12는 VS Code, ARC-13은 Chrome, ARC-14는 패키징·업데이트를 후속 상세 설계한다. ARC-01은 클라이언트 UX, ARC-06은 실행 및 세션을 유지한다. ARC-05/07/08/09/10과 계약을 교차 검토한다. 신규 상세 설계나 구현 착수를 뜻하지 않는다.

## Verification Requirements
공식 문서·정책을 버전별 확인하고 Desktop 없는 설치, Core 중복 시작·충돌·종료, 버전 불일치와 복구를 시험한다. Chrome의 허용되지 않은 확장/웹페이지·위조 메시지·Host 교체·localhost 오리진 및 포트 선점, 권한 회수와 Service Worker 재시작을 시험한다. VS Code의 Workspace Trust, 로컬·SSH·WSL·컨테이너 위치, SecretStorage 및 원격 파일 경계를 시험한다. 계정 토큰이 Extension 또는 웹페이지로 전달되지 않는지 검증한다.

## Unresolved
Core 언어·프로세스·IPC·배포·업데이트와 인증 메커니즘, Desktop/Extension 단독 설치 경험, 원격 Core 실행 및 데이터 이전, 최초 OS·CLI, 이벤트 재개와 최소 Chrome/VS Code 버전은 미정이다. 클라이언트 등록·폐기·키 회전은 후속 설계에서 결정한다.

## 후속 채택된 계약 기준 · ADR-016

사용자가 후속 [ADR-016](ADR-016-core-contract-baseline.md)의 D01~D08을 설계 기준으로 채택했다. ADR-014 원문의 역사적 제안과 별개로 공통 논리 API·Chrome 플랫폼 경로·macOS XPC 우선 검증 후보가 후속 기준이다. 이 부록은 ADR-014 전체의 소급 채택이나 OS/Provider 지원·구현 검증을 뜻하지 않는다.
