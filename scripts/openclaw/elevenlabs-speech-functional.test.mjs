// Positive ordinary synthesis contracts only; no production provider connection.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import { ELEVENLABS_SPEECH_PIN, runElevenLabsSpeechCapture } from './capture-elevenlabs-speech.mjs';

const root = process.env.OPENCLAW_ELEVENLABS_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const capture = await runElevenLabsSpeechCapture(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const key = 'fixture-elevenlabs-speech';
const base = 'https://api.elevenlabs.io';
const voice = 'pMsXgVXv3BLzUgSXRplE';
const model = 'eleven_multilingual_v2';
const text = 'Plain speech fixture.';
const voiceSettings = { stability: 0.5, similarityBoost: 0.75, style: 0, useSpeakerBoost: true, speed: 1 };
const defaults = { apiKey: key, baseUrl: base, voiceId: voice, modelId: model, voiceSettings };
const wireSettings = { stability: 0.5, similarity_boost: 0.75, style: 0, use_speaker_boost: true, speed: 1 };
const audioBase64 = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]).toString('base64');
const lower = { stability: 0, similarityBoost: 0, style: 0, useSpeakerBoost: false, speed: 0.5 };
const upper = { stability: 1, similarityBoost: 1, style: 1, useSpeakerBoost: true, speed: 2 };

// Independent expectations list every wire difference from the explicit defaults.
const expected = [
  { id: 'default-file' }, { id: 'default-note', format: 'opus_48000_64', extension: '.opus', compatible: true },
  { id: 'file-opus', format: 'opus_48000_64', extension: '.opus', compatible: true },
  { id: 'note-mp3', format: 'mp3_22050_32' },
  { id: 'file-wav', format: 'wav_44100', extension: '.wav' },
  { id: 'file-pcm', format: 'pcm_22050', extension: '.pcm' },
  { id: 'file-ulaw', format: 'ulaw_8000', extension: '.ulaw' },
  { id: 'file-alaw', format: 'alaw_8000', extension: '.alaw' },
  { id: 'other-format', format: 'flac_44100', extension: '.bin' },
  { id: 'format-spelling', format: 'OpUs_48000_64', extension: '.opus', compatible: true },
  { id: 'configured', baseUrl: 'https://speech.example.test/prefix', voiceId: 'ABCDEFGHIJ0123456789',
    resolved: { baseUrl: 'https://speech.example.test/prefix', voiceId: 'ABCDEFGHIJ0123456789', modelId: 'eleven_v3', seed: 17,
      applyTextNormalization: 'ON', languageCode: 'EN',
      voiceSettings: { stability: 0.3, similarityBoost: 0.6, style: 0.4, useSpeakerBoost: false, speed: 1.2 } },
    body: { model_id: 'eleven_v3', seed: 17, apply_text_normalization: 'on', language_code: 'en',
      voice_settings: { stability: 0.3, similarity_boost: 0.6, style: 0.4, use_speaker_boost: false, speed: 1.2 } } },
  { id: 'settings-lower', resolved: { voiceSettings: lower }, body: { voice_settings: { stability: 0, similarity_boost: 0, style: 0, use_speaker_boost: false, speed: 0.5 } } },
  { id: 'settings-upper', resolved: { voiceSettings: upper }, body: { voice_settings: { stability: 1, similarity_boost: 1, style: 1, use_speaker_boost: true, speed: 2 } } },
  { id: 'settings-partial', resolved: { voiceSettings: { ...voiceSettings, stability: 0.2, speed: 1.3 } },
    body: { voice_settings: { ...wireSettings, stability: 0.2, speed: 1.3 } } },
  { id: 'seed-zero', resolved: { seed: 0 }, body: { seed: 0 } },
  { id: 'seed-upper', resolved: { seed: 4294967295 }, body: { seed: 4294967295 } },
  { id: 'config-alias-turbo25', resolved: { modelId: 'eleven_flash_v2_5' }, body: { model_id: 'eleven_flash_v2_5' } },
  { id: 'config-alias-turbo2', resolved: { modelId: 'eleven_flash_v2' }, body: { model_id: 'eleven_flash_v2' } },
  { id: 'override-alias-turbo25', body: { model_id: 'eleven_flash_v2_5' } },
  { id: 'override-alias-turbo2', body: { model_id: 'eleven_flash_v2' } },
  { id: 'custom-model', resolved: { modelId: 'custom-speech-model' }, body: { model_id: 'custom-speech-model' } },
  { id: 'normalization-auto', resolved: { applyTextNormalization: 'AUTO', languageCode: 'DE' }, body: { apply_text_normalization: 'auto', language_code: 'de' } },
  { id: 'normalization-on', resolved: { applyTextNormalization: 'on', languageCode: 'fr' }, body: { apply_text_normalization: 'on', language_code: 'fr' } },
  { id: 'normalization-off', resolved: { applyTextNormalization: 'Off', languageCode: 'ZH' }, body: { apply_text_normalization: 'off', language_code: 'zh' } },
  { id: 'overrides', voiceId: '0123456789ABCDEFGHIJ', format: 'wav_44100', extension: '.wav', latency: '4',
    resolved: { voiceId: 'ABCDEFGHIJ0123456789', modelId: 'eleven_v3', seed: 17,
      applyTextNormalization: 'on', languageCode: 'de', voiceSettings: { ...voiceSettings, stability: 0.2, speed: 1.2 } },
    body: { model_id: 'eleven_flash_v2_5', seed: 0, apply_text_normalization: 'off', language_code: 'en',
      voice_settings: { stability: 0.2, similarity_boost: 0, style: 1, use_speaker_boost: false, speed: 0.5 } } },
  { id: 'override-settings-upper', body: { seed: 4294967295,
    voice_settings: { stability: 1, similarity_boost: 1, style: 1, use_speaker_boost: true, speed: 2 } } },
  { id: 'latency-zero', latency: '0' }, { id: 'latency-upper', latency: '4' },
  { id: 'v3-latency', resolved: { modelId: 'eleven_v3' }, body: { model_id: 'eleven_v3' } },
  { id: 'v3-override-latency', body: { model_id: 'ELEVEN_V3' } },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
];

