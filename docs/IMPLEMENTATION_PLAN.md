# 구현 계획 및 GitHub 이력 관리

기준일: 2026-11-17. 설계 완료와 제품 구현 완료를 분리한다.

Project: https://github.com/users/jkaae93/projects/2

macOS arm64 + Flutter Desktop + Shared Local Core + SQLite를 Phase 1으로 구현한다. Mock 검증 후 Claude, Codex 비교 Adapter를 연결하고 Phase 2에서 Noise 채널·Chrome·VS Code로 확장한다. Windows/Linux/원격 Host와 Tier2 외부 anchor는 별도 설계·시험 이슈 없이 지원으로 표시하지 않는다. 일정은 PROVIDER_MVP_FEASIBILITY의 가정이며 납기 약속이 아니다.

- [IMP-01 기반 구조·빌드·계약 스키마](https://github.com/jkaae93/oches-builder/issues/1) · 선행: 없음
- [IMP-02 SQLite 정본·이벤트·멱등 트랜잭션](https://github.com/jkaae93/oches-builder/issues/2) · 선행: IMP-01
- [IMP-03 macOS XPC 상호 신원·키 보호](https://github.com/jkaae93/oches-builder/issues/3) · 선행: IMP-01
- [IMP-04 정책·요청별 승인·인가](https://github.com/jkaae93/oches-builder/issues/4) · 선행: IMP-02, IMP-03
- [IMP-05 FreshnessAnchor·DurableIntent·삭제 복구](https://github.com/jkaae93/oches-builder/issues/5) · 선행: IMP-02, IMP-03, IMP-04
- [IMP-06 Provider 설치·계정 참조·Capability](https://github.com/jkaae93/oches-builder/issues/6) · 선행: IMP-01, IMP-04
- [IMP-07 Mock Runtime·세션·취소 경합](https://github.com/jkaae93/oches-builder/issues/7) · 선행: IMP-02, IMP-04, IMP-06
- [IMP-08 프로젝트 분석·안전한 Profile](https://github.com/jkaae93/oches-builder/issues/8) · 선행: IMP-01, IMP-04
- [IMP-09 Agent 정의·변환 계획·승인 적용](https://github.com/jkaae93/oches-builder/issues/9) · 선행: IMP-06, IMP-08
- [IMP-10 템플릿 Registry·타입 그래프 Validator](https://github.com/jkaae93/oches-builder/issues/10) · 선행: IMP-09
- [IMP-11 추천 엔진·단일 Agent 기준선](https://github.com/jkaae93/oches-builder/issues/11) · 선행: IMP-08, IMP-10
- [IMP-12 DAG Scheduler·동시성·재시도](https://github.com/jkaae93/oches-builder/issues/12) · 선행: IMP-07, IMP-10
- [IMP-13 불변 산출물·평가·독립 관측](https://github.com/jkaae93/oches-builder/issues/13) · 선행: IMP-02, IMP-07, IMP-12
- [IMP-14 Memory·Context·삭제 전파](https://github.com/jkaae93/oches-builder/issues/14) · 선행: IMP-05, IMP-08
- [IMP-15 Claude 1차 Adapter·비용·실환경 게이트](https://github.com/jkaae93/oches-builder/issues/15) · 선행: IMP-06, IMP-07, IMP-09, IMP-13
- [IMP-16 Flutter Desktop 수직 흐름](https://github.com/jkaae93/oches-builder/issues/16) · 선행: IMP-05, IMP-11, IMP-12, IMP-13, IMP-14, IMP-15
- [IMP-17 Codex 비교 Adapter](https://github.com/jkaae93/oches-builder/issues/17) · 선행: IMP-15, IMP-16
- [IMP-18 설치키·Noise IK 종단 채널](https://github.com/jkaae93/oches-builder/issues/18) · 선행: IMP-03, IMP-04, IMP-05, IMP-16
- [IMP-19 Chrome MV3·Native Messaging](https://github.com/jkaae93/oches-builder/issues/19) · 선행: IMP-18
- [IMP-20 VS Code 로컬 Extension](https://github.com/jkaae93/oches-builder/issues/20) · 선행: IMP-18
- [IMP-21 패키징·업데이트·호환·롤백](https://github.com/jkaae93/oches-builder/issues/21) · 선행: IMP-16, IMP-17, IMP-19, IMP-20
- [IMP-22 출시 검증·추적성·비기능 게이트](https://github.com/jkaae93/oches-builder/issues/22) · 선행: IMP-21

## 공통 구현·검증·변경 이력 규칙

## 에이전트 작업 및 완료 규칙
- [ ] 선행 이슈 완료와 참조 설계의 최신 보완절을 확인한다. 문서 충돌·언어/라이브러리 미결정은 ADR/이슈에 기록하고 추측으로 계약을 바꾸지 않는다.
- [ ] 구현 전에 입력/출력 schema·오류·상태 전이·권한·버전 경계를 PR에 명시하고 위 체크리스트를 독립 리뷰 가능한 하위 PR로 나눈다.
- [ ] 정상·거부·장애/경합 회귀 테스트와 실제 실행 명령·환경·기대/실제 결과·증거를 첨부한다. 설계 시제품 테스트를 제품 통과로 대체하지 않는다.
- [ ] 로그/fixture에 credential·쿠키·민감 원문을 남기지 않는다. unknown을 성공/지원/비용 0으로 바꾸지 않는다.
- [ ] PR에 Refs #이슈번호, 마지막 완료 PR에 Closes #이슈번호를 넣는다. 변경 사유·계약 영향·migration/rollback·잔여 위험을 기록한다.
- [ ] 상태: Backlog → Todo(선행 충족) → In progress → In Review → Done(수용 기준 증거+리뷰+병합). 차단은 댓글에 원인/해제 조건/관련 이슈를 기록한다.
- [ ] 완료 시 변경 commit/PR, 테스트 증거 및 미실행 플랫폼을 댓글로 남긴다. 범위 변경은 날짜·사유·영향을 댓글로 보존한다.

초기 제품 시험 상태: NOT RUN. 이 이슈 생성은 구현 완료나 버그 부재를 보증하지 않는다.

설계 원문은 현재 로컬 미커밋 파일을 포함한다. 첫 기반 이슈에서 원문 snapshot/hash와 저장소 반영을 확보해야 다른 에이전트가 동일한 기준으로 작업할 수 있다.
