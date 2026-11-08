// Independent ordinary-success literal wire/result expectations for complete pinned OpenRouter source.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenrouterImageGeneration, OPENROUTER_IMAGE_GENERATION_PIN } from './capture-openrouter-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureOpenrouterImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const prompt = ' Draw a small blue square. ';
const model = 'google/gemini-3.1-flash-image-preview';
const base = 'https://openrouter.ai/api/v1';
const custom = 'https://images.example.com/v1';
const image = (bytesBase64 = png, fileName = 'image-1.png', mimeType = 'image/png', revisedPrompt) => ({ mimeType, fileName, ...(revisedPrompt ? { revisedPrompt } : {}), bytesBase64 });
// Expectations are handwritten independently of exporter vectors and captured input/result values.
const dedicated = (extra = {}) => ({ model, prompt, n: 1, ...extra });
const chat = (extra = {}) => ({ model, messages: [{ role: 'user', content: prompt }], modalities: ['image', 'text'], n: 1, ...extra });
const refs = [
  { type: 'image_url', image_url: { url: 'data:image/png;base64,' + jpeg } },
  { type: 'image_url', image_url: { url: 'data:Image/PNG; Mode=RGB;base64,' + png } },
  { type: 'image_url', image_url: { url: 'data:image/webp;base64,' + webp } },
  { type: 'image_url', image_url: { url: 'data:image/png;base64,' + opaque } },
  { type: 'image_url', image_url: { url: 'data:image/png;base64,' + png } },
];
const plans = [
  ['default-count', [dedicated()]],
  ['canonical-trailing-slashes', [dedicated()]],
  ['legacy-root', [dedicated()]],
  ['legacy-js-trim', [dedicated()]],
  ['canonical-js-trim', [dedicated()]],
  ['model-prompt-js-trim', [dedicated({ model: 'google/gemini-3-pro-image-preview', prompt: '  Preserve this exact prompt.\n' })]],
  ['prefixed-model-geometry-ignored', [dedicated({ model: 'openrouter/google/gemini-3-pro-image-preview' })]],
  ['non-gemini-geometry-ignored', [dedicated({ model: 'openai/gpt-5.4-image-2' })]],
  ['dedicated-four-reverse-completion', [dedicated(), dedicated(), dedicated(), dedicated()]],
  ['custom-chat-count-four', [chat({ n: 4 })], custom],
  ['aspect-1-1', [dedicated({ aspect_ratio: '1:1' })]],
  ['aspect-2-3', [dedicated({ aspect_ratio: '2:3' })]],
  ['aspect-3-2', [dedicated({ aspect_ratio: '3:2' })]],
  ['aspect-3-4', [dedicated({ aspect_ratio: '3:4' })]],
  ['aspect-4-3', [dedicated({ aspect_ratio: '4:3' })]],
  ['aspect-4-5', [dedicated({ aspect_ratio: '4:5' })]],
  ['aspect-5-4', [dedicated({ aspect_ratio: '5:4' })]],
  ['aspect-9-16', [dedicated({ aspect_ratio: '9:16' })]],
  ['aspect-16-9', [dedicated({ aspect_ratio: '16:9' })]],
  ['aspect-21-9', [dedicated({ aspect_ratio: '21:9' })]],
  ['resolution-1K', [dedicated({ resolution: '1K' })]],
  ['resolution-2K', [dedicated({ resolution: '2K' })]],
  ['resolution-4K', [dedicated({ resolution: '4K' })]],
  ['chat-gemini-trimmed-geometry', [chat({ image_config: { aspect_ratio: '16:9', image_size: '4K' } })], custom],
  ['input-one-default-png', [dedicated({ input_references: [refs[0]] })]],
  ['input-five-raw-bytes-mime-name', [dedicated({ input_references: refs })]],
  ['chat-input-five', [chat({ messages: [{ role: 'user', content: [{ type: 'text', text: prompt }, ...refs] }] })], custom],
  ['dedicated-sniff-and-explicit-mime', [dedicated()]],
  ['dedicated-media-type-alias-precedence', [dedicated()]],
  ['chat-message-images-then-content-string', [chat()], custom],
  ['chat-content-array-image-url-variants', [chat()], custom],
  ['chat-base64-and-inline-variants', [chat()], custom],
  ['chat-valid-precedence', [chat()], custom],
  ['chat-choice-order-contiguous-filenames', [chat()], custom],
  ['base64-unpadded', [dedicated()]],
  ['base64-whitespace', [dedicated()]],
  ['chat-data-url-case-parameters', [chat()], custom],
  ['media-cap-floor', [dedicated()]],
  ['media-cap-larger-chat-four', [chat({ n: 4 })], custom],
  ['source-only-default-model-timeout', [dedicated()]],
  ['source-only-configured-header', [dedicated()]],
];
const expectedResults = new Map(plans.map(([id]) => [id, { images: [image()], model }]));
expectedResults.set('model-prompt-js-trim', { images: [image()], model: 'google/gemini-3-pro-image-preview' });
expectedResults.set('prefixed-model-geometry-ignored', { images: [image()], model: 'openrouter/google/gemini-3-pro-image-preview' });
expectedResults.set('non-gemini-geometry-ignored', { images: [image()], model: 'openai/gpt-5.4-image-2' });
expectedResults.set('dedicated-four-reverse-completion', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(), image(webp, 'image-1.webp', 'image/webp'), image(opaque)], model });
expectedResults.set('custom-chat-count-four', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(png, 'image-2.png'), image(webp, 'image-3.webp', 'image/webp'), image(opaque, 'image-4.png')], model });
expectedResults.set('dedicated-sniff-and-explicit-mime', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(png, 'image-2.png'), image(webp, 'image-3.webp', 'image/webp'), image(jpeg, 'image-4.png', 'Image/PNG; charset=binary', 'Revised prompt.')], model });
expectedResults.set('dedicated-media-type-alias-precedence', { images: [image(jpeg, 'image-1.webp', 'image/webp', 'Alias prompt'), image(webp, 'image-2.jpg', 'image/jpeg')], model });
expectedResults.set('chat-message-images-then-content-string', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(png, 'image-2.png'), image(webp, 'image-3.webp', 'image/webp')], model });
expectedResults.set('chat-content-array-image-url-variants', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(png, 'image-2.png')], model });
expectedResults.set('chat-base64-and-inline-variants', { images: [image(jpeg), image(webp, 'image-2.webp', 'image/webp'), image(jpeg, 'image-3.jpg', 'image/jpeg'), image(png, 'image-4.png')], model });
expectedResults.set('chat-valid-precedence', { images: [image(), image(webp, 'image-2.webp', 'image/webp'), image(jpeg, 'image-3.png'), image(jpeg, 'image-4.jpg', 'image/jpeg')], model });
expectedResults.set('chat-choice-order-contiguous-filenames', { images: [image(jpeg, 'image-1.jpg', 'image/jpeg'), image(png, 'image-2.png'), image(webp, 'image-3.webp', 'image/webp'), image(opaque, 'image-4.png')], model });
expectedResults.set('chat-data-url-case-parameters', { images: [image(png, 'image-1.png', 'Image/PNG')], model });

