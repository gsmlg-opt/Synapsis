// Independent handwritten ordinary-success expectations for the unchanged pinned source.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureDeepInfraImageGeneration, DEEPINFRA_IMAGE_GENERATION_PIN } from './capture-deepinfra-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureDeepInfraImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const model = 'black-forest-labs/FLUX-1-schnell';
const prompt = ' Draw a small blue square. ';
const base = 'https://api.deepinfra.com/v1/openai';
const capability = {
  generate: { maxCount: 4, supportsSize: true, supportsAspectRatio: false, supportsResolution: false },
  edit: { enabled: true, maxCount: 1, maxInputImages: 1, supportsSize: true, supportsAspectRatio: false, supportsResolution: false },
  geometry: { sizes: ['512x512', '1024x1024', '1024x1792', '1792x1024'] },
};
const descriptor = { id: 'deepinfra', label: 'DeepInfra', defaultModel: model,
  models: [model, 'black-forest-labs/FLUX-1-dev', 'Qwen/Qwen-Image-Max', 'stabilityai/sdxl-turbo'], capabilities: capability };
const image = (bytesBase64 = png, mimeType = 'image/png', fileName = 'image-1.png', revisedPrompt) => ({
  mimeType, fileName, ...(revisedPrompt ? { revisedPrompt } : {}), bytesBase64,
});
const json = (overrides = {}) => ({ model, prompt, n: 1, size: '1024x1024', response_format: 'b64_json', ...overrides });
const file = (bytesBase64 = png, fileName = 'image-1.png', mimeType = 'image/png', size = 68) => ({
  name: 'image', fileName, mimeType, size, bytesBase64,
});
const multipart = (uploaded = file(), size = '1024x1024') => [
  { name: 'model', value: model }, { name: 'prompt', value: prompt }, { name: 'n', value: '1' },
  { name: 'size', value: size }, { name: 'response_format', value: 'b64_json' }, uploaded,
];
// Every plan is independently specified here; no expected wire field is calculated from captured inputs/results.
const plans = [
  ['default-count-size', json()],
  ['explicit-model-prompt', json({ model: 'Vendor/Image-X', prompt: '  Preserve this exact prompt.\n' })],
  ['deepinfra-prefixed-model', json({ model: 'black-forest-labs/FLUX-1-dev' })],
  ['count-four', json({ n: 4 })],
  ['size-512', json({ size: '512x512' })],
  ['size-1024', json()],
  ['size-portrait', json({ size: '1024x1792' })],
  ['size-landscape', json({ size: '1792x1024' })],
  ['size-trim', json({ size: '1024x1792' })],
  ['unused-options', json()],
  ['edit-defaults', multipart()],
  ['edit-explicit-size-count', multipart(file(), '512x512')],
  ['edit-explicit-mime-filename', multipart(file(jpeg, 'input.jpg', 'image/jpeg; mode=rgb', 10))],
  ['edit-unicode-path-name', multipart(file(png, '绘图/输入.png'))],
  ['edit-default-jpeg-filename', multipart(file(jpeg, 'image-1.jpg', 'image/jpeg', 10))],
  ['custom-base', json({ model: 'Custom/Model' }), 'https://images.example.test/custom/v2'],
  ['javascript-whitespace', json({ model: 'Vendor/Image-X', size: '512x512' }), 'https://images.example.test/js/v3'],
  ['ordered-inline-sniff-prompts', json({ n: 4 })],
  ['explicit-mime-wins', json()],
  ['base64-unpadded', json()],
  ['base64-whitespace', json()],
  ['four-ordered-downloads', json({ n: 4 })],
  ['edit-one-download', multipart()],
  ['json-bom-raw-chunks', json()],
  ['media-cap-floor', json()],
  ['media-cap-larger', json()],
  ['source-only-default-model-timeout', json()],
  ['source-only-configured-header', json()],
];
const expectedResults = new Map(plans.map(([id, body]) => [id, { images: [image()], model: Array.isArray(body) ? model : body.model }]));
expectedResults.set('ordered-inline-sniff-prompts', { model, images: [image(jpeg, 'image/jpeg', 'image-1.jpg', 'First'),
  image(png, 'image/png', 'image-2.png'), image(webp, 'image/webp', 'image-3.webp', 'Third'),
  image(opaque, 'image/jpeg', 'image-4.jpg', 'Fourth')] });
