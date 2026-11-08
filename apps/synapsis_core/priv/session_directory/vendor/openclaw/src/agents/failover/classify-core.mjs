import { inspectTlsCertificateError } from "../../../packages/ai/src/utils/tls-certificate-errors.mjs";
import { matchesContextOverflowMessage } from "../../../packages/ai/src/utils/overflow.mjs";
import { safeParseJsonRecord } from "../../../packages/normalization-core/src/json-coercion.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../../packages/normalization-core/src/string-coerce.mjs";
import { normalizeOptionalLowercaseString } from "../../../packages/normalization-core/src/string-coerce.mjs";
import { extractLeadingHttpStatus } from "../../shared/assistant-error-format.mjs";
import { isGenericProviderInternalError } from "../../shared/assistant-error-format.mjs";
import { parseApiErrorInfo } from "../../shared/assistant-error-format.mjs";
import { classifyOAuthRefreshFailure } from "../auth-profiles/oauth-refresh-failure.mjs";
import { isImageDimensionErrorMessage } from "../embedded-agent-helpers/image-errors.mjs";
import { isImageSizeError } from "../embedded-agent-helpers/image-errors.mjs";
import { isModelNotFoundErrorMessage } from "../live-model-errors.mjs";
import { classifyCoreFailoverReasonFromErrorType } from "./classification-rules.mjs";
import { classifyFailoverClassificationFromHttpStatus } from "./classification-rules.mjs";
import { classifyFailoverReasonFrom402Text } from "./classification-rules.mjs";
import { classifyFailoverReasonFromCode } from "./classification-rules.mjs";
import { failoverReasonFromClassification } from "./classification-rules.mjs";
import { inferSignalStatus } from "./classification-rules.mjs";
import { isClaudeCliAuthError } from "./classification-rules.mjs";
import { isExactUnknownNoDetailsError } from "./classification-rules.mjs";
import { isGenericUnknownStreamErrorMessage } from "./classification-rules.mjs";
import { isReplayInvalidErrorMessage } from "./classification-rules.mjs";
import { isUnsupportedImageInputErrorMessage } from "./classification-rules.mjs";
import { toPluginClassification } from "./classification-rules.mjs";
import { toReasonClassification } from "./classification-rules.mjs";
import { isContextOverflowErrorFromTables } from "./context-overflow-tables.mjs";
import { looksLikeProviderContextOverflowCandidate } from "./context-overflow-tables.mjs";
import { isAuthErrorMessage } from "./message-patterns.mjs";
import { isAuthPermanentErrorMessage } from "./message-patterns.mjs";
import { isBillingErrorMessage } from "./message-patterns.mjs";
import { isOverloadedErrorMessage } from "./message-patterns.mjs";
import { isPeriodicUsageLimitErrorMessage } from "./message-patterns.mjs";
import { isProviderCompletedErrorFinishReasonMessage } from "./message-patterns.mjs";
import { isRateLimitErrorMessage } from "./message-patterns.mjs";
import { isServerErrorMessage } from "./message-patterns.mjs";
import { isSessionTranscriptValidationErrorMessage } from "./message-patterns.mjs";
import { isTimeoutErrorMessage } from "./message-patterns.mjs";
import { matchesFormatErrorPattern } from "./message-patterns.mjs";
import { resolveExecutionApprovalFailureMessage } from "./message-patterns.mjs";
const HTML_BODY_RE = /^\s*(?:<!doctype\s+html\b|<html\b)/i;
const HTML_CLOSE_RE = /<\/html>/i;
function isHtmlErrorResponse(raw        )          {
  const candidate = raw
    .trim()
    .replace(/^error:\s*/i, "")
    .trim();
  const rest = extractLeadingHttpStatus(candidate)?.rest ?? candidate;
  return HTML_BODY_RE.test(rest) && HTML_CLOSE_RE.test(rest);
}
const PRIORITY_MESSAGE_CLASSIFIERS                
                                                                        
  = [
  [isUnsupportedImageInputErrorMessage, "format"],
  [isClaudeCliAuthError, "auth"],
  [isSessionTranscriptValidationErrorMessage, "format"],
  [isCliSessionExpiredErrorMessage, "session_expired"],
  [isModelNotFoundErrorMessage, "model_not_found"],
  [(raw) => /\bworkers_ai\b.*\bquota limit exceeded\b/i.test(raw), "rate_limit"],
  [(raw) => /\bmodelnotreadyexception\b/i.test(raw), "overloaded"],
  // Groq does not currently ship a bundled provider hook.
  [(raw) => /model(?:_is)?_deactivated|model has been deactivated/i.test(raw), "model_not_found"],
];
const GENERAL_MESSAGE_CLASSIFIERS                
                                                     
  = [
  [isRateLimitErrorMessage, "rate_limit"],
  [isOverloadedErrorMessage, "overloaded"],
  // A provider-completed error is not a hang; preserve server-error copy and failover.
  [isProviderCompletedErrorFinishReasonMessage, "server_error"],
  [
    (raw) =>
      isStructuredServerErrorMessage(raw) &&
      !isBillingErrorMessage(raw) &&
      !isAuthPermanentErrorMessage(raw) &&
      !isAuthErrorMessage(raw),
    "server_error",
  ],
  [isGenericProviderInternalError, "timeout"],
  // Auth precedes broad api_error matching, which can also wrap invalid credentials.
  [(raw) => Boolean(classifyOAuthRefreshFailure(raw)?.reason), "auth_permanent"],
  [isAuthPermanentErrorMessage, "auth_permanent"],
  [isAuthErrorMessage, "auth"],
  [
    (raw) =>
      isGenericUnknownStreamErrorMessage(raw) ||
      isServerErrorMessage(raw) ||
      isJsonApiInternalServerError(raw),
    "timeout",
  ],
  [isCloudCodeAssistFormatError, "format"],
  [isExactUnknownNoDetailsError, "no_error_details"],
  [isTimeoutErrorMessage, "timeout"],
  [(raw) => matchesContextOverflowMessage(raw, "assistant-error"), "context_overflow"],
];
function isTransportHtmlErrorStatus(status                    )          {
  return (
    status === 408 || status === 499 || (status !== undefined && status >= 500 && status < 600)
  );
}
function classifyFailoverClassificationFromMessage(
  raw        ,
  provider         ,
  errorType         ,
)                                {
  if (isImageDimensionErrorMessage(raw) || isImageSizeError(raw)) {
    return null;
  }
  const priorityReason = PRIORITY_MESSAGE_CLASSIFIERS.find(([matches]) =>
    matches(raw, provider),
  )?.[1];
  if (priorityReason) {
    return toReasonClassification(priorityReason);
  }
  if (isContextOverflowErrorFromTables(raw)) {
    return { kind: "context_overflow" };
  }
  if (isReplayInvalidErrorMessage(raw)) {
    return toReasonClassification("format");
  }
  const reasonFrom402Text = classifyFailoverReasonFrom402Text(raw);
  if (reasonFrom402Text) {
    return toReasonClassification(reasonFrom402Text);
  }
  const leadingStatus = extractLeadingHttpStatus(raw.trim());
  if (leadingStatus?.code !== 429 && isBillingErrorMessage(raw)) {
    return toReasonClassification("billing");
  }
  if (isPeriodicUsageLimitErrorMessage(raw)) {
    return toReasonClassification(isBillingErrorMessage(raw) ? "billing" : "rate_limit");
  }
  const generalReason = GENERAL_MESSAGE_CLASSIFIERS.find(([matches]) => matches(raw))?.[1];
  if (generalReason) {
    return toPluginClassification(generalReason);
  }
  // Inspect raw and SDK-preserved types before the generic HTTP fallback, but
  // after more-specific text so invalid-request wrappers cannot hide an outage.
  const apiErrorReason = classifyCoreFailoverReasonFromErrorType(
    parseApiErrorInfo(raw)?.type ?? errorType,
  );
  if (apiErrorReason) {
    return toReasonClassification(apiErrorReason);
  }
  return classifyFailoverClassificationFromHttpStatus(
    inferSignalStatus({ message: raw }),
    raw,
    null,
    undefined,
    provider,
  );
}
function classifyFailoverDetailCandidates(
  details                               ,
  provider                    ,
)                                {
  for (const detail of details ?? []) {
    const classification = classifyFailoverClassificationFromMessage(detail, provider);
    if (classification) {
      return classification;
    }
  }
  return null;
}
function mergeMessageAndDetailClassification(
  messageClassification                               ,
  detailClassification                               ,
)                                {
  if (!messageClassification || !detailClassification) {
    return messageClassification ?? detailClassification;
  }
  if (messageClassification.kind === "context_overflow") {
    return messageClassification;
  }
  return detailClassification.kind === "context_overflow" ||
    (detailClassification.reason === "billing" && messageClassification.reason === "rate_limit") ||
    messageClassification.reason === "format"
    ? detailClassification
    : messageClassification;
}
function hasIndependentTransientMessage(
  raw                    ,
  reason                ,
  provider                    ,
)          {
  const text = raw && (extractLeadingHttpStatus(raw)?.rest ?? raw);
  const info = parseApiErrorInfo(text);
  const payload = !info && text ? safeParseJsonRecord(text) : null;
  const prose = info
    ? info.message
    : payload
      ? typeof payload.message === "string"
        ? payload.message
        : undefined
      : text;
  return Boolean(
    prose &&
    classifyFailoverReasonFromCode(prose) !== reason &&
    failoverReasonFromClassification(classifyFailoverClassificationFromMessage(prose, provider)) ===
      reason,
  );
}
export function classifyFailoverSignalCore(
  signal                ,
  classifyProviderError                          ,
)                                {
  if (resolveExecutionApprovalFailureMessage(signal.message)) {
    return null;
  }
  const inferredStatus = inferSignalStatus(signal);
  const explicitStatus = Number.isFinite(signal.status) ? signal.status : undefined;
  const messageClassification = signal.message
    ? classifyFailoverClassificationFromMessage(signal.message, signal.provider, signal.errorType)
    : null;
  const detailClassification = classifyFailoverDetailCandidates(signal.details, signal.provider);
  const messageOrDetailClassification = mergeMessageAndDetailClassification(
    messageClassification,
    detailClassification,
  );
  const errorTypeReason = classifyCoreFailoverReasonFromErrorType(signal.errorType);
  const errorTypeClassification = errorTypeReason ? toReasonClassification(errorTypeReason) : null;
  // Provider-attributed 401/403/429 text is ambiguous enough to consult only the
  // scoped owner hook. Passing the inferred status also fences unresolved ids
  // from the descriptor-free broad scan in provider-runtime.
  const providerHookStatus =
    explicitStatus ??
    (signal.provider && (inferredStatus === 401 || inferredStatus === 403 || inferredStatus === 429)
      ? inferredStatus
      : undefined);
  // Pure table matches are also the cheap runtime-load gate. Structured,
  // context-shaped, and otherwise-unclassified signals still consult the
  // provider once; its result remains authoritative over the prepared tables.
  const hasProviderHookSignal = Boolean(
    signal.message || signal.code || signal.errorType || inferredStatus !== undefined,
  );
  const hasStructuredDescriptor =
    providerHookStatus !== undefined || signal.code !== undefined || signal.errorType !== undefined;
  const hasContextCandidate = Boolean(
    signal.message && looksLikeProviderContextOverflowCandidate(signal.message),
  );
  const shouldConsultProviderPlugin =
    hasProviderHookSignal &&
    (hasStructuredDescriptor || hasContextCandidate || !messageClassification);
  let providerPluginReason                        = null;
  if (shouldConsultProviderPlugin) {
    const context = {
      errorMessage: signal.message ?? "",
      provider: signal.provider,
      status: providerHookStatus,
      code: signal.code,
      errorType: signal.errorType,
    };
    providerPluginReason = classifyProviderError?.(context) ?? null;
  }
  const tlsCertificateError = inspectTlsCertificateError(signal);
  if (!providerPluginReason && tlsCertificateError && inferredStatus === undefined) {
    return toReasonClassification("tls_certificate");
  }
  if (
    !providerPluginReason &&
    signal.message &&
    isTransportHtmlErrorStatus(inferredStatus) &&
    isHtmlErrorResponse(signal.message)
  ) {
    // CDN page text is not a provider signal; classify its HTTP status through the shared owner.
    return classifyFailoverClassificationFromHttpStatus(
      inferredStatus,
      undefined,
      null,
      signal.status,
      signal.provider,
    );
  }
  // Message/detail semantics stay ahead of generic structured types so an
  // invalid-request wrapper cannot hide billing, context, or provider policy.
  const codeReason =
    classifyFailoverReasonFromCode(signal.code) ??
    classifyFailoverReasonFromCode(parseApiErrorInfo(signal.message)?.code);
  // A validation code identifies the rejected operation; arbitrary parameter
  // text must not turn it into an unrelated failure through message matching.
  const effectiveMessageClassification = providerPluginReason
    ? toPluginClassification(providerPluginReason)
    : codeReason === "format"
      ? toReasonClassification("format")
      : mergeMessageAndDetailClassification(
          messageOrDetailClassification ?? errorTypeClassification,
          codeReason ? toReasonClassification(codeReason) : null,
        );
  if (codeReason === "auth_permanent") {
    return toReasonClassification(codeReason);
  }
  const statusClassification = classifyFailoverClassificationFromHttpStatus(
    inferredStatus,
    signal.message,
    effectiveMessageClassification,
    signal.status,
    signal.provider,
    { preserveProviderSignalClassification: providerPluginReason !== null },
  );
  const classification =
    statusClassification ??
    (codeReason ? toReasonClassification(codeReason) : effectiveMessageClassification);
  if (
    !providerPluginReason &&
    inferredStatus !== undefined &&
    inferredStatus >= 400 &&
    inferredStatus < 500 &&
    inferredStatus !== 408 &&
    inferredStatus !== 409 &&
    inferredStatus !== 410 &&
    inferredStatus !== 429 &&
    inferredStatus !== 499 &&
    classification?.kind === "reason" &&
    classification.reason === codeReason &&
    (codeReason === "rate_limit" || codeReason === "overloaded" || codeReason === "timeout")
  ) {
    // Inspect prose, not the JSON code that supplied the presentation reason.
    // Bedrock throttling text and provider-owned decisions remain retryable.
    const info = parseApiErrorInfo(signal.message);
    const hasTransientProse =
      hasIndependentTransientMessage(signal.message, codeReason, signal.provider) ||
      signal.details?.some((detail) =>
        hasIndependentTransientMessage(detail, codeReason, signal.provider),
      );
    if (!hasTransientProse && !/^throttling_?exception$/i.test(signal.code ?? info?.code ?? "")) {
      return { ...classification, sameModelRetry: false };
    }
  }
  return classification;
}
export function isCloudCodeAssistFormatError(raw        )          {
  return !isImageDimensionErrorMessage(raw) && matchesFormatErrorPattern(raw);
}
const API_ERROR_TRANSIENT_SIGNALS_RE =
  /internal server error|overload|temporarily unavailable|service unavailable|unknown error|server error|bad gateway|gateway timeout|upstream error|backend error|try again later|temporarily.+unable|unexpected error/i;
