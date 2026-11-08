import { asOptionalObjectRecord as readObjectRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { asOptionalRecord as readRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { truncateUtf16Safe } from "../../packages/normalization-core/src/utf16-slice.mjs";
import { extractCanvasFromDetails } from "../chat/canvas-render.mjs";
import { extractCanvasFromText } from "../chat/canvas-render.mjs";
import { isToolCallContentType } from "../chat/tool-content.mjs";
import { isToolResultContentType } from "../chat/tool-content.mjs";
import { MAX_TOOL_APPROVAL_REVIEWS } from "../shared/tool-approval-reviews.mjs";
import { normalizeToolApprovalReview } from "../shared/tool-approval-reviews.mjs";
import { truncateChatHistoryText } from "./chat-display-projection.helpers.mjs";
function isDisplayRouteIdentifier(value         , maxChars        )                  {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maxChars &&
    value.trim() === value
  );
}
export function isToolHistoryBlockType(type         )          {
  if (typeof type !== "string") {
    return false;
  }
  const normalized = type.trim();
  return isToolCallContentType(normalized) || isToolResultContentType(normalized);
}
export function isToolResultHistoryBlockType(type         )          {
  return typeof type === "string" && isToolResultContentType(type.trim());
}
export function projectToolResultDetails(
  details         ,
  maxChars        ,
)                                                                       {
  const record = readRecord(details);
  if (!record) {
    return { details: undefined, truncated: false };
  }
  const projected                          = {};
  const browserTab = readRecord(record.browserTab);
  // A partial or shortened address can select a different browser. Only display
  // text may be truncated; route identifiers must survive projection unchanged.
  if (
    isDisplayRouteIdentifier(browserTab?.targetId, 128) &&
    isDisplayRouteIdentifier(browserTab?.profile, 128) &&
    ((browserTab?.target === "host" && browserTab.node === undefined) ||
      (browserTab?.target === "node" && isDisplayRouteIdentifier(browserTab.node, 256)))
  ) {
    projected.browserTab = {
      targetId: browserTab.targetId,
      profile: browserTab.profile,
      target: browserTab.target,
      ...(browserTab.target === "node" ? { node: browserTab.node } : {}),
      ...(typeof browserTab.url === "string"
        ? { url: truncateUtf16Safe(browserTab.url, 2_048) }
        : {}),
      ...(typeof browserTab.title === "string"
        ? { title: truncateUtf16Safe(browserTab.title, 512) }
        : {}),
    };
  }
  // Surface capped detail fields through the same message-level display marker.
  let truncated = false;
  for (const key of ["exitCode", "durationMs"]         ) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      projected[key] = value;
    }
  }
  if (typeof record.cwd === "string") {
    const cwd = truncateChatHistoryText(record.cwd, maxChars);
    projected.cwd = cwd.text;
    truncated ||= cwd.truncated;
  }
  if (isDisplayRouteIdentifier(record.sessionKey, maxChars)) {
    projected.sessionKey = record.sessionKey;
  }
  for (const key of ["ok", "changed", "created"]         ) {
    if (typeof record[key] === "boolean") {
      projected[key] = record[key];
    }
  }
  if (typeof record.diff === "string" && record.diff.trim()) {
    const diff = truncateChatHistoryText(record.diff, maxChars);
    projected.diff = diff.text;
    truncated ||= diff.truncated;
  }
  if (Array.isArray(record.approvalReviews)) {
    const reviews = record.approvalReviews
      .slice(-MAX_TOOL_APPROVAL_REVIEWS)
      .flatMap((review) => normalizeToolApprovalReview(review) ?? []);
    if (reviews.length > 0) {
      projected.approvalReviews = reviews;
    }
  }
  const reviewOutcome = record.approvalReviewOutcome;
  if (reviewOutcome === "approved" || reviewOutcome === "denied" || reviewOutcome === "reviewing") {
    projected.approvalReviewOutcome = reviewOutcome;
  }
  const preview = extractCanvasFromDetails(record);
  if (preview?.mcpApp && preview.viewId) {
    projected.mcpAppPreview = {
      kind: "canvas",
      view: {
        id: preview.viewId,
        ...(preview.url ? { url: preview.url } : {}),
        ...(preview.title ? { title: preview.title } : {}),
      },
      presentation: {
        target: "assistant_message",
        ...(preview.title ? { title: preview.title } : {}),
        ...(preview.preferredHeight ? { preferred_height: preview.preferredHeight } : {}),
        ...(preview.sandbox ? { sandbox: preview.sandbox } : {}),
      },
      mcpApp: preview.mcpApp,
    };
  }
  return { details: Object.keys(projected).length > 0 ? projected : undefined, truncated };
}
export function messageHasToolResultShape(message                         )          {
  const role = typeof message.role === "string" ? message.role.toLowerCase() : "";
  if (role === "toolresult" || role === "tool_result" || role === "tool" || role === "function") {
    return true;
  }
  const content = Array.isArray(message.content) ? message.content : [];
  if (content.some((block) => isToolResultHistoryBlockType(readObjectRecord(block)?.type))) {
    return true;
  }
  const hasToolCallBlock = content.some((block) => {
    const type = readObjectRecord(block)?.type;
    return isToolHistoryBlockType(type) && !isToolResultHistoryBlockType(type);
  });
  const hasToolId =
    typeof message.toolCallId === "string" ||
    typeof message.tool_call_id === "string" ||
    typeof message.toolUseId === "string" ||
    typeof message.tool_use_id === "string";
  const hasToolName = typeof message.toolName === "string" || typeof message.tool_name === "string";
  return hasToolId && hasToolName && !hasToolCallBlock;
}
export function extractChatHistoryBlockText(message         )                     {
  const entry = readObjectRecord(message);
  if (!entry) {
    return undefined;
  }
  if (typeof entry.content === "string") {
    return entry.content;
  }
  if (typeof entry.text === "string") {
    return entry.text;
  }
  if (!Array.isArray(entry.content)) {
    return undefined;
  }
  const textParts = entry.content
    .map((block) => readObjectRecord(block)?.text)
    .filter((value)                  => typeof value === "string");
  return textParts.length > 0 ? textParts.join("\n") : undefined;
}
function extractChatHistoryCanvasPreview(message                         ) {
  const direct = extractCanvasFromDetails(message.details);
  if (direct) {
    return direct;
  }
  if (!Array.isArray(message.content)) {
    return undefined;
  }
  for (const block of message.content) {
    const preview = extractCanvasFromDetails(readRecord(block)?.details);
    if (preview) {
      return preview;
    }
  }
  return undefined;
}
export function extractChatToolResultCanvasPreview(
  message         ,
)                                {
  const entry = readRecord(message);
  if (!entry) {
    return undefined;
  }
  const detailsPreview = extractChatHistoryCanvasPreview(entry);
  const text = detailsPreview ? undefined : extractChatHistoryBlockText(entry);
  const preview = detailsPreview ?? extractCanvasFromText(text);
  return preview ? { preview, rawText: detailsPreview ? null : (text ?? null) } : undefined;
}
export function appendChatCanvasBlocks   (
  content              ,
  previews                              ,
)                             {
  const baseContent                             = [...content];
  for (const { preview, rawText } of previews) {
    // Only retained blocks participate: rejecting an id collision must not
    // reserve that preview's different URL for subsequent previews.
    const alreadyPresent = baseContent.some((block) => {
      const typed = readObjectRecord(block);
      const existing = typed?.type === "canvas" ? readObjectRecord(typed.preview) : undefined;
      return Boolean(
        existing &&
        ((existing.viewId && existing.viewId === preview.viewId) ||
          (existing.url && existing.url === preview.url)),
      );
    });
    if (!alreadyPresent) {
      baseContent.push({ type: "canvas", preview, rawText });
    }
  }
  return baseContent;
}
export function appendChatCanvasBlocksToMessage(
  message                                     ,
  previews                              ,
)                                      {
  if (!message || previews.length === 0) {
    return message;
  }
  const content = Array.isArray(message.content)
    ? message.content
    : typeof message.content === "string"
      ? [{ type: "text", text: message.content }]
      : typeof message.text === "string"
        ? [{ type: "text", text: message.text }]
        : [];
  return { ...message, content: appendChatCanvasBlocks(content, previews) };
}
function messageContainsToolHistoryContent(entry                         )          {
  if (
    typeof entry.toolCallId === "string" ||
    typeof entry.tool_call_id === "string" ||
    typeof entry.toolName === "string" ||
    typeof entry.tool_name === "string"
  ) {
    return true;
  }
  if (!Array.isArray(entry.content)) {
    return false;
  }
  return entry.content.some((block) => isToolHistoryBlockType(readObjectRecord(block)?.type));
}
export function augmentChatHistoryWithCanvasBlocks(messages           )            {
  if (messages.length === 0) {
    return messages;
  }
  const next = [...messages];
  let changed = false;
  let lastAssistantIndex = -1;
  let lastRenderableAssistantIndex = -1;
  const pending                      = [];
  for (let index = 0; index < next.length; index++) {
    const entry = readObjectRecord(next[index]);
    if (!entry) {
      continue;
    }
    const role = typeof entry.role === "string" ? entry.role.toLowerCase() : "";
    if (role === "assistant") {
      lastAssistantIndex = index;
      if (!messageContainsToolHistoryContent(entry)) {
        lastRenderableAssistantIndex = index;
        if (pending.length > 0) {
          next[index] = appendChatCanvasBlocksToMessage(entry, pending);
          pending.length = 0;
          changed = true;
        }
      }
      continue;
    }
    if (!messageContainsToolHistoryContent(entry)) {
      continue;
    }
    const preview = extractChatToolResultCanvasPreview(entry);
    if (!preview) {
      continue;
    }
    pending.push(preview);
  }
  if (pending.length > 0) {
    const targetIndex =
      lastRenderableAssistantIndex >= 0 ? lastRenderableAssistantIndex : lastAssistantIndex;
    if (targetIndex >= 0) {
      next[targetIndex] = appendChatCanvasBlocksToMessage(readRecord(next[targetIndex]), pending);
      changed = true;
    }
  }
  return changed ? next : messages;
}
export { isDisplayRouteIdentifier, extractChatHistoryCanvasPreview, messageContainsToolHistoryContent };