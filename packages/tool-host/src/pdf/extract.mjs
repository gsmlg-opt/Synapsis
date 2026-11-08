import { createEngine, encodePng } from 'clawpdf';

// Rendering/text algorithm adapted from OpenClaw at
// 488631c18fae7cc541ba8fc8beff6cbb0438787b:
// extensions/document-extract/document-extractor.runtime.ts (see OPENCLAW-LICENSE).
// This bytes-only foundation has no provider, source acquisition or tool catalog.
export const PDF_LIMITS = Object.freeze({
  maxBytes: 10 * 1024 * 1024,
  defaultMaxPages: 20,
  // An explicit host operational bound, not OpenClaw's model-facing input schema.
  maxPages: 1000,
  maxPixels: 4_000_000,
  minTextChars: 200,
  maxTextChars: 200_000,
  maxRenderDimension: 10_000
});

const REQUEST_FIELDS = new Set(['buffer', 'maxPages', 'maxPixels', 'minTextChars', 'password', 'pageNumbers']);

function integerOption(name, value, fallback, ceiling) {
  const result = value === undefined ? fallback : value;
  if (!Number.isSafeInteger(result) || result <= 0 || result > ceiling) {
    throw new RangeError(`${name} must be a positive integer at most ${ceiling}`);
  }
  return result;
}

function normalizeRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new TypeError('PDF request must be an object');
  for (const field of Object.keys(request)) {
    if (!REQUEST_FIELDS.has(field)) throw new TypeError(`Unsupported PDF request field: ${field}`);
  }
  if (!(request.buffer instanceof Uint8Array)) throw new TypeError('buffer must contain PDF bytes as a Uint8Array');
  if (request.buffer.byteLength === 0 || request.buffer.byteLength > PDF_LIMITS.maxBytes) {
    throw new RangeError(`PDF bytes must be between 1 and ${PDF_LIMITS.maxBytes}`);
  }
  if (request.password !== undefined && typeof request.password !== 'string') throw new TypeError('password must be a string');
  if (request.pageNumbers !== undefined && (!Array.isArray(request.pageNumbers) || request.pageNumbers.length === 0 ||
      request.pageNumbers.length > PDF_LIMITS.maxPages ||
      !request.pageNumbers.every(page => Number.isSafeInteger(page) && page > 0))) {
    throw new RangeError(`pageNumbers must contain 1 to ${PDF_LIMITS.maxPages} positive integer page numbers`);
  }
  return {
    buffer: request.buffer,
    password: request.password,
    pageNumbers: request.pageNumbers === undefined ? undefined : [...new Set(request.pageNumbers)].sort((a, b) => a - b),
    maxPages: integerOption('maxPages', request.maxPages, PDF_LIMITS.defaultMaxPages, PDF_LIMITS.maxPages),
    maxPixels: integerOption('maxPixels', request.maxPixels, PDF_LIMITS.maxPixels, PDF_LIMITS.maxPixels),
    minTextChars: integerOption('minTextChars', request.minTextChars, PDF_LIMITS.minTextChars, Number.MAX_SAFE_INTEGER)
  };
}

function textPrefix(text, limit) {
  let end = Math.min(text.length, Math.max(0, limit));
  if (end > 0 && end < text.length) {
    const last = text.charCodeAt(end - 1), next = text.charCodeAt(end);
    if (last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end--;
  }
  return text.slice(0, end);
}

function pageRenderOptions(width, height, maxPixels) {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || maxPixels < 1) return null;
  const defaultWidth = Math.ceil(width * (96 / 72)), defaultHeight = Math.ceil(height * (96 / 72));
  if (defaultWidth <= PDF_LIMITS.maxRenderDimension && defaultHeight <= PDF_LIMITS.maxRenderDimension && defaultWidth * defaultHeight <= maxPixels) {
    return { options: { dpi: 96, forms: true }, reduced: false };
  }
  const landscape = width >= height, longer = Math.max(width, height), shorter = Math.min(width, height);
  let low = 1, high = Math.min(PDF_LIMITS.maxRenderDimension, Math.ceil(longer * (96 / 72))), size = 0;
  while (low <= high) {
    const candidate = Math.floor((low + high) / 2), other = Math.max(1, Math.ceil(shorter * (candidate / longer)));
    if (candidate * other <= maxPixels) {
      size = candidate;
      low = candidate + 1;
    } else high = candidate - 1;
  }
  if (size === 0) return null;
  return { options: landscape ? { width: size, forms: true } : { height: size, forms: true }, reduced: true };
}

