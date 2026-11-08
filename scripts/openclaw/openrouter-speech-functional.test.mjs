// Independent ordinary-success oracle authored from pinned original OpenRouter modules.
// Fixture bytes are opaque: this does not qualify decoding, authentication or network guards.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { tmpdir } from 'node:os';
import { join, posix } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { OPENROUTER_SPEECH_PIN, captureOpenRouterSpeech } from './capture-openrouter-speech.mjs';

const root = process.env.OPENCLAW_OPENROUTER_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_OPENROUTER_SPEECH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openrouter-speech.json', import.meta.url);
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const gitBlob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const key = 'fixture-openrouter-speech';
const text = 'Plain speech fixture.';
const audioBase64 = 'UklGRgABAv8=';
const canonicalBase = 'https://openrouter.ai/api/v1';
const models = ['hexgrad/kokoro-82m', 'elevenlabs/eleven-turbo-v2',
  'google/gemini-3.1-flash-tts-preview', 'mistralai/voxtral-mini-tts-2603'];
const voices = [{ id: 'af_alloy', name: 'af_alloy' }];
const metadata = { id: 'openrouter', label: 'OpenRouter', autoSelectOrder: 35,
  defaultModel: 'hexgrad/kokoro-82m', defaultTimeoutMs: 120000,
  models, voices: ['af_alloy'] };
const defaults = { apiKey: key, model: 'hexgrad/kokoro-82m', voice: 'af_alloy' };
const sourcePaths = [
  'extensions/openrouter/speech-provider.ts', 'extensions/openrouter/provider-defaults.ts',
  'src/tts/openai-compatible-speech-provider.ts', 'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts',
  'src/shared/dot-path.ts', 'src/shared/path-array-index.ts', 'src/infra/prototype-keys.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts',
  'src/tts/tts-provider-resolution.ts',
];

