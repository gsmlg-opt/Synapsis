// Independent handwritten ordinary-success expectations, separate from capture request/result logic.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMicrosoftFoundryImageGeneration, MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN } from './capture-microsoft-foundry-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureMicrosoftFoundryImageGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const model = 'MAI-Image-2.5';
const prompt = ' Draw a small blue square. ';
const endpoint = 'https://foundry.example.test';
const base = 'https://foundry.example.test/mai/v1';
const descriptor = { id: 'microsoft-foundry', label: 'Microsoft Foundry', defaultTimeoutMs: 600000, models: [],
  capabilities: { generate: { maxCount: 1, supportsSize: true },
    edit: { enabled: true, maxCount: 1, maxInputImages: 1, supportsSize: false }, output: { formats: ['png'] } } };
const json = (overrides = {}) => ({ model, prompt, width: 1024, height: 1024, ...overrides });
const image = (bytesBase64 = png, mimeType = 'image/png', fileName = 'microsoft-foundry-image-1.png', revisedPrompt) => ({
  mimeType, fileName, ...(revisedPrompt ? { revisedPrompt } : {}), bytesBase64,
});
const upload = (bytesBase64 = png, fileName = 'microsoft-foundry-input-1.png', mimeType = 'image/png', size = 68) => ({
  name: 'image', fileName, mimeType, size, bytesBase64,
});
const multipart = (file = upload(), selectedModel = model) => [
  { name: 'model', value: selectedModel }, { name: 'prompt', value: prompt }, file,
];
// All semantic expectations are literal plans, never derived from captured inputs or outputs.
const plans = [
  ['default-count-size', json()],
  ['explicit-count-one', json()],
  ['model-2.5-flash', json({ model: 'MAI-Image-2.5-flash' }), { model: 'MAI-Image-2.5-flash' }],
  ['model-2e', json({ model: 'MAI-Image-2e' }), { model: 'MAI-Image-2e' }],
  ['model-2', json({ model: 'MAI-Image-2' }), { model: 'MAI-Image-2' }],
  ['model-2-efficient', json({ model: 'MAI-Image-2-efficient' }), { model: 'MAI-Image-2-efficient' }],
  ['trimmed-model-prompt', json({ prompt: '  Preserve this exact prompt.\n' })],
  ['prefixed-model', json({ model: 'microsoft-foundry/Custom/Model' }), { model: 'microsoft-foundry/Custom/Model' }],
  ['custom-deployment-generation-metadata', json({ model: 'draw-prod' }), { model: 'draw-prod',
    config: { models: [{ id: 'draw-prod', name: 'MAI-Image-2e' }] } }],
  ['custom-deployment-generation-no-metadata', json({ model: 'draw-prod' }), { model: 'draw-prod' }],
  ['javascript-whitespace', json(), { config: { baseUrl: '\uFEFFhttps://foundry.example.test/openai/v1///\u00a0' } }],
  ['size-768', json({ width: 768, height: 768 })],
  ['size-768x1365', json({ width: 768, height: 1365 })],
  ['size-1365x768', json({ width: 1365, height: 768 })],
  ['size-800x1000', json({ width: 800, height: 1000 })],
  ['size-leading-zeros', json({ width: 768, height: 768 })],
  ['unused-options', json()],
  ['endpoint-openai-v1', json(), { config: { baseUrl: 'https://foundry.example.test/openai/v1/' } }],
  ['endpoint-anthropic', json(), { config: { baseUrl: 'https://foundry.example.test/anthropic/v1/' } }],
  ['endpoint-prefix', json(), { config: { baseUrl: 'https://foundry.example.test/resource/openai/v1/' }, baseUrl: 'https://foundry.example.test/resource/mai/v1' }],
  ['endpoint-query-trailing', json(), { config: { baseUrl: ' https://foundry.example.test/resource///?api-version=fixture#ordinary ' }, baseUrl: 'https://foundry.example.test/resource/mai/v1' }],
  ['endpoint-hostcase-defaultport', json(), { config: { baseUrl: 'https://FOUNDRY.EXAMPLE.TEST:443/openai/v1' } }],
  ['endpoint-existing-mai-v1', json(), { config: { baseUrl: 'https://foundry.example.test/mai/v1/' }, baseUrl: 'https://foundry.example.test/mai/v1/mai/v1' }],
  ['edit-default-png', multipart()],
  ['edit-flash', multipart(upload(), 'MAI-Image-2.5-flash'), { model: 'MAI-Image-2.5-flash' }],
  ['edit-jpeg', multipart(upload(jpeg, 'microsoft-foundry-input-1.jpg', 'image/jpeg', 10))],
  ['edit-jpg', multipart(upload(jpeg, 'microsoft-foundry-input-1.jpg', 'image/jpeg', 10))],
  ['edit-trimmed-name', multipart(upload(png, 'source.png'))],
  ['edit-path-name', multipart(upload(png, '绘图/输入.png'))],
  ['edit-custom-deployment-metadata', multipart(upload(), 'edit-prod'), { model: 'edit-prod', config: {
    models: [{ id: 'other-prod', name: 'MAI-Image-2' }, { id: 'edit-prod', name: ' MAI-Image-2.5-flash ' }] } }],
  ['edit-unused-size-options', multipart()],
  ['response-explicit-mime', json(), { image: image(jpeg, 'Image/WEBP; codec=fixture', 'microsoft-foundry-image-1.webp', 'Explicit') }],
  ['response-sniff-jpeg', json(), { image: image(jpeg, 'image/jpeg', 'microsoft-foundry-image-1.jpg', 'Revised ordinary prompt.') }],
  ['response-sniff-webp', json(), { image: image(webp, 'image/webp', 'microsoft-foundry-image-1.webp') }],
  ['response-png-fallback', json(), { image: image(opaque) }],
  ['base64-unpadded', json()],
  ['base64-whitespace', json()],
  ['media-cap-floor', json(), { config: { mediaMaxMb: 2.25 } }],
  ['media-cap-larger', json(), { config: { mediaMaxMb: 80.25 }, maxBytes: 113246208 }],
  ['source-only-default-timeout', json(), { timeoutMs: 600000 }],
  ['source-only-configured-header', json(), { config: { request: { headers: { 'X-Fixture-Render': ' normal ', 'Content-Type': 'text/plain' } } },
    header: true }],
];
const headersFromConfig = extra => ({ 'api-key': 'synthetic-explicit-key',
  ...(extra.header ? { 'content-type': 'text/plain', 'x-fixture-render': 'normal' } : {}) });
