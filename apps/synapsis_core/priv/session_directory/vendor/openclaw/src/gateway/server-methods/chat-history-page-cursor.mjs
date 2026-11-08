import { z } from "zod";
import { readChatHistoryMessageId } from "../session-history-tail.mjs";
const PREFIX = "history-page:";
const MAX_CURSOR_CHARS = 4096;
const cursorSchema = z.object({
  sessionId: z.string().min(1).max(1024),
  source: z.string().min(1).max(128),
  messageId: z.string().min(1).max(1024),
  direction: z.enum(["older", "newer"]),
});
function encodeChatHistoryPageCursor(cursor                       )                     {
  if (!cursorSchema.safeParse(cursor).success) {
    return undefined;
  }
  const encoded = PREFIX + Buffer.from(JSON.stringify(cursor)).toString("base64url");
  return encoded.length <= MAX_CURSOR_CHARS ? encoded : undefined;
}
export function resolveChatHistoryPageCursors(
  anchor                                   ,
  capped           ,
  original           ,
)                                                               {
  if (!anchor) {
    return {};
  }
  const oldest = readChatHistoryMessageId(capped[0]) ?? anchor.oldestMessageId;
  const newest = readChatHistoryMessageId(capped.at(-1)) ?? anchor.newestMessageId;
  const cursor = (messageId        , direction                                    ) =>
    encodeChatHistoryPageCursor({
      sessionId: anchor.sessionId,
      source: anchor.source,
      messageId,
      direction,
    });
  return {
    ...(oldest &&
    (anchor.hasOlder || (capped.length > 0 && oldest !== readChatHistoryMessageId(original[0])))
      ? { olderCursor: cursor(oldest, "older") }
      : {}),
    ...(newest &&
    (anchor.hasNewer || (capped.length > 0 && newest !== readChatHistoryMessageId(original.at(-1))))
      ? { newerCursor: cursor(newest, "newer") }
      : {}),
  };
}
export { PREFIX, MAX_CURSOR_CHARS, cursorSchema, encodeChatHistoryPageCursor };