// Raw inputs reproduce the fixed input handoff. Each resolved/wire value is a
// literal conclusion from the original source, not a call into its normalizers.
const recipes = [
  { id: 'default-file' },
  { id: 'configured', raw: { baseUrl: 'https://openrouter.ai/v1/',
    modelId: 'google/gemini-3.1-flash-tts-preview', voiceId: 'Kore', speed: 1.1,
    responseFormat: ' MP3 ', provider: { options: { openai: { instructions: 'Speak warmly.' } } } },
    resolved: { baseUrl: canonicalBase, model: 'google/gemini-3.1-flash-tts-preview',
      voice: 'Kore', speed: 1.1, responseFormat: 'mp3',
      provider: { options: { openai: { instructions: 'Speak warmly.' } } } },
    body: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'Kore', speed: 1.1,
      provider: { options: { openai: { instructions: 'Speak warmly.' } } } } },
  { id: 'custom-prefix', raw: { baseUrl: 'https://speech.example/router/v7///',
    model: 'mistralai/voxtral-mini-tts-2603', voice: 'ordinary-voice', speed: 0.9,
    provider: { order: ['ordinary-route'] } },
    resolved: { baseUrl: 'https://speech.example/router/v7', model: 'mistralai/voxtral-mini-tts-2603',
      voice: 'ordinary-voice', speed: 0.9, provider: { order: ['ordinary-route'] } },
    wireBase: 'https://speech.example/router/v7',
    body: { model: 'mistralai/voxtral-mini-tts-2603', voice: 'ordinary-voice', speed: 0.9,
      provider: { order: ['ordinary-route'] } } },
  { id: 'overrides', raw: { modelId: 'elevenlabs/eleven-turbo-v2',
    voiceId: 'configured-voice', speed: 0.8 },
    overrides: { model: ' google/gemini-3.1-flash-tts-preview ', voice: ' Kore ', speed: 1.2 },
    resolved: { model: 'elevenlabs/eleven-turbo-v2', voice: 'configured-voice', speed: 0.8 },
    body: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'Kore', speed: 1.2 } },
  { id: 'id-alias-overrides',
    overrides: { modelId: ' mistralai/voxtral-mini-tts-2603 ', voiceId: ' ordinary-id ', speed: 1.1 },
    body: { model: 'mistralai/voxtral-mini-tts-2603', voice: 'ordinary-id', speed: 1.1 } },
  { id: 'override-key-precedence', overrides: { model: ' google/gemini-3.1-flash-tts-preview ',
    modelId: 'ignored-model', voice: ' Kore ', voiceId: 'ignored-voice' },
    body: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'Kore' } },
  { id: 'blank-overrides', raw: { model: 'elevenlabs/eleven-turbo-v2',
    voice: 'configured-voice', speed: 0.9 }, overrides: { model: ' ', voice: ' ' },
    resolved: { model: 'elevenlabs/eleven-turbo-v2', voice: 'configured-voice', speed: 0.9 },
    body: { model: 'elevenlabs/eleven-turbo-v2', voice: 'configured-voice', speed: 0.9 } },
  { id: 'speaker-precedence', raw: { speakerVoice: ' speaker-v ', speakerVoiceId: 'unused-id',
    voice: 'unused-voice', voiceId: 'unused' }, resolved: { voice: 'speaker-v' },
    body: { voice: 'speaker-v' } },
  { id: 'speaker-id', raw: { speakerVoiceId: ' speaker-id ', voice: 'unused-voice' },
    resolved: { voice: 'speaker-id' }, body: { voice: 'speaker-id' } },
  { id: 'unicode-trim', raw: { modelId: '\u00a0\ufeff hexgrad/kokoro-82m \ufeff\u00a0',
    voiceId: '\u00a0\ufeff af_alloy \ufeff\u00a0', speed: 1.25 },
    resolved: { model: 'hexgrad/kokoro-82m', voice: 'af_alloy', speed: 1.25 },
    body: { model: 'hexgrad/kokoro-82m', voice: 'af_alloy', speed: 1.25 } },
  { id: 'pcm-file', raw: { responseFormat: ' PCM ', provider: { order: [] } },
    resolved: { responseFormat: 'pcm', provider: { order: [] } },
    body: { response_format: 'pcm', provider: { order: [] } }, format: 'pcm' },
  { id: 'default-note', target: 'voice-note' },
  { id: 'pcm-note', target: 'voice-note', raw: { responseFormat: 'pcm' },
    resolved: { responseFormat: 'pcm' }, body: { response_format: 'pcm' }, format: 'pcm' },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  { id: 'legacy-config', legacy: true,
    raw: { modelId: 'elevenlabs/eleven-turbo-v2', voiceId: 'legacy-voice' },
    resolved: { model: 'elevenlabs/eleven-turbo-v2', voice: 'legacy-voice' },
    body: { model: 'elevenlabs/eleven-turbo-v2', voice: 'legacy-voice' } },
  { id: 'nested-precedence', raw: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'nested-voice' },
    legacyRaw: { apiKey: key, model: 'elevenlabs/eleven-turbo-v2', voice: 'legacy-voice' },
    resolved: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'nested-voice' },
    body: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'nested-voice' } },
];

const secretCall = (path, value) => ({ module: 'openclaw/plugin-sdk/secret-input',
  export: 'normalizeResolvedSecretInputString', path, ...(value === undefined ? {} : { value }) });
const ordinarySynthesisCalls = [
  secretCall('tts.providers.openrouter.apiKey', key),
  secretCall('tts.providers.openrouter.apiKey'),
  { module: 'src/plugin-sdk/provider-http.ts', export: 'resolveProviderHttpRequestConfig' },
  { module: 'src/plugin-sdk/provider-http.ts', export: 'postJsonRequest' },
  { module: 'src/plugin-sdk/provider-http.ts', export: 'assertOkOrThrowHttpError',
    status: 200, label: 'OpenRouter TTS API error' },
  { module: 'src/plugin-sdk/provider-http.ts', export: 'readProviderBinaryResponse',
    status: 200, label: 'OpenRouter TTS API error', kind: 'audio' },
  { module: 'src/plugin-sdk/provider-http.ts', export: 'release' },
];

