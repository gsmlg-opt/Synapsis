// Independent ordinary-success oracle authored from pinned original DeepInfra modules.
// Audio bytes are opaque; decoding and excluded auth/policy/reader behavior are unqualified.
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
import { captureDeepInfraSpeech, DEEPINFRA_SPEECH_PIN } from './capture-deepinfra-speech.mjs';

const root = process.env.OPENCLAW_DEEPINFRA_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_DEEPINFRA_SPEECH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/deepinfra-speech.json', import.meta.url);
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const gitBlob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const key = 'fixture-deepinfra-speech';
const text = 'Plain speech fixture.';
const audioBase64 = 'UklGRgABAv8=';
const canonicalBase = 'https://api.deepinfra.com/v1/openai';
const models = ['hexgrad/Kokoro-82M', 'Qwen/Qwen3-TTS', 'ResembleAI/chatterbox-turbo', 'sesame/csm-1b'];
const voices = [{ id: 'af_bella', name: 'af_bella' }];
const metadata = { id: 'deepinfra', label: 'DeepInfra', autoSelectOrder: 45,
  defaultModel: 'hexgrad/Kokoro-82M', defaultTimeoutMs: 120000, models, voices: ['af_bella'] };
const defaults = { model: 'hexgrad/Kokoro-82M', voice: 'af_bella' };
const sourcePaths = [
  'extensions/deepinfra/speech-provider.ts', 'extensions/deepinfra/media-models.ts',
  'src/tts/openai-compatible-speech-provider.ts', 'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts', 'src/shared/dot-path.ts', 'src/shared/path-array-index.ts',
  'src/infra/prototype-keys.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'src/tts/tts-provider-resolution.ts',
];
const nestedExtraBody = { model: 'nested-model', voice: 'nested-voice', input: 'nested-input',
  response_format: 'nested-format', speed: 1.7, extra_body: { nested: true },
  options: { seeds: [7, 11], style: { language: '中文', enabled: true } }, tags: ['one', { two: 2 }] };
const customOptions = { ttsModels: [
  { id: 'ordinary/custom-first', name: 'Custom First', tags: ['tts'], pricing: { input_characters: 0.02 } },
  { id: 'ordinary/custom-second', name: 'Custom Second', tags: ['tts', 'multilingual'],
    pricing: { output_seconds: 0.03 } },
] };
const customMetadata = { ...metadata, defaultModel: 'ordinary/custom-first',
  models: ['ordinary/custom-first', 'ordinary/custom-second'] };

