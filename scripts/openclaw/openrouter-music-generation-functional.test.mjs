// Ordinary successful whole-source music requests and parser lifecycle only; no provider connection.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenRouterMusicGeneration } from './capture-openrouter-music-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureOpenRouterMusicGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const defaultModel = 'google/lyria-3-pro-preview';
const standardAudio = Buffer.from('RIFF synthetic music bytes 😀');
const largeAudio = Buffer.alloc(196609);
for (let index = 0; index < largeAudio.length; index++) largeAudio[index] = index % 251;
const ids = [
  'default-wav', 'default-timeout', 'explicit-model-mp3', 'blank-model-lyrics',
  'lyrics-instrumental-duration', 'instrumental-false-duration-down', 'duration-half-up', 'custom-base',
  'image-url', 'image-bytes-default-mime', 'image-bytes-explicit-mime', 'image-url-precedes-bytes',
  'transcript-whitespace-utf8-byte-chunks', 'transcript-only-space', 'one-base64-stream-across-deltas',
  'unterminated-done', 'padded-two-tail', 'padded-one-tail', 'unpadded-two-tail', 'unpadded-one-tail',
  'ignored-stream-fields', 'ordinary-sse-comments-crlf', 'audio-delta-edge-whitespace',
  'large-multiple-events-chunks', 'large-single-event-chunks', 'near-configured-audio-transcript-caps',
];
const lyrics = new Map([
  ['transcript-whitespace-utf8-byte-chunks', ' \t歌 e\u0301 😀\r\n line\u00a0\ufeff '],
  ['transcript-only-space', ' \t\r\n '], ['one-base64-stream-across-deltas', '  Intro\n歌 😀  '],
  ['ignored-stream-fields', 'Kept lyrics'], ['ordinary-sse-comments-crlf', ' CRLF lyric '],
  ['large-multiple-events-chunks', 'Start 歌 😀 end'], ['near-configured-audio-transcript-caps', '歌'.repeat(10922)],
]);

function expectedAudio(id) {
  if (['padded-two-tail', 'unpadded-two-tail'].includes(id)) return Buffer.from('ABCD');
  if (['padded-one-tail', 'unpadded-one-tail'].includes(id)) return Buffer.from('ABCDE');
  if (id === 'large-multiple-events-chunks') return largeAudio;
  if (id === 'large-single-event-chunks') return largeAudio.subarray(0, 65537);
  if (id === 'near-configured-audio-transcript-caps') return largeAudio.subarray(0, 32767);
  return standardAudio;
}

function expectedModel(id) {
  return id === 'explicit-model-mp3' ? 'google/lyria-3-clip-preview' : id === 'custom-base' ? 'vendor/track-v2' : defaultModel;
}

function expectedFormat(id) {
  return ['explicit-model-mp3', 'large-single-event-chunks'].includes(id) ? 'mp3' : 'wav';
}

function expectedContent(id) {
  const prompt = 'A gentle morning melody 😀';
  const prompts = new Map([
    ['lyrics-instrumental-duration', prompt + '\n\nInstrumental only. No vocals, no sung lyrics, no spoken word.\n\nLyrics:\nFirst line\nSecond line 😀\n\nTarget duration: about 30 seconds.'],
    ['instrumental-false-duration-down', prompt + '\n\nTarget duration: about 29 seconds.'],
    ['duration-half-up', prompt + '\n\nTarget duration: about 2 seconds.'],
  ]);
  const images = new Map([
    ['image-url', 'https://images.example.test/cover.png'],
    ['image-bytes-default-mime', 'data:image/png;base64,iVBORw0KGgo='],
    ['image-bytes-explicit-mime', 'data:image/jpeg;base64,/9j/'],
    ['image-url-precedes-bytes', 'https://images.example.test/cover.png'],
  ]);
  return images.has(id) ? [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: images.get(id) } }] :
    (prompts.get(id) ?? prompt);
}

