import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { readStringField } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { extractHttpResponseBody } from "./http-error-response.mjs";
const ERROR_PAYLOAD_PREFIX_RE =
  /^(?:error|(?:[a-z][\w-]*\s+)?api\s*error|apierror|openai\s*error|anthropic\s*error|gateway\s*error|codex\s*error)(?:\s+\d{3})?[:\s-]+/i;
const HTTP_STATUS_DELIMITER_RE = /(?:\s*:\s*|\s+)/;
const HTTP_STATUS_CODE_PREFIX_RE = new RegExp(
  `^(?:http\\s*)?(\\d{3})(?:${HTTP_STATUS_DELIMITER_RE.source}([\\s\\S]+))?$`,
  "i",
);
const PROVIDER_WRAPPED_HTTP_STATUS_RE =
  /^(?:[a-z][\w-]*(?:\s+[a-z][\w-]*){0,3}\s+)?api\s*error\s*\((\d{3})\)(?:\s*:\s*([\s\S]*))?$/i;
const LABELED_HTTP_STATUS_RE =
  /^(?:status code|unexpected status|http status)\s*[:=]?\s*(\d{3})\b(?:\s*[:,]?\s*(?:message\s*:\s*)?([\s\S]*))?$/i;
const ERROR_STATUS_ENVELOPE_RE = /^error\s*[:,]\s*/i;
const HTML_ERROR_PREFIX_RE = /^\s*(?:<!doctype\s+html\b|<html\b)/i;
const HTML_CLOSE_RE = /<\/html>/i;
const CLOUDFLARE_HTML_ERROR_CODES = new Set([521, 522, 523, 524, 525, 526, 530]);
const STANDALONE_HTML_ERROR_HINT_RE =
  /\bcloudflare\b|cdn-cgi\/challenge-platform|challenge-error-text|enable javascript and cookies to continue|access denied|forbidden|service unavailable|bad gateway|web server is down|captcha|attention required/i;
