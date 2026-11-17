# 상세 설계 로드맵

상태: 제안 · 기준: 대화로 제공된 ARC-00 v0.1 및 ARCHITECTURE_GOALS. 우선순위는 설계 착수 순서와 다르다. 양방향 협의는 상호 계약 검토이며 순환적인 완료 선행조건이 아니다.

| 순서 | 문서 | 우선순위 | 선행 입력과 검토 관계 |
|---|---|---|---|
| 1 | ARC-05 Provider & Account | P0 | ARC-00; ARC-06 실행 계약, ARC-10 저장 경계와 교차 검토 |
| 2 | ARC-06 Runtime & Session | P0 | ARC-05 capability·계정 참조; ARC-09 승인과 ARC-10 이력 경계 |
| 3 | ARC-10 Storage & Observability | P2 | ARC-05/06의 상태·이벤트 요구; 전체 모듈과 계약 검토 |
| 4 | ARC-02 Project Analyzer | P1 | ARC-00; ARC-10 저장 및 비밀파일 경계 |
| 5 | ARC-03 Architecture Decision Engine | P1 | ARC-02 Profile, ARC-05 capability; ARC-09 평가 기준 협의 |
| 6 | ARC-04 Agent Definition & Configuration | P1 | ARC-03 제안, ARC-05/06 기능과 실행 계약 |
| 7 | ARC-07 Orchestration & Task Scheduling | P1 | ARC-04 구성, ARC-06 실행 계약, ARC-10 상태; ARC-09 정책 협의 |
| 8 | ARC-09 Evaluation & Safety | P2 | ARC-03/06/07 경계; 안전 승인 요구는 앞선 설계에서도 검토 |
| 9 | ARC-08 Memory & Context | P2 | ARC-07 작업, ARC-10 원본 및 지식 저장 |
| 10 | ARC-01 GUI & UX | P2 | 위 계약과 사용자 흐름; 초기 UX 검토는 각 설계와 병행 |

ARC-10은 다른 모듈의 기반이므로 P2라도 요구와 경계를 일찍 검토한다. 우선순위 변경은 하지 않았다. 각 설계는 작성 후 In Review, 사용자 승인 및 완료 조건 충족 후 Done이다. 사용자 선택에 따라 기존 상태를 보존하고 In Review를 추가했다. Todo는 Ready 후보, In progress는 In Progress에 대응하며 Backlog와 Done은 그대로다.

사용자가 ARC-10까지 설계 진행을 요청하여 후속 설계를 진행한다. 완료 상태는 별도 사용자 승인 후 부여한다. ARC-05와 ARC-06의 상호 의존은 capability 및 계정 참조 계약을 ARC-05에서 초안으로 정의하고 실행 수명주기는 ARC-06에서 확정해 해소한다.

## 멀티 플랫폼 확장 순서 · 2026-11-16

이번 단계는 상위 계획만 다루며 ARC-11~14 상세 설계를 시작하지 않는다. 기존 ARC-01~10 초안은 유지하되 새 경계가 검토 전까지 최종 확정되지 않는다. 상호 참조는 계약 협의이며 순환적인 작업 완료 조건이 아니다.

| 단계 | 후속 작업 | 우선순위 제안 | 선행 및 검증 |
|---|---|---|---|
| 0 | ARC-00 v0.2 및 ADR-014 검토 | P0 | 대안·위협 모델·기존 결정 영향의 사용자 검토 |
| 1 | ARC-11 Multi-Client & Shared Core API | P0 | ARC-05/06/09/10 경계; 클라이언트 인증·인가·버전 협상과 이벤트 복구 검증 |
| 2 | ARC-12 VS Code Extension | P1 | ARC-11 계약, ARC-01/02/06/09; Workspace Trust, 로컬/원격 Host·Webview·SecretStorage 검증 |
| 3 | ARC-13 Chrome Extension | P1 | ARC-11 계약, ARC-01/06/08/09; Native Messaging 대 localhost, MV3·권한·공격 경계 검증 |
| 4 | ARC-14 Packaging, Distribution & Updates | P1 | ARC-11~13 요구 및 각 OS; Desktop 없는 설치, Native Host 등록, 업데이트·호환·롤백·스토어 정책 검증 |
| 5 | 기존 ARC-01~10 영향 반영 | 기존 Priority 유지 | 각 경계 및 사용자 승인·권한·저장·평가 정합성 재검토; 기존 초안 전면 재작성 금지 |

초기 검증은 공식 문서와 버전·정책 확인 → 최소 권한 및 위협 모델 검토 → 격리 환경에서 연결·거부·복구 실험 → 각 플랫폼 설치·업데이트와 Remote 환경 검증 순서다. 실험이나 실제 Extension 구현은 별도 후속 작업이다. ARC-01은 공통 사용자 흐름과 클라이언트 표현을, ARC-06은 Provider 실행·시도·세션 수명주기를 유지하고 ARC-11~13과 계약한다. ARC-02는 workspace/웹 데이터 출처, ARC-04는 플랫폼별 설정 적용 승인, ARC-05는 비밀 유지, ARC-07은 다중 클라이언트 충돌, ARC-08은 웹 컨텍스트, ARC-09는 클라이언트 권한, ARC-10은 세션·감사와 재연결을 검토한다.

## 템플릿 시스템 확장 · 2026-11-16

ARC-15는 Architecture Template & Registry System의 신규 상세 설계 ID로 제안한다. 추천·편집·Agent Definition은 ARC-03/01/04의 기존 책임을 재사용하고, 템플릿 버전·Registry·Validator만 독립 소유한다. 선행은 ARC-00 v0.3·ADR-015 검토, ARC-11의 Core 접근·권한 계약, ARC-10의 저장 경계다. 이어 ARC-15의 스키마·버전·인스턴스·보안·호환성을 상세 설계하고 ARC-03/04/07과 계약을 검토한 뒤 ARC-01 및 ARC-12/13의 플랫폼별 UX·권한을 설계한다. ARC-05/06 Capability 및 ARC-09 승인과의 정합성도 검증한다. ARC-14의 배포 계획에는 기본 템플릿 버전·업데이트와 마이그레이션 영향을 반영한다. 이 단계는 상위 계획이며 신규 상세 설계나 구현을 시작하지 않는다.

## 후속 설계 상태 · 2026-11-16

위 내용은 작성 당시의 기록이다. 이후 [ARC-11](ARC-11.md)~[ARC-14](ARC-14.md) 설계 제안과 [요구사항·수용 기준](REQUIREMENTS_ACCEPTANCE.md), ARC-09/10 보완 계약을 추가했다. 사용자 승인과 실제 OS·Provider·저장소 시험은 미완료이며 GitHub Projects 상태를 자동 변경하지 않았다. 과거의 미착수·미정 표현은 이 후속 설계의 존재나 제안된 기본값을 부정하지 않는다.
