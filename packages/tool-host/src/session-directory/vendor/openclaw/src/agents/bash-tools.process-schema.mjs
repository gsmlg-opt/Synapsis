import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
export function isProcessPollResultDetails(value         )          {
  const details = asOptionalRecord(value);
  return Boolean(
    details &&
    typeof details.sessionId === "string" &&
    (details.status === "running" || details.status === "completed") &&
    (typeof details.aggregated === "string" ||
      (details.persistedDetailsTruncated === true &&
        Array.isArray(details.originalDetailKeys) &&
        details.originalDetailKeys.includes("aggregated"))),
  );
}