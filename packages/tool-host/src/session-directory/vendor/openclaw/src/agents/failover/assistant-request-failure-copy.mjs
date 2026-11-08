import { safeParseJsonRecord } from "../../../packages/normalization-core/src/json-coercion.mjs";
import { asPositiveSafeInteger } from "../../../packages/normalization-core/src/number-coercion.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../../packages/normalization-core/src/string-coerce.mjs";
import { truncateUtf16Safe } from "../../../packages/normalization-core/src/utf16-slice.mjs";
import { classifyGatewayStorageFailure } from "../../infra/sqlite-error-diagnostics.mjs";
import { redactSensitiveText } from "../../logging/redact.mjs";
import { CONTEXT_OVERFLOW_ERROR_MESSAGE } from "../../shared/assistant-error-format.mjs";
import { extractErrorHttpStatus } from "../../shared/assistant-error-format.mjs";
import { formatTransportErrorCopy } from "../../shared/assistant-error-format.mjs";
import { parseApiErrorInfo } from "../../shared/assistant-error-format.mjs";
import { escapeMarkdownText } from "../../shared/text/escape-markdown.mjs";
import { classifyFailoverSignalCore } from "./classify-core.mjs";
import { isContextOverflowErrorFromTables } from "./context-overflow-tables.mjs";
import { isServerErrorMessage } from "./message-patterns.mjs";
import { isSessionTranscriptValidationErrorMessage } from "./message-patterns.mjs";
import { isUnsupportedReasoningEffortParameterError } from "./message-patterns.mjs";
import { resolveExecutionApprovalFailureMessage } from "./message-patterns.mjs";
import { extractFailoverSignalDetails } from "./signal-details.mjs";
export const ERROR_PREFIX_RE =
  /^(?:error|(?:[a-z][\w-]*\s+)?api\s*error|openai\s*error|anthropic\s*error|gateway\s*error|codex\s*error|request failed|failed|exception)(?:\s+\d{3})?[:\s-]+/i;
export const PROVIDER_SCHEMA_REJECTION_USER_TEXT =
  "The AI service couldn't accept this request. Try a new conversation with /new, or choose another model in the Control UI.";