// Raw inputs mirror the frozen handoff. Expected normalized and wire fields below
// are literal conclusions from original source; no target normalizer supplies them.
const formats = [
  ['mp3', ' MP3 ', true], ['opus', ' OPUS ', true], ['flac', ' FLAC ', false],
  ['wav', ' WAV ', false], ['pcm', ' PCM ', false],
];
const recipes = [
  { id: 'default-file' },
  { id: 'default-note', target: 'voice-note' },
  ...formats.flatMap(([format, rawFormat, voiceCompatible]) => [
    { id: `format-${format}-file`, raw: { responseFormat: rawFormat },
      resolved: { responseFormat: format }, body: { response_format: format }, format, voiceCompatible },
    { id: `format-${format}-note`, target: 'voice-note', raw: { responseFormat: rawFormat },
      resolved: { responseFormat: format }, body: { response_format: format }, format, voiceCompatible },
  ]),
  { id: 'configured', raw: { baseUrl: 'https://api.deepinfra.com/v1/openai/',
    modelId: 'Qwen/Qwen3-TTS', voiceId: 'configured-voice', speed: 1.1, responseFormat: ' OPUS ',
    extraBody: { temperature: 0.6 } },
    resolved: { baseUrl: canonicalBase, model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 1.1,
      responseFormat: 'opus', extraBody: { temperature: 0.6 } },
    body: { model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 1.1,
      response_format: 'opus', extra_body: { temperature: 0.6 } }, format: 'opus', voiceCompatible: true },
  { id: 'custom-prefix', raw: { baseUrl: 'https://speech.example/deepinfra/v7///',
    model: 'ResembleAI/chatterbox-turbo', voice: 'ordinary-voice', speed: 0.9 },
    resolved: { baseUrl: 'https://speech.example/deepinfra/v7', model: 'ResembleAI/chatterbox-turbo',
      voice: 'ordinary-voice', speed: 0.9 }, wireBase: 'https://speech.example/deepinfra/v7',
    body: { model: 'ResembleAI/chatterbox-turbo', voice: 'ordinary-voice', speed: 0.9 } },
  { id: 'configured-namespace', raw: { model: ' deepinfra/Qwen/Qwen3-TTS ' },
    resolved: { model: 'Qwen/Qwen3-TTS' }, body: { model: 'Qwen/Qwen3-TTS' } },
  { id: 'overrides', raw: { modelId: 'Qwen/Qwen3-TTS', voiceId: 'configured-voice', speed: 0.8 },
    overrides: { model: ' deepinfra/ResembleAI/chatterbox-turbo ', voice: ' override-voice ', speed: 1.2 },
    resolved: { model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 0.8 },
    body: { model: 'ResembleAI/chatterbox-turbo', voice: 'override-voice', speed: 1.2 } },
  { id: 'id-alias-overrides', overrides: { modelId: ' deepinfra/sesame/csm-1b ',
    voiceId: ' ordinary-id ', speed: 1.1 }, body: { model: 'sesame/csm-1b', voice: 'ordinary-id', speed: 1.1 } },
  { id: 'override-key-precedence', overrides: { model: ' deepinfra/Qwen/Qwen3-TTS ',
    modelId: 'ignored-model', voice: ' primary-voice ', voiceId: 'ignored-voice' },
    body: { model: 'Qwen/Qwen3-TTS', voice: 'primary-voice' } },
  { id: 'blank-selected-overrides', raw: { model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 0.9 },
    overrides: { model: ' ', modelId: 'ignored-model', voice: ' ', voiceId: 'ignored-voice' },
    resolved: { model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 0.9 },
    body: { model: 'Qwen/Qwen3-TTS', voice: 'configured-voice', speed: 0.9 } },
  { id: 'config-key-precedence', raw: { model: ' deepinfra/Qwen/Qwen3-TTS ', modelId: 'ignored-model',
    voice: ' primary-voice ', voiceId: 'ignored-voice' },
    resolved: { model: 'Qwen/Qwen3-TTS', voice: 'primary-voice' },
    body: { model: 'Qwen/Qwen3-TTS', voice: 'primary-voice' } },
  { id: 'blank-selected-config-model', raw: { model: ' ', modelId: 'ignored-model' } },
  { id: 'speaker-precedence', raw: { speakerVoice: ' speaker-v ', speakerVoiceId: 'unused-id',
    voice: 'unused-voice', voiceId: 'unused' }, resolved: { voice: 'speaker-v' }, body: { voice: 'speaker-v' } },
  { id: 'speaker-id', raw: { speakerVoice: ' ', speakerVoiceId: ' speaker-id ', voice: 'unused-voice' },
    resolved: { voice: 'speaker-id' }, body: { voice: 'speaker-id' } },
  { id: 'blank-speaker-fallback', raw: { speakerVoice: ' ', speakerVoiceId: ' ',
    voice: ' ordinary-voice ', voiceId: 'unused-id' },
    resolved: { voice: 'ordinary-voice' }, body: { voice: 'ordinary-voice' } },
  { id: 'unicode-trim', raw: { modelId: '\u00a0\ufeff deepinfra/hexgrad/Kokoro-82M \ufeff\u00a0',
    voiceId: '\u00a0\ufeff af_bella \ufeff\u00a0', speed: 1.25 },
    resolved: { model: 'hexgrad/Kokoro-82M', voice: 'af_bella', speed: 1.25 },
    body: { model: 'hexgrad/Kokoro-82M', voice: 'af_bella', speed: 1.25 } },
  { id: 'zero-speed', raw: { speed: 0 }, resolved: { speed: 0 }, body: { speed: 0 } },
  { id: 'nested-extra-body', raw: { extraBody: nestedExtraBody },
    resolved: { extraBody: nestedExtraBody }, body: { extra_body: nestedExtraBody } },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  { id: 'legacy-config', legacy: true,
    raw: { modelId: 'sesame/csm-1b', voiceId: 'legacy-voice', extraBody: { legacy: true } },
    resolved: { model: 'sesame/csm-1b', voice: 'legacy-voice', extraBody: { legacy: true } },
    body: { model: 'sesame/csm-1b', voice: 'legacy-voice', extra_body: { legacy: true } } },
  { id: 'nested-precedence', raw: { model: 'Qwen/Qwen3-TTS', voice: 'nested-voice', extraBody: { nested: true } },
    legacyRaw: { apiKey: key, model: 'sesame/csm-1b', voice: 'legacy-voice', extraBody: { legacy: true } },
    resolved: { model: 'Qwen/Qwen3-TTS', voice: 'nested-voice', extraBody: { nested: true } },
    body: { model: 'Qwen/Qwen3-TTS', voice: 'nested-voice', extra_body: { nested: true } } },
  { id: 'case-sensitive-model-prefix', raw: { model: 'DeepInfra/Qwen/Qwen3-TTS' },
    resolved: { model: 'DeepInfra/Qwen/Qwen3-TTS' }, body: { model: 'DeepInfra/Qwen/Qwen3-TTS' } },
  { id: 'single-model-prefix-strip', overrides: { model: 'deepinfra/deepinfra/Qwen/Qwen3-TTS' },
    body: { model: 'deepinfra/Qwen/Qwen3-TTS' } },
  { id: 'factory-custom-catalog', factoryOptions: customOptions, providerMetadata: customMetadata,
    resolved: { model: 'ordinary/custom-first' }, body: { model: 'ordinary/custom-first' } },
  { id: 'factory-empty-catalog', factoryOptions: { ttsModels: [] } },
  { id: 'configured-repeated-namespace', raw: { model: 'deepinfra/deepinfra/deepinfra/Qwen/Qwen3-TTS' },
    resolved: { model: 'deepinfra/deepinfra/Qwen/Qwen3-TTS' }, body: { model: 'Qwen/Qwen3-TTS' } },
];