expectedResults.set('explicit-mime-wins', { model, images: [image(jpeg, 'Image/WEBP; codec=fixture', 'image-1.webp', 'Explicit')] });
expectedResults.set('four-ordered-downloads', { model, images: [image(jpeg, 'image/jpeg', 'image-1.jpg', 'Download 1'),
  image(webp, 'image/webp', 'image-2.webp', 'Download 2'), image(png, 'image/png', 'image-3.png', 'Download 3'),
  image(opaque, 'image/avif', 'image-4.avif', 'Download 4')] });
expectedResults.set('edit-one-download', { model, images: [image(jpeg, 'image/jpeg', 'image-1.jpg', 'Edited')] });

test('28 ordinary successful complete-source observations match every independent literal wire/result plan', () => {
  assert.deepEqual(capture.observations.map(row => row.id), plans.map(([id]) => id));
  for (const [id, body, origin = base] of plans) {
    const row = rows.get(id);
    const isMultipart = Array.isArray(body);
    assert.equal(row.request.url, origin + '/images/' + (isMultipart ? 'edits' : 'generations'), id);
    assert.equal(row.request.method, 'POST', id);
    assert.equal(row.request.kind, isMultipart ? 'multipart' : 'json', id);
    assert.deepEqual(row.request.body, body, id);
    assert.deepEqual(row.result, expectedResults.get(id), id);
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.releaseCount, 1, id);
    assert.equal(row.request.releaseCount, 1, id);
    assert.deepEqual(row.keyCalls, [{ provider: 'deepinfra' }], id);
    const headers = { authorization: 'Bearer synthetic-explicit-key',
      ...(!isMultipart ? { 'content-type': 'application/json' } : {}),
      ...(id === 'source-only-configured-header' ? { 'x-fixture-render': 'normal' } : {}) };
    assert.deepEqual(row.request.headers, headers, id);
    if (isMultipart) {
      assert.equal(Object.hasOwn(row.request, 'jsonBody'), false);
      assert.equal(row.request.multipartBoundary.rawHttpExecuted, false);
      assert.equal(row.request.body.filter(part => part.name === 'image').length, 1);
      assert.equal(row.request.body.some(part => part.name === 'images' || part.name === 'image[]'), false);
    } else assert.deepEqual(row.request.jsonBody, body, id);
  }
});

test('whole-source default, empty and supplied imageGenModels constructors preserve metadata exactly', () => {
  assert.deepEqual(capture.providerDescriptor, descriptor);
  assert.equal(Object.hasOwn(capture.providerDescriptor, 'defaultTimeoutMs'), false);
  assert.deepEqual(capture.constructorObservations.map(row => row.id), ['source-only-empty-catalog', 'source-only-custom-catalog']);
  assert.deepEqual(capture.constructorObservations[0].descriptor, descriptor);
  assert.deepEqual(capture.constructorObservations[1].descriptor, { ...descriptor, defaultModel: 'Vendor/First', models: ['Vendor/First', 'Other/Second'] });
  assert.ok(capture.constructorObservations.every(row => row.hostComparable === false && row.adaptationReason));
});

