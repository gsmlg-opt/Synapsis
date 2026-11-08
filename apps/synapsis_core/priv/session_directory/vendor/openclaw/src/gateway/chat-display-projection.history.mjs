import { createHash } from "node:crypto";
import { expectDefined } from "../../packages/normalization-core/src/expect.mjs";
import { asFiniteNumber } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalRecord as readRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { isOpenClawRuntimeContextCustomMessage } from "../agents/internal-runtime-context.mjs";
import { isHeartbeatOkResponse } from "../auto-reply/heartbeat-filter.mjs";
import { isHeartbeatUserMessage } from "../auto-reply/heartbeat-filter.mjs";
import { HEARTBEAT_PROMPT } from "../auto-reply/heartbeat.mjs";
import { isCompletionReportInputProvenance } from "../sessions/input-provenance.mjs";
import { isSubagentCoordinationInputProvenance } from "../sessions/input-provenance.mjs";
import { INTER_SESSION_PROMPT_PREFIX_BASE } from "../sessions/input-provenance.mjs";
import { normalizeInputProvenance } from "../sessions/input-provenance.mjs";
import { stripInterSessionPromptPrefixForDisplay } from "../sessions/input-provenance.mjs";
import { parseAgentSessionKey } from "../../packages/session-url-contract/src/session-key-normalization.mjs";
import { readSessionTranscriptRunId } from "../sessions/transcript-events.mjs";
import { buildRunUserTurnIdempotencyKey } from "../sessions/user-turn-transcript.metadata.mjs";
import { projectAssistantDisplayContent } from "../shared/assistant-display-content.mjs";
import { extractAssistantPhaseText } from "../shared/chat-message-content.mjs";
import { isOpenClawDeliveryMirrorAssistantMessage } from "../shared/transcript-only-openclaw-assistant.mjs";
import { extractChatHistoryBlockText } from "./chat-display-projection.canvas.mjs";
import { asRoleContentMessage } from "./chat-display-projection.helpers.mjs";
import { extractProjectedText } from "./chat-display-projection.helpers.mjs";
import { hasAssistantNonTextContent } from "./chat-display-projection.helpers.mjs";
import { hasAssistantDisplayableNonTextContent } from "./chat-display-projection.helpers.mjs";
import { hasTranscriptMediaFacts } from "./chat-display-projection.helpers.mjs";
import { isEmptyTextOnlyContent } from "./chat-display-projection.helpers.mjs";
import { isProjectedForwardedMessage } from "./chat-display-projection.helpers.mjs";
import { isForwardedUserMessage } from "./chat-display-projection.helpers.mjs";
import { isCronRunMessage } from "./chat-display-projection.helpers.mjs";
import { mapChatDisplayMessages } from "./chat-display-projection.map.mjs";
export function isSubagentCoordinationHistoryInput(
  message                         ,
  isSubagentSession                                                           ,
)          {
  if (message.role !== "user") {
    return false;
  }
  const provenance = normalizeInputProvenance(message.provenance);
  if (isSubagentCoordinationInputProvenance(provenance)) {
    return true;
  }
  return Boolean(
    provenance?.kind === "inter_session" &&
    provenance.sourceTool === "sessions_send" &&
    provenance.sourceSessionKey &&
    isSubagentSession?.(provenance.sourceSessionKey),
  );
}
export function createSubagentCoordinationHistoryProjection(
  resolver                                      ,
  state   
                                                                                      
                                                                                       
                                                                                         
    = {
    hiddenInputKeys: new Set        (),
    visibleInputKeys: new Set        (),
    visibleSteerRunIds: new Set        (),
  },
) {
  const { hiddenInputKeys, visibleInputKeys, visibleSteerRunIds } = state;
  return (messages           )            => {
    resolver?.assertCurrent?.();
    const projected = messages.map((message) => {
      const record = readRecord(message);
      if (!record) {
        return message;
      }
      const metadata = readRecord(record["__openclaw"]);
      if (isSubagentCoordinationHistoryInput(record, resolver?.isSubagentSession)) {
        const inputKey = record.idempotencyKey ?? metadata?.idempotencyKey;
        // Steering belongs to an already-running turn, not the sender's requested run.
        if (typeof inputKey === "string" && !metadata?.steerTargetRunId) {
          hiddenInputKeys.add(inputKey);
        }
        return record.display === false ? record : { ...record, display: false };
      }
      const runId = readSessionTranscriptRunId(record);
      if (record.role === "user") {
        const inputKey = record.idempotencyKey ?? metadata?.idempotencyKey;
        if (typeof inputKey === "string") {
          visibleInputKeys.add(inputKey);
        }
        const steerTargetRunId = metadata?.steerTargetRunId ?? runId;
        if (typeof steerTargetRunId === "string") {
          visibleSteerRunIds.add(steerTargetRunId);
        }
        return message;
      }
      if (record.display === false) {
        return message;
      }
      if (
        (record.role === "assistant" || record.role === "toolResult" || record.role === "custom") &&
        runId &&
        !visibleSteerRunIds.has(runId) &&
        (hiddenInputKeys.has(buildRunUserTurnIdempotencyKey(runId)) ||
          (!visibleInputKeys.has(buildRunUserTurnIdempotencyKey(runId)) &&
            resolver?.isSubagentRunMessage(
              runId,
              typeof metadata?.seq === "number" ? metadata.seq : undefined,
            )))
      ) {
        return { ...record, display: false };
      }
      return message;
    });
    resolver?.assertCurrent?.();
    return projected;
  };
}
function readTtsSupplementMarker(
  message                         ,
)                                  {
  const marker = readRecord(message.openclawTtsSupplement);
  if (!marker) {
    return undefined;
  }
  const textSha256 = normalizeOptionalString(marker.textSha256);
  const spokenText = normalizeOptionalString(marker.spokenText);
  return textSha256 || spokenText ? { textSha256, spokenText } : undefined;
}
function readAssistantTtsSupplementMarker(
  message                         ,
)                                  {
  const marker = readTtsSupplementMarker(message);
  if (!marker || asRoleContentMessage(message)?.role !== "assistant") {
    return undefined;
  }
  const content = message.content;
  if (!Array.isArray(content)) {
    return undefined;
  }
  let hasSupplementBlock = false;
  for (const block of content) {
    const record = readRecord(block);
    if (!record) {
      continue;
    }
    if (record.type !== "text") {
      hasSupplementBlock = true;
      continue;
    }
    const text = typeof record.text === "string" ? record.text.trim() : "";
    if (text && text !== "Audio reply") {
      return undefined;
    }
  }
  return hasSupplementBlock ? marker : undefined;
}
function readTtsSupplementTargetText(message                         )         {
  return asRoleContentMessage(message)?.role === "assistant" &&
    !isProjectedForwardedMessage(message) &&
    !readTtsSupplementMarker(message)
    ? extractProjectedText(message.content ?? message.text).trim()
    : "";
}
function mergeTtsSupplementContent(
  target                         ,
  supplement                         ,
)                          {
  const supplementBlocks = Array.isArray(supplement.content)
    ? supplement.content.filter((block) => {
        const record = readRecord(block);
        return record !== undefined && record.type !== "text";
      })
    : [];
  if (supplementBlocks.length === 0) {
    return target;
  }
  const targetContent = target.content;
  if (Array.isArray(targetContent)) {
    return { ...target, content: [...targetContent, ...supplementBlocks] };
  }
  const targetText = extractProjectedText(targetContent ?? target.text).trim();
  return {
    ...target,
    content: [...(targetText ? [{ type: "text", text: targetText }] : []), ...supplementBlocks],
  };
}
export function mergeTtsSupplementMessages(
  messages                                ,
)                                 {
  if (!messages.some(readAssistantTtsSupplementMarker)) {
    return messages;
  }
  const targetTexts                            = [];
  const targetHashes                            = [];
  const merged                                 = [];
  let changed = false;
  for (const message of messages) {
    const marker = readAssistantTtsSupplementMarker(message);
    if (marker) {
      let targetIndex = -1;
      for (let i = merged.length - 1; i >= 0; i--) {
        const candidate = merged[i];
        if (!candidate) {
          continue;
        }
        const text = (targetTexts[i] ??= readTtsSupplementTargetText(candidate));
        if (
          text &&
          ((marker.textSha256 &&
            (targetHashes[i] ??= createHash("sha256").update(text).digest("hex")) ===
              marker.textSha256) ||
            (marker.spokenText && text === marker.spokenText))
        ) {
          targetIndex = i;
          break;
        }
      }
      if (targetIndex >= 0) {
        merged[targetIndex] = mergeTtsSupplementContent(
          expectDefined(merged[targetIndex], "merged entry at target index"),
          message,
        );
        // Appended media can carry text. Only this replaced position loses its
        // prepared facts; other positions still refer to their original messages.
        targetTexts[targetIndex] = targetHashes[targetIndex] = undefined;
        changed = true;
        continue;
      }
    }
    merged.push(message);
  }
  return changed ? merged : messages;
}
function isSubagentAnnounceInterSessionUserMessage(
  message                         ,
  readText                                                           ,
)          {
  const provenance = normalizeInputProvenance(message.provenance);
  if (
    provenance?.kind === "inter_session" &&
    (provenance.sourceTool === "subagent_announce" || provenance.sourceTool === "subagent_settle")
  ) {
    return true;
  }
  const text = readText ? readText(message) : extractProjectedText(message.content ?? message.text);
  return (
    typeof text === "string" &&
    text.includes(INTER_SESSION_PROMPT_PREFIX_BASE) &&
    text.includes("sourceTool=subagent_announce")
  );
}
function readChatHistoryRecordTimestampMs(message         )                     {
  const meta = readRecord(readRecord(message)?.["__openclaw"]);
  return asFiniteNumber(meta?.recordTimestampMs) ?? asFiniteNumber(readRecord(message)?.timestamp);
}
export function isPreSessionStartAssistantMessage(
  message         ,
  sessionStartedAt                    ,
)          {
  const timestamp = readChatHistoryRecordTimestampMs(message);
  return (
    sessionStartedAt !== undefined &&
    readRecord(message)?.role === "assistant" &&
    timestamp !== undefined &&
    timestamp < sessionStartedAt
  );
}
export function createPreSessionStartAnnouncePairFilter(sessionStartedAt                    ) {
  let precedingAnnounce = false;
  return (messages           )            => {
    if (sessionStartedAt === undefined || messages.length === 0) {
      return messages;
    }
    let changed = false;
    const kept            = [];
    for (const current of messages) {
      if (precedingAnnounce) {
        precedingAnnounce = false;
        if (isPreSessionStartAssistantMessage(current, sessionStartedAt)) {
          changed = true;
          continue;
        }
      }
      const record = readRecord(current);
      if (
        record?.role === "user" &&
        isSubagentAnnounceInterSessionUserMessage(record, extractChatHistoryBlockText)
      ) {
        const ts = readChatHistoryRecordTimestampMs(current);
        if (typeof ts === "number" && ts < sessionStartedAt) {
          // The adjacent assistant may arrive in the next appended chunk.
          precedingAnnounce = true;
          changed = true;
          continue;
        }
      }
      kept.push(current);
    }
    return changed ? kept : messages;
  };
}
export function dropPreSessionStartAnnouncePairs(
  messages           ,
  sessionStartedAt                    ,
)            {
  return createPreSessionStartAnnouncePairFilter(sessionStartedAt)(messages);
}
export function readPluginSteeringId(message         )                     {
  const record = readRecord(message);
  if (record?.role !== "user") {
    return undefined;
  }
  const provenance = normalizeInputProvenance(record.provenance);
  const sourceTool = provenance?.sourceTool;
  return provenance?.kind === "internal_system" && sourceTool?.startsWith("plugin:")
    ? sourceTool.slice("plugin:".length).trim() || undefined
    : undefined;
}
export function projectPluginSteeringMessage(message                         ) {
  const pluginId = readPluginSteeringId(message);
  if (!pluginId) {
    return message;
  }
  const metadata = readRecord(message["__openclaw"]);
  const steering = readRecord(metadata?.pluginSteering);
  const displayText = typeof steering?.displayText === "string" ? steering.displayText : undefined;
  return {
    ...message,
    display: true,
    ...(displayText === undefined
      ? {}
      : { content: [{ type: "text", text: displayText }], text: displayText }),
    __openclaw: {
      ...metadata,
      // The body belongs in capped content, not duplicated in uncapped metadata.
      pluginSteering: {
        pluginId,
        ...(typeof steering?.pluginName === "string" ? { pluginName: steering.pluginName } : {}),
      },
    },
  };
}
function isDisplayHiddenProjectedMessage(message                         )          {
  if (message.display === false) {
    return true;
  }
  return isOpenClawRuntimeContextCustomMessage(message);
}
function shouldHideProjectedHistoryMessage(
  message                         ,
  roleContent                           ,
  heartbeatUser         ,
)          {
  if (isDisplayHiddenProjectedMessage(message)) {
    return true;
  }
  if (isProjectedForwardedMessage(message)) {
    return false;
  }
  if (!roleContent) {
    return false;
  }
  const provenance = normalizeInputProvenance(message.provenance);
  if (
    roleContent.role === "user" &&
    provenance?.kind === "internal_system" &&
    (provenance.sourceTool === "exec" || provenance.sourceTool === "cron_failure_repair")
  ) {
    // Internal repair instructions belong to the model transcript, not the chat feed.
    // Keep the agent's authored outcome visible, including requests for user help.
    return true;
  }
  if (roleContent.role === "user" && isCompletionReportInputProvenance(message.provenance)) {
    return true;
  }
  if (roleContent.role === "user" && isSubagentAnnounceInterSessionUserMessage(message)) {
    return true;
  }
  if (
    roleContent.role === "user" &&
    isEmptyTextOnlyContent(message.content ?? message.text) &&
    !hasTranscriptMediaFacts(message)
  ) {
    return true;
  }
  if (roleContent.role === "assistant" && isEmptyTextOnlyContent(message.content ?? message.text)) {
    return false;
  }
  return heartbeatUser || isHeartbeatOkResponse(roleContent);
}
export function isHeartbeatHistoryTurnBoundaryMessage(message         )          {
  const record = readRecord(message);
  if (!record || isForwardedUserMessage(record)) {
    return false;
  }
  const roleContent = asRoleContentMessage(record);
  return roleContent?.role === "user" && isHeartbeatUserMessage(roleContent, HEARTBEAT_PROMPT);
}
function attachProjectedTurnBoundary(message                         )                          {
  const metadata = readRecord(message["__openclaw"]);
  if (metadata?.turnBoundary === true) {
    return message;
  }
  return {
    ...message,
    __openclaw: {
      ...metadata,
      turnBoundary: true,
    },
  };
}
function canCarryProjectedTurnBoundary(message                           )          {
  return Boolean(message && message.role !== "system" && message.role !== "custom");
}
function openclawAssistantModel(message                         )                     {
  return message.role === "assistant" &&
    message.provider === "openclaw" &&
    typeof message.model === "string"
    ? message.model
    : undefined;
}
function displayTextForDuplicateCheck(message                         )                     {
  const text = extractProjectedText(message.content ?? message.text).trim();
  return text ? text : undefined;
}
function isDuplicateAssistantDelivery(
  current                         ,
  previousVisible                                     ,
)          {
  if (!previousVisible) {
    return false;
  }
  const acpInjection =
    openclawAssistantModel(previousVisible) === "acp-runtime" &&
    openclawAssistantModel(current) === "gateway-injected";
  if (!acpInjection) {
    const deliveryMirror = readRecord(current.openclawDeliveryMirror);
    if (
      !isOpenClawDeliveryMirrorAssistantMessage(current) ||
      deliveryMirror?.kind !== "channel-final" ||
      asRoleContentMessage(previousVisible)?.role !== "assistant" ||
      isOpenClawDeliveryMirrorAssistantMessage(previousVisible) ||
      isProjectedForwardedMessage(previousVisible)
    ) {
      return false;
    }
    const previousMeta = readRecord(previousVisible["__openclaw"]);
    if (typeof deliveryMirror.sourceAssistantMessageId === "string") {
      if (
        !deliveryMirror.sourceAssistantMessageId ||
        deliveryMirror.sourceAssistantMessageId !== previousMeta?.id ||
        hasAssistantDisplayableNonTextContent(previousVisible) ||
        hasAssistantNonTextContent(current) ||
        hasTranscriptMediaFacts(previousVisible) ||
        hasTranscriptMediaFacts(current)
      ) {
        return false;
      }
      const previousText = extractAssistantPhaseText(previousVisible)?.trim();
      const currentText = extractAssistantPhaseText(current)?.trim();
      return Boolean(previousText && currentText && previousText === currentText);
    }
    if (typeof previousMeta?.mirrorIdentity !== "string" || !previousMeta.mirrorIdentity.trim()) {
      return false;
    }
  }
  if (hasAssistantNonTextContent(previousVisible) || hasAssistantNonTextContent(current)) {
    return false;
  }
  const previousText = displayTextForDuplicateCheck(previousVisible);
  const currentText = displayTextForDuplicateCheck(current);
  return Boolean(previousText && currentText && previousText === currentText);
}
export function toProjectedMessages(messages           )                                 {
  return messages.flatMap((message) => {
    const record = readRecord(message);
    return record ? [projectAssistantDisplayContent(record)] : [];
  });
}
export function filterVisibleProjectedHistoryMessages(
  messages                                ,
  turnBoundaryPending = false,
)   
                                           
                               
  {
  if (messages.length === 0) {
    return { messages, turnBoundaryPending };
  }
  let pendingTurnBoundary = turnBoundaryPending;
  let changed = false;
  const visible                                 = [];
  const assistantSources = new Map                                 ();
  for (let i = 0; i < messages.length; i++) {
    const current = messages[i];
    if (!current) {
      continue;
    }
    const currentRoleContent = asRoleContentMessage(current);
    const heartbeatUser = Boolean(
      currentRoleContent && isHeartbeatUserMessage(currentRoleContent, HEARTBEAT_PROMPT),
    );
    const next = heartbeatUser ? messages[i + 1] : undefined;
    const nextRoleContent = next ? asRoleContentMessage(next) : null;
    if (
      next &&
      nextRoleContent &&
      isHeartbeatOkResponse(
        nextRoleContent,
        undefined,
        Boolean(
          currentRoleContent &&
          isHeartbeatUserMessage(currentRoleContent, HEARTBEAT_PROMPT, { heartbeatOnly: true }),
        ),
      ) &&
      !isProjectedForwardedMessage(next)
    ) {
      changed = true;
      pendingTurnBoundary = true;
      i++;
      continue;
    }
    if (shouldHideProjectedHistoryMessage(current, currentRoleContent, heartbeatUser)) {
      changed = true;
      pendingTurnBoundary ||= heartbeatUser && !isForwardedUserMessage(current);
      continue;
    }
    const mirrorSourceId = readRecord(current.openclawDeliveryMirror)?.sourceAssistantMessageId;
    const source =
      typeof mirrorSourceId === "string" ? assistantSources.get(mirrorSourceId) : messages[i - 1];
    if (isDuplicateAssistantDelivery(current, source)) {
      changed = true;
      continue;
    }
    if (pendingTurnBoundary && canCarryProjectedTurnBoundary(currentRoleContent)) {
      visible.push(attachProjectedTurnBoundary(current));
      pendingTurnBoundary = false;
      changed = true;
    } else {
      visible.push(current);
    }
    const sourceId = readRecord(current["__openclaw"])?.id;
    if (currentRoleContent?.role === "assistant" && typeof sourceId === "string") {
      assistantSources.set(sourceId, current);
    }
  }
  return {
    messages: changed ? visible : messages,
    turnBoundaryPending: pendingTurnBoundary,
  };
}
function stripPromptPrefixFromContent(content         , strip                          )          {
  if (typeof content === "string") {
    return strip(content);
  }
  if (!Array.isArray(content)) {
    return content;
  }
  return content.map((block) => {
    if (!block || typeof block !== "object" || Array.isArray(block)) {
      return block;
    }
    const record = block                           ;
    if (typeof record.text !== "string") {
      return block;
    }
    const stripped = strip(record.text);
    return stripped === record.text ? block : { ...record, text: stripped };
  });
}
function readForwardedSender(message                         ) {
  // Only structured provenance identifies the sender; prompt headers are display text.
  const provenance = normalizeInputProvenance(message.provenance);
  const sourceSessionKey = provenance?.sourceSessionKey;
  const parsed = parseAgentSessionKey(sourceSessionKey);
  const agentId = parsed?.agentId;
  const jobId = isCronRunMessage(message)
    ? provenance?.jobId
    : parsed?.rest.match(/^cron:([^:]+):run:[^:]+$/u)?.[1];
  return { sourceSessionKey, agentId, jobId };
}
function resolveForwardedSenderSession(
  message                         ,
  resolveCronJobName                                       ,
)                                                                        {
  const { sourceSessionKey, agentId, jobId } = readForwardedSender(message);
  const label = jobId ? (resolveCronJobName(jobId) ?? "Automation") : undefined;
  return sourceSessionKey
    ? { sessionKey: sourceSessionKey, ...(agentId ? { agentId } : {}), ...(label ? { label } : {}) }
    : undefined;
}
export function projectForwardedMessages(
  messages                                ,
  resolveCronJobName                                        ,
)                                 {
  const resolve =
    resolveCronJobName ??
    (() => {
      throw new Error("Cron job names must be prepared before projecting forwarded messages");
    });
  const names = new Map                            ();
  const resolveName = (jobId        ) => {
    if (!names.has(jobId)) {
      names.set(jobId, resolve(jobId));
    }
    return names.get(jobId);
  };
  return mapChatDisplayMessages(messages, (message) => {
    if (!isForwardedUserMessage(message) && !isProjectedForwardedMessage(message)) {
      return message;
    }
    const senderSession = resolveForwardedSenderSession(message, resolveName);
    if (message.role === "assistant") {
      const previous = readRecord(message.senderSession);
      if (previous?.label === senderSession?.label) {
        return message;
      }
      return {
        ...message,
        senderSession,
        senderLabel: `Forwarded from ${senderSession?.label ?? senderSession?.agentId}`,
      };
    }
    const cronRun = isCronRunMessage(message);
    const prefix = normalizeInputProvenance(message.provenance)?.sourcePromptPrefix;
    const strip = cronRun
      ? (text        ) =>
          prefix && text.startsWith(prefix) ? text.slice(prefix.length).replace(/^ /u, "") : text
      : stripInterSessionPromptPrefixForDisplay;
    const next                          = {
      ...message,
      role: "assistant",
      ...(cronRun
        ? { __openclaw: { ...readRecord(message["__openclaw"]), turnBoundary: true } }
        : {}),
      senderLabel:
        senderSession?.label || senderSession?.agentId
          ? `Forwarded from ${senderSession.label ?? senderSession.agentId}`
          : "Forwarded agent message",
      ...(senderSession ? { senderSession } : {}),
    };
    if ("content" in next) {
      next.content = stripPromptPrefixFromContent(next.content, strip);
    }
    if (typeof next.text === "string") {
      next.text = strip(next.text);
    }
    return next;
  });
}
export { readTtsSupplementMarker, readAssistantTtsSupplementMarker, readTtsSupplementTargetText, mergeTtsSupplementContent, isSubagentAnnounceInterSessionUserMessage, readChatHistoryRecordTimestampMs, isDisplayHiddenProjectedMessage, shouldHideProjectedHistoryMessage, attachProjectedTurnBoundary, canCarryProjectedTurnBoundary, openclawAssistantModel, displayTextForDuplicateCheck, isDuplicateAssistantDelivery, stripPromptPrefixFromContent, readForwardedSender, resolveForwardedSenderSession };