const expectedRows = recipes.map(recipe => {
  const raw = { apiKey: key, ...recipe.raw };
  const rawConfig = recipe.legacy ? { deepinfra: raw }
    : { providers: { deepinfra: raw }, ...(recipe.legacyRaw ? { deepinfra: recipe.legacyRaw } : {}) };
  const input = { text: recipe.text ?? text, target: recipe.target ?? 'audio-file',
    timeoutMs: 12345, cfg: {}, rawConfig,
    ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}) };
  const resolvedConfig = { ...defaults, ...recipe.resolved };
  const synthesisRequest = { text: input.text, target: input.target, timeoutMs: 12345,
    cfg: {}, providerConfig: resolvedConfig,
    ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}) };
  const format = recipe.format ?? 'mp3';
  const factoryOptions = recipe.factoryOptions ?? {};
  return { id: recipe.id, input, inputAfter: input, factoryOptions, factoryOptionsAfter: factoryOptions,
    resolvedConfig, providerMetadata: recipe.providerMetadata ?? metadata, listVoices: voices,
    synthesisRequest, synthesisRequestAfter: synthesisRequest,
    request: { url: `${recipe.wireBase ?? canonicalBase}/audio/speech`,
      body: { model: 'hexgrad/Kokoro-82M', input: input.text, voice: 'af_bella',
        response_format: 'mp3', ...recipe.body }, timeoutMs: 12345 },
    response: { status: 200, headers: { 'Content-Type': 'application/octet-stream' }, audioBase64 },
    result: { audioBase64, outputFormat: format, fileExtension: `.${format}`,
      voiceCompatible: recipe.voiceCompatible ?? true }, releaseCount: 1 };
});

