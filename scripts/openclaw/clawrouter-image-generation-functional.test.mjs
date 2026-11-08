// Handwritten ordinary-success plans, independent of capture inputs/results and host implementation.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureClawRouterImageGeneration, CLAWROUTER_IMAGE_GENERATION_PIN } from './capture-clawrouter-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureClawRouterImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const model = 'openai/gpt-image-2.5-flare';
const prompt = ' Draw a small blue square. ';
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const base = 'https://router.example.test/v1';
const body = extra => ({ model, prompt, n: 1, ...extra });
const image = (bytesBase64 = png, mimeType = 'image/png', fileName = 'image-1.png', revisedPrompt) => ({
  mimeType, fileName, ...(revisedPrompt ? { revisedPrompt } : {}), bytesBase64,
});
const plans = [
  ['minimal', body()], ['fractional-timeout', body()],
  ['model-1', body({ model: 'openai/gpt-image-2.5-flare-2026-09-08' })],
  ['model-2', body({ model: 'openai/gpt-image-2.5-sunburst' })],
  ['model-3', body({ model: 'openai/gpt-image-2.5-sunburst-2026-09-08' })],
  ['base-v1', body()], ['base-prefix-trim', body(), { base: 'https://router.example.test/resource/v1' }],
  ['count-1', body({ n: 1 })], ['count-2', body({ n: 2 })], ['count-3', body({ n: 3 })],
  ['count-4', body({ n: 4 })], ['count-5', body({ n: 5 })], ['count-6', body({ n: 6 })],
  ['count-7', body({ n: 7 })], ['count-8', body({ n: 8 })], ['count-9', body({ n: 9 })], ['count-10', body({ n: 10 })],
  ['fewer-results', body({ n: 2 }), { resultCount: 1 }],
  ['catalog-lowered-limits', body({ prompt: '蓝🌕', n: 2, size: '32x32' })],
  ['prompt-unicode-whitespace', body({ prompt: '  绘画 🌕 e\u0301\n' })], ['empty-references', body()],
  ['size-0', body({ size: '1024x1024' })], ['size-1', body({ size: '1536x1024' })],
  ['size-2', body({ size: '1024x1536' })], ['size-3', body({ size: 'auto' })],
  ['quality-0', body({ quality: 'low' })], ['quality-1', body({ quality: 'medium' })],
  ['quality-2', body({ quality: 'high' })], ['quality-3', body({ quality: 'xhigh' })],
  ['quality-4', body({ quality: 'max' })], ['quality-5', body({ quality: 'auto' })],
  ['format-0', body({ output_format: 'png' })], ['format-1', body({ output_format: 'jpeg' })],
  ['format-2', body({ output_format: 'webp' })],
  ['background-0', body({ background: 'auto' })], ['background-1', body({ background: 'opaque' })],
  ['background-2', body({ background: 'transparent' })],
  ['openai-options', body({ background: 'transparent', moderation: 'low', output_compression: 0, user: ' ordinary user ' })],
  ['background-top-priority', body({ background: 'opaque' })], ['background-nullish', body({ background: 'transparent' })],
  ['inline-jpeg', body(), { images: [image(jpeg, 'image/jpeg', 'image-1.jpg')] }],
  ['inline-webp', body(), { images: [image(webp, 'image/webp', 'image-1.webp')] }],
  ['explicit-png', body(), { images: [image(png, 'image/png', 'image-1.png', 'Revised ordinary prompt.')] }],
  ['explicit-jpeg', body(), { images: [image(jpeg, 'image/jpeg', 'image-1.jpg', 'Revised ordinary prompt.')] }],
  ['explicit-webp', body(), { images: [image(webp, 'image/webp', 'image-1.webp', 'Revised ordinary prompt.')] }],
  ['base64-unpadded', body()], ['base64-whitespace', body()],
  ['ordered-url-results', body({ n: 2 }), { downloads: true, images: [
    image(png, 'image/png', 'image-1.png', 'First.'), image(png, 'image/png', 'image-2.png', 'Second.')] }],
  ['repeat-fresh-catalog-first', body()], ['repeat-fresh-catalog-second', body({ n: 3 })],
  ['source-only-default-timeout', body(), { timeoutMs: 180000 }],
  ['source-only-configured-header', body(), { header: true }],
];
const jsonCaps = [0, 90527062, 180005547, 269484032, 358962518, 448441003,
  537919488, 627397974, 716876459, 806354944, 895833430];
const ordinaryHeaders = { accept: 'application/json', authorization: 'Bearer synthetic-explicit-key', 'x-clawrouter-client': 'openclaw' };
const catalogReceipt = (api, total, extra = {}) => ({ url: api + '/catalog', method: 'GET', headers: { ...ordinaryHeaders, ...extra },
  timeoutMs: total - 5, atMs: 100005, auditContext: 'clawrouter.image-catalog', dispatcherPolicy: null,
  releaseCount: 1, maxBytes: 1048576, releasedAtMs: 100012 });
