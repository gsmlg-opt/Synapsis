// Ordinary successful source-backed OpenAI speech requests; no provider connection.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import { OPENAI_SPEECH_PIN, runOpenAISpeechCapture } from './capture-openai-speech.mjs';

const root = process.env.OPENCLAW_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const capture = await runOpenAISpeechCapture(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const text = 'Plain speech fixture.';
const key = 'fixture-openai-speech';
const base = 'https://api.openai.com/v1';
const groq = 'https://api.groq.com/openai/v1';
const custom = 'https://speech.example.test/v1';
const audioBase64 = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]).toString('base64');
const defaults = { apiKey: key, baseUrl: base, model: 'gpt-4o-mini-tts', voice: 'coral' };

// Expected requests are explicit wire contracts, independent of capture recipes.
const expected = [
  { id: 'default-file', target: 'audio-file', raw: { apiKey: key }, resolved: defaults,
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'mp3' }, format: 'mp3', compatible: false },
  { id: 'default-note', target: 'voice-note', raw: { apiKey: key }, resolved: defaults,
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'opus' }, format: 'opus', compatible: true },
  { id: 'file-opus', target: 'audio-file', raw: { apiKey: key, responseFormat: 'opus' }, resolved: { ...defaults, responseFormat: 'opus' },
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'opus' }, format: 'opus', compatible: false },
  { id: 'note-wav', target: 'voice-note', raw: { apiKey: key, responseFormat: ' WAV ' }, resolved: { ...defaults, responseFormat: 'wav' },
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'wav' }, format: 'wav', compatible: false },
  { id: 'file-wav', target: 'audio-file', raw: { apiKey: key, responseFormat: 'wav' }, resolved: { ...defaults, responseFormat: 'wav' },
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'wav' }, format: 'wav', compatible: false },
  { id: 'groq-file', target: 'audio-file', raw: { apiKey: key, baseUrl: groq, model: 'playai-tts', voice: 'Fritz-PlayAI' },
    resolved: { apiKey: key, baseUrl: groq, model: 'playai-tts', voice: 'Fritz-PlayAI' },
    body: { model: 'playai-tts', input: text, voice: 'Fritz-PlayAI', response_format: 'wav' }, format: 'wav', compatible: false },
  { id: 'groq-note', target: 'voice-note', raw: { apiKey: key, baseUrl: groq, model: 'playai-tts', voice: 'Fritz-PlayAI' },
    resolved: { apiKey: key, baseUrl: groq, model: 'playai-tts', voice: 'Fritz-PlayAI' },
    body: { model: 'playai-tts', input: text, voice: 'Fritz-PlayAI', response_format: 'wav' }, format: 'wav', compatible: false },
  { id: 'configured-openai', target: 'audio-file', raw: { apiKey: key, model: ' gpt-4o-mini-tts-2025-12-15 ', voice: ' nova ', speed: 1.25, instructions: ' Speak evenly. ' },
    resolved: { ...defaults, model: 'gpt-4o-mini-tts-2025-12-15', voice: 'nova', speed: 1.25, instructions: 'Speak evenly.' },
    body: { model: 'gpt-4o-mini-tts-2025-12-15', input: text, voice: 'nova', response_format: 'mp3', speed: 1.25, instructions: 'Speak evenly.' }, format: 'mp3', compatible: false },
  { id: 'legacy-model', target: 'audio-file', raw: { apiKey: key, model: 'tts-1', instructions: ' Speak evenly. ' },
    resolved: { ...defaults, model: 'tts-1', instructions: 'Speak evenly.' },
    body: { model: 'tts-1', input: text, voice: 'coral', response_format: 'mp3' }, format: 'mp3', compatible: false },
  { id: 'custom-voice-model', target: 'audio-file', raw: { apiKey: key, baseUrl: ' https://speech.example.test/v1/// ', model: 'local-voice-model', voice: 'speaker-7', speed: 4.5, instructions: ' Speak warmly. ' },
    resolved: { apiKey: key, baseUrl: custom, model: 'local-voice-model', voice: 'speaker-7', speed: 4.5, instructions: 'Speak warmly.' },
    body: { model: 'local-voice-model', input: text, voice: 'speaker-7', response_format: 'mp3', speed: 4.5, instructions: 'Speak warmly.' }, format: 'mp3', compatible: false },
  { id: 'provider-overrides', target: 'audio-file', raw: { apiKey: key, model: 'tts-1', voice: 'alloy', speed: 1.1 },
    overrides: { model: 'tts-1-hd', voice: 'echo', speed: 1.5 }, resolved: { ...defaults, model: 'tts-1', voice: 'alloy', speed: 1.1 },
    body: { model: 'tts-1-hd', input: text, voice: 'echo', response_format: 'mp3', speed: 1.5 }, format: 'mp3', compatible: false },
  { id: 'extra-body-fields', target: 'audio-file', raw: { apiKey: key, extraBody: { language: 'en', seed: 7 } },
    resolved: { ...defaults, extraBody: { language: 'en', seed: 7 } },
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'mp3', language: 'en', seed: 7 }, format: 'mp3', compatible: false },
  { id: 'extra-body-final-wins', target: 'audio-file', raw: { apiKey: key, speed: 1.1, extra_body: { model: 'tts-1-hd', input: 'Replacement plain speech.', speed: 0.8 } },
    resolved: { ...defaults, speed: 1.1, extraBody: { model: 'tts-1-hd', input: 'Replacement plain speech.', speed: 0.8 } },
    body: { model: 'tts-1-hd', input: 'Replacement plain speech.', voice: 'coral', response_format: 'mp3', speed: 0.8 }, format: 'mp3', compatible: false },
  { id: 'telephony', target: 'telephony', raw: { apiKey: key, responseFormat: 'wav' }, resolved: { ...defaults, responseFormat: 'wav' },
    body: { model: 'gpt-4o-mini-tts', input: text, voice: 'coral', response_format: 'pcm' }, format: 'pcm' },
];

