import { normalizeLowercaseStringOrEmpty } from "../../normalization-core/src/string-coerce.mjs";
const SENSITIVE_URL_QUERY_PARAM_NAMES = new Set([
  "token",
  "key",
  "api_key",
  "apikey",
  "secret",
  "access_token",
  "auth_token",
  "password",
  "pass",
  "passwd",
  "auth",
  "jwt",
  "session",
  "id_token",
  "code",
  "client_secret",
  "app_secret",
  "hook_token",
  "refresh_token",
  "signature",
  "x_amz_signature",
  "x_amz_security_token",
  "private_key",
  "credential",
  "authorization",
  // Common signed/API gateway aliases that do not contain an existing secret-name marker.
  "sig",
  "x_api_key",
  "x_access_token",
  "x_auth_token",
]);
const URL_QUERY_NAME_SEPARATOR_RE = /[\p{C}\p{Z}\u115F\u1160\u3164\uFFA0+]/gu;
const SUFFIXED_OR_SCOPED_TOKEN_QUERY_PARAM_RE = /(?:^|_)token(?:_[a-f0-9]{16,})?$/u;
const MAX_NESTED_URL_REDACTION_DEPTH = 8;
function normalizeUrlQueryParamName(name        )   
                
                              
  {
  let current = name.replace(URL_QUERY_NAME_SEPARATOR_RE, "");
  for (let depth = 0; depth <= MAX_NESTED_URL_REDACTION_DEPTH; depth += 1) {
    let decoded        ;
    try {
      decoded = decodeURIComponent(current).replace(URL_QUERY_NAME_SEPARATOR_RE, "");
    } catch {
      break;
    }
    if (decoded === current) {
      return {
        value: normalizeLowercaseStringOrEmpty(current).replaceAll("-", "_"),
        unresolvedEncoding: false,
      };
    }
    current = decoded;
  }
  return {
    value: normalizeLowercaseStringOrEmpty(current).replaceAll("-", "_"),
    unresolvedEncoding: current.includes("%"),
  };
}
export function isSensitiveUrlQueryParamName(name        )          {
  const normalized = normalizeUrlQueryParamName(name);
  return (
    normalized.unresolvedEncoding ||
    SENSITIVE_URL_QUERY_PARAM_NAMES.has(normalized.value) ||
    SUFFIXED_OR_SCOPED_TOKEN_QUERY_PARAM_RE.test(normalized.value)
  );
}
export { SENSITIVE_URL_QUERY_PARAM_NAMES, URL_QUERY_NAME_SEPARATOR_RE, SUFFIXED_OR_SCOPED_TOKEN_QUERY_PARAM_RE, MAX_NESTED_URL_REDACTION_DEPTH, normalizeUrlQueryParamName };