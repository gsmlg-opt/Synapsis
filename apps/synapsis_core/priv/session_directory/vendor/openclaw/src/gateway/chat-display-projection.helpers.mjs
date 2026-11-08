import { safeParseJson } from "../../packages/normalization-core/src/json-coercion.mjs";
import {
  asOptionalObjectRecord as readObjectRecord,
  asOptionalRecord as readRecord,
} from "../../packages/normalization-core/src/record-coerce.mjs";
import { truncateUtf16Safe } from "../../packages/normalization-core/src/utf16-slice.mjs";
import { isMeaningfulMediaFact, readPersistedMediaFacts } from "../media/media-facts.mjs";
import { isRelativeAssistantMediaReference, splitMediaOutput } from "../media/parse-output.mjs";
import { normalizeInputProvenance } from "../sessions/input-provenance.mjs";
import { isAssistantTextContentBlockType as isAssistantTextContentType } from "../shared/chat-message-content.mjs";

export { isAssistantTextContentType };

                                  
               
                    
  

export const DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS = 8_000;

/** Removes private yield inputs from a display copy without changing the source argument objects. */
export function stripPrivateToolCallContextForDisplay(entry                         )          {
  if (entry.type !== "toolCall" || entry.name !== "sessions_yield") {
    return false;
  }
  let changed = false;
  for (const field of ["arguments", "input"]) {
    const toolInput = readRecord(entry[field]);
    if (!toolInput || !("message" in toolInput)) {
      continue;
    }
    const { message: _, ...publicInput } = toolInput;
    entry[field] = publicInput;
    changed = true;
  }
  return changed;
}

export function takeAssistantManagedMediaUrlsForDisplay(
  entry                         ,
  role        ,
)                                       {
  const delivery = role === "assistant" ? readRecord(entry.openclawDelivery) : undefined;
  const urls = Array.isArray(delivery?.mediaUrls)
    ? delivery.mediaUrls.filter((url)                => typeof url === "string")
    : [];
  if (!delivery || !Object.hasOwn(delivery, "mediaUrls")) {
    return { changed: false, urls };
  }
  const projectedDelivery = { ...delivery };
  delete projectedDelivery.mediaUrls;
  if (Object.keys(projectedDelivery).length > 0) {
    entry.openclawDelivery = projectedDelivery;
  } else {
    delete entry.openclawDelivery;
  }
  return { changed: true, urls };
}

/** Keeps managed attachment commands in the raw transcript while removing them from display text. */
export function stripAssistantMediaDirectivesForDisplay(
  text        ,
  managedMediaUrls                   ,
)         {
  if (managedMediaUrls.length === 0 || !/(?:^|[\r\n])\s*MEDIA:/iu.test(text)) {
    return text;
  }
  const managed = new Set(managedMediaUrls.map((url) => url.trim()).filter(Boolean));
  const parsed = splitMediaOutput(text, {
    extractAudioDirectives: false,
  });
  if (
    !parsed.mediaUrls?.some(
      (url) => isRelativeAssistantMediaReference(url) && managed.has(url.trim()),
    )
  ) {
    return text;
  }
  return (parsed.segments ?? [])
    .filter(
      (segment) =>
        segment.type !== "media" ||
        !isRelativeAssistantMediaReference(segment.url) ||
        !managed.has(segment.url.trim()),
    )
    .map((segment) => (segment.type === "media" ? `MEDIA:${segment.url}` : segment.text))
    .join("\n");
}

export function resolveEffectiveChatHistoryMaxChars(maxChars         )         {
  if (typeof maxChars === "number") {
    return maxChars;
  }
  return DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS;
}