test('source multipart uses native Blob lowercasing, exact upload bytes, trimmed/default names and ordered fields', () => {
  for (const [id, fields] of plans.filter(([, body]) => Array.isArray(body))) {
    const row = rows.get(id);
    assert.deepEqual(row.request.body.map(part => part.name), ['model', 'prompt', 'n', 'size', 'response_format', 'image'], id);
    assert.deepEqual(row.request.body.at(-1), fields.at(-1), id);
    assert.equal(Object.hasOwn(row.request.headers, 'content-type'), false, id);
  }
  assert.equal(rows.get('edit-explicit-size-count').request.body[2].value, '1');
  assert.equal(rows.get('edit-explicit-mime-filename').input.inputImages[0].mimeType, ' Image/JPEG; mode=RGB ');
  assert.equal(rows.get('edit-explicit-mime-filename').request.body.at(-1).mimeType, 'image/jpeg; mode=rgb');
  assert.equal(rows.get('edit-unicode-path-name').request.body.at(-1).fileName, '绘图/输入.png');
});

test('real response helper sniffs JPEG/PNG/WebP, falls back to JPEG, preserves explicit MIME and full ordered images only', () => {
  assert.deepEqual(rows.get('ordered-inline-sniff-prompts').result, expectedResults.get('ordered-inline-sniff-prompts'));
  assert.deepEqual(rows.get('explicit-mime-wins').result, expectedResults.get('explicit-mime-wins'));
  for (const id of ['base64-unpadded', 'base64-whitespace', 'json-bom-raw-chunks']) {
    assert.deepEqual(rows.get(id).result, { images: [image()], model }, id);
  }
  const raw = rows.get('json-bom-raw-chunks').response.rawChunks;
  const bytes = Buffer.concat(raw.map(chunk => Buffer.from(chunk, 'base64')));
  assert.deepEqual([...bytes.subarray(0, 3)], [239, 187, 191]);
  assert.equal(bytes.subarray(3).toString(), '{"data":[{"b64_json":"' + png + '"}]}');
  assert.equal(raw.length, 4);
});

test('exact generate-four/edit-one successful sequential download plans retain bytes, MIME, filename and revised prompt', () => {
  const four = rows.get('four-ordered-downloads');
  assert.deepEqual(four.downloads.map(download => [download.url, download.contentType, download.bodyBase64]), [
    ['https://assets.example.test/image-1', 'Image/JPEG; mode=RGB', jpeg],
    ['https://assets.example.test/image-2', 'image/webp; charset=binary', webp],
    ['https://assets.example.test/image-3', 'image/png', png],
    ['https://assets.example.test/image-4', 'IMAGE/AVIF; codec=av1', opaque],
  ]);
  assert.deepEqual(rows.get('edit-one-download').downloads.map(download => [download.url, download.contentType, download.bodyBase64]), [
    ['https://assets.example.test/image-1', 'image/jpeg', jpeg],
  ]);
  for (const row of capture.observations) {
    const count = row.id === 'four-ordered-downloads' ? 4 : row.id === 'edit-one-download' ? 1 : 0;
    assert.equal(row.downloads.length, count, row.id);
    assert.equal(row.readerCalls.length, 1 + count, row.id);
    assert.ok(row.downloads.every(download => download.releaseCount === 1 && download.method === 'GET'), row.id);
  }
});

test('actual deadline and cap helpers use four generation assets or one edit asset and decrement successful service budgets', () => {
  for (const row of capture.observations) {
    const sourceDefaults = row.id === 'source-only-default-model-timeout';
    const total = sourceDefaults ? 60000 : 30000;
    const maxBytes = row.id === 'media-cap-larger' ? 449839104 : row.request.kind === 'multipart' ? 90527062 : 358962518;
    assert.equal(row.request.maxBytes, maxBytes, row.id);
    assert.deepEqual(row.readerCalls[0], { kind: 'json', label: 'deepinfra.image-generation', maxBytes,
      timeoutMs: total - 7, atMs: 100007 }, row.id);
    assert.equal(row.request.timeoutMs, sourceDefaults ? undefined : 30000, row.id);
    assert.equal(Object.hasOwn(row.request, 'timeoutMs'), !sourceDefaults, row.id);
    assert.equal(row.clock.endMs, 100010 + row.downloads.length * 24, row.id);
    assert.equal(row.statusCalls.length, 1 + row.downloads.length, row.id);
    assert.deepEqual(row.statusCalls[0], { label: row.request.kind === 'multipart' ? 'DeepInfra image edit failed' : 'DeepInfra image generation failed', timeoutMs: total - 7, atMs: 100007 }, row.id);
    row.downloads.forEach((download, index) => {
      assert.equal(download.atMs, 100010 + index * 24, row.id);
      assert.equal(download.timeoutMs, total - 10 - index * 24, row.id);
      assert.equal(download.maxBytes, 67108864, row.id);
      assert.deepEqual(row.readerCalls[index + 1], { kind: 'binary', label: 'DeepInfra image download', mediaKind: 'image', maxBytes: 67108864,
        timeoutMs: total - 21 - index * 24, atMs: 100021 + index * 24 }, row.id);
      assert.deepEqual(row.statusCalls[index + 1], { label: 'DeepInfra image download failed', timeoutMs: total - 21 - index * 24, atMs: 100021 + index * 24 }, row.id);
    });
  }
});

