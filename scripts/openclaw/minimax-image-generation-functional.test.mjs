// Independent handwritten ordinary-success expectations for unchanged pinned MiniMax source.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMinimaxImageGeneration, MINIMAX_IMAGE_GENERATION_PIN } from './capture-minimax-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureMinimaxImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const prompt = ' Draw a small blue square. ';
const base = 'https://api.minimax.io';
const image = (bytesBase64 = png, fileName = 'image-1.png') => ({ mimeType: 'image/png', fileName, bytesBase64 });
const body = (overrides = {}) => ({ model: 'image-01', prompt, response_format: 'base64', n: 1, ...overrides });
// Each wire expectation is independently specified, never computed from capture inputs/results.
const plans = [
  ['default-count', body()],
  ['explicit-model-prompt', body({ model: ' Vendor/Image-X ', prompt: '  Preserve this exact prompt.\n' })],
  ['minimax-prefixed-model', body({ model: ' minimax/image-01 ' })],
  ['portal-provider', body()],
  ['count-one', body()],
  ['count-nine', body({ n: 9 })],
  ['aspect-1-1', body({ aspect_ratio: '1:1' })],
  ['aspect-16-9', body({ aspect_ratio: '16:9' })],
  ['aspect-4-3', body({ aspect_ratio: '4:3' })],
  ['aspect-3-2', body({ aspect_ratio: '3:2' })],
  ['aspect-2-3', body({ aspect_ratio: '2:3' })],
  ['aspect-3-4', body({ aspect_ratio: '3:4' })],
  ['aspect-9-16', body({ aspect_ratio: '9:16' })],
  ['aspect-21-9', body({ aspect_ratio: '21:9' })],
  ['aspect-js-trim', body({ aspect_ratio: '16:9' })],
  ['input-default-mime', body({ subject_reference: [{ type: 'character', image_file: 'data:image/jpeg;base64,' + jpeg }] })],
  ['input-raw-mime-filename-ignored', body({ subject_reference: [{ type: 'character', image_file: 'data: Image/PNG; Mode=RGB ;base64,' + png }] })],
  ['ordered-opaque-results', body({ n: 9 })],
  ['base64-unpadded', body()],
  ['base64-whitespace', body()],
  ['metadata-ignored', body()],
  ['configured-cn-region', body(), 'https://api.minimaxi.com'],
  ['portal-configured-cn-region', body(), 'https://api.minimaxi.com'],
  ['media-cap-floor', body()],
  ['media-cap-larger', body()],
  ['source-only-default-model-timeout', body()],
  ['source-only-configured-header', body()],
];
const results = new Map(plans.map(([id]) => [id, { images: [image()], model: 'image-01' }]));
results.set('explicit-model-prompt', { images: [image()], model: ' Vendor/Image-X ' });
results.set('minimax-prefixed-model', { images: [image()], model: ' minimax/image-01 ' });
results.set('ordered-opaque-results', { images: [image(jpeg), image(webp, 'image-2.png'), image(opaque, 'image-3.png'), image(png, 'image-4.png')], model: 'image-01' });
const capabilities = {
  generate: { maxCount: 9, supportsSize: false, supportsAspectRatio: true, supportsResolution: false },
  edit: { enabled: true, maxCount: 9, maxInputImages: 1, supportsSize: false, supportsAspectRatio: true, supportsResolution: false },
  geometry: { aspectRatios: ['1:1', '16:9', '4:3', '3:2', '2:3', '3:4', '9:16', '21:9'] },
};

test('27 complete-source ordinary success observations match independent literal POST and result plans', () => {
  assert.deepEqual(capture.observations.map(row => row.id), plans.map(([id]) => id));
  for (const [id, expectedBody, origin = base] of plans) {
    const row = rows.get(id);
    assert.equal(row.request.url, origin + '/v1/image_generation', id);
    assert.equal(row.request.method, 'POST', id);
    assert.deepEqual(row.request.body, expectedBody, id);
    assert.deepEqual(row.result, results.get(id), id);
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.config.effectiveBaseUrl, origin, id);
    assert.equal(row.releaseCount, 1, id);
    assert.equal(row.request.releaseCount, 1, id);
    assert.deepEqual(row.request.headers, { authorization: 'Bearer synthetic-explicit-key', 'content-type': 'application/json',
      ...(id === 'source-only-configured-header' ? { 'x-fixture-render': 'normal' } : {}) }, id);
  }
});

