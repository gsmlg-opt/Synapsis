import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { z } from "zod";
export const NESTED_TOOL_ACTIVITY_CUSTOM_TYPE = "openclaw.nested-tool.v1";
const correlationId = z.string().min(1).max(1024);
const activityDetails = z
  .object({
    runId: correlationId,
    scopeId: correlationId,
    afterEntryId: correlationId.nullable(),
    startOrder: z.number().int().nonnegative(),
    parentToolCallId: correlationId.optional(),
    toolCallId: correlationId,
    toolName: z.string().min(1).max(256),
    input: z.unknown(),
    result: z.object({ content: z.array(z.unknown()), details: z.unknown().optional() }),
    isError: z.boolean(),
    startedAt: z.number().finite(),
    timestamp: z.number().finite(),
  })
  .strict();
const activitySchema = z.object({
  role: z.literal("custom"),
  customType: z.literal(NESTED_TOOL_ACTIVITY_CUSTOM_TYPE),
  display: z.literal(true),
  excludeFromContext: z.literal(true),
  content: z.literal(""),
  details: activityDetails,
  timestamp: z.number().finite(),
});
let compiledActivitySchema                                   ;
function getActivitySchema() {
  // Ordinary transcript rows never pay the one-time compilation cost.
  return (compiledActivitySchema ??= z.compile(activitySchema));
}
export function readNestedToolActivity(value         )                                 {
  if (asOptionalRecord(value)?.customType !== NESTED_TOOL_ACTIVITY_CUSTOM_TYPE) {
    return undefined;
  }
  const parsed = getActivitySchema().safeParse(value);
  return parsed.success ? parsed.data : undefined;
}
export function nestedToolActivityContent({ details }                    ) {
  const { input, result, ...call } = details;
  return [
    {
      type: "toolCall",
      id: call.toolCallId,
      runId: call.runId,
      name: call.toolName,
      arguments: input,
      parentToolCallId: call.parentToolCallId,
      timestamp: call.startedAt,
    },
    { ...call, ...result, type: "toolResult" },
  ]         ;
}
export { correlationId, activityDetails, activitySchema, compiledActivitySchema, getActivitySchema };