const GENERIC_PROVIDER_INTERNAL_ERROR_RE = /an error occurred while processing your request/i;
const SUPPORT_REQUEST_ID_RE = /(?:request[\s_-]*id)\s*[:#]?\s*([a-z0-9][a-z0-9_-]{6,}[a-z0-9])/i;
export const CONTEXT_OVERFLOW_ERROR_MESSAGE =
  "Context overflow: prompt too large for the model. Try /reset (or /new) to start a fresh session, or use a larger-context model.";
export function formatProviderRefusalText(message   
                        
                      
 )                     {
  const refusal = Array.isArray(message.diagnostics)
    ? message.diagnostics.find(
        (diagnostic) => asOptionalRecord(diagnostic)?.type === "provider_refusal",
      )
    : undefined;
  if (!refusal) {
    // Older transcripts retain the code but have no review findings or continuation state.
    return message.errorCode === "misalignment_policy_violation"
      ? "The provider stopped this request as a safety precaution (misalignment)."
      : undefined;
  }
  const category = asOptionalRecord(asOptionalRecord(refusal)?.details)?.category;
  const safeCategory =
    typeof category === "string" && /^[a-z0-9_-]{1,64}$/i.test(category) ? category : undefined;
  if (safeCategory === "misalignment") {
    return "Chat stopped as a precaution. Review the findings in chat before continuing.";
  }
  return `The provider refused this request${safeCategory ? ` (category: ${safeCategory})` : ""}. Revise the request and try again.`;
}
function isErrorPayloadObject(payload         )                          {
  const record = asOptionalRecord(payload);
  if (!record) {
    return false;
  }
  if (record.type === "error") {
    return true;
  }
  if (typeof record.request_id === "string" || typeof record.requestId === "string") {
    return true;
  }
  const error = asOptionalRecord(record.error);
  return (
    [error?.message, error?.type, error?.code].some((value) => typeof value === "string") ||
    typeof record.error === "string"
  );
}
export function parseApiErrorPayload(raw         )                      {
  const trimmed = normalizeOptionalString(raw);
  if (!trimmed) {
    return null;
  }
  const candidate = trimmed.replace(ERROR_PAYLOAD_PREFIX_RE, "").trim();
  if (!candidate.startsWith("{") || !candidate.endsWith("}")) {
    return null;
  }
  try {
    const parsed = JSON.parse(candidate)           ;
    return isErrorPayloadObject(parsed) ? parsed : null;
  } catch {
    return null;
  }
}
function extractHttpStatusMatch(
  match                         ,
)                                        {
  if (!match) {
    return null;
  }
  const code = Number(match[1]);
  if (!Number.isInteger(code) || code < 100 || code > 599) {
    return null;
  }
  return { code, rest: (match[2] ?? "").trim() };
}
export function extractLeadingHttpStatus(raw        )                                        {
  return extractHttpStatusMatch(raw.match(HTTP_STATUS_CODE_PREFIX_RE));
}
export function extractProviderWrappedHttpStatus(
  raw        ,
)                                        {
  return extractHttpStatusMatch(raw.match(PROVIDER_WRAPPED_HTTP_STATUS_RE));
}
export function extractErrorHttpStatus(raw        )                                        {
  const candidate = raw.trim().replace(ERROR_STATUS_ENVELOPE_RE, "");
  return (
    extractLeadingHttpStatus(candidate) ??
    extractProviderWrappedHttpStatus(candidate) ??
    extractHttpStatusMatch(candidate.match(LABELED_HTTP_STATUS_RE))
  );
}
export function isCloudflareOrHtmlErrorPage(raw        )          {
  const trimmed = raw.trim();
  if (
    HTML_ERROR_PREFIX_RE.test(trimmed) &&
    HTML_CLOSE_RE.test(trimmed) &&
    STANDALONE_HTML_ERROR_HINT_RE.test(trimmed)
  ) {
    return true;
  }

  const status = extractHttpResponseBody(extractLeadingHttpStatus(trimmed));
  if (!status || status.code < 500) {
    return false;
  }

  if (CLOUDFLARE_HTML_ERROR_CODES.has(status.code)) {
    return true;
  }

  return (
    status.code < 600 && HTML_ERROR_PREFIX_RE.test(status.body) && HTML_CLOSE_RE.test(status.body)
  );
}
export function isGenericProviderInternalError(raw        )          {
  const trimmed = raw.trim();
  return (
    GENERIC_PROVIDER_INTERNAL_ERROR_RE.test(trimmed) &&
    (/help\.openai\.com/i.test(trimmed) || SUPPORT_REQUEST_ID_RE.test(trimmed))
  );
}
export function parseApiErrorInfo(raw         ) {
  const trimmed = normalizeOptionalString(raw);
  if (!trimmed) {
    return null;
  }

  let httpCode                    ;
  let candidate = trimmed;

  const httpPrefix = extractLeadingHttpStatus(candidate);
  if (httpPrefix) {
    httpCode = String(httpPrefix.code);
    candidate = httpPrefix.rest;
  }

  let payload = parseApiErrorPayload(candidate);
  if (!payload) {
    return null;
  }
  // A proxy can wrap the terminal upstream error in its ordered attempt history.
  for (let depth = 0; depth < 4; depth++) {
    const attempts          = asOptionalRecord(payload.error)?.attempts;
    const finalAttempt = Array.isArray(attempts) ? asOptionalRecord(attempts.at(-1)) : undefined;
    const details = finalAttempt?.details;
    if (!isErrorPayloadObject(details)) {
      break;
    }
    payload = details;
  }

  const error = asOptionalRecord(payload.error);
  const errorCode = readStringField(error, "code");
  const errorType = readStringField(error, "type");
  // A nested code also supplies the type when that type is blank or absent.
  const type = error
    ? errorCode !== undefined && !errorType
      ? errorCode
      : errorType
    : typeof payload.message === "string"
      ? readStringField(payload, "error")
      : undefined;
  const code = errorCode ?? readStringField(payload, "code");
  return {
    httpCode,
    type: type ?? readStringField(payload, "type"),
    ...(code === undefined ? {} : { code }),
    message:
      readStringField(error, "message") ??
      readStringField(payload, "message") ??
      readStringField(payload, "error"),
    requestId: readStringField(payload, "request_id") ?? readStringField(payload, "requestId"),
  };
}
const CONNECTION_FAILED_MESSAGE =
  "Couldn't connect to the AI service. Check your connection, then try again. For details, open Settings → Logs in the Control UI or run `openclaw logs --follow`.";
const TRANSPORT_ERRORS = [
  {
    code: /\beconnrefused\b/i,
    phrases: /connection refused|actively refused/i,
    message: CONNECTION_FAILED_MESSAGE,
  },
  {
    code: /\beconnreset\b|\beconnaborted\b|\benetreset\b|\bepipe\b/i,
    phrases: /socket hang up|connection reset|connection aborted/i,
    message:
      "Lost the connection to the AI service. Check the conversation before trying again. For details, open Settings → Logs in the Control UI or run `openclaw logs --follow`.",
  },
  {
    code: /\benotfound\b|\beai_again\b|\benetunreach\b|\behostunreach\b|\behostdown\b/i,
    phrases:
      /getaddrinfo|no such host|\bdns\b|network is unreachable|host is unreachable|fetch failed|connection error|network request failed/i,
    message: CONNECTION_FAILED_MESSAGE,
  },
];
export function formatTransportErrorCopy(raw        )                     {
  if (!raw || isCloudflareOrHtmlErrorPage(raw)) {
    return undefined;
  }
  for (const { code, phrases, message } of TRANSPORT_ERRORS) {
    if (code.test(raw) || phrases.test(raw)) {
      return message;
    }
  }
  if (raw.includes("网络错误") || raw.includes("网络异常") || raw.includes("连接错误")) {
    return CONNECTION_FAILED_MESSAGE;
  }
  return undefined;
}
export { ERROR_PAYLOAD_PREFIX_RE, HTTP_STATUS_DELIMITER_RE, HTTP_STATUS_CODE_PREFIX_RE, PROVIDER_WRAPPED_HTTP_STATUS_RE, LABELED_HTTP_STATUS_RE, ERROR_STATUS_ENVELOPE_RE, HTML_ERROR_PREFIX_RE, HTML_CLOSE_RE, CLOUDFLARE_HTML_ERROR_CODES, STANDALONE_HTML_ERROR_HINT_RE, GENERIC_PROVIDER_INTERNAL_ERROR_RE, SUPPORT_REQUEST_ID_RE, isErrorPayloadObject, extractHttpStatusMatch, CONNECTION_FAILED_MESSAGE, TRANSPORT_ERRORS };