const rawHeaders = { authorization: 'Bearer synthetic-explicit-key' };
const wireHeaders = { ...rawHeaders, 'content-type': 'text/plain;charset=UTF-8' };
const capabilities = {
  generate: { maxCount: 4, supportsSize: false, supportsAspectRatio: true, supportsResolution: true },
  edit: { enabled: true, maxCount: 4, maxInputImages: 5, supportsSize: false, supportsAspectRatio: true, supportsResolution: true },
  geometry: { aspectRatios: ['1:1','2:3','3:2','3:4','4:3','4:5','5:4','9:16','16:9','21:9'], resolutions: ['1K','2K','4K'] },
};

test('41 full-source successful observations match complete independent literal request arrays and results', () => {
  assert.equal(plans.length, 41);
  assert.deepEqual(capture.observations.map(row => row.id), plans.map(([id]) => id));
  for (const [id, bodies, origin = base] of plans) {
    const row = rows.get(id);
    const extraHeaders = id === 'source-only-configured-header' ? { 'x-fixture-render': 'normal' } : {};
    const maxBytes = origin === base ? 90527062 : id === 'media-cap-larger-chat-four' ? 898629632 : id === 'custom-chat-count-four' ? 716876459 : 180005547;
    assert.deepEqual(row.requests, bodies.map((body, ordinal) => ({ ordinal, url: origin + (origin === base ? '/images' : '/chat/completions'), method: 'POST', body,
      rawBody: JSON.stringify(body), headers: { ...rawHeaders, ...extraHeaders }, wireHeaders: { ...wireHeaders, ...extraHeaders },
      timeoutMs: id === 'source-only-default-model-timeout' ? 180000 : 30000, releaseCount: 1, maxBytes })), id);
    assert.deepEqual(row.result, expectedResults.get(id), id);
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.providerId, 'openrouter', id);
    assert.equal(row.responses.length, bodies.length, id);
  }
});

