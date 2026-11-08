import { matchesContextOverflowMessage } from "../../../packages/ai/src/utils/overflow.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../../packages/normalization-core/src/string-coerce.mjs";
import { isProviderRequestSizeCeilingError } from "./message-patterns.mjs";
import { isRateLimitErrorMessage } from "./message-patterns.mjs";
const PROVIDER_CONTEXT_OVERFLOW_SIGNAL_RE =
  /\b(?:context|window|prompt|token|tokens|input|request|model)\b/i;
const PROVIDER_CONTEXT_OVERFLOW_ACTION_RE =
  /\b(?:too\s+(?:large|long|many)|exceed(?:s|ed|ing)?|overflow|limit|maximum|max)\b/i;
export function looksLikeProviderContextOverflowCandidate(errorMessage        )          {
  return (
    !isRateLimitErrorMessage(errorMessage) &&
    PROVIDER_CONTEXT_OVERFLOW_SIGNAL_RE.test(errorMessage) &&
    PROVIDER_CONTEXT_OVERFLOW_ACTION_RE.test(errorMessage)
  );
}
export function isReasoningConstraintErrorMessage(raw        )          {
  if (!raw) {
    return false;
  }
  const lower = normalizeLowercaseStringOrEmpty(raw);
  return (
    lower.includes("reasoning is mandatory") ||
    lower.includes("reasoning is required") ||
    lower.includes("requires reasoning") ||
    (lower.includes("reasoning") && lower.includes("cannot be disabled"))
  );
}
export function hasRateLimitTpmHint(raw        )          {
  return matchesContextOverflowMessage(raw, "tpm-rate-limit-hint");
}
export function isContextOverflowErrorFromTables(errorMessage         )          {
  if (!errorMessage) {
    return false;
  }
  // Groq uses 413 for TPM (tokens per minute) limits, which is a rate limit, not context
  // overflow — unless the request alone exceeds the whole limit, which no wait can satisfy.
  if (
    (hasRateLimitTpmHint(errorMessage) && !isProviderRequestSizeCeilingError(errorMessage)) ||
    isReasoningConstraintErrorMessage(errorMessage)
  ) {
    return false;
  }

  return (
    matchesContextOverflowMessage(errorMessage, "failover-explicit") ||
    (looksLikeProviderContextOverflowCandidate(errorMessage) &&
      matchesContextOverflowMessage(errorMessage, "provider-fallback"))
  );
}
export { PROVIDER_CONTEXT_OVERFLOW_SIGNAL_RE, PROVIDER_CONTEXT_OVERFLOW_ACTION_RE };