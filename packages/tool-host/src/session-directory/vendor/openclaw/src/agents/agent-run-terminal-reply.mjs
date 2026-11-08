import { stripMixedSilentReplyTokens } from "../auto-reply/reply/mixed-silent-reply-tokens.mjs";
import { isSilentReplyText } from "../auto-reply/tokens.mjs";
export function prepareAgentRunReplyText(rawText        )                     {
  if (isSilentReplyText(rawText)) {
    return undefined;
  }
  return stripMixedSilentReplyTokens(rawText) ?? rawText.replace(/[\r\n]\s*NO_REPLY\s*$/iu, "");
}