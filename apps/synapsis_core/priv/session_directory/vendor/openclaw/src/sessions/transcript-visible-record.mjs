import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE } from "../agents/internal-runtime-context.mjs";
export function isVisibleTranscriptRecord(value         )                                   {
  const record = asOptionalRecord(value);
  return (
    Boolean(record?.message) ||
    record?.type === "compaction" ||
    record?.type === "reset" ||
    (record?.type === "custom_message" &&
      record.display === true &&
      record.customType !== OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE)
  );
}