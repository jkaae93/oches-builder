/**
 * Side Panel safe data renderer.
 * Always writes untrusted selection text with textContent (never innerHTML) and enforces
 * two-step explicit confirmation before proposing transmission to Core.
 */
export function renderSidePanelState(documentRef, state) {
  const trustEl = documentRef.getElementById('trust-badge');
  const connEl = documentRef.getElementById('connection-status');
  const originEl = documentRef.getElementById('selection-origin');
  const staleEl = documentRef.getElementById('selection-stale-status');
  const previewEl = documentRef.getElementById('selection-preview');
  const confirmBtn = documentRef.getElementById('confirm-transfer-btn');

  if (trustEl) {
    trustEl.textContent =
      'Trust: USER_ENROLLED_KEY (Chrome origin checked; standalone Host execution unproven)';
  }
  if (connEl) {
    connEl.textContent = state.connected
      ? `Connected to Core via Noise IK (cursor=${state.lastCursor ?? 0})`
      : 'Disconnected — awaiting re-authentication';
  }
  const sel = state.activeSelection ?? null;
  if (!sel) {
    if (originEl) originEl.textContent = 'Origin: none';
    if (staleEl) staleEl.textContent = 'State: no selection captured';
    if (previewEl) previewEl.textContent = '';
    if (confirmBtn) confirmBtn.disabled = true;
    return;
  }

  if (originEl) {
    originEl.textContent = `Origin: ${sel.origin} (tab=${sel.tabId}, frame=${sel.frameId})`;
  }
  if (staleEl) {
    staleEl.textContent = sel.stale
      ? `STALE (${sel.staleReason}) — explicit re-selection required`
      : sel.confirmedForTransfer
        ? 'Confirmed for proposal (Core execution still requires Desktop approval)'
        : 'Captured locally (not yet sent)';
  }
  if (previewEl) {
    previewEl.textContent = sel.selectionText;
  }
  if (confirmBtn) {
    confirmBtn.disabled = Boolean(sel.stale);
  }
}
