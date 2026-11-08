// Literal assertions against independent pinned source executions; ordinary success only.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureGoogleImageGeneration } from './capture-google-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureGoogleImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const names = ['source-only-defaults', 'explicit-default', 'custom-model',
  'alias-gemini-3-pro', 'alias-gemini-3-pro-preview', 'alias-gemini-3-flash', 'alias-gemini-3.1-pro',
  'alias-gemini-3.1-flash-lite-preview', 'alias-gemini-3.1-flash', 'alias-gemini-3.1-flash-preview',
  'alias-gemini-4', 'alias-gemma-4-26b', 'alias-prefixed',
  'size-1024x1024', 'size-1024x1536', 'size-1536x1024', 'size-1024x1792', 'size-1792x1024',
  'size-unmapped-small', 'size-tier-2k', 'size-tier-4k', 'size-js-whitespace',
  'geometry-overrides-1k', 'geometry-overrides-2k', 'geometry-overrides-4k', 'blank-aspect',
  'edit-one', 'edit-five', 'count-one', 'count-four', 'ignored-controls', 'ordered-candidates',
  'mime-precedence', 'base64-variants', 'more-than-four', 'larger-media-cap', 'official-root-normalization', 'official-uppercase-host'];
const imageConfig = id => rows.get(id).request.body.generationConfig.imageConfig;
const output = id => rows.get(id).result.images;
const model = id => rows.get(id).result.model;

// These values are hand-written expectations from the source contract, not host output.
test('38 whole-provider success vectors preserve inputs and explicit source-default adaptation', () => {
  assert.deepEqual(capture.observations.map(row => row.id), names);
  assert.deepEqual(capture.vectorIds, names);
  assert.deepEqual(capture.hostComparableIds, names.slice(1));
  for (const row of capture.observations) {
    assert.deepEqual(row.inputAfter, row.input, row.id);
    assert.equal(row.request.method, 'POST', row.id);
    assert.equal(row.request.timeoutMs, row.id === 'source-only-defaults' ? 180000 : 12345, row.id);
    assert.equal(row.releaseCount, 1, row.id);
    assert.deepEqual(row.readerCalls, [{ kind: 'json', label: 'google.image-generation',
      maxBytes: row.id === 'larger-media-cap' ? 449839104 : 358962518 }], row.id);
    assert.deepEqual(row.request.headers, { 'x-goog-api-key': 'fixture-google-images', 'Content-Type': 'application/json' }, row.id);
    assert.deepEqual(Object.keys(row.result).sort(), ['images', 'model'], row.id);
    assert.deepEqual(row.request.body.generationConfig.responseModalities, ['TEXT', 'IMAGE'], row.id);
    assert.equal(row.request.body.contents.length, 1, row.id);
    assert.equal(row.request.body.contents[0].role, 'user', row.id);
    assert.deepEqual(row.request.body.contents[0].parts.at(-1), { text: ' Draw a small blue square. ' }, row.id);
    assert.equal(row.request.url, `https://generativelanguage.googleapis.com/v1beta/models/${row.result.model}:generateContent`, row.id);
    assert.deepEqual(row.facadeCalls.map(call => call.kind), ['explicit-key', 'request-sanitizer', 'attribution', 'request-config', 'successful-status'], row.id);
    assert.equal(row.facadeCalls[0].input.provider, 'google', row.id);
    assert.equal(row.facadeCalls[0].input.cfg.models.providers.google.baseUrl, row.config.baseUrl, row.id);
    assert.deepEqual(row.facadeCalls[1], { kind: 'request-sanitizer', input: null, output: null }, row.id);
    assert.deepEqual(row.facadeCalls[2].output, {}, row.id);
  }
  const defaults = rows.get('source-only-defaults');
  assert.equal(Object.hasOwn(defaults.input, 'model'), false);
  assert.equal(Object.hasOwn(defaults.input, 'timeoutMs'), false);
  assert.equal(defaults.result.model, 'gemini-3.1-flash-image');
  assert.equal(defaults.hostComparable, false);
  assert.match(defaults.adaptationReason, /host requires explicit model and finite timeout/);
});

