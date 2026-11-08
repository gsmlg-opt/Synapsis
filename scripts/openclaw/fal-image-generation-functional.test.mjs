// Semantic expectations below are handwritten independently of exporter vectors.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureFalImageGeneration, FAL_IMAGE_GENERATION_PIN } from './capture-fal-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureFalImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const model = 'fal-ai/flux/dev';
const baseUrl = 'https://fal.example.test';
const prompt = ' Draw a small blue square. ';
const sizes = ['1024x1024', '1024x1536', '1536x1024', '1024x1792', '1792x1024'];
const ratios = ['1:1', '2:3', '3:2', '2.35:1', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '21:9', '4:1', '1:4', '8:1', '1:8'];
const nano = ['21:9', '16:9', '3:2', '4:3', '5:4', '1:1', '4:5', '3:4', '2:3', '9:16'];
const nano2 = [...nano, '4:1', '1:4', '8:1', '1:8'];
const krea = ['1:1', '4:3', '3:2', '16:9', '2.35:1', '4:5', '2:3', '9:16'];
const grok = ['2:1', '20:9', '19.5:9', '16:9', '4:3', '3:2', '1:1', '2:3', '3:4', '9:16', '9:19.5', '9:20', '1:2'];
const gpt25 = ['openai/gpt-image-2.5/flare/text-to-image', 'openai/gpt-image-2.5/flare/edit',
  'openai/gpt-image-2.5/sunburst/text-to-image', 'openai/gpt-image-2.5/sunburst/edit'];
const dimensions = [[1024, 1024], [1024, 1536], [1536, 1024], [1024, 1792], [1792, 1024]];
// Exact integer and symbolic wire results, not recomputed with callback algorithms.
const fluxRatioSizes = ['square_hd', { width: 683, height: 1024 }, { width: 1024, height: 683 },
  { width: 1024, height: 436 }, 'portrait_4_3', 'landscape_4_3', { width: 819, height: 1024 },
  { width: 1024, height: 819 }, 'portrait_16_9', 'landscape_16_9', { width: 1024, height: 439 },
  { width: 1024, height: 256 }, { width: 256, height: 1024 }, { width: 1024, height: 128 }, { width: 128, height: 1024 }];
const gpt25RatioSizes = [[1536, 1536], [1024, 1536], [1536, 1024], [1536, 656], [1152, 1536],
  [1536, 1152], [1232, 1536], [1536, 1232], [864, 1536], [1536, 864], [1536, 656]];
const refs = (count, mime = 'image/png') => Array.from({ length: count }, (_, i) =>
  `data:${mime};base64,${Buffer.from([i + 1, 240, 32]).toString('base64')}`);
