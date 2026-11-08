import { compileSafeRegexDetailed } from "./safe-regex.mjs";
function normalizeRejectReason(result                        )                                 {
  if (result.reason === null || result.reason === "empty") {
    return null;
  }
  return result.reason;
}
export function compileConfigRegex(pattern        , flags = "")                             {
  const result = compileSafeRegexDetailed(pattern, flags);
  // Blank config entries are absence, not rejection diagnostics.
  if (result.reason === "empty") {
    return null;
  }
  return {
    regex: result.regex,
    pattern: result.source,
    flags: result.flags,
    reason: normalizeRejectReason(result),
  }                       ;
}
export { normalizeRejectReason };