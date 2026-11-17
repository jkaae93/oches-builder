# Analyzer exclusions: candidate v1

This list implements the categories in DESIGN_FINALIZATION N1 and is a review candidate, not a guarantee of secret discovery. It is not yet connected to a public scanning or approval flow. Each path component is classified case-insensitively against the lists below; extension matches apply to every component, so excluded directories cannot be traversed merely by appending a child name.

- Credentials: `.env`, `.env.*`, `.ssh`, `.aws`, `.gnupg`, `.kube`, `.netrc`, `.npmrc`, `.pypirc`, `id_rsa`, `id_ed25519`, `credentials`, `credentials.json`, `service-account.json`; extensions `pem`, `key`, `p12`, `pfx`, `keystore`, `jks`.
- Version control: `.git`, `.hg`, `.svn`.
- Dependencies: `node_modules`, `.dart_tool`, `.pub-cache`, `vendor`, `pods`, `.venv`, `venv`, `__pycache__`.
- Builds: `build`, `dist`, `target`, `.next`, `.gradle`, `deriveddata`, `coverage`.
- Media: `png`, `jpg`, `jpeg`, `gif`, `webp`, `heic`, `svg`, `mp3`, `wav`, `mp4`, `mov`, `avi`, `pdf`.
- Archives: `zip`, `tar`, `gz`, `bz2`, `xz`, `7z`, `rar`, `dmg`, `iso`.
- Bundles: `app`, `framework`, `bundle`, `xcassets`, `xcodeproj`, `xcworkspace`.

Additional user exclusions are exact relative paths or subtree roots, not wildcard expressions; malformed paths and rules are rejected. Default exclusions cannot be disabled through this classifier. N1 allows path-specific exceptions, but they must remain unavailable until an explicit path-specific approval is bound and rechecked. Naming, content, platform and file-format heuristics can miss secrets; report this uncertainty and do not log content.
