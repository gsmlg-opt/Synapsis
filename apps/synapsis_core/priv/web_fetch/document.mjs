import { createReadabilityWebContentExtractor } from './vendor/openclaw/extensions/web-readability/web-content-extractor.mjs';
import { readResponseText } from './vendor/openclaw/src/agents/tools/web-shared.mjs';
import { extractBasicHtmlContent, markdownToText, truncateWebFetchText } from './vendor/openclaw/src/agents/tools/web-fetch-utils.mjs';
import { truncateSanitizedExternalContent, wrapExternalContent, wrapWebContent } from './vendor/openclaw/src/security/external-content.mjs';
import { resolveIntegerOption } from './vendor/openclaw/packages/normalization-core/src/number-coercion.mjs';

const REFERENCE_COMMIT = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const DEPENDENCY_VERSIONS = Object.freeze({ '@mozilla/readability': '0.6.0', linkedom: '0.18.13', entities: '8.1.0' });
const WRAPPER_WITH_WARNING_OVERHEAD = wrapWebContent('', 'web_fetch').length;
const WRAPPER_NO_WARNING_OVERHEAD = wrapExternalContent('', { source: 'web_fetch', includeWarning: false }).length;
const readability = createReadabilityWebContentExtractor();
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

function fields(value, names) {
  if (!record(value) || names.some(key => !own(value, key)) ||
      Object.keys(value).some(key => !names.includes(key))) throw new TypeError('Invalid document request');
}

// Source-derived outer assembly: web-fetch.ts:279-306 and441-538. The unchanged
// source helpers own sanitization, framing, Markdown and UTF16-safe slicing.
// Host acquisition has already bounded complete bytes; no spill file is created.
function wrapContent(value, maxChars) {
  if (maxChars <= 0) return { text: '', truncated: true, rawLength: value.length, length: 0 };
  const includeWarning = maxChars >= WRAPPER_WITH_WARNING_OVERHEAD + Math.min(value.length, WRAPPER_WITH_WARNING_OVERHEAD);
  const overhead = includeWarning ? WRAPPER_WITH_WARNING_OVERHEAD : WRAPPER_NO_WARNING_OVERHEAD;
  const bounded = truncateSanitizedExternalContent(value, Math.max(0, maxChars - overhead));
  const wrapped = truncateWebFetchText(wrapExternalContent(bounded.text, { source: 'web_fetch', includeWarning }), maxChars);
  return { text: wrapped.text, truncated: bounded.truncated || wrapped.truncated,
    rawLength: value.length, length: wrapped.text.length };
}

function assemble(input, payload, maxChars) {
  let metadataTruncated = false;
  const boundProtocolField = (value, limit) => {
    const bounded = truncateWebFetchText(value, limit);
    metadataTruncated ||= bounded.truncated;
    return Buffer.from(bounded.text, 'utf16le').toString('utf16le');
  };
  let remainingMetadataChars = Math.min(512, Math.floor(maxChars / 2));
  const wrapMetadata = value => {
    if (typeof value !== 'string' || !value) return undefined;
    const maxInner = Math.max(0, remainingMetadataChars - WRAPPER_NO_WARNING_OVERHEAD);
    const bounded = truncateSanitizedExternalContent(value, Math.min(256, maxInner));
    metadataTruncated ||= bounded.truncated;
    if (!bounded.text) return undefined;
    const wrapped = wrapExternalContent(bounded.text, { source: 'web_fetch', includeWarning: false });
    remainingMetadataChars -= wrapped.length;
    return wrapped;
  };
  const warning = wrapMetadata(payload.warning);
  const title = wrapMetadata(payload.title);
  const wrapped = wrapContent(payload.text, maxChars - (title?.length ?? 0) - (warning?.length ?? 0));
  const oversizedFinalUrl = input.finalUrl !== input.url && input.finalUrl.length > 2048;
  metadataTruncated ||= oversizedFinalUrl;
  return {
    url: input.url,
    finalUrl: oversizedFinalUrl ? input.url : input.finalUrl,
    contentType: boundProtocolField(payload.contentType, 256),
    status: input.status,
    ...(title ? { title } : {}),
    extractMode: input.extractMode,
    extractor: boundProtocolField(payload.extractor, 128),
    externalContent: { untrusted: true, source: 'web_fetch', wrapped: true },
    truncated: wrapped.truncated || metadataTruncated || payload.truncated,
    length: wrapped.length,
    rawLength: wrapped.rawLength,
    text: wrapped.text,
    ...(warning ? { warning } : {}),
  };
}

