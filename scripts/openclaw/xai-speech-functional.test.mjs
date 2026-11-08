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
import { XAI_SPEECH_PIN, runXaiSpeechCapture } from './capture-xai-speech.mjs';

const root = process.env.OPENCLAW_XAI_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_XAI_SPEECH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/xai-speech.json', import.meta.url);
const capture = await runXaiSpeechCapture(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const key = 'fixture-xai-speech';
const base = 'https://api.x.ai/v1';
const text = 'Plain speech fixture.';
const defaults = { apiKey: key, baseUrl: base, voiceId: 'eve' };
const audioBase64 = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]).toString('base64');
const sourcePaths = [
  'extensions/xai/speech-provider.ts', 'extensions/xai/speech-provider-metadata.ts',
  'extensions/xai/speech-provider-metadata-factory.ts', 'extensions/xai/tts.ts',
  'extensions/xai/model-definitions.ts', 'extensions/xai/model-id.ts',
  'extensions/xai/src/xai-user-agent.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/error-coercion.ts',
  'packages/normalization-core/src/utf16-slice.ts', 'packages/media-core/src/base64.ts',
  'src/infra/ws.ts', 'packages/gateway-client/src/websocket-data.ts',
];

// Literal expected differences from eve/en/mp3; no expectations are read from a fixture or source helper.
const expected = [
  { id: 'default-file' },
  { id: 'configured', baseUrl: 'https://speech.example.test/prefix', voiceId: 'ara', language: 'pt-br', speed: 1.15,
    format: 'wav', resolved: { baseUrl: 'https://speech.example.test/prefix', voiceId: 'ara', language: 'pt-br', speed: 1.15, responseFormat: 'wav' } },
  { id: 'raw-aliases', voiceId: 'leo', language: 'zh-cn', speed: 0.95,
    resolved: { voiceId: 'leo', language: 'zh-cn', speed: 0.95 } },
  { id: 'primary-config-fields', voiceId: 'rex', language: 'fr', resolved: { voiceId: 'rex', language: 'fr' } },
  { id: 'provider-overrides', voiceId: 'sal', language: 'ja', speed: 1.2, format: 'wav',
    resolved: { voiceId: 'ara', language: 'de', speed: 0.9, responseFormat: 'wav' } },
  { id: 'partial-overrides', voiceId: 'rex', language: 'fr', speed: 1.1,
    resolved: { voiceId: 'leo', language: 'fr', speed: 1.1 } },
  { id: 'language-auto', language: 'auto', resolved: { language: 'auto' } },
  { id: 'language-bcp', language: 'es-mx', resolved: { language: 'es-mx' } },
  { id: 'file-mp3', resolved: { responseFormat: 'mp3' } },
  { id: 'file-wav', format: 'wav', resolved: { responseFormat: 'wav' } },
  { id: 'file-pcm', format: 'pcm', resolved: { responseFormat: 'pcm' } },
  { id: 'file-mulaw', format: 'mulaw', resolved: { responseFormat: 'mulaw' } },
  { id: 'file-alaw', format: 'alaw', resolved: { responseFormat: 'alaw' } },
  { id: 'default-note' },
  { id: 'note-configured-wav', voiceId: 'ara', language: 'de', speed: 1.1,
    resolved: { voiceId: 'ara', language: 'de', speed: 1.1, responseFormat: 'wav' } },
  { id: 'telephony', voiceId: 'leo', language: 'pt-br', speed: 1.15, format: 'pcm',
    resolved: { voiceId: 'leo', language: 'pt-br', speed: 1.15, responseFormat: 'mp3' } },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
];

test('17 ordinary callbacks preserve independent complete config, request and opaque result expectations', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row.id));
  assert.equal(rows.size, 17);
  for (const want of expected) {
    const row = rows.get(want.id);
    const baseUrl = want.baseUrl ?? base;
    const format = want.format ?? 'mp3';
    const body = { text: want.text ?? text, voice_id: want.voiceId ?? 'eve', language: want.language ?? 'en',
      output_format: { codec: format }, ...(want.speed === undefined ? {} : { speed: want.speed }) };
    assert.deepEqual(row.resolvedConfig, { ...defaults, ...want.resolved }, want.id);
    assert.deepEqual(row.request, { url: `${baseUrl}/tts`, method: 'POST',
      path: want.baseUrl ? '/prefix/tts' : '/v1/tts', query: {},
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json',
        ...(want.baseUrl ? {} : { 'user-agent': 'openclaw/2026.10.5' }) },
      body, bodyText: JSON.stringify(body), timeoutMs: 12345,
      policy: { fixture: 'xai-origin-policy', baseUrl }, auditContext: 'xai tts', fetchInvoked: false }, want.id);
    assert.deepEqual(row.result, want.id === 'telephony'
      ? { audioBase64, outputFormat: 'pcm', sampleRate: 24000 }
      : { audioBase64, outputFormat: format, fileExtension: `.${format}`, voiceCompatible: false }, want.id);
    assert.deepEqual(row.inputAfter, row.input, want.id);
    assert.equal(row.releaseCount, 1, want.id);
  }
});

