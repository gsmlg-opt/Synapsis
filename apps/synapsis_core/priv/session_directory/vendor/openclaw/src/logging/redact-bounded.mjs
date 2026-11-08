const REDACT_REGEX_CHUNK_THRESHOLD = 32_768;
const REDACT_REGEX_CHUNK_SIZE = 16_384;
export function replacePatternBounded(
  text        ,
  pattern        ,
  replacer                                  ,
)         {
  if (text.length <= REDACT_REGEX_CHUNK_THRESHOLD) {
    return text.replace(pattern, replacer);
  }

  let output                    ;
  // Preserve every chunk-local replacement; only defer assembling unchanged output.
  // Chunking may miss matches spanning chunk boundaries; use only for token-like redaction patterns.
  for (let index = 0; index < text.length; index += REDACT_REGEX_CHUNK_SIZE) {
    const chunk = text.slice(index, index + REDACT_REGEX_CHUNK_SIZE);
    const replaced = chunk.replace(pattern, replacer);
    if (output !== undefined) {
      output += replaced;
    } else if (replaced !== chunk) {
      output = text.slice(0, index) + replaced;
    }
  }
  return output ?? text;
}
export { REDACT_REGEX_CHUNK_THRESHOLD, REDACT_REGEX_CHUNK_SIZE };