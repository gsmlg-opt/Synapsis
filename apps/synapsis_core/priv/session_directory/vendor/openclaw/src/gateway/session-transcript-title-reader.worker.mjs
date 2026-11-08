import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { hasInterSessionUserProvenance } from "../sessions/input-provenance.mjs";
import { resolveSessionTitleSource } from "../sessions/session-title-source.mjs";
import { projectSessionDisplayMessage } from "./session-display-projection.mjs";
import { sqliteMessageEventWithSeq } from "./session-transcript-entry-message.mjs";
function findFirstTitleUserText(
  entries                                                            ,
  includeInterSession         ,
  skillCommands                     ,
)                {
  for (const entry of entries) {
    const message = sqliteMessageEventWithSeq(entry);
    const projected = projectSessionDisplayMessage(message);
    if (
      projected?.role === "user" &&
      (includeInterSession || !hasInterSessionUserProvenance(asOptionalRecord(message)))
    ) {
      const source = resolveSessionTitleSource(projected.text, skillCommands);
      if (source) {
        return source;
      }
    }
  }
  return null;
}
function findLastMessageText(
  entries                                                            ,
)                {
  let text                = null;
  entries.findLast((entry) => {
    const message = sqliteMessageEventWithSeq(entry);
    text = projectSessionDisplayMessage(message, { flattenMarkdown: true })?.text ?? null;
    return text !== null;
  });
  return text;
}
export { findFirstTitleUserText, findLastMessageText };