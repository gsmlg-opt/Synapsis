export function escapeMarkdownText(text        )         {
  return text.replace(/[!-/:-@[-`{-~]/g, "\\$&");
}