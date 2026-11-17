# Desktop scaffold

The initial target is macOS arm64. This shell does not yet connect to an authenticated Core; the default transport reports unavailable. XPC identity, authorization and other platforms are not verified.

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