test('31 complete ordinary callbacks preserve independently specified config, HTTP and opaque result maps', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row.id));
  assert.equal(rows.size, 31);
  for (const want of expected) {
    const row = rows.get(want.id);
    const format = want.format ?? 'mp3_44100_128';
    const query = { output_format: format, ...(want.latency !== undefined ? { optimize_streaming_latency: want.latency } : {}) };
    const path = `${want.baseUrl === undefined ? '' : '/prefix'}/v1/text-to-speech/${want.voiceId ?? voice}`;
    const url = new URL(`${want.baseUrl ?? base}/v1/text-to-speech/${want.voiceId ?? voice}`);
    for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
    const body = { text: want.text ?? text, model_id: model, voice_settings: wireSettings, ...want.body };
    assert.deepEqual(row.resolvedConfig, { ...defaults, ...want.resolved }, want.id);
    assert.deepEqual(row.request, { url: url.toString(), method: 'POST', path, query,
      headers: { 'xi-api-key': key, 'Content-Type': 'application/json',
        ...(format.toLowerCase().startsWith('mp3_') ? { Accept: 'audio/mpeg' } : {}) },
      body, bodyText: row.request.bodyText, timeoutMs: 12345, auditContext: 'elevenlabs.tts' }, want.id);
    assert.deepEqual(JSON.parse(row.request.bodyText), body, want.id);
    assert.deepEqual(row.result, { audioBase64, outputFormat: format,
      fileExtension: want.extension ?? '.mp3', voiceCompatible: want.compatible ?? false }, want.id);
    assert.deepEqual(row.inputAfter, row.input, want.id);
    assert.equal(row.releaseCount, 1, want.id);
  }
});

test('default provider metadata retains advertised inventory independently of effective model aliases', () => {
  const metadata = { id: 'elevenlabs', label: 'ElevenLabs', autoSelectOrder: 20, defaultModel: model,
    models: ['eleven_v3', 'eleven_multilingual_v2', 'eleven_flash_v2_5', 'eleven_flash_v2', 'eleven_turbo_v2_5', 'eleven_monolingual_v1'] };
  for (const row of rows.values()) assert.deepEqual(row.providerMetadata, metadata, row.id);
  assert.equal(rows.get('config-alias-turbo25').request.body.model_id, 'eleven_flash_v2_5');
  assert.equal(rows.get('custom-model').request.body.model_id, 'custom-speech-model');
});