const expectedTalkConfig = [
  { id: 'talk-defaults', input: {
    baseTtsConfig: { providers: { deepinfra: { apiKey: key } } }, talkProviderConfig: {} }, result: defaults },
  { id: 'talk-configured', input: {
    baseTtsConfig: { providers: { deepinfra: { apiKey: key, model: 'hexgrad/Kokoro-82M', voice: 'af_bella',
      speed: 0.9, extraBody: { base: true, options: { seed: 7 } } } } },
    talkProviderConfig: { apiKey: 'fixture-talk-speech', baseUrl: 'https://talk.example/deepinfra/v2///',
      modelId: ' deepinfra/Qwen/Qwen3-TTS ', voiceId: 'talk-voice', speed: 1.2, responseFormat: ' FLAC ',
      extraBody: { ignored: true } } },
    result: { baseUrl: 'https://talk.example/deepinfra/v2', model: 'Qwen/Qwen3-TTS', voice: 'talk-voice',
      speed: 1.2, responseFormat: 'flac', extraBody: { base: true, options: { seed: 7 } } } },
  { id: 'talk-speaker', input: {
    baseTtsConfig: { providers: { deepinfra: { apiKey: key, model: 'ResembleAI/chatterbox-turbo',
      voice: 'baseline-voice', extraBody: { retained: true } } } },
    talkProviderConfig: { baseUrl: 'https://api.deepinfra.com/v1/openai/', speakerVoice: ' talk-speaker ',
      speakerVoiceId: 'unused', voice: 'unused', voiceId: 'unused', responseFormat: ' OPUS ' } },
    result: { baseUrl: canonicalBase, model: 'ResembleAI/chatterbox-turbo', voice: 'talk-speaker',
      responseFormat: 'opus', extraBody: { retained: true } } },
  { id: 'talk-model-alias-unselected', input: {
    baseTtsConfig: { providers: { deepinfra: { apiKey: key, model: 'sesame/csm-1b', speed: 0.9 } } },
    talkProviderConfig: { model: 'deepinfra/Qwen/Qwen3-TTS', speed: 0, voiceId: ' voice-id ' } },
    result: { model: 'sesame/csm-1b', voice: 'voice-id', speed: 0 } },
  { id: 'talk-empty-nested-precedence', input: {
    baseTtsConfig: { providers: { deepinfra: {} }, deepinfra: { apiKey: key, model: 'sesame/csm-1b',
      voice: 'legacy-voice', extraBody: { legacy: true } } }, talkProviderConfig: {} }, result: defaults },
].map(row => ({ ...row, inputAfter: row.input, factoryOptions: {}, factoryOptionsAfter: {} }));

const expectedTalkOverrides = [
  { id: 'talk-id-overrides', input: { params: { voiceId: ' vf ', voice: 'ignored',
    modelId: ' deepinfra/Qwen/Qwen3-TTS ', model: 'ignored', speed: 1.25 } },
    result: { voice: 'vf', model: 'deepinfra/Qwen/Qwen3-TTS', speed: 1.25 } },
  { id: 'talk-alias-overrides', input: { params: { voice: ' v ',
    model: ' deepinfra/sesame/csm-1b ', speed: 0.9 } },
    result: { voice: 'v', model: 'deepinfra/sesame/csm-1b', speed: 0.9 } },
  { id: 'talk-blank-overrides', input: { params: { voice: ' ', model: ' ' } }, result: {} },
  { id: 'talk-blank-id-overrides', input: { params: { voiceId: ' ', voice: 'ignored-fallback',
    modelId: ' ', model: 'ignored-fallback', speed: 1.1 } }, result: { speed: 1.1 } },
].map(row => ({ ...row, inputAfter: row.input, factoryOptions: {}, factoryOptionsAfter: {} }));

