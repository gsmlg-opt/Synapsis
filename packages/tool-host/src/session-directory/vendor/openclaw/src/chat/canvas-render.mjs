import { safeParseJsonRecord } from "../../packages/normalization-core/src/json-coercion.mjs";
import { asFiniteNumber } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { readNonBlankString } from "../../packages/normalization-core/src/string-coerce.mjs";
function coerceMcpAppDescriptor(
  record                                     ,
)                                      {
  const viewId = readNonBlankString(record?.viewId);
  if (!viewId || viewId.length > 128) {
    return undefined;
  }
  const serverName = readNonBlankString(record?.serverName);
  const toolName = readNonBlankString(record?.toolName);
  const uiResourceUri = readNonBlankString(record?.uiResourceUri);
  const toolCallId = readNonBlankString(record?.toolCallId);
  const originSessionKey = readNonBlankString(record?.originSessionKey);
  const resultMetaState = record?.resultMetaState === "unavailable" ? "unavailable" : undefined;
  const hasCompleteDescriptor = Boolean(
    serverName &&
    serverName.length <= 256 &&
    toolName &&
    toolName.length <= 256 &&
    uiResourceUri?.startsWith("ui://") &&
    uiResourceUri.length <= 2048 &&
    toolCallId &&
    toolCallId.length <= 512,
  );
  return hasCompleteDescriptor
    ? {
        viewId,
        serverName,
        toolName,
        uiResourceUri,
        toolCallId,
        ...(originSessionKey && originSessionKey.length <= 512 ? { originSessionKey } : {}),
        ...(resultMetaState ? { resultMetaState } : {}),
      }
    : { viewId };
}
function normalizePreferredHeight(value                    )                     {
  return typeof value === "number" && Number.isFinite(value) && value >= 160
    ? Math.min(Math.trunc(value), 1200)
    : undefined;
}
export function isCanvasBoardWidgetName(value         )                  {
  return typeof value === "string" && /^[a-z0-9][a-z0-9._-]{0,63}$/u.test(value);
}
export function extractCanvasFromRecord(value         )                            {
  const record = asOptionalRecord(value);
  if (!record) {
    return undefined;
  }
  const kind = readNonBlankString(record?.kind)?.trim().toLowerCase();
  if (kind !== "canvas") {
    return undefined;
  }
  const presentation = asOptionalRecord(record.presentation);
  const view = asOptionalRecord(record.view);
  const source = asOptionalRecord(record.source);
  const mcpApp = coerceMcpAppDescriptor(asOptionalRecord(record.mcpApp));
  const mcpAppViewId = mcpApp?.viewId;
  const requestedSurface =
    readNonBlankString(presentation?.target) ?? readNonBlankString(record?.target);
  const surface = requestedSurface ?? "assistant_message";
  if (surface !== "assistant_message" && surface !== "node_panel") {
    return undefined;
  }
  const title = readNonBlankString(presentation?.title) ?? readNonBlankString(view?.title);
  const preferredHeight = normalizePreferredHeight(
    asFiniteNumber(presentation?.preferred_height) ??
      asFiniteNumber(presentation?.preferredHeight) ??
      asFiniteNumber(view?.preferred_height) ??
      asFiniteNumber(view?.preferredHeight),
  );
  const className =
    readNonBlankString(presentation?.class_name) ?? readNonBlankString(presentation?.className);
  const style = readNonBlankString(presentation?.style);
  const sandbox = readNonBlankString(presentation?.sandbox);
  const viewUrl = readNonBlankString(view?.url) ?? readNonBlankString(view?.entryUrl);
  const viewId = readNonBlankString(view?.id) ?? readNonBlankString(view?.docId);
  const requestedBoardWidgetName = readNonBlankString(view?.boardWidgetName);
  const boardWidgetName = isCanvasBoardWidgetName(requestedBoardWidgetName)
    ? requestedBoardWidgetName
    : undefined;
  const preview                = {
    kind: "canvas",
    surface,
    render: "url",
    ...(title ? { title } : {}),
    ...(preferredHeight ? { preferredHeight } : {}),
    ...(sandbox === "strict" || sandbox === "scripts" ? { sandbox } : {}),
    ...(mcpApp ? { mcpApp } : {}),
  };
  if (mcpAppViewId && viewId === mcpAppViewId) {
    return { ...preview, viewId };
  }
  const url =
    viewUrl ??
    (readNonBlankString(source?.type)?.trim().toLowerCase() === "url"
      ? readNonBlankString(source?.url)
      : undefined);
  if (!url) {
    return undefined;
  }
  return {
    ...preview,
    url,
    ...(viewUrl && viewId ? { viewId } : {}),
    ...(className ? { className } : {}),
    ...(style ? { style } : {}),
    ...(viewUrl && boardWidgetName ? { boardWidgetName } : {}),
  };
}
export function extractCanvasFromDetails(value         )                            {
  const details = asOptionalRecord(value);
  return extractCanvasFromRecord(details?.mcpAppPreview);
}
export function extractCanvasFromText(outputText                    )                            {
  const parsed = outputText ? safeParseJsonRecord(outputText) : undefined;
  return extractCanvasFromRecord(parsed);
}
export { coerceMcpAppDescriptor, normalizePreferredHeight };