# 독립 리뷰 후속 증거 · 2026-11-16

기준: REVIEW_75의 독립 점수 75/100, CONDITIONAL. 아래 확인은 설계·실험 범위를 확장할 뿐 점수 또는 G2·G3·G8을 PASS로 변경하지 않는다.

| 우선순위 | 수행한 작업 | 증거·남은 위험 |
|---|---|---|
| ARC-11 앱 신원·키 보호 | macOS 별도 프로세스의 Unix socket peer 사용자·그룹 관찰과 공식 OS 문서 확인 | [OS별 증거](ARC-11-OS-SECURITY-EVIDENCE.md). 동일 사용자의 프로세스를 UID/GID만으로 구별할 수 없음을 보였으나 서명·키 보호·신뢰 UI와 Windows/Linux 실증은 미실행; G3 UNKNOWN |
| ARC-04/15 스키마·변환 | ARC-15 예시의 AgentDefinition이 ARC-04에서 요구하는 필수 필드를 빠뜨린 문제를 발견해 보완. 예시의 필수 키·상한에 대한 제한적 양성/음성 검사 실행 | `ARC-15.md` 예시는 JSON 파싱 및 일부 필수 필드·양수 상한을 확인했다. 정식 스키마와 Provider Adapter가 없으므로 포트 전체·의미 등가성·변환 검증은 미실행; G2 UNKNOWN |
| 평가 데이터셋·정답·운영 합격치 | 실제 Git 커밋의 읽기 전용 과제 2개를 제안하고 ignore 규칙 정답을 전역·시스템 ignore를 격리한 임시 Git 저장소에서 재현 | [실제 과제 후보](fixtures/REAL_TASK_CANDIDATES.md). 승인, 모델/제품 실행, 대표 표본과 운영 합격치는 없음; G8 UNKNOWN |
| 첫 OS/CLI 수직 흐름·저장 및 복구 | 현재 macOS와 설치 CLI 버전은 기존 기록을 확인; SQLite 기초 실험 기록만 존재 | [Provider 형식](PROVIDER_FORMAT_EVIDENCE.md), [SQLite 기초](SQLITE_EXPERIMENT.md). 제품이나 Adapter 없음, OS/CLI 선정·공식 연동 및 장애 주입 미실행. 실제 인증 변경에는 사용자 승인 필요 |

## 확인한 제한

이 작업은 일반 GitHub Issue·코드·인증 변경을 수행하지 않았다. 로컬 `docs/`는 미추적 상태이며 기존 내용을 유지했다. Project 항목을 새로 만들거나 Done으로 옮기지 않았다. 실제 실험을 시행하지 않은 항목은 NOT RUN 또는 UNKNOWN이다. 추가 검증은 OS별 서명·키 보호 환경과 구현체, 평가자·사용자 선택이 필요하다.
