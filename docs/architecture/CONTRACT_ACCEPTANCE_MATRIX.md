# 교차 계약 수용 사례 및 독립 관측 명세 v1

상태: 구현 전 제안 · 2026-11-16. [교차 모듈 계약 명세](INTERFACE_CONTRACT_V1.md) C01~C08의 판정 가능한 설계 기준이다. 제품 시험을 실행했거나 사용자·평가자가 이 기준을 승인했다는 뜻이 아니다. 우측 상태는 모두 **NOT RUN**이다. 기존 V-01~16과 RT/N 추적은 [요구사항 추적](REQUIREMENTS_TRACEABILITY_V2.md)에 두며 아래 X01~X24는 교차 경계 세부 사례다.

## 공통 시험 문맥과 독립 증거

- 모든 사례는 고유 workspace W와 인증된 사용자 A, 관련 정확한 object/revision, Capability snapshot, 정책 및 승인 버전을 고정한다. 정상 권한 양성 대조를 먼저 실행하고, 이후 변경된 항목 하나만 다르게 한 부정 대조를 실행한다. 권한 거부 시험은 별도 사용자 B와 workspace X를 사용한다.
- 상태 변경 전후의 정본 revision·내용, 시도/프로세스 생성 기록, 실제 파일·네트워크 효과, 정책·승인 결정을 **서로 독립된 관측 경로**에서 얻는다. 평가 대상의 자체 로그나 모델 답변만으로 부작용 부재를 증명하지 않는다. 제품 관측 수단이 없으면 NOT RUN 또는 INDETERMINATE다.
- 표의 `무변경`은 요구된 정본 내용과 revision이 바뀌지 않고 대상 외 파일·외부 전송·새 프로세스가 발생하지 않음을 뜻한다. 진단·감사 기록 추가는 허용하되 비밀·대상 존재 여부를 외부 오류에 누출하지 않는다. 모든 부정 사례는 기대 오류뿐 아니라 부작용을 함께 판정한다.
- 동일 requestId 시험은 actor·workspace·operation과 모든 입력/기대 revision을 함께 고정한다. 스키마·정책·Provider 문서 버전과 제품·OS·Adapter 버전, fixture 해시, 독립 관측기와 판정자·시각을 기록한다. 실제 부작용이 관측되면 다른 증거가 없어도 FAIL이고, 관측 불가능한 부작용은 0으로 추정하지 않는다.

