import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../../packages/normalization-core/src/string-coerce.mjs";
import { CHAT_PENDING_INPUT_MESSAGE_PREFIX } from "../../../packages/gateway-protocol/src/schema/chat-history-constants.mjs";
import { jsonUtf8Bytes } from "../../infra/json-utf8-bytes.mjs";
import { projectChatDisplayMessage } from "../chat-display-projection.core.mjs";
export function readChatHistoryReplyMessageId(message         )                     {
  const record = asOptionalRecord(message);
  return (
    normalizeOptionalString(asOptionalRecord(record?.["__openclaw"])?.replyToId) ??
    (record?.role === "assistant"
      ? normalizeOptionalString(asOptionalRecord(record.openclawDelivery)?.replyToId)
      : undefined)
  );
}
export async function attachChatHistoryReplyMessages(
  messages           ,
  params                       ,
  options       
                                 
                                                             
       
                  
                                  
                                                            
      
                                  
   ,
)                     {
  const replies = new Map                              ();
  const result            = [];
  for (const message of messages) {
    const record = asOptionalRecord(message);
    const metadata = asOptionalRecord(record?.["__openclaw"]);
    const messageId = readChatHistoryReplyMessageId(message);
    if (!record || !messageId || !params.sessionId) {
      result.push(message);
      continue;
    }
    let reply = replies.get(messageId);
    if (!reply && messageId.startsWith(CHAT_PENDING_INPUT_MESSAGE_PREFIX)) {
      // Pending custody is joined separately; its namespace cannot select transcript rows.
      reply = { ok: false, unavailableReason: "not_found" };
    }
    if (!reply) {
      const original = await options.readers.readSessionMessageByIdAsync(
        {
          agentId: params.sessionAgentId,
          sessionId: params.sessionId,
          sessionKey: params.canonicalKey,
          storePath: params.storePath,
          sessionEntry: params.entry,
        },
        messageId,
        {
          allowResetArchiveFallback: true,
          historyVisibility: { sessionStartedAt: params.entry?.sessionStartedAt },
        },
      );
      const projected = original.message
        ? projectChatDisplayMessage(original.message, {
            maxChars: 500,
            includePluginSteering: params.includePluginSteering,
            subagentCoordination: options.readers.subagentCoordination,
            resolveCronJobName: options.resolveCronJobName,
            ...(options.deferProfileDisplay
              ? {}
              : { resolveCurrentUserProfileDisplay: options.resolveCurrentUserProfileDisplay }),
          })
        : undefined;
      // Quoted previews do not display model identity; keep role-specific model policy
      // at the response owner without introducing a nested disclosure site.
      const preview = projected ? { ...projected } : undefined;
      if (preview) {
        delete preview.provider;
        delete preview.model;
      }
      reply =
        original.oversized || (preview && jsonUtf8Bytes(preview) > 8 * 1024)
          ? { ok: false, unavailableReason: "oversized" }
          : preview
            ? { ok: true, message: preview }
            : { ok: false, unavailableReason: original.found ? "not_visible" : "not_found" };
      replies.set(messageId, reply);
    }
    result.push({ ...record, __openclaw: { ...metadata, replyToMessage: reply } });
  }
  return result;
}