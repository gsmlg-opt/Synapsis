export function estimateBase64DecodedBytes(base64        )         {
  // Avoid `trim()`/`replace()` here: they allocate a second (potentially huge) string.
  // We only need a conservative decoded-size estimate to enforce budgets before Buffer.from(..., "base64").
  let effectiveLen = base64.length;
  // oxlint-disable-next-line eslint/no-control-regex -- Preserve the estimator's ASCII control and space handling.
  const firstWhitespace = base64.search(/[\x00-\x20]/);
  if (firstWhitespace !== -1) {
    for (let i = firstWhitespace; i < base64.length; i += 1) {
      if (base64.charCodeAt(i) <= 0x20) {
        effectiveLen -= 1;
      }
    }
  }

  if (effectiveLen === 0) {
    return 0;
  }

  let padding = 0;
  // Find last non-whitespace char(s) to detect '=' padding without allocating/copying.
  let end = base64.length - 1;
  while (end >= 0 && base64.charCodeAt(end) <= 0x20) {
    end -= 1;
  }
  if (end >= 0 && base64[end] === "=") {
    padding = 1;
    end -= 1;
    while (end >= 0 && base64.charCodeAt(end) <= 0x20) {
      end -= 1;
    }
    if (end >= 0 && base64[end] === "=") {
      padding = 2;
    }
  }

  const estimated = Math.floor((effectiveLen * 3) / 4) - padding;
  return Math.max(0, estimated);
}