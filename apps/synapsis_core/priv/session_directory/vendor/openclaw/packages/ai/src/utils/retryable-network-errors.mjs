import { collectNestedErrorCandidates } from "../../../normalization-core/src/error-coercion.mjs";
import { extractErrorCodeOrErrno } from "../../../normalization-core/src/error-coercion.mjs";
import { readErrorName } from "../../../normalization-core/src/error-coercion.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../../normalization-core/src/string-coerce.mjs";
export const WEBSOCKET_NON_RETRYABLE_CLOSE_ERROR_CODE = "ERR_WEBSOCKET_NON_RETRYABLE_CLOSE";
const TRANSIENT_NETWORK_CODES = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ENOTFOUND",
  "ETIMEDOUT",
  "ESOCKETTIMEDOUT",
  "ECONNABORTED",
  "EPIPE",
  "ENETDOWN",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EADDRNOTAVAIL",
  "EAI_AGAIN",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_DNS_RESOLVE_FAILED",
  "UND_ERR_CONNECT",
  "UND_ERR_SOCKET",
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_BODY_TIMEOUT",
  "ERR_HTTP2_INVALID_SESSION",
  "EPROTO",
  "ERR_SSL_WRONG_VERSION_NUMBER",
  "ERR_SSL_PROTOCOL_RETURNED_AN_ERROR",
  "ERR_WEBSOCKET_TRANSPORT",
]);
const TRANSIENT_NETWORK_ERROR_NAMES = new Set([
  "AbortError",
  "ConnectTimeoutError",
  "HeadersTimeoutError",
  "BodyTimeoutError",
  "TimeoutError",
]);
const TRANSIENT_NETWORK_MESSAGE_CODE_RE =
  /\b(ECONNRESET|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|ESOCKETTIMEDOUT|ECONNABORTED|EPIPE|ENETDOWN|EHOSTUNREACH|ENETUNREACH|EADDRNOTAVAIL|EAI_AGAIN|EPROTO|UND_ERR_CONNECT_TIMEOUT|UND_ERR_DNS_RESOLVE_FAILED|UND_ERR_CONNECT|UND_ERR_SOCKET|UND_ERR_HEADERS_TIMEOUT|UND_ERR_BODY_TIMEOUT|ERR_HTTP2_INVALID_SESSION)\b/i;
const TRANSIENT_NETWORK_MESSAGE_SNIPPETS = [
  "getaddrinfo",
  "socket hang up",
  "client network socket disconnected before secure tls connection was established",
  "network error",
  "network is unreachable",
  "temporary failure in name resolution",
  "upstream connect error",
  "disconnect/reset before headers",
  "tlsv1 alert",
  "ssl routines",
  "packet length too long",
  "write eproto",
];
function isWrappedFetchFailedMessage(message        )          {
  // Keep wrapped variants (for example "...: fetch failed") while avoiding broad
  // matches like "Web fetch failed (404): ..." that are not transport failures.
  return message === "fetch failed" || /:\s*fetch failed$/.test(message);
}
export function isTransientNetworkError(err         )          {
  if (!err) {
    return false;
  }
  const candidates = collectNestedErrorCandidates(err);
  if (
    candidates.some(
      (candidate) =>
        extractErrorCodeOrErrno(candidate) === WEBSOCKET_NON_RETRYABLE_CLOSE_ERROR_CODE,
    )
  ) {
    return false;
  }
  for (const candidate of candidates) {
    const code = extractErrorCodeOrErrno(candidate);
    if (code && TRANSIENT_NETWORK_CODES.has(code)) {
      return true;
    }

    const name = readErrorName(candidate);
    if (name && TRANSIENT_NETWORK_ERROR_NAMES.has(name)) {
      return true;
    }

    if (!candidate || typeof candidate !== "object") {
      continue;
    }
    // SAFETY: Only object-shaped error graph nodes reach this optional message read.
    const message = normalizeLowercaseStringOrEmpty((candidate                         ).message);
    if (!message) {
      continue;
    }
    if (
      TRANSIENT_NETWORK_MESSAGE_CODE_RE.test(message) ||
      isWrappedFetchFailedMessage(message) ||
      TRANSIENT_NETWORK_MESSAGE_SNIPPETS.some((snippet) => message.includes(snippet))
    ) {
      return true;
    }
  }

  return false;
}
export { TRANSIENT_NETWORK_CODES, TRANSIENT_NETWORK_ERROR_NAMES, TRANSIENT_NETWORK_MESSAGE_CODE_RE, TRANSIENT_NETWORK_MESSAGE_SNIPPETS, isWrappedFetchFailedMessage };