test('twenty-six complete-source requests retain exact successful request/result bytes and input values', () => {
  assert.deepEqual(capture.observations.map(row => row.id), ids);
  for (const row of capture.observations) {
    const { id } = row;
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.equal(row.request.url, id === 'custom-base' ? 'https://music.example.test/v1/chat/completions' :
      'https://openrouter.ai/api/v1/chat/completions', id);
    assert.equal(row.request.method, 'POST', id);
    assert.equal(row.request.timeoutMs, id === 'default-timeout' ? 180000 : id === 'explicit-model-mp3' ? 23456 : 12345, id);
    assert.deepEqual(row.request.headers, { 'content-type': 'application/json', 'x-fixture-header': 'synthetic-config' }, id);
    assert.deepEqual(row.request.jsonBody, { model: expectedModel(id),
      messages: [{ role: 'user', content: expectedContent(id) }], modalities: ['text', 'audio'],
      audio: { format: expectedFormat(id) }, stream: true }, id);
    assert.deepEqual(row.request.bodyKeyOrder, ['model', 'messages', 'modalities', 'audio', 'stream'], id);
    assert.deepEqual(row.result, { tracks: [{ mimeType: expectedFormat(id) === 'mp3' ? 'audio/mpeg' : 'audio/wav',
      fileName: `track-1.${expectedFormat(id)}`, bytesBase64: expectedAudio(id).toString('base64') }],
      model: expectedModel(id), ...(lyrics.has(id) ? { lyrics: [lyrics.get(id)] } : {}),
      metadata: { inputImageCount: id.startsWith('image-') ? 1 : 0,
        instrumental: id === 'lyrics-instrumental-duration', requestedFormat: expectedFormat(id) } }, id);
    assert.equal(row.releaseCount, 1, id);
    assert.deepEqual(row.statusCalls, [{ label: 'OpenRouter music generation failed' }], id);
    assert.deepEqual(row.maxBytesCalls, [{ kind: 'audio', maxBytes: id === 'near-configured-audio-transcript-caps' ? 32768 : 16777216 }], id);
  }
});

test('normal completion releases the actual reader and provider handle for every raw native stream', () => {
  for (const row of capture.observations) {
    assert.deepEqual(row.stream, { chunksRead: row.response.chunksBase64.length, readerCancelCount: 1,
      readerReleaseLockCount: 1, lockedAfter: false }, row.id);
  }
  const byteChunks = rows.get('transcript-whitespace-utf8-byte-chunks').response.chunksBase64.map(value => Buffer.from(value, 'base64'));
  assert.ok(byteChunks.every(bytes => bytes.length === 1));
  const wire = Buffer.concat(byteChunks).toString();
  assert.ok(wire.includes('歌 e\u0301 😀'));
  assert.ok(wire.endsWith('data: [DONE]\n'));
  const unterminated = rows.get('unterminated-done');
  assert.ok(Buffer.concat(unterminated.response.chunksBase64.map(value => Buffer.from(value, 'base64'))).toString().endsWith('data: [DONE]'));
  assert.ok(rows.get('one-base64-stream-across-deltas').response.chunksBase64.length > 20);
  assert.ok(rows.get('large-multiple-events-chunks').response.chunksBase64.length > 30);
  assert.ok(rows.get('large-single-event-chunks').response.chunksBase64.length > 20);
});

test('successful streams preserve transcript edges and decode padded/unpadded quartets across SSE deltas', () => {
  assert.equal(rows.get('transcript-whitespace-utf8-byte-chunks').result.lyrics[0], ' \t歌 e\u0301 😀\r\n line\u00a0\ufeff ');
  assert.equal(rows.get('transcript-only-space').result.lyrics[0], ' \t\r\n ');
  assert.equal(Object.hasOwn(rows.get('default-wav').result, 'lyrics'), false);
  for (const id of ['one-base64-stream-across-deltas', 'audio-delta-edge-whitespace', 'ignored-stream-fields']) {
    assert.equal(rows.get(id).result.tracks[0].bytesBase64, standardAudio.toString('base64'), id);
  }
  for (const id of ['padded-one-tail', 'padded-two-tail', 'unpadded-one-tail', 'unpadded-two-tail']) {
    assert.deepEqual(Buffer.from(rows.get(id).result.tracks[0].bytesBase64, 'base64'), expectedAudio(id), id);
  }
  const near = rows.get('near-configured-audio-transcript-caps');
  assert.equal(near.config.mediaMaxMb, 0.03125);
  assert.equal(Buffer.from(near.result.tracks[0].bytesBase64, 'base64').length, 32767);
  assert.equal(Buffer.byteLength(near.result.lyrics[0]), 32766);
});