| ID / 경계 | 사전 상태 → 행위 | 기대 결과와 독립 증거 | 현재 |
|---|---|---|---|
| X01 C01 | profile P1·snapshot S1의 후보 목록 → 동일 조건 재조회 | 선택한 불변 templateId/versionId와 추천 근거·P1/S1을 각각 조회·일치 확인; 추천만으로 승인·실행 0 | NOT RUN |
| X02 C01 | P1/S1 추천 후 S2로 capability 변경 | 이전 제안은 stale, S2 재평가 전 실행 차단; 제안·승인·실행 관측 | NOT RUN |
| X03 C01 | A가 볼 수 없는 template를 조회 | 외부 응답에 내용·존재 여부 미노출, 정본 무변경; UI/응답 및 감사 범위 대조 | NOT RUN |
| X04 C02 | 불변 template T1에서 instance I1/I2 생성 후 I1 수정·T1 삭제 표시 | I2와 T1 version snapshot은 생성 당시 값 유지; 해시와 revisions 비교 | NOT RUN |
| X05 C02 | I revision4·definition revision1 검증 후 definition revision2 교체 | 예전 validation report는 stale, 승인 없는 실행 0; 버전 고정 보고서 확인 | NOT RUN |
| X06 C02 | 없는 definition 참조, 미지 major, 포트 타입 불일치 각각 제출 | INVALID_INPUT/UNSUPPORTED/PORT_MISMATCH 또는 해당 논리 오류, 각 경우 정본·실행 무변경 | NOT RUN |
| X07 C03 | 보안상 필수 경로 제한을 Provider가 표현하지 못함 | MappingReport가 UNSUPPORTED/LOSSY/UNKNOWN; 승인 UI 확인만으로 적용·실행 금지; 원본·대상 파일 비교 | NOT RUN |
| X08 C03 | 선택 필드의 검증된 손실 계획에 사용자 동의 후 대상 파일 외부 수정 | 기대 버전 충돌/STALE로 적용 안 함; 파일 전후 해시 및 계획 ID·승인 범위 확인 | NOT RUN |
| X09 C03 | snapshot supported로 계획 후 설치/Adapter 버전 변경 | 이전 계획 stale, 최신 지원 확인 전 실행 금지; versioned snapshot과 실제 호출 관측 | NOT RUN |
| X10 C04 | 실행 승인 없이 prepare가 attempt를 정상 예약 → 해당 attempt 승인 발급 뒤 start 직전 만료 | 예약된 Prepared 정본은 유지하지만 start는 거부, 외부 프로세스·전송 0; 프로세스 관측과 정본 대조. 다른 새 attempt에 예전 승인 재사용도 거부; 외부 전송이 수반되는 시작은 유효한 실행 승인이 있어도 별도 전송 승인 누락·변경이면 거부 | NOT RUN |
| X11 C04 | 시작 기록 직후 생성 여부 관측 불능 → 동일 request 재전송 | attempt Unknown·Task Blocked, 외부 프로세스 자동 재생성 0; 통제된 생성 추적과 상태 조회 | NOT RUN |
| X12 C04 | Running에 취소 요청, 정상 종료와 경합 | 실제 확인된 종료만 반영, cancel 수락은 종료가 아님, 정상 종료는 Task Evaluating; 종료 및 Task/attempt 정본 대조 | NOT RUN |
| X13 C05 | 성공 가능한 정상 상태 전이 → 동일 id/동일 입력 재전송 | 하나의 상태 전이·관련 이벤트와 동일 결과; 저장소 트랜잭션 및 외부 부작용 관측 | NOT RUN |
| X14 C05 | 동일 id에 다른 기대 revision 또는 입력; 별도 사례에서 커밋 도중 저장 실패 | 전자는 CONFLICT·무변경, 후자는 전체 commit 또는 전체 rollback; 실제 저장소 장애 주입 및 재시작 조회 | NOT RUN |
| X15 C05 | snapshot 읽는 동안 새 이벤트 commit 및 cursor 만료 | 상태/cursor 동일 시점, cursor 뒤 이벤트 재조회; 만료 시 정본 재조회와 유실 표시. 데이터셋/독립 저장소 조회 | NOT RUN |
| X16 C06 | 근거 K1을 선택한 뒤 K1의 읽기 권한 철회 | 기존 선택·승인으로 K1을 외부에 전송하지 않음; 권한 기록·선택 버전 및 독립 네트워크 관측 | NOT RUN |
| X17 C06 | 유효 기억의 원본을 삭제하고 인덱스 재구축 | stale/unknown 상태; 인덱스로 삭제된 원문이 재생성되거나 주입되지 않음; 삭제·인덱스·전송 대조 | NOT RUN |
| X18 C06 | 컨텍스트 예산이 후보 전체보다 작음 | 제외 항목·사유가 표시되고 결과를 완전한 입력으로 주장하지 않음; Selection 및 UI 대조 | NOT RUN |
| X19 C07 | task A/attempt 1/manifest M1을 평가 기준 E1로 통과 | 동일 버전의 저장된 PASS 뒤에만 Task A 성공; 평가·산출물·상태 정본 비교 | NOT RUN |
| X20 C07 | PASS 후, Task 성공 전이 직전에 가변 workspace 산출물 내용·attempt·기준 중 하나를 변경 | 원래 불변 snapshot에 대한 결과만 유지하고 새 가변 파일 버전에는 이전 PASS를 재사용하지 않음; snapshot/버전 일치를 보장하지 못하면 INDETERMINATE 또는 Blocked. 독립 파일·manifest·task 상태를 경합 주입해 대조 | NOT RUN |
| X21 C07 | 평가 저장 실패 또는 파일 읽기 실패 | Task 성공 금지, INDETERMINATE 또는 저장 실패 기록; 독립 파일·저장소 관측 | NOT RUN |
| X22 C08 | 등록된 Desktop/Extension의 workspace W 읽기, 유효한 권한 | 양성 요청만 허용; 동일 데이터 정본·revision 확인. 각 클라이언트·Core 기록 비교 | NOT RUN |
| X23 C08 | 미등록 client·다른 workspace·위조 웹페이지·만료 승인 각각으로 실행 | 매 요청 거부, 등록·정본·외부 프로세스·전송 무변경; 요청 출처와 독립 관측 | NOT RUN |
| X24 C08 | 실행 중 Worker 종료 후 재접속 및 protocol major 불일치 | 재인증·cursor 또는 snapshot 후 기존 attempt 표시; 자동 start 0. 비호환 변경은 거부 | NOT RUN |

## 결과 해석과 후속 승인

1. X01~X24는 구현 전 읽기 가능한 계약이며 스스로 실행·합격한 테스트가 아니다. 모든 행을 PASS로 판정하려면 독립 관측기와 대상 구현, 고정된 버전 및 양·부정 대조의 실제 증거가 있어야 한다.
2. C01~C08 한 연결의 대표 사례가 통과해도 모든 입력·OS·Provider·실패 경합을 보증하지 않는다. 제품 버전 또는 정본·정책·Capability가 바뀌면 영향을 받은 사례의 기존 결과는 재사용 전 검토한다.
3. G2는 모든 모듈과 실제 상호운용 근거가 미완료여서 UNKNOWN이다. G3는 OS/클라이언트 신뢰 경계의 별도 실증 전 UNKNOWN이다. G8은 실제 작업 품질·평가자 승인·운영 합격치가 없어 UNKNOWN이다. 이 계약 문서의 존재만으로 통과시키지 않는다.
