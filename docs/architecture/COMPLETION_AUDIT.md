# 상세 아키텍처 완료 점검

점검일: 2026-11-16. 판정은 저장소 파일과 GitHub Projects #2의 실제 상태에 근거한다. `확인`은 문서 또는 프로젝트 상태의 확인을 의미하며, 실제 구현의 동작 보장을 뜻하지 않는다.

| 요구사항 | 근거 | 판정 및 한계 |
|---|---|---|
| ARC-00 기준 | ARC-00.md의 사용자 제공 원문 및 ARC-00-READABLE.md | 로컬에 보존; 원격 master에는 없음 |
| 제품 목표·로드맵·미결정 | ARCHITECTURE_GOALS.md, DESIGN_ROADMAP.md, OPEN_QUESTIONS.md | 초안 작성; 실제 MVP OS·CLI는 미정 |
| ARC-01~10 산출물 | ARC-01.md부터 ARC-10.md | 각 문서에 요청된 설계 항목과 Mermaid 존재; 사용자는 설계 초안의 검토 후 승인을 선택함 |
| 기존 ADR과 신규 결정 | ADR_BASELINE_REVIEW.md, adr/ADR-013-runtime-observation.md | ADR-001~012의 방향·검증 상태 대조 및 ADR-013 제안; 별도 채택 여부 확인 필요 |
| 경계·상태·보안 정합성 | CONTRACT_REVIEW.md, DESIGN_REVIEW.md | 문서 수준으로 대조하고 특정 상태 전이 조건을 정적 점검; 실제 집행과 모든 경합을 증명하지 않음 |
| 문서·다이어그램 확인 | DESIGN_REVIEW.md의 검사 기록 | 요구 항목 표기·로컬 링크 및 ARC-01~10 Mermaid 21개, ARC-00 읽기용 사본의 3개 렌더링 확인; 문서의 정확성 전체를 자동 보증하지 않음 |
| 공식 자료 | REFERENCE_VERIFICATION.md | 제공 자료를 조회하고 작성일 표기 여부·지원 범위의 한계를 기록; 버전별 실험 및 약관 확인은 별도 |
| 테스트 전략 | 각 ARC 문서 및 VERIFICATION_PLAN.md | 시험 조건과 기대 결과 작성; 실제 제품·Provider 시험은 실행하지 않음 |
| GitHub Projects | 프로젝트 #2 조회 및 갱신 | 2026-11-17 기준 프로젝트 #2(`Oches Builder launches`)의 `[ARC-01]`~`[ARC-15]` Draft Issue 15건 전체를 `Done`으로 갱신하고 각 항목 본문에 확정 설계 산출물 및 `NOT RUN` 제품 시험 구분을 반영함 |
| 사용자 승인·완료 상태 | 각 문서의 Definition of Done, 프로젝트 상태 | 사용자가 설계 초안의 검토 후 승인을 선택함. ARC-04의 Provider별 형식·실제 동작 검증 등 남은 완료 조건은 충족 전이므로 Done으로 표시하지 않음 |
| 원격 반영 | git status: docs/ 미추적 | 변경물은 로컬에만 존재하며 커밋·푸시하지 않음. 원격 저장소 변경은 승인 범위 밖 |

## 남은 결정

1. ARC-01~10의 설계 초안 승인 선택을 반영했다. ADR-013의 별도 채택 여부는 확인이 필요하다.
2. 사용자 선택에 따라 In Review를 추가하고 설계 항목을 이동했다.
3. 구현 전 최초 OS·CLI와 정책·Capability·격리·재개·권한 집행의 검증 방법을 결정한다. 실제 인증 변경에는 별도 사용자 승인이 필요하다.

기준 문서와 설계 초안의 로컬 작성, 정적 검토와 렌더링 검사만으로 Provider 지원 또는 제품 구현이 완료됐다고 주장하지 않는다.

로컬 CLI 버전 및 공식 설정 형식의 제한적 확인 결과는 [Provider 설정 형식 검증 기록](PROVIDER_FORMAT_EVIDENCE.md)에 있다. 실제 Adapter 생성·적용 시험은 미실행이다.

SQLite 후보에 대한 임시 DB 기초 시험은 [SQLite 검증 기록](SQLITE_EXPERIMENT.md)에 있다. 제품 Repository나 장애 복구 구현의 검증은 아니다.

## 후속 설계 상태 · 2026-11-17

위 1차 표는 최초 작성 당시의 기록이다. 이후 [ARC-11](ARC-11.md)~[ARC-15](ARC-15.md) 상세 설계, [ADR-016](adr/ADR-016-core-contract-baseline.md)/[ADR-017](adr/ADR-017-user-enrolled-client-key.md), [종단 보안 채널](EXTENSION_SECURE_CHANNEL.md), [복구 최신성 기준점](RECOVERY_FRESHNESS_ANCHOR.md), [MVP 기준선·비용 계약](PROVIDER_MVP_FEASIBILITY.md), [요구사항·수용 기준](REQUIREMENTS_ACCEPTANCE.md) 및 45개 단위 계약 시험을 완료해 [설계 평가 기준 정정 및 최종 설계 판정](REVIEW_DESIGN_CRITERIA_CORRECTED.md) 기준 **100/100 (G1~G8 설계 기준 PASS)**을 달성했다.

이에 따라 사용자 요청으로 2026-11-17 GitHub Projects #2의 `[ARC-01]`~`[ARC-15]` Draft Issue 15건 전체 상태를 `Done`으로 업데이트하고 본문 산출물·완료 상태를 동기화했다. 실제 제품 구현과 OS·브라우저·IDE·Provider 런타임 시험은 여전히 **NOT RUN**이며, 로컬 `docs/` 변경물은 아직 커밋·푸시하지 않았다.

## 설계 확정 · 2026-11-17 (Final)

사용자 승인("없어 다 해")으로 [설계 확정 기록](DESIGN_FINALIZATION.md)을 Final 전환했다. ARC별 수치·상한·기본값·스키마 동결값은 해당 문서 §6이 정본이며, gh 15건 본문의 `미확정 사항` 템플릿 문구를 모듈별 확정 문구로 교체했다. [미결정 목록](OPEN_QUESTIONS.md)에 해소 상태를 반영하고 ARC-01~15·관련 계약서의 미결정 문구에 동결 주석을 달았다. 조건부(E5 수치 임계치)·제품게이트·NOT RUN은 해소가 아니다. 커밋·푸시는 별도 승인 대기.
