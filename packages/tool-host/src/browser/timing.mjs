// Phase limits follow pinned Browser act-policy. The native host owns the outer
// allowance; these pure helpers never renew it or install a per-child timer.
export const MAX_BROWSER_TIMEOUT_MS = 2_147_000_000;
const DEFAULT_TIMED_KINDS = new Set(['click', 'type', 'hover', 'scrollIntoView', 'drag', 'select', 'fill', 'wait', 'evaluate']);

function integer(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.floor(value);
  if (typeof value === 'string' && /^[+-]?\d+$/.test(value.trim())) {
    const number = Number(value);
    if (Number.isFinite(number)) return Math.floor(number);
  }
  return undefined;
}

function phase(request, fallback, maximum) {
  return Math.min(maximum, Math.max(500, integer(request.timeoutMs) ?? fallback));
}

export function prepareActRequest(request) {
  return request.timeoutMs === undefined && DEFAULT_TIMED_KINDS.has(request.kind)
    ? { ...request, timeoutMs: 60_000 }
    : { ...request };
}

export const interactionTimeoutMs = request => phase(request, 8_000, 60_000);
export const waitTimeoutMs = request => phase(request, 20_000, 120_000);

export function typingTimeoutMs(request) {
  // Explicit slow-type delays are a host extension to the reference's75ms.
  const extra = request.slowly && typeof request.text === 'string'
    ? request.text.length * Math.max(0, (request.delayMs ?? 75) - 75)
    : 0;
  return Math.min(MAX_BROWSER_TIMEOUT_MS, interactionTimeoutMs(request) + extra);
}

export function pressTimeoutMs(request) {
  // The host also permits locator-targeted key presses. Their interaction phase
  // precedes the supported key hold, unlike the reference's keyboard-only path.
  return Math.min(MAX_BROWSER_TIMEOUT_MS, interactionTimeoutMs(request) + (request.delayMs ?? 0));
}

export function evaluateInnerTimeoutMs(request) {
  const outer = waitTimeoutMs(request);
  return Math.min(outer, Math.max(1_000, Math.min(120_000, outer - 500)));
}
