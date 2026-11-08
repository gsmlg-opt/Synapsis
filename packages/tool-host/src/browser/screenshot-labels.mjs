const MAX_LABELS = 150;
const overlaps = (a, b) => a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;

// Read the capture's actual pixel dimensions, without decoding or re-encoding it.
export function screenshotDimensions(buffer, type) {
  if (type === 'png' && buffer.length >= 24 && buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    const width = buffer.readUInt32BE(16); const height = buffer.readUInt32BE(20);
    if (width && height) return { width, height };
  }
  if (type === 'jpeg' && buffer.length >= 4 && buffer.readUInt16BE(0) === 0xffd8) {
    let offset = 2;
    while (offset < buffer.length) {
      if (buffer[offset++] !== 0xff) break;
      while (buffer[offset] === 0xff) offset++;
      const marker = buffer[offset++];
      if (marker === 0xd9 || marker === 0xda) break;
      if (marker === 0x01 || marker >= 0xd0 && marker <= 0xd8) continue;
      if (offset + 2 > buffer.length) break;
      const length = buffer.readUInt16BE(offset);
      if (length < 2 || offset + length > buffer.length) break;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker) && length >= 8) {
        const height = buffer.readUInt16BE(offset + 3); const width = buffer.readUInt16BE(offset + 5);
        if (width && height) return { width, height };
      }
      offset += length;
    }
  }
  throw new Error('Cannot determine screenshot dimensions for label annotations');
}

export async function measureScreenshotLabels({ page, handles, metadata, space, assertCurrent }) {
  const view = await page.evaluate(() => ({
    x: window.visualViewport.pageLeft, y: window.visualViewport.pageTop,
    width: window.visualViewport.width, height: window.visualViewport.height,
    scale: window.visualViewport.scale,
    fullWidth: Math.max(document.body?.scrollWidth ?? 0, document.documentElement.scrollWidth,
      document.body?.offsetWidth ?? 0, document.documentElement.offsetWidth,
      document.body?.clientWidth ?? 0, document.documentElement.clientWidth),
  }));
  assertCurrent();
  const inputs = []; let skipped = 0;
  for (const [ref, handle] of handles) {
    const info = metadata.get(ref);
    if (!info) continue;
    if (space === 'fullpage' && inputs.length >= MAX_LABELS) { skipped++; continue; }
    const box = await handle.boundingBox();
    assertCurrent();
    if (!box || !box.width || !box.height) { skipped++; continue; }
    inputs.push({ ref, role: info.role, ...(info.name ? { name: info.name } : {}),
      doc: { x: box.x + view.x, y: box.y + view.y, width: box.width, height: box.height } });
  }
  return { view, inputs, skipped };
}

export function planScreenshotLabels(measurement, space, elementRect) {
  const { view, inputs } = measurement;
  const viewport = { x: view.x, y: view.y, width: view.width, height: view.height };
  const annotations = []; const overlays = []; let skipped = measurement.skipped;
  for (const input of inputs) {
    if (space === 'element' && !overlaps(input.doc, elementRect)) continue;
    if (space === 'viewport' && !overlaps(input.doc, viewport)) { annotations.push(input); skipped++; continue; }
    if (overlays.length >= MAX_LABELS) { skipped++; continue; }
    overlays.push(input); annotations.push(input);
  }
  return { annotations, overlays, skipped };
}

// The caller records this detached handle before any guard or page mutation.
export function createScreenshotOverlay(page) {
  return page.evaluateHandle(() => document.createElement('div'));
}

export async function attachScreenshotOverlay(root, overlays, captureY) {
  await root.evaluate((root, { overlays, captureY }) => {
    const document = root.ownerDocument;
    root.setAttribute('data-synapsis-labels', '1');
    root.style.cssText = 'all:initial;position:absolute;top:0;left:0;width:0;height:0;pointer-events:none;z-index:2147483647;font-family:monospace;';
    for (const item of overlays) {
      const { x, y, width, height } = item.doc;
      const box = document.createElement('div');
      box.style.cssText = `all:initial;position:absolute;left:${Math.round(x)}px;top:${Math.round(y)}px;width:${Math.max(1, Math.round(width))}px;height:${Math.max(1, Math.round(height))}px;border:2px solid #ffb020;box-sizing:border-box;pointer-events:none;`;
      const tag = document.createElement('div'); tag.textContent = item.ref;
      const labelY = y - captureY < 14 ? y + 2 : y - 14;
      tag.style.cssText = `all:initial;position:absolute;left:${Math.round(x)}px;top:${Math.round(labelY)}px;background:#ffb020;color:#1a1a1a;font:bold 11px/14px monospace;padding:0 4px;border-radius:2px;white-space:nowrap;pointer-events:none;`;
      root.append(box, tag);
    }
    document.documentElement.append(root);
  }, { overlays, captureY });
}

export async function clearScreenshotOverlay(root, cleanupError) {
  if (!root) return;
  let failure;
  try { if (!await root.evaluate(root => { root.remove(); return !root.isConnected; })) failure = true; }
  catch { failure = true; }
  try { await root.dispose(); } catch { failure = true; }
  if (failure) throw cleanupError();
}

export function screenshotAnnotations(plan, clip, dimensions) {
  const scale = dimensions.width / clip.width;
  return plan.annotations.map(({ ref, role, name, doc }) => ({
    ref, number: Number(ref.match(/\d+/)?.[0] ?? 0), role, ...(name ? { name } : {}),
    box: { x: Math.round((doc.x - clip.x) * scale), y: Math.round((doc.y - clip.y) * scale),
      width: Math.max(1, Math.round(doc.width * scale)), height: Math.max(1, Math.round(doc.height * scale)) },
  }));
}
