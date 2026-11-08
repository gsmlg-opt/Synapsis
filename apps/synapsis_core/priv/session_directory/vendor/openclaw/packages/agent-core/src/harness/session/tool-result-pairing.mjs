import { asOptionalObjectRecord } from "../../../../normalization-core/src/record-coerce.mjs";
export const SYNTHETIC_MISSING_TOOL_RESULT_DETAIL_KEY = "openclawSyntheticMissingToolResult";
export const LEGACY_MISSING_TOOL_RESULT_TEXT =
  "[openclaw] missing tool result in session history; inserted synthetic error result for transcript repair.";
export function isSyntheticMissingToolResult(message   
                    
                    
                    
 )          {
  if (!message.isError) {
    return false;
  }
  if (
    asOptionalObjectRecord(message.details)?.[SYNTHETIC_MISSING_TOOL_RESULT_DETAIL_KEY] === true
  ) {
    return true;
  }
  const content = message.content;
  return (
    Array.isArray(content) &&
    content.some((block) => {
      const record = asOptionalObjectRecord(block);
      return record?.type === "text" && record.text === LEGACY_MISSING_TOOL_RESULT_TEXT;
    })
  );
}