// Independent handwritten ordinary-success expectations for unchanged pinned source.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isIP } from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { captureLitellmImageGeneration, LITELLM_IMAGE_GENERATION_PIN } from './capture-litellm-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureLitellmImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const model = 'gpt-image-2';
const prompt = ' Draw a small blue square. ';
const base = 'https://proxy.example.test/v1';
const descriptor = { id: 'litellm', label: 'LiteLLM', defaultModel: model, models: [model], capabilities: {
  generate: { maxCount: 4, supportsSize: true, supportsAspectRatio: false, supportsResolution: false },
  edit: { enabled: true, maxCount: 4, maxInputImages: 5, supportsSize: true, supportsAspectRatio: false, supportsResolution: false },
  geometry: { sizes: ['256x256', '512x512', '1024x1024', '1024x1536', '1024x1792', '1536x1024',
    '1792x1024', '2048x2048', '2048x1152', '3840x2160', '2160x3840'] },
} };
const image = (bytesBase64 = png, mimeType = 'image/png', fileName = 'image-1.png', revisedPrompt) => ({
  mimeType, fileName, ...(revisedPrompt ? { revisedPrompt } : {}), bytesBase64,
});
const json = (overrides = {}) => ({ model, prompt, n: 1, size: '1024x1024', ...overrides });
const file = (bytesBase64 = png, fileName = 'image-1.png', mimeType = 'image/png', size = 68, name = 'image') => ({
  name, fileName, mimeType, size, bytesBase64,
});
const multipart = (uploaded = [file()], size = '1024x1024', count = '1') => [
  { name: 'model', value: model }, { name: 'prompt', value: prompt }, { name: 'n', value: count },
  { name: 'size', value: size }, ...uploaded,
];
// No expected wire field is calculated from captured inputs, observed request fields or source outputs.
const plans = [
  ['default-count-size', json()],
  ['explicit-model-prompt', json({ model: 'Vendor/Image-X', prompt: '  Preserve this exact prompt.\n' })],
  ['litellm-prefixed-model', json({ model: 'litellm/Vendor/Image-X' })],
  ['count-four', json({ n: 4 })],
  ['size-256', json({ size: '256x256' })],
  ['size-512', json({ size: '512x512' })],
  ['size-1024', json()],
  ['size-1024x1536', json({ size: '1024x1536' })],
  ['size-portrait', json({ size: '1024x1792' })],
  ['size-1536x1024', json({ size: '1536x1024' })],
  ['size-landscape', json({ size: '1792x1024' })],
  ['size-2048', json({ size: '2048x2048' })],
  ['size-2048x1152', json({ size: '2048x1152' })],
  ['size-3840x2160', json({ size: '3840x2160' })],
  ['size-2160x3840', json({ size: '2160x3840' })],
  ['size-untrimmed', json({ size: ' 1024x1792 ' })],
  ['unused-options', json()],
  ['edit-defaults', multipart()],
  ['edit-count-four', multipart([file()], ' 512x512 ', '4')],
  ['edit-five-ordered', multipart([
    file(png, 'image-1.png', 'image/png', 68, 'image[]'),
    file(jpeg, 'image-2.jpg', 'image/jpeg', 10, 'image[]'),
    file(webp, 'image-3.webp', 'image/webp', 12, 'image[]'),
    file(opaque, 'fourth.png', 'image/png', 27, 'image[]'),
    file(png, 'fifth.png', 'image/png', 68, 'image[]'),
  ], '1024x1024', '4')],
  ['edit-explicit-mime-filename', multipart([file(jpeg, 'input.jpg', 'image/jpeg; mode=rgb', 10)])],
  ['edit-unicode-path-name', multipart([file(png, '绘图/输入.png')])],
  ['edit-default-jpeg-filename', multipart([file(jpeg, 'image-1.jpg', 'image/jpeg', 10)])],
  ['custom-base', json({ model: 'litellm/Custom/Model' }), 'https://images.example.test/custom/v2'],
  ['javascript-whitespace', json({ model: 'litellm/Vendor/Image-X', size: '\uFEFF512x512\u00a0' }), 'https://images.example.test/js/v3'],
  ['ordered-inline-default-png', json({ n: 4 })],
  ['explicit-mime-wins', json()],
  ['base64-unpadded', json()],
  ['base64-whitespace', json()],
  ['four-ordered-downloads', json({ n: 4 })],
  ['edit-four-ordered-downloads', multipart([file()], '1024x1024', '4')],
  ['json-bom-raw-chunks', json()],
  ['media-cap-floor', json()],
  ['media-cap-larger', json()],
  ['source-only-default-model-timeout', json()],
  ['source-only-configured-header', json()],
];
const expectedResults = new Map(plans.map(([id, body]) => [id, { images: [image()], model: Array.isArray(body) ? model : body.model }]));
expectedResults.set('ordered-inline-default-png', { model, images: [image(jpeg, 'image/png', 'image-1.png', 'First'),
  image(png, 'image/png', 'image-2.png'), image(webp, 'image/png', 'image-3.png', 'Third'),
  image(opaque, 'image/png', 'image-4.png', 'Fourth')] });
