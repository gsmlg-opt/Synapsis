import { SILENT_REPLY_TOKEN } from "../tokens.mjs";

/** Removes one standalone leading control line without changing the remaining text. */
export function stripMixedSilentReplyTokens(text        )                {
  const prefix = `${SILENT_REPLY_TOKEN}\n`;
  return text.slice(0, prefix.length).toUpperCase() === prefix ? text.slice(prefix.length) : null;
}
