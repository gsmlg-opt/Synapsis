// Literal ordinary-success qualification of pinned Google music and actual pinned SDK conversion.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureGoogleMusicGeneration } from './capture-google-music-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureGoogleMusicGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const clip = 'lyria-3-clip-preview', pro = 'lyria-3-pro-preview';
const prompt = 'Morning melody 歌 😀';
const ordinaryTrack = { mimeType: 'audio/mpeg', fileName: 'track-1.mp3', bytesBase64: 'AP+A' };
const ordinaryMetadata = { inputImageCount: 0, instrumental: false };
const tenReferences = ['AP8=', 'Af4=', 'Av0=', 'A/w=', 'BPs=', 'Bfo=', 'Bvk=', 'B/g=', 'CPc=', 'CfY=']
  .map(data => ({ inlineData: { mimeType: 'image/png', data } }));
// Expected contracts are explicit literals, independent of capture-vector and source helpers.
const cases = [
  ['clip-default', {}],
  ['source-default-timeout', { timeout: 180000 }],
  ['blank-model-and-lyrics', {}],
  ['pro-wav', { model: pro, tracks: [{ mimeType: 'Audio/WAVE; codecs=pcm', fileName: 'track-1.wav', bytesBase64: 'AP+A' }],
    metadata: { ...ordinaryMetadata, requestedFormat: 'wav' } }],
  ['pro-mp3', { model: pro, metadata: { ...ordinaryMetadata, requestedFormat: 'mp3' } }],
  ['models-resource-name', { model: 'models/' + pro, resource: 'models/' + pro,
    tracks: [{ mimeType: 'audio/vendor-unknown', fileName: 'track-1.mp3', bytesBase64: 'AP+A' }],
    metadata: { ...ordinaryMetadata, requestedFormat: 'mp3' } }],
  ['tunedModels-resource-name', { model: 'tunedModels/custom-music', resource: 'tunedModels/custom-music' }],
  ['provider-prefix-preserved', { model: 'google/' + pro,
    tracks: [{ mimeType: 'audio/vendor-unknown', fileName: 'track-1.mp3', bytesBase64: 'AP+A' }] }],
  ['unknown-pro-mime-wav', { model: pro, tracks: [{ mimeType: 'audio/vendor-unknown', fileName: 'track-1.wav', bytesBase64: 'AP+A' }] }],
  ['instrumental-with-lyrics', { text: 'Compose 雪 😀\n\nInstrumental only. No vocals, no sung lyrics, no spoken word.\n\nLyrics:\nVerse one\n第二行 😀',
    metadata: { inputImageCount: 0, instrumental: true, requestedLyrics: true, requestedFormat: 'mp3' } }],
  ['image-default-mime', { references: [{ inlineData: { mimeType: 'image/png', data: 'AP+A' } }],
    metadata: { inputImageCount: 1, instrumental: false } }],
  ['ordered-image-inputs', { references: [{ inlineData: { mimeType: 'Image/JPEG; source=fixture', data: 'AAEC/w==' } },
    { inlineData: { mimeType: 'image/png', data: 'ECA=' } }], metadata: { inputImageCount: 2, instrumental: false } }],
  ['ten-image-inputs', { references: tenReferences, metadata: { inputImageCount: 10, instrumental: false } }],
  ['all-candidate-text-media-order', { tracks: [
    { mimeType: 'Audio/FLAC; mode=fixture', fileName: 'track-1.flac', bytesBase64: 'Ag==' },
    { mimeType: 'AUDIO/WAV', fileName: 'track-2.wav', bytesBase64: 'Aw==' },
    { mimeType: 'audio/ogg', fileName: 'track-3.ogg', bytesBase64: 'BA==' },
    { mimeType: 'audio/x-m4a', fileName: 'track-4.m4a', bytesBase64: 'BQ==' },
  ], lyrics: ['First lyric 雪 😀', 'Second lyric\n歌'] }],
  ['camel-empty-inline-suppresses-snake', { lyrics: ['普通 text'] }],
  ['base64-standard-url-safe-variants', { tracks: [
    { mimeType: 'audio/mpeg', fileName: 'track-1.mp3', bytesBase64: 'AQ==' },
    { mimeType: 'audio/mpeg', fileName: 'track-2.mp3', bytesBase64: 'Ag==' },
    { mimeType: 'audio/mpeg', fileName: 'track-3.mp3', bytesBase64: '+/8=' },
    { mimeType: 'audio/mpeg', fileName: 'track-4.mp3', bytesBase64: '+/8=' },
    { mimeType: 'audio/mpeg', fileName: 'track-5.mp3', bytesBase64: 'AP+A' },
  ] }],
  ['default-mime-and-raw-alias', { tracks: [
    { mimeType: 'audio/mpeg', fileName: 'track-1.mp3', bytesBase64: 'AQ==' },
    { mimeType: 'AUDIO/X-WAV; source=fixture', fileName: 'track-2.wav', bytesBase64: 'Ag==' },
  ] }],
  ['official-openai-base-normalization', { baseUrl: 'https://generativelanguage.googleapis.com' }],
  ['custom-versioned-base', { baseUrl: 'https://relay.example.test/prefix' }],
  ['duration-unused', {}],
];

