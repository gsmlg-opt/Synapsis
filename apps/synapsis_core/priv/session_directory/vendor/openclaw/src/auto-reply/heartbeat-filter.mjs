import { expectDefined } from "../../packages/normalization-core/src/index.mjs";
import { safeParseJsonRecord } from "../../packages/normalization-core/src/json-coercion.mjs";
import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString as readString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { MESSAGE_TOOL_DELIVERY_HINTS } from "../plugin-sdk/message-tool-delivery-hints.mjs";
import { isSilentAssistantTranscriptMessage } from "../shared/chat-message-content.mjs";
import {
  collectToolCallIds,
  isContractToolCallBlock,
  isContractToolResultBlock,
  readToolCallName,
} from "../shared/tool-block-contract.mjs";
import {
  HEARTBEAT_RESPONSE_TOOL_INSTRUCTIONS,
  HEARTBEAT_RESPONSE_TOOL_PROMPT,
  INTERNAL_WAKE_TRANSCRIPT_PROMPTS,
  isHeartbeatAcknowledgementText,
  resolveHeartbeatPromptForResponseTool,
} from "./heartbeat.mjs";
import { HEARTBEAT_TOKEN, SILENT_REPLY_TOKEN } from "./tokens.mjs";

// Saved transcripts retain calls to the retired response tool.
const HEARTBEAT_RESPONSE_TOOL_NAME = "heartbeat_respond";

const HEARTBEAT_TASK_PROMPT_PREFIX =
  "Run the following periodic tasks (only those due based on their intervals):";
const HEARTBEAT_TASK_PROMPT_COMPLETIONS = [
  ...[HEARTBEAT_TOKEN, SILENT_REPLY_TOKEN].map(
    (token) => `After completing all due tasks, reply ${token}.`,
  ),
  HEARTBEAT_RESPONSE_TOOL_INSTRUCTIONS,
  `After completing all due tasks, use ${HEARTBEAT_RESPONSE_TOOL_NAME}`,
];
                                                                      

function isVisibleHeartbeatResponseToolCall(block                         )          {
  const nested = isRecord(block.function) ? block.function : undefined;
  const value =
    block.arguments ??
    block.args ??
    block.input ??
    nested?.arguments ??
    nested?.args ??
    nested?.input;
  const args = isRecord(value)
    ? value
    : typeof value === "string"
      ? safeParseJsonRecord(value)
      : undefined;
  return args?.notify === true || args?.notify === "true";
}

function collectAssistantToolCalls(message                            ) {
  if (message.role !== "assistant") {
    return [];
  }
  const toolCalls = (message                           ).tool_calls;
  return [
    ...(Array.isArray(toolCalls) ? toolCalls.filter(isRecord) : []),
    ...(Array.isArray(message.content) ? message.content.filter(isContractToolCallBlock) : []),
  ];
}

function isEmbeddedToolResultOnlyContent(content         )          {
  return (
    Array.isArray(content) &&
    content.length > 0 &&
    content.every((block) => isContractToolResultBlock(block))
  );
}

function isToolResultMessage(message                            )          {
  return (
    message.role === "toolResult" ||
    message.role === "tool" ||
    (message.role === "user" && isEmbeddedToolResultOnlyContent(message.content))
  );
}

function matchesHeartbeatPromptText(text        , prompt                    )          {
  return Boolean(prompt) && (text === prompt || text.startsWith(`${prompt}\n`));
}

function resolveMessageText(content         )                                               {
  if (typeof content === "string") {
    return { text: content, hasNonTextContent: false };
  }
  if (!Array.isArray(content)) {
    return { text: "", hasNonTextContent: content != null };
  }
  let hasNonTextContent = false;
  let text = "";
  for (const block of content) {
    if (typeof block !== "object" || block === null || !("type" in block)) {
      hasNonTextContent = true;
      continue;
    }
    // Provider thinking/reasoning is not user-visible output; it must not keep a
    // no-op heartbeat acknowledgement in future model request history.
    if (
      block.type === "thinking" ||
      block.type === "reasoning" ||
      block.type === "redacted_thinking"
    ) {
      continue;
    }
    if (block.type !== "text" && block.type !== "input_text" && block.type !== "output_text") {
      hasNonTextContent = true;
      continue;
    }
    const blockText = (block                      ).text;
    if (typeof blockText !== "string") {
      hasNonTextContent = true;
      continue;
    }
    text += blockText;
  }
  return { text, hasNonTextContent };
}

/** Return whether a user message is an internal heartbeat prompt. */
export function isHeartbeatUserMessage(
  message                            ,
  heartbeatPrompt         ,
  options                              = {},
)          {
  if (message.role !== "user") {
    return false;
  }
  const { text } = resolveMessageText(message.content);
  const trimmed = text.trim();
  if (!trimmed) {
    return false;
  }
  const normalizedHeartbeatPrompt = heartbeatPrompt?.trim();
  const transcriptPrompts = options.heartbeatOnly
    ? [INTERNAL_WAKE_TRANSCRIPT_PROMPTS.heartbeat]
    : Object.values(INTERNAL_WAKE_TRANSCRIPT_PROMPTS);
  if (transcriptPrompts.some((prompt) => trimmed === prompt)) {
    return true;
  }
  if (
    MESSAGE_TOOL_DELIVERY_HINTS.some((prefix) => trimmed.startsWith(prefix)) &&
    transcriptPrompts.some((prompt) => trimmed.endsWith(prompt))
  ) {
    return true;
  }
  if (
    matchesHeartbeatPromptText(trimmed, normalizedHeartbeatPrompt) ||
    matchesHeartbeatPromptText(trimmed, HEARTBEAT_RESPONSE_TOOL_PROMPT) ||
    (normalizedHeartbeatPrompt &&
      matchesHeartbeatPromptText(
        trimmed,
        resolveHeartbeatPromptForResponseTool(normalizedHeartbeatPrompt),
      ))
  ) {
    return true;
  }
  return (
    trimmed.startsWith(HEARTBEAT_TASK_PROMPT_PREFIX) &&
    HEARTBEAT_TASK_PROMPT_COMPLETIONS.some((completion) => trimmed.includes(completion))
  );
}

