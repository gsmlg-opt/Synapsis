import { asOptionalObjectRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../packages/normalization-core/src/string-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { shortenHomeInString } from "../utils.mjs";
import { unwrapToolCallForDisplay } from "./tool-display-call.mjs";
import { defaultTitle } from "./tool-display-common.mjs";
import { formatDetailKey } from "./tool-display-common.mjs";
import { normalizeToolDisplayName } from "./tool-display-common.mjs";
import { resolveToolDetailForArgs } from "./tool-display-common.mjs";
import { TOOL_DISPLAY_CONFIG } from "./tool-display-config.mjs";
const FALLBACK = TOOL_DISPLAY_CONFIG.fallback;
const TOOL_MAP = TOOL_DISPLAY_CONFIG.tools;
const DETAIL_LABEL_OVERRIDES                         = {
  agentId: "agent",
  sessionKey: "session",
  targetId: "target",
  targetUrl: "url",
  nodeId: "node",
  requestId: "request",
  messageId: "message",
  threadId: "thread",
  channelId: "channel",
  guildId: "guild",
  userId: "user",
  runTimeoutSeconds: "timeout",
  timeoutSeconds: "timeout",
  includeTools: "tools",
  pollQuestion: "poll",
  maxChars: "max chars",
};
export function resolveToolDisplay(params   
                
                 
                
                              
 )              {
  const call = unwrapToolCallForDisplay({ name: params.name, args: params.args });
  const name = normalizeToolDisplayName(call.name);
  const key = normalizeLowercaseStringOrEmpty(name);
  const spec = TOOL_MAP[key];
  const title = spec?.title ?? defaultTitle(name);
  const label = spec?.label ?? title;
  const detail = resolveToolDetailForArgs({
    toolKey: key,
    args: call.args,
    meta: params.meta,
    spec,
    fallbackDetailKeys: FALLBACK.detailKeys,
    detailMode: "summary",
    toolDetailMode: params.detailMode,
    detailFormatKey: (raw) => formatDetailKey(raw, DETAIL_LABEL_OVERRIDES),
  });
  return {
    name,
    icon: spec?.icon ?? FALLBACK.icon,
    title,
    label,
    detail: detail ? shortenHomeInString(detail) : detail,
  };
}
export function formatToolDetail(display             )                     {
  return display.detail || undefined;
}
export function inferToolMetaFromArgsCore(
  toolName        ,
  args         ,
  options                                  ,
)                     {
  return formatToolDetail(
    resolveToolDisplay({ name: toolName, args, detailMode: options?.detailMode }),
  );
}
export function isShellToolDisplayName(name                    )          {
  const normalized = normalizeLowercaseStringOrEmpty(name);
  return normalized === "bash" || normalized === "exec" || normalized === "shell";
}
export function isCommandBearingToolCall(name                    , args          )          {
  if (isShellToolDisplayName(name)) {
    return true;
  }
  return normalizeOptionalString(asOptionalObjectRecord(args)?.command) !== undefined;
}
export { FALLBACK, TOOL_MAP, DETAIL_LABEL_OVERRIDES };