test('complete Clip and Pro descriptor keeps generate and ten-reference edit capabilities', () => {
  const mode = { maxTracks: 1, supportsLyrics: true, supportsInstrumental: true, supportsFormat: true,
    supportedFormatsByModel: { [clip]: ['mp3'], [pro]: ['mp3', 'wav'] } };
  assert.deepEqual(capture.provider, { id: 'google', label: 'Google', defaultModel: clip, models: [clip, pro],
    capabilities: { generate: mode, edit: { enabled: true, ...mode, maxInputImages: 10 } } });
});

test('20 first-audio-success callbacks execute exact SDK REST serialization and complete source results', () => {
  assert.deepEqual(capture.observations.map(row => row.id), cases.map(row => row[0]));
  for (const [id, expected] of cases) {
    const row = rows.get(id), model = expected.model ?? clip, timeout = expected.timeout ?? 12345;
    const body = { contents: [{ parts: [{ text: expected.text ?? prompt }, ...(expected.references ?? [])], role: 'user' }],
      generationConfig: { responseModalities: ['AUDIO', 'TEXT'] } };
    const resource = expected.resource ?? 'models/' + model;
    const baseUrl = expected.baseUrl ?? 'https://generativelanguage.googleapis.com';
    assert.deepEqual(row.requests, [{ url: `${baseUrl}/v1beta/${resource}:generateContent`, method: 'POST',
      headers: { 'content-type': 'application/json', 'user-agent': 'google-genai-sdk/2.28.0 gl-node/v24.22.1',
        'x-goog-api-client': 'google-genai-sdk/2.28.0 gl-node/v24.22.1', 'x-goog-api-key': 'synthetic-google-fixture-key',
        'x-server-timeout': timeout === 180000 ? '180' : '13' }, rawBody: JSON.stringify(body), body, signalProvided: true }], id);
    assert.deepEqual(row.result, { tracks: expected.tracks ?? [ordinaryTrack], ...(expected.lyrics ? { lyrics: expected.lyrics } : {}),
      model, metadata: expected.metadata ?? ordinaryMetadata }, id);
    assert.deepEqual(row.sdkOptions, [{ apiKey: 'synthetic-google-fixture-key', httpOptions: {
      ...(expected.baseUrl ? { baseUrl: expected.baseUrl } : {}), timeout, headers: {} } }], id);
    assert.deepEqual(row.responseReads, { json: 1, text: 0 }, id);
    assert.deepEqual(row.sdkJsonInput, row.response, id);
    assert.deepEqual(row.inputAfter, row.input, id);
  }
});

test('actual SDK preserves prompt-first ordered binary reference parts and source ignores input filenames', () => {
  const ordered = rows.get('ordered-image-inputs');
  assert.deepEqual(ordered.requests[0].body.contents, [{ parts: [{ text: prompt },
    { inlineData: { mimeType: 'Image/JPEG; source=fixture', data: 'AAEC/w==' } },
    { inlineData: { mimeType: 'image/png', data: 'ECA=' } }], role: 'user' }]);
  assert.equal(ordered.input.inputImages[0].fileName, 'ignored-one.jpg');
  assert.equal(ordered.requests[0].rawBody.includes('ignored-one.jpg'), false);
  assert.deepEqual(ordered.input.inputImages.map(row => Buffer.from(row.bytesBase64, 'base64')),
    [Buffer.from([0, 1, 2, 255]), Buffer.from([16, 32])]);
  assert.deepEqual(rows.get('ten-image-inputs').requests[0].body.contents[0].parts,
    [{ text: prompt }, ...tenReferences]);
  assert.equal(rows.get('ten-image-inputs').result.metadata.inputImageCount, 10);
});

