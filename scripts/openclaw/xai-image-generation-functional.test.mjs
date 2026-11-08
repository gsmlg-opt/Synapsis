// Hand-written pinned-source contracts under ordinary successful synthetic services.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureXaiImageGeneration, XAI_IMAGE_GENERATION_PIN } from './capture-xai-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureXaiImageGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const ratios = ['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3', '2:1', '1:2', '19.5:9', '9:19.5', '20:9', '9:20'];
const ids = ['default-count', 'explicit-model-prompt', 'count-four', 'count-seven-clamped',
  'aspect-1-1', 'aspect-16-9', 'aspect-9-16', 'aspect-4-3', 'aspect-3-4', 'aspect-3-2', 'aspect-2-3',
  'aspect-2-1', 'aspect-1-2', 'aspect-19.5-9', 'aspect-9-19.5', 'aspect-20-9', 'aspect-9-20',
  'unsupported-aspect-omitted', 'resolution-1k', 'resolution-2k', 'resolution-custom', 'unused-options',
  'edit-url', 'edit-bytes-default-mime', 'edit-bytes-explicit-mime', 'edit-url-preferred', 'edit-three-ordered',
  'custom-base', 'javascript-whitespace', 'ordered-inline-mime-prompts', 'base64-unpadded', 'base64-whitespace',
  'jpeg-default-png-no-sniff', 'opaque-default-png', 'six-inline-preserved', 'four-ordered-downloads',
  'mixed-inline-downloads', 'inline-preferred-over-url', 'media-cap-floor', 'media-cap-larger',
  'source-only-default-model-timeout'];
const body = id => rows.get(id).request.body;

test('41 ordered complete-source success vectors preserve input and release all observed response handles', () => {
  assert.deepEqual(capture.observations.map(row => row.id), ids);
  for (const row of capture.observations) {
    assert.deepEqual(row.inputAfter, row.input, row.id);
    assert.equal(row.request.method, 'POST', row.id);
    assert.deepEqual(row.request.jsonBody, row.request.body, row.id);
    assert.equal(row.releaseCount, 1, row.id);
    assert.equal(row.request.releaseCount, 1, row.id);
    assert.equal(row.request.body.prompt, row.input.prompt, row.id);
    assert.equal(row.request.body.response_format, 'b64_json', row.id);
    assert.equal(row.request.body.n, Math.min(row.input.count ?? 1, 4), row.id);
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], row.id);
    assert.equal(row.result.model, row.request.body.model, row.id);
    assert.equal(row.readerCalls.length, 1 + row.downloads.length, row.id);
    assert.ok(row.downloads.every(download => download.releaseCount === 1), row.id);
    assert.equal(row.request.timeoutMs, row.hostComparable ? 30000 : 600000, row.id);
  }
});

test('metadata comes from complete original image region and original model constants/manifest', () => {
  assert.deepEqual(capture.providerDescriptor, { id: 'xai', label: 'xAI', defaultModel: 'grok-imagine-image',
    defaultTimeoutMs: 600000, models: ['grok-imagine-image', 'grok-imagine-image-2.0', 'grok-imagine-image-quality'],
    capabilities: { generate: { maxCount: 4, supportsAspectRatio: true, supportsResolution: true, supportsSize: false },
      edit: { enabled: true, maxCount: 4, maxInputImages: 3, supportsAspectRatio: true, supportsResolution: true, supportsSize: false },
      geometry: { aspectRatios: ratios, resolutions: ['1K', '2K'] } } });
  assert.deepEqual(body('default-count'), { model: 'grok-imagine-image', prompt: ' Draw a small blue square. ', n: 1, response_format: 'b64_json' });
  assert.equal(body('count-four').n, 4);
  assert.equal(body('count-seven-clamped').n, 4);
  assert.equal(body('explicit-model-prompt').model, 'Vendor/Image-X');
  assert.equal(body('explicit-model-prompt').prompt, '  Preserve this exact prompt.\n');
});

test('all thirteen advertised aspects forward while ordinary unadvertised aspect is omitted successfully', () => {
  for (const ratio of ratios) assert.equal(body('aspect-' + ratio.replaceAll(':', '-')).aspect_ratio, ratio);
  assert.deepEqual(body('unsupported-aspect-omitted'), body('default-count'));
  assert.equal(rows.get('unsupported-aspect-omitted').result.images.length, 1);
});

test('resolution is trimmed/lowercased and unused generic/provider fields do not enter the JSON body', () => {
  assert.equal(body('resolution-1k').resolution, '1k');
  assert.equal(body('resolution-2k').resolution, '2k');
  assert.equal(body('resolution-custom').resolution, 'ultra-hd');
  assert.deepEqual(body('unused-options'), body('default-count'));
  assert.deepEqual(Object.keys(body('default-count')), ['model', 'prompt', 'n', 'response_format']);
});

