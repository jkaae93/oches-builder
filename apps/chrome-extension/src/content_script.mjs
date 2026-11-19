export const MAX_EXCERPT_BYTES = 32_768;

/**
 * Untrusted renderer selection extractor.
 * Content Script has zero Native Host / Core / approval API access and strictly emits
 * plain selection data stripped of any page-supplied authority claims.
 */
export function buildUntrustedSelectionPayload({
  selectionText,
  pageTitle = '',
  elementHint = '',
  capturedAt = Date.now(),
  // Deliberately strip any attacker-supplied spoofed fields if passed from DOM events.
  ..._ignoredPageClaims
}) {
  if (typeof selectionText !== 'string' || selectionText.trim().length === 0) {
    throw new Error('EMPTY_SELECTION');
  }

  let excerpt = selectionText;
  let truncated = false;
  const rawBytes = Buffer.byteLength(excerpt, 'utf8');
  if (rawBytes > MAX_EXCERPT_BYTES) {
    excerpt = Buffer.from(excerpt, 'utf8').subarray(0, MAX_EXCERPT_BYTES).toString('utf8');
    truncated = true;
  }

  return {
    kind: 'USER_EXPLICIT_PAGE_SELECTION',
    explicitUserGesture: true,
    selectionText: excerpt,
    truncated,
    pageTitle: String(pageTitle).slice(0, 512),
    elementHint: String(elementHint).slice(0, 256),
    capturedAt: Number.isFinite(capturedAt) ? Math.trunc(capturedAt) : Date.now(),
  };
}
