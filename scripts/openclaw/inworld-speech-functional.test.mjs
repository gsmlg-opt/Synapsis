// Independent ordinary-success expectations; no production provider connection.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { INWORLD_SPEECH_PIN, runInworldSpeechCapture } from './capture-inworld-speech.mjs';

const root = process.env.OPENCLAW_INWORLD_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_INWORLD_SPEECH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/inworld-speech.json', import.meta.url);
const capture = await runInworldSpeechCapture(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const key = 'fixture-inworld-speech';
const base = 'https://api.inworld.ai';
const text = 'Plain speech fixture.';
const defaults = { apiKey: key, baseUrl: base, voiceId: 'Sarah', modelId: 'inworld-tts-1.5-max' };
const audioBase64 = 'UklGRgABAv8=';
const singleNdjson = '{"result":{"audioContent":"UklGRgABAv8="}}\n';
const chunks = ['{"result":{"audioContent":"UklGRg=="}}',
  '{"result":{"audioContent":"AAE="}}', '{"result":{"audioContent":"Av8="}}'];
const sourcePaths = [
  'extensions/inworld/speech-provider.ts', 'extensions/inworld/tts.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/utf16-slice.ts',
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
];

// Authored expected values; none are obtained from capture helpers or the frozen fixture.
const expected = [
  { id: 'default-file' },
  { id: 'configured', baseUrl: 'https://speech.example.test/prefix', voiceId: 'Ashley', modelId: 'inworld-tts-1.5-mini', temperature: 0.8,
    raw: { baseUrl: ' https://speech.example.test/prefix/// ', voiceId: '\u00a0\ufeff Ashley \ufeff\u00a0',
      modelId: '\ufeff\u00a0 inworld-tts-1.5-mini \u00a0\ufeff', temperature: 0.8 },
    resolved: { baseUrl: 'https://speech.example.test/prefix', voiceId: 'Ashley', modelId: 'inworld-tts-1.5-mini', temperature: 0.8 } },
  { id: 'provider-overrides', voiceId: 'Wendy', modelId: 'inworld-tts-1.5-mini', temperature: 1.1,
    raw: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-max', temperature: 0.8 },
    overrides: { voiceId: ' Wendy ', modelId: ' inworld-tts-1.5-mini ', temperature: 1.1 },
    resolved: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-max', temperature: 0.8 } },
  { id: 'partial-overrides', voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.5,
    raw: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.1 },
    overrides: { temperature: 1.5 }, resolved: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.1 } },
  { id: 'override-aliases', voiceId: 'Olivia', modelId: 'inworld-tts-1', temperature: 1.5,
    raw: { voiceId: 'Sarah', modelId: 'inworld-tts-1.5-max', temperature: 0.8 },
    overrides: { voice: ' Olivia ', model: ' inworld-tts-1 ', temperature: 1.5 },
    resolved: { voiceId: 'Sarah', modelId: 'inworld-tts-1.5-max', temperature: 0.8 } },
  { id: 'override-primary-fields', voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 0.8,
    overrides: { voiceId: ' Dennis ', voice: 'Sarah', modelId: ' inworld-tts-1.5-mini ',
      model: 'inworld-tts-1.5-max', temperature: 0.8 } },
  { id: 'default-note', target: 'voice-note' },
  { id: 'configured-note', target: 'voice-note', voiceId: 'Ashley', modelId: 'inworld-tts-1-max', temperature: 1.1,
    raw: { voiceId: 'Ashley', modelId: 'inworld-tts-1-max', temperature: 1.1 },
    resolved: { voiceId: 'Ashley', modelId: 'inworld-tts-1-max', temperature: 1.1 } },
  { id: 'telephony', target: 'telephony', voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.5,
    raw: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.5 },
    resolved: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.5 } },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  { id: 'multiple-audio-lines', ndjson: chunks.join('\n') + '\n' },
  { id: 'blank-lines', ndjson: `\n  \n\u00a0\ufeff  ${chunks[0]}  \ufeff\u00a0\n\t\n${chunks[1]}\n\n${chunks[2]}\n` },
  { id: 'metadata-lines', ndjson: ['{"requestId":"ordinary-request"}', chunks[0],
    '{"result":{"requestId":"ordinary-progress"}}', chunks[1], chunks[2]].join('\n') + '\n' },
  { id: 'base64-normalization', ndjson: '{"result":{"audioContent":" UklG Rg==\\t"}}\n' +
    '{"result":{"audioContent":"AAE"}}\n{"result":{"audioContent":"Av8"}}\n' },
];

