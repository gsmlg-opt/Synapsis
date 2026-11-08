import { normalizeLowercaseStringOrEmpty } from "../../normalization-core/src/string-coerce.mjs";
export function normalizeProviderId(provider        )         {
  return normalizeLowercaseStringOrEmpty(provider);
}