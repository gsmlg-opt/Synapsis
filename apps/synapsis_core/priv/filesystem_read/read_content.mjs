import { detectSupportedImageMimeType } from './vendor/openclaw/src/agents/utils/mime.mjs';
import { processImage } from './vendor/openclaw/src/agents/utils/image-resize.mjs';
import { classifyAttachmentBytes } from './vendor/openclaw/packages/media-core/src/attachment-classify.mjs';

const REFERENCE_COMMIT = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const VISION_NOTE = '[Current model does not support images. The image will be omitted from this request.]';
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

function fields(value, required, optional = []) {
  if (!record(value) || required.some(key => !own(value, key)) ||
      Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) {
    throw new TypeError('Invalid read content input');
  }
}

function decodeText(buffer, input) {
  if (input.decodeMode === 'utf8') return buffer.toString('utf8');
  const [first, second] = buffer;
  if ((first === 0xff && second === 0xfe) || (first === 0xfe && second === 0xff)) {
    return new TextDecoder(first === 0xff ? 'utf-16le' : 'utf-16be').decode(buffer);
  }
  if (process.platform !== 'win32') return buffer.toString('utf8');
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    // Actual Windows system-codepage resolution must be supplied by its trusted
    // host owner before model cutover. Never invent a locale/console fallback.
    if (!own(input, 'windowsEncoding')) throw new Error('Windows system encoding unresolved');
    if (input.windowsEncoding.trim().toLowerCase() === 'utf-8') return buffer.toString('utf8');
    try {
      return new TextDecoder(input.windowsEncoding).decode(buffer);
    } catch {
      return buffer.toString('utf8');
    }
  }
}

function sourceResult(content) {
  const text = content.find(part => part.type === 'text')?.text ?? '';
  const image = content.find(part => part.type === 'image');
  return {
    kind: 'result',
    result: {
      content,
      details: image ? { kind: 'image', content: text, mimeType: image.mimeType } : { kind: 'text', content: text },
    },
  };
}

// Input is an immutable byte snapshot, never a path or filename hint. This is
// source preparation only; TextRead retains normalization, budgets and paging.
export async function prepareReadContent(request) {
  fields(request, ['protocol', 'id', 'operation', 'input']);
  if (request.protocol !== 1 || typeof request.id !== 'string' || request.operation !== 'read_content') {
    throw new TypeError('Invalid read content request');
  }
  const input = request.input;
  fields(input, ['bytes', 'autoResizeImages', 'decodeMode'], ['modelHasVision', 'windowsEncoding']);
  if (typeof input.bytes !== 'string' || typeof input.autoResizeImages !== 'boolean' ||
      !['local', 'utf8'].includes(input.decodeMode) ||
      (own(input, 'modelHasVision') && typeof input.modelHasVision !== 'boolean') ||
      (own(input, 'windowsEncoding') && (typeof input.windowsEncoding !== 'string' || !input.windowsEncoding.trim()))) {
    throw new TypeError('Invalid read content input');
  }
  const buffer = Buffer.from(input.bytes, 'base64');
  if (buffer.toString('base64') !== input.bytes) throw new TypeError('Invalid read content bytes');
  const mimeType = detectSupportedImageMimeType(buffer);
  const attachment = mimeType ? undefined : await classifyAttachmentBytes({ buffer });
  let result;
  if (attachment?.class === 'document') {
    result = sourceResult([{ type: 'text', text: `Read did not return file contents because it detected a binary document [${attachment.mime ?? 'unknown'}]. Use an available document parser or converter, or convert the file to text, Markdown, or CSV, then read the converted file.` }]);
  } else if (mimeType) {
    const processed = await processImage({ data: Buffer.from(buffer), mimeType }, { autoResizeImages: input.autoResizeImages });
    const notes = processed.ok
      ? [`Read image file [${processed.image.mimeType}]`, ...processed.hints]
      : [`Read image file [${mimeType}]`, processed.message];
    if (input.modelHasVision === false) notes.push(VISION_NOTE);
    const content = [{ type: 'text', text: notes.join('\n') }];
    if (processed.ok && input.modelHasVision !== false) content.push(processed.image);
    result = sourceResult(content);
  } else {
    result = { kind: 'text', text: decodeText(buffer, input) };
  }
  return {
    protocol: 1,
    id: request.id,
    referenceCommit: REFERENCE_COMMIT,
    codecVersions: { rastermill: '0.4.0', photon: '0.3.4', fileType: '22.1.1' },
    runtime: {
      node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
      icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch,
    },
    result,
  };
}