test('14 ordinary original callbacks preserve literal config, request, response and result observations', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row.id));
  assert.equal(rows.size, 14);
  for (const want of expected) {
    const row = rows.get(want.id);
    const target = want.target ?? 'audio-file';
    const baseUrl = want.baseUrl ?? base;
    const encoding = target === 'telephony' ? 'PCM' : target === 'voice-note' ? 'OGG_OPUS' : 'MP3';
    const body = { text: want.text ?? text, voiceId: want.voiceId ?? 'Sarah',
      modelId: want.modelId ?? 'inworld-tts-1.5-max',
      audioConfig: { audioEncoding: encoding, ...(target === 'telephony' ? { sampleRateHertz: 22050 } : {}) },
      ...(want.temperature === undefined ? {} : { temperature: want.temperature }) };
    assert.deepEqual(row.input, { text: want.text ?? text, target, timeoutMs: 12345,
      rawConfig: { providers: { inworld: { apiKey: key, ...want.raw } } },
      ...(want.overrides ? { providerOverrides: want.overrides } : {}) }, want.id);
    assert.deepEqual(row.resolvedConfig, { ...defaults, ...want.resolved }, want.id);
    // Supplied headers remain recorded provenance; no authentication-validity assertion.
    const { headers, ...request } = row.request;
    assert.deepEqual(request, { url: `${baseUrl}/tts/v1/voice:stream`, method: 'POST',
      path: want.baseUrl ? '/prefix/tts/v1/voice:stream' : '/tts/v1/voice:stream', query: {},
      body, bodyText: JSON.stringify(body), timeoutMs: 12345,
      policy: { hostnameAllowlist: [want.baseUrl ? 'speech.example.test' : 'api.inworld.ai'] },
      auditContext: 'inworld-tts' }, want.id);
    assert.deepEqual(row.response, { status: 200, ndjson: want.ndjson ?? singleNdjson,
      audioChunksBase64: want.ndjson ? ['UklGRg==', 'AAE=', 'Av8='] : ['UklGRgABAv8='], audioBase64 }, want.id);
    assert.deepEqual(row.result, target === 'telephony'
      ? { audioBase64, outputFormat: 'pcm', sampleRate: 22050 }
      : { audioBase64, outputFormat: encoding.toLowerCase(), fileExtension: target === 'voice-note' ? '.ogg' : '.mp3',
        voiceCompatible: target === 'voice-note' }, want.id);
    assert.deepEqual(row.inputAfter, row.input, want.id);
    assert.equal(row.releaseCount, 1, want.id);
  }
});

test('nested raw config, JS trim and partial provider overrides preserve explicit precedence', () => {
  assert.deepEqual(rows.get('default-file').resolvedConfig, defaults);
  const configured = rows.get('configured');
  assert.equal(configured.input.rawConfig.providers.inworld.voiceId, '\u00a0\ufeff Ashley \ufeff\u00a0');
  assert.equal(configured.resolvedConfig.voiceId, 'Ashley');
  assert.equal(configured.resolvedConfig.modelId, 'inworld-tts-1.5-mini');
  assert.equal(configured.request.url, 'https://speech.example.test/prefix/tts/v1/voice:stream');
  const overrides = rows.get('provider-overrides');
  assert.equal(overrides.resolvedConfig.voiceId, 'Dennis');
  assert.equal(overrides.resolvedConfig.temperature, 0.8);
  assert.equal(overrides.request.body.voiceId, 'Wendy');
  assert.equal(overrides.request.body.temperature, 1.1);
  assert.equal(rows.get('partial-overrides').request.body.voiceId, 'Dennis');
  assert.equal(rows.get('partial-overrides').request.body.modelId, 'inworld-tts-1.5-mini');
  assert.equal(rows.get('partial-overrides').request.body.temperature, 1.5);
});

test('ordinary raw voice/model override aliases and primary spellings execute original selection', () => {
  const aliases = rows.get('override-aliases');
  assert.deepEqual(aliases.input.providerOverrides, { voice: ' Olivia ', model: ' inworld-tts-1 ', temperature: 1.5 });
  assert.equal(aliases.request.body.voiceId, 'Olivia');
  assert.equal(aliases.request.body.modelId, 'inworld-tts-1');
  assert.equal(rows.get('override-primary-fields').request.body.voiceId, 'Dennis');
  assert.equal(rows.get('override-primary-fields').request.body.modelId, 'inworld-tts-1.5-mini');
  assert.match(capture.hostAdaptation.config, /voice_id\/model_id\/temperature\/base_url/);
});

test('file MP3, note OGG_OPUS and telephony PCM22050 are source metadata without codec decoding', () => {
  assert.deepEqual(rows.get('default-file').result,
    { audioBase64, outputFormat: 'mp3', fileExtension: '.mp3', voiceCompatible: false });
  assert.deepEqual(rows.get('default-note').result,
    { audioBase64, outputFormat: 'ogg_opus', fileExtension: '.ogg', voiceCompatible: true });
  assert.deepEqual(rows.get('telephony').request.body.audioConfig, { audioEncoding: 'PCM', sampleRateHertz: 22050 });
  assert.deepEqual(rows.get('telephony').result, { audioBase64, outputFormat: 'pcm', sampleRate: 22050 });
  assert.equal(rows.get('authored-text').request.body.text, '  Ordinary speech.\n你好 🌍 — café.\t ');
});

