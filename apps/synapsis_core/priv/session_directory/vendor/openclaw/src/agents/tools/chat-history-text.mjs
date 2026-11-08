import { NESTED_TOOL_ACTIVITY_CUSTOM_TYPE } from "../../sessions/nested-tool-activity.mjs";
export function stripToolMessages(messages           )            {
  return messages.filter((msg) => {
    if (!msg || typeof msg !== "object") {
      return true;
    }
    const { role, customType } = msg                                            ;
    return (
      role !== "toolResult" &&
      role !== "tool" &&
      !(role === "custom" && customType === NESTED_TOOL_ACTIVITY_CUSTOM_TYPE)
    );
  });
}