export function truncateChatHistoryText(
  text        ,
  maxChars         = DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS,
  preserveExactPrefix = false,
  toolResultMaxChars         ,
)                                       {
  let limit = maxChars;
  if (toolResultMaxChars !== undefined && toolResultMaxChars < Math.min(text.length, maxChars)) {
    // Complete JSON drives source cards, Canvas, and structured output rendering.
    const preview = truncateUtf16Safe(text, maxChars);
    if (!/^\s*[[{]/u.test(preview) || safeParseJson(preview) === undefined) {
      limit = toolResultMaxChars;
    }
  }
  if (text.length <= limit) {
    return { text, truncated: false };
  }
  const prefix = truncateUtf16Safe(text, limit);
  return {
    text: preserveExactPrefix ? prefix : `${prefix}\n...(truncated)...`,
    truncated: true,
  };
}

export function extractAssistantTextForSilentCheck(message         )                     {
  const entry = readObjectRecord(message);
  if (entry?.role !== "assistant") {
    return undefined;
  }
  if (typeof entry.text === "string") {
    return entry.text;
  }
  if (typeof entry.content === "string") {
    return entry.content;
  }
  if (!Array.isArray(entry.content) || entry.content.length === 0) {
    return undefined;
  }

  const texts           = [];
  for (const block of entry.content) {
    const typed = readObjectRecord(block);
    if (!typed) {
      return undefined;
    }
    if (isAssistantInternalReasoningContentType(typed.type)) {
      continue;
    }
    if (!isAssistantTextContentType(typed.type) || typeof typed.text !== "string") {
      return undefined;
    }
    texts.push(typed.text);
  }
  return texts.length > 0 ? texts.join("\n") : undefined;
}

export function isAssistantInternalReasoningContentType(type         )          {
  return type === "thinking" || type === "reasoning" || type === "redacted_thinking";
}

export function hasAssistantNonTextContent(message         , includeReasoning = true)          {
  const content = readObjectRecord(message)?.content;
  return (
    Array.isArray(content) &&
    content.some((block) => {
      const entry = readObjectRecord(block);
      return (
        entry &&
        !isAssistantTextContentType(entry.type) &&
        (includeReasoning || !isAssistantInternalReasoningContentType(entry.type))
      );
    })
  );
}

export function hasAssistantDisplayableNonTextContent(message         )          {
  return hasAssistantNonTextContent(message, false);
}

export function shouldPreserveAssistantControlReplyText(message                         )          {
  if (isProjectedForwardedMessage(message)) {
    return true;
  }
  return hasAssistantDisplayableNonTextContent(message);
}

export function asRoleContentMessage(message                         )                            {
  const role = typeof message.role === "string" ? message.role.toLowerCase() : "";
  if (!role) {
    return null;
  }
  return {
    ...message,
    role,
    ...(message.content !== undefined
      ? { content: message.content }
      : message.text !== undefined
        ? { content: message.text }
        : {}),
  };
}

export function isEmptyTextOnlyContent(content         )          {
  if (typeof content === "string") {
    return content.trim().length === 0;
  }
  if (!Array.isArray(content)) {
    return false;
  }
  for (const block of content) {
    const entry = readObjectRecord(block);
    if (entry?.type !== "text" || typeof entry.text !== "string" || entry.text.trim().length > 0) {
      return false;
    }
  }
  return true;
}

export function hasTranscriptMediaFacts(message                         )          {
  return (readPersistedMediaFacts(message) ?? []).some(isMeaningfulMediaFact);
}

export function extractProjectedText(content         )         {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }
  const parts           = [];
  for (const block of content) {
    const text = readObjectRecord(block)?.text;
    if (typeof text === "string") {
      parts.push(text);
    }
  }
  return parts.join("\n");
}

export function isCronRunMessage(message                         )          {
  const provenance = normalizeInputProvenance(message.provenance);
  return (
    provenance?.kind === "internal_system" &&
    provenance.sourceTool === "cron" &&
    Boolean(provenance.jobId && provenance.runId && provenance.sourceSessionKey)
  );
}

export function isForwardedUserMessage(message                         )          {
  return message.role === "user" && hasForwardedMessageProvenance(message);
}

export function isProjectedForwardedMessage(message                         )          {
  return message.role === "assistant" && hasForwardedMessageProvenance(message);
}

function hasForwardedMessageProvenance(message                         )          {
  const provenance = normalizeInputProvenance(message.provenance);
  return (
    (provenance?.kind === "inter_session" && provenance.sourceTool === "sessions_send") ||
    isCronRunMessage(message)
  );
}