/** Return whether an assistant message is only a heartbeat acknowledgement. */
export function isHeartbeatOkResponse(
  message                            ,
  ackMaxChars         ,
  allowTruncated = false,
)          {
  if (message.role !== "assistant" || collectAssistantToolCalls(message).length > 0) {
    return false;
  }
  const { text, hasNonTextContent } = resolveMessageText(message.content);
  return (
    !hasNonTextContent &&
    (isSilentAssistantTranscriptMessage(message) ||
      isHeartbeatAcknowledgementText(text, ackMaxChars, allowTruncated))
  );
}

function advancePastAdjacentToolResults(
  messages                              ,
  startIndex        ,
)         {
  let index = startIndex;
  while (index < messages.length) {
    const message = messages.at(index);
    if (!message || !isToolResultMessage(message)) {
      break;
    }
    index++;
  }
  return index;
}

function hasCompletedVisibleHeartbeatResponseToolCall(
  messages                              ,
  index        ,
  visibleCalls                                ,
)          {
  const callIds = new Set(visibleCalls.flatMap((call) => collectToolCallIds(call)));
  for (let resultIndex = index + 1; resultIndex < messages.length; resultIndex++) {
    const result = expectDefined(messages[resultIndex], "messages entry at resultIndex");
    const { content } = result;
    const blocks = Array.isArray(content) ? content.filter(isContractToolResultBlock) : [];
    if (blocks.length === 0 && !isToolResultMessage(result)) {
      break;
    }
    const records                                 = blocks.length > 0 ? blocks : [result];
    if (
      records.some(
        (record) =>
          record.isError !== true &&
          record.is_error !== true &&
          readString(record.type) !== "tool_result_error" &&
          (callIds.size === 0 || collectToolCallIds(record).some((id) => callIds.has(id))),
      )
    ) {
      return true;
    }
  }
  return false;
}

function resolveHeartbeatArtifactSpanEnd(
  messages                              ,
  startIndex        ,
  ackMaxChars         ,
  allowTruncated = false,
)                     {
  let index = startIndex + 1;
  let sawTerminalHeartbeatArtifact = false;
  let sawNonTerminalAssistantOutput = false;

  while (index < messages.length) {
    const message = messages.at(index);
    if (!message) {
      break;
    }
    // Both the next wake and an ordinary user turn end this heartbeat span.
    if (message.role === "user" && !isEmbeddedToolResultOnlyContent(message.content)) {
      break;
    }
    if (isHeartbeatOkResponse(message, ackMaxChars, allowTruncated)) {
      sawTerminalHeartbeatArtifact = true;
      index = advancePastAdjacentToolResults(messages, index + 1);
      continue;
    }
    const toolCalls = collectAssistantToolCalls(message);
    const heartbeatCalls = toolCalls.filter(
      (block) => readToolCallName(block) === HEARTBEAT_RESPONSE_TOOL_NAME,
    );
    const visibleCalls = heartbeatCalls.filter(isVisibleHeartbeatResponseToolCall);
    if (visibleCalls.length > 0) {
      if (hasCompletedVisibleHeartbeatResponseToolCall(messages, index, visibleCalls)) {
        return undefined;
      }
    } else if (heartbeatCalls.length > 0) {
      sawTerminalHeartbeatArtifact = true;
      index = advancePastAdjacentToolResults(messages, index + 1);
      continue;
    } else if (
      !sawTerminalHeartbeatArtifact &&
      !isToolResultMessage(message) &&
      toolCalls.length === 0
    ) {
      if (message.role !== "assistant") {
        return undefined;
      }
      sawNonTerminalAssistantOutput = true;
    }
    index++;
  }

  if (sawNonTerminalAssistantOutput && !sawTerminalHeartbeatArtifact) {
    return undefined;
  }
  return index;
}

/** Remove heartbeat-only prompt, ack, and silent tool artifacts from a transcript. */
export function filterHeartbeatTranscriptArtifacts                                      (
  messages     ,
  ackMaxChars         ,
  heartbeatPrompt         ,
)      {
  if (messages.length === 0) {
    return messages;
  }

  const result      = [];
  for (let i = 0; i < messages.length;) {
    const message = expectDefined(messages[i], "messages entry at i");
    const next = isHeartbeatUserMessage(message, heartbeatPrompt)
      ? resolveHeartbeatArtifactSpanEnd(
          messages,
          i,
          ackMaxChars,
          isHeartbeatUserMessage(message, heartbeatPrompt, { heartbeatOnly: true }),
        )
      : undefined;
    if (next === undefined) {
      result.push(message);
    }
    i = next ?? i + 1;
  }

  return result;
}
