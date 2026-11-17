# 구성 비교 집계 oracle 후보

2026-11-16 · 평가 설계용 합성 사례, 제품 및 독립 관측기 NOT RUN. [평가 계약](../EVALUATION_OBSERVABILITY_SPEC.md#구성-비교개선의-판정-계약-후보)에 연결한다. 한 행은 사전 등록된 서로 다른 작업과 반복 번호의 쌍이며, 기준선과 후보는 각각 다른 격리 snapshot에서 실행한다. 중복 `(datasetVersion, taskId, repeat, configuration)`은 충돌로 거부한다.

| 작업/반복 | 기준선 | 후보 | 기대 분류 |
|---|---|---|---|
| A/1 | PASS | PASS | 양쪽 PASS |
| B/1 | PASS | FAIL | 기준선만 PASS |
| C/1 | FAIL | PASS | 후보만 PASS |
| D/1 | FAIL | FAIL | 양쪽 FAIL |
| E/1 | PASS | INDETERMINATE | 미완결: 후보 관측 불명 |
| F/1 | NOT RUN | PASS | 미완결: 기준선 미실행 |
| G/1 | FAIL | NOT RUN | 미완결: 후보 미실행, 기준선 FAIL 보존 |

이 합성 입력의 예상 총계는 예정 7쌍, 완료 4쌍, 미완결 3쌍이며 완료 네 분류는 각각 1쌍이다. 후보 PASS의 전체 예정 trial 기준 표시는 3/7이고, 후보 INDETERMINATE와 NOT RUN은 각각 1/7, 기준선 NOT RUN은 1/7이다. 완료 쌍의 후보 PASS 2/4를 전체 예정 trial의 성공률로 표시해서는 안 된다. 한쪽 FAIL과 다른 쪽 미실행은 미완결 쌍으로 집계하되 개별 FAIL을 삭제하지 않는다. 관측된 안전 위반의 FAIL 우선순위와 시험 중단 규칙은 집계 결과와 별도로 적용한다.

표의 산술은 2026-11-16에 Python `collections.Counter`로 독립 계산했다: 후보 PASS 3, FAIL 2, INDETERMINATE 1, NOT RUN 1; 완료 쌍 4, 미완결 쌍 3. 이는 표본 산술 확인이지 대상 집계기 검증이 아니다.

## 부정 대조

- 중복 trial, 같은 쌍에 다른 dataset version·task snapshot, 미등록 구성 또는 알 수 없는 상태 → INVALID_INPUT/비교 불가; 임의 마지막 값 선택 금지.
- 예정된 trial 결과 누락 → NOT RUN 사유와 함께 미완결; 저장 오류를 PASS/FAIL로 바꾸지 않는다.
- 안전 위반 FAIL과 반대편 INDETERMINATE → 쌍은 미완결이며 해당 개별 위반은 FAIL로 남긴다.
- A/1과 A/2는 별도 반복이나 하나의 작업 표본이다. 7행 전체를 7개의 독립 무작위 사용자 작업으로 주장하지 않는다.
- 동일한 합성 결과를 두 번 제출하거나 집계 범위를 바꾸면 중복 카운트하지 않고 해당 버전·범위의 결과를 구분한다. 사전 등록된 작업·범위 밖 결과는 별도 보고한다.

이 oracle은 비교 UI와 집계의 의도된 동작을 검토하기 위한 표이며 통계적 우월성·작업 대표성·실제 제품 동작의 증거가 아니다. 평가자 검토와 제품 구현 후 양·부정 대조는 NOT RUN이다.