const cfgFor = extra => ({ models: { providers: { 'microsoft-foundry': {
  baseUrl: endpoint, ...(extra.config?.baseUrl ? { baseUrl: extra.config.baseUrl } : {}),
  ...(extra.config?.models ? { models: extra.config.models } : {}),
  ...(extra.config?.request ? { request: extra.config.request } : {}),
} } }, ...(extra.config?.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: extra.config.mediaMaxMb } } } : {}) });

test('41 independent full request/result plans cover every ordinary successful source callback', () => {
  assert.equal(plans.length, 41);
  assert.deepEqual([...rows.keys()], plans.map(([id]) => id));
  for (const [id, body, extra = {}] of plans) {
    const row = rows.get(id);
    const isMultipart = Array.isArray(body);
    const maxBytes = extra.maxBytes ?? 90527062;
    const request = { url: (extra.baseUrl ?? base) + '/images/' + (isMultipart ? 'edits' : 'generations'),
      method: 'POST', kind: isMultipart ? 'multipart' : 'json', body,
      ...(isMultipart ? { multipartBoundary: { rawHttpExecuted: false,
        format: 'ordered native FormData fields and exact Blob bytes/name/type; no generated HTTP boundary compared' } }
        : { rawBody: JSON.stringify(body), jsonBody: body }),
      headers: { 'api-key': 'synthetic-explicit-key', ...(!isMultipart ? { 'content-type': 'application/json' } : {}),
        ...(extra.header ? { 'x-fixture-render': 'normal' } : {}) },
      timeoutMs: extra.timeoutMs ?? 30000, atMs: 100000, releaseCount: 1, maxBytes, releasedAtMs: 100010 };
    assert.deepEqual(row.request, request, id + ' full request');
    assert.deepEqual(row.result, { images: [extra.image ?? image()], model: extra.model ?? model }, id + ' full result');
    assert.deepEqual(Object.keys(row.result), ['images', 'model'], id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.releaseCount, 1, id);
    assert.equal(row.result.images.length, 1, id);
  }
});

test('descriptor and source caps advertise one image, one edit input, size only for generations, PNG output', () => {
  assert.deepEqual(capture.providerDescriptor, descriptor);
  assert.equal(Object.hasOwn(capture.providerDescriptor, 'defaultModel'), false);
  for (const row of capture.observations) {
    assert.ok(row.input.count === undefined || row.input.count === 1, row.id);
    assert.ok((row.input.inputImages?.length ?? 0) <= 1, row.id);
  }
});

