import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
export function readRunFailureNotice(message         )                               {
  const notice = asOptionalRecord(asOptionalRecord(message)?.openclawRunError);
  if (
    typeof notice?.runId !== "string" ||
    !notice.runId.trim() ||
    typeof notice.summary !== "string" ||
    !notice.summary.trim()
  ) {
    return undefined;
  }
  return { runId: notice.runId, summary: notice.summary };
}