// Pure immutable computation on already acquired bytes. An in-memory Response
// adapts the original source decoder API; it performs no transport or network.
export async function prepareReadableDocument(request) {
  fields(request, ['protocol', 'id', 'operation', 'input']);
  if (request.protocol !== 1 || typeof request.id !== 'string' || !request.id ||
      request.operation !== 'readable_document') throw new TypeError('Invalid document request');
  const input = request.input;
  fields(input, ['bytes', 'url', 'finalUrl', 'status', 'contentType', 'extractMode', 'maxChars']);
  if (typeof input.bytes !== 'string' || typeof input.url !== 'string' || typeof input.finalUrl !== 'string' ||
      !Number.isSafeInteger(input.status) || input.status < 200 || input.status > 299 ||
      (input.contentType !== null && typeof input.contentType !== 'string') ||
      !['markdown', 'text'].includes(input.extractMode) || !Number.isSafeInteger(input.maxChars)) {
    throw new TypeError('Invalid document input');
  }
  const bytes = Buffer.from(input.bytes, 'base64');
  if (bytes.byteLength > 750000 || bytes.toString('base64') !== input.bytes) throw new RangeError('Invalid document bytes');
  const headers = input.contentType === null ? undefined : { 'content-type': input.contentType };
  const decoded = await readResponseText(new Response(bytes, { headers }), { maxBytes: 750000 });
  const body = decoded.text;
  const declaredType = input.contentType?.split(';')[0]?.trim().toLowerCase();
  const head = body.trimStart().slice(0, 256).toLowerCase();
  const contentType = declaredType || ((head.startsWith('<!doctype html') || head.startsWith('<html')) ? 'text/html' : 'application/octet-stream');
  let text = body, title, extractor = 'raw';
  if (contentType === 'text/markdown') {
    extractor = 'cf-markdown';
    if (input.extractMode === 'text') text = markdownToText(body);
  } else if (['text/html', 'application/xhtml+xml'].includes(contentType)) {
    // Execute the original plugin with actual Readability and linkedom/worker.
    // Runtime provider discovery is deliberately outside this byte transformer.
    const extracted = await readability.extract({ html: body, url: input.finalUrl, extractMode: input.extractMode });
    if (extracted?.text) {
      ({ text, title } = extracted);
      extractor = readability.id;
    } else {
      const basic = await extractBasicHtmlContent({ html: body, extractMode: input.extractMode });
      if (!basic?.text) throw new Error('Readable document returned no content');
      ({ text, title } = basic);
      extractor = 'raw-html';
    }
  } else if (contentType === 'application/json' || contentType.endsWith('+json')) {
    // Original web-fetch.ts:754-772: preserve every numeric source lexeme.
    try {
      text = JSON.stringify(JSON.parse(body, (_key, value, context) =>
        typeof value === 'number' ? JSON.rawJSON(context.source) : value), null, 2);
      extractor = 'json';
    } catch {
      text = body;
      extractor = 'raw';
    }
  }
  const result = assemble(input, { contentType, text, title, extractor,
    truncated: decoded.truncated,
    warning: decoded.truncated ? `Response body incomplete after ${decoded.bytesRead} bytes.` : undefined,
  }, resolveIntegerOption(input.maxChars, 20000, { min: 100, max: 20000 }));
  return {
    protocol: 1, id: request.id, referenceCommit: REFERENCE_COMMIT,
    dependencyVersions: { ...DEPENDENCY_VERSIONS },
    runtime: { node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
      icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch },
    result,
  };
}