const reader = (kind, maxBytes, timeoutMs, atMs) => ({ kind, maxBytes, timeoutMs, chunkTimeoutMs: 30000,
  hasOnIdleTimeout: true, hasOnOverflow: true, atMs, implementation: 'successful-lower-body-reader-facade' });
const release = (kind, url, atMs) => ({ kind, url, releaseCount: 1, atMs });
const downloadUrls = ['https://router.example.test/results/ignored-first.jpg', 'https://images.example.test/ignored-second.webp'];

test('52 independent full wire/result and lifetime plans cover ordinary callbacks', () => {
  assert.equal(plans.length, 52);
  assert.deepEqual([...rows.keys()], plans.map(([id]) => id));
  for (const [id, expectedBody, extra = {}] of plans) {
    const row = rows.get(id), api = extra.base ?? base, total = extra.timeoutMs ?? 30000;
    const custom = extra.header ? { 'x-fixture-provider': 'provider', 'x-fixture-request': 'request' } : {};
    const postUrl = api + '/images/generations', end = extra.downloads ? 100036 : 100022;
    assert.deepEqual(row.catalogRequest, catalogReceipt(api, total, custom), id + ' full catalog GET');
    assert.deepEqual(row.request, { url: postUrl, method: 'POST',
      headers: { ...ordinaryHeaders, ...custom, 'content-type': 'application/json' },
      timeoutMs: total - 12, atMs: 100012, auditContext: null, dispatcherPolicy: null,
      releaseCount: 1, kind: 'json', rawBody: JSON.stringify(expectedBody), body: expectedBody, jsonBody: expectedBody,
      maxBytes: jsonCaps[expectedBody.n], releasedAtMs: end }, id + ' full POST');
    const expectedImages = extra.images ?? Array.from({ length: extra.resultCount ?? expectedBody.n }, (_, i) => image(png, 'image/png', `image-${i + 1}.png`));
    assert.deepEqual(row.result, { images: expectedImages, model: expectedBody.model }, id + ' full result');
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], id);
    assert.deepEqual(row.inputAfter, row.input, id);
    const expectedDownloads = extra.downloads ? downloadUrls.map((url, i) => ({ url, method: 'GET', headers: {},
      timeoutMs: i === 0 ? 29978 : 29971, atMs: i === 0 ? 100022 : 100029,
      auditContext: 'clawrouter-image-download', dispatcherPolicy: null, releaseCount: 1,
      maxBytes: 67108864, releasedAtMs: i === 0 ? 100029 : 100036 })) : [];
    assert.deepEqual(row.downloads, expectedDownloads, id + ' full clean ordered download GETs');
    assert.deepEqual(row.readerCalls, [reader('catalog', 1048576, total - 9, 100009),
      reader('post', jsonCaps[expectedBody.n], total - 19, 100019),
      ...(extra.downloads ? [reader('download', 67108864, 29973, 100027), reader('download', 67108864, 29966, 100034)] : [])], id);
    assert.deepEqual(row.releaseCalls, [release('catalog', api + '/catalog', 100012),
      ...(extra.downloads ? [release('download', downloadUrls[0], 100029), release('download', downloadUrls[1], 100036)] : []),
      release('post', postUrl, end)], id);
    assert.equal(row.releaseCount, extra.downloads ? 4 : 2, id);
    assert.deepEqual(row.clock, { kind: 'synthetic-Date.now', startMs: 100000, endMs: end,
      serviceCostsMs: { key: 2, config: 3, catalog: 4, catalogRead: 3, post: 7, jsonRead: 3, download: 5, binaryRead: 2 },
      sameProviderInstance: true }, id);
    assert.deepEqual(row.statusCalls, extra.downloads ? [
      { label: 'ClawRouter image download failed', status: 200, atMs: 100027, implementation: 'successful-status-facade' },
      { label: 'ClawRouter image download failed', status: 200, atMs: 100034, implementation: 'successful-status-facade' }] : [], id);
    assert.deepEqual(row.guardCalls, [
      { url: api + '/catalog', timeoutMs: total - 5, options: { auditContext: 'clawrouter.image-catalog' },
        implementation: 'successful-no-network-fetchWithTimeoutGuarded-facade' },
      { url: postUrl, timeoutMs: total - 12, options: null,
        implementation: 'successful-no-network-fetchWithTimeoutGuarded-facade' }], id);

  }
});

