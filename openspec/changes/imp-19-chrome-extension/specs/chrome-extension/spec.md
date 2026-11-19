# Chrome MV3 Extension and Native Messaging Boundary

## ADDED Requirements

### Requirement: Native Messaging manifest, caller origin, and 256 KiB frame enforcement
The Native Messaging host SHALL enforce exact `chrome-extension://<32 a-p chars>/` entries in `allowed_origins` with zero wildcards, verify Chrome's `argv[1]` origin without trusting payload-supplied origins, classify direct-execution-unproven Chrome origins strictly as `USER_ENROLLED_KEY`, and reject empty or `> 262144` byte native-endian 32-bit length-prefixed frames (W1/P7).

#### Scenario: Spoofed origin, wildcard manifest, or oversized frame rejected (V-14 / W1 / P7)
- **WHEN** a manifest contains a wildcard origin, Host receives a mismatched `argv[1]` or spoofed body origin, or a frame exceeds 262,144 bytes
- **THEN** manifest validation fails, the Native Host drops or rejects the connection, and frames above W1/P7 are rejected before decoding

### Requirement: Untrusted content script, stale tab handling, key vault fail-closed, and Worker recovery
The Chrome Service Worker SHALL store keys non-extractably (`extractable=false`) with IndexedDB failing closed on `KEY_UNAVAILABLE`, reject spoofed `payload.origin`/`tabId`/`approved` fields in favor of `sender` metadata, mark selections `stale` upon navigation or document change, reject `sendNativeMessage` for stateful streams, and recover from Worker restart using read-only cursor polling with zero auto-starts (V-14 / V-21).

#### Scenario: Page spoof attempt, tab navigation, Worker restart, and missing IndexedDB
- **WHEN** a page injects fake approval/origin fields, a tab navigates after selection, IndexedDB/WebCrypto is missing, or the Service Worker reconnects after port loss
- **THEN** fake fields are stripped/rejected, stale selections are blocked until re-selected, missing storage yields `KEY_UNAVAILABLE`, and reconnection performs Noise re-auth plus read-only state sync only