const expectedRows = recipes.map(recipe => {
  const raw = { apiKey: key, ...recipe.raw };
  const rawConfig = recipe.legacy ? { openrouter: raw }
    : { providers: { openrouter: raw }, ...(recipe.legacyRaw ? { openrouter: recipe.legacyRaw } : {}) };
  const input = { text: recipe.text ?? text, target: recipe.target ?? 'audio-file',
    timeoutMs: 12345, cfg: {}, rawConfig,
    ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}) };
  const resolvedConfig = { ...defaults, ...recipe.resolved };
  const synthesisRequest = { text: input.text, target: input.target, timeoutMs: 12345,
    cfg: {}, providerConfig: resolvedConfig,
    ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}) };
  const format = recipe.format ?? 'mp3';
  return { id: recipe.id, input, inputAfter: input, resolvedConfig,
    providerMetadata: metadata, listVoices: voices, synthesisRequest, synthesisRequestAfter: synthesisRequest,
    request: { url: `${recipe.wireBase ?? canonicalBase}/audio/speech`,
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: { model: 'hexgrad/kokoro-82m', input: input.text, voice: 'af_alloy',
        response_format: 'mp3', ...recipe.body }, timeoutMs: 12345 },
    response: { status: 200, headers: { 'Content-Type': 'application/octet-stream' }, audioBase64 },
    result: { audioBase64, outputFormat: format, fileExtension: `.${format}`, voiceCompatible: format === 'mp3' },
    releaseCount: 1, platformCalls: ordinarySynthesisCalls };
});

const expectedTalkConfig = [
  { id: 'talk-defaults',
    input: { baseTtsConfig: { providers: { openrouter: { apiKey: key } } }, talkProviderConfig: {} },
    result: defaults,
    platformCalls: [secretCall('tts.providers.openrouter.apiKey', key)] },
  { id: 'talk-configured', input: {
    baseTtsConfig: { providers: { openrouter: { apiKey: key, model: 'hexgrad/kokoro-82m',
      voice: 'af_alloy', speed: 0.9, provider: { order: ['ordinary-route'] } } } },
    talkProviderConfig: { apiKey: 'fixture-talk-speech', baseUrl: 'https://talk.example/router/v2///',
      modelId: 'mistralai/voxtral-mini-tts-2603', voiceId: 'talk-voice', speed: 1.2,
      responseFormat: ' PCM ', provider: { ignored: true } } },
    result: { apiKey: 'fixture-talk-speech', baseUrl: 'https://talk.example/router/v2',
      model: 'mistralai/voxtral-mini-tts-2603', voice: 'talk-voice', speed: 1.2,
      responseFormat: 'pcm', provider: { order: ['ordinary-route'] } },
    platformCalls: [secretCall('tts.providers.openrouter.apiKey', key),
      secretCall('talk.providers.openrouter.apiKey', 'fixture-talk-speech')] },
  { id: 'talk-speaker', input: {
    baseTtsConfig: { providers: { openrouter: { apiKey: key, model: 'elevenlabs/eleven-turbo-v2',
      voice: 'baseline-voice' } } },
    talkProviderConfig: { baseUrl: 'https://openrouter.ai/v1/', speakerVoice: ' talk-speaker ',
      speakerVoiceId: 'unused', voice: 'unused', voiceId: 'unused', responseFormat: ' MP3 ' } },
    result: { apiKey: key, baseUrl: canonicalBase, model: 'elevenlabs/eleven-turbo-v2',
      voice: 'talk-speaker', responseFormat: 'mp3' },
    platformCalls: [secretCall('tts.providers.openrouter.apiKey', key)] },
].map(row => ({ ...row, inputAfter: row.input }));

const expectedTalkOverrides = [
  { id: 'talk-id-overrides', input: { params: { voiceId: ' vf ', voice: 'ignored',
    modelId: ' model-id ', model: 'ignored', speed: 1.25 } },
    result: { voice: 'vf', model: 'model-id', speed: 1.25 } },
  { id: 'talk-alias-overrides', input: { params: { voice: ' v ', model: ' m ', speed: 0.9 } },
    result: { voice: 'v', model: 'm', speed: 0.9 } },
  { id: 'talk-blank-overrides', input: { params: { voice: ' ', model: ' ' } }, result: {} },
  { id: 'talk-blank-id-overrides', input: { params: { voiceId: ' ', voice: 'ignored-fallback',
    modelId: ' ', model: 'ignored-fallback', speed: 1.1 } }, result: { speed: 1.1 } },
].map(row => ({ ...row, inputAfter: row.input, platformCalls: [] }));