expectedResults.set('explicit-mime-wins', { model, images: [image(jpeg, 'Image/WEBP; codec=fixture', 'image-1.webp', 'Explicit')] });
for (const id of ['four-ordered-downloads', 'edit-four-ordered-downloads']) expectedResults.set(id, { model, images: [
  image(jpeg, 'image/jpeg', 'image-1.jpg', 'Download 1'), image(webp, 'image/webp', 'image-2.webp', 'Download 2'),
  image(png, 'image/png', 'image-3.png', 'Download 3'), image(opaque, 'image/avif', 'image-4.avif', 'Download 4'),
] });

test('36 ordinary successful complete-source observations match independent complete literal wire/result plans', () => {
  assert.deepEqual(capture.observations.map(row => row.id), plans.map(([id]) => id));
  assert.equal(plans.length, 36);
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
    assert.equal(row.request.atMs, 100000, id);
    assert.equal(row.request.releasedAtMs, row.clock.endMs, id);
    assert.deepEqual(row.keyCalls, [{ provider: 'litellm' }], id);
    const headers = { authorization: 'Bearer synthetic-explicit-key',
      ...(!isMultipart ? { 'content-type': 'application/json' } : {}),
      ...(id === 'source-only-configured-header' ? { 'x-fixture-render': 'normal' } : {}) };
    assert.deepEqual(row.request.headers, headers, id);
    if (isMultipart) {
      assert.equal(Object.hasOwn(row.request, 'jsonBody'), false);
      assert.deepEqual(row.request.multipartBoundary, { rawHttpExecuted: false,
        format: 'ordered native FormData fields and exact Blob bytes/name/type; no generated HTTP boundary compared' });
    } else assert.deepEqual(row.request.jsonBody, body, id);
  }
});

test('unchanged source descriptor advertises all eleven sizes and generate-four/edit-four/five-reference metadata', () => {
  assert.deepEqual(capture.providerDescriptor, descriptor);
  assert.equal(Object.hasOwn(capture.providerDescriptor, 'defaultTimeoutMs'), false);
  assert.deepEqual(plans.slice(4, 15).map(([, body]) => body.size), descriptor.capabilities.geometry.sizes);
});

test('native multipart retains four edit outputs and exact singular or five ordered repeated image parts', () => {
  for (const [id, fields] of plans.filter(([, body]) => Array.isArray(body))) {
    const row = rows.get(id);
    assert.deepEqual(row.request.body.map(part => part.name), id === 'edit-five-ordered'
      ? ['model', 'prompt', 'n', 'size', 'image[]', 'image[]', 'image[]', 'image[]', 'image[]']
      : ['model', 'prompt', 'n', 'size', 'image'], id);
    assert.deepEqual(row.request.body, fields, id);
    assert.equal(Object.hasOwn(row.request.headers, 'content-type'), false, id);
  }
  assert.equal(rows.get('edit-count-four').request.body[2].value, '4');
  assert.equal(rows.get('edit-count-four').request.body[3].value, ' 512x512 ');
  assert.equal(rows.get('edit-explicit-mime-filename').input.inputImages[0].mimeType, ' Image/JPEG; mode=RGB ');
  assert.equal(rows.get('edit-explicit-mime-filename').request.body.at(-1).mimeType, 'image/jpeg; mode=rgb');
  assert.equal(rows.get('edit-unicode-path-name').request.body.at(-1).fileName, '绘图/输入.png');
});

