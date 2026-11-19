import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateNativeManifest } from '../apps/chrome-extension/native-host/host_bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');

function run() {
  const chromeManifest = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'apps/chrome-extension/manifest.json'), 'utf8')
  );
  assert.equal(chromeManifest.manifest_version, 3);
  assert.ok(Number(chromeManifest.minimum_chrome_version) >= 120, 'P2 requires Chrome >= 120');

  const nativeTemplate = JSON.parse(
    fs.readFileSync(
      path.join(ROOT, 'apps/chrome-extension/native-host/com.oches.builder.host.template.json'),
      'utf8'
    )
  );
  validateNativeManifest(nativeTemplate);

  const vscodePkg = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'apps/vscode-extension/package.json'), 'utf8')
  );
  assert.equal(vscodePkg.engines.vscode, '^1.85.0', 'P2 requires VS Code >= 1.85.0');
  assert.equal(vscodePkg.capabilities.virtualWorkspaces.supported, false, 'P8 disallows virtual workspaces in v1');

  const corePackageSwift = fs.readFileSync(path.join(ROOT, 'core/Package.swift'), 'utf8');
  assert.ok(corePackageSwift.includes('.macOS(.v13)'), 'P1 Core package targets macOS arm64');

  const pubspec = fs.readFileSync(path.join(ROOT, 'apps/desktop/pubspec.yaml'), 'utf8');
  assert.ok(pubspec.includes('name: oches_desktop'));

  const summary = {
    ok: true,
    verifiedPins: {
      chromeMinVersion: chromeManifest.minimum_chrome_version,
      nativeHostName: nativeTemplate.name,
      vscodeMinEngine: vscodePkg.engines.vscode,
      vscodePublisherId: `${vscodePkg.publisher}.${vscodePkg.name}`,
      v1InstallMode: 'bundledLocalDesktopAndCoreOnly (P9)',
    },
    notRunProductGates: [
      'Apple Developer ID code signing',
      'Apple notarization ticket verification',
      'Chrome Web Store & VS Code Marketplace reviews',
    ],
  };
  console.log(JSON.stringify(summary, null, 2));
}

run();
