import { deriveSessionTitle as derivePinnedSessionTitle, prepareSessionTitleRead } from './vendor/openclaw/src/gateway/session-utils-core.mjs';
import { projectSessionDisplayMessage as projectPinnedSessionDisplayMessage } from './vendor/openclaw/src/gateway/session-display-projection.mjs';
import { findFirstTitleUserText, findLastMessageText } from './vendor/openclaw/src/gateway/session-transcript-title-reader.worker.mjs';

export const REFERENCE_COMMIT = '488631c18fae7cc541ba8fc8beff6cbb0438787b';

export const deriveSessionTitle = derivePinnedSessionTitle;

// The pinned projection consumes delivery fields on its display copy. Keep the
// source function unchanged while protecting caller-owned transcript messages.
export function projectSessionDisplayMessage(message, options) {
  return projectPinnedSessionDisplayMessage(structuredClone(message), options);
}

function transcriptEvents(messages = []) {
  return structuredClone(messages).map((message, seq) => ({ event: { type: 'message', message }, seq }));
}

// Storage probes and their shared deadline belong to the invoking Elixir owner.
// This pure adapter only selects text from the supplied bounded message pages.
export function projectRows(rows, { includeDerivedTitles = false, includeLastMessage = false } = {}) {
  return rows.map(row => {
    const prepared = prepareSessionTitleRead(row.entry, row.externalDisplayName, { includeDerivedTitles, includeLastMessage });
    if (!prepared) return { needsHead: false, needsTail: false };
    const firstUserMessage = includeDerivedTitles && !prepared.derivedTitle
      ? findFirstTitleUserText(transcriptEvents(row.head), false)
      : null;
    const derivedTitle = includeDerivedTitles
      ? prepared.derivedTitle ?? derivePinnedSessionTitle(row.entry, firstUserMessage, row.externalDisplayName)
      : undefined;
    const lastMessagePreview = includeLastMessage ? findLastMessageText(transcriptEvents(row.tail)) : null;
    return {
      ...(derivedTitle === undefined ? {} : { derivedTitle }),
      ...(lastMessagePreview === null ? {} : { lastMessagePreview }),
      needsHead: Boolean(includeDerivedTitles && !prepared.derivedTitle && firstUserMessage === null),
      needsTail: Boolean(includeLastMessage && lastMessagePreview === null),
    };
  });
}
