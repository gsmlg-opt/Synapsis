import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { isToolCallContentType } from "../../chat/tool-content.mjs";
import { isToolResultContentType } from "../../chat/tool-content.mjs";
import { readToolErrorFlag } from "../../chat/tool-content.mjs";
import { readTranscriptDisplayPosition } from "../../chat/transcript-display-position.mjs";
import { jsonUtf8Bytes } from "../../infra/json-utf8-bytes.mjs";
import { readChatHistoryMessageId } from "../session-history-tail.mjs";
export const CHAT_HISTORY_MAX_SINGLE_MESSAGE_BYTES = 128 * 1024;
const CHAT_HISTORY_OVERSIZED_PLACEHOLDER = "[chat.history omitted: message too large]";
const CHAT_HISTORY_UNAVAILABLE_SENTINEL =
  "[chat.history unavailable: transcript too large to display; the full history is preserved on disk]";
export function createChatHistoryActivityProjection(
  messages           ,
  activity                                  = [],
) {
  const byId = new Map(activity.map((entry) => [entry.messageId, entry]));
  const projected = new Map                               ();
  for (const message of messages) {
    const messageId = readChatHistoryMessageId(message);
    const entry = messageId ? byId.get(messageId) : undefined;
    const record = asOptionalRecord(message);
    if (
      entry &&
      record &&
      (isToolResultContentType(record.role) ||
        record.role === "tool" ||
        record.role === "function" ||
        (Array.isArray(record.content) &&
          record.content.some((block) => {
            const type = asOptionalRecord(block)?.type;
            return isToolCallContentType(type) || isToolResultContentType(type);
          })))
    ) {
      projected.set(message, entry);
    }
  }
  return projected;
}
export function createChatHistoryByteCounter(
  activity                                             ,
) {
  const sizes = new Map                 ();
  const messageBytes = (message         )         => {
    const cached = sizes.get(message);
    if (cached !== undefined) {
      return cached;
    }
    const descriptor = activity?.get(message);
    const bytes = jsonUtf8Bytes(message) + (descriptor ? jsonUtf8Bytes(descriptor) + 1 : 0);
    sizes.set(message, bytes);
    return bytes;
  };
  return {
    messageBytes,
    framingBytes: (messages           ) =>
      messages.some((message) => activity?.has(message)) ? 13 : 0,
    messagesBytes: (messages           ) =>
      (messages.some((message) => activity?.has(message)) ? 15 : 2) +
      messages.reduce        ((bytes, message) => bytes + messageBytes(message), 0) +
      Math.max(0, messages.length - 1),
  };
}
function buildChatHistoryUnavailableSentinel()                          {
  return {
    role: "assistant",
    timestamp: Date.now(),
    content: [{ type: "text", text: CHAT_HISTORY_UNAVAILABLE_SENTINEL }],
  };
}
export function buildOversizedHistoryPlaceholder(message          )                          {
  const entry = asOptionalRecord(message) ?? {};
  const role = typeof entry.role === "string" ? entry.role : "assistant";
  const timestamp = typeof entry.timestamp === "number" ? entry.timestamp : Date.now();
  const metadata = asOptionalRecord(entry["__openclaw"]) ?? {};
  // A bounded placeholder still identifies the tool so callers can reopen its
  // durable row. The caller checks this envelope against the byte cap as well.
  const toolIdentity = Object.fromEntries(
    ["toolCallId", "tool_call_id", "toolUseId", "tool_use_id", "toolName", "tool_name", "name"]
      .filter((key) => typeof entry[key] === "string")
      .map((key) => [key, entry[key]]),
  );
  const isError = readToolErrorFlag(entry);
  const metadataId = typeof metadata.id === "string" ? metadata.id : undefined;
  const metadataSeq = typeof metadata.seq === "number" ? metadata.seq : undefined;
  const metadataIdempotencyKey =
    typeof metadata.idempotencyKey === "string" ? metadata.idempotencyKey : undefined;
  const turnBoundary = metadata.turnBoundary === true;
  const transcriptPosition = readTranscriptDisplayPosition(metadata.transcriptPosition);
  return {
    role,
    timestamp,
    content: [{ type: "text", text: CHAT_HISTORY_OVERSIZED_PLACEHOLDER }],
    ...toolIdentity,
    ...(isError !== undefined ? { isError } : {}),
    __openclaw: {
      ...(metadata.toolOutput ? { toolOutput: metadata.toolOutput } : {}),
      ...(metadataId ? { id: metadataId } : {}),
      ...(typeof metadata.runId === "string" ? { runId: metadata.runId } : {}),
      ...(metadataSeq !== undefined ? { seq: metadataSeq } : {}),
      ...(metadataIdempotencyKey ? { idempotencyKey: metadataIdempotencyKey } : {}),
      ...(turnBoundary ? { turnBoundary: true } : {}),
      ...(transcriptPosition ? { transcriptPosition } : {}),
      truncated: true,
      reason: "oversized",
    },
  };
}
export function replaceOversizedChatHistoryMessages(params   
                                                                
                      
                                
 )                                                 {
  const { messages, maxSingleMessageBytes } = params;
  const byteCounter = params.byteCounter ?? createChatHistoryByteCounter();
  let replacedCount = 0;
  const next = messages.map((message) => {
    if (byteCounter.messageBytes(message) <= maxSingleMessageBytes) {
      return message;
    }
    replacedCount += 1;
    const placeholder = buildOversizedHistoryPlaceholder(message);
    return byteCounter.messageBytes(placeholder) <= maxSingleMessageBytes
      ? placeholder
      : buildChatHistoryUnavailableSentinel();
  });
  return { messages: replacedCount > 0 ? next : messages, replacedCount };
}
export { CHAT_HISTORY_OVERSIZED_PLACEHOLDER, CHAT_HISTORY_UNAVAILABLE_SENTINEL, buildChatHistoryUnavailableSentinel };