const expectedTimeouts = [
  { id: 'provider-default', config: { timeoutMs: 30000, timeoutMsSource: 'default' }, result: 120000 },
  { id: 'configured-default', config: { timeoutMs: 45000, timeoutMsSource: 'config' }, result: 45000 },
  { id: 'configured-standard', config: { timeoutMs: 30000, timeoutMsSource: 'config' }, result: 30000 },
  { id: 'per-call', config: { timeoutMs: 30000, timeoutMsSource: 'default' }, timeoutMs: 75000, result: 75000 },
].map(({ id, config, timeoutMs, result }) => {
  const input = { config, provider: metadata, ...(timeoutMs === undefined ? {} : { timeoutMs }) };
  return { id, input, inputAfter: input, result, factoryOptions: {}, factoryOptionsAfter: {} };
});

// Platform calls, request headers, auth resolution, policy and reader settings are
// provenance only. Ordinary semantic comparison selects declared fields explicitly.
function ordinaryConfig(config) {
  const { apiKey, ...ordinary } = config;
  return ordinary;
}
function ordinarySynthesisRequest(request) {
  return { ...request, providerConfig: ordinaryConfig(request.providerConfig) };
}
function ordinaryObservation(row) {
  return { id: row.id, input: row.input, inputAfter: row.inputAfter,
    factoryOptions: row.factoryOptions, factoryOptionsAfter: row.factoryOptionsAfter,
    resolvedConfig: ordinaryConfig(row.resolvedConfig), providerMetadata: row.providerMetadata,
    listVoices: row.listVoices, synthesisRequest: ordinarySynthesisRequest(row.synthesisRequest),
    synthesisRequestAfter: ordinarySynthesisRequest(row.synthesisRequestAfter),
    request: { url: row.request.url, body: row.request.body, timeoutMs: row.request.timeoutMs },
    response: row.response, result: row.result, releaseCount: row.releaseCount };
}
function ordinaryCallback(row, configResult = false) {
  return { id: row.id, input: row.input, inputAfter: row.inputAfter,
    factoryOptions: row.factoryOptions, factoryOptionsAfter: row.factoryOptionsAfter,
    result: configResult ? ordinaryConfig(row.result) : row.result };
}

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

const capture = await captureDeepInfraSpeech(root);

test('35 original synthesis callbacks match independent ordinary config, wire and result maps', () => {
  assert.deepEqual(capture.observations.map(ordinaryObservation), expectedRows);
  for (const row of capture.observations) {
    assert.deepEqual([...Buffer.from(row.result.audioBase64, 'base64')], [82, 73, 70, 70, 0, 1, 2, 255], row.id);
  }
});

test('all five formats retain their output metadata for both audio-file and voice-note', () => {
  for (const [format, , voiceCompatible] of formats) {
    for (const [suffix, target] of [['file', 'audio-file'], ['note', 'voice-note']]) {
      const row = capture.observations.find(row => row.id === `format-${format}-${suffix}`);
      assert.equal(row.input.target, target);
      assert.deepEqual(row.result, { audioBase64, outputFormat: format,
        fileExtension: `.${format}`, voiceCompatible });
    }
  }
});

test('nested extraBody is forwarded under extra_body without replacing top-level speech fields', () => {
  const row = capture.observations.find(row => row.id === 'nested-extra-body');
  assert.deepEqual(row.request.body, { model: 'hexgrad/Kokoro-82M', input: text,
    voice: 'af_bella', response_format: 'mp3', extra_body: nestedExtraBody });
});

test('original Talk callbacks retain their distinct config and override alias rules', () => {
  assert.deepEqual(capture.talkConfigObservations.map(row => ordinaryCallback(row, true)), expectedTalkConfig);
  assert.deepEqual(capture.talkOverrideObservations.map(row => ordinaryCallback(row)), expectedTalkOverrides);
});

test('positive source timeout resolver observations retain provider, config and per-call values', () => {
  assert.deepEqual(capture.timeoutObservations.map(row => ordinaryCallback(row)), expectedTimeouts);
});