test('both registered IDs retain complete independent descriptors, with shared actual registration and manifest provenance', () => {
  assert.deepEqual(capture.providerDescriptors, ['minimax', 'minimax-portal'].map(id => ({ id, label: 'MiniMax',
    defaultModel: 'image-01', models: ['image-01'], capabilities })));
  assert.deepEqual(capture.registrationProvenance, {
    executed: false, source: 'extensions/minimax/index.ts', sourceSha256: hash(readFileSync(join(root, 'extensions/minimax/index.ts'))),
    calls: ['api.registerImageGenerationProvider(buildMinimaxImageGenerationProvider());',
      'api.registerImageGenerationProvider(buildMinimaxImageGenerationProvider("minimax-portal"));'],
    manifest: 'extensions/minimax/openclaw.plugin.json', manifestSha256: hash(readFileSync(join(root, 'extensions/minimax/openclaw.plugin.json'))),
    manifestProviders: ['minimax', 'minimax-portal'], manifestImageGenerationProviders: ['minimax', 'minimax-portal'],
    limit: 'Both IDs register in the same minimax plugin; no separate minimax-portal index or manifest exists at this pin. Registration and plugin assembly do not execute.',
  });
  assert.equal(rows.get('portal-provider').providerId, 'minimax-portal');
  assert.equal(rows.get('portal-configured-cn-region').providerId, 'minimax-portal');
});

test('raw model whitespace/prefix and prompt are preserved; ordinary aspect ratios use JavaScript trim', () => {
  assert.equal(rows.get('explicit-model-prompt').request.body.model, ' Vendor/Image-X ');
  assert.equal(rows.get('minimax-prefixed-model').request.body.model, ' minimax/image-01 ');
  assert.equal(rows.get('aspect-js-trim').input.aspectRatio, '\uFEFF 16:9\u00a0');
  assert.equal(rows.get('aspect-js-trim').request.body.aspect_ratio, '16:9');
  assert.equal(rows.get('count-nine').request.body.n, 9);
  for (const row of capture.observations) {
    assert.ok((row.input.inputImages?.length ?? 0) <= 1, row.id);
    assert.ok(row.request.body.n >= 1 && row.request.body.n <= 9, row.id);
  }
});

test('single input bytes become character data URLs with raw MIME or default JPEG while filename stays input-only', () => {
  assert.deepEqual(rows.get('input-default-mime').request.body.subject_reference,
    [{ type: 'character', image_file: 'data:image/jpeg;base64,' + jpeg }]);
  const row = rows.get('input-raw-mime-filename-ignored');
  assert.deepEqual(row.input, { prompt, model: 'image-01', timeoutMs: 30000,
    inputImages: [{ bytesBase64: png, mimeType: ' Image/PNG; Mode=RGB ', fileName: ' 绘图/输入.png ' }] });
  assert.deepEqual(row.request.body.subject_reference,
    [{ type: 'character', image_file: 'data: Image/PNG; Mode=RGB ;base64,' + png }]);
  assert.equal(JSON.stringify(row.request.body).includes('绘图'), false);
});

test('whole canonicalizeBase64 normalizes padded, unpadded and whitespace successes; opaque bytes remain ordered PNG outputs', () => {
  assert.deepEqual(rows.get('ordered-opaque-results').result, {
    images: [image(jpeg), image(webp, 'image-2.png'), image(opaque, 'image-3.png'), image(png, 'image-4.png')], model: 'image-01',
  });
  for (const id of ['default-count', 'base64-unpadded', 'base64-whitespace', 'metadata-ignored']) {
    assert.deepEqual(rows.get(id).result, { images: [image()], model: 'image-01' }, id);
  }
  assert.deepEqual(rows.get('metadata-ignored').response.json, {
    data: { image_base64: [png], ignored: 'data metadata' },
    metadata: { success_count: 27, failed_count: 0, mime_type: 'image/jpeg' }, id: 'ignored-response-id',
    base_resp: { status_code: 0, status_msg: 'normal success' }, model: 'ignored-response-model', usage: { total_tokens: 42 },
  });
});