test('metadata is actual source declaration and does not truncate direct response images', () => {
  assert.deepEqual(capture.metadata, {
    id: 'google', label: 'Google', defaultModel: 'gemini-3.1-flash-image',
    models: ['gemini-3.1-flash-image', 'gemini-3-pro-image'],
    capabilities: {
      generate: { maxCount: 4, supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
      edit: { enabled: true, maxCount: 4, maxInputImages: 5, supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
      geometry: { sizes: ['1024x1024', '1024x1536', '1536x1024', '1024x1792', '1792x1024'],
        aspectRatios: ['1:1', '2:3', '3:2', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '21:9'], resolutions: ['1K', '2K', '4K'] },
    },
  });
  assert.equal(output('more-than-four').length, 6);
  assert.equal(rows.get('more-than-four').input.count, 1);
  assert.deepEqual(output('more-than-four').map(image => image.bytesBase64), ['AQ==', 'Ag==', 'Aw==', 'BA==', 'BQ==', 'Bg==']);
  assert.deepEqual(output('more-than-four').map(image => image.fileName), ['image-1.png', 'image-2.png', 'image-3.png', 'image-4.png', 'image-5.png', 'image-6.png']);
});

test('prompt-only exact body omits imageConfig and all unrequested fields', () => {
  assert.deepEqual(rows.get('explicit-default').request.body, {
    contents: [{ role: 'user', parts: [{ text: ' Draw a small blue square. ' }] }],
    generationConfig: { responseModalities: ['TEXT', 'IMAGE'] },
  });
  assert.deepEqual(rows.get('source-only-defaults').request.body, rows.get('explicit-default').request.body);
  assert.equal(model('custom-model'), 'Vendor/Image-X');
  assert.equal(rows.get('custom-model').input.model, ' \u00a0Vendor/Image-X\ufeff ');
});

test('whole original model canonicalizer preserves exact prefix and maps all nine aliases', () => {
  for (const [id, expected] of [
    ['alias-gemini-3-pro', 'gemini-3.1-pro-preview'], ['alias-gemini-3-pro-preview', 'gemini-3.1-pro-preview'],
    ['alias-gemini-3-flash', 'gemini-3-flash-preview'], ['alias-gemini-3.1-pro', 'gemini-3.1-pro-preview'],
    ['alias-gemini-3.1-flash-lite-preview', 'gemini-3.1-flash-lite'], ['alias-gemini-3.1-flash', 'gemini-3-flash-preview'],
    ['alias-gemini-3.1-flash-preview', 'gemini-3-flash-preview'], ['alias-gemini-4', 'gemini-4-argon'],
    ['alias-gemma-4-26b', 'gemma-4-26b-a4b-it'], ['alias-prefixed', 'google/gemini-3.1-pro-preview'],
  ]) assert.equal(model(id), expected, id);
});

test('five sizes and source-only geometry contributions preserve strict numeric normalization', () => {
  for (const [id, expected] of [
    ['size-1024x1024', { aspectRatio: '1:1' }], ['size-1024x1536', { aspectRatio: '2:3', imageSize: '2K' }],
    ['size-1536x1024', { aspectRatio: '3:2', imageSize: '2K' }], ['size-1024x1792', { aspectRatio: '9:16', imageSize: '2K' }],
    ['size-1792x1024', { aspectRatio: '16:9', imageSize: '2K' }], ['size-tier-2k', { imageSize: '2K' }],
    ['size-tier-4k', { imageSize: '4K' }], ['size-js-whitespace', { aspectRatio: '2:3', imageSize: '2K' }],
    ['geometry-overrides-1k', { aspectRatio: '4:5', imageSize: '1K' }],
    ['geometry-overrides-2k', { aspectRatio: '21:9', imageSize: '2K' }],
    ['geometry-overrides-4k', { aspectRatio: '3:4', imageSize: '4K' }],
    ['blank-aspect', { aspectRatio: '2:3', imageSize: '2K' }],
  ]) assert.deepEqual(imageConfig(id), expected, id);
  assert.equal(Object.hasOwn(rows.get('size-unmapped-small').request.body.generationConfig, 'imageConfig'), false);
});

test('one and five edit images retain original raw MIME and ordered bytes with final exact prompt', () => {
  const one = rows.get('edit-one');
  assert.deepEqual(one.request.body.contents[0].parts, [
    { inlineData: { mimeType: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=' } },
    { text: ' Draw a small blue square. ' },
  ]);
  assert.deepEqual(rows.get('edit-five').request.body.contents[0].parts, [
    { inlineData: { mimeType: ' Image/JPEG; ColorSpace=RGB ', data: 'AQ==' } },
    { inlineData: { mimeType: 'image/webp', data: 'Ag==' } },
    { inlineData: { mimeType: 'image/png', data: 'Aw==' } },
    { inlineData: { mimeType: 'image/svg+xml', data: 'BA==' } },
    { inlineData: { mimeType: 'image/avif', data: 'BQ==' } },
    { text: ' Draw a small blue square. ' },
  ]);
});

test('count and all typed unsupported controls are ignored without fanout or result embellishment', () => {
  for (const id of ['count-one', 'count-four', 'ignored-controls']) {
    assert.deepEqual(rows.get(id).request, rows.get('explicit-default').request, id);
    assert.deepEqual(rows.get(id).result, rows.get('explicit-default').result, id);
  }
});

test('candidates flatten in order while valid absent content and non-media parts are skipped', () => {
  assert.deepEqual(output('ordered-candidates'), [
    { mimeType: 'image/png', fileName: 'image-1.png', bytesBase64: 'AQ==' },
    { mimeType: 'image/webp', fileName: 'image-2.webp', bytesBase64: 'Ag==' },
    { mimeType: 'image/avif', fileName: 'image-3.avif', bytesBase64: 'Aw==' },
  ]);
  assert.deepEqual(Object.keys(rows.get('ordered-candidates').result).sort(), ['images', 'model']);
});

test('camel nullish precedence, MIME fallback/case/parameters and source filename extension are exact', () => {
  assert.deepEqual(output('mime-precedence'), [
    { mimeType: 'Image/JPEG; ColorSpace=RGB', fileName: 'image-1.jpg', bytesBase64: 'AQ==' },
    { mimeType: 'image/svg+xml; charset=UTF-8', fileName: 'image-2.svg', bytesBase64: 'Ag==' },
    { mimeType: 'image/png', fileName: 'image-3.png', bytesBase64: '/9j/' },
    { mimeType: 'IMAGE/WEBP; Mode=Lossless', fileName: 'image-4.webp', bytesBase64: 'BA==' },
    { mimeType: 'application/octet-stream', fileName: 'image-5.octet-stream', bytesBase64: 'BQ==' },
    { mimeType: 'opaque', fileName: 'image-6.png', bytesBase64: 'Bg==' },
  ]);
});

test('whole Google and canonical Base64 helpers preserve padded/unpadded, URL-safe and valid whitespace bytes', () => {
  assert.deepEqual(output('base64-variants').map(image => image.bytesBase64), ['AQ==', 'Ag==', '+/8=', '+/8=', 'AQ==']);
  assert.deepEqual(output('base64-variants').map(image => image.fileName), ['image-1.png', 'image-2.png', 'image-3.png', 'image-4.png', 'image-5.png']);
});

test('actual cap source region executes configured 80.25 MiB and original four-result response formula', () => {
  assert.equal(rows.get('explicit-default').request.maxBytes, 358962518);
  assert.equal(rows.get('larger-media-cap').request.maxBytes, 449839104);
  assert.equal(rows.get('larger-media-cap').facadeCalls[0].input.cfg.agents.defaults.mediaMaxMb, 80.25);
  assert.equal(rows.get('count-one').request.maxBytes, rows.get('count-four').request.maxBytes);
});

test('whole Google URL and HTTP wrapper normalize an ordinary official root before lower facade', () => {
  const row = rows.get('official-root-normalization');
  assert.equal(row.config.baseUrl, ' https://generativelanguage.googleapis.com/openai/// ');
  assert.equal(row.facadeCalls[3].input.baseUrl, 'https://generativelanguage.googleapis.com/v1beta');
  assert.equal(row.request.url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent');
  assert.equal(row.hostComparable, true);
  const uppercase = rows.get('official-uppercase-host');
  assert.equal(uppercase.config.baseUrl, 'https://GENERATIVELANGUAGE.GOOGLEAPIS.COM/openai///');
  assert.equal(uppercase.facadeCalls[3].input.baseUrl, 'https://generativelanguage.googleapis.com/v1beta');
  assert.equal(uppercase.request.url, row.request.url);
  assert.equal(uppercase.hostComparable, true);
});

test('whole unchanged modules, exact cap source projection and every alias/facade reconstruct provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.selectedManifest.sources.length, 33);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.equal(executed.filter(row => row.wholeModule).length, 19);
  assert.equal(executed.filter(row => !row.wholeModule).length, 1);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) continue;
    let original = bytes.toString();
    if (!row.wholeModule) {
      const projection = row.projection;
      const selected = bytes.subarray(projection.startByte, projection.endByte);
      assert.equal(hash(selected), projection.sourceRegionSha256, row.path);
      original = projection.prelude + '\n' + selected.toString();
      assert.equal(original, projection.generatedCode, row.path);
      assert.equal(hash(original), projection.generatedSha256, row.path);
      assert.match(selected.toString(), /export function resolveGeneratedMediaMaxBytes/);
      assert.match(selected.toString(), /export function resolveGeneratedImageDownloadMaxBytes/);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
    if (binding.origin) assert.equal(hash(readFileSync(join(root, binding.origin))), binding.originSha256);
  }
  for (const source of ['extensions/google/image-generation-provider.ts', 'extensions/google/http-request.ts',
    'extensions/google/provider-policy.ts', 'extensions/google/src/google-api-base-url.ts',
    'extensions/google/generation-provider-metadata.ts', 'extensions/google/generation-auth.ts',
    'src/media-understanding/provider-json-post.ts', 'src/image-generation/image-assets.ts']) {
    assert.ok(executed.some(row => row.path === source && row.wholeModule), source);
  }
  assert.equal(capture.sourceRecords.find(row => row.path === 'extensions/google/image-generation-provider.ts').sha256,
    '37be0cef2a96e0f8ab33a5caee2a2149d873bbab900da105464c2d0375be7686');
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-google-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('full tracked-tree receipts and explicit facade limits avoid network/identity/readiness claims', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['214-line', 'modes and symlinks', 'complete original configured-max-bytes source region',
    'finally release', 'must not impersonate OpenClaw', 'does not accept localhost', 'hostComparable=false', 'Inactive additive protocol']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-http-transport-facade'));
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-status-native-json-reader-facades'));
  assert.ok(capture.importBindings.some(row => row.kind === 'uninvoked-throwing-facade' && row.exports.includes('isProviderApiKeyConfiguredAsync')));
});

test('fresh independent captures reproduce the frozen fixture twice exactly', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/google-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureGoogleImageGeneration(root), frozen);
});
