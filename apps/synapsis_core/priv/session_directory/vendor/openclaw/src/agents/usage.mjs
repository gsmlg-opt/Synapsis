import { asFiniteNumber } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
const normalizeTokenCount = (value         )                     => {
  const numeric = asFiniteNumber(value);
  return numeric === undefined
    ? undefined
    : Math.min(Math.max(0, Math.trunc(numeric)), Number.MAX_SAFE_INTEGER);
};
export function normalizeContextUsage(value         )                           {
  const raw = asOptionalRecord(value);
  if (raw?.state !== "available") {
    return raw?.state === "unavailable" ? { state: "unavailable" } : undefined;
  }
  const promptTokens = normalizeTokenCount(raw.promptTokens);
  const totalTokens = normalizeTokenCount(raw.totalTokens);
  return promptTokens !== undefined && totalTokens !== undefined && totalTokens >= promptTokens
    ? { state: "available", promptTokens, totalTokens }
    : undefined;
}
export { normalizeTokenCount };