test('original NDJSON parsing preserves exact opaque bytes across records and ordinary whitespace', () => {
  for (const id of ['multiple-audio-lines', 'blank-lines', 'metadata-lines', 'base64-normalization']) {
    const row = rows.get(id);
    assert.deepEqual([...Buffer.from(row.result.audioBase64, 'base64')], [82, 73, 70, 70, 0, 1, 2, 255], id);
    assert.equal(row.result.audioBase64, 'UklGRgABAv8=', id);
  }
  assert.match(rows.get('blank-lines').response.ndjson, /\u00a0\ufeff/);
  assert.match(rows.get('metadata-lines').response.ndjson, /ordinary-progress/);
  assert.deepEqual(rows.get('base64-normalization').response.ndjson.split('\n').filter(Boolean).map(line => JSON.parse(line).result.audioContent),
    [' UklG Rg==\t', 'AAE', 'Av8']);
});

test('provider metadata comes from original source and successful synthetic reads release once', () => {
  for (const row of rows.values()) {
    assert.deepEqual(row.providerMetadata, { id: 'inworld', label: 'Inworld', autoSelectOrder: 30,
      defaultModel: 'inworld-tts-1.5-max', models: ['inworld-tts-1.5-max', 'inworld-tts-1.5-mini', 'inworld-tts-1-max', 'inworld-tts-1'] });
    assert.deepEqual(row.platformCalls, [
      { module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString', path: 'tts.providers.inworld.apiKey' },
      { module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString', path: 'tts.providers.inworld.apiKey' },
      { module: 'openclaw/plugin-sdk/ssrf-runtime', export: 'fetchWithSsrFGuard' },
      { module: 'openclaw/plugin-sdk/response-limit-runtime', export: 'readResponseWithLimit', maxBytes: 33554432,
        chunkTimeoutMs: 30000, overflowCallbackProvided: true, idleCallbackProvided: true },
      { module: 'openclaw/plugin-sdk/ssrf-runtime', export: 'release' },
    ], row.id);
  }
  assert.deepEqual(capture.counts, { observations: 14, synthesisCallbacks: 13, telephonyCallbacks: 1,
    httpRequests: 14, releases: 14, wholeModules: 11, trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('complete original modules, export facades and plugin manifest have pinned provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(INWORLD_SPEECH_PIN, capture.referencePin);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${INWORLD_SPEECH_PIN}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })));
    assert.equal(audit.gitBlob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
    assert.equal(audit.wholeModule, true);
    assert.equal(audit.executed, true);
  }
  assert.deepEqual(capture.dataAudit.map(audit => audit.path), ['extensions/inworld/openclaw.plugin.json']);
  const manifestBytes = readFileSync(join(root, 'extensions/inworld/openclaw.plugin.json'));
  assert.deepEqual(manifestBytes, execFileSync('git', ['show', `${INWORLD_SPEECH_PIN}:extensions/inworld/openclaw.plugin.json`], { cwd: root }));
  assert.equal(capture.dataAudit[0].sourceSha256, hash(manifestBytes));
  assert.equal(capture.dataAudit[0].gitBlob,
    createHash('sha1').update(`blob ${manifestBytes.length}\0`).update(manifestBytes).digest('hex'));
  assert.deepEqual(capture.pluginManifest, JSON.parse(manifestBytes));
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.checkout.before.commit, INWORLD_SPEECH_PIN);
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-inworld-speech.mjs', import.meta.url))));
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source));
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export \{ .* \} from ".*";$/.test(line)));
  }
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier),
    ['openclaw/plugin-sdk/media-runtime', 'openclaw/plugin-sdk/ssrf-runtime']);
});

test('synthetic transport/reader and complete original media constants stay explicit', () => {
  assert.deepEqual(capture.environmentFixture, { env: {}, cfg: {} });
  assert.deepEqual(capture.platformBoundaries.map(boundary => boundary.module), [
    'openclaw/plugin-sdk/secret-input', 'node:fs', 'openclaw/plugin-sdk/response-limit-runtime', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
  for (const boundary of capture.platformBoundaries) assert.equal(boundary.originalSourceExecuted, false);
  for (const term of ['process.env={}', '16 MiB', '32 MiB', '12345 ms', '2000 ms', 'production bounded/idle reader',
    'canonicalizeBase64', 'NDJSON parser', 'native publication remains MP3', 'listVoices']) {
    assert.ok([...capture.limits, ...Object.values(capture.hostAdaptation)].some(limit => limit.includes(term)), term);
  }
});

test('fresh isolated source capture equals the parent-generated frozen fixture', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});

test('documented CLI writes a fresh capture exactly equal to the frozen fixture', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-inworld-speech-'));
  try {
    const output = join(temporary, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-inworld-speech.mjs', import.meta.url)), '--source', root, '--output', output],
    { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(readFileSync(output)), JSON.parse(readFileSync(fixture)));
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
