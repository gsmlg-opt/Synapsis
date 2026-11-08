import { asPositiveSafeInteger } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { readTranscriptDisplayPosition } from "../chat/transcript-display-position.mjs";
import { ASSISTANT_DISPLAY_CONTENT_FIELD } from "../shared/assistant-display-content.mjs";
const PREFIX = "artifact_transcript_image_";
function imageReference(message                         , contentIndex        ) {
  const metadata = asOptionalRecord(message["__openclaw"]);
  const position = readTranscriptDisplayPosition(metadata?.transcriptPosition);
  const messageId = metadata?.id;
  const messageSeq = asPositiveSafeInteger(metadata?.seq);
  if (
    !position ||
    typeof messageId !== "string" ||
    !messageId ||
    messageId.length > 1024 ||
    messageSeq === undefined ||
    messageSeq >= Number.MAX_SAFE_INTEGER
  ) {
    return undefined;
  }
  return { source: position.source, rawSeq: position.rawSeq, messageId, messageSeq, contentIndex };
}
function encodeReference(reference                          )         {
  return PREFIX + Buffer.from(JSON.stringify(reference)).toString("base64url");
}
function displayContentField(message                         )         {
  return message.role === "assistant" && Array.isArray(message[ASSISTANT_DISPLAY_CONTENT_FIELD])
    ? ASSISTANT_DISPLAY_CONTENT_FIELD
    : "content";
}
function hasInlineImagePayload(block                         )          {
  const source = asOptionalRecord(block.source);
  return (
    block.type === "image" &&
    [block.data, source?.data].some((value) => typeof value === "string" && value.length > 0)
  );
}
export function projectTranscriptImageArtifacts(message         )          {
  const record = asOptionalRecord(message);
  if (!record) {
    return message;
  }
  const field = displayContentField(record);
  const content = record[field];
  if (!Array.isArray(content)) {
    return message;
  }
  let projected                       ;
  for (let index = 0; index < content.length; index++) {
    const block = asOptionalRecord(content[index]);
    if (
      !block ||
      !hasInlineImagePayload(block) ||
      (typeof block.url === "string" && block.url.trim())
    ) {
      continue;
    }
    const reference = imageReference(record, index);
    if (!reference) {
      continue;
    }
    projected ??= content.slice();
    projected[index] = { ...block, artifactId: encodeReference(reference) };
  }
  return projected ? { ...record, [field]: projected } : message;
}
export { PREFIX, imageReference, encodeReference, displayContentField, hasInlineImagePayload };