test('ordered one/three-image edits prefer URLs, preserve original bytes and trim only source MIME strings', () => {
  assert.deepEqual(body('edit-url').image, { url: 'https://assets.example.test/input-one', type: 'image_url' });
  const raw = rows.get('edit-bytes-default-mime').input.inputImages[0].bytesBase64;
  assert.deepEqual(body('edit-bytes-default-mime').image, { url: `data:image/png;base64,${raw}`, type: 'image_url' });
  const jpeg = rows.get('edit-bytes-explicit-mime').input.inputImages[0].bytesBase64;
  assert.deepEqual(body('edit-bytes-explicit-mime').image, { url: `data:Image/JPEG; mode=RGB;base64,${jpeg}`, type: 'image_url' });
  assert.deepEqual(body('edit-url-preferred').image, { url: 'https://assets.example.test/preferred', type: 'image_url' });
  const many = rows.get('edit-three-ordered');
  assert.deepEqual(many.request.body.images, [{ url: 'https://assets.example.test/one', type: 'image_url' },
    { url: `data:image/jpeg;base64,${many.input.inputImages[1].bytesBase64}`, type: 'image_url' },
    { url: `data:image/png;base64,${many.input.inputImages[2].bytesBase64}`, type: 'image_url' }]);
  for (const row of capture.observations) {
    if (row.id === 'custom-base' || row.id === 'javascript-whitespace') continue;
    assert.equal(row.request.url, 'https://api.x.ai/v1/images/' + (row.input.inputImages ? 'edits' : 'generations'), row.id);
  }
});

test('custom prefix/trailing slashes and ECMAScript whitespace preserve selected model and exact endpoint', () => {
  assert.equal(rows.get('custom-base').request.url, 'https://images.example.test/custom/v2/images/generations');
  assert.equal(body('custom-base').model, 'Custom/Model');
  assert.equal(rows.get('javascript-whitespace').request.url, 'https://images.example.test/js/v3/images/generations');
  assert.deepEqual(body('javascript-whitespace'), { model: 'Vendor/Image-X', prompt: ' Draw a small blue square. ',
    n: 1, response_format: 'b64_json', aspect_ratio: '16:9', resolution: '2k' });
});

test('canonical/unpadded/whitespace Base64 and exact inline MIME/prompt projection use real asset parser without sniffing', () => {
  const original = rows.get('default-count').result.images[0].bytesBase64;
  assert.equal(rows.get('base64-unpadded').result.images[0].bytesBase64, original);
  assert.equal(rows.get('base64-whitespace').result.images[0].bytesBase64, original);
  const inline = rows.get('ordered-inline-mime-prompts');
  assert.deepEqual(inline.result.images.map(image => [image.mimeType, image.fileName, image.revisedPrompt]), [
    ['image/png', 'image-1.png', 'First'], ['Image/JPEG; mode=RGB', 'image-2.jpg', undefined], ['image/webp', 'image-3.webp', 'Third'] ]);
  for (const id of ['jpeg-default-png-no-sniff', 'opaque-default-png']) {
    const row = rows.get(id);
    assert.deepEqual(row.result.images[0], { mimeType: 'image/png', fileName: 'image-1.png', bytesBase64: row.response.json.data[0].b64_json });
  }
  assert.equal(rows.get('six-inline-preserved').result.images.length, 6);
  assert.deepEqual(rows.get('six-inline-preserved').result.images.map(image => image.revisedPrompt), ['Item 1', 'Item 2', 'Item 3', 'Item 4', 'Item 5', 'Item 6']);
});

test('four sequential URL downloads and mixed inline/URL retain order, normalized download MIME and Base64 precedence', () => {
  const row = rows.get('four-ordered-downloads');
  assert.deepEqual(row.downloads.map(download => download.url), [1, 2, 3, 4].map(index => `https://assets.example.test/image-${index}`));
  assert.deepEqual(row.result.images.map(image => [image.mimeType, image.fileName, image.revisedPrompt]), [
    ['image/jpeg', 'image-1.jpg', 'Download 1'], ['image/webp', 'image-2.webp', 'Download 2'],
    ['image/png', 'image-3.png', 'Download 3'], ['image/avif', 'image-4.avif', 'Download 4'] ]);
  assert.deepEqual(row.result.images.map(image => image.bytesBase64), row.downloads.map(download => download.bodyBase64));
  const mixed = rows.get('mixed-inline-downloads');
  assert.deepEqual(mixed.result.images.map(image => image.bytesBase64), [mixed.response.json.data[0].b64_json,
    mixed.downloads[0].bodyBase64, mixed.response.json.data[2].b64_json, mixed.downloads[1].bodyBase64]);
  assert.deepEqual(mixed.result.images.map(image => image.mimeType), ['image/png', 'image/webp', 'image/jpeg', 'image/png']);
  assert.equal(rows.get('inline-preferred-over-url').downloads.length, 0);
  assert.equal(rows.get('inline-preferred-over-url').result.images[0].bytesBase64, rows.get('default-count').result.images[0].bytesBase64);
});

