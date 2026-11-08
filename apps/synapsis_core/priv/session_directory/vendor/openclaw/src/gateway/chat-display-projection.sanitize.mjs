import { estimateBase64DecodedBytes } from "../../packages/media-core/src/base64.mjs";
import { asFiniteNumber } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalObjectRecord as readObjectRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { asOptionalRecord as readRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { prepareAgentRunReplyText } from "../agents/agent-run-terminal-reply.mjs";
import { normalizeContextUsage } from "../agents/usage.mjs";
import { parseInboundMediaUri } from "../media/inbound-media-uri.mjs";
import { buildInboundMediaUriFromPath } from "../media/media-reference.mjs";
import { STATE_CONTENTION_DIAGNOSTIC } from "../sessions/session-run-error-presentation.mjs";
import { isSilentAssistantTranscriptMessage } from "../shared/chat-message-content.mjs";
import { parseAssistantTextSignature } from "../shared/chat-message-content.mjs";
import { readAssistantTextBlocksForPhase } from "../shared/chat-message-content.mjs";
import { readTerminalSourceReplyDeliveryMirror } from "../shared/chat-message-content.mjs";
import { resolveAssistantMessagePhase } from "../shared/chat-message-content.mjs";
import { isToolHistoryBlockType } from "./chat-display-projection.canvas.mjs";
import { isToolResultHistoryBlockType } from "./chat-display-projection.canvas.mjs";
import { messageHasToolResultShape } from "./chat-display-projection.canvas.mjs";
import { projectToolResultDetails } from "./chat-display-projection.canvas.mjs";
import { projectAssistantCommentaryFallbacks } from "./chat-display-projection.commentary.mjs";
import { DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS } from "./chat-display-projection.helpers.mjs";
import { hasTranscriptMediaFacts } from "./chat-display-projection.helpers.mjs";
import { isAssistantTextContentBlockType as isAssistantTextContentType } from "../shared/chat-message-content.mjs";
import { isProjectedForwardedMessage } from "./chat-display-projection.helpers.mjs";
import { shouldPreserveAssistantControlReplyText } from "./chat-display-projection.helpers.mjs";
import { stripAssistantMediaDirectivesForDisplay } from "./chat-display-projection.helpers.mjs";
import { stripPrivateToolCallContextForDisplay } from "./chat-display-projection.helpers.mjs";
import { takeAssistantManagedMediaUrlsForDisplay } from "./chat-display-projection.helpers.mjs";
import { truncateChatHistoryText } from "./chat-display-projection.helpers.mjs";
import { projectWorkspaceResultConflict } from "./worker-environments/workspace-conflicts.mjs";
import { WORKSPACE_CONFLICT_TRANSCRIPT_TYPE } from "./worker-environments/workspace-conflicts.mjs";
const MEDIA_PRIVATE_FIELDS = ["data", "blob", "path", "file", "filePath", "localPath"]         ;
const MEDIA_REFERENCE_FIELDS = ["url", "openUrl", "image_url", "audio_url", "video_url"]         ;
const MEDIA_FACT_PRIVATE_FIELDS = [
  "workspaceDir",
  ...MEDIA_PRIVATE_FIELDS.filter((field) => field !== "path"),
]         ;
function projectChatHistoryMediaReference(value         )                     {
  if (typeof value !== "string") {
    return undefined;
  }
  const reference = value.trim();
  if (/^\/(?:api\/chat\/media\/outgoing|media|__openclaw__)\//u.test(reference)) {
    return reference.split(/[?#]/u, 1)[0];
  }
  try {
    if (/^media:/iu.test(reference)) {
      return parseInboundMediaUri(reference)?.normalizedSource;
    }
    const url = new URL(reference);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return undefined;
    }
    url.username = url.password = url.search = url.hash = "";
    return url.toString();
  } catch {
    return undefined;
  }
}
function projectChatHistoryMediaBlock(entry                         , fact = false)          {
  if (!fact && (typeof entry.type !== "string" || !/^(?:image|audio|video)$/u.test(entry.type))) {
    return false;
  }
  const media = entry                                                        ;
  const hasTopLevelPayload = typeof media.data === "string" || typeof media.blob === "string";
  const source = fact ? undefined : readRecord(media.source);
  const projectedSource = source ? { ...source } : undefined;
  const records                            = [media, ...(projectedSource ? [projectedSource] : [])];
  if (projectedSource) {
    media.source = projectedSource;
  }
  const privateFields = fact ? MEDIA_FACT_PRIVATE_FIELDS : MEDIA_PRIVATE_FIELDS;
  const referenceFields = fact ? (["path", "url"]         ) : MEDIA_REFERENCE_FIELDS;
  const sourceIsReference =
    !source &&
    (!fact ||
      typeof media.source !== "string" ||
      /^(?:[a-z][a-z0-9+.-]*:|~?[\\/])|[\\/]/iu.test(media.source));
  let encodedPayload                    ;
  for (const record of records) {
    let omitted = false;
    const payload = typeof record.data === "string" ? record.data : record.blob;
    if (encodedPayload === undefined && typeof payload === "string") {
      encodedPayload = payload;
    }
    for (const field of privateFields) {
      if (!Object.hasOwn(record, field)) {
        continue;
      }
      delete record[field];
      omitted = true;
    }
    const recordReferences =
      record === media && sourceIsReference ? [...referenceFields, "source"] : referenceFields;
    for (const field of recordReferences) {
      if (!Object.hasOwn(record, field)) {
        continue;
      }
      // Managed inbound file paths persisted on media facts are host-local absolute
      // paths; rewrite them to canonical `media://inbound/<id>` URIs the UI loads through
      // the authenticated assistant-media route, instead of redacting the reference entirely.
      const inboundUri = fact ? buildInboundMediaUriFromPath(String(record[field])) : undefined;
      const projected = inboundUri ?? projectChatHistoryMediaReference(record[field]);
      record[field] = projected;
      if (projected === undefined) {
        delete record[field];
        omitted = true;
      }
    }
    if (!fact && omitted) {
      // Preserve shipped image/audio omission ownership; new video blocks mark both levels.
      if (record === media || media.type !== "image") {
        record.omitted = true;
      }
      if (record === media || media.type !== "audio") {
        media.omitted = true;
      }
    }
  }
  if (!fact && encodedPayload !== undefined) {
    (media.type === "audio" && !hasTopLevelPayload && projectedSource
      ? projectedSource
      : media
    ).bytes = estimateBase64DecodedBytes(encodedPayload);
  }
  return true;
}
function projectChatHistoryAttachmentBlock(entry                         )          {
  if (entry.type !== "attachment") {
    return false;
  }
  const attachment = readRecord(entry.attachment);
  if (!attachment) {
    return false;
  }
  const projected = { ...attachment };
  for (const field of MEDIA_PRIVATE_FIELDS) {
    delete projected[field];
  }
  const url = projectChatHistoryMediaReference(projected.url);
  if (!url) {
    delete projected.url;
  } else {
    projected.url = url;
  }
  entry.attachment = projected;
  return true;
}
function projectChatHistoryMediaFacts(value         )                        {
  return Array.isArray(value)
    ? value.map((fact) => {
        const projected = { ...readRecord(fact) };
        projectChatHistoryMediaBlock(projected, true);
        return projected;
      })
    : undefined;
}
export function sanitizeChatHistoryContentBlock(
  block         ,
  opts                                                                                         ,
)                                                           {
  if (!block || typeof block !== "object") {
    return { block, changed: false, truncated: false };
  }
  const entry = { ...(block                           ) };
  let changed = stripPrivateToolCallContextForDisplay(entry);
  // Display-cap truncation is a fact consumers need (to fetch the full row), so
  // it is tracked apart from `changed`, which also covers metadata stripping.
  let truncated = false;
  const preserveExactToolPayload =
    opts?.preserveExactToolPayload === true || isToolHistoryBlockType(entry.type);
  const maxChars = opts?.maxChars ?? DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS;
  const toolResultMaxChars =
    opts?.preserveExactToolPayload || isToolResultHistoryBlockType(entry.type)
      ? opts?.toolResultMaxChars
      : undefined;
  if (isToolResultHistoryBlockType(entry.type) && "details" in entry) {
    const projectedDetails = projectToolResultDetails(entry.details, maxChars);
    if (projectedDetails.details) {
      entry.details = projectedDetails.details;
    } else {
      delete entry.details;
    }
    changed = true;
    truncated ||= projectedDetails.truncated;
  }
  if (preserveExactToolPayload && Array.isArray(entry.content)) {
    // Some transcripts carry both nested output blocks and their joined text.
    // Keep one representation, and apply the same media privacy rules recursively.
    const text = entry.content
      .flatMap((item) => {
        const value = readRecord(item)?.text;
        return typeof value === "string" ? [value] : [];
      })
      .join("\n");
    if (entry.text === text) {
      delete entry.text;
      changed = true;
    }
    const content = entry.content.map((item) =>
      sanitizeChatHistoryContentBlock(item, {
        preserveExactToolPayload: true,
        maxChars,
        toolResultMaxChars,
      }),
    );
    if (content.some((item) => item.changed)) {
      entry.content = content.map((item) => item.block);
      changed = true;
    }
    truncated ||= content.some((item) => item.truncated);
  }
  for (const field of ["text", "content", "partialJson", "arguments", "thinking"]         ) {
    if (
      typeof entry[field] !== "string" ||
      (preserveExactToolPayload && (field === "partialJson" || field === "arguments"))
    ) {
      continue;
    }
    const res = truncateChatHistoryText(
      entry[field],
      maxChars,
      preserveExactToolPayload && (field === "text" || field === "content"),
      field === "text" || field === "content" ? toolResultMaxChars : undefined,
    );
    entry[field] = res.text;
    changed ||= res.truncated;
    truncated ||= res.truncated;
  }
  for (const field of ["thinkingSignature", "openclawReasoningReplay"]) {
    if (field in entry) {
      delete entry[field];
      changed = true;
    }
  }
  const mediaChanged = projectChatHistoryMediaBlock(entry);
  const attachmentChanged = projectChatHistoryAttachmentBlock(entry);
  changed ||= mediaChanged || attachmentChanged;
  return { block: changed ? entry : block, changed, truncated };
}
function sanitizeAssistantPhasedContentBlocks(content           )            {
  const hasExplicitPhasedText = content.some((block) => {
    const entry = readObjectRecord(block);
    return (
      entry && isAssistantTextContentType(entry.type) && parseAssistantTextSignature(entry)?.phase
    );
  });
  if (!hasExplicitPhasedText) {
    return content;
  }
  const filtered = content.filter((block) => {
    const entry = readObjectRecord(block);
    return (
      !entry ||
      !isAssistantTextContentType(entry.type) ||
      parseAssistantTextSignature(entry)?.phase === "final_answer"
    );
  });
  return filtered.length === content.length ? content : filtered;
}
function projectAssistantMixedToolContent(content           , maxChars        )                   {
  const hasToolHistoryBlock = content.some((block) =>
    isToolHistoryBlockType(readObjectRecord(block)?.type),
  );
  if (!hasToolHistoryBlock) {
    return null;
  }

  let hasVisibleText = false;
  const projectedContent            = [];
  for (const block of content) {
    const entry = readObjectRecord(block);
    if (!entry) {
      continue;
    }
    if (!isAssistantTextContentType(entry.type)) {
      projectedContent.push(block);
      continue;
    }
    if (parseAssistantTextSignature(entry)?.phase === "commentary") {
      continue;
    }
    if (typeof entry.text !== "string" || !entry.text.trim()) {
      continue;
    }
    const truncated = truncateChatHistoryText(entry.text, maxChars);
    if (truncated.text.trim()) {
      projectedContent.push({ type: "text", text: truncated.text });
      hasVisibleText = true;
    }
  }

  // Mixed messages supply both the visible bubble and its reasoning/tool trace.
  // Keep structured siblings or a history reload loses activity shown while live.
  return hasVisibleText ? projectedContent : null;
}
const COST_FIELDS = ["input", "output", "cacheRead", "cacheWrite", "total"]         ;
const USAGE_FIELDS = [
  "input",
  "output",
  "total",
  "totalTokens",
  "inputTokens",
  "outputTokens",
  "promptTokens",
  "completionTokens",
  "cacheRead",
  "cacheWrite",
  "cache_read_input_tokens",
  "cache_creation_input_tokens",
  "input_tokens",
  "output_tokens",
  "prompt_tokens",
  "completion_tokens",
  "total_tokens",
]         ;
function sanitizeNumericMetadata(
  raw         ,
  fields                   ,
)                                      {
  const record = readObjectRecord(raw);
  if (!record) {
    return undefined;
  }
  const projected                          = {};
  for (const key of fields) {
    const value = asFiniteNumber(record[key]);
    if (value !== undefined) {
      projected[key] = value;
    }
  }
  if (fields === USAGE_FIELDS) {
    const state = readObjectRecord(record.usageReport)?.state;
    if (state === "available" || state === "unavailable") {
      projected.usageReport = { state };
    }
    const cost = sanitizeNumericMetadata(record.cost, COST_FIELDS);
    if (cost) {
      projected.cost = cost;
    }
    const contextUsage = normalizeContextUsage(record.contextUsage);
    if (contextUsage) {
      projected.contextUsage = contextUsage;
    }
  }
  return Object.keys(projected).length > 0 ? projected : undefined;
}
function projectWorkspaceConflictDetails(
  entry                         ,
)                                      {
  if (entry.role !== "custom" || entry.customType !== WORKSPACE_CONFLICT_TRANSCRIPT_TYPE) {
    return undefined;
  }
  const details = readRecord(entry.details);
  if (
    !details ||
    !Array.isArray(details.paths) ||
    details.paths.length === 0 ||
    !details.paths.every(
      (entryPath)                      => typeof entryPath === "string" && entryPath.length > 0,
    ) ||
    typeof details.stagedResultRef !== "string" ||
    !/^refs\/openclaw\/worker-results\/[A-Za-z0-9-]+$/u.test(details.stagedResultRef) ||
    (details.totalCount !== undefined &&
      (!Number.isSafeInteger(details.totalCount) ||
        (details.totalCount          ) < details.paths.length))
  ) {
    return undefined;
  }
  try {
    return projectWorkspaceResultConflict(
      details.paths,
      details.stagedResultRef,
      details.totalCount                      ,
    );
  } catch {
    return undefined;
  }
}
export function prepareAssistantHistoryMessage(message         )          {
  const entry = readObjectRecord(message);
  if (
    entry?.role !== "assistant" ||
    entry.display === true ||
    entry.display === false ||
    readTerminalSourceReplyDeliveryMirror(entry) ||
    isProjectedForwardedMessage(entry)
  ) {
    return message;
  }
  const field = typeof entry.text === "string" ? "text" : "content";
  const inlineText = entry[field];
  if (typeof inlineText !== "string" && !Array.isArray(entry.content)) {
    return message;
  }
  const finalBlocks = readAssistantTextBlocksForPhase(entry, "final_answer");
  const blocks = finalBlocks.length ? finalBlocks : readAssistantTextBlocksForPhase(entry);
  const rawText =
    typeof inlineText === "string" ? inlineText : blocks.map((block) => block.text).join("");
  const text = prepareAgentRunReplyText(rawText);
  if (text === undefined || text === rawText) {
    return message;
  }
  // History is projected more than once. This is already prepared text,
  // even when it is itself NO_REPLY or starts with another control-looking line.
  if (typeof inlineText === "string") {
    return { ...entry, [field]: text, display: true };
  }
  let remainingPrefix = rawText.endsWith(text) ? rawText.length - text.length : 0;
  let remainingLength = text.length;
  const replacements = new Map                  ();
  for (const block of blocks) {
    const removed = Math.min(remainingPrefix, block.text.length);
    remainingPrefix -= removed;
    const visible = block.text.slice(removed, removed + remainingLength);
    remainingLength -= visible.length;
    if (visible !== block.text) {
      replacements.set(block, { ...block, text: visible });
    }
  }
  return {
    ...entry,
    content: Array.isArray(entry.content)
      ? entry.content.map((block) => replacements.get(block) ?? block)
      : entry.content,
    display: true,
  };
}
export function sanitizeChatHistoryMessage(
  message         ,
  maxChars         = DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS,
  toolResultMaxChars         ,
)                                         {
  if (!message || typeof message !== "object") {
    return { message, changed: false };
  }
  const prepared = prepareAssistantHistoryMessage(message);
  const entry = { ...(prepared                           ) };
  let changed = prepared !== message;
  let truncated = false;
  if ("providerReplay" in entry) {
    delete entry.providerReplay;
    changed = true;
  }
  const openClawMeta = readRecord(entry["__openclaw"]);
  if (
    openClawMeta &&
    ("upstreamUserText" in openClawMeta ||
      "modelPromptProjection" in openClawMeta ||
      "sessionSendDelivery" in openClawMeta ||
      "requesterOrigin" in openClawMeta ||
      "chatInputRecovery" in openClawMeta ||
      "media" in openClawMeta)
  ) {
    // Codex retains the decorated upstream prompt for transcript reconstruction.
    // It is not display data and can otherwise evict the visible row from history.
    const projectedMeta = { ...openClawMeta };
    delete projectedMeta.upstreamUserText;
    // Captured model input is private replay state, not part of the display transcript.
    delete projectedMeta.modelPromptProjection;
    // Durable delivery facts contain private endpoint bindings, not display data.
    delete projectedMeta.sessionSendDelivery;
    // Operational requester custody is independent of redacted display identity.
    delete projectedMeta.requesterOrigin;
    delete projectedMeta.chatInputRecovery;
    if ("media" in projectedMeta) {
      projectedMeta.media = projectChatHistoryMediaFacts(projectedMeta.media);
      if (projectedMeta.media === undefined) {
        delete projectedMeta.media;
      }
    }
    if (Object.keys(projectedMeta).length > 0) {
      entry["__openclaw"] = projectedMeta;
    } else {
      delete entry["__openclaw"];
    }
    changed = true;
  }
  const role = typeof entry.role === "string" ? entry.role.toLowerCase() : "";
  const managedMedia = takeAssistantManagedMediaUrlsForDisplay(entry, role);
  changed ||= managedMedia.changed;
  const preserveExactToolPayload =
    role === "toolresult" ||
    role === "tool_result" ||
    role === "tool" ||
    role === "function" ||
    typeof entry.toolName === "string" ||
    typeof entry.tool_name === "string" ||
    typeof entry.toolCallId === "string" ||
    typeof entry.tool_call_id === "string";
  const resultMaxChars =
    preserveExactToolPayload && messageHasToolResultShape(entry) ? toolResultMaxChars : undefined;

  if ("details" in entry) {
    const conflictDetails = projectWorkspaceConflictDetails(entry);
    const toolResultDetails =
      !conflictDetails && messageHasToolResultShape(entry)
        ? projectToolResultDetails(entry.details, maxChars)
        : undefined;
    // Only the terminal owner's presentation category crosses this report boundary.
    // Correlation is projected separately; raw diagnostics and report fields stay private.
    const runFailureDetails =
      entry.role === "custom" &&
      entry.customType === "run-failed-before-reply" &&
      readRecord(entry.details)?.errorKind === "state_contention"
        ? { errorKind: "state_contention", diagnostic: STATE_CONTENTION_DIAGNOSTIC }
        : undefined;
    const projectedDetails = conflictDetails ?? toolResultDetails?.details ?? runFailureDetails;
    if (projectedDetails) {
      entry.details = projectedDetails;
    } else {
      delete entry.details;
    }
    changed = true;
    truncated ||= toolResultDetails?.truncated === true;
  }

  for (const field of ["usage", "cost"]         ) {
    if (!(field in entry)) {
      continue;
    }
    const sanitized =
      entry.role === "assistant"
        ? sanitizeNumericMetadata(entry[field], field === "usage" ? USAGE_FIELDS : COST_FIELDS)
        : undefined;
    if (sanitized) {
      entry[field] = sanitized;
    } else {
      delete entry[field];
    }
    changed = true;
  }

  const stripAssistantMedia =
    role === "assistant" && !shouldPreserveAssistantControlReplyText(entry);

  const projectText = (text        ) => {
    const controlStripped = stripAssistantMedia
      ? stripAssistantMediaDirectivesForDisplay(text, managedMedia.urls)
      : text;
    changed ||= controlStripped !== text;
    const res = truncateChatHistoryText(
      controlStripped,
      maxChars,
      preserveExactToolPayload,
      resultMaxChars,
    );
    changed ||= res.truncated;
    truncated ||= res.truncated;
    return res.text;
  };
  if (typeof entry.content === "string") {
    entry.content = projectText(entry.content);
  } else if (Array.isArray(entry.content)) {
    const content = entry.content;
    const commentary = readRecord(entry.openclawStreamFallback)?.source === "segment";
    let remainingText = maxChars;
    let updated                       ;
    for (let index = 0; index < content.length; index++) {
      const rawBlock = commentary ? readRecord(content[index]) : undefined;
      const rawText =
        rawBlock && isAssistantTextContentType(rawBlock.type) && typeof rawBlock.text === "string"
          ? rawBlock.text
          : undefined;
      if (rawText !== undefined && remainingText <= 0) {
        updated ??= content.slice();
        updated[index] = undefined;
        truncated ||= rawText.length > 0;
        continue;
      }
      const sanitized = sanitizeChatHistoryContentBlock(content[index], {
        preserveExactToolPayload,
        maxChars: rawText === undefined ? maxChars : remainingText,
        toolResultMaxChars,
      });
      if (rawText !== undefined) {
        remainingText -= rawText.length + 1;
      }
      const contentBlock = stripAssistantMedia ? readRecord(sanitized.block) : undefined;
      if (
        contentBlock &&
        isAssistantTextContentType(contentBlock.type) &&
        typeof contentBlock.text === "string"
      ) {
        const text = stripAssistantMediaDirectivesForDisplay(contentBlock.text, managedMedia.urls);
        if (text !== contentBlock.text) {
          sanitized.block = { ...contentBlock, text };
          sanitized.changed = true;
        }
      }
      if (sanitized.changed) {
        updated ??= content.slice();
        updated[index] = sanitized.block;
      }
      truncated ||= sanitized.truncated;
    }
    if (updated) {
      entry.content = commentary ? updated.filter((block) => block !== undefined) : updated;
      changed = true;
    }
    if (entry.role === "assistant" && Array.isArray(entry.content)) {
      const mixedToolContent = projectAssistantMixedToolContent(entry.content, maxChars);
      if (mixedToolContent) {
        entry.content = mixedToolContent;
        if (entry.phase === "commentary") {
          delete entry.phase;
        }
        changed = true;
      } else {
        const sanitizedPhases = sanitizeAssistantPhasedContentBlocks(entry.content);
        if (sanitizedPhases !== entry.content) {
          entry.content = sanitizedPhases;
          changed = true;
        }
      }
    }
  }

  if (typeof entry.text === "string") {
    entry.text = projectText(entry.text);
  }

  if (truncated) {
    // Record the display cap where it is applied so any session.message or
    // chat.history consumer can tell a bounded preview from the full row and
    // fetch it via chat.message.get. An upstream "oversized" transcript
    // marker already explains the truncation; never overwrite its reason.
    const meta = readRecord(entry["__openclaw"]);
    entry["__openclaw"] = {
      ...meta,
      truncated: true,
      reason: typeof meta?.reason === "string" ? meta.reason : "display-cap",
    };
    changed = true;
  }

  return { message: changed ? entry : message, changed };
}
function hasAssistantMixedToolVisibleText(message         )          {
  const content = readObjectRecord(message)?.content;
  if (!Array.isArray(content)) {
    return false;
  }
  let hasToolHistoryBlock = false;
  let hasText = false;
  for (const block of content) {
    const entry = readObjectRecord(block);
    if (!entry) {
      continue;
    }
    if (isToolHistoryBlockType(entry.type)) {
      hasToolHistoryBlock = true;
    }
    if (
      isAssistantTextContentType(entry.type) &&
      typeof entry.text === "string" &&
      entry.text.trim()
    ) {
      hasText = true;
    }
  }
  return hasToolHistoryBlock && hasText;
}
export function shouldDropAssistantHistoryMessage(message         )          {
  const entry = readObjectRecord(message);
  if (entry?.role !== "assistant") {
    return false;
  }
  if (entry.display === false) {
    return true;
  }
  if (entry.display === true || readTerminalSourceReplyDeliveryMirror(entry)) {
    return false;
  }
  if (isProjectedForwardedMessage(entry)) {
    return false;
  }
  if (resolveAssistantMessagePhase(message) === "commentary") {
    return !hasAssistantMixedToolVisibleText(message);
  }
  return isSilentAssistantTranscriptMessage(message);
}
export function sanitizeChatHistoryMessages(
  messages           ,
  maxChars         = DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS,
  opts                                                                        ,
)            {
  if (messages.length === 0) {
    return messages;
  }
  let changed = false;
  const next            = [];
  for (const original of messages) {
    let message = original;
    if (opts?.includeCommentaryFallbacks === true) {
      const projection = projectAssistantCommentaryFallbacks(message, maxChars);
      message = projection.message;
      changed ||= message !== original;
      for (const commentary of projection.fallbacks) {
        changed = true;
        const hasMediaFacts = hasTranscriptMediaFacts(readRecord(commentary) ?? {});
        if (!hasMediaFacts && shouldDropAssistantHistoryMessage(commentary)) {
          continue;
        }
        const projected = sanitizeChatHistoryMessage(
          commentary,
          maxChars,
          opts?.toolResultMaxChars,
        );
        next.push(projected.message);
      }
    }
    if (shouldDropAssistantHistoryMessage(message)) {
      changed = true;
      continue;
    }
    const res = sanitizeChatHistoryMessage(message, maxChars, opts?.toolResultMaxChars);
    changed ||= res.changed;
    next.push(res.message);
  }
  return changed ? next : messages;
}
export { MEDIA_PRIVATE_FIELDS, MEDIA_REFERENCE_FIELDS, MEDIA_FACT_PRIVATE_FIELDS, projectChatHistoryMediaReference, projectChatHistoryMediaBlock, projectChatHistoryAttachmentBlock, projectChatHistoryMediaFacts, sanitizeAssistantPhasedContentBlocks, projectAssistantMixedToolContent, COST_FIELDS, USAGE_FIELDS, sanitizeNumericMetadata, projectWorkspaceConflictDetails, hasAssistantMixedToolVisibleText };