test('all candidate text/media order and nullish inline precedence survive actual SDK response conversion', () => {
  const all = rows.get('all-candidate-text-media-order');
  assert.equal(all.response.candidates.length, 2);
  assert.equal(all.response.candidates[0].content.parts[0].inlineData.data, 'AQ==');
  assert.deepEqual(all.result.lyrics, ['First lyric 雪 😀', 'Second lyric\n歌']);
  assert.deepEqual(all.result.tracks.map(row => row.bytesBase64), ['Ag==', 'Aw==', 'BA==', 'BQ==']);
  assert.equal(all.result.tracks.length, 4);
  assert.equal(Object.hasOwn(all.result, 'usageMetadata'), false);
  assert.equal(Object.hasOwn(all.result, 'modelVersion'), false);
  assert.deepEqual(rows.get('camel-empty-inline-suppresses-snake').result,
    { tracks: [ordinaryTrack], lyrics: ['普通 text'], model: clip, metadata: ordinaryMetadata });
  assert.equal(all.sdkJsonInput.candidates[0].content.parts[2].inlineData, null);
  assert.deepEqual(all.sdkJsonInput.candidates[0].content.parts[2].inline_data,
    { data: 'Aw==', mime_type: ' AUDIO/WAV ' });
});

test('actual Base64 and MIME helpers retain bytes, raw labels and exact-Pro-only unknown extension fallback', () => {
  const variants = rows.get('base64-standard-url-safe-variants');
  assert.deepEqual(variants.result.tracks.map(row => Buffer.from(row.bytesBase64, 'base64')),
    [Buffer.from([1]), Buffer.from([2]), Buffer.from([251, 255]), Buffer.from([251, 255]), Buffer.from([0, 255, 128])]);
  assert.equal(rows.get('pro-wav').result.tracks[0].mimeType, 'Audio/WAVE; codecs=pcm');
  assert.equal(rows.get('models-resource-name').result.tracks[0].fileName, 'track-1.mp3');
  assert.equal(rows.get('provider-prefix-preserved').result.tracks[0].fileName, 'track-1.mp3');
  assert.equal(rows.get('unknown-pro-mime-wav').result.tracks[0].fileName, 'track-1.wav');
  assert.deepEqual(rows.get('default-mime-and-raw-alias').result.tracks.map(row => [row.mimeType, row.fileName]),
    [['audio/mpeg', 'track-1.mp3'], ['AUDIO/X-WAV; source=fixture', 'track-2.wav']]);
  assert.equal(rows.get('pro-wav').requests[0].rawBody.includes('wav'), false);
  assert.deepEqual(rows.get('duration-unused').requests[0].body, rows.get('clip-default').requests[0].body);
});

test('key/attribution inputs and default-timeout boundaries remain explicit and first response ends every successful callback', () => {
  for (const row of capture.observations) {
    const cfg = { models: { providers: { google: row.config.baseUrl === undefined ? {} : { baseUrl: row.config.baseUrl } } } };
    assert.deepEqual(row.keyCalls, [{ provider: 'google', cfg, agentDir: '/synthetic/google-agent', store: { fixture: 'synthetic-key-store' } }], row.id);
    const normalizedBase = row.id === 'official-openai-base-normalization' ? 'https://generativelanguage.googleapis.com'
      : row.id === 'custom-versioned-base' ? 'https://relay.example.test/prefix' : 'https://generativelanguage.googleapis.com/v1beta';
    assert.deepEqual(row.attributionCalls, [{ provider: 'google', api: 'google-generative-ai', baseUrl: normalizedBase,
      capability: 'other', transport: 'http' }], row.id);
    assert.equal(row.requests.length, 1, row.id);
    assert.equal(row.sdkOptions.length, 1, row.id);
  }
  assert.equal(rows.get('source-default-timeout').hostComparable, false);
  assert.equal(Object.hasOwn(rows.get('source-default-timeout').input, 'timeoutMs'), false);
  assert.deepEqual(rows.get('blank-model-and-lyrics').result.metadata, ordinaryMetadata);
  assert.deepEqual(capture.deferredCalls, []);
  assert.deepEqual(capture.dynamicImports, []);
});

