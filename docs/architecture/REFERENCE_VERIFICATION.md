# 참고 자료 확인 기록

확인일: 2026-11-16. 아래는 공개 자료에 적힌 내용과 제품 적용 제안을 구분한다. 제품과 공식 Provider의 연동 승인이나 실제 기능 시험 결과가 아니다. 문서에 발행일이 표시되지 않으면 미표기로 기록한다.

| 자료 | 발행일 | 확인한 내용과 한계 | 적용 문서 |
|---|---|---|---|
| [Building effective agents](https://www.anthropic.com/research/building-effective-agents) | 2024-12-19 | 단순하고 조합 가능한 패턴과 워크플로·에이전트 구분을 설명. 현재 페이지는 당시 도구 환경이 변했다고 알림 | ARC-03의 단일 기준선은 제품 제안 |
| [Components of agent memory](https://www.anthropic.com/research/components-of-agent-memory) | 2026-11-06 | 기억의 구성과 선별을 논의 | ARC-08의 출처·검증 상태는 제품 제안 |
| [Effective context engineering](https://www.anthropic.com/research/effective-context-engineering-for-ai-agents) | 2025-09-29 | 컨텍스트 선택·검색의 중요성을 설명 | ARC-08의 선택적 제공은 제품 제안 |
| [Multi-agent research system](https://www.anthropic.com/research/multi-agent-research-system) | 2025-06-13 | 자사 연구 시스템의 조율·평가·운영 경험을 설명; 모든 작업에서 멀티 에이전트가 우월하다는 근거는 아님 | ARC-07 |
| [Long-running harnesses](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents) | 2025-11-26 | 세션 간 진행 상태 및 환경 관리 문제를 설명 | ARC-06/07의 복구 요구는 제품 제안 |
| [Demystifying evals](https://www.anthropic.com/research/demystifying-evals-for-ai-agents) | 2026-01-09 | 에이전트 평가의 구성과 회귀 검증을 설명 | ARC-09의 기준선 비교는 제품 제안 |
| [Claude Code 인증](https://code.claude.com/docs/en/authentication) | 미표기 | 공식 CLI의 계정 및 로그인 방법을 설명. 외부 GUI에 의한 계정 격리나 모든 기능 집행을 보장하지 않음 | ARC-05 |
| [Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [인증](https://learn.chatgpt.com/docs/auth) | 미표기 | 공식 문서는 CLI 최초 실행 시 ChatGPT 등 이용 가능한 로그인 방식을 선택하고 로그인 상태를 확인하는 방법을 설명한다. 버전별 세션 계약·계정 격리·외부 제품 연동 허용은 별도 확인 필요 | ARC-05/06 |
| [Google Antigravity 공식 인증 문서](https://antigravity.google/docs/install?tab=cli) | 미표기 | 공식 문서는 로컬 표면 간 인증을 공유한다고 설명한다. 따라서 세션별 계정 격리를 가정할 수 없으며 외부 GUI 연동 허용·격리·세션 계약은 별도 확인 필요 | ARC-05 |
| [Orca 저장소](https://github.com/stablyai/orca) | 미표기 | 공개 저장소에 접근 가능. 참고 사례이나 특정 버전 소스와 라이선스 검토는 미완료 | ARC-05/06 |
| [GitHub CLI Projects](https://cli.github.com/manual/gh_project) | 미표기 | 프로젝트 관리 명령 공식 안내; 실제 프로젝트의 필드·권한은 별도 조회 | 프로젝트 관리 |

Provider의 공식 문서 내용은 변경될 수 있다. 대상 OS·설치 버전·계정·약관을 고정한 실험 전까지 지원 매트릭스는 unknown으로 유지한다.
