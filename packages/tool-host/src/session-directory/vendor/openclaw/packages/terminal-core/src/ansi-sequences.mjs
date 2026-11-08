export const ANSI_OSC_INTRODUCER_PATTERN = "(?:\\x1b\\]|\\x9d)";
export const ANSI_STRING_TERMINATOR_PATTERN = "(?:\\x1b\\\\|\\x07|\\x9c)";
const ANSI_OSC_PATTERN = `${ANSI_OSC_INTRODUCER_PATTERN}[^\\x07\\x1b\\x9c]*${ANSI_STRING_TERMINATOR_PATTERN}`;
export const ANSI_COMPAT_CONTROL_SEQUENCE_PATTERN =
  "[\\u001B\\u009B][[\\]()#;?]*(?:\\d{1,4}(?:[;:]\\d{0,4})*)?[\\dA-PR-TZcf-nq-uy=><~]";
const ansiOscAtIndexRegex = new RegExp(ANSI_OSC_PATTERN, "y");
export function matchAnsiOscAt(input        , index        )                     {
  // Reset the sticky matcher when callers interleave segment iterators.
  ansiOscAtIndexRegex.lastIndex = index;
  return ansiOscAtIndexRegex.exec(input)?.[0];
}
export function scanAnsiCsiAt(input        , index        )                          {
  const firstCode = input.charCodeAt(index);
  if (firstCode !== 0x9b && (firstCode !== 0x1b || input.charCodeAt(index + 1) !== 0x5b)) {
    return undefined;
  }

  let cursor = index + (firstCode === 0x9b ? 1 : 2);
  const controls           = [];
  let ended = false;
  while (cursor < input.length) {
    const code = input.charCodeAt(cursor);
    if (code === 0x18 || code === 0x1a) {
      cursor += 1;
      ended = true;
      break;
    }
    if (code === 0x1b || code === 0x9b) {
      ended = true;
      break;
    }
    if (code <= 0x1f || code === 0x7f) {
      controls.push(input.charAt(cursor));
      cursor += 1;
      continue;
    }
    if (code >= 0x20 && code <= 0x3f) {
      cursor += 1;
      continue;
    }
    if (code >= 0x40 && code <= 0x7e) {
      cursor += 1;
    }
    ended = true;
    break;
  }
  return { controls, ended, value: input.slice(index, cursor) };
}
export { ANSI_OSC_PATTERN, ansiOscAtIndexRegex };