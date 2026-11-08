import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { OPENCLAW_TRANSCRIPT_ARTIFACT_PROVIDER } from "../../packages/agent-core/src/harness/session/transcript-model.mjs";
import { MODEL_FALLBACK_NOTICE_KIND } from "./model-fallback-notice.mjs";
export const OPENCLAW_DELIVERY_MIRROR_MODEL = "delivery-mirror"         ;
export const SUBAGENT_COMPLETION_DIRECT_DELIVERY_KIND = "subagent-completion-direct"         ;
export const CRON_DIRECT_DELIVERY_CONTEXT_KIND = "cron-direct-delivery-context"         ;
export const SKILL_WORKSHOP_CHANGE_NOTICE_KIND = "skill-workshop-change"         ;
const OPENCLAW_GATEWAY_INJECTED_MODEL = "gateway-injected"         ;
const TRANSCRIPT_ONLY_OPENCLAW_ASSISTANT_MODELS = new Set        ([
  OPENCLAW_DELIVERY_MIRROR_MODEL,
  OPENCLAW_GATEWAY_INJECTED_MODEL,
]);
const OPENCLAW_DELIVERY_MIRROR_KINDS = new Set([
  "channel-final",
  "channel-final-suppressed",
  "message-tool-source-reply",
  CRON_DIRECT_DELIVERY_CONTEXT_KIND,
  SUBAGENT_COMPLETION_DIRECT_DELIVERY_KIND,
  SKILL_WORKSHOP_CHANGE_NOTICE_KIND,
  MODEL_FALLBACK_NOTICE_KIND,
]);
function isOpenClawDeliveryMirrorMarker(value         )          {
  const kind = asOptionalRecord(value)?.kind;
  return typeof kind === "string" && OPENCLAW_DELIVERY_MIRROR_KINDS.has(kind);
}
export function isTranscriptOnlyOpenClawAssistantModel(provider         , model         )          {
  return (
    provider === OPENCLAW_TRANSCRIPT_ARTIFACT_PROVIDER &&
    typeof model === "string" &&
    TRANSCRIPT_ONLY_OPENCLAW_ASSISTANT_MODELS.has(model)
  );
}
export function isTranscriptOnlyOpenClawAssistantMessage(message         )          {
  const entry = asOptionalRecord(message);
  if (entry?.role !== "assistant") {
    return false;
  }
  if (isTranscriptOnlyOpenClawAssistantModel(entry.provider, entry.model)) {
    return true;
  }
  return isOpenClawDeliveryMirrorMarker(entry.openclawDeliveryMirror);
}
export function isOpenClawMessageToolMirrorAssistantMessage(message         )          {
  const entry = asOptionalRecord(message);
  return entry?.role === "assistant" && entry.openclawMessageToolMirror !== undefined;
}
export function isOpenClawDeliveryMirrorAssistantMessage(message         )          {
  const entry = asOptionalRecord(message);
  return (
    entry?.role === "assistant" &&
    entry.provider === OPENCLAW_TRANSCRIPT_ARTIFACT_PROVIDER &&
    entry.model === OPENCLAW_DELIVERY_MIRROR_MODEL
  );
}
export { OPENCLAW_GATEWAY_INJECTED_MODEL, TRANSCRIPT_ONLY_OPENCLAW_ASSISTANT_MODELS, OPENCLAW_DELIVERY_MIRROR_KINDS, isOpenClawDeliveryMirrorMarker };