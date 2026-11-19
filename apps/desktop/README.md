# Desktop scaffold

The initial target is macOS arm64. The default transport invokes the native readiness channel. On macOS 14 or later, the native bridge probes a configured XPC service using a pinned Team ID and signing identifier. Missing configuration, invalid configuration, interruption and timeout report unavailable. Readiness never authorizes analysis or dispatches project data.

The application bundle must supply `OchesCoreServiceName`, `OchesCoreTeamID` and `OchesCoreSigningIdentifier` through reviewed packaging configuration. No service or signing identity is assumed by default. A deployed service, verified approval issuance and protected analysis dispatch are still pending; even a successful readiness reply remains unavailable for analysis. Other platforms and signed application-to-service integration are not verified.

The development baseline is Flutter 3.41.6 (framework revision `db50e20168`, Dart 3.11.4), Xcode 26.6 (17F113), and Swift 6.3.3. The Flutter application lockfile is tracked. Use the exact Flutter revision for reproducibility; verify the selected Xcode and Swift versions with `xcodebuild -version` and `swift --version`.

From a clean checkout on macOS arm64:

```sh
cd apps/desktop
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build macos --debug
cd ../..
swift test --package-path core
```

A successful scaffold build is not evidence of authenticated XPC, persistent storage, or provider support.