test('original source normalizes all ordinary endpoint shapes before config consumes the resolved base', () => {
  for (const [id, , extra = {}] of plans) {
    const row = rows.get(id);
    const baseUrl = extra.baseUrl ?? base;
    assert.deepEqual(row.configCalls, [{ provider: 'microsoft-foundry', capability: 'image', transport: 'http',
      baseUrl, defaultBaseUrl: baseUrl, allowPrivateNetwork: false,
      defaultHeaders: { 'api-key': 'synthetic-explicit-key' },
      request: extra.header ? { headers: { 'X-Fixture-Render': 'normal', 'Content-Type': 'text/plain' } } : null,
      output: { baseUrl, headers: headersFromConfig(extra), allowPrivateNetwork: false },
      implementation: 'successful-provider-http-request-config-facade' }], id);
    assert.deepEqual(row.keyCalls, [{ provider: 'microsoft-foundry', cfg: cfgFor(extra), agentDir: null, store: null,
      implementation: 'successful-explicit-synthetic-key-facade' }], id);
    assert.deepEqual(row.sanitizeCalls, [{
      input: extra.header ? { headers: { 'X-Fixture-Render': ' normal ', 'Content-Type': 'text/plain' } } : null,
      output: extra.header ? { headers: { 'X-Fixture-Render': 'normal', 'Content-Type': 'text/plain' } } : null,
      implementation: 'successful-configured-request-sanitizer-facade' }], id);
  }
});

test('native multipart uses ordered model/prompt/image, exact bytes/names and normalized PNG/JPEG/JPG MIME', () => {
  for (const [id, fields] of plans.filter(([, body]) => Array.isArray(body))) {
    assert.deepEqual(rows.get(id).request.body.map(part => part.name), ['model', 'prompt', 'image'], id);
    assert.deepEqual(rows.get(id).request.body, fields, id);
    assert.equal(Object.hasOwn(rows.get(id).request.headers, 'content-type'), false, id);
  }
  assert.deepEqual(rows.get('edit-unused-size-options').request.body, multipart());
  assert.deepEqual(rows.get('unused-options').request.body, json());
  assert.deepEqual(rows.get('size-leading-zeros').request.body, json({ width: 768, height: 768 }));
});

test('source model trim/prefix retention and metadata use deployment id for requests and results', () => {
  assert.deepEqual(rows.get('prefixed-model').request.body, json({ model: 'microsoft-foundry/Custom/Model' }));
  assert.deepEqual(rows.get('javascript-whitespace').request.body, json());
  assert.deepEqual(rows.get('trimmed-model-prompt').request.body, json({ prompt: '  Preserve this exact prompt.\n' }));
  assert.equal(rows.get('custom-deployment-generation-metadata').result.model, 'draw-prod');
  assert.equal(rows.get('edit-custom-deployment-metadata').result.model, 'edit-prod');
});

test('inline results sniff MIME, retain explicit MIME, trim revised prompts and canonicalize valid Base64', () => {
  assert.deepEqual(rows.get('response-sniff-jpeg').result, {
    images: [image(jpeg, 'image/jpeg', 'microsoft-foundry-image-1.jpg', 'Revised ordinary prompt.')], model });
  assert.deepEqual(rows.get('response-sniff-webp').result, {
    images: [image(webp, 'image/webp', 'microsoft-foundry-image-1.webp')], model });
  assert.deepEqual(rows.get('response-explicit-mime').result, {
    images: [image(jpeg, 'Image/WEBP; codec=fixture', 'microsoft-foundry-image-1.webp', 'Explicit')], model });
  for (const id of ['default-count-size', 'base64-unpadded', 'base64-whitespace'])
    assert.deepEqual(rows.get(id).result, { images: [image()], model }, id);
  assert.deepEqual(rows.get('response-png-fallback').result, { images: [image(opaque)], model });
});

test('real source deadline/cap helpers, original POST wrappers and try/finally produce complete success ledgers', () => {
  for (const [id, , extra = {}] of plans) {
    const row = rows.get(id);
    const maxBytes = extra.maxBytes ?? 90527062;
    assert.deepEqual(row.clock, { kind: 'synthetic-Date.now', startMs: 100000, endMs: 100010,
      serviceCostsMs: { post: 7, jsonRead: 3 } }, id);
    assert.deepEqual(row.statusCalls, [{ label: row.request.kind === 'multipart'
      ? 'Microsoft Foundry MAI image edit failed' : 'Microsoft Foundry MAI image generation failed',
      status: 200, atMs: 100007, implementation: 'successful-status-facade' }], id);
    assert.deepEqual(row.readerCalls, [{ kind: 'json', label: 'microsoft-foundry.image-generation', maxBytes,
      atMs: 100007, implementation: 'successful-native-response-json-facade' }], id);
    assert.deepEqual(row.capCalls, [{ maxBytes, atMs: 100007, implementation: 'source-inline-cap-parameter-observation' }], id);
    assert.deepEqual(row.releaseCalls, [{ releaseCount: 1, atMs: 100010 }], id);
    assert.deepEqual(row.guardCalls, [{ allowPrivateNetwork: false, ssrfPolicy: null, dispatcherPolicy: null,
      output: { allowPrivateNetwork: false }, implementation: 'successful-guarded-options-attribution-facade' }], id);
  }
});

