import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { composeTranscriptDisplay } from "../../chat/transcript-display-position.mjs";
import { readLegacyCompactionMetrics } from "../../config/sessions/legacy-compaction-history.mjs";
import { readChatHistoryMessageId } from "../session-history-tail.mjs";
import { readChatHistoryMessageSeq } from "../session-history-tail.mjs";
import { readChatHistoryPaginationKey } from "../session-history-tail.mjs";
import { CHAT_HISTORY_MAX_SINGLE_MESSAGE_BYTES } from "./chat-history-budget.mjs";
import { buildOversizedHistoryPlaceholder } from "./chat-history-budget.mjs";
import { createChatHistoryActivityProjection } from "./chat-history-budget.mjs";
import { createChatHistoryByteCounter } from "./chat-history-budget.mjs";
import { replaceOversizedChatHistoryMessages } from "./chat-history-budget.mjs";
import { resolveChatHistoryPageCursors } from "./chat-history-page-cursor.mjs";
function readPageMessageSequence(message         , messageSequences                   ) {
  if (typeof messageSequences === "function") {
    return messageSequences(message);
  }
  return (
    messageSequences?.[readChatHistoryPaginationKey(message) ?? ""] ??
    readChatHistoryMessageSeq(message)
  );
}
export function enrichChatHistoryCompactionMarkers(
  messages           ,
  entry                                ,
  metrics = readLegacyCompactionMetrics(entry),
)            {
  if (metrics.length === 0) {
    return messages;
  }
  const checkpointByEntryId = new Map(metrics.map((metric) => [metric.entryId, metric]));
  let changed = false;
  const enriched = messages.map((message) => {
    const record = asOptionalRecord(message);
    const metadata = asOptionalRecord(record?.["__openclaw"]);
    if (metadata?.kind !== "compaction" || typeof metadata.id !== "string") {
      return message;
    }
    const checkpoint = checkpointByEntryId.get(metadata.id);
    if (!checkpoint) {
      return message;
    }
    const tokensBefore = checkpoint.tokensBefore;
    const tokensAfter = checkpoint.tokensAfter;
    if (tokensBefore === undefined && tokensAfter === undefined) {
      return message;
    }
    changed = true;
    return {
      ...record,
      __openclaw: {
        ...metadata,
        ...(tokensBefore !== undefined ? { tokensBefore } : {}),
        ...(tokensAfter !== undefined ? { tokensAfter } : {}),
      },
    };
  });
  return changed ? enriched : messages;
}
function resolveChatHistoryMessageGroup(
  messages           ,
  index        ,
  messageCost                              ,
  messageSequences                   ,
)                                               {
  const sequence = (message         ) => readPageMessageSequence(message, messageSequences);
  const seq = sequence(messages[index]);
  let start = index;
  let end = index + 1;
  let cost = messageCost(messages[index]);
  if (seq === undefined) {
    return { start, end, cost };
  }
  while (start > 0 && sequence(messages[start - 1]) === seq) {
    start -= 1;
    cost += messageCost(messages[start]);
  }
  while (end < messages.length && sequence(messages[end]) === seq) {
    cost += messageCost(messages[end]);
    end += 1;
  }
  return { start, end, cost };
}
export function prepareChatHistoryResponsePage(
  historyPage                 ,
  {
    entry: historyEntry,
    compactionMetrics,
    maxHistoryBytes,
    responseHistoryBytes = maxHistoryBytes,
    messageId,
  }       
                          
                                                                                            
   ,
  messageSequences                               = historyPage.pagination?.messageSequences ??
    historyPage.anchor?.messageSequences,
)                          {
  const normalized = enrichChatHistoryCompactionMarkers(
    historyPage.messages,
    historyEntry,
    compactionMetrics,
  );
  const activity = createChatHistoryActivityProjection(normalized, historyPage.activity);
  const byteCounter = createChatHistoryByteCounter(activity);
  const framingCost = 1 + byteCounter.framingBytes(normalized);
  const maxCost = responseHistoryBytes - framingCost;
  const messageCost = (message         ) => byteCounter.messageBytes(message) + 1;
  const groups            = [];
  for (let index = 0; index < normalized.length;) {
    const group = resolveChatHistoryMessageGroup(normalized, index, messageCost, messageSequences);
    // A source row is the fetchable unit; replacing its display siblings keeps
    // numeric offsets lossless without letting one row escape the page budget.
    groups.push(
      ...(group.cost > maxCost
        ? [
            buildOversizedHistoryPlaceholder(
              normalized
                .slice(group.start, group.end)
                .find((message) => readChatHistoryMessageId(message) === messageId) ??
                normalized[group.end - 1],
            ),
          ]
        : normalized.slice(group.start, group.end)),
    );
    index = group.end;
  }
  const replaced = replaceOversizedChatHistoryMessages({
    byteCounter,
    messages: groups,
    maxSingleMessageBytes: Math.min(CHAT_HISTORY_MAX_SINGLE_MESSAGE_BYTES, maxCost - 1),
  });
  const messages = replaced.messages;
  function capChatHistoryTail()            {
    let start = messages.length;
    let cost = 0;
    while (start > 0) {
      const group = resolveChatHistoryMessageGroup(
        messages,
        start - 1,
        messageCost,
        messageSequences,
      );
      if (cost + group.cost > maxCost) {
        break;
      }
      start = group.start;
      cost += group.cost;
    }
    return start > 0 ? messages.slice(start) : messages;
  }

  function capChatHistoryAroundMessage(anchorMessageId        )            {
    const anchorIndex = messages.findIndex(
      (message) => readChatHistoryMessageId(message) === anchorMessageId,
    );
    if (anchorIndex === -1) {
      return [];
    }
    const groupAt = (index        ) =>
      resolveChatHistoryMessageGroup(messages, index, messageCost, messageSequences);
    const anchorGroup = groupAt(anchorIndex);
    if (!(anchorGroup.cost <= maxCost)) {
      return [messages[anchorIndex]];
    }

    let { start, end, cost } = anchorGroup;
    const grow = (index        ) => {
      const group = groupAt(index);
      if (!(cost + group.cost <= maxCost)) {
        return false;
      }
      start = Math.min(start, group.start);
      end = Math.max(end, group.end);
      cost += group.cost;
      return true;
    };
    let canGrowOlder = start > 0;
    let canGrowNewer = end < messages.length;
    while (canGrowOlder || canGrowNewer) {
      canGrowOlder &&= grow(start - 1) && start > 0;
      canGrowNewer &&= grow(end) && end < messages.length;
    }
    return messages.slice(start, end);
  }
  const capped = messageId
    ? capChatHistoryAroundMessage(
        historyPage.anchor?.direction
          ? (readChatHistoryMessageId(
              historyPage.anchor.direction === "newer"
                ? replaced.messages[0]
                : replaced.messages.at(-1),
            ) ?? messageId)
          : messageId,
      )
    : capChatHistoryTail();
  const pagination = historyPage.pagination;
  let candidateNextOffset                    ;
  if (pagination !== undefined) {
    let oldestSeq                    ;
    for (const message of capped) {
      oldestSeq = readPageMessageSequence(message, pagination.messageSequences);
      if (oldestSeq !== undefined) {
        break;
      }
    }
    // Every selected source row is complete, inline or by reference.
    candidateNextOffset =
      oldestSeq === undefined
        ? pagination.offset + pagination.rawPageMessages
        : Math.max(pagination.offset + 1, pagination.totalMessages - oldestSeq + 1);
  }
  const hasMore =
    pagination !== undefined && candidateNextOffset !== undefined
      ? candidateNextOffset < pagination.totalMessages
      : undefined;
  const survivors = new Set(capped);
  const omittedCount = normalized.reduce        (
    (count, message) => count + (survivors.has(message) ? 0 : 1),
    0,
  );
  return {
    messages: composeTranscriptDisplay(capped),
    ...(capped.some((message) => activity.has(message))
      ? { activity: capped.flatMap((message) => activity.get(message) ?? []) }
      : {}),
    messagesBytes: byteCounter.messagesBytes(capped),
    ...(omittedCount > 0
      ? {
          omission: {
            omittedCount,
            normalizedBytes: byteCounter.messagesBytes(normalized),
            ...(capped.length < replaced.messages.length ? { byteLimited: true          } : {}),
          },
        }
      : {}),
    responseHistoryBytes,
    ...resolveChatHistoryPageCursors(historyPage.anchor, capped, normalized),
    ...(hasMore ? { nextOffset: candidateNextOffset } : {}),
    ...(hasMore !== undefined ? { hasMore } : {}),
    ...(pagination !== undefined ? { totalMessages: pagination.totalMessages } : {}),
  };
}
export { readPageMessageSequence, resolveChatHistoryMessageGroup };