const expectedTimeouts = [
  { id: 'provider-default', config: { timeoutMs: 30000, timeoutMsSource: 'default' }, result: 120000 },
  { id: 'configured-default', config: { timeoutMs: 45000, timeoutMsSource: 'config' }, result: 45000 },
  { id: 'configured-standard', config: { timeoutMs: 30000, timeoutMsSource: 'config' }, result: 30000 },
  { id: 'per-call', config: { timeoutMs: 30000, timeoutMsSource: 'default' }, timeoutMs: 75000, result: 75000 },
].map(({ id, config, timeoutMs, result }) => {
  const input = { config, provider: metadata, ...(timeoutMs === undefined ? {} : { timeoutMs }) };
  return { id, input, inputAfter: input, result, platformCalls: [] };
});

// Facade policy, request plumbing and reader options remain captured provenance.
// Only semantic ordinary fields participate in this success oracle.
function ordinaryCalls(calls) {
  const keys = ['module', 'export', 'path', 'value', 'status', 'label', 'kind'];
  return calls.map(call => Object.fromEntries(keys.filter(key => Object.hasOwn(call, key))
    .map(key => [key, call[key]])));
}
function ordinaryObservation(row) {
  const { allowPrivateNetwork, dispatcherPolicy, fetchFnProvided, policy, requireHttps, ...request } = row.request;
  return { ...row, request, platformCalls: ordinaryCalls(row.platformCalls) };
}
const ordinaryTalkObservation = row => ({ ...row, platformCalls: ordinaryCalls(row.platformCalls) });

// Reconstruct provenance edges from original erased modules and the separately
// disclosed facade sources. No behavior expectations come from facade code.
function staticImportEdges(importer, source) {
  const specifiers = [...source.matchAll(
    /(?:^import\s+(?:[^;]*?\sfrom\s+)?|^export\s+\{[^}]*\}\s+from\s+)["']([^"']+)["']/gm,
  )].map(match => match[1]);
  return specifiers.map(specifier => ({ importer, specifier,
    resolved: specifier.startsWith('.')
      ? posix.normalize(posix.join(posix.dirname(importer), specifier)).replace(/\.js$/u, '.ts')
      : specifier }));
}
function orderedEdges(edges) {
  return [...new Map(edges.map(edge => [JSON.stringify(edge), edge])).values()]
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
}

const capture = await captureOpenRouterSpeech(root);

test('16 original synthesis callbacks match independent full ordinary config, wire and result maps', () => {
  assert.deepEqual(capture.observations.map(ordinaryObservation), expectedRows);
  for (const row of capture.observations) {
    assert.deepEqual([...Buffer.from(row.result.audioBase64, 'base64')], [82, 73, 70, 70, 0, 1, 2, 255], row.id);
  }
});

test('original Talk config and overrides preserve their distinct alias precedence', () => {
  assert.deepEqual(capture.talkConfigObservations.map(ordinaryTalkObservation), expectedTalkConfig);
  assert.deepEqual(capture.talkOverrideObservations.map(ordinaryTalkObservation), expectedTalkOverrides);
});

test('source timeout resolver uses provider metadata, configured source and per-call values', () => {
  assert.deepEqual(capture.timeoutObservations.map(ordinaryTalkObservation), expectedTimeouts);
});