test('complete descriptor and original registration/manifest provenance stay independent of plugin execution', () => {
  assert.deepEqual(capture.providerDescriptors, [{ id: 'openrouter', label: 'OpenRouter', defaultModel: model,
    models: [model, 'google/gemini-3-pro-image-preview', 'openai/gpt-5.4-image-2'], capabilities }]);
  assert.deepEqual(capture.registrationProvenance, { executed: false, source: 'extensions/openrouter/index.ts',
    sourceSha256: hash(readFileSync(join(root, 'extensions/openrouter/index.ts'))),
    calls: ['api.registerImageGenerationProvider(buildOpenRouterImageGenerationProvider());'],
    manifest: 'extensions/openrouter/openclaw.plugin.json', manifestSha256: hash(readFileSync(join(root, 'extensions/openrouter/openclaw.plugin.json'))),
    manifestProviders: ['openrouter'], manifestImageGenerationProviders: ['openrouter'],
    limit: 'Actual OpenRouter registration call and manifest verified as provenance only; plugin assembly does not execute.' });
});

test('official roots and legacy roots use dedicated images while public custom bases use full chat', () => {
  for (const id of ['default-count','canonical-trailing-slashes','legacy-root','legacy-js-trim','canonical-js-trim']) assert.equal(rows.get(id).requests[0].url, base + '/images', id);
  assert.equal(rows.get('legacy-js-trim').inputAfter.model, model);
  assert.equal(rows.get('canonical-js-trim').config.baseUrl, '\uFEFF ' + base + '/\u00a0');
  assert.equal(rows.get('legacy-js-trim').config.baseUrl, '\uFEFF https://openrouter.ai/v1///\u00a0');
  assert.deepEqual(rows.get('custom-chat-count-four').requests[0].body, chat({ n: 4 }));
  assert.deepEqual(rows.get('dedicated-four-reverse-completion').fixtureControl, { kind: 'successful-responses-in-explicit-completion-order', completionOrder: [3,2,1,0] });
  const row = rows.get('dedicated-four-reverse-completion');
  assert.deepEqual(row.requests.map(request => request.ordinal), [0,1,2,3]);
  assert.deepEqual(row.completionOrder, [3,2,1,0]);
  assert.deepEqual(row.releaseCalls, [3,2,1,0].map(ordinal => ({ ordinal, releaseCount: 1 })));
  assert.deepEqual(row.result.images.map(result => result.fileName), ['image-1.jpg','image-1.png','image-1.webp','image-1.png']);
});

test('model and geometry trim uses source JavaScript semantics and geometry is Gemini-prefix-only', () => {
  assert.equal(rows.get('model-prompt-js-trim').input.model, '\uFEFF google/gemini-3-pro-image-preview\u00a0');
  assert.equal(rows.get('model-prompt-js-trim').result.model, 'google/gemini-3-pro-image-preview');
  assert.equal(rows.get('model-prompt-js-trim').requests[0].body.prompt, '  Preserve this exact prompt.\n');
  assert.deepEqual(rows.get('chat-gemini-trimmed-geometry').requests[0].body.image_config, { aspect_ratio: '16:9', image_size: '4K' });
  for (const id of ['prefixed-model-geometry-ignored','non-gemini-geometry-ignored']) {
    assert.equal(Object.hasOwn(rows.get(id).requests[0].body, 'aspect_ratio'), false);
    assert.equal(Object.hasOwn(rows.get(id).requests[0].body, 'resolution'), false);
    assert.equal(Object.hasOwn(rows.get(id).requests[0].body, 'size'), false);
  }
});