test('resolveConfig consumes nested raw config and individual overrides take precedence', () => {
  assert.deepEqual(rows.get('default-file').input.rawConfig, { providers: { xai: { apiKey: key } } });
  assert.deepEqual(rows.get('default-file').resolvedConfig, defaults);
  assert.deepEqual(rows.get('default-file').request.body,
    { text, voice_id: 'eve', language: 'en', output_format: { codec: 'mp3' } });
  const configured = rows.get('configured');
  assert.equal(configured.input.rawConfig.providers.xai.baseUrl, ' https://speech.example.test/prefix/// ');
  assert.equal(configured.resolvedConfig.baseUrl, 'https://speech.example.test/prefix');
  assert.equal(configured.request.url, 'https://speech.example.test/prefix/tts');
  assert.deepEqual(rows.get('provider-overrides').input.providerOverrides,
    { voiceId: ' sal ', language: ' JA ', speed: 1.2 });
  assert.equal(rows.get('provider-overrides').resolvedConfig.voiceId, 'ara');
  assert.equal(rows.get('provider-overrides').request.body.voice_id, 'sal');
  assert.equal(rows.get('provider-overrides').request.body.language, 'ja');
  assert.equal(rows.get('provider-overrides').request.body.speed, 1.2);
  assert.deepEqual(rows.get('partial-overrides').request.body,
    { text, voice_id: 'rex', language: 'fr', output_format: { codec: 'mp3' }, speed: 1.1 });
});

test('raw aliases and language normalization remain source observations behind the explicit host atom API', () => {
  const aliases = rows.get('raw-aliases');
  assert.equal(aliases.input.rawConfig.providers.xai.voice, ' leo ');
  assert.equal(aliases.input.rawConfig.providers.xai.languageCode, ' ZH-CN ');
  assert.equal(aliases.resolvedConfig.voiceId, 'leo');
  assert.equal(aliases.request.body.language, 'zh-cn');
  assert.equal(rows.get('primary-config-fields').request.body.voice_id, 'rex');
  assert.equal(rows.get('primary-config-fields').request.body.language, 'fr');
  assert.equal(rows.get('language-auto').request.body.language, 'auto');
  assert.equal(rows.get('language-bcp').request.body.language, 'es-mx');
  assert.match(capture.hostAdaptation.config, /voice_id\/language\/speed\/response_format\/base_url/);
});

test('format metadata, voice-note MP3 and telephony PCM are planned without audio decoding', () => {
  for (const format of ['mp3', 'wav', 'pcm', 'mulaw', 'alaw']) {
    assert.deepEqual(rows.get(`file-${format}`).result,
      { audioBase64, outputFormat: format, fileExtension: `.${format}`, voiceCompatible: false });
  }
  assert.equal(rows.get('note-configured-wav').resolvedConfig.responseFormat, 'wav');
  assert.equal(rows.get('note-configured-wav').request.body.output_format.codec, 'mp3');
  assert.equal(rows.get('default-note').result.voiceCompatible, false);
  const telephony = rows.get('telephony');
  assert.equal(telephony.resolvedConfig.responseFormat, 'mp3');
  assert.equal(telephony.request.body.output_format.codec, 'pcm');
  assert.deepEqual(telephony.result, { audioBase64, outputFormat: 'pcm', sampleRate: 24000 });
  for (const row of rows.values()) {
    assert.deepEqual(Object.keys(row.result), row.id === 'telephony'
      ? ['audioBase64', 'outputFormat', 'sampleRate']
      : ['audioBase64', 'outputFormat', 'fileExtension', 'voiceCompatible']);
  }
});

