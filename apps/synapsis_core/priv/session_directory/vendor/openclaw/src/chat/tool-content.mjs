import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
const TOOL_USE_ID_FIELDS = [
  "id",
  "tool_call_id",
  "toolCallId",
  "tool_use_id",
  "toolUseId",
]         ;
function normalizeToolContentType(value         )         {
  return typeof value === "string" ? value.toLowerCase() : "";
}
export function isToolCallContentType(value         )          {
  const type = normalizeToolContentType(value);
  return type === "toolcall" || type === "tool_call" || type === "tooluse" || type === "tool_use";
}
export function isToolResultContentType(value         )          {
  const type = normalizeToolContentType(value);
  return type === "toolresult" || type === "tool_result";
}
export function resolveToolUseId(block                  )                     {
  for (const field of TOOL_USE_ID_FIELDS) {
    const id = normalizeOptionalString(block[field]);
    if (id) {
      return id;
    }
  }
  return undefined;
}
export function readToolErrorFlag(value                         )                      {
  const raw = value.isError ?? value.is_error;
  return typeof raw === "boolean" ? raw : undefined;
}
export { TOOL_USE_ID_FIELDS, normalizeToolContentType };