test('source descriptor and selected live catalog constraints stay distinct', () => {
  assert.deepEqual(capture.providerDescriptor, { id: 'clawrouter', label: 'ClawRouter', defaultTimeoutMs: 180000, models: [],
    capabilities: { generate: { maxCount: 10, supportsSize: true, supportsAspectRatio: false, supportsResolution: false },
      edit: { enabled: false }, output: { qualities: ['low', 'medium', 'high', 'xhigh', 'max', 'auto'],
        formats: ['png', 'jpeg', 'webp'], backgrounds: ['auto', 'opaque', 'transparent'] } } });
  assert.deepEqual(rows.get('catalog-lowered-limits').catalogResponse.providers[0].models[0].pricing.generation, {
    maxPromptCharacters: 2, maxImages: 2, dimensionMultiple: 8, minPixels: 1024, maxPixels: 2048, maxEdge: 64, maxAspectRatio: 2 });
  assert.equal(rows.get('repeat-fresh-catalog-first').catalogResponse.providers[0].models[0].pricing.generation.maxImages, 2);
  assert.equal(rows.get('repeat-fresh-catalog-second').catalogResponse.providers[0].models[0].pricing.generation.maxImages, 3);
  assert.equal(rows.get('repeat-fresh-catalog-second').catalogResponse.providers[0].offers[0].affordability, 'request-dependent');
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-default-timeout', 'source-only-configured-header']);
  for (const row of capture.observations.filter(row => row.hostComparable)) {
    assert.ok(Number.isFinite(row.input.timeoutMs) && row.input.timeoutMs > 0);
    assert.ok(row.input.model && row.config.baseUrl);
  }
});

test('original normalized base and ordinary configured headers flow through named service seams', () => {
  for (const [id, , extra = {}] of plans) {
    const row = rows.get(id), api = extra.base ?? base;
    const rawConfig = id === 'base-v1' ? { baseUrl: 'https://router.example.test/v1/' }
      : id === 'base-prefix-trim' ? { baseUrl: ' \uFEFFhttps://router.example.test/resource/v1///\u00a0' }
      : extra.header ? { baseUrl: 'https://router.example.test', headers: { 'X-Fixture-Provider': ' provider ' },
        request: { headers: { 'X-Fixture-Request': ' request ' } } } : { baseUrl: 'https://router.example.test' };
    assert.deepEqual(row.config, rawConfig, id);
    const ordinaryConfigCalls = row.configCalls.map(({ provider, capability, transport, baseUrl, defaultBaseUrl, request, output, atMs, implementation }) => ({
      provider, capability, transport, baseUrl, defaultBaseUrl, request,
      output: { baseUrl: output.baseUrl, headers: output.headers }, atMs, implementation,
    }));
    assert.deepEqual(ordinaryConfigCalls, [{ provider: 'clawrouter', capability: 'image', transport: 'http', baseUrl: api,
      defaultBaseUrl: api, request: extra.header ? { headers: { 'X-Fixture-Request': 'request' } } : null,
      output: { baseUrl: api, headers: extra.header ? { 'x-fixture-request': 'request' } : {} },
      atMs: 100002, implementation: 'successful-provider-http-request-config-facade' }], id);
    assert.deepEqual(row.sanitizeCalls, [
      { input: extra.header ? { headers: { 'X-Fixture-Request': ' request ' } } : null,
        output: extra.header ? { headers: { 'X-Fixture-Request': 'request' } } : null,
        implementation: 'successful-configured-request-sanitizer-facade' },
      { input: extra.header ? { headers: { 'X-Fixture-Provider': ' provider ' } } : {},
        output: extra.header ? { headers: { 'X-Fixture-Provider': 'provider' } } : null,
        implementation: 'successful-configured-request-sanitizer-facade' }], id);
  }
  assert.equal(capture.serviceFacadeLedger.length, 6);
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('all source, transformed regions, import/export bindings and runtime receipts reconstruct independently', () => {
  assert.equal(CLAWROUTER_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, CLAWROUTER_IMAGE_GENERATION_PIN);
  assert.deepEqual(capture.dynamicImports, []);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(capture.sourceRecords.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/clawrouter/image-generation-provider.ts', 'extensions/clawrouter/image-model-catalog.ts', 'extensions/clawrouter/base-url.ts',
    'src/image-generation/image-assets.ts', 'src/image-generation/openai-compatible-image-urls.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  ].sort());
  assert.deepEqual(capture.sourceRecords.filter(row => row.executed && !row.wholeModule).map(row => row.path).sort(), [
    'src/media/configured-max-bytes.ts', 'src/media-understanding/shared.ts', 'src/media-understanding/shared.ts', 'src/agents/provider-http-errors.ts',
  ].sort());
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let original = bytes.toString();
    if (!row.wholeModule) {
      const p = row.projection;
      original = p.prelude + '\n' + p.regions.map(region => {
        const selected = bytes.subarray(region.startByte, region.endByte);
        assert.equal(hash(selected), region.sourceRegionSha256, row.path); return selected.toString();
      }).join('\n');
      assert.equal(original, p.generatedCode, row.path); assert.equal(hash(original), p.generatedSha256, row.path);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-clawrouter-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.deepEqual({ executable: capture.runtime.executable, version: capture.runtime.version }, {
    executable: '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node', version: '24.22.1' });
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.ok(capture.limits.some(row => row.includes('2147000000ms')));
  assert.ok(capture.limits.some(row => row.includes('production policy/reader equivalence')));
});

test('two fresh full captures equal frozen fixture including provenance and successful I/O ledgers', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/clawrouter-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureClawRouterImageGeneration(root), fixture);
});