test('configured sanitizer/resolver are accurately source-only facades; ordinary rows require explicit host effective config', () => {
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 26);
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-default-model-timeout', 'source-only-configured-header',
  ]);
  for (const row of capture.observations) {
    assert.equal(row.sanitizeCalls.length, 1, row.id);
    assert.equal(row.configCalls.length, 1, row.id);
    assert.equal(row.sanitizeCalls[0].implementation, 'successful-configured-request-sanitizer-facade');
    assert.equal(row.configCalls[0].implementation, 'successful-provider-http-request-config-facade');
    assert.equal(row.configCalls[0].provider, 'deepinfra');
    assert.equal(row.configCalls[0].capability, 'image');
    assert.equal(row.configCalls[0].transport, 'http');
    if (row.id !== 'source-only-configured-header') assert.deepEqual(row.sanitizeCalls[0], {
      input: null, output: null, implementation: 'successful-configured-request-sanitizer-facade',
    });
  }
  assert.deepEqual(rows.get('source-only-configured-header').sanitizeCalls[0], {
    input: { headers: { 'X-Fixture-Render': ' normal ' } }, output: { headers: { 'X-Fixture-Render': 'normal' } },
    implementation: 'successful-configured-request-sanitizer-facade',
  });
  assert.deepEqual(rows.get('source-only-configured-header').configCalls[0].request, { headers: { 'X-Fixture-Render': 'normal' } });
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
  assert.equal(capture.serviceFacadeLedger.length, 6);
});

test('complete unchanged modules, exact regions, every binding and exporter/harness/runtime receipts reconstruct', () => {
  assert.equal(DEEPINFRA_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, DEEPINFRA_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/deepinfra/image-generation-provider.ts', 'extensions/deepinfra/media-models.ts',
    'src/image-generation/openai-compatible-image-provider.ts', 'src/image-generation/image-assets.ts',
    'src/image-generation/openai-compatible-image-urls.ts', 'src/plugin-sdk/blob-runtime.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(), [
    'src/media/configured-max-bytes.ts', 'src/media-understanding/shared.ts',
  ].sort());
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
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
    if (binding.origin) assert.equal(hash(readFileSync(join(root, binding.origin))), binding.originSha256);
  }
  const manifest = capture.importBindings.find(row => row.kind === 'original-json-data-export');
  assert.equal(manifest.source, 'extensions/deepinfra/openclaw.plugin.json');
  assert.equal(manifest.importer, 'extensions/deepinfra/media-models.ts');
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-deepinfra-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('all 58558 tracked blobs/modes/symlinks are verified before and after with precise stated boundaries', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['Complete unchanged DeepInfra', 'Two complete original source regions', 'modes and symlinks',
    'FormData and Blob', 'bounded stream reader', 'hostComparable=false', 'Inactive independent source oracle']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
});

test('two fresh captures equal the final frozen JSON including all source, runtime and service receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/deepinfra-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureDeepInfraImageGeneration(root), fixture);
});
