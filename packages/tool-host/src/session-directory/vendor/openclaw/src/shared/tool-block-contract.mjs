import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
const TOOL_CALL_BLOCK_TYPES = new Set([
  "toolCall",
  "toolUse",
  "functionCall",
  "tool_call",
  "tool_use",
  "function_call",
]);
const TOOL_RESULT_BLOCK_TYPES = new Set([
  "toolResult",
  "tool_result",
  "tool_result_error",
  "function_call_output",
]);

                                                       
               
               
                 
                  
                      
  

export function isToolCallBlockType(value         )          {
  return typeof value === "string" && TOOL_CALL_BLOCK_TYPES.has(value);
}

function isToolResultBlockType(value         )          {
  return typeof value === "string" && TOOL_RESULT_BLOCK_TYPES.has(value);
}

export function isContractToolCallBlock(value         )                         {
  return isRecord(value) && isToolCallBlockType(value.type);
}

export function isContractToolResultBlock(value         )                                   {
  return isRecord(value) && isToolResultBlockType(value.type);
}

export function readToolCallName(block                         )                     {
  for (const candidate of [block, block.function]) {
    const direct = normalizeOptionalString(candidate);
    if (direct) {
      return direct;
    }
    if (!isRecord(candidate)) {
      continue;
    }
    for (const key of ["name", "toolName", "tool_name", "functionName", "function_name"]) {
      const name = normalizeOptionalString(candidate[key]);
      if (name) {
        return name;
      }
    }
  }
  return undefined;
}

export function collectToolCallIds(block                         )           {
  const ids = new Set        ();
  for (const key of ["call_id", "tool_call_id", "toolCallId", "tool_use_id", "toolUseId", "id"]) {
    const id = normalizeOptionalString(block[key]);
    if (id) {
      ids.add(id);
    }
  }
  return [...ids];
}