test('fourteen ordinary speech callbacks preserve explicit configuration, wire content and exact bytes', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row.id));
  for (const [index, want] of expected.entries()) {
    const row = capture.observations[index];
    assert.deepEqual(row.input, { text, target: want.target, timeoutMs: 12345,
      providerConfig: want.raw, ...(want.overrides ? { providerOverrides: want.overrides } : {}) }, want.id);
    assert.deepEqual(row.resolvedConfig, want.resolved, want.id);
    assert.deepEqual(row.request, { url: `${want.resolved.baseUrl}/audio/speech`, method: 'POST',
      body: want.body, timeoutMs: 12345 }, want.id);
    assert.deepEqual(row.result, want.format === 'pcm'
      ? { audioBase64, outputFormat: 'pcm', sampleRate: 24000 }
      : { audioBase64, outputFormat: want.format, fileExtension: `.${want.format}`, voiceCompatible: want.compatible }, want.id);
    assert.equal(row.releaseCount, 1, want.id);
    for (const name of ['resolveGeneratedMediaMaxBytes', 'fetchWithSsrFGuard', 'readProviderBinaryResponse', 'captureHttpExchangeAsync', 'release']) {
      assert.equal(row.platformCalls.filter(call => call.export === name).length, 1, `${want.id}: ${name}`);
    }
    const read = row.platformCalls.find(call => call.export === 'readProviderBinaryResponse');
    assert.equal(read.maxBytes, 16 * 1024 * 1024, want.id);
  }
});

test('complete pinned modules and explicit SDK facades have exact source and transformed provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, OPENAI_SPEECH_PIN);
  assert.deepEqual(capture.sourceAudit.map(item => item.path), [
    'extensions/openai/speech-provider.ts', 'extensions/openai/realtime-provider-shared.ts',
    'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
    'packages/normalization-core/src/record-coerce.ts',
  ]);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${OPENAI_SPEECH_PIN}:${audit.path}`], { cwd: root }));
    assert.equal(audit.gitBlob, execFileSync('git', ['rev-parse', `${OPENAI_SPEECH_PIN}:${audit.path}`], { cwd: root, encoding: 'utf8' }).trim());
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })));
    assert.equal(audit.wholeModule, true);
    assert.equal(audit.executed, true);
  }
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-openai-speech.mjs', import.meta.url))));
  assert.deepEqual(capture.transformation.sdkFacades.map(item => item.module), [
    'openclaw/plugin-sdk/string-coerce-runtime', 'openclaw/plugin-sdk/number-runtime',
  ]);
  for (const facade of capture.transformation.sdkFacades) assert.equal(facade.sha256, hash(facade.source));
  assert.equal(capture.transformation.sdkFacades[0].source,
    'export { asFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeLowercaseStringOrEmpty, normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n');
  assert.equal(capture.transformation.sdkFacades[1].source,
    'export { resolveExpiresAtMsFromEpochSeconds } from "packages/normalization-core/src/number-coercion.ts";\n');
  assert.ok(capture.transformation.staticImports.some(item => item.importer === 'packages/normalization-core/src/number-coercion.ts' && item.specifier === './string-coerce.ts' && item.resolved === 'packages/normalization-core/src/string-coerce.ts'));
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier), [
    'openclaw/plugin-sdk/media-generation-runtime', 'openclaw/plugin-sdk/provider-http',
    'openclaw/plugin-sdk/proxy-capture', 'openclaw/plugin-sdk/ssrf-runtime', 'openclaw/plugin-sdk/media-runtime',
  ]);
});

test('declared synthetic boundaries and narrow execution limits remain explicit', () => {
  assert.deepEqual(capture.platformBoundaries.map(item => item.module), [
    'openclaw/plugin-sdk/secret-input', 'openclaw/plugin-sdk/speech-provider',
    'openclaw/plugin-sdk/media-generation-runtime', 'openclaw/plugin-sdk/provider-http',
    'openclaw/plugin-sdk/proxy-capture', 'openclaw/plugin-sdk/ssrf-runtime', 'openclaw/plugin-sdk/media-runtime',
  ]);
  for (const item of capture.platformBoundaries) assert.equal(item.originalSourceExecuted, false);
  for (const term of ['process.env', '16 MiB', 'voice compatibility', 'directive', 'synthetic successful HTTP', 'registration']) {
    assert.ok(capture.limits.some(value => value.includes(term)), term);
  }
});

test('fresh isolated captures reproduce the frozen ordinary observations exactly', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-speech.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await runOpenAISpeechCapture(root), frozen);
});