test('model trim preserves prefixes and supplied size bytes; response defaults PNG without sniffing and explicit MIME wins', () => {
  assert.deepEqual(rows.get('litellm-prefixed-model').request.body, json({ model: 'litellm/Vendor/Image-X' }));
  assert.deepEqual(rows.get('javascript-whitespace').request.body, json({ model: 'litellm/Vendor/Image-X', size: '\uFEFF512x512\u00a0' }));
  assert.deepEqual(rows.get('size-untrimmed').request.body, json({ size: ' 1024x1792 ' }));
  assert.deepEqual(rows.get('ordered-inline-default-png').result, expectedResults.get('ordered-inline-default-png'));
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

test('both generation and edit perform four successful sequential GETs preserving ordered bytes/MIME/names/prompts', () => {
  for (const id of ['four-ordered-downloads', 'edit-four-ordered-downloads']) {
    assert.deepEqual(rows.get(id).downloads.map(download => [download.url, download.contentType, download.bodyBase64]), [
      ['https://assets.example.test/image-1', 'Image/JPEG; mode=RGB', jpeg],
      ['https://assets.example.test/image-2', 'image/webp; charset=binary', webp],
      ['https://assets.example.test/image-3', 'image/png', png],
      ['https://assets.example.test/image-4', 'IMAGE/AVIF; codec=av1', opaque],
    ]);
    assert.deepEqual(rows.get(id).result, expectedResults.get(id));
  }
  for (const row of capture.observations) {
    const count = ['four-ordered-downloads', 'edit-four-ordered-downloads'].includes(row.id) ? 4 : 0;
    assert.equal(row.downloads.length, count, row.id);
    assert.equal(row.readerCalls.length, 1 + count, row.id);
    assert.ok(row.downloads.every(download => download.releaseCount === 1 && download.method === 'GET'), row.id);
  }
});

test('actual deadline/cap helpers use source cap four in both modes and decrement ordinary successful service budgets', () => {
  for (const row of capture.observations) {
    const sourceDefaults = row.id === 'source-only-default-model-timeout';
    const total = sourceDefaults ? 60000 : 30000;
    const maxBytes = row.id === 'media-cap-larger' ? 449839104 : 358962518;
    assert.equal(row.request.maxBytes, maxBytes, row.id);
    assert.deepEqual(row.readerCalls[0], { kind: 'json', label: 'litellm.image-generation', maxBytes,
      timeoutMs: total - 7, atMs: 100007 }, row.id);
    assert.equal(row.request.timeoutMs, sourceDefaults ? undefined : 30000, row.id);
    assert.equal(Object.hasOwn(row.request, 'timeoutMs'), !sourceDefaults, row.id);
    assert.deepEqual(row.clock, { kind: 'synthetic-Date.now', startMs: 100000, endMs: 100010 + row.downloads.length * 24,
      serviceCostsMs: { post: 7, jsonRead: 3, download: 11, binaryRead: 13 } }, row.id);
    assert.equal(row.statusCalls.length, 1 + row.downloads.length, row.id);
    assert.deepEqual(row.statusCalls[0], { label: row.request.kind === 'multipart' ? 'LiteLLM image edit failed' : 'LiteLLM image generation failed',
      timeoutMs: total - 7, atMs: 100007 }, row.id);
    row.downloads.forEach((download, index) => {
      assert.equal(download.atMs, 100010 + index * 24, row.id);
      assert.equal(download.timeoutMs, total - 10 - index * 24, row.id);
      assert.equal(download.maxBytes, 67108864, row.id);
      assert.equal(download.releasedAtMs, 100034 + index * 24, row.id);
      assert.deepEqual(row.readerCalls[index + 1], { kind: 'binary', label: 'LiteLLM image download', mediaKind: 'image', maxBytes: 67108864,
        timeoutMs: total - 21 - index * 24, atMs: 100021 + index * 24 }, row.id);
      assert.deepEqual(row.statusCalls[index + 1], { label: 'LiteLLM image download failed', timeoutMs: total - 21 - index * 24,
        atMs: 100021 + index * 24 }, row.id);
    });
  }
});

test('literal configured-header consumption and omitted model/timeout are accurately source-only successful facades', () => {
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 34);
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-default-model-timeout', 'source-only-configured-header',
  ]);
  for (const row of capture.observations) {
    assert.equal(row.sanitizeCalls.length, 1, row.id);
    assert.equal(row.configCalls.length, 1, row.id);
    assert.equal(row.sanitizeCalls[0].implementation, 'successful-configured-request-sanitizer-facade');
    assert.equal(row.configCalls[0].implementation, 'successful-provider-http-request-config-facade');
    assert.equal(row.configCalls[0].provider, 'litellm');
    assert.equal(row.configCalls[0].capability, 'image');
    assert.equal(row.configCalls[0].transport, 'http');
    const publicBase = row.id === 'custom-base' ? 'https://images.example.test/custom/v2///'
      : row.id === 'javascript-whitespace' ? 'https://images.example.test/js/v3///' : base;
    assert.equal(row.configCalls[0].baseUrl, publicBase, row.id);
    assert.deepEqual(row.configCalls[0].output, { baseUrl: publicBase, headers: {
      authorization: 'Bearer synthetic-explicit-key',
      ...(row.id === 'source-only-configured-header' ? { 'x-fixture-render': 'normal' } : {}),
    } }, row.id);
    if (row.id !== 'source-only-configured-header') {
      assert.deepEqual(row.sanitizeCalls[0], { input: null, output: null,
        implementation: 'successful-configured-request-sanitizer-facade' });
      assert.equal(row.configCalls[0].request, null);
    }
  }
  assert.deepEqual(rows.get('source-only-configured-header').sanitizeCalls[0], {
    input: { headers: { 'X-Fixture-Render': ' normal ' } }, output: { headers: { 'X-Fixture-Render': 'normal' } },
    implementation: 'successful-configured-request-sanitizer-facade',
  });
  assert.deepEqual(rows.get('source-only-configured-header').configCalls[0].request, { headers: { 'X-Fixture-Render': 'normal' } });
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
  assert.equal(capture.serviceFacadeLedger.length, 6);
});