test('nested raw configuration resolves before synthesis and overrides merge individually', () => {
  assert.deepEqual(rows.get('default-file').input.rawConfig, { providers: { elevenlabs: { apiKey: key } } });
  const configured = rows.get('configured');
  assert.equal(configured.input.rawConfig.providers.elevenlabs.languageCode, ' EN ');
  assert.equal(configured.resolvedConfig.languageCode, 'EN');
  assert.equal(configured.request.body.language_code, 'en');
  const row = rows.get('overrides');
  assert.equal(row.resolvedConfig.seed, 17);
  assert.equal(row.request.body.seed, 0);
  assert.equal(row.request.body.voice_settings.stability, 0.2);
  assert.equal(row.request.body.voice_settings.similarity_boost, 0);
  assert.equal(row.request.body.voice_settings.use_speaker_boost, false);
  assert.deepEqual(rows.get('default-file').request.body, { text, model_id: model, voice_settings: wireSettings });
});

test('format plans remain opaque and preserve spelling without adding MIME or sample-rate metadata', () => {
  assert.equal(rows.get('file-opus').result.voiceCompatible, true);
  assert.equal(rows.get('note-mp3').result.voiceCompatible, false);
  assert.equal(rows.get('file-pcm').result.fileExtension, '.pcm');
  assert.equal(rows.get('other-format').result.fileExtension, '.bin');
  assert.equal(rows.get('format-spelling').result.outputFormat, 'OpUs_48000_64');
  for (const row of rows.values()) assert.deepEqual(Object.keys(row.result), ['audioBase64', 'outputFormat', 'fileExtension', 'voiceCompatible']);
});

test('ordinary v3 requests omit latency while other models retain both inclusive latency bounds', () => {
  assert.deepEqual(rows.get('latency-zero').request.query, { output_format: 'mp3_44100_128', optimize_streaming_latency: '0' });
  assert.deepEqual(rows.get('latency-upper').request.query, { output_format: 'mp3_44100_128', optimize_streaming_latency: '4' });
  for (const id of ['v3-latency', 'v3-override-latency']) assert.deepEqual(rows.get(id).request.query, { output_format: 'mp3_44100_128' });
  assert.equal(rows.get('authored-text').request.body.text, '  Ordinary speech.\n你好 🌍 — café.\t ');
});

test('each successful source request consumes exact fixture bytes and releases once with no reader options', () => {
  for (const row of rows.values()) {
    assert.deepEqual(row.platformCalls.map(call => call.export), [
      'normalizeResolvedSecretInputString', 'normalizeResolvedSecretInputString',
      'resolveElevenLabsApiKeyWithProfileFallback', 'ssrfPolicyFromHttpBaseUrlAllowedHostname',
      'fetchWithSsrFGuard', 'assertOkOrThrowProviderError', 'readProviderBinaryResponse', 'release',
    ], row.id);
    assert.deepEqual(row.platformCalls[6], { module: 'openclaw/plugin-sdk/provider-http', export: 'readProviderBinaryResponse',
      label: 'ElevenLabs API error', kind: 'audio', optionsProvided: false }, row.id);
  }
  assert.deepEqual(capture.counts, { observations: 31, synthesisCallbacks: 31, httpRequests: 31,
    releases: 31, wholeModules: 10, trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('all complete source modules have exact pinned byte and TypeScript-erasure provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.referencePin, ELEVENLABS_SPEECH_PIN);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), [
    'extensions/elevenlabs/speech-provider-factory.ts', 'extensions/elevenlabs/shared.ts',
    'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts', 'src/utils/boolean.ts',
    'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/constants.ts',
  ]);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${ELEVENLABS_SPEECH_PIN}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })));
    assert.equal(audit.gitBlob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
    assert.equal(audit.wholeModule, true);
    assert.equal(audit.executed, true);
  }
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-elevenlabs-speech.mjs', import.meta.url))));
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source));
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export \{ .* \} from ".*";$/.test(line)));
  }
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier), [
    'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
});

test('declared platform and publication limits keep unexecuted surfaces explicit', () => {
  assert.deepEqual(capture.platformBoundaries.map(item => item.module), [
    'openclaw/plugin-sdk/secret-input', 'extensions/elevenlabs/config-api.ts', 'node:fs',
    'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
  for (const boundary of capture.platformBoundaries) assert.equal(boundary.originalSourceExecuted, false);
  for (const term of ['16 MiB', '2000 ms', 'streamSynthesize', 'listVoices', 'synthesizeTelephony',
    'directive parsing', 'plugin registration', 'MP3/Opus/WAV', 'process.env={}']) {
    assert.ok(capture.limits.some(value => value.includes(term)), term);
  }
});

test('fresh isolated source capture exactly reproduces the frozen fixture', () => {
  const fixture = process.env.OPENCLAW_ELEVENLABS_SPEECH_FIXTURE
    ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/elevenlabs-speech.json', import.meta.url);
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});
