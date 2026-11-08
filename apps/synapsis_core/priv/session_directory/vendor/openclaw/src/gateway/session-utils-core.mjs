import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { deriveGoalSessionTitle } from "./derive-goal-session-title.mjs";
export function deriveSessionTitle(
  entry                          ,
  firstUserMessage                ,
  externalDisplayName                ,
)                     {
  if (!entry) {
    return undefined;
  }

  // When no model label was persisted, prefer a task-bearing sentence over a
  // raw first-bubble truncation so Control UI and gateway clients stay readable.
  // Derived titles are human content only; UI/TUI/ACP own key-based fallbacks,
  // which an id prefix here would mask.
  return (
    normalizeOptionalString(entry.label) ??
    normalizeOptionalString(externalDisplayName) ??
    normalizeOptionalString(entry.displayName) ??
    normalizeOptionalString(entry.subject) ??
    (deriveGoalSessionTitle(firstUserMessage) || undefined)
  );
}
export function prepareSessionTitleRead(
  entry                          ,
  displayName                    ,
  opts                                                                  ,
) {
  if (!entry?.sessionId || !(opts.includeDerivedTitles || opts.includeLastMessage)) {
    return undefined;
  }
  // Metadata wins over transcript text in both scalar and tool rows. Carry
  // that result forward so title-only reads do not hydrate discarded payloads.
  const derivedTitle = opts.includeDerivedTitles
    ? deriveSessionTitle(entry, undefined, displayName)
    : undefined;
  return {
    derivedTitle,
    needsTranscript: opts.includeLastMessage || !derivedTitle,
  };
}