# 설계 개선 후 자체 재평가 v0.1

검토일: 2026-11-16. 기준: 대화에 제공된 Architecture Review Protocol v1.0과 로컬 작업 트리. 이 표는 설계 작성자의 자체 평가이며, 후속 독립 호환성 리뷰어가 보완된 ARC-04/15 계약을 확인한 뒤 동일 가중치로 75/100을 별도로 산정했다. 독립 품질·보안 리뷰도 점수의 관련 항목과 잔여 한계를 검토했다. 점수는 구현·공식 지원의 증명이 아니며 사용자 승인 및 실제 시험은 미완료다. 기존 문서들은 Git에 추적되지 않은 로컬 초안이다.

## 동일 가중치 재평가

| 항목 | 점수/5 | 가중 점수 | 근거와 점수 제한 |
|---|---:|---:|---|
| Requirements Coverage | 4 | 16/20 | [추적표](REQUIREMENTS_ACCEPTANCE.md) R-01~12가 목표, 책임, 부정 시험과 합격 조건을 연결한다. 후보 기준·fixture의 사용자 검토는 미완료다. |
| Architecture & Module Boundaries | 4 | 12/15 | [교차 계약](CROSS_MODULE_CONTRACTS.md)은 각 경계의 방향·정본·버전·오류와 stale 처리를 구분한다. 물리 API와 실제 통합은 미검증이다. |
| Extensibility & Compatibility | 4 | 12/15 | [ARC-11](ARC-11.md)은 major/minor 및 capability 협상·실패를, [ARC-12](ARC-12.md)와 [ARC-13](ARC-13.md)은 Trust·원격 실행·Worker 종료 및 미지원 경로를 구분한다. 실제 OS/Provider 조합 시험은 미실행이다. |
| Security & Authentication | 3 | 9/15 | [ARC-11](ARC-11.md)은 등록·철회·권한·위협 경계와 미검증 시 차단을 제안한다. 신뢰 UI·앱 신원과 키 보호의 OS별 실증이 없어 안전성은 미확정이다. |
| Reliability & Recovery | 4 | 8/10 | [ARC-06](ARC-06.md)의 Unknown·취소 경합, [ARC-11](ARC-11.md)의 단절·커서 복구 및 [ARC-10](ARC-10.md)의 트랜잭션 실패 조건이 있다. 제품 장애 주입 시험은 미실행이다. |
| Data & Memory Consistency | 4 | 8/10 | [ARC-10](ARC-10.md)의 제안 보존·삭제·파생물 정책과 [ARC-09](ARC-09.md)의 버전 고정 평가 계약이 원본과 정본 책임을 구분한다. 저장·백업과 삭제의 실제 보장은 미검증이다. |
| Verifiability & Observability | 4 | 8/10 | [검증 계획](VERIFICATION_PLAN.md) V-01~16, [수용 기준](REQUIREMENTS_ACCEPTANCE.md)과 20개 [합성 fixture](fixtures/recommendation-v0.1.json)에 입력·기대 제약·실패 처리 및 증거 기록 방식이 있다. fixture의 적합성 검토와 제품 실행은 아직 없다. |
| Feasibility & Cost | 2 | 2/5 | 설치된 CLI 버전·공식 자료의 제한적 확인은 있으나 첫 OS·CLI 승인, 실동작 및 비용은 미검증이다. [Provider 검증](PROVIDER_FORMAT_EVIDENCE.md) |
| **합계** | | **75/100** | 계산식 Σ(가중치 × 점수 / 5). 제안 설계의 예외·제약 검토 수준에 대한 평가다. |

## Hard Gate 재판정

- **G1 PASS(설계 추적):** R-01~12가 모듈·시험을 연결한다. 수용 기준이 제품 이해관계자에게 승인됐다는 뜻은 아니다.
- **G2 UNKNOWN:** 책임과 주요 오류 경로는 대조했으나 ARC-04의 실제 중립 스키마·플랫폼 구현과 전체 계약의 호환성은 미검증이다.
- **G3 UNKNOWN:** 구조와 fail-closed 요구가 제안됐지만 OS별 앱 신원·키 보호·승인 강제 능력은 미검증이다.
- **G4 PASS:** 플랫폼·Provider 지원 여부를 supported/unsupported/unknown으로 기록하고 불명확한 필수 기능을 차단한다. 실제 지원의 증거는 아니다.
- **G5 PASS:** Task/Attempt, 템플릿/인스턴스 및 기록·지식의 논리적 소유자가 지정됐다.
- **G6 PASS(정책 설계):** 실패·재시도·취소·Unknown·복구 정책이 명시됐다. 실제 복구 보장 판정은 별도다.
- **G7 PASS(정책 설계):** 템플릿의 버전 불변, 검증, 신뢰 경계와 승인 분리가 정의됐다. 파서와 권한 집행은 미검증이다.
- **G8 UNKNOWN:** R-01~12 및 V-01~16에 안전·계약 시험의 기대 결과와 합격 조건이 제안됐으나 실제 작업의 품질 데이터셋과 운영 합격치는 미확정이다. fixture 승인과 실제 시험도 남았다.

**판정은 CONDITIONAL이다.** 점수 75는 목표 수준의 자체 설계 평가이지, 모든 Hard Gate 통과·보안 안전성·릴리스 준비 또는 독립 리뷰 통과를 뜻하지 않는다. G2/G3/G8은 UNKNOWN으로 남는다. 원래 F-01의 실제 강제 보장과 F-03의 Provider 실증은 해결되지 않았으며, F-02/F-04/F-05는 구체 계약과 확인 가능한 시험을 제안했으나 승인과 구현 검증이 남는다.

## 검증한 범위

로컬 Markdown 상대 링크, 20개 합성 fixture의 JSON 파싱·ID 유일성·4개 그룹 각 5개·필수 속성 및 V-01~16 존재를 정적 점검했다. 이 검사는 설계의 의미적 정확성, fixture의 정답, 구현 동작이나 보안성을 증명하지 않는다. CLI 버전 확인 외 로그인, 모델 호출, 설정 변경, 실제 Adapter 또는 플랫폼 통합은 수행하지 않았다.

## 독립 검토에서 반영한 수정

보안 검토에서 ARC-09의 집행 불명 시 경고만으로 실행할 수 있다는 문구 충돌을 발견해 차단으로 통일하고 원본 관찰·진단 권한을 분리했다. 호환성 검토에서 중립 정의·포트·Provider 손실 계약 부재를 지적해 ARC-04/15 v0.2로 보완했으며, 이후 확장성 4/5·전체 75/100으로 재평가했다. 품질 검토의 fixture oracle 및 snapshot/cursor 경합 지적은 각각 fixtures/ORACLE.md와 ARC-11에 반영했다. 독립 검토는 제품 시험이 아니다. G2·G3·G8은 UNKNOWN을 유지한다.

## 후속 확인

[독립 리뷰 후속 증거](REVIEW_FOLLOWUP_EVIDENCE.md)에 macOS peer 자격의 제한적 실험, ARC-04/15 예시 수정, 실제 저장소 기반 평가 과제 후보를 기록했다. 제품 동작·앱 신원·키 보호·운영 평가를 증명하지 않으므로 G2/G3/G8은 UNKNOWN이다.
