# macOS 코드 신원 위조 실험 및 Core 신뢰 경계

2026-11-16 · macOS 26.4 (25E246), arm64 · 범위: 임시 테스트 바이너리의 정적 코드 서명. 제품·Provider 실행, 인증 또는 사용자 키체인 변경 없음. 실험은 이 컴퓨터의 `clang`과 `codesign`만 사용했고 임시 디렉터리와 파일은 종료 후 삭제됐다.

## 관찰한 실험과 결과

1. 다른 동작을 출력하는 서로 다른 C 실행 파일 두 개를 임시로 컴파일했다. 두 파일의 SHA-256이 다름을 비교한 뒤, 각각 `codesign --sign - --identifier test.local.oches.identity`로 **ad-hoc 서명**했다. 외부 서명 인증서나 개인키는 사용하지 않았다.
2. 두 실행 파일 모두 `codesign --verify --strict`를 통과했고, 식별자만 요구하는 `codesign --verify -R '=identifier "test.local.oches.identity"'` 검사도 통과했다. **서명 자체의 무결성과 임의 식별자의 일치는 신뢰된 발행자나 앱 신원을 입증하지 못한다.**
3. 두 번째 ad-hoc 파일은 `anchor apple generic`과 같은 식별자를 함께 요구하는 검사에서 거부됐다. 다만 올바른 Developer ID 앱의 양성 대조가 없으므로 이 명령으로 적법한 제품 앱의 허용·배포 신뢰성을 증명하지 않았다.
4. 두 번째 서명된 파일의 바이트 한 개를 변경한 뒤 `codesign --verify --strict`가 실패했다. 이는 이 시제품의 파일 변조를 잡은 결과이며 모든 변조·실행 중 교체에 대한 보장이 아니다.

이 실험은 파일 **경로의 정적 검증**이다. 실제 IPC 연결 상대의 실행 중 코드 신원을 검증하지 않았고, UID/GID, PID, 파일 경로 또는 `identifier`만으로 통신 상대를 인증할 수 있다는 근거가 아니다. 검증된 경로의 교체, PID 재사용, 연결 전후 경합, 신뢰 UI 위조, 키 접근, 의도하지 않은 권한 증가는 시험하지 않았다. macOS 보안 정책과 서명 방식은 OS·배포 형태마다 재확인이 필요하다.

## 경계별 선택지와 실패 조건

| 경계 | 후보 접근 | 증거로 필요한 실험 | 실패 시 제품 동작 |
|---|---|---|---|
| Client → Core | OS peer 자격과 **연결된 실행 주체**의 검증 가능한 코드 서명 요구사항; Core의 등록·인가를 별도 적용 | 올바른 발행자/서명·식별자의 양성 대조, 같은 UID의 다른 서명·ad-hoc·복제 식별자·손상 파일·PID 재사용·연결 중 교체의 부정 대조 | 실제 연결 주체와 검증 대상을 안전하게 결합하지 못하거나 신원이 불명이면 등록·변경·실행 거부 |
| Core → Client | 별도 신뢰 경로로 고정·검증된 Core 신원과 챌린지에 대한 키 증명 후보 | 가짜 Core/소켓 선점, 재설치·키 교체·오래된 키, 서버 바인딩 실패를 거부하는지 양·부정 대조 | 서버 신원 확인 불가 또는 불일치 시 정보 제공·명령 중단; 사용자 경고만으로 우회하지 않음 |
| 개인키 저장 | 코드 서명·entitlement와 접근 제어가 있는 OS 키 보관 후보 | 서명된 제품 구성요소에서 정상 사용하고 같은 사용자 다른 프로세스·다른 서명·복제 앱의 접근/내보내기 시도가 거부되는지 확인 | 비밀이 노출되거나 접근 제한·키 출처를 검증할 수 없으면 권한 부여·실행 금지 |
| 최초 등록·승인 | 제품의 신뢰 UI와 대상·권한·workspace를 묶은 사용자 확인 | UI 위장·메시지 재전송·승인 범위 변경·만료·철회, 사용자가 확인한 내용과 실제 호출의 일치 | 검증되지 않은 UI나 오래된 승인으로 실행하지 않음 |
| Chrome Host/VS Code Host | Native Host 및 Extension Host의 별도 신원·연결, 확장 ID/Workspace Trust를 보조 조건으로 사용 | 정상 확장과 다른 확장, Native Host 교체, Webview/Content Script 메시지 위조와 원격 Host 위치별 검증 | ID·Origin·Workspace Trust 하나만으로 Core 변경·실행 권한 부여 금지 |

macOS 전용 상세 API, OS 버전·프로세스 형태별 신뢰할 수 있는 peer 식별, 키의 비추출성과 entitlement 배포, 앱 업데이트 시 요구사항·키 회전 방식은 **미결정**이다. 특정 Apple API 이름이나 코드 서명 검사를 선택했다고 G3가 통과되는 것은 아니다. 특히 같은 OS 사용자로 실행되는 악성 프로세스에 대한 방어 한계와 플랫폼이 제공하는 증거의 신뢰성을 별도로 검토한다.

## 공식 문서와 검증 한계

[Apple 코드 서명 안내](https://developer.apple.com/library/archive/technotes/tn2206/)는 코드 신원과 지정 요구사항을 이용한 검증을 설명한다. [Apple Keychain 접근 그룹 안내](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)는 코드 서명과 접근 그룹의 관계를 설명한다. 위의 시제품 결과와 제품에 적용할 fail-closed 정책은 이 문서의 실험·설계 제안이며, 공식 자료가 Oches의 보안을 인증한 것은 아니다.

## 미실행 및 판정

실제 Oches Core·클라이언트·Native Host의 서명된 양성 대조, 같은 사용자 악성 프로세스의 live peer 검증, OS 키 생성·보호·키 유출, 등록/철회/회전, 사용자 승인 UI, Windows/Linux 시험은 **NOT RUN**이다. 별도 서명된 시제품·보안 테스트 환경 및 명시적 실험 승인 없이 실제 사용자 자격증명이나 키체인을 수정하지 않는다. G3는 **UNKNOWN**, 제품 안전·릴리스 준비는 미입증이다. 점수를 목표치에 맞추어 변경하지 않는다.

재현: 저장소 루트에서 `python3 docs/architecture/experiments/verify-macos-adhoc-identity.py`. 임시 시제품만 생성하며 사용자 인증과 키체인을 사용하지 않는다. 후속 신뢰 UI·키 보호·상호 인증 비교와 별도 임시 키 실험은 [ARC-11 신뢰 경계 선택지](ARC-11-TRUST-OPTIONS.md)에 정리했다.