function isJsonApiInternalServerError(raw        )          {
  const value = normalizeLowercaseStringOrEmpty(raw);
  // Providers wrap transient 5xx errors in JSON payloads like:
  // {"type":"error","error":{"type":"api_error","message":"Internal server error"}}
  // Non-standard providers (e.g. MiniMax) may use different message text:
  // {"type":"api_error","message":"unknown error, 520 (1000)"}
  if (!value.includes('"type":"api_error"')) {
    return false;
  }
  // Leading 429 wrappers defer billing classification to the HTTP policy below.
  if (isBillingErrorMessage(raw)) {
    return false;
  }
  // Only match when the message contains a transient signal. api_error payloads
  // with non-transient messages (e.g. context overflow, schema validation) should
  // fall through to more specific classifiers or remain unclassified.
  return API_ERROR_TRANSIENT_SIGNALS_RE.test(raw);
}
function isStructuredServerErrorMessage(raw        )          {
  const parsedType = normalizeOptionalLowercaseString(parseApiErrorInfo(raw)?.type);
  if (parsedType === "server_error" || parsedType === "upstream_error") {
    return true;
  }
  const value = normalizeLowercaseStringOrEmpty(raw);
  return (
    value.includes('"type":"server_error"') ||
    value.includes('"code":"server_error"') ||
    value.includes('"type":"upstream_error"') ||
    value.includes('"code":"upstream_error"')
  );
}
function isCliSessionExpiredErrorMessage(raw        )          {
  return /\b(?:session (?:not found|does not exist|expired|invalid)|conversation (?:not found|does not exist|expired|invalid)|no conversation found|no such session|invalid session|(?:session|conversation) id not found)\b/.test(
    normalizeLowercaseStringOrEmpty(raw),
  );
}
export { HTML_BODY_RE, HTML_CLOSE_RE, isHtmlErrorResponse, PRIORITY_MESSAGE_CLASSIFIERS, GENERAL_MESSAGE_CLASSIFIERS, isTransportHtmlErrorStatus, classifyFailoverClassificationFromMessage, classifyFailoverDetailCandidates, mergeMessageAndDetailClassification, hasIndependentTransientMessage, API_ERROR_TRANSIENT_SIGNALS_RE, isJsonApiInternalServerError, isStructuredServerErrorMessage, isCliSessionExpiredErrorMessage };