const body = (extra = {}, count = 1, format = 'png') => ({ prompt, num_images: count, output_format: format, ...extra });
const kb = (extra = {}) => ({ prompt, creativity: 'medium', ...extra });
const image = (bytesBase64, mimeType = 'image/png', fileName = 'image-1.png') => ({ mimeType, fileName, bytesBase64 });
const ordinaryImages = count => Array.from({ length: count }, (_, i) => image(Buffer.from([i + 11, 22, 33]).toString('base64'), 'image/png', `image-${i + 1}.png`));
const plans = [];
const plan = (id, wire = body(), extra = {}) => plans.push({ id, wire, route: model, count: 1, ...extra });
plan('flux-default'); plan('fractional-timeout');
plan('trim-model-base', body({ prompt: '  Keep prompt\n' }), { base: 'https://fal.example.test/render' });
plan('flux-auto-edit', body({ image_url: refs(1)[0] }), { route: model + '/image-to-image' });
plan('flux-explicit-edit', body({ image_size: { width: 2048, height: 2048 }, image_url: refs(1)[0] }), { route: model + '/image-to-image' });
plan('custom-preserved-edit', body({ image_size: { width: 1024, height: 1536 }, image_url: refs(1)[0] }), { route: 'fal-ai/custom/edit' });
plan('custom-preserved-middle', body({ image_url: refs(1)[0] }), { route: 'fal-ai/custom/image-to-image/revision' });
plan('reference-mime-name', body({ image_url: refs(1, 'Image/JPEG; mode=fixture')[0] }), { route: model + '/image-to-image' });
plan('reference-blank-mime', body({ image_url: refs(1)[0] }), { route: model + '/image-to-image' });
plan('count-two', body({}, 2), { count: 2 }); plan('count-three', body({}, 3), { count: 3 });
plan('count-four-jpeg', body({}, 4, 'jpeg'), { count: 4 }); plan('explicit-png-count-one');
plan('geometry-precedence', body({ image_size: { width: 1024, height: 1536 } }));
plan('generic-gpt-text', body({ image_size: { width: 1536, height: 1024 } }), { route: 'openai/gpt-image-2' });
plan('generic-gpt-auto-edit-max', body({ image_size: 'landscape_16_9', image_urls: refs(10) }), { route: 'openai/gpt-image-2/edit' });
plan('generic-gpt-explicit-edit', body({ image_urls: refs(1) }), { route: 'openai/gpt-image-2/edit' });
plan('generic-gpt-text-suffix-edit', body({ image_urls: refs(1) }), { route: 'openai/gpt-image-2/text-to-image/edit' });
plan('media-cap-floor'); plan('media-cap-larger', body(), { cap: 84148224 });
dimensions.forEach(([width, height], i) => plan(`flux-size-${i}`, body({ image_size: { width, height } })));
fluxRatioSizes.forEach((image_size, i) => plan(`flux-ratio-${i}`, body({ image_size })));
for (const [i, edge, short] of [[0, 1024, 576], [1, 2048, 1152], [2, 4096, 2304]]) {
  plan(`flux-resolution-${i}`, body({ image_size: { width: edge, height: edge } }));
  plan(`flux-ratio-resolution-${i}`, body({ image_size: { width: short, height: edge } }));
}
gpt25.forEach((route, i) => {
  plan(`gpt25-model-${i}`, body(), { route });
  plan(`gpt25-edit-${i}`, body({ image_urls: refs(i === 0 ? 16 : 1) }), { route: [
    'openai/gpt-image-2.5/flare/edit', 'openai/gpt-image-2.5/flare/edit',
    'openai/gpt-image-2.5/sunburst/edit', 'openai/gpt-image-2.5/sunburst/edit',
  ][i] });
});
plan('gpt25-auto', body({ image_size: 'auto' }), { route: gpt25[0] });
dimensions.forEach(([width, height], i) => plan(`gpt25-size-${i}`, body({ image_size: { width, height } }), { route: gpt25[0] }));
gpt25RatioSizes.forEach(([width, height], i) => plan(`gpt25-ratio-${i}`, body({ image_size: { width, height } }), { route: gpt25[0] }));
['low', 'medium', 'high', 'xhigh', 'max', 'auto'].forEach((quality, i) => plan(`gpt25-quality-${i}`, body({ quality }), { route: gpt25[0] }));
['png', 'jpeg', 'webp'].forEach((format, i) => plan(`gpt25-format-${i}`, body({}, 1, format), { route: gpt25[0] }));
['transparent', 'opaque', 'auto'].forEach((background, i) => plan(`gpt25-background-${i}`, body({ background }), { route: gpt25[0] }));
for (const [i, route, count] of [[0, 'krea/v2/medium/text-to-image', 10], [1, 'krea/v2/large/text-to-image', 1]]) {
  plan(`krea-model-${i}`, kb(), { route });
  plan(`krea-reference-${i}`, kb({ image_style_references: refs(count).map(image_url => ({ image_url })) }), { route });
}
krea.forEach((aspect_ratio, i) => plan(`krea-ratio-${i}`, kb({ aspect_ratio }), { route: 'krea/v2/medium/text-to-image' }));
['raw', 'low', 'medium', 'high', 'high'].forEach((creativity, i) => plan(`krea-creativity-${i}`, kb({ creativity }), { route: 'krea/v2/medium/text-to-image' }));
plan('krea-size', kb({ aspect_ratio: '2:3' }), { route: 'krea/v2/large/text-to-image' });
for (const [family, route, allowed, max] of [
  ['nano', 'fal-ai/nano-banana', nano, 3], ['nano2', 'fal-ai/nano-banana-2', nano2, 14],
  ['lite', 'google/nano-banana-2-lite', nano2, 14], ['grok', 'xai/grok-imagine-image', grok, 3],
]) {
  plan(`${family}-generate`, body(), { route });
  plan(`${family}-auto-edit-max`, body({ image_urls: refs(max) }), { route: route + '/edit' });
  plan(`${family}-explicit-edit`, body({ image_urls: refs(1) }), { route: route + '/edit' });
  plan(`${family}-size`, body({ aspect_ratio: '2:3' }), { route });
  allowed.forEach((aspect_ratio, i) => plan(`${family}-ratio-${i}`, body({ aspect_ratio }), { route }));
}
['1K', '2K', '4K'].forEach((resolution, i) => plan(`nano2-resolution-${i}`, body({ resolution }), { route: 'fal-ai/nano-banana-2' }));
['1k', '2k'].forEach((resolution, i) => plan(`grok-resolution-${i}`, body({ resolution }), { route: 'xai/grok-imagine-image' }));
plan('grok-quality', body(), { route: 'xai/grok-imagine-image/quality' });
plan('grok-quality-auto-edit', body({ image_urls: refs(1) }), { route: 'xai/grok-imagine-image/quality/edit' });
plan('grok-quality-explicit-edit', body({ image_urls: refs(3) }), { route: 'xai/grok-imagine-image/quality/edit' });
plan('result-url-mime-metadata', body({}, 4), { count: 4, metadata: { prompt: 'Actual provider prompt.' }, images: [
  image('/9j/', 'Image/JPEG; codec=fixture', 'image-1.jpg'), image('UklGRgQAAABXRUJQ', 'image/png', 'image-2.png'),
  image('AQID', 'image/webp', 'image-3.webp'), image('BAUG', 'image/svg+xml; charset=UTF-8', 'image-4.svg'),
] });
plan('result-blank-mime-prompt', body(), { images: [image('/9j/')] });
plan('source-only-default-model-timeout', body(), { defaults: true });
plan('source-only-configured-header', body(), { header: true });

