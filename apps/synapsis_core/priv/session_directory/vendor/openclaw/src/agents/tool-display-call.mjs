import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
const TOOL_CALL_DISPLAY_NAMES = new Set(["dispatch_action", "tool_call"]);
export function unwrapToolCallForDisplay                                 (call   
             
                 
 )                                          {
  const args = asOptionalRecord(call.args);
  const id = typeof args?.id === "string" ? args.id.trim() : "";
  if (!TOOL_CALL_DISPLAY_NAMES.has(call.name?.trim().toLowerCase() ?? "") || !id) {
    return call;
  }
  const innerArgs = args?.args;
  const prototype = isRecord(innerArgs) ? Object.getPrototypeOf(innerArgs) : undefined;
  return {
    // The catalog owns source:sourceName:toolName IDs; ordinary names pass through.
    name: id.match(/^(?:openclaw|mcp|client):[^:]+:(.+)$/u)?.[1] ?? id,
    args: prototype === Object.prototype || prototype === null ? innerArgs : {},
  };
}
export { TOOL_CALL_DISPLAY_NAMES };