// Ordinary synthetic successful transcription only. No provider connection.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenAITranscription } from './capture-openai-transcription.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureOpenAITranscription(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const expected = [
  ['default-wav', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['explicit-model', 'voice.wav', 'audio/wav', 'gpt-4o-mini-transcribe', 'Plain transcript.'],
  ['language-prompt-unicode', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['blank-optional-fields', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['filename-basename', 'voice note.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['aac-extension', 'VOICE.m4a', 'audio/aac', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['aac-extensionless', 'voice.m4a', 'audio/aac', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['mime-default', 'voice.wav', 'application/octet-stream', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['custom-base', 'voice.wav', 'audio/wav', 'Vendor/Model-X', 'Plain transcript.'],
  ['response-unicode', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'A  e\u0301 😀\r\nZ'],
  ['silence', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', ''],
  ['ignored-query', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['buffer-subrange', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['native-mime-case', 'voice.wav', 'audio/wav; codecs=pcm', 'gpt-4o-transcribe', 'Plain transcript.'],
  ['raw-json-bom', 'voice.wav', 'audio/wav', 'gpt-4o-transcribe', 'JSON BOM transcript.'],
];

// A valid tiny mono PCM WAV: 8 kHz, 16 bits, two samples. No audio codec runs.
const audioBase64 = 'UklGRigAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQQAAAAAANB/';

test('fifteen ordinary complete-source requests preserve multipart fields, bytes, results and releases', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row[0]));
  for (const [id, name, type, model, text] of expected) {
    const row = rows.get(id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.request.url, id === 'custom-base'
      ? 'https://transcription.example.test/v1/audio/transcriptions'
      : 'https://api.openai.com/v1/audio/transcriptions', id);
    assert.equal(row.request.method, 'POST', id);
    assert.equal(row.request.timeoutMs, 12345, id);
    const fields = id === 'language-prompt-unicode' ? { model, language: 'EN-us', prompt: '名称 Ada 😀' } : { model };
    assert.deepEqual(row.request.fields, fields, id);
    assert.deepEqual(row.request.fieldOrder, [...Object.keys(fields), 'file'], id);
    assert.deepEqual(row.request.file, { name, blobType: type, effectivePartMime: type,
      size: 48, bytesBase64: audioBase64 }, id);
    assert.deepEqual(row.result, { text, model }, id);
    assert.equal(row.releaseCount, 1, id);
    assert.deepEqual(row.readerCalls, [{ maxBytes: 16777216, chunkTimeoutMs: 30000 }], id);
  }
});

test('raw optional inputs and ignored query remain distinct from observed multipart values', () => {
  assert.equal(rows.get('explicit-model').input.model, ' gpt-4o-mini-transcribe ');
  assert.equal(rows.get('language-prompt-unicode').input.language, ' EN-us ');
  assert.equal(rows.get('language-prompt-unicode').input.prompt, ' 名称 Ada 😀 ');
  assert.equal(rows.get('blank-optional-fields').input.language, ' \t ');
  assert.equal(rows.get('blank-optional-fields').input.prompt, ' \n ');
  assert.equal(rows.get('filename-basename').input.fileName, '  recordings/day/voice note.wav  ');
  assert.equal(rows.get('aac-extensionless').input.mime, 'Audio/AAC');
  assert.equal(Object.hasOwn(rows.get('mime-default').input, 'mime'), false);
  assert.equal(rows.get('custom-base').input.baseUrl, ' https://transcription.example.test/v1/// ');
  assert.equal(rows.get('custom-base').input.model, ' Vendor/Model-X ');
  assert.equal(rows.get('native-mime-case').input.mime, 'Audio/WAV; Codecs=PCM');
  assert.deepEqual(rows.get('ignored-query').input.query,
    { response_format: 'text', temperature: 0, timestamp_granularities: ['word'] });
  assert.equal(rows.get('buffer-subrange').input.bufferView.byteOffset, 7);
  assert.equal(rows.get('buffer-subrange').input.bufferView.byteLength, 48);
  assert.equal(rows.get('buffer-subrange').input.bufferView.backingBytesBase64,
    Buffer.concat([Buffer.alloc(7, 0x11), Buffer.from(audioBase64, 'base64'), Buffer.alloc(5, 0x22)]).toString('base64'));
});

test('actual JSON wrapper handles raw UTF8 BOM, transcript-edge Unicode, silence and requested model', () => {
  const bom = rows.get('raw-json-bom');
  assert.equal(bom.response.bodyText, '\uFEFF{"text":" JSON BOM transcript. ","model":"server-selected"}');
  assert.deepEqual(Buffer.from(bom.response.bodyBytesBase64, 'base64').subarray(0, 3), Buffer.from([239, 187, 191]));
  assert.equal(rows.get('response-unicode').response.json.text, '\uFEFF\u00A0 A  e\u0301 😀\r\nZ \u00A0\uFEFF');
  assert.equal(rows.get('silence').response.json.text, ' \r\n\t\u00A0\uFEFF ');
  assert.equal(rows.get('explicit-model').response.json.model, 'server-selected');
  assert.equal(rows.get('explicit-model').result.model, 'gpt-4o-mini-transcribe');
});

test('unchanged whole modules and per-importer generated facades retain exact executable provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const whole = capture.sourceRecords.filter(row => row.executed);
  assert.equal(whole.length, 19);
  for (const row of whole) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.wholeModule, true, row.path);
    assert.equal(row.sha256, hash(bytes), row.path);
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
  }
  for (const path of ['extensions/openai/audio-transcription.ts', 'src/media-understanding/openai-compatible-audio.ts',
    'src/media-understanding/shared.ts', 'src/plugin-sdk/blob-runtime.ts', 'src/agents/provider-http-errors.ts',
    'src/agents/provider-request-config.ts']) assert.ok(whole.some(row => row.path === path), path);
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    assert.ok(binding.importer && binding.specifier);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-openai-transcription.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
});

test('whole tracked reference tree agrees before and after ordinary capture', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
});

test('native synthetic lower boundaries and unexecuted production bodies are disclosed', () => {
  for (const term of ['native FormData', 'bounded stream reader', 'policy', 'query', 'input audio byte cap', 'registration']) {
    assert.ok(capture.limits.some(value => value.includes(term)), term);
  }
  assert.deepEqual(capture.deferredCalls, []);
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-policy-fixture'));
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-body-reader-fixture'));
});

test('fresh independent whole-source executions reproduce the frozen fixture exactly', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-transcription.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureOpenAITranscription(root), frozen);
});