test('independent literal plans match every complete POST, ordered GET and raw callback result', () => {
  assert.deepEqual([...rows.keys()], plans.map(row => row.id));
  for (const p of plans) {
    const row = rows.get(p.id); const cap = p.cap ?? 67108864; const end = 100015 + p.count * 7;
    assert.deepEqual(row.request, { url: (p.base ?? baseUrl) + '/' + p.route, method: 'POST',
      headers: { authorization: 'Key synthetic-explicit-key', 'content-type': 'application/json', ...(p.header ? { 'x-fixture-render': 'normal' } : {}) },
      timeoutMs: p.defaults ? null : 29995, atMs: 100005, auditContext: 'fal-image-generate',
      dispatcherPolicy: null, initSupplied: true, releaseCount: 1, kind: 'json', rawBody: JSON.stringify(p.wire),
      body: p.wire, jsonBody: p.wire, maxBytes: 16777216, releasedAtMs: end }, p.id + ' whole POST');
    assert.deepEqual(row.downloads, Array.from({ length: p.count }, (_, i) => ({
      url: `https://images.example.test/${i + 1}`, method: 'GET', headers: {},
      timeoutMs: p.defaults ? 30000 : 29985 - i * 7, atMs: 100015 + i * 7,
      auditContext: 'fal-image-download', dispatcherPolicy: null, initSupplied: false,
      releaseCount: 1, maxBytes: cap, releasedAtMs: 100022 + i * 7,
    })), p.id + ' whole ordered downloads');
    assert.deepEqual(row.result, { images: p.images ?? ordinaryImages(p.count), model: p.route,
      ...(p.metadata ? { metadata: p.metadata } : {}) }, p.id + ' whole result');
    assert.deepEqual(row.inputAfter, row.input, p.id + ' no input mutation');
    assert.equal(row.releaseCount, p.count + 1);
  }
});

