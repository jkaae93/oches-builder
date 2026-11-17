# 교차 모듈 계약 및 정합성 v0.1

상태: 설계 제안 · 2026-11-16. 각 계약은 소유 모듈의 최신 초안과 함께 읽는다. 물리 구현·상호운용성은 시험 전 미검증이다. 인증된 주체와 workspace는 ARC-11이 설정하고 모든 오류는 성공이나 지원으로 변환하지 않는다.

| 경계 / 호출 방향 | 정본·입력 버전 | 결과·오류·변경 영향 |
|---|---|---|
| ARC-03 → ARC-15 Registry | ARC-15의 불변 templateId/versionId; ARC-05 Capability snapshot | 후보와 요구 조건, NOT_FOUND/권한 거부; 스냅샷 만료 시 추천 stale. ARC-03은 검증·승인 소유 안 함 |
| ARC-15 → ARC-04 Definition | ARC-04의 definitionId/version 및 의미, ARC-15 instance revision | 유효/오류/unknown·손실; 정의 또는 schema 변경 시 validation report stale. template schemaVersion과 definition version 독립 |
| ARC-04 → ARC-05 Capability | ARC-05의 설치·계정·capability snapshot/version | supported/unsupported/unknown 및 근거; 필수 unknown 실행 차단. 설정 변환의 불명확한 손실은 오류/경고로 노출 |
| ARC-07 → ARC-06 Runtime | ARC-07 Task revision·DAG version, ARC-06 attemptId | prepare/start/cancel/observe, 중복·거부·Unknown; Task 상태와 시도 상태는 별도, 종료 확인 전 재시도 금지 |
| ARC-06 → ARC-10 Storage | ARC-06 시도 상태 의미, ARC-10 상태·event 정본과 revision | expectedVersion/operationId 원자 commit; 충돌·쓰기 실패; 외부 프로세스 생성과 원자적이지 않음 |
| ARC-08 Context → ARC-10 Memory | ARC-08 지식 유효성, ARC-10 기록·출처·접근 제어와 버전 | 선택 항목/출처/제외 사유; 출처 변경·삭제·권한 철회 시 stale, 주입 전 재확인 |
| ARC-07 → ARC-09 Evaluation → ARC-10 | Task revision·attemptId·artifact manifest hash/version, criteria/evaluator version | PASS/FAIL/INDETERMINATE; 다른 대상이나 stale PASS 재사용 불가; 평가 기록 저장 실패 시 성공 전이 금지 |
| ARC-12/13 또는 Desktop → ARC-11 Core | Core 정본; protocol major/minor, workspace와 기대 revision | 인증·인가·정책 통과 후 소유 모듈 호출; DENIED/CONFLICT/UNSUPPORTED/UNKNOWN; 끊김 시 cursor 또는 snapshot, 재실행 금지 |

템플릿 선택, 설정 적용 승인, 실행 승인 및 외부 전송 승인은 별개다. 승인 참조는 대상·행위·범위·버전에 결부하며 사용자 인터페이스 또는 추천 점수가 승인을 대체하지 않는다. 위 계약의 시험은 [수용 기준](REQUIREMENTS_ACCEPTANCE.md) R-01~12와 [검증 계획](VERIFICATION_PLAN.md) V-01~16에 추적한다.

## 후속 계약 제안

각 연결의 입출력·불변 조건·오류·변경 영향과 양성/부정 수용 예는 [교차 모듈 계약 명세 v1](INTERFACE_CONTRACT_V1.md)을 참조한다. 해당 계약은 초안이며 실제 통합 및 G2 통과 증거가 아니다.
