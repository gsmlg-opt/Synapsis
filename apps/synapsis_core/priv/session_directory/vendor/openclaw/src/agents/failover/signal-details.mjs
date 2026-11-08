import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { truncateUtf16Safe } from "../../../packages/normalization-core/src/utf16-slice.mjs";
const MAX_FAILOVER_DETAIL_CANDIDATES = 12;
const MAX_FAILOVER_DETAIL_CHARS = 1_000;
function collectFailoverDetailCandidates(
  value         ,
  candidates          ,
  seen             ,
)       {
  if (candidates.length >= MAX_FAILOVER_DETAIL_CANDIDATES) {
    return;
  }
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    const normalized = truncateUtf16Safe(String(value).trim(), MAX_FAILOVER_DETAIL_CHARS);
    if (normalized && !candidates.includes(normalized)) {
      candidates.push(normalized);
    }
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
        try {
          collectFailoverDetailCandidates(JSON.parse(trimmed)           , candidates, seen);
        } catch {
          // Non-JSON detail strings are still useful as direct classifier candidates.
        }
      }
    }
    return;
  }
  const record = asOptionalRecord(value);
  if (!record || seen.has(record)) {
    return;
  }
  seen.add(record);
  for (const key of ["message", "param", "code", "type", "error", "detail", "body"]) {
    collectFailoverDetailCandidates(record[key], candidates, seen);
    if (candidates.length >= MAX_FAILOVER_DETAIL_CANDIDATES) {
      return;
    }
  }
}
export function extractFailoverSignalDetails(...values           )                       {
  const candidates           = [];
  const seen = new Set        ();
  for (const value of values) {
    collectFailoverDetailCandidates(value, candidates, seen);
    if (candidates.length >= MAX_FAILOVER_DETAIL_CANDIDATES) {
      break;
    }
  }
  return candidates.length > 0 ? candidates : undefined;
}
export { MAX_FAILOVER_DETAIL_CANDIDATES, MAX_FAILOVER_DETAIL_CHARS, collectFailoverDetailCandidates };