test('provider metadata and actual context preserve default models, supported formats and source-only timeout adaptation', () => {
  assert.deepEqual(capture.provider, { id: 'openrouter', label: 'OpenRouter', defaultModel,
    models: [defaultModel, 'google/lyria-3-clip-preview'], capabilities: {
      generate: { maxTracks: 1, maxDurationSeconds: 180, supportsLyrics: true, supportsInstrumental: true,
        supportsDuration: true, supportsFormat: true, supportedFormats: ['mp3', 'wav'] },
      edit: { enabled: true, maxTracks: 1, maxInputImages: 1, maxDurationSeconds: 180, supportsLyrics: true,
        supportsInstrumental: true, supportsDuration: true, supportsFormat: true, supportedFormats: ['mp3', 'wav'] },
    } });
  const sourceOnly = rows.get('default-timeout');
  assert.equal(Object.hasOwn(sourceOnly.input, 'timeoutMs'), false);
  assert.equal(sourceOnly.hostComparable, false);
  assert.ok(sourceOnly.adaptationReason.includes('explicit finite total timeout'));
  for (const row of capture.observations) {
    assert.deepEqual(row.configCalls, [{ provider: 'openrouter', capability: 'audio', jsonContentType: true,
      ...(row.id === 'custom-base' ? { baseUrl: ' https://music.example.test/v1/// ' } : {}),
      defaultBaseUrl: 'https://openrouter.ai/api/v1' }], row.id);
  }
});

test('nine unchanged whole modules and one exact original region retain source/executable/import provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.equal(executed.filter(row => row.wholeModule).length, 9);
  assert.equal(executed.filter(row => !row.wholeModule).length, 1);
  for (const row of capture.sourceRecords) {
    const original = readFileSync(join(root, row.path));
    assert.equal(row.sha256, hash(original), row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let generated = original.toString();
    if (row.projection) {
      const region = original.subarray(row.projection.startByte, row.projection.endByte);
      assert.equal(row.projection.sourceRegionSha256, hash(region));
      generated = row.projection.prelude + region.toString();
      assert.equal(row.projection.generatedCode, generated);
      assert.equal(row.projection.generatedSha256, hash(generated));
    }
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false })), row.path);
  }
  for (const source of ['extensions/openrouter/music-generation-provider.ts', 'extensions/openrouter/generation-request-context.ts',
    'packages/media-core/src/base64.ts', 'src/image-generation/image-assets.ts']) assert.ok(executed.some(row => row.path === source && row.wholeModule), source);
  for (const binding of capture.importBindings) {
    assert.ok(binding.importer && binding.specifier);
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    if (binding.source) assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))));
    if (binding.origin) assert.equal(binding.originSha256, hash(readFileSync(join(root, binding.origin))));
  }
  assert.deepEqual(capture.dynamicImports, []);
  assert.deepEqual(capture.deferredCalls, []);
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-openrouter-music-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
});

test('whole tracked checkout receipts and explicit lower-service limits remain honest', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const term of ['actual SSE parser', 'synthetic facades', 'normal-completion cleanup', '32KiB cap',
    'hostComparable=false', 'registration execution', 'whole reference/P10']) {
    assert.ok(capture.limits.some(value => value.includes(term)), term);
  }
  assert.equal(capture.importBindings.filter(row => row.kind === 'successful-config-status-transport-fixture').length, 2);
});

test('fresh independent whole-source executions reproduce the frozen fixture exactly', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openrouter-music-generation.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureOpenRouterMusicGeneration(root), frozen);
});