const PROVIDER_OUTPUT_TOKEN_LIMIT_RE =
  /^['"]?max_(?:tokens|output_tokens|completion_tokens|new_tokens)['"]?\s*(?:[:=]\s*)?\(?(\d[\d,]*)\)?\s+exceeds?\b.{0,120}?\b(?:maximum|max|limit)\b(?:\s+(?:output\s+)?tokens?)?(?:\s+(?:is|of)|\s*[:=])?\s*\(?(\d[\d,]*)\)?(?:\D|$)/i;
const PROVIDER_CACHE_CONTROL_LIMIT_RE =
  /^A maximum of (\d{1,6}) blocks with cache_control may be provided\. Found (\d{1,6})\.$/i;
export const ERROR_DETAILS_HINT =
  "For details, open Settings → Logs in the Control UI or run `openclaw logs --follow` in your terminal.";
const STORAGE_FAILURE_COPY                                        = {
  SQLITE_BUSY:
    "OpenClaw is busy saving your conversation. Wait a moment, then check the conversation before trying again.",
  SQLITE_LOCKED:
    "OpenClaw is busy saving your conversation. Wait a moment, then check the conversation before trying again.",
  SQLITE_FULL:
    "OpenClaw couldn't save your conversation because the disk is full. Free up space on the computer running OpenClaw before continuing.",
  SQLITE_READONLY:
    "OpenClaw doesn't have permission to save your conversation. Check folder permissions on the computer running OpenClaw.",
  SQLITE_IOERR:
    "OpenClaw couldn't save your conversation. Check the storage on the computer running OpenClaw before continuing.",
  transcript_writer_fenced:
    "This conversation changed while OpenClaw was working. Check its latest messages before continuing.",
  session_actor_reconciliation:
    "OpenClaw couldn't confirm the last update to this conversation. Wait for current work to finish, then reopen the conversation. If it still fails, restart OpenClaw.",
};
const ASSISTANT_REQUEST_FAILURE_COPY = {
  auth: "Couldn't sign in to the AI service. Sign in again under Models in the Control UI or run `openclaw configure`.",
  auth_permanent:
    "The AI service isn't accepting your login. Sign in again under Models in the Control UI or run `openclaw configure`.",
  format: PROVIDER_SCHEMA_REJECTION_USER_TEXT,
  rate_limit: "The AI service needs a short break. Please try again in a few minutes.",
  overloaded: "The AI service is busy. Please try again in a moment, or choose another model.",
  billing:
    "The AI service reported a billing problem. Check your account's credit balance and usage limits before trying again.",
  server_error: "The AI service is having trouble. Please try again in a moment.",
  timeout:
    "The request took too long. Check the conversation for any completed work before trying again.",
  tls_certificate: `Couldn't connect securely to the AI service. ${ERROR_DETAILS_HINT}`,
  context_overflow: CONTEXT_OVERFLOW_ERROR_MESSAGE,
  model_not_found:
    "This model was not found. Choose another model in the Control UI or run `openclaw configure`.",
  session_expired:
    "Your AI session expired. Start a new conversation with /new. If it happens again, sign in under Models in the Control UI.",
  empty_response: "The AI service returned an empty reply. Please try again.",
  no_error_details: "",
  unclassified: "",
  unknown: "",
}                                         ;
export function renderAssistantRequestFailureCopy(
  facts                                  ,
)                     {
  if (facts.storageFailure) {
    return `⚠️ ${STORAGE_FAILURE_COPY[facts.storageFailure]} ${ERROR_DETAILS_HINT}`;
  }
  if (facts.code === "incomplete_tool_call") {
    return "⚠️ The task couldn't finish. Some actions may have completed; check their results before continuing.";
  }
  const reason =
    facts.reason === "timeout" && typeof facts.status === "number" && facts.status >= 500
      ? "server_error"
      : facts.reason;
  const copy = reason ? ASSISTANT_REQUEST_FAILURE_COPY[reason] : undefined;
  if (copy) {
    return `⚠️ ${copy}`;
  }
  const hasStatus =
    facts.status !== undefined &&
    Number.isInteger(facts.status) &&
    facts.status >= 100 &&
    facts.status <= 599;
  if (!hasStatus && !facts.provider?.trim() && !facts.model?.trim()) {
    return undefined;
  }
  return `⚠️ OpenClaw couldn't finish this reply. ${ERROR_DETAILS_HINT}`;
}
export function renderFormatErrorCopy(raw        )         {
  const trimmed = raw.trim();
  const normalized =
    extractErrorHttpStatus(trimmed)?.rest ?? trimmed.replace(ERROR_PREFIX_RE, "").trim();
  let candidate = extractErrorHttpStatus(normalized)?.rest ?? normalized;
  // Some proxies serialize the upstream error inside their own error.message.
  for (let depth = 0; depth < 4; depth++) {
    // HTTP reason phrases can precede a body, including inside a proxy's message.
    candidate = (extractErrorHttpStatus(candidate)?.rest ?? candidate).replace(
      /^(?:bad request|unprocessable (?:entity|content))\s*:?\s*(?=[{[<])/iu,
      "",
    );
    const parsedMessage = parseApiErrorInfo(candidate)?.message?.trim();
    if (!parsedMessage || parsedMessage === candidate) {
      break;
    }
    candidate = parsedMessage;
  }
  if (isSessionTranscriptValidationErrorMessage(candidate)) {
    return "OpenClaw couldn't read this conversation's history. Ask the Gateway operator to try `openclaw doctor --fix`. If it still fails, preserve the history and contact support with the Gateway logs.";
  }
  const embeddingModel = candidate.match(/^"([\w./:-]{1,200})" does not support chat$/u)?.[1];
  if (embeddingModel) {
    const model = escapeMarkdownText(redactSensitiveText(embeddingModel, { mode: "tools" }));
    return `${model} is an embedding model and cannot chat; pick a chat model with /model (or remove it from models.providers.ollama.models).`;
  }
  if (PROVIDER_CACHE_CONTROL_LIMIT_RE.test(candidate)) {
    return "The AI service couldn't accept this conversation. Start a new conversation with /new, or choose another model in the Control UI.";
  }
  if (isUnsupportedReasoningEffortParameterError(candidate)) {
    return "This model endpoint does not support reasoning_effort. Set compat.supportsReasoningEffort: false on this model in your custom provider configuration and try again.";
  }
  if (candidate.length > 300 || !PROVIDER_OUTPUT_TOKEN_LIMIT_RE.test(candidate)) {
    if (!candidate || /^[{<]/u.test(candidate)) {
      return PROVIDER_SCHEMA_REJECTION_USER_TEXT;
    }
    if (candidate.startsWith("[")) {
      try {
        JSON.parse(candidate);
        return PROVIDER_SCHEMA_REJECTION_USER_TEXT;
      } catch {
        // Preserve field-path diagnostics, not truncated or suffixed JSON arrays.
        if (!/^\[[a-z_$][\w$.-]*\](?:\s|:|$)/iu.test(candidate)) {
          return PROVIDER_SCHEMA_REJECTION_USER_TEXT;
        }
      }
    }
    // Redact before truncation so a clipped credential cannot escape matching.
    const detail = redactSensitiveText(candidate, { mode: "tools" })
      .replace(/[\p{Cc}\p{Cf}\s]+/gu, " ")
      .trim();
    if (!detail) {
      return PROVIDER_SCHEMA_REJECTION_USER_TEXT;
    }
    const bounded = detail.length > 600 ? `${truncateUtf16Safe(detail, 600)}…` : detail;
    return `LLM request rejected: ${escapeMarkdownText(bounded)}`;
  }
  return "The reply length is set too high for this model. Lower its reply limit in the Control UI settings, or choose another model.";
}
export function renderAssistantFormatFailureCopy(
  message                                                                      ,
  reason                        ,
)                     {
  for (const [isBody, raw] of [
    [true, message.errorBody],
    [false, message.errorMessage],
  ]         ) {
    if (typeof raw !== "string") {
      continue;
    }
    const info = parseApiErrorInfo(raw);
    if (isBody && !info?.message) {
      continue;
    }
    const status = extractErrorHttpStatus(raw)?.code;
    if (
      reason !== "format" &&
      !(
        typeof message.errorType === "string" &&
        message.errorType.toLowerCase().includes("invalid_request")
      ) &&
      !info?.type?.toLowerCase().includes("invalid_request") &&
      status !== 400 &&
      status !== 422
    ) {
      continue;
    }
    const copy = renderFormatErrorCopy(raw);
    if (copy !== PROVIDER_SCHEMA_REJECTION_USER_TEXT) {
      return copy;
    }
  }
  return undefined;
}
export function renderModelLoadFailureCopy(message   
                  
                      
                      
 )                     {
  if (
    message.errorCode !== "model_load_failed" ||
    typeof message.errorBody !== "string" ||
    typeof message.model !== "string"
  ) {
    return undefined;
  }
  const contextLength = asPositiveSafeInteger(
    safeParseJsonRecord(message.errorBody)?.requestedContextLength,
  );
  const model = redactSensitiveText(message.model, { mode: "tools" })
    .replace(/[\p{Cc}\p{Cf}\s]+/gu, " ")
    .trim();
  if (!contextLength || !model) {
    return undefined;
  }
  const label = escapeMarkdownText(truncateUtf16Safe(model, 200));
  return `Could not load model "${label}" with ${contextLength} context tokens. Wait for loading to finish on the model server, then retry, or lower the model's configured context size.`;
}
export function renderRecordedAssistantFailureCopy(message   
                  
                         
                      
                      
                      
 )                     {
  const modelLoadCopy = renderModelLoadFailureCopy(message);
  if (modelLoadCopy) {
    return modelLoadCopy;
  }
  const approvalMessage = resolveExecutionApprovalFailureMessage(
    typeof message.errorMessage === "string" ? message.errorMessage : undefined,
  );
  if (approvalMessage) {
    return `⚠️ ${approvalMessage}`;
  }
  const raw = typeof message.errorMessage === "string" ? message.errorMessage.trim() : "";
  if (raw === "Worker inference result exceeds the transcript message limit.") {
    return "The worker could not save the model response because it exceeded the message size limit. Retry with a smaller response or continue on the Gateway. Earlier actions may have completed; verify their results before continuing.";
  }
  if (
    raw ===
    "Cloud worker could not preserve authoritative provider replay. Stop or reclaim the cloud worker, then retry locally."
  ) {
    return "The worker could not preserve the model's continuation data. Stop or reclaim the worker, then retry on the Gateway. Earlier actions may have completed; verify their results before continuing.";
  }
  const info = parseApiErrorInfo(raw);
  const code = typeof message.errorCode === "string" ? message.errorCode : info?.code;
  const status = extractErrorHttpStatus(raw)?.code;
  const classification = classifyFailoverSignalCore({
    message: raw,
    code,
    errorType: typeof message.errorType === "string" ? message.errorType : info?.type,
    status,
    details: extractFailoverSignalDetails(message.errorBody),
  });
  if (
    classification?.kind === "context_overflow" ||
    [message.errorCode, message.errorType, raw].some(
      (value) =>
        typeof value === "string" &&
        (normalizeLowercaseStringOrEmpty(value) === "context_overflow" ||
          isContextOverflowErrorFromTables(value)),
    )
  ) {
    return CONTEXT_OVERFLOW_ERROR_MESSAGE;
  }
  const formatCopy =
    !classification?.reason || classification.reason === "format"
      ? renderAssistantFormatFailureCopy(message, classification?.reason)
      : undefined;
  if (formatCopy) {
    return formatCopy;
  }
  const classifiedCopy = renderAssistantRequestFailureCopy({
    storageFailure: classifyGatewayStorageFailure(message),
    code,
    status,
    // The legacy timeout retry bucket also includes explicit server failures.
    reason:
      classification?.reason === "timeout" && isServerErrorMessage(raw)
        ? "server_error"
        : classification?.reason,
  });
  if (status !== undefined || (classification && classification.reason !== "timeout")) {
    return classifiedCopy;
  }
  return formatTransportErrorCopy([raw, code].filter(Boolean).join(" ")) ?? classifiedCopy;
}
export { PROVIDER_OUTPUT_TOKEN_LIMIT_RE, PROVIDER_CACHE_CONTROL_LIMIT_RE, STORAGE_FAILURE_COPY, ASSISTANT_REQUEST_FAILURE_COPY };