/**
 * Extract one actual PDF from bytes; resolves only after document/engine cleanup.
 * CPU work executes on this Node thread. The future Elixir Port caller must own
 * the one-shot process deadline/termination; no BEAM nonblocking claim is made here.
 * Returns { text, images: [{type, data: base64, mimeType}], metadata }.
 */
export async function extractPdfContent(input) {
  const request = normalizeRequest(input);
  const engine = await createEngine({ maxRenderPixels: request.maxPixels });
  let pdf;
  try {
    pdf = await engine.open(request.buffer, request.password === undefined ? {} : { password: request.password });
    const intendedPages = request.pageNumbers;
    const selectedPages = intendedPages === undefined
      ? Array.from({ length: Math.min(pdf.pageCount, request.maxPages) }, (_, i) => i + 1)
      : intendedPages.filter(page => page <= pdf.pageCount).slice(0, request.maxPages);
    if (intendedPages && selectedPages.length === 0) throw new RangeError(`No requested PDF pages exist in this ${pdf.pageCount}-page document`);
    const metadata = {
      pages: {
        processed: selectedPages, total: pdf.pageCount,
        selection: intendedPages === undefined ? 'automatic' : 'explicit',
        truncated: selectedPages.length < (intendedPages?.length ?? pdf.pageCount)
      },
      textTruncated: false, imagesTruncated: false
    };
    const imagePages = [];
    let text = '';
    for (const pageNumber of selectedPages) {
      const pageText = pdf.page(pageNumber).text();
      if (pageText.trim().length < request.minTextChars) imagePages.push(pageNumber);
      const separator = text ? '\n\n' : '';
      const prefix = textPrefix(pageText, PDF_LIMITS.maxTextChars - text.length - separator.length);
      metadata.textTruncated ||= prefix.length < pageText.length;
      if (prefix) text += separator + prefix;
    }
    const images = [];
    let remainingPixels = request.maxPixels;
    try {
      for (const [index, pageNumber] of imagePages.entries()) {
        if (remainingPixels <= 0) { metadata.imagesTruncated = true; break; }
        const page = pdf.page(pageNumber);
        // Floor the shared allowance so rounding cannot exceed the aggregate budget.
        const allocation = Math.max(1, Math.floor(remainingPixels / (imagePages.length - index)));
        const plan = pageRenderOptions(page.width, page.height, allocation);
        if (!plan) { metadata.imagesTruncated = true; continue; }
        const rendered = page.render(plan.options);
        const pixels = rendered.width * rendered.height;
        if (pixels > allocation || rendered.width > PDF_LIMITS.maxRenderDimension || rendered.height > PDF_LIMITS.maxRenderDimension) {
          throw new Error('PDF renderer exceeded its planned image budget');
        }
        metadata.imagesTruncated ||= plan.reduced;
        const bytes = await encodePng(rendered.rgba, { width: rendered.width, height: rendered.height });
        images.push({ type: 'image', data: Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64'), mimeType: 'image/png' });
        remainingPixels -= pixels;
      }
    } catch (error) {
      // Reference partial-result semantics: the image phase is discarded as a
      // whole and its omission is explicit. Empty text cannot rescue a failure.
      metadata.imagesTruncated = true;
      if (!text.trim()) throw new Error('PDF image extraction failed with no extractable text', { cause: error });
      return { text, images: [], metadata };
    }
    return { text, images, metadata };
  } finally {
    try { pdf?.destroy(); }
    finally { await engine.destroy(); }
  }
}