test('complete descriptor preserves exact models, per-model geometry/options and all prefix limits', () => {
  const empty = Object.fromEntries([...gpt25, 'krea/v2/medium/text-to-image', 'krea/v2/large/text-to-image'].map(m => [m, []]));
  const paths = (prefix, suffixes) => suffixes.map(suffix => prefix + suffix);
  const expected = { id: 'fal', label: 'fal', defaultModel: model,
    models: [model, model + '/image-to-image', 'krea/v2/medium/text-to-image', 'krea/v2/large/text-to-image', ...gpt25],
    capabilities: { generate: { maxCount: 4, supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
      edit: { enabled: true, maxCount: 4, maxInputImages: 1,
        maxInputImagesByModel: { ...Object.fromEntries(gpt25.map(m => [m, 16])), 'fal-ai/nano-banana': 3, 'fal-ai/nano-banana/edit': 3 },
        maxInputImagesByModelPrefix: { 'openai/gpt-image-': 10, 'krea/v2/': 10, 'fal-ai/nano-banana-': 14,
          'google/nano-banana-2-lite': 14, 'xai/grok-imagine-image': 3 },
        supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
      geometry: { sizes, sizesByModel: empty, aspectRatios: ratios, aspectRatiosByModel: {
        ...Object.fromEntries(paths('fal-ai/nano-banana', ['', '/edit']).map(m => [m, nano])),
        ...Object.fromEntries(paths('google/nano-banana-2-lite', ['', '/edit']).map(m => [m, nano2])),
        ...Object.fromEntries(paths('xai/grok-imagine-image', ['', '/edit', '/quality', '/quality/edit']).map(m => [m, grok])),
        'krea/v2/medium/text-to-image': krea, 'krea/v2/large/text-to-image': krea,
        'fal-ai/nano-banana-2': nano2, 'fal-ai/nano-banana-2/edit': nano2,
      }, resolutions: ['1K', '2K', '4K'], resolutionsByModel: { ...empty,
        'fal-ai/nano-banana': [], 'fal-ai/nano-banana/edit': [], 'google/nano-banana-2-lite': [], 'google/nano-banana-2-lite/edit': [],
        ...Object.fromEntries(paths('xai/grok-imagine-image', ['', '/edit', '/quality', '/quality/edit']).map(m => [m, ['1K', '2K']])),
      } }, output: { formats: ['png', 'jpeg'], formatsByModel: Object.fromEntries(gpt25.map(m => [m, ['png', 'jpeg', 'webp']])),
        qualitiesByModel: Object.fromEntries(gpt25.map(m => [m, ['low', 'medium', 'high', 'xhigh', 'max', 'auto']])),
        backgroundsByModel: Object.fromEntries(gpt25.map(m => [m, ['transparent', 'opaque', 'auto']])),
      } } };
  assert.deepEqual(capture.providerDescriptor, expected);
  assert.equal(Object.hasOwn(capture.providerDescriptor, 'defaultTimeoutMs'), false);
  assert.equal(capture.staticMetadataContradictions.length, 4);
});

test('source HTTP context makes Key/JSON headers and source-normalized base before declared config facade', () => {
  for (const p of plans) {
    const row = rows.get(p.id);
    const configuredBase = p.id === 'trim-model-base' ? '\uFEFFhttps://fal.example.test/render///\u00a0' : baseUrl;
    const request = p.header ? { headers: { 'X-Fixture-Render': 'normal' } } : null;
    assert.deepEqual(row.configCalls, [{ provider: 'fal', capability: 'image', transport: 'http', baseUrl: configuredBase.trim(),
      defaultBaseUrl: 'https://fal.run', allowPrivateNetwork: false,
      defaultHeaders: { Authorization: 'Key synthetic-explicit-key', 'Content-Type': 'application/json' }, request,
      output: { baseUrl: p.base ?? baseUrl, headers: { authorization: 'Key synthetic-explicit-key', 'content-type': 'application/json',
        ...(p.header ? { 'x-fixture-render': 'normal' } : {}) }, dispatcherPolicy: null },
      implementation: 'successful-provider-http-request-config-facade' }], p.id);
    const cfg = { models: { providers: { fal: { baseUrl: configuredBase,
      ...(p.header ? { request: { headers: { 'X-Fixture-Render': ' normal ' } } } : {}),
    } } }, ...(p.id === 'media-cap-floor' ? { agents: { defaults: { mediaMaxMb: 2.25 } } } : {}),
    ...(p.id === 'media-cap-larger' ? { agents: { defaults: { mediaMaxMb: 80.25 } } } : {}) };
    assert.deepEqual(row.keyCalls, [{ provider: 'fal', cfg, agentDir: null, store: null,
      implementation: 'successful-explicit-synthetic-key-facade' }], p.id);
    assert.deepEqual(row.sanitizeCalls, [{ input: p.header ? { headers: { 'X-Fixture-Render': ' normal ' } } : null,
      output: request, implementation: 'successful-configured-request-sanitizer-facade' }], p.id);
  }
});

test('original JSON cap/idle selection and binary cap/deadline/release ordering have exact success ledgers', () => {
  for (const p of plans) {
    const row = rows.get(p.id); const cap = p.cap ?? 67108864;
    assert.deepEqual(row.readerCalls, [{ kind: 'json', maxBytes: 16777216, chunkTimeoutMs: 30000,
      hasOnIdleTimeout: true, hasOnOverflow: true, atMs: 100012, implementation: 'successful-lower-body-reader-facade' },
    ...Array.from({ length: p.count }, (_, i) => ({ kind: 'binary', maxBytes: cap, chunkTimeoutMs: null,
      hasOnIdleTimeout: false, hasOnOverflow: true, atMs: 100020 + i * 7, implementation: 'successful-lower-body-reader-facade' }))], p.id);
    assert.deepEqual(row.statusCalls, [{ label: 'fal image generation failed', status: 200, atMs: 100012,
      implementation: 'successful-status-facade' }, ...Array.from({ length: p.count }, (_, i) => ({
      label: 'fal image download failed', status: 200, atMs: 100020 + i * 7, implementation: 'successful-status-facade',
    }))], p.id);
    assert.deepEqual(row.releaseCalls, [...Array.from({ length: p.count }, (_, i) => ({
      kind: 'download', url: `https://images.example.test/${i + 1}`, releaseCount: 1, atMs: 100022 + i * 7,
    })), { kind: 'post', url: (p.base ?? baseUrl) + '/' + p.route, releaseCount: 1, atMs: 100015 + p.count * 7 }], p.id);
    assert.deepEqual(row.clock, { kind: 'synthetic-Date.now', startMs: 100000, endMs: 100015 + p.count * 7,
      serviceCostsMs: { key: 2, config: 3, post: 7, jsonRead: 3, download: 5, binaryRead: 2 } }, p.id);
  }
});

test('positive matrix covers descriptor models, routing families, advertised values and structural reference bounds', () => {
  for (const m of [model, model + '/image-to-image', 'krea/v2/medium/text-to-image', 'krea/v2/large/text-to-image', ...gpt25])
    assert.ok(capture.observations.some(row => row.result.model === m), m);
  for (const [prefix, count] of [['gpt25-edit-0', 16], ['generic-gpt-auto-edit-max', 10], ['krea-reference-0', 10],
    ['nano-auto-edit-max', 3], ['nano2-auto-edit-max', 14], ['lite-auto-edit-max', 14], ['grok-auto-edit-max', 3]])
    assert.equal(rows.get(prefix).input.inputImages.length, count, prefix);
  for (const row of capture.observations) {
    assert.ok(row.input.count === undefined || (row.input.count >= 1 && row.input.count <= 4));
    if (row.result.model.startsWith('krea/')) {
      assert.ok(row.input.count === undefined || row.input.count === 1);
      assert.equal(Object.hasOwn(row.input, 'outputFormat'), false); assert.equal(Object.hasOwn(row.input, 'resolution'), false);
    }
  }
  for (const m of gpt25) assert.deepEqual(capture.providerDescriptor.capabilities.geometry.resolutionsByModel[m], []);
  for (const ratio of ['4:1', '1:4', '8:1', '1:8']) {
    assert.ok(capture.providerDescriptor.capabilities.geometry.aspectRatios.includes(ratio));
    assert.equal(capture.observations.some(row => gpt25.includes(row.input.model) && row.input.aspectRatio === ratio), false);
  }
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-default-model-timeout', 'source-only-configured-header',
  ]);
  assert.deepEqual(rows.get('source-only-default-model-timeout').input, { prompt });
  assert.equal(capture.serviceFacadeLedger.length, 7);
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('every original/generated/executable/import/runtime/exporter/harness receipt reconstructs independently', () => {
  assert.equal(FAL_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, FAL_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/fal/image-generation-provider.ts', 'extensions/fal/http-config.ts', 'src/image-generation/image-assets.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(), [
    'src/media/configured-max-bytes.ts', 'src/media-understanding/shared.ts',
    'src/agents/provider-http-errors.ts', 'src/agents/provider-request-config.ts',
  ].sort());
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let source = bytes.toString();
    if (!row.wholeModule) {
      const p = row.projection;
      source = p.prelude + '\n' + p.regions.map(region => {
        const original = bytes.subarray(region.startByte, region.endByte);
        assert.equal(hash(original), region.sourceRegionSha256, row.path); return original.toString();
      }).join('\n');
      assert.equal(source, p.generatedCode); assert.equal(hash(source), p.generatedSha256);
    }
    assert.equal(hash(stripTypeScriptTypes(source, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  const expectedRegions = {
    'src/media/configured-max-bytes.ts': [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']],
    'src/media-understanding/shared.ts': [['export function createProviderOperationDeadline(', '/** Resolves a static or lazy request timeout']],
    'src/agents/provider-request-config.ts': [['export function normalizeBaseUrl(baseUrl:', '// Header keys are compared case-insensitively']],
    'src/agents/provider-http-errors.ts': [
      ['const PROVIDER_RESPONSE_MAX_BYTES =', 'const SHORT_BEARER_TOKEN_PATTERN ='],
      ['function readProviderResponseBytes(', 'type ProviderHttpErrorOptions ='],
      ['export async function readProviderJsonResponse<T>(', 'export async function readProviderJsonObjectResponse('],
    ],
  };
  for (const [path, markers] of Object.entries(expectedRegions)) {
    const bytes = readFileSync(join(root, path));
    assert.deepEqual(executed.find(row => row.path === path).projection.regions.map(r => [r.startByte, r.endByte]),
      markers.map(([start, end]) => [bytes.indexOf(start), bytes.indexOf(end, bytes.indexOf(start))]), path);
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-fal-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const path of ['extensions/fal/openclaw.plugin.json', 'extensions/fal/index.ts', 'extensions/fal/provider-contract-api.ts',
    'extensions/fal/onboard.ts', 'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts'])
    assert.deepEqual(capture.sourceRecords.find(row => row.path === path), {
      path, sha256: hash(readFileSync(join(root, path))), executed: false, provenanceOnly: true,
    });
  for (const text of ['698-line', '48-line', 'fatal TextDecoder', 'modes and symlinks', 'Raw callback only',
    'all eight routing schemas', 'Lower successful', 'without sniffing', 'No retry/poll/upload/multipart/inline-output', 'Inactive independent source oracle'])
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
});

test('two fresh captures equal the frozen JSON including complete protocol and provenance receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/fal-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureFalImageGeneration(root), fixture);
});
