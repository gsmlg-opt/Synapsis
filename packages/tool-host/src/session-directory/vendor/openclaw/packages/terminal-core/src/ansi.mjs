import { ANSI_COMPAT_CONTROL_SEQUENCE_PATTERN } from "./ansi-sequences.mjs";
import { ANSI_OSC_INTRODUCER_PATTERN } from "./ansi-sequences.mjs";
import { ANSI_STRING_TERMINATOR_PATTERN } from "./ansi-sequences.mjs";
import { matchAnsiOscAt } from "./ansi-sequences.mjs";
import { scanAnsiCsiAt } from "./ansi-sequences.mjs";
const ANSI_OSC_SEQUENCE_PATTERN = `${ANSI_OSC_INTRODUCER_PATTERN}[\\s\\S]*?${ANSI_STRING_TERMINATOR_PATTERN}`;
const ANSI_COMPAT_SEQUENCE_AT_INDEX_REGEX = new RegExp(
  `${ANSI_OSC_SEQUENCE_PATTERN}|${ANSI_COMPAT_CONTROL_SEQUENCE_PATTERN}`,
  "y",
);
function hasAnsiIntroducer(input        )          {
  return input.includes("\u001B") || input.includes("\u009B") || input.includes("\u009D");
}
function stripAnsiInternal(
  input        ,
  options                                                                    ,
)         {
  if (!hasAnsiIntroducer(input)) {
    return input;
  }
  const output           = [];
  let copyStart = 0;
  let index = 0;

  while (index < input.length) {
    const introducerCode = input.charCodeAt(index);
    if (introducerCode !== 0x1b && introducerCode !== 0x9b && introducerCode !== 0x9d) {
      index += 1;
      continue;
    }

    const osc = matchAnsiOscAt(input, index);
    const csi = osc ? undefined : scanAnsiCsiAt(input, index);
    ANSI_COMPAT_SEQUENCE_AT_INDEX_REGEX.lastIndex = index;
    const compatibilityMatch =
      !osc && options.compatibilityGrammar
        ? ANSI_COMPAT_SEQUENCE_AT_INDEX_REGEX.exec(input)?.[0]
        : undefined;
    let length = osc?.length ?? csi?.value.length ?? compatibilityMatch?.length;
    if (length === undefined) {
      index += 1;
      continue;
    }

    if (csi && !csi.ended && options.preserveIncompleteCsi) {
      break;
    }

    if (csi?.controls.length === 0 && compatibilityMatch) {
      length = Math.max(length, compatibilityMatch.length);
    }

    output.push(input.slice(copyStart, index), ...(csi?.controls ?? []));
    index += length;
    copyStart = index;
  }

  output.push(input.slice(copyStart));
  return output.join("");
}
export function stripAnsi(input        )         {
  return stripAnsiInternal(input, { compatibilityGrammar: false });
}
const LOG_CONTROL_CHARS_REGEX = new RegExp(
  `[${String.fromCharCode(0x00)}-${String.fromCharCode(0x1f)}${String.fromCharCode(0x7f)}-${String.fromCharCode(0x9f)}]`,
  "g",
);
export function sanitizeForLog(v        )         {
  return stripAnsi(v).replace(LOG_CONTROL_CHARS_REGEX, "");
}
export { ANSI_OSC_SEQUENCE_PATTERN, ANSI_COMPAT_SEQUENCE_AT_INDEX_REGEX, hasAnsiIntroducer, stripAnsiInternal, LOG_CONTROL_CHARS_REGEX };