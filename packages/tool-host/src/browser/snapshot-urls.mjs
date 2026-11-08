const SNAPSHOT_BYTES = 262144;
const HEADER = '\n\nLinks:\n';

// Match the pinned Playwright driver: document anchors only, exact href
// deduplication, first occurrence order, and at most one hundred URLs. Unlike
// the pin's catch-to-empty behavior, evaluation failure fails the owned capture.
export async function collectSnapshotUrls(scope) {
  return scope.evaluate(maxBytes => {
    const entries = []; const seen = new Set(); const encoder = new TextEncoder();
    let bytes = encoder.encode(JSON.stringify({ entries: [], truncated: false })).byteLength;
    let truncated = false;
    for (const anchor of document.querySelectorAll('a[href]')) {
      const url = anchor instanceof HTMLAnchorElement ? anchor.href : '';
      if (!url || seen.has(url)) continue;
      seen.add(url);
      const label = (anchor.textContent || anchor.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim() || url;
      let text = label.slice(0, 120);
      // Keep the label limit in UTF-16 units without publishing half a pair.
      if (text.length < label.length && /[\uD800-\uDBFF]$/.test(text)) text = text.slice(0, -1);
      const entry = { text: text || url, url };
      const size = encoder.encode(JSON.stringify(entry)).byteLength + (entries.length ? 1 : 0);
      if (bytes + size > maxBytes) { truncated = true; break; }
      entries.push(entry); bytes += size;
      if (entries.length === 100) break;
    }
    return { entries, truncated };
  }, SNAPSHOT_BYTES);
}

// The body already owns its rendered refs. Append only complete numbered URL
// lines within the same character/UTF-8 budgets; never clip an href or leave a
// bare header. The body line-count budget does not count this appendix.
export function appendSnapshotUrls(snapshot, collected, maxChars) {
  let output = snapshot; let bytes = Buffer.byteLength(snapshot);
  let truncated = collected.truncated;
  let count = 0;
  for (const entry of collected.entries) {
    const addition = `${count ? '\n' : HEADER}${count + 1}. ${entry.text} -> ${entry.url}`;
    const size = Buffer.byteLength(addition);
    if (output.length + addition.length > maxChars || bytes + size > SNAPSHOT_BYTES) { truncated = true; break; }
    output += addition; bytes += size; count++;
  }
  return { snapshot: output, truncated };
}
