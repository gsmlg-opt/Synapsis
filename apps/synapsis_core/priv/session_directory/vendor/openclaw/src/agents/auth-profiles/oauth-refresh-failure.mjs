import { normalizeProviderId } from "../../../packages/model-catalog-core/src/provider-id.mjs";
import { sanitizeForLog } from "../../../packages/terminal-core/src/ansi.mjs";
const OAUTH_REFRESH_FAILURE_PROVIDER_RE = /OAuth token refresh failed for ([^:]+):/i;
const SAFE_PROVIDER_ID_RE = /^[a-z0-9][a-z0-9._-]*$/;
const CLAUDE_CLI_AUTH_FAILURE_RE =
  /\bclaude-cli\b.+?\b(failed to authenticate|401\s+invalid authentication credentials)\b/is;
function isClaudeCliExpiredOAuthMessage(message        )          {
  return CLAUDE_CLI_AUTH_FAILURE_RE.test(message);
}
function isOAuthRefreshFailureMessage(message        )          {
  const lower = message.toLowerCase();
  return (
    lower.includes("oauth token refresh failed") ||
    lower.includes("access token could not be refreshed") ||
    lower.includes("authentication session could not be refreshed automatically") ||
    isClaudeCliExpiredOAuthMessage(message)
  );
}
function extractOAuthRefreshFailureProvider(message        )                {
  if (isClaudeCliExpiredOAuthMessage(message)) {
    // The message was produced by the claude-cli subprocess; the provider is
    // statically known — no need to parse it from the error text.
    return "claude-cli";
  }
  const provider = message.match(OAUTH_REFRESH_FAILURE_PROVIDER_RE)?.[1]?.trim();
  return provider && provider.length > 0 ? provider : null;
}
function sanitizeOAuthRefreshFailureProvider(provider                           )                {
  // Only return normalized provider ids that are safe to embed in shell guidance.
  const sanitized = provider ? sanitizeForLog(provider).replaceAll("`", "").trim() : "";
  const normalized = normalizeProviderId(sanitized);
  return normalized && SAFE_PROVIDER_ID_RE.test(normalized) ? normalized : null;
}
export function classifyOAuthRefreshFailureReason(
  message        ,
)                                   {
  const lower = message.toLowerCase();
  return (
    OAUTH_REFRESH_REASON_SIGNALS.find(([, signals]) =>
      signals.some((signal) => lower.includes(signal)),
    )?.[0] ?? (isClaudeCliExpiredOAuthMessage(message) ? "revoked" : null)
  );
}
const OAUTH_REFRESH_REASON_SIGNALS                
                                                         
  = [
  ["refresh_token_reused", ["refresh_token_reused"]],
  ["expired", ["refresh_token_expired"]],
  ["invalid_grant", ["invalid_grant"]],
  ["token_invalidated", ["token_invalidated"]],
  ["sign_in_again", ["sign_in_again", "signing in again", "sign in again", "log in again"]],
  ["invalid_refresh_token", ["invalid_refresh_token", "invalid refresh token"]],
  ["revoked", ["revoked"]],
];
export function classifyOAuthRefreshFailure(message        )                             {
  if (!isOAuthRefreshFailureMessage(message)) {
    return null;
  }
  return {
    provider: sanitizeOAuthRefreshFailureProvider(extractOAuthRefreshFailureProvider(message)),
    reason: classifyOAuthRefreshFailureReason(message),
  };
}
export { OAUTH_REFRESH_FAILURE_PROVIDER_RE, SAFE_PROVIDER_ID_RE, CLAUDE_CLI_AUTH_FAILURE_RE, isClaudeCliExpiredOAuthMessage, isOAuthRefreshFailureMessage, extractOAuthRefreshFailureProvider, sanitizeOAuthRefreshFailureProvider, OAUTH_REFRESH_REASON_SIGNALS };