test('complete unchanged modules, exact source regions and every source/executable/import/exporter/harness/runtime receipt reconstruct', () => {
  assert.equal(LITELLM_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, LITELLM_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/litellm/image-generation-provider.ts', 'src/image-generation/openai-compatible-image-provider.ts',
    'src/image-generation/image-assets.ts', 'src/image-generation/openai-compatible-image-urls.ts', 'src/plugin-sdk/blob-runtime.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(), [
    'extensions/litellm/onboard.ts', 'src/media/configured-max-bytes.ts', 'src/media-understanding/shared.ts',
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
  const native = capture.importBindings.find(row => row.kind === 'native-node-platform-binding');
  assert.equal(native.importer, 'extensions/litellm/image-generation-provider.ts');
  assert.equal(native.specifier, 'node:net');
  assert.deepEqual(native.exports, ['isIP']);
  assert.equal(native.nativeModule, 'node:net');
  assert.equal(native.nativeExport, 'isIP');
  assert.equal(native.functionSha256, hash(isIP.toString()));
  assert.equal(native.runtimeSha256, capture.runtime.sha256);
  const onboard = capture.sourceRecords.find(row => row.path === 'extensions/litellm/onboard.ts');
  const source = readFileSync(join(root, onboard.path));
  assert.equal(onboard.projection.prelude, '');
  assert.equal(onboard.projection.startByte, source.indexOf('export const LITELLM_BASE_URL ='));
  assert.equal(onboard.projection.endByte, source.indexOf('export const LITELLM_DEFAULT_MODEL_ID ='));
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-litellm-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('all 58558 tracked blobs/modes/symlinks are verified pre/post and limits distinguish source execution from facades', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['Complete unchanged LiteLLM', 'Three complete original source regions', 'modes and symlinks',
    'FormData and Blob', 'bounded stream reader', 'hostComparable=false', 'Host policy', 'Inactive independent source oracle']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
});

test('two fresh captures equal final frozen JSON including all source/runtime/service receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/litellm-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureLitellmImageGeneration(root), fixture);
});
