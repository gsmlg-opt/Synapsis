import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { isSyntheticMissingToolResult } from "../../packages/agent-core/src/harness/session/tool-result-pairing.mjs";
import { projectAgentActivityItem } from "../agents/agent-activity-presentation.mjs";
import { resolveCompletedActivityWrappers } from "../agents/agent-activity-presentation.mjs";
import { isProcessPollResultDetails } from "../agents/bash-tools.process-schema.mjs";
import { unwrapToolCallForDisplay } from "../agents/tool-display-call.mjs";
import { inferToolMetaFromArgsCore } from "../agents/tool-display.mjs";
import { isCommandBearingToolCall } from "../agents/tool-display.mjs";
import { resolveToolDisplay } from "../agents/tool-display.mjs";
import { isToolResultError } from "../agents/tool-result-error.mjs";
import { isToolCallContentType } from "../chat/tool-content.mjs";
import { isToolResultContentType } from "../chat/tool-content.mjs";
import { readToolErrorFlag } from "../chat/tool-content.mjs";
import { resolveToolUseId } from "../chat/tool-content.mjs";
import { readNestedToolActivity } from "../sessions/nested-tool-activity.mjs";
import { nestedToolActivityContent } from "../sessions/nested-tool-activity.mjs";
import { readSessionTranscriptRunId } from "../sessions/transcript-events.mjs";
export function projectAgentToolActivity(tool                   )                    {
  const input = { name: tool.name, args: tool.args };
  const unwrapped = unwrapToolCallForDisplay(input);
  // History may omit executed args; its presentation name is then a name-only fallback.
  const call =
    unwrapped === input && tool.presentationName
      ? { name: tool.presentationName, args: tool.args }
      : unwrapped;
  const meta = tool.meta ?? inferToolMetaFromArgsCore(call.name, call.args);
  const label = resolveToolDisplay(call).label;
  const details = asOptionalRecord(asOptionalRecord(tool.result)?.details);
  const approval =
    tool.phase === "result" &&
    (details?.status === "approval-pending" || details?.status === "approval-unavailable");
  const skipped = tool.phase === "result" && details?.status === "skipped";
  const status =
    tool.phase !== "result"
      ? "running"
      : skipped && details.deniedReason === "steering"
        ? "skipped"
        : approval || skipped
          ? "blocked"
          : tool.status === "unknown"
            ? undefined
            : (tool.status ??
              (tool.isError === true
                ? "failed"
                : tool.isError === false
                  ? "completed"
                  : undefined));
  const activity                    = projectAgentActivityItem(
    {
      itemId: `tool:${tool.toolCallId}`,
      toolCallId: tool.toolCallId,
      name: tool.name,
      kind: "tool",
      phase: tool.phase === "result" ? "end" : tool.phase,
      title: meta ? `${label} ${meta}` : label,
      ...(status
        ? { status }
        : { summary: "Outcome unknown", title: `${label} — outcome unknown` }),
      ...(approval
        ? {
            approvalId: normalizeOptionalString(details?.approvalId),
            approvalSlug: normalizeOptionalString(details?.approvalSlug),
            summary:
              details?.status === "approval-pending"
                ? "Awaiting approval before command can run."
                : "Command is blocked because no interactive approval route is available.",
          }
        : {}),
      ...(skipped ? { summary: "Skipped" } : {}),
      ...(meta ? { meta } : {}),
      commandBearing: isCommandBearingToolCall(call.name, call.args),
      ...(tool.hideFromChannelProgress ? { hideFromChannelProgress: true } : {}),
    },
    { args: tool.args, result: tool.result, nativeOperation: tool.nativeOperation },
  );
  // Outcome and visibility still belong to the original execution facts.
  return { ...activity, name: call.name };
}
export function projectAgentHistoryActivity(
  messages                                                        ,
)                         {
  const facts = new Map                                              ();
  let turn = 0;
  const entries = messages.map(({ messageId, message }) => {
    const record = asOptionalRecord(message);
    const metadata = asOptionalRecord(record?.["__openclaw"]);
    if (
      record?.role === "user" &&
      !metadata?.steerTargetRunId &&
      !(record.excludeFromContext === true && metadata?.contextFreeCommand === true)
    ) {
      turn += 1;
    }
    const nestedActivity = readNestedToolActivity(message);
    const nested = nestedActivity?.details;
    const content = nestedActivity
      ? nestedToolActivityContent(nestedActivity)
      : Array.isArray(record?.content)
        ? record.content
        : [];
    const blocks = content.flatMap((block) => {
      const value = asOptionalRecord(block);
      return value && (isToolCallContentType(value.type) || isToolResultContentType(value.type))
        ? [value]
        : [];
    });
    if (
      record &&
      (isToolResultContentType(record.role) || record.role === "tool" || record.role === "function")
    ) {
      // Result envelopes mirror their payload as a content block. The envelope
      // owns details and error state; it is one outcome, not two operations.
      blocks.splice(0, blocks.length, record);
    }
    return {
      messageId,
      hasTools: blocks.length > 0,
      blocks: blocks.map((block, index) => {
        const toolCallId =
          normalizeOptionalString(block.toolCallId) ??
          normalizeOptionalString(block.tool_call_id) ??
          normalizeOptionalString(block.toolUseId) ??
          normalizeOptionalString(block.tool_use_id) ??
          (block === record ? undefined : resolveToolUseId(block));
        const recordedRunId =
          normalizeOptionalString(block.runId) ??
          nested?.runId ??
          readSessionTranscriptRunId(message) ??
          normalizeOptionalString(record?.runId);
        return {
          block,
          runId: recordedRunId ? JSON.stringify([turn, recordedRunId]) : undefined,
          parentToolCallId:
            nested && nested.toolCallId === toolCallId
              ? nested.parentToolCallId
              : normalizeOptionalString(block.parentToolCallId),
          key: toolCallId
            ? JSON.stringify([
                turn,
                nested?.runId ?? readSessionTranscriptRunId(message),
                nested?.scopeId,
                toolCallId,
              ])
            : "history:" + messageId + ":" + index,
          toolCallId: toolCallId ?? "history:" + messageId + ":" + index,
          callId: toolCallId,
          executedArgs: nested && nested.toolCallId === toolCallId ? nested.input : undefined,
          isError:
            readToolErrorFlag(block) ??
            (record ? readToolErrorFlag(record) : undefined) ??
            (typeof nested?.isError === "boolean" ? nested.isError : undefined),
        };
      }),
    };
  });
  const groups = new Map                                                               ();
  for (const { blocks } of entries) {
    for (const { block, key } of blocks) {
      const group = groups.get(key) ?? { calls: 0, results: 0, synthetic: 0 };
      group[
        isToolCallContentType(block.type)
          ? "calls"
          : isSyntheticMissingToolResult(block)
            ? "synthetic"
            : "results"
      ] += 1;
      groups.set(key, group);
    }
  }
  for (const entry of entries) {
    entry.blocks = entry.blocks.filter(({ block, key }) => {
      const group = groups.get(key) ;
      // Transcript repair placeholders lose compact authority to an actual result.
      // The raw row remains available, with an explicit empty activity descriptor.
      return !(group.calls <= 1 && group.results === 1 && isSyntheticMissingToolResult(block));
    });
    for (const [index, block] of entry.blocks.entries()) {
      const group = groups.get(block.key) ;
      // Legacy/imported rows may reuse IDs. Never propagate an ambiguous outcome.
      if (group.calls > 1 || group.results + (group.results === 1 ? 0 : group.synthetic) > 1) {
        block.key = "history:" + entry.messageId + ":" + index;
      }
    }
  }
  for (const { blocks } of entries) {
    for (const {
      block,
      key,
      toolCallId,
      callId,
      executedArgs,
      runId,
      parentToolCallId,
    } of blocks) {
      if (isToolCallContentType(block.type)) {
        const name =
          normalizeOptionalString(block.name) ?? normalizeOptionalString(block.toolName) ?? "Tool";
        // A transcript call is not live authority. Its result may be absent or
        // outside this page; only live events can establish running activity.
        facts.set(key, {
          toolCallId,
          callId,
          runId,
          parentToolCallId,
          name,
          presentationName: unwrapToolCallForDisplay({
            name,
            args: executedArgs ?? block.arguments ?? block.args ?? block.input,
          }).name,
          phase: "result",
          args: executedArgs,
        });
      }
    }
  }
  for (const { blocks } of entries) {
    for (const {
      block,
      key,
      toolCallId,
      callId,
      executedArgs,
      isError,
      runId,
      parentToolCallId,
    } of blocks) {
      if (isToolCallContentType(block.type)) {
        continue;
      }
      const call = facts.get(key);
      const name =
        call?.name ??
        normalizeOptionalString(block.toolName) ??
        normalizeOptionalString(block.name) ??
        "Tool";
      const failed = isError === true || isToolResultError(block);
      const details = asOptionalRecord(block.details);
      const exitReasonLost =
        (name === "exec" || name === "bash" || name === "process") &&
        details?.status === "completed" &&
        typeof details.exitCode === "number" &&
        Number.isFinite(details.exitCode) &&
        details.exitCode !== 0 &&
        details.persistedDetailsTruncated === true &&
        details.exitReason === undefined &&
        Array.isArray(details.originalDetailKeys) &&
        details.originalDetailKeys.includes("exitReason");
      const poll = name === "process" && isProcessPollResultDetails(details);
      facts.set(key, {
        ...call,
        toolCallId,
        callId,
        runId: call?.runId ?? runId,
        parentToolCallId: call?.parentToolCallId ?? parentToolCallId,
        name,
        phase: "result",
        args: executedArgs ?? call?.args,
        result: block,
        isError: failed ? true : poll ? false : isError,
        // The existing persistence cap can remove the distinction between a
        // requested stop and a failed command. Do not invent that outcome.
        ...(!failed && exitReasonLost ? { status: "unknown"          } : {}),
        ...(poll ? { nativeOperation: "process.poll" } : {}),
      });
    }
  }
  const prepared = [...facts].map(([key, fact]) => {
    const activity = projectAgentToolActivity({
      ...fact,
      ...(fact.name === "collab.wait" ? { nativeOperation: "wait"          } : {}),
    });
    if (fact.result === undefined) {
      activity.unpairedCall = true;
    }
    return {
      key,
      callId: fact.callId,
      runId: fact.runId,
      parentToolCallId: fact.parentToolCallId,
      activity,
    };
  });
  const wrappers = resolveCompletedActivityWrappers(prepared);
  const preparedByKey = new Map(prepared.map((call) => [call.key, call]));
  return entries.flatMap(({ messageId, blocks, hasTools }) => {
    if (!hasTools) {
      return [];
    }
    const items = new Map                           ();
    for (const { key } of blocks) {
      const call = preparedByKey.get(key);
      if (!call || wrappers.has(call)) {
        continue;
      }
      const item = call.activity;
      if (!item.hideFromChannelProgress && !item.suppressChannelProgress) {
        items.set(item.itemId, item);
      }
    }
    return [{ messageId, items: [...items.values()] }];
  });
}