test('metadata maxCount four controls raw cap independently of n and configured cap retains the 64MiB floor', () => {
  for (const row of capture.observations) {
    const maxBytes = row.id === 'media-cap-larger' ? 84148224 : 67108864;
    assert.equal(row.request.maxBytes, row.id === 'media-cap-larger' ? 449839104 : 358962518, row.id);
    assert.equal(row.readerCalls[0].maxBytes, row.request.maxBytes, row.id);
    for (const download of row.downloads) assert.equal(download.maxBytes, maxBytes, row.id);
  }
  assert.equal(rows.get('default-count').request.body.n, 1);
  assert.equal(rows.get('media-cap-floor').request.maxBytes, 358962518);
});

test('actual source deadline helpers carry one decreasing total budget across all successful service reads', () => {
  for (const row of capture.observations) {
    const total = row.request.timeoutMs;
    assert.deepEqual(row.readerCalls[0], { kind: 'json', label: 'xai.image-generation', maxBytes: row.request.maxBytes,
      timeoutMs: total - 7, atMs: 100007 }, row.id);
    row.downloads.forEach((download, index) => {
      assert.equal(download.method, 'GET');
      assert.equal(download.atMs, 100010 + index * 24);
      assert.equal(download.timeoutMs, total - 10 - index * 24);
      assert.equal(row.readerCalls[index + 1].timeoutMs, total - 21 - index * 24);
    });
    assert.equal(row.clock.endMs, 100010 + row.downloads.length * 24, row.id);
  }
  const defaults = rows.get('source-only-default-model-timeout');
  assert.equal(defaults.hostComparable, false);
  assert.equal(defaults.result.model, 'grok-imagine-image');
  assert.equal(defaults.request.timeoutMs, 600000);
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 40);
});

test('whole modules and complete source regions reconstruct original/generated/executable hashes and declared import boundaries', () => {
  assert.equal(capture.referencePin, XAI_IMAGE_GENERATION_PIN);
  assert.equal(XAI_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.equal(executed.filter(row => row.wholeModule).length, 9);
  assert.equal(executed.filter(row => !row.wholeModule).length, 4);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) continue;
    let original = bytes.toString();
    if (!row.wholeModule) {
      const p = row.projection; const selected = bytes.subarray(p.startByte, p.endByte);
      assert.equal(hash(selected), p.sourceRegionSha256, row.path);
      original = p.prelude + '\n' + selected.toString();
      assert.equal(original, p.generatedCode, row.path);
      assert.equal(hash(original), p.generatedSha256, row.path);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const source of ['extensions/xai/image-generation-provider.ts', 'src/image-generation/openai-compatible-image-provider.ts',
    'src/image-generation/image-assets.ts', 'src/image-generation/openai-compatible-image-urls.ts']) {
    assert.ok(executed.some(row => row.path === source && row.wholeModule), source);
  }
  const provider = readFileSync(join(root, 'extensions/xai/image-generation-provider.ts'), 'utf8');
  assert.equal(provider.trimEnd().split('\n').length, 83);
  const regions = new Map(executed.filter(row => !row.wholeModule).map(row => [row.path, row.projection.generatedCode]));
  assert.match(regions.get('extensions/xai/capability-provider-metadata-factory.ts'), /export function createXaiImageGenerationProviderMetadata\(\)/);
  assert.match(regions.get('src/media/configured-max-bytes.ts'), /export function resolveGeneratedImageDownloadMaxBytes\(/);
  assert.match(regions.get('src/media-understanding/shared.ts'), /export function createProviderOperationDeadline\(/);
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
    if (binding.origin) assert.equal(hash(readFileSync(join(root, binding.origin))), binding.originSha256);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-xai-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('tracked source tree before/after and synthetic service limits remain explicit', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['83-line', 'four complete original source regions', 'modes and symlinks', 'bounded stream reader', 'hostComparable=false', 'Inactive independent source oracle']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
  assert.ok(capture.importBindings.some(binding => binding.kind === 'successful-native-download-fixture'));
  assert.ok(capture.importBindings.some(binding => binding.kind === 'original-json-data-export'));
});

test('two fresh complete-source captures exactly reproduce every frozen field', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/xai-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureXaiImageGeneration(root), fixture);
});
