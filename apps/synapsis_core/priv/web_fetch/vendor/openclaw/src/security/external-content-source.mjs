import { normalizeLowercaseStringOrEmpty } from "../../packages/normalization-core/src/string-coerce.mjs";

/** Hook session sources that carry untrusted external content into agent prompts. */
                                                                      

/**
 * Resolve a hook session key into its external content source.
 * Unknown `hook:*` sessions are treated as webhooks so legacy/custom hooks stay wrapped.
 */
export function resolveHookExternalContentSource(
  sessionKey        ,
)                                        {
  const normalized = normalizeLowercaseStringOrEmpty(sessionKey);
  if (normalized.startsWith("hook:gmail:")) {
    return "gmail";
  }
  if (normalized.startsWith("hook:")) {
    return "webhook";
  }
  return undefined;
}

/** Map hook session provenance to the prompt-facing external content source label. */
export function mapHookExternalContentSource(
  source                           ,
)                      {
  return source === "webhook" ? "webhook" : "email";
}

/** Return true when a session key should receive external-content prompt wrapping. */
export function isExternalHookSession(sessionKey        )          {
  return resolveHookExternalContentSource(sessionKey) !== undefined;
}
