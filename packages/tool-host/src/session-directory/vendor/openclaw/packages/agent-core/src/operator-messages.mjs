import { asOptionalRecord } from "../../normalization-core/src/record-coerce.mjs";
export const SYSTEM_UPDATE_MESSAGE_CUSTOM_TYPE = "openclaw.system-update";
export function getOpenClawSystemUpdateKind(value         ) {
  const entry = asOptionalRecord(value);
  const message = entry?.type === "message" ? asOptionalRecord(entry.message) : entry;
  if (
    !message ||
    (message.role !== "custom" && message.type !== "custom_message") ||
    message.customType !== SYSTEM_UPDATE_MESSAGE_CUSTOM_TYPE
  ) {
    return undefined;
  }
  const kind = asOptionalRecord(message.details)?.kind;
  return kind === "prompt-update" || kind === "runtime-context" ? kind : undefined;
}