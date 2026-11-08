function longestBacktickRun(value        )         {
  let longest = 0;
  let current = 0;
  for (const char of value) {
    if (char === "`") {
      current += 1;
      longest = Math.max(longest, current);
      continue;
    }
    current = 0;
  }
  return longest;
}
export function formatInlineCodeSpan(value        )         {
  const delimiter = "`".repeat(longestBacktickRun(value) + 1);
  const padding = value.startsWith("`") || value.endsWith("`") || value.includes("\n") ? " " : "";
  return `${delimiter}${padding}${value}${padding}${delimiter}`;
}
export { longestBacktickRun };