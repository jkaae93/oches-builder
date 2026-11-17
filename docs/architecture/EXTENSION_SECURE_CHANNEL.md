# 확장–Core 종단 보안 채널 설계

상태: **설계 결정 기준** · 2026-11-16. 사용자 채택 [ADR-017](adr/ADR-017-user-enrolled-client-key.md)의 설치키와 Desktop 요청별 승인 위에, Host가 중간에 있는 Chrome 및 VS Code 경로의 메시지 기밀성·무결성을 제공한다. 이 문서는 종단 채널·키 분리·저장 실패 차단·부수정보 완화 계약을 확정한다. 실제 제품 구현과 대상 OS·브라우저·IDE 실행 시험은 **NOT RUN**이다.

## 채널과 프레임 계약

- 확장과 Core가 암호학적 양 끝이다. Native Messaging Host 또는 Extension Host 밖의 전달 프로세스는 길이 접두 암호문 프레임만 중계한다. localhost TCP 개방은 사용하지 않는다.
- 등록 후의 채널은 **Noise IK (`Noise_IK_25519_ChaChaPoly_SHA256`)**를 사용한다. [Noise Protocol Framework](https://noiseprotocol.org/noise.html)
  - 확장은 등록 단계에서 사용자 대조 및 Core 서명으로 검증한 Core의 Noise static X25519 공개키(`coreNoiseStaticKey`)를 고정한다.
  - Core는 등록된 설치 서명키로 검증한 확장의 Noise static X25519 공개키(`clientNoiseStaticKey`)를 해당 `clientId`·`workspaceId`·`enrollmentGeneration` 범위에 결부한다.
- **프레임과 청크 규칙:**
  - 전송 프레임은 최대 **65,535 바이트(64 KiB - 1)**의 Noise transport 메시지 한도를 준수하며, 논리 메시지는 암호화 전 최대 **60 KiB** 평문 청크로 분할한다.
  - 각 청크의 AEAD 평문 헤더에는 `(logicalMessageId, chunkIndex, isFinal, bodyBytes, paddingLength, paddingBytes)`를 포함한다. `chunkIndex`는 메시지 내 `0`부터 단조 증가해야 하며, `isFinal=true` 이전에 연결이 끊기거나 순서·`logicalMessageId`·패딩 길이가 불일치하면 해당 채널을 즉시 닫고 부분 데이터를 소비하지 않는다.
  - Chrome Native Messaging 공식 상한(Host→Extension 1 MB, Extension→Host 64 MiB) 이내에서 단일 논리 요청/응답의 최대 직렬화 크기는 256 KiB로 제한하며, 초과 시 `INVALID_INPUT`으로 부작용 없이 거부한다.
- **Zero-RTT 금지 및 재연결:**
  - handshake prologue에는 `[protocolMajor, "Noise_IK_25519_ChaChaPoly_SHA256", coreId, clientId, enrollmentGeneration, clientRole]`의 RFC 8785 JCS 정규화 UTF-8 바이트(SHA-256)를 바인딩한다.
  - 양측은 등록된 상대 static 공개키와 현재 등록·철회 상태를 검증한다. **handshake가 양쪽에서 완료(`Split`)되고 Core가 `hello`/인가를 확정한 뒤에만** 0-RTT가 아닌 transport 데이터·민감 정보·위험 명령을 처리한다. 0-RTT 페이로드는 프로토콜 수준에서 거부한다.
  - 새 연결마다 새 ephemeral 키쌍과 새 CipherState를 생성한다. 인증 실패, static 키 불일치, AEAD 복호화 오류, 청크 순서 불일치 또는 철회 감지 시 채널을 즉시 종료하고 기존 nonce/CipherState를 절대 재사용하지 않는다.
- **구현 규율:** 양측은 동일한 표준 Noise 규격과 고정된 상호운용 test vector를 통과한 검토된 암호 구현체를 사용하며, 자체 암호 알고리즘 구현이나 미지원 환경에서의 평문 fallback을 금지한다.

## 키 분리·등록 결부·저장 규칙

- **키 분리:** 각 설치는 서명용 키쌍(`signingKey`: macOS Secure Enclave 사용 시 ECDSA P-256, 그 외 소프트웨어 안전 저장소 기준 Ed25519)과 Noise static 키쌍(`noiseStaticKey`: X25519)을 별도 용도로 생성한다. 한 키 형식을 다른 형식으로 임의 변환·겸용하지 않는다.
- **등록 transcript 결부:** 최초 등록은 [등록 transcript](CLIENT_INSTALLATION_AUTH_DESIGN.md#최초-core-키-확인-및-noise-키-결부-계약)의 RFC 8785 JCS 정규화 및 SHA-256 digest 규칙을 따른다. Core와 확장의 **서명 공개키 지문(`signingKeyId`)과 Noise static 공개키 지문(`noiseStaticKeyId`)을 모두** 등록 transcript와 등록 완료 응답 서명에 포함한다. 미등록 상태에서는 비밀·프로젝트 데이터와 위험 명령을 전송하지 않으며, 등록 전 비교 단계 자체를 종단 암호화로 간주하지 않는다.
- **플랫폼별 저장과 실패 시 차단(Fail-Closed):**
  - **macOS Desktop / Core:** `signingKey`는 Secure Enclave/Keychain(비추출 우선)에 저장하고, `noiseStaticKey`(X25519)는 동일 Team ID 및 코드 서명 접근 제어(ACL)가 설정된 macOS Data Protection Keychain 항목에 보관한다(X25519에 대해 Secure Enclave 하드웨어 비추출을 가정하지 않음). Keychain 접근 거부·잠금·ACL 미충족 시 평문 파일 fallback 없이 `KEY_UNAVAILABLE`을 반환하고 기동/등록을 차단한다.
  - **Chrome Extension (MV3):** `signingKey`는 Service Worker에서 `extractable=false` WebCrypto `CryptoKey`로 생성해 확장 전용 IndexedDB에 저장한다. `noiseStaticKey`는 WebCrypto X25519 지원 여부 및 `extractable=false` 사용 가능성을 대상 런타임에서 확인하며, 미지원 또는 비추출 상태 유지가 불가능할 경우 평문 저장이나 평문 전송으로 대체하지 않고 `UNSUPPORTED`/`KEY_UNAVAILABLE`로 차단한다. 확장 origin 내 비신뢰 문맥(Content Script, 웹페이지, 다른 패널)으로 `CryptoKey` 객체 `postMessage` 전달 및 임의 바이트 서명 대리 API 노출을 금지한다. [Chrome Web Crypto 저장](https://developer.chrome.com/docs/modern-web-guidance/guides/security/client-side-encryption)
  - **VS Code Extension:** `ExtensionContext.secrets`(Electron `safeStorage` / OS Keychain backend)에만 직렬화된 키를 보관하며 `workspaceState`·`globalState`·평문 파일 저장을 금지한다. 프로세스 메모리 사용 중 노출 위험을 명시하며, 호스트 OS의 저장소 backend가 암호화되지 않은 `basic_text` fallback이거나 신뢰 경계가 확인되지 않은 원격 Host(SSH/WSL/Container)인 경우 `KEY_UNAVAILABLE`/`UNSUPPORTED`로 실패 처리하고 위험 기능을 차단한다. [VS Code SecretStorage](https://code.visualstudio.com/api/extension-capabilities/common-capabilities)

## 부수 정보·오류 매핑·Desktop 승인

- **응답 크기 패딩:** 민감한 읽기 응답(`snapshot`, 분석/평가 요약, 승인 범위 등)을 Host 중계 경로로 전송할 때는 AEAD 평문 내부에서 **4 KiB(4,096 바이트) 단위 버킷으로 패딩(`paddingLength`, `paddingBytes`)**하여 응답 길이만으로 프로젝트 파일/작업 유무나 짧은 오류·결과를 미세하게 식별하는 부수 정보 노출을 제한한다.
- **외부 오류 매핑:** 인증·권한·존재 여부 확인 실패 시 외부 채널에는 대상 존재 여부를 감춘 일관된 범주 오류(`DENIED`, `APPROVAL_REQUIRED`, `CONFLICT`, `UNAVAILABLE`)만 반환한다. 실패의 상세 원인(서명 불일치, 키 미등록, workspace 미인가, 정책 불일치)은 Core의 로컬 감사 로그에만 기록한다.
- **인가와 Desktop 승인:** Core는 복호화된 채널 요청에 대해 등록키 주체(`USER_ENROLLED_KEY`)·workspace·operation·JCS 입력 digest·`expectedRevision`·단회 nonce·현재 정책 버전을 검증한다. `USER_ENROLLED_KEY`를 `PLATFORM_BOUND`로 표시하지 않는다. 쓰기·실행·외부 전송 요청은 Core가 직접 구성한 대상·범위·부작용을 양방향 XPC peer 검증을 통과한 Desktop 신뢰 UI에 표시하고, 사용자의 명시적 승인(`approvalId`)과 nonce 소비·상태/감사를 ARC-09/10 단일 로컬 트랜잭션으로 커밋한 뒤에만 시작한다.

## 한계 및 검증 조건

- Noise 채널은 Host 중계자가 내용을 도청하거나 조용히 변조하는 것을 방지하는 설계다. 중계자는 여전히 통신 빈도·타이밍과 버킷 단위의 대략적 트래픽 규모를 관찰하거나 전달을 지연·중단·실시간 중계할 수 있다. 확장 실행 문맥 또는 Core 자체가 침해된 경우 해당 주체가 키를 사용할 수 있으므로, 실시간 relay와 침해된 확장의 서명 대리는 Desktop 요청별 승인 및 최소 권한으로 위험을 제한한다.
- **계약 검증 및 제품 시험 목록:**
  - 동일 등록 쌍의 정상 IK handshake·청크 조립·패딩 제거·승인 후 실행 양성 대조
  - 다른 Core/클라이언트 static 키, 변조된 prologue, 0-RTT 데이터 삽입, 청크 순서 변경/누락, AEAD 태그 변조 거부
  - Host 중계 경로에서 평문/비밀 미노출 확인 및 오류 응답의 타 workspace 존재 여부 비노출 확인
  - 서비스 워커 종료·재접속 시 새 ephemeral 키 및 새 CipherState 재협상, 키 철회·교체 후 구 키 즉시 거부
  - Keychain/SecretStorage/WebCrypto 실패 시 평문 fallback 0건 (`KEY_UNAVAILABLE`) 확인
- 논리 채널·키 결부·0-RTT 차단 계약은 [계약 시제품 테스트](contracts/test_extension_secure_channel.py)로 단위 검증하고, 실제 Chrome/VS Code/macOS 제품 및 OS 런타임 보안 시험은 **NOT RUN**으로 구분한다.