test('two source-only rows retain explicit model/public base and record finite timeout or literal header consumption', () => {
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 39);
  assert.deepEqual(capture.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-default-timeout', 'source-only-configured-header',
  ]);
  assert.deepEqual(rows.get('source-only-default-timeout').input, { prompt, model });
  assert.equal(rows.get('source-only-default-timeout').request.timeoutMs, 600000);
  assert.equal(rows.get('source-only-configured-header').request.headers['content-type'], 'application/json');
  assert.equal(rows.get('source-only-configured-header').request.headers['x-fixture-render'], 'normal');
  assert.equal(capture.serviceFacadeLedger.length, 6);
  assert.ok(capture.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('all whole-source, source-region, import, runtime, exporter and harness hashes reconstruct independently', () => {
  assert.equal(MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN);
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(executed.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/microsoft-foundry/image-generation-provider.ts', 'src/image-generation/image-assets.ts',
    'src/plugin-sdk/blob-runtime.ts', 'src/plugin-sdk/expect-runtime.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  ].sort());
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(), [
    'extensions/microsoft-foundry/shared.ts', 'src/media/configured-max-bytes.ts',
    'src/media-understanding/shared.ts', 'src/media-understanding/shared.ts',
  ].sort());
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let original = bytes.toString();
    if (!row.wholeModule) {
      const p = row.projection;
      const selected = p.regions.map(region => {
        const bytesInRegion = bytes.subarray(region.startByte, region.endByte);
        assert.equal(hash(bytesInRegion), region.sourceRegionSha256, row.path);
        return bytesInRegion.toString();
      });
      original = p.prelude + '\n' + selected.join('\n');
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
  const foundry = executed.find(row => row.path === 'extensions/microsoft-foundry/shared.ts');
  const sharedBytes = readFileSync(join(root, foundry.path));
  assert.deepEqual(foundry.projection.regions.map(region => [region.startByte, region.endByte]), [
    [sharedBytes.indexOf('export const PROVIDER_ID ='), sharedBytes.indexOf('export const DEFAULT_GPT5_API =')],
    [sharedBytes.indexOf('export function isFoundryMaiImageModel('), sharedBytes.indexOf('function supportsFoundryReasoningContent(')],
    [sharedBytes.indexOf('export function normalizeFoundryEndpoint('), sharedBytes.indexOf('export function resolveFoundryApi(')],
    [sharedBytes.indexOf('export function extractFoundryEndpoint('), sharedBytes.indexOf('export function resolveFoundryModelCapabilities(')],
  ]);
  const sharedProjections = executed.filter(row => row.path === 'src/media-understanding/shared.ts');
  const httpBytes = readFileSync(join(root, 'src/media-understanding/shared.ts'));
  assert.deepEqual(sharedProjections.map(row => row.projection.regions).flat().map(region => [region.startByte, region.endByte]).sort((a, b) => a[0] - b[0]), [
    [httpBytes.indexOf('export function createProviderOperationDeadline('), httpBytes.indexOf('/** Resolves a static or lazy request timeout')],
    [httpBytes.indexOf('type GuardedPostRequestRetryOptions ='), httpBytes.indexOf('// Keep the shipped transcription name')],
  ]);
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-microsoft-foundry-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.deepEqual(capture.dynamicImports, []);
});

test('complete pinned tree receipts distinguish executed image helpers from registration and service provenance', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const path of ['extensions/microsoft-foundry/index.ts', 'extensions/microsoft-foundry/openclaw.plugin.json',
    'extensions/microsoft-foundry/runtime.ts', 'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts']) {
    assert.deepEqual(capture.sourceRecords.find(row => row.path === path), {
      path, sha256: hash(readFileSync(join(root, path))), executed: false, provenanceOnly: true,
    });
  }
  for (const text of ['Complete unchanged 295-line Microsoft Foundry', 'complete original cap/deadline/HTTP-wrapper',
    'modes and symlinks', 'FormData and Blob', 'bounded stream reading', 'hostComparable=false',
    'Credentials/env/runtime-auth', 'Inactive independent source oracle'])
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
});

test('two fresh captures equal final frozen JSON with all source/runtime/request/result/service receipts', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/microsoft-foundry-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureMicrosoftFoundryImageGeneration(root), fixture);
});