test('18 whole modules, exact deadline region and full source/import provenance remain unchanged', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.sourceRecords.filter(row => row.executed && row.wholeModule).length, 18);
  assert.deepEqual(capture.sourceRecords.filter(row => row.executed && !row.wholeModule).map(row => row.path), ['src/media-understanding/shared.ts']);
  for (const path of ['extensions/google/music-generation-provider.ts', 'extensions/google/google-genai-runtime.ts',
    'extensions/google/generation-provider-metadata.ts', 'extensions/google/base64.ts', 'extensions/google/generation-auth.ts',
    'extensions/google/provider-policy.ts', 'extensions/google/src/google-api-base-url.ts',
    'src/music-generation/provider-assets.ts', 'packages/media-core/src/mime.ts', 'packages/media-core/src/base64.ts']) {
    assert.ok(capture.sourceRecords.some(row => row.path === path && row.wholeModule), path);
  }
  for (const row of capture.sourceRecords) {
    const original = readFileSync(join(root, row.path));
    assert.equal(row.sha256, hash(original), row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let code = original.toString();
    if (row.projection) {
      const region = original.subarray(row.projection.startByte, row.projection.endByte);
      assert.equal(row.projection.sourceRegionSha256, hash(region));
      code = row.projection.prelude + region.toString();
      assert.equal(row.projection.generatedCode, code);
      assert.equal(row.projection.generatedSha256, hash(code));
    }
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(code, { mode: 'transform', sourceMap: false })), row.path);
  }
  assert.deepEqual(capture.sourceRecords.find(row => row.path === 'LICENSE'),
    { path: 'LICENSE', sha256: hash(readFileSync(join(root, 'LICENSE'))), executed: false, provenanceOnly: true });
  for (const binding of capture.importBindings) {
    assert.ok(binding.importer && binding.specifier);
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    if (binding.source) assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))));
    if (binding.origin) assert.equal(binding.originSha256, hash(readFileSync(join(root, binding.origin))));
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-google-music-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
});

test('actual SDK entry/version/integrity and fetch-only constructor binding are independently preserved', () => {
  const sdk = capture.sdk.before;
  assert.equal(sdk.name, '@google/genai');
  assert.equal(sdk.version, '2.28.0');
  const integrity = 'sha512-hyNAJj+ywu3L46qlZod6KO/JvcT3QONz6VCiPevC/FWOjAD+LQb7DMLUoV8vzoLpt61Q0ruQX99iqbxEjPJWmw==';
  assert.equal(sdk.npmIntegrity, integrity);
  assert.equal(sdk.pinnedSourceIntegrity, integrity);
  assert.deepEqual(capture.sdk.after, sdk);
  for (const row of sdk.files) assert.equal(row.sha256, hash(readFileSync(row.path)), row.path);
  assert.equal(JSON.parse(readFileSync(join(root, sdk.sourceManifest))).dependencies['@google/genai'], '2.28.0');
  const installed = JSON.parse(readFileSync('/tmp/synapsis-googlemusic365-sdk/node_modules/@google/genai/package.json'));
  assert.equal(installed.exports['.'].node.import, './dist/node/index.mjs');
  const binding = capture.importBindings.find(row => row.specifier === '@google/genai');
  assert.equal(binding.kind, 'actual-pinned-sdk-constructor-with-only-fetch-injection');
  assert.equal(binding.generatedCode,
    'export class GoogleGenAI extends globalThis.__sdk.GoogleGenAI {constructor(options){globalThis.__platform.options(options);super({...options,httpOptions:{...options.httpOptions,fetch:globalThis.__platform.fetch}});}}');
  assert.equal(binding.sdkEntrySha256, hash(readFileSync(binding.sdkEntry)));
  assert.equal(capture.limits.length, 8);
  assert.ok(capture.limits.some(value => value.includes('Source observations do not claim host all-vector replay')));
  assert.ok(capture.limits.some(value => value.includes('Source text-only retry and explicit terminal-stop paths are not invoked')));
  assert.ok(capture.limits.some(value => value.includes('does not prove real sockets')));
});

test('two fresh actual-SDK source executions exactly reproduce the complete frozen fixture', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/google-music-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  const fresh = await captureGoogleMusicGeneration(root);
  assert.deepEqual(fresh, fixture);
});
