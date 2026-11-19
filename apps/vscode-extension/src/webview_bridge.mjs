import crypto from 'node:crypto';
import { MAX_LOGICAL_MESSAGE_BYTES } from '../../../core/contracts/noise_ik_client.mjs';

const ALLOWED_WEBVIEW_OPS = new Set([
  'requestStatus',
  'proposeAnalyze',
  'proposeApply',
  'requestCancel',
]);

const ALLOWED_WEBVIEW_FIELDS = new Set(['webviewId', 'op', 'workspaceId', 'planId', 'targetUri']);
const FORBIDDEN_CREDENTIAL_KEYS = ['secret', 'token', 'privatekey', 'cookie', 'authorization'];

export class WebviewBoundaryError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function escapeHtmlText(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function assertNoSecretsInState(obj, pathPrefix = 'state') {
  if (!obj || typeof obj !== 'object') return;
  for (const [key, val] of Object.entries(obj)) {
    const lower = key.toLowerCase();
    if (FORBIDDEN_CREDENTIAL_KEYS.some((bad) => lower.includes(bad))) {
      throw new WebviewBoundaryError(
        'CREDENTIAL_LEAK_BLOCKED',
        `Refusing to expose credential field ${pathPrefix}.${key} to Webview`
      );
    }
    if (val && typeof val === 'object') {
      assertNoSecretsInState(val, `${pathPrefix}.${key}`);
    }
  }
}

export function buildWebviewHtml({
  nonce = crypto.randomBytes(16).toString('hex'),
  cspSource = "'self'",
  viewState = {},
}) {
  assertNoSecretsInState(viewState);
  const csp = [
    "default-src 'none'",
    `script-src 'nonce-${nonce}'`,
    `style-src 'nonce-${nonce}'`,
    `img-src ${cspSource} data:`,
    "frame-ancestors 'none'",
  ].join('; ');

  const statusText = escapeHtmlText(viewState.statusText ?? 'Unknown');
  const workspaceText = escapeHtmlText(viewState.workspaceText ?? 'None');
  const projectSnippet = escapeHtmlText(viewState.projectSnippet ?? '');
  const trustNotice = escapeHtmlText(
    viewState.trustNotice ?? 'USER_ENROLLED_KEY (Shared Extension Host unproven; Desktop approval required)'
  );
  const actionsDisabled = viewState.allowWorkspaceOperations === true ? '' : 'disabled';

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta http-equiv="Content-Security-Policy" content="${csp}" />
  <style nonce="${nonce}">
    body { font-family: sans-serif; padding: 12px; }
    pre { white-space: pre-wrap; }
  </style>
  <title>Oches Builder</title>
</head>
<body>
  <h1 id="title">Oches Builder</h1>
  <p id="trust">${trustNotice}</p>
  <p id="status">${statusText}</p>
  <p id="workspace">${workspaceText}</p>
  <pre id="project-data">${projectSnippet}</pre>
  <button id="analyze-btn" type="button" ${actionsDisabled}>Analyze Local Workspace</button>
  <button id="apply-btn" type="button" ${actionsDisabled}>Apply Plan</button>
  <script nonce="${nonce}">
    const statusEl = document.getElementById('status');
    window.addEventListener('message', (event) => {
      if (event.data && typeof event.data.statusText === 'string' && statusEl) {
        statusEl.textContent = event.data.statusText;
      }
    });
  </script>
</body>
</html>`;
}

export function validateWebviewMessage(rawMessage, { expectedWebviewId }) {
  if (!rawMessage || typeof rawMessage !== 'object' || Array.isArray(rawMessage)) {
    throw new WebviewBoundaryError('MALICIOUS_WEBVIEW_MESSAGE', 'Webview payload must be an object');
  }
  const bytes = Buffer.byteLength(JSON.stringify(rawMessage), 'utf8');
  if (bytes > MAX_LOGICAL_MESSAGE_BYTES) {
    throw new WebviewBoundaryError('PAYLOAD_TOO_LARGE', 'Webview payload exceeds 256 KiB W1 limit');
  }
  if (rawMessage.webviewId !== expectedWebviewId) {
    throw new WebviewBoundaryError('UNTRUSTED_WEBVIEW_SENDER', 'Mismatched Webview sender ID');
  }
  for (const key of Object.keys(rawMessage)) {
    if (!ALLOWED_WEBVIEW_FIELDS.has(key)) {
      throw new WebviewBoundaryError('UNKNOWN_WEBVIEW_FIELD', `Rejected unexpected field: ${key}`);
    }
  }
  if (typeof rawMessage.op !== 'string' || !ALLOWED_WEBVIEW_OPS.has(rawMessage.op)) {
    throw new WebviewBoundaryError('MALICIOUS_WEBVIEW_MESSAGE', `Disallowed Webview op: ${rawMessage.op}`);
  }
  for (const field of ['workspaceId', 'planId', 'targetUri']) {
    if (rawMessage[field] !== undefined) {
      if (typeof rawMessage[field] !== 'string') {
        throw new WebviewBoundaryError('MALICIOUS_WEBVIEW_MESSAGE', `${field} must be string`);
      }
      const val = rawMessage[field];
      if (val.includes('..') || /<script|javascript:|;|\|\||&&|\$\(/i.test(val)) {
        throw new WebviewBoundaryError(
          'MALICIOUS_WEBVIEW_MESSAGE',
          `Rejected suspicious traversal/script/shell characters in ${field}`
        );
      }
    }
  }
  return {
    webviewId: rawMessage.webviewId,
    op: rawMessage.op,
    workspaceId: rawMessage.workspaceId ?? null,
    planId: rawMessage.planId ?? null,
    targetUri: rawMessage.targetUri ?? null,
  };
}
