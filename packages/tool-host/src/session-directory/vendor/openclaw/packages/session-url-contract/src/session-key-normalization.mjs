import { normalizeLowercaseStringOrEmpty } from "../../normalization-core/src/string-coerce.mjs";
import { normalizeOptionalString } from "../../normalization-core/src/string-coerce.mjs";
import { parseAgentSessionKeyParts } from "./session-key.mjs";
const SIGNAL_GROUP_ID_PATTERN = /(^|:)signal:group:([^:]+)/gi;
const MATRIX_ROOM_KEY_PATTERN = /^(?:(?:agent:[^:]*:)+:*)?matrix:(?:channel|group):/i;
const NORMALIZED_SESSION_KEY_CACHE_MAX_ENTRIES = 2048;
const NORMALIZED_SESSION_KEY_CACHE_MAX_LENGTH = 4096;
const normalizedSessionKeyCache = new Map                ();
function writeNormalizedSessionKeyCache(raw        , normalized        )       {
  if (raw.length > NORMALIZED_SESSION_KEY_CACHE_MAX_LENGTH) {
    return;
  }
  normalizedSessionKeyCache.set(raw, normalized);
  if (normalizedSessionKeyCache.size > NORMALIZED_SESSION_KEY_CACHE_MAX_ENTRIES) {
    const oldest = normalizedSessionKeyCache.keys().next();
    if (!oldest.done) {
      normalizedSessionKeyCache.delete(oldest.value);
    }
  }
}
function collectCasePreservedSpans(raw        )                  {
  const spans                  = [];
  // matchAll clones the global matcher, so separate keys never share a cursor.
  for (const match of raw.matchAll(SIGNAL_GROUP_ID_PATTERN)) {
    const matched = match[0];
    const segment = match[2] ?? "";
    const segStart = match.index + matched.length - segment.length;
    // Segment spans match the legacy peerId.trim() behavior exactly.
    spans.push({ start: segStart, end: segStart + segment.length, trim: true });
  }
  // Nested/malformed ownership wrappers remain opaque; only the matcher owns their shape.
  const match = MATRIX_ROOM_KEY_PATTERN.exec(raw);
  if (!match || match[0].length >= raw.length) {
    return spans;
  }
  const tailStart = match[0].length;
  const tail = raw.slice(tailStart);
  const threadMarker = ":thread:";
  const markerIndex = normalizeLowercaseStringOrEmpty(tail).lastIndexOf(threadMarker);
  if (markerIndex === -1) {
    spans.push({ start: tailStart, end: raw.length, trim: false });
    return spans;
  }
  // Room/event bytes stay opaque; only the structural thread marker is folded.
  spans.push({ start: tailStart, end: tailStart + markerIndex, trim: false });
  const threadIdStart = tailStart + markerIndex + threadMarker.length;
  if (threadIdStart < raw.length) {
    spans.push({ start: threadIdStart, end: raw.length, trim: false });
  }
  return spans;
}
export function normalizeSessionKeyPreservingOpaquePeerIds(
  sessionKey                           ,
)         {
  const raw = normalizeOptionalString(sessionKey);
  if (!raw) {
    return "";
  }
  const cached = normalizedSessionKeyCache.get(raw);
  if (cached !== undefined) {
    return cached;
  }
  const folded = raw.toLowerCase();
  // Ordinary inventory keys are cheap to fold and would churn the bounded
  // opaque-key cache, repeatedly scanning deleted Map entries during eviction.
  if (!folded.includes("signal:") && !folded.includes("matrix:")) {
    return folded;
  }
  const spans = collectCasePreservedSpans(raw)
    .filter((span) => span.end > span.start)
    .toSorted((a, b) => a.start - b.start);

  let normalized = "";
  let cursor = 0;
  for (const span of spans) {
    if (span.start < cursor) {
      // Overlapping/contained in an already-emitted preserved range; skip.
      continue;
    }
    normalized += normalizeLowercaseStringOrEmpty(raw.slice(cursor, span.start));
    const preserved = raw.slice(span.start, span.end);
    normalized += span.trim ? preserved.trim() : preserved;
    cursor = span.end;
  }
  normalized += normalizeLowercaseStringOrEmpty(raw.slice(cursor));
  writeNormalizedSessionKeyCache(raw, normalized);
  return normalized;
}
export function parseAgentSessionKey(
  sessionKey                           ,
)                               {
  return parseAgentSessionKeyParts(normalizeSessionKeyPreservingOpaquePeerIds(sessionKey));
}
export { SIGNAL_GROUP_ID_PATTERN, MATRIX_ROOM_KEY_PATTERN, NORMALIZED_SESSION_KEY_CACHE_MAX_ENTRIES, NORMALIZED_SESSION_KEY_CACHE_MAX_LENGTH, normalizedSessionKeyCache, writeNormalizedSessionKeyCache, collectCasePreservedSpans };