test('provider metadata and native-origin User-Agent come from the complete original modules', () => {
  for (const row of rows.values()) {
    assert.deepEqual(row.providerMetadata, { id: 'xai', label: 'xAI', autoSelectOrder: 25,
      models: [], voices: ['ara', 'eve', 'leo', 'rex', 'sal'] }, row.id);
  }
  assert.equal(rows.get('default-file').request.headers['user-agent'], 'openclaw/2026.10.5');
  assert.deepEqual(rows.get('configured').request.headers,
    { authorization: `Bearer ${key}`, 'content-type': 'application/json' });
  assert.match(capture.hostAdaptation.headers, /host retains its Req identity/);
});

test('each synthetic successful request forwards reader options and releases once without invoking fetch', () => {
  for (const row of rows.values()) {
    assert.deepEqual(row.platformCalls, [
      { module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString', path: 'tts.providers.xai.apiKey' },
      { module: 'openclaw/plugin-sdk/media-generation-runtime', export: 'resolveGeneratedMediaMaxBytes', kind: 'audio' },
      { module: 'openclaw/plugin-sdk/ssrf-runtime', export: 'ssrfPolicyFromHttpBaseUrlAllowedOrigin',
        baseUrl: row.id === 'configured' ? 'https://speech.example.test/prefix' : base },
      { module: 'openclaw/plugin-sdk/provider-http', export: 'postJsonRequest' },
      { module: 'openclaw/plugin-sdk/provider-http', export: 'assertOkOrThrowProviderError', label: 'xAI TTS API error' },
      { module: 'openclaw/plugin-sdk/provider-http', export: 'readProviderBinaryResponse', label: 'xAI TTS API error',
        kind: 'audio', maxBytes: 16777216, overflowCallbackProvided: true, overflowCallbackInvoked: false },
      { module: 'openclaw/plugin-sdk/provider-http', export: 'release' },
    ], row.id);
  }
  assert.deepEqual(capture.counts, { observations: 17, synthesisCallbacks: 16, telephonyCallbacks: 1,
    httpRequests: 17, releases: 17, wholeModules: 17, trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('complete original TypeScript and JSON sources have pinned byte and transformation provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(XAI_SPEECH_PIN, capture.referencePin);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${XAI_SPEECH_PIN}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })));
    assert.equal(audit.gitBlob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
    assert.equal(audit.wholeModule, true);
    assert.equal(audit.executed, true);
  }
  assert.deepEqual(capture.dataAudit.map(audit => audit.path), ['extensions/xai/openclaw.plugin.json', 'package.json']);
  for (const audit of capture.dataAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${XAI_SPEECH_PIN}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.gitBlob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
  }
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.checkout.before.commit, XAI_SPEECH_PIN);
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-xai-speech.mjs', import.meta.url))));
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source));
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export \{ .* \} from ".*";$/.test(line)));
  }
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier), [
    'openclaw/plugin-sdk/media-generation-runtime', 'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
});

test('synthetic environment, HTTP, version and uninvoked socket/profile boundaries stay explicit', () => {
  assert.deepEqual(capture.environmentFixture, { env: {}, cfg: {}, artifactVersion: '2026.10.5' });
  assert.deepEqual(capture.platformBoundaries.map(boundary => boundary.module), [
    'openclaw/plugin-sdk/provider-auth', 'openclaw/plugin-sdk/provider-auth-runtime',
    'openclaw/plugin-sdk/secret-input', 'openclaw/plugin-sdk/agent-harness-registration',
    'extensions/xai/ws-runtime.ts', 'node:buffer', 'openclaw/plugin-sdk/media-generation-runtime',
    'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
  for (const boundary of capture.platformBoundaries) assert.equal(boundary.originalSourceExecuted, false);
  for (const term of ['process.env={}', '16 MiB', '12345 ms', '2000 ms', 'production bounded reader',
    'bodyText', 'listVoices', 'directive parsing', 'Telephony forces pcm', 'MP3/WAV', 'Req identity']) {
    assert.ok(capture.limits.some(limit => limit.toLowerCase().includes(term.toLowerCase())), term);
  }
});

test('fresh isolated source capture equals the parent-generated frozen fixture', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});

test('documented CLI writes a fresh capture exactly equal to the frozen fixture', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-xai-speech-'));
  try {
    const output = join(temporary, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-xai-speech.mjs', import.meta.url)), '--source', root, '--output', output],
    { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(readFileSync(output)), JSON.parse(readFileSync(fixture)));
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