test('all four original model identifiers and the default voice are present in every provider instance', () => {
  for (const row of capture.observations) {
    assert.deepEqual(row.providerMetadata, metadata, row.id);
    assert.deepEqual(row.listVoices, voices, row.id);
  }
  assert.equal(capture.observations.length, 16);
  assert.equal(capture.talkConfigObservations.length, 3);
  assert.equal(capture.talkOverrideObservations.length, 4);
  assert.equal(capture.timeoutObservations.length, 4);
  assert.deepEqual(capture.counts, { observations: 16, synthesisCallbacks: 16,
    telephonyCallbacks: 0, httpRequests: 16, releases: 16, listVoicesCallbacks: 16,
    talkConfigObservations: 3, talkOverrideObservations: 4, timeoutObservations: 4,
    totalObservations: 27, wholeModules: 12, trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('whole original modules, manifest, license and full tracked checkout have pinned provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(OPENROUTER_SPEECH_PIN, pin);
  assert.equal(capture.referencePin, pin);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root }));
    assert.deepEqual(audit, { path: audit.path, gitBlob: gitBlob(bytes), sourceSha256: hash(bytes),
      executableSha256: hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      wholeModule: true, executed: true });
  }
  assert.deepEqual(capture.dataAudit.map(audit => audit.path), ['extensions/openrouter/openclaw.plugin.json', 'LICENSE']);
  for (const audit of capture.dataAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.gitBlob, gitBlob(bytes));
  }
  const manifest = readFileSync(join(root, 'extensions/openrouter/openclaw.plugin.json'));
  assert.deepEqual(capture.pluginManifest, JSON.parse(manifest));
  assert.deepEqual(capture.pluginManifest.contracts.speechProviders, ['openrouter']);
  assert.deepEqual(capture.license, { path: 'LICENSE', text: readFileSync(join(root, 'LICENSE'), 'utf8') });
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.checkout.before.commit, pin);
  assert.equal(capture.checkout.before.tree,
    execFileSync('git', ['rev-parse', `${pin}^{tree}`], { cwd: root, encoding: 'utf8' }).trim());
  assert.equal(capture.harness.path, 'scripts/openclaw/capture-openrouter-speech.mjs');
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-openrouter-speech.mjs', import.meta.url))));
  assert.equal(capture.transformation.api, 'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options, { mode: 'transform', sourceMap: false });
  const expectedImports = sourcePaths.flatMap(path => staticImportEdges(path,
    stripTypeScriptTypes(readFileSync(join(root, path), 'utf8'), { mode: 'transform', sourceMap: false })));
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source));
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export \{ .* \} from ".*";$/.test(line)));
    expectedImports.push(...staticImportEdges(facade.module, facade.source));
  }
  assert.deepEqual(orderedEdges(capture.transformation.staticImports), orderedEdges(expectedImports));
  assert.deepEqual(capture.transformation.dynamicImports, [{
    importer: 'src/tts/openai-compatible-speech-provider.ts', specifier: '../plugin-sdk/provider-http.js',
    resolved: 'src/plugin-sdk/provider-http.ts',
  }]);
});

test('synthetic environment and platform modules remain explicit qualification boundaries', () => {
  assert.deepEqual(capture.environmentFixture, { env: {}, cfg: {} });
  assert.deepEqual(capture.platformBoundaries.map(boundary => boundary.module), [
    'openclaw/plugin-sdk/secret-input', 'src/plugin-sdk/provider-http.ts',
    'src/plugins/sdk-deprecation.ts', 'src/tts/provider-registry-core.ts',
    'src/tts/provider-registry.ts', 'src/tts/speaker.ts', 'src/tts/tts-settings.ts',
    'src/tts/voice-models.ts', 'globalThis',
  ]);
  for (const boundary of capture.platformBoundaries) {
    assert.equal(boundary.originalSourceExecuted, false);
    assert.equal(typeof boundary.exports, 'object');
    assert.ok(Object.keys(boundary.exports).length > 0);
    for (const description of Object.values(boundary.exports)) {
      assert.equal(typeof description, 'string');
      assert.ok(description.length > 0);
    }
  }
  assert.deepEqual(Object.keys(capture.hostAdaptation).sort(), ['config', 'headers', 'response', 'talk']);
  for (const description of Object.values(capture.hostAdaptation)) {
    assert.equal(typeof description, 'string');
    assert.ok(description.length > 0);
  }
});

test('fresh module capture equals the entire parent-generated persisted fixture', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});

test('fresh CLI capture equals the entire parent-generated persisted fixture', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-openrouter-speech-'));
  try {
    const output = join(temporary, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-openrouter-speech.mjs', import.meta.url)), '--source', root, '--output', output],
    { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(readFileSync(output)), JSON.parse(readFileSync(fixture)));
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
