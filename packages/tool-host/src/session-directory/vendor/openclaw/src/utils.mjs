import os from "node:os";
import path from "node:path";
import { normalizeHomeDirValue } from "../packages/normalization-core/src/home-dir.mjs";
import { resolveConfigDir } from "./infra/config-dir.mjs";
import { resolveEffectiveHomeDir } from "../packages/normalization-core/src/home-dir.mjs";
import { resolveUserPath } from "./infra/home-dir.mjs";
import { escapeRegExp as escapeRegExpValue } from "./shared/regexp.mjs";
export function resolveHomeDir()                     {
  return resolveEffectiveHomeDir(process.env, os.homedir);
}
const HOME_TEXT_START = String.raw`(?<=^|[\s"'\x60(\[{<=:;]|file://)`;
const HOME_TEXT_DELIMITER = String.raw`[\s"'\x60)\]}>]`;
const HOME_TEXT_LIST_NEXT = String.raw`[:;](?=[/\\~$]|[A-Za-z]:)`;
function resolveHomeDisplayPrefix()                                               {
  const home = resolveHomeDir();
  if (!home) {
    return undefined;
  }
  const explicitHome = normalizeHomeDirValue(process.env.OPENCLAW_HOME);
  if (explicitHome) {
    return { home, prefix: "$OPENCLAW_HOME" };
  }
  return { home, prefix: "~" };
}
export function shortenHomeInString(input        )         {
  if (!input) {
    return input;
  }
  const display = resolveHomeDisplayPrefix();
  // A filesystem-root home such as "/" would turn every path separator into the prefix.
  if (!display || path.parse(display.home).root === display.home) {
    return input;
  }
  // Diagnostics delimit paths with whitespace, quotes, brackets, `=`, and PATH list separators.
  // Replace the home only between those delimiters so /home/al+old, /mnt/home/al, and
  // /home/al.bak stay exact. Trailing `.`, `,`, `;`, or `:` ends the home only when a
  // delimiter, the end of the text, or the next PATH entry follows it.
  // POSIX file names may contain backslashes, so only Windows treats them as separators.
  const pathSeparator = process.platform === "win32" ? String.raw`[\\/]` : "/";
  const homePattern = new RegExp(
    `${HOME_TEXT_START}${escapeRegExpValue(display.home)}(?=$|${pathSeparator}|${HOME_TEXT_DELIMITER}|[.,;:](?:$|${HOME_TEXT_DELIMITER})|${HOME_TEXT_LIST_NEXT})`,
    process.platform === "win32" ? "giu" : "gu",
  );
  return input.replace(homePattern, display.prefix);
}
export { resolveConfigDir, resolveUserPath, HOME_TEXT_START, HOME_TEXT_DELIMITER, HOME_TEXT_LIST_NEXT, resolveHomeDisplayPrefix };