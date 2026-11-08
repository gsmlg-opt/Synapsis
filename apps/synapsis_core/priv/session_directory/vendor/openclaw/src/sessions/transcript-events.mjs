import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
export function readSessionTranscriptRunId(message         )                     {
  return isRecord(message)
    ? normalizeOptionalString((asOptionalRecord(message["__openclaw"]) ?? {}).runId)
    : undefined;
}
export function readSessionTranscriptFailureRunId(entry         )                     {
  if (
    !isRecord(entry) ||
    (entry.type !== "custom_message" && entry.role !== "custom") ||
    entry.customType !== "run-failed-before-reply" ||
    !isRecord(entry.details)
  ) {
    return undefined;
  }
  return normalizeOptionalString(entry.details.runId);
}