test('actual configured-cap and inline-cap functions always budget nine image results, honoring floor and larger cap', () => {
  for (const row of capture.observations) {
    const maxBytes = row.id === 'media-cap-larger' ? 1010827264 : 806354944;
    assert.equal(row.request.maxBytes, maxBytes, row.id);
    assert.deepEqual(row.readerCalls, [{ kind: 'json', label: 'minimax.image-generation', maxBytes, atMs: 100007 }], row.id);
    assert.deepEqual(row.statusCalls, [{ label: 'MiniMax image generation failed', options: null, atMs: 100007 }], row.id);
    assert.deepEqual(row.releaseCalls, [{ atMs: 100010, releaseCount: 1 }], row.id);
    assert.equal(row.request.atMs, 100000, row.id);
    assert.equal(row.request.releasedAtMs, 100010, row.id);
    assert.equal(row.clock.endMs, 100010, row.id);
    assert.equal(Object.hasOwn(row.request, 'timeoutMs'), row.id !== 'source-only-default-model-timeout', row.id);
    if (row.id !== 'source-only-default-model-timeout') assert.equal(row.request.timeoutMs, 30000, row.id);
  }
});

test('CN selection uses configured protocol region with empty frozen env; host mapping receives explicit effective root', () => {
  assert.deepEqual(capture.vmEnvironment, { processEnv: {}, frozen: true, hostEnvironmentRead: false });
  assert.equal(rows.get('configured-cn-region').config.baseUrl, ' https://api.minimaxi.com/anthropic ');
  assert.equal(rows.get('portal-configured-cn-region').config.baseUrl, 'https://api.minimaxi.com/v1');
  for (const id of ['configured-cn-region', 'portal-configured-cn-region']) {
    const row = rows.get(id);
    assert.equal(row.config.effectiveBaseUrl, 'https://api.minimaxi.com');
    assert.equal(row.configCalls[0].baseUrl, 'https://api.minimaxi.com');
    assert.equal(row.hostComparable, true);
  }
});

test('named config/credential/policy/sanitizer facades expose literal outputs with only two source-only rows', () => {
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 25);
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id),
    ['source-only-default-model-timeout', 'source-only-configured-header']);
  for (const row of capture.observations) {
    assert.equal(row.configCalls.length, 1, row.id);
    assert.equal(row.sanitizeCalls.length, 1, row.id);
    assert.deepEqual(row.keyCalls, [{ provider: row.providerId, implementation: 'literal-synthetic-credential-in-config-facade' }], row.id);
    const call = row.configCalls[0];
    assert.equal(call.provider, row.providerId, row.id);
    assert.equal(call.capability, 'image', row.id);
    assert.equal(call.defaultBaseUrl, base, row.id);
    assert.equal(call.jsonContentType, true, row.id);
    assert.equal(call.implementation, 'successful-explicit-credential-http-config-policy-facade', row.id);
    assert.deepEqual(call.output, { baseUrl: row.config.effectiveBaseUrl, headers: row.request.headers }, row.id);
    if (row.hostComparable) {
      assert.deepEqual(row.sanitizeCalls, [{ input: null, output: null, implementation: 'successful-configured-request-sanitizer-facade' }], row.id);
      assert.equal(call.request, null, row.id);
    } else assert.ok(row.adaptationReason);
  }
  assert.deepEqual(rows.get('source-only-configured-header').sanitizeCalls, [{
    input: { headers: { 'X-Fixture-Render': ' normal ' } }, output: { headers: { 'X-Fixture-Render': 'normal' } },
    implementation: 'successful-configured-request-sanitizer-facade',
  }]);
  assert.equal(capture.serviceFacadeLedger.length, 5);
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('unchanged whole modules, complete cap region and every generated binding reconstruct all source/executable hashes', () => {
  assert.equal(MINIMAX_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, MINIMAX_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/minimax/image-generation-provider.ts', 'extensions/minimax/media-provider-runtime.ts',
    'src/media-understanding/provider-json-post.ts', 'src/image-generation/image-assets.ts',
    'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
    'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/record-coerce.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path), ['src/media/configured-max-bytes.ts']);
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
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-minimax-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('all 58558 tracked blobs, modes and symlinks are verified before/after with accurate execution limits', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['Complete unchanged MiniMax', 'complete original configured-max-bytes', 'modes and symlinks',
    'Whole postJsonResponse', 'hostComparable=false', 'frozen empty', 'no multiple-input callback', 'Inactive independent source oracle']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
});

test('two fresh captures equal frozen JSON including all source, runtime and successful-service receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/minimax-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureMinimaxImageGeneration(root), fixture);
});
