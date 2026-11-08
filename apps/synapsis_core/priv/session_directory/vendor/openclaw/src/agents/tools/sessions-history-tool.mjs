import { asPositiveSafeInteger } from "../../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { capArrayByJsonBytes } from "../../gateway/session-utils.fs.mjs";
import { jsonUtf8Bytes } from "../../infra/json-utf8-bytes.mjs";
import { truncateUtf16Safe } from "../../../packages/normalization-core/src/utf16-slice.mjs";
const SESSIONS_HISTORY_MAX_BYTES = 80 * 1024;
const SESSIONS_HISTORY_TEXT_MAX_CHARS = 4000;
const SESSIONS_HISTORY_PENDING_MAX_BYTES = 4096;
function sanitizeHistoryMessage(
  message         ,
  maxChars = SESSIONS_HISTORY_TEXT_MAX_CHARS,
)   
                   
                     
  {
  if (!message || typeof message !== "object") {
    return { message, truncated: false };
  }
  const entry = { ...(message                           ) };
  let truncated = false;
  const sanitizeText = (text        ) => {
    if (text.length <= maxChars) {
      return text;
    }
    truncated = true;
    return `${truncateUtf16Safe(text, maxChars)}\n…(truncated)…`;
  };
  // Tool result details often contain very large nested payloads.
  for (const field of ["details", "usage", "cost"]) {
    if (field in entry) {
      delete entry[field];
      truncated = true;
    }
  }

  if (typeof entry.content === "string") {
    entry.content = sanitizeText(entry.content);
  } else if (Array.isArray(entry.content)) {
    entry.content = entry.content.map((block         ) => {
      if (!block || typeof block !== "object") {
        return block;
      }
      const content = { ...(block                           ) };
      const fields =
        content.type === "thinking" ? ["text", "thinking", "partialJson"] : ["text", "partialJson"];
      for (const field of fields) {
        if (typeof content[field] === "string") {
          content[field] = sanitizeText(content[field]);
        }
      }
      return content;
    });
  }
  if (typeof entry.text === "string") {
    entry.text = sanitizeText(entry.text);
  }
  return { message: entry, truncated };
}
function boundPendingInputs(page                       ) {
  // Pending input is context for an intentional next action, never executable
  // history. Keep the whole page addressable while sharing one hard byte cap.
  const metadata = page.items.map(({ id, state, acceptedAt }) => ({ id, state, acceptedAt }));
  const messageBudget = Math.floor(
    (SESSIONS_HISTORY_PENDING_MAX_BYTES -
      jsonUtf8Bytes({ ...page, items: metadata }) -
      page.items.length * 12) /
      Math.max(page.items.length, 1),
  );
  let truncated = false;
  const items = page.items.map((item, index) => {
    const result = sanitizeHistoryMessage(item.message, Math.max(1, Math.floor(messageBudget / 8)));
    const record = asOptionalRecord(result.message);
    const media = asOptionalRecord(record?.["__openclaw"])?.media;
    const message = { role: "user", content: record?.content, ...(media ? { media } : {}) };
    const oversized = jsonUtf8Bytes(message) > messageBudget;
    truncated ||= result.truncated || oversized;
    return {
      ...metadata[index],
      message: oversized ? { role: "user", content: "[Input omitted; request limit: 1]" } : message,
    };
  });
  const pendingInputs = {
    items,
    total: page.total,
    ...(page.nextBefore !== undefined ? { nextBefore: page.nextBefore } : {}),
  };
  return { pendingInputs, bytes: jsonUtf8Bytes(pendingInputs), truncated };
}
function enforceSessionsHistoryHardCap(params   
                   
                
                   
 )                                                           {
  if (params.bytes <= params.maxBytes) {
    return { items: params.items, bytes: params.bytes, hardCapped: false };
  }

  const last = params.items.at(-1);
  const lastOnly = last ? [last] : [];
  const lastBytes = jsonUtf8Bytes(lastOnly);
  if (lastBytes <= params.maxBytes) {
    return { items: lastOnly, bytes: lastBytes, hardCapped: true };
  }

  const placeholder = [buildSessionsHistoryOmittedPlaceholder(last)];
  return { items: placeholder, bytes: jsonUtf8Bytes(placeholder), hardCapped: true };
}
function readHistoryMessageSeq(message         )                     {
  const meta = asOptionalRecord(asOptionalRecord(message)?.["__openclaw"]);
  return asPositiveSafeInteger(meta?.seq);
}
function readHistoryMessageId(message         )                     {
  const meta = asOptionalRecord(asOptionalRecord(message)?.["__openclaw"]);
  const id = meta?.id;
  return typeof id === "string" && id.length > 0 ? id : undefined;
}
function capSessionsHistoryAroundMessage(
  items           ,
  messageId        ,
  maxBytes        ,
)                                      {
  const anchorIndex = items.findIndex((item) => readHistoryMessageId(item) === messageId);
  if (anchorIndex === -1) {
    return capArrayByJsonBytes(items, maxBytes);
  }

  let start = anchorIndex;
  let end = anchorIndex + 1;
  let bytes = jsonUtf8Bytes([items[anchorIndex]]);
  let canGrowOlder = start > 0;
  let canGrowNewer = end < items.length;
  while (canGrowOlder || canGrowNewer) {
    if (canGrowOlder) {
      // Singleton arrays preserve JSON's array-element encoding; replacing one
      // bracket with a comma gives the exact growth of this nonempty window.
      const candidateBytes = bytes + jsonUtf8Bytes([items[start - 1]]) - 1;
      if (candidateBytes <= maxBytes) {
        start -= 1;
        bytes = candidateBytes;
      } else {
        canGrowOlder = false;
      }
    }
    canGrowOlder &&= start > 0;

    if (canGrowNewer) {
      const candidateBytes = bytes + jsonUtf8Bytes([items[end]]) - 1;
      if (candidateBytes <= maxBytes) {
        end += 1;
        bytes = candidateBytes;
      } else {
        canGrowNewer = false;
      }
    }
    canGrowNewer &&= end < items.length;
  }
  return { items: items.slice(start, end), bytes };
}
function buildSessionsHistoryOmittedPlaceholder(source         )                          {
  const seq = readHistoryMessageSeq(source);
  const id = readHistoryMessageId(source);
  return {
    role: "assistant",
    content: "[sessions_history omitted: message too large]",
    ...(seq !== undefined || id !== undefined
      ? {
          __openclaw: {
            ...(seq !== undefined ? { seq } : {}),
            ...(id !== undefined ? { id } : {}),
          },
        }
      : {}),
  };
}
function resolveSessionsHistoryPaginationMetadata(params   
                      
                                                    
                                      
                                         
 )                                {
  const result = params.result;
  if (params.requestedMessageId) {
    return typeof result?.totalMessages === "number" ? { totalMessages: result.totalMessages } : {};
  }
  const offset = typeof result?.offset === "number" ? result.offset : params.requestedOffset;
  if (offset === undefined) {
    return {};
  }

  const totalMessages =
    typeof result?.totalMessages === "number" ? result.totalMessages : undefined;
  if (totalMessages === undefined) {
    return {
      offset,
      ...(typeof result?.nextOffset === "number" ? { nextOffset: result.nextOffset } : {}),
      ...(typeof result?.hasMore === "boolean" ? { hasMore: result.hasMore } : {}),
    };
  }

  // Respect Gateway replay cursors and this tool's own byte cap while always advancing.
  const seq = params.messages
    .map((message) => readHistoryMessageSeq(message))
    .find((value)                  => typeof value === "number");
  const gatewayOffset = result?.nextOffset;
  const nextOffset =
    seq === undefined
      ? gatewayOffset
      : Math.max(offset + 1, Math.min(gatewayOffset ?? totalMessages, totalMessages - seq + 1));
  const hasMore =
    nextOffset !== undefined
      ? nextOffset < totalMessages
      : typeof result?.hasMore === "boolean"
        ? result.hasMore
        : undefined;
  return {
    offset,
    ...(hasMore === true && nextOffset !== undefined ? { nextOffset } : {}),
    ...(hasMore !== undefined ? { hasMore } : {}),
    totalMessages,
  };
}
export { sanitizeHistoryMessage, boundPendingInputs, enforceSessionsHistoryHardCap, readHistoryMessageSeq, readHistoryMessageId, capSessionsHistoryAroundMessage, buildSessionsHistoryOmittedPlaceholder, resolveSessionsHistoryPaginationMetadata, SESSIONS_HISTORY_MAX_BYTES };