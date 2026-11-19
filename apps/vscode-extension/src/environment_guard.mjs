export const WORKSPACE_MUTATING_OR_SENSITIVE_OPS = new Set([
  'analyzeWorkspace',
  'applyPlan',
  'startRun',
  'sendExternalContext',
]);

export const READ_ONLY_OPS = new Set(['getStatus', 'inspectSnapshot']);

export class VSCodeEnvironmentError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function evaluateVSCodeEnvironment({
  remoteName = '',
  uiKind = 'Desktop',
  workspaceFolders = [],
  isTrusted = false,
} = {}) {
  const normalizedRemote = typeof remoteName === 'string' ? remoteName.trim() : '';
  const hasRemoteHost = normalizedRemote.length > 0;
  const isWebUI = uiKind === 'Web' || uiKind === 2;

  const folderUris = Array.isArray(workspaceFolders)
    ? workspaceFolders.map((folder) => {
        const uriObj = folder?.uri;
        const hasCustomToString =
          uriObj &&
          typeof uriObj.toString === 'function' &&
          uriObj.toString !== Object.prototype.toString;
        const scheme = uriObj?.scheme ?? folder?.scheme ?? '';
        const fsPath = uriObj?.fsPath ?? folder?.fsPath ?? '';
        const raw =
          (hasCustomToString ? uriObj.toString() : null) ??
          folder?.raw ??
          (scheme && fsPath ? `${scheme}://${fsPath}` : '');
        return { scheme, fsPath, raw };
      })
    : [];

  const hasNonLocalScheme = folderUris.some((f) => f.scheme !== 'file');

  if (hasRemoteHost || isWebUI || hasNonLocalScheme) {
    return {
      supported: false,
      status: 'UNSUPPORTED',
      reason: 'REMOTE_OR_VIRTUAL_HOST_UNSUPPORTED',
      remoteName: normalizedRemote || null,
      uiKind,
      allowReadOnly: true,
      allowWorkspaceOperations: false,
      workspaceUris: folderUris.map((f) => f.raw).filter(Boolean),
    };
  }

  if (isTrusted !== true) {
    return {
      supported: true,
      status: 'RESTRICTED_MODE',
      reason: 'WORKSPACE_UNTRUSTED',
      remoteName: null,
      uiKind,
      allowReadOnly: true,
      allowWorkspaceOperations: false,
      workspaceUris: folderUris.map((f) => f.raw).filter(Boolean),
    };
  }

  return {
    supported: true,
    status: 'LOCAL_TRUSTED',
    reason: null,
    remoteName: null,
    uiKind,
    allowReadOnly: true,
    allowWorkspaceOperations: true,
    workspaceUris: folderUris.map((f) => f.raw).filter(Boolean),
  };
}

export function assertOperationAllowed(envState, operation) {
  if (READ_ONLY_OPS.has(operation)) {
    return;
  }
  if (!envState || envState.status === 'UNSUPPORTED' || !envState.supported) {
    throw new VSCodeEnvironmentError(
      'REMOTE_UNSUPPORTED',
      'v1 supports local desktop file workspaces on the same host as Core only; remote SSH/WSL/Container/Web is disabled'
    );
  }
  if (envState.status === 'RESTRICTED_MODE' || !envState.allowWorkspaceOperations) {
    throw new VSCodeEnvironmentError(
      'RESTRICTED_MODE_DENIED',
      'Workspace is untrusted (Restricted Mode); analysis, apply, execution, and transfer are blocked'
    );
  }
  if (!WORKSPACE_MUTATING_OR_SENSITIVE_OPS.has(operation)) {
    throw new VSCodeEnvironmentError('UNSUPPORTED_OPERATION', `Unknown operation: ${operation}`);
  }
}