test('default, nondefault and empty factory options preserve catalog order and default choice', () => {
  for (const row of capture.observations) {
    assert.deepEqual(row.providerMetadata, row.id === 'factory-custom-catalog' ? customMetadata : metadata, row.id);
    assert.deepEqual(row.listVoices, voices, row.id);
    assert.deepEqual(row.factoryOptionsAfter, row.factoryOptions, row.id);
    assert.deepEqual(row.inputAfter, row.input, row.id);
    assert.deepEqual(row.synthesisRequestAfter, row.synthesisRequest, row.id);
  }
  assert.equal(capture.observations.length, 35);
  assert.equal(capture.talkConfigObservations.length, 5);
  assert.equal(capture.talkOverrideObservations.length, 4);
  assert.equal(capture.timeoutObservations.length, 4);
  assert.deepEqual(capture.counts, { observations: 35, synthesisCallbacks: 35,
    telephonyCallbacks: 0, httpRequests: 35, releases: 35, listVoicesCallbacks: 35,
    talkConfigObservations: 5, talkOverrideObservations: 4, timeoutObservations: 4,
    totalObservations: 48, wholeModules: 12, originalDataModules: 1,
    trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('whole original modules, manifest, license and full tracked checkout have pinned provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(DEEPINFRA_SPEECH_PIN, pin);
  assert.equal(capture.referencePin, pin);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root, timeout: 30000 }));
    assert.deepEqual(audit, { path: audit.path, gitBlob: gitBlob(bytes), sourceSha256: hash(bytes),
      executableSha256: hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      wholeModule: true, executed: true });
  }
  assert.deepEqual(capture.dataAudit.map(audit => audit.path), ['extensions/deepinfra/openclaw.plugin.json', 'LICENSE']);
  for (const audit of capture.dataAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root, timeout: 30000 }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.gitBlob, gitBlob(bytes));
  }
  const manifest = readFileSync(join(root, 'extensions/deepinfra/openclaw.plugin.json'));
  assert.equal(capture.dataAudit[0].loadedAs,
    'vm.SyntheticModule default JSON.parse of complete pinned original bytes');
  assert.equal(capture.dataAudit[0].evaluated, true);
  assert.deepEqual(capture.pluginManifest, JSON.parse(manifest));
  assert.deepEqual(capture.pluginManifest.contracts.speechProviders, ['deepinfra']);
  assert.deepEqual(capture.license, { path: 'LICENSE', text: readFileSync(join(root, 'LICENSE'), 'utf8') });
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.checkout.before.commit, pin);
  assert.equal(capture.checkout.before.tree,
    execFileSync('git', ['rev-parse', `${pin}^{tree}`], { cwd: root, encoding: 'utf8', timeout: 30000 }).trim());
  assert.equal(capture.harness.path, 'scripts/openclaw/capture-deepinfra-speech.mjs');
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-deepinfra-speech.mjs', import.meta.url))));
  assert.equal(capture.transformation.api, 'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options, { mode: 'transform', sourceMap: false });
  const expectedImports = sourcePaths.flatMap(path => staticImportEdges(path,
    stripTypeScriptTypes(readFileSync(join(root, path), 'utf8'), { mode: 'transform', sourceMap: false })));
  assert.deepEqual(capture.transformation.sdkFacades.map(facade => facade.module), [
    'openclaw/plugin-sdk/speech-provider', 'openclaw/plugin-sdk/string-coerce-runtime',
    '@openclaw/normalization-core/record-coerce', '@openclaw/normalization-core/string-coerce',
    '@openclaw/normalization-core/number-coercion',
  ]);
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

test('synthetic environment and unexecuted platform modules remain explicit provenance boundaries', () => {
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
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-deepinfra-speech-'));
  try {
    const output = join(temporary, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-deepinfra-speech.mjs', import.meta.url)), '--source', root, '--output', output],
    { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(readFileSync(output)), JSON.parse(readFileSync(fixture)));
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
