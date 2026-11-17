# ARC-11 OS별 앱 신원·키 보호 검증 기록

검토일 2026-11-16 · 상태: 부분 검증, G3 UNKNOWN. 실험은 사용자의 실제 인증·설정·키체인을 변경하지 않았다. 제품 Core/Extension 구현 및 서명된 앱은 아직 없어 제품 인증·인가를 검증할 수 없다.

## 현재 환경에서 수행한 실험

| 구분 | 환경·방법 | 관찰 | 판정 범위 |
|---|---|---|---|
| macOS peer credentials | macOS 26.4 (25E246). 각 socketpair를 생성한 뒤 fork한 두 자식과 각각 통신하고 부모에서 `getpeereid`를 호출 | 두 연결에서 호출자와 같은 유효 사용자·그룹으로 관찰됨 | 자격 확인으로 앱 신원을 판별할 수 없음. socketpair는 fork 전에 생성됐으므로 독립 앱의 연결 시점 자격 확인 시험도 아님. 경로 기반 socket, 다른 사용자, 서명 검증·프로세스 교체·PID 재사용, 개인키 보호 또는 제품 보안을 시험한 것은 아님 |
| macOS 경로 socket | 임시 디렉터리의 Unix socket에 같은 사용자로 별도 실행한 두 Python 프로세스가 각각 연결. 서버가 `getpeereid` 호출 | 두 연결의 유효 사용자·그룹이 동일 | 서로 다른 프로세스의 동일 사용자 자격을 확인한 사례. 다른 사용자 거부, 제품 앱 신원·서명과 키 보호는 검증하지 않음 |
| macOS Keychain·앱 신원 | 제품 앱·서명 프로필·등록 흐름 부재 | 실험 미실행 | UNKNOWN. 특정 access group·코드 서명 검사 및 키의 실제 비추출성·다른 앱 접근 거부는 입증되지 않음 |
| Windows named pipe·키 보호 | 대상 OS 부재 | 실험 미실행 | UNKNOWN. ACL과 클라이언트 토큰 검증·앱 신원 및 키 보호 미확인 |
| Linux Unix socket·키 보호 | 대상 OS 부재 | 실험 미실행 | UNKNOWN. peer credentials와 자격증명 저장소·앱 신원 미확인 |

## 공식 자료와 설계상의 함의

- [Apple의 Keychain 접근 그룹 설명](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)은 코드 서명으로 보호되는 앱 식별자와 Keychain 접근 그룹을 설명한다. 실제 Oches 실행 파일·확장 프로세스가 요구한 entitlement와 서명을 갖는지, 해당 구성에서 키 접근이 차단되는지는 별도 검증해야 한다.
- [Apple 배포 서명 안내](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)는 일부 entitlement에 프로비저닝 프로필 승인이 필요함을 설명한다. CLI, VS Code Host 및 Native Messaging Host에 동일한 앱 격리가 자동 적용된다고 가정하지 않는다.
- [Microsoft named pipe 가장 문서](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-impersonatenamedpipeclient)는 가장 실패를 검사해야 한다고 명시한다. 특정 프로세스의 코드 신원이나 키 보호가 확인됐다는 근거는 아니다.
- [Linux unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html)은 `SO_PEERCRED`가 연결 시점 상대 자격을 반환한다고 설명한다. 같은 사용자로 실행되는 임의 코드와 신뢰 앱의 구분 또는 실행 파일 무결성을 단독으로 증명하지 않는다.

## 다음 실증 조건

별도로 승인된 테스트 환경에서 신뢰 UI와 Core의 배포·서명, 클라이언트 개인키 생성/접근 제어, 서버 신원 확인, 동일 사용자 악성 프로세스·다른 사용자·바이너리 교체·복제·철회·재설치·재연결을 OS별로 시험한다. 대상 OS/버전, 서명 방식, 입력, 관찰 결과, 비밀을 제거한 증거 및 실패 시 차단 여부를 기록한다. 조건 미충족 또는 미실행이면 해당 클라이언트의 변경·실행 기능은 지원한다고 주장하지 않는다. 현재 어느 플랫폼도 G3 PASS 조건을 만족한다고 판정하지 않는다.

## 코드 서명 신원 위조의 추가 실험

[macOS 코드 신원 위조 실험](MACOS_IDENTITY_EXPERIMENT.md)에서 서로 다른 두 임시 실행 파일이 같은 ad-hoc 식별자만으로 검증을 통과하고, 변경된 파일의 무결성 검증은 실패했다. 식별자만으로 앱 신원을 구별할 수 없다는 부정 사례다. 신뢰된 서명 양성 대조, 실제 연결 peer, 키 보호와 등록·승인은 시험하지 않았으므로 G3는 UNKNOWN이다.
