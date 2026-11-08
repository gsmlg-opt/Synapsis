import { stripAnsi } from "./ansi.mjs";
export function sanitizeTerminalText(input        )         {
  // Strip escapes first so removed bytes cannot become a new ANSI sequence.
  return stripAnsi(input).replace(/\p{Cc}/gu, (control) =>
    control === "\r" ? "\\r" : control === "\n" ? "\\n" : control === "\t" ? "\\t" : "",
  );
}