test('one and five references preserve all raw bytes, trim MIME, default PNG, and omit names in both routes', () => {
  assert.deepEqual(rows.get('input-one-default-png').requests[0].body.input_references, [refs[0]]);
  assert.deepEqual(rows.get('input-five-raw-bytes-mime-name').requests[0].body.input_references, refs);
  assert.deepEqual(rows.get('chat-input-five').requests[0].body.messages[0].content, [{ type: 'text', text: prompt }, ...refs]);
  for (const id of ['input-five-raw-bytes-mime-name','chat-input-five']) {
    const row = rows.get(id); assert.equal(row.input.inputImages.length, 5);
    assert.equal(row.input.inputImages[1].fileName, ' 绘图/输入.png ');
    assert.equal(row.requests[0].rawBody.includes('绘图'), false);
  }
});

test('dedicated MIME sniff/explicit/alias and full chat paths preserve distinct MIME/name/order behavior', () => {
  for (const id of ['dedicated-sniff-and-explicit-mime','dedicated-media-type-alias-precedence','chat-message-images-then-content-string',
    'chat-content-array-image-url-variants','chat-base64-and-inline-variants','chat-valid-precedence','chat-choice-order-contiguous-filenames',
    'base64-unpadded','base64-whitespace','chat-data-url-case-parameters']) assert.deepEqual(rows.get(id).result, expectedResults.get(id), id);
  // Chat bare Base64 does not sniff JPEG, whereas dedicated bare Base64 does.
  assert.deepEqual(rows.get('chat-base64-and-inline-variants').result.images[0], image(jpeg));
  assert.deepEqual(rows.get('dedicated-sniff-and-explicit-mime').result.images[0], image(jpeg, 'image-1.jpg', 'image/jpeg'));
  assert.deepEqual(rows.get('chat-choice-order-contiguous-filenames').result.images.map(result => result.fileName), ['image-1.jpg','image-2.png','image-3.webp','image-4.png']);
});

test('real postJsonRequest serialization and native Request expose raw versus effective content type without fabrication', () => {
  for (const row of capture.observations) {
    assert.equal(row.configCalls[0].jsonContentType, false, row.id);
    for (const request of row.requests) {
      assert.equal(Object.hasOwn(request.headers, 'content-type'), false, row.id);
      assert.equal(request.wireHeaders['content-type'], 'text/plain;charset=UTF-8', row.id);
      assert.equal(request.rawBody, JSON.stringify(request.body), row.id);
    }
  }
  const sharedRegion = capture.sourceRecords.find(row => row.path === 'src/media-understanding/shared.ts');
  assert.ok(sharedRegion.projection.generatedCode.includes('body: JSON.stringify(params.body)'));
  assert.ok(sharedRegion.projection.generatedCode.includes('headers: params.headers'));
  assert.equal(sharedRegion.projection.generatedCode.includes('application/json'), false);
  assert.ok(capture.limits.some(limit => limit.includes('source-comment discrepancy')));
});

test('source JSON cap arguments, all reader/status/release receipts, and no GET stay exact for success', () => {
  for (const [id, bodies, origin = base] of plans) {
    const row = rows.get(id);
    const completion = id === 'dedicated-four-reverse-completion' ? [3,2,1,0] : [0];
    const maxBytes = origin === base ? 90527062 : id === 'media-cap-larger-chat-four' ? 898629632 : id === 'custom-chat-count-four' ? 716876459 : 180005547;
    assert.deepEqual(row.completionOrder, completion, id);
    assert.deepEqual(row.releaseCalls, completion.map(ordinal => ({ ordinal, releaseCount: 1 })), id);
    assert.deepEqual(row.readerCalls, completion.map(ordinal => ({ ordinal, kind: 'json', label: 'openrouter.image-generation', maxBytes })), id);
    assert.deepEqual(row.statusCalls, completion.map(ordinal => ({ ordinal, label: 'OpenRouter image generation failed', options: null })), id);
    assert.deepEqual(row.guardCalls, bodies.map(() => ({ allowPrivateNetwork: false, implementation: 'successful-public-guard-options-facade', output: { allowPrivateNetwork: false } })), id);
    assert.ok(row.requests.every(request => request.method === 'POST'));
    assert.ok((row.input.inputImages?.length ?? 0) <= 5);
    assert.ok(row.result.images.length >= 1 && row.result.images.length <= 4);
    assert.ok(row.requests.length >= 1 && row.requests.length <= 4);
  }
});

test('named config/key/sanitizer/policy boundaries and exactly two source-only rows are explicit', () => {
  assert.deepEqual(capture.vmEnvironment, { processEnv: {}, frozen: true, hostEnvironmentRead: false });
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 39);
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), ['source-only-default-model-timeout','source-only-configured-header']);
  for (const row of capture.observations) {
    assert.deepEqual(row.keyCalls, [{ provider: 'openrouter', implementation: 'literal-synthetic-credential-in-config-facade' }], row.id);
    assert.equal(row.configCalls.length, 1, row.id); assert.equal(row.sanitizeCalls.length, 1, row.id);
    const call = row.configCalls[0];
    const expectedBase = row.id === 'legacy-root' || row.id === 'legacy-js-trim' ? 'https://openrouter.ai/v1' : plans.find(([id]) => id === row.id)[2] ?? base;
    assert.equal(call.output.baseUrl, expectedBase, row.id);
    assert.equal(call.provider, 'openrouter', row.id); assert.equal(call.capability, 'image', row.id);
    assert.equal(call.defaultBaseUrl, base, row.id); assert.equal(call.missingApiKeyMessage, 'OpenRouter API key missing', row.id);
    assert.equal(call.implementation, 'successful-explicit-credential-http-config-policy-facade', row.id);
    if (row.hostComparable) { assert.deepEqual(row.sanitizeCalls, [{ input: null, output: null, implementation: 'successful-configured-request-sanitizer-facade' }], row.id); assert.equal(call.request, null, row.id); }
    else assert.ok(row.adaptationReason);
  }
  assert.deepEqual(rows.get('source-only-configured-header').sanitizeCalls, [{ input: { headers: { 'X-Fixture-Render': ' normal ' } }, output: { headers: { 'X-Fixture-Render': 'normal' } }, implementation: 'successful-configured-request-sanitizer-facade' }]);
  assert.equal(capture.serviceFacadeLedger.length, 6);
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('whole modules, all three complete original regions and every generated import reconstruct source hashes', () => {
  assert.equal(OPENROUTER_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, OPENROUTER_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/openrouter/image-generation-provider.ts','extensions/openrouter/generation-request-context.ts','extensions/openrouter/provider-defaults.ts',
    'src/media-understanding/provider-json-post.ts','src/image-generation/image-assets.ts',
    'packages/media-core/src/base64.ts','packages/media-core/src/constants.ts',
    'packages/normalization-core/src/number-coercion.ts','packages/normalization-core/src/string-coerce.ts','packages/normalization-core/src/record-coerce.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(), ['extensions/openrouter/provider-catalog.ts','src/media/configured-max-bytes.ts','src/media-understanding/shared.ts'].sort());
  const markers = {
    'extensions/openrouter/provider-catalog.ts': ['const OPENROUTER_LEGACY_BASE_URL','export function resolveOpenRouterApiBaseUrl'],
    'src/media/configured-max-bytes.ts': ['const MB = 1024 * 1024;','/** Reads channel/account media caps'],
    'src/media-understanding/shared.ts': ['type GuardedPostRequestRetryOptions =','// Keep the shipped transcription name'],
  };
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) continue;
    let original = bytes.toString();
    if (!row.wholeModule) {
      const p = row.projection; const selected = bytes.subarray(p.startByte, p.endByte);
      const [start, end] = markers[row.path];
      assert.equal(p.startByte, bytes.indexOf(start), row.path);
      assert.equal(p.endByte, bytes.indexOf(end, p.startByte), row.path);
      assert.equal(hash(selected), p.sourceRegionSha256, row.path);
      original = p.prelude + '\n' + selected.toString();
      assert.equal(original, p.generatedCode, row.path); assert.equal(hash(original), p.generatedSha256, row.path);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
    if (binding.origin) assert.equal(hash(readFileSync(join(root, binding.origin))), binding.originSha256);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-openrouter-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('all 58558 tracked blobs, modes and symlinks are verified before/after and execution limits remain explicit', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.equal(capture.sourceTree.before.commit, OPENROUTER_IMAGE_GENERATION_PIN);
  assert.match(capture.sourceTree.before.tree, /^[a-f0-9]{40}$/);
  assert.match(capture.sourceTree.before.filesSha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const term of ['Whole unchanged OpenRouter','complete POST region','modes and symlinks','Promise.all preserves invocation order',
    'native Request','hostComparable=false','frozen empty','at most five input references','Inactive independent reference oracle']) assert.ok(capture.limits.some(limit => limit.includes(term)), term);
});

test('two fresh captures equal frozen JSON including all source/runtime/request/release receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openrouter-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureOpenrouterImageGeneration(root), fixture);
});
