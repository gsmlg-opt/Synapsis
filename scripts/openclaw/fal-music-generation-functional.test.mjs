// Independent literal assertions for ordinary successful pinned FAL source callbacks only.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureFalMusicGeneration } from './capture-fal-music-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureFalMusicGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const mini = 'fal-ai/minimax-music/v2.6';
const ace = 'fal-ai/ace-step/prompt-to-audio';
const stable = 'fal-ai/stable-audio-25/text-to-audio';
const prompt = '  Morning melody 歌 😀  ';
const url = 'https://audio.example.test/music';
const standardBytes = Buffer.from('FAL ordinary synthetic music 歌 😀');
const audioSetting = { sample_rate: 44100, bitrate: 256000, format: 'mp3' };
const defaultBody = { prompt, lyrics_optimizer: true, audio_setting: audioSetting };
// Expected values are literal cases, independent of capture vectors/provider helper code.
const expected = [
  ['default-minimax', mini, defaultBody, 'audio/mpeg', 'track-1.mp3', url, { audioUrl: url, instrumental: false }],
  ['default-timeout', mini, defaultBody, 'audio/mpeg', 'track-1.mp3', url, { audioUrl: url, instrumental: false }],
  ['minimax-lyrics-duration-mp3', mini,
    { prompt, lyrics: 'Verse 歌 😀\nChorus', duration: 52.5, audio_setting: audioSetting },
    'audio/mpeg', 'track-1.mp3', url,
    { seed: 42, tags: ['calm', 'piano'], audioUrl: url, instrumental: false, requestedFormat: 'mp3', requestedDurationSeconds: 52.5 },
    ['Returned 歌 😀\nSecond line']],
  ['minimax-instrumental-duration-mp3', mini,
    { prompt, is_instrumental: true, duration: 240, audio_setting: audioSetting },
    'audio/mpeg', 'track-1.mp3', url,
    { seed: 0, tags: [], audioUrl: url, instrumental: true, requestedFormat: 'mp3', requestedDurationSeconds: 240 }],
  ['minimax-false-blank-model-lyrics', mini,
    { prompt, lyrics_optimizer: true, duration: 30, audio_setting: audioSetting },
    'audio/mpeg', 'track-1.mp3', url, { audioUrl: url, instrumental: false, requestedDurationSeconds: 30 }],
  ['ace-default', ace, { prompt }, 'audio/wav', 'track-1.wav', url, { audioUrl: url, instrumental: false }],
  ['ace-instrumental-duration-wav', ace, { prompt, instrumental: true, duration: 31.5 },
    'audio/wav', 'track-1.wav', url,
    { seed: 7, tags: 'instrumental', audioUrl: url, instrumental: true, requestedFormat: 'wav', requestedDurationSeconds: 31.5 },
    ['ACE returned lyric']],
  ['ace-false-duration-wav', ace, { prompt, duration: 60 }, 'audio/wav', 'track-1.wav', url,
    { audioUrl: url, instrumental: false, requestedFormat: 'wav', requestedDurationSeconds: 60 }],
  ['stable-default', stable, { prompt }, 'audio/wav', 'track-1.wav', url, { audioUrl: url, instrumental: false }],
  ['stable-duration-wav', stable, { prompt, seconds_total: 90 }, 'audio/wav', 'track-1.wav', url,
    { audioUrl: url, instrumental: false, requestedFormat: 'wav', requestedDurationSeconds: 90 }],
  ['audio-priority-and-candidate-filename', mini, defaultBody, 'audio/mpeg', 'chosen-name.wav', 'https://audio.example.test/first',
    { seed: 11, tags: { style: 'ambient' }, audioUrl: 'https://audio.example.test/first', instrumental: false }, ['Priority lyric']],
  ['audio-file-string-url', mini, defaultBody, 'audio/wave', 'track-1.wav', 'https://audio.example.test/file-only',
    { audioUrl: 'https://audio.example.test/file-only', instrumental: false }],
  ['candidate-mime-after-generic-header', mini, defaultBody, 'audio/wave', 'track-1.wav', url, { audioUrl: url, instrumental: false }],
  ['candidate-mime-after-binary-header', mini, defaultBody, 'audio/flac', 'archive.flac', url, { audioUrl: url, instrumental: false }],
  ['default-mime-with-generic-candidate', mini, defaultBody, 'audio/mpeg', 'track-1.mp3', url, { audioUrl: url, instrumental: false }],
  ['header-mime-default-filename', mini, defaultBody, 'audio/ogg', 'track-1.ogg', url, { audioUrl: url, instrumental: false }],
  ['custom-base-configured-cap-chunks', mini, { prompt, lyrics_optimizer: true, duration: 18, audio_setting: audioSetting },
    'audio/mpeg', 'track-1.mp3', url,
    { seed: 0, tags: false, audioUrl: url, instrumental: false, requestedFormat: 'mp3', requestedDurationSeconds: 18 }],
];

test('complete FAL descriptor preserves all three models and per-model ordinary capabilities', () => {
  assert.deepEqual(capture.provider, { id: 'fal', label: 'fal', defaultModel: mini, models: [mini, ace, stable], capabilities: {
    generate: { maxTracks: 1, maxDurationSeconds: 240, supportsLyrics: true,
      supportsLyricsByModel: { [ace]: false, [stable]: false }, supportsInstrumental: true,
      supportsInstrumentalByModel: { [stable]: false }, supportsDuration: true, supportsFormat: true,
      supportedFormats: ['mp3', 'wav'], supportedFormatsByModel: { [mini]: ['mp3'], [ace]: ['wav'], [stable]: ['wav'] } },
    edit: { enabled: false } } });
});

test('17 ordinary callbacks produce exact literal successful requests, first tracks and complete source response metadata', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row[0]));
  for (const [id, model, body, mimeType, fileName, audioUrl, metadata, lyrics] of expected) {
    const row = rows.get(id);
    const timeoutMs = id === 'default-timeout' ? 180000 : 12345;
    const baseUrl = id === 'custom-base-configured-cap-chunks' ? 'https://relay.example.test/fal' : 'https://fal.run';
    assert.deepEqual(row.requests, [{ url: `${baseUrl}/${model}`, body, timeoutMs,
      allowPrivateNetwork: false, dispatcherPolicy: { fixture: 'synthetic-successful-policy' },
      errorLabel: 'fal music generation failed', responseLabel: 'fal music generation',
      headers: { authorization: 'Key synthetic-fal-fixture-key', 'content-type': 'application/json' }, method: 'POST' }], id);
    assert.deepEqual(row.result, { tracks: [{ mimeType, fileName, metadata: { url: audioUrl }, bytesBase64: standardBytes.toString('base64') }],
      model, ...(lyrics === undefined ? {} : { lyrics }), metadata }, id);
    assert.deepEqual(row.downloadCalls, [{ url: audioUrl, init: { method: 'GET' },
      deadline: { deadlineAtMs: 1800000000000 + timeoutMs, label: 'fal generated music download', timeoutMs },
      provider: 'fal', requestFailedMessage: 'fal generated music download failed' }], id);
    assert.deepEqual(row.inputAfter, row.input, id);
  }
});

test('actual candidate helpers prioritize audio before audio_file and preserve normalized candidate names and MIME precedence', () => {
  const priority = rows.get('audio-priority-and-candidate-filename');
  assert.deepEqual(Object.keys(priority.response.payload), ['audio_file', 'audio', 'seed', 'tags', 'lyrics']);
  assert.equal(priority.downloadCalls.length, 1);
  assert.equal(priority.downloadCalls[0].url, 'https://audio.example.test/first');
  assert.equal(priority.result.tracks.length, 1);
  assert.equal(priority.result.tracks[0].fileName, 'chosen-name.wav');
  assert.equal(priority.result.tracks[0].mimeType, 'audio/mpeg');
  assert.equal(priority.response.payload.audio.content_type, ' AUDIO/WAV ; charset=utf-8 ');
  assert.equal(priority.response.contentType, ' Audio/MPEG ; charset=binary ');
  assert.equal(rows.get('candidate-mime-after-generic-header').result.tracks[0].mimeType, 'audio/wave');
  assert.equal(rows.get('candidate-mime-after-binary-header').result.tracks[0].mimeType, 'audio/flac');
  assert.equal(rows.get('default-mime-with-generic-candidate').result.tracks[0].mimeType, 'audio/mpeg');
  assert.equal(rows.get('header-mime-default-filename').result.tracks[0].fileName, 'track-1.ogg');
  assert.equal(Object.hasOwn(rows.get('audio-file-string-url').result, 'lyrics'), false);
  assert.equal(Object.hasOwn(rows.get('audio-file-string-url').result.metadata, 'seed'), false);
  assert.equal(Object.hasOwn(rows.get('audio-file-string-url').result.metadata, 'tags'), false);
});

test('whole actual http-config forwards only explicit successful synthetic key/config boundaries', () => {
  for (const row of capture.observations) {
    const custom = row.id === 'custom-base-configured-cap-chunks';
    const cfg = custom ? { models: { providers: { fal: {
      baseUrl: ' https://relay.example.test/fal/// ', request: { headers: { 'x-test': 'ordinary' } },
    } } }, agents: { defaults: { mediaMaxMb: 0.03125 } } } : { models: { providers: { fal: {} } } };
    assert.deepEqual(row.keyCalls, [{ provider: 'fal', cfg, agentDir: '/synthetic/fal-agent', store: { fixture: 'synthetic-key-store' } }], row.id);
    assert.deepEqual(row.sanitizeCalls, [custom ? { headers: { 'x-test': 'ordinary' } } : null], row.id);
    assert.deepEqual(row.configCalls, [{ ...(custom ? { baseUrl: 'https://relay.example.test/fal///' } : {}),
      defaultBaseUrl: 'https://fal.run', ...(custom ? { request: { headers: { 'x-test': 'ordinary' } } } : {}),
      allowPrivateNetwork: false, defaultHeaders: { Authorization: 'Key synthetic-fal-fixture-key', 'Content-Type': 'application/json' },
      provider: 'fal', capability: 'audio', transport: 'http' }], row.id);
  }
});

test('actual native response bodies complete with lock release and configured/default media caps', () => {
  for (const row of capture.observations) {
    assert.deepEqual(row.stream, { chunksRead: row.id === 'custom-base-configured-cap-chunks' ? 4 : 1,
      readerReleaseLockCount: 1, readerCancelCount: 0, lockedAfter: false }, row.id);
    assert.deepEqual(row.maxBytesCalls, [{ kind: 'audio', maxBytes: row.id === 'custom-base-configured-cap-chunks' ? 32768 : 16777216 }], row.id);
    assert.deepEqual(Buffer.concat(row.response.chunksBase64.map(bytes => Buffer.from(bytes, 'base64'))), standardBytes, row.id);
  }
  const sourceDefault = rows.get('default-timeout');
  assert.equal(Object.hasOwn(sourceDefault.input, 'timeoutMs'), false);
  assert.equal(sourceDefault.hostComparable, false);
  assert.equal(sourceDefault.adaptationReason, 'Source omitted timeout defaults to 180000ms; host protocol requires an explicit finite total timeout.');
});

test('18 unchanged whole modules and two exact source regions retain immutable source, executable and import binding provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.deepEqual(capture.sourceRecords.find(row => row.path === 'LICENSE'), {
    path: 'LICENSE', sha256: hash(readFileSync(join(root, 'LICENSE'))), executed: false, provenanceOnly: true,
  });
  assert.equal(executed.filter(row => row.wholeModule).length, 18);
  assert.deepEqual(executed.filter(row => !row.wholeModule).map(row => row.path).sort(),
    ['src/media-understanding/shared.ts', 'src/media/configured-max-bytes.ts']);
  for (const source of ['extensions/fal/music-generation-provider.ts', 'extensions/fal/http-config.ts',
    'src/music-generation/provider-assets.ts', 'packages/media-core/src/mime.ts',
    'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/record-coerce.ts',
    'src/infra/http-response-body.ts', 'src/infra/http-response-body-timeout.ts',
    'packages/normalization-core/src/response-bytes.ts']) {
    assert.ok(executed.some(row => row.path === source && row.wholeModule), source);
  }
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
  for (const binding of capture.importBindings) {
    assert.ok(binding.importer && binding.specifier);
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    if (binding.source) assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))));
    if (binding.origin) assert.equal(binding.originSha256, hash(readFileSync(join(root, binding.origin))));
  }
  assert.deepEqual(capture.dynamicImports, []);
  assert.deepEqual(capture.deferredCalls, []);
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-fal-music-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
});

test('verified full tracked checkout and explicit ordinary-only boundaries do not claim service or host qualification', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  assert.equal(capture.platform.dateNowMs, 1800000000000);
  for (const term of ['whole reference/P10', 'Synthetic successful key/config', 'no interruption claim',
    'hostComparable=false', 'two complete original source-region projections', 'base64 conversion is not invoked', 'codec/playback/quality']) {
    assert.ok(capture.limits.some(value => value.includes(term)), term);
  }
  assert.equal(capture.importBindings.filter(row => row.kind === 'successful-synthetic-key-fixture').length, 1);
  assert.equal(capture.importBindings.filter(row => row.kind === 'successful-config-submission-fixture').length, 2);
  assert.equal(capture.importBindings.filter(row => row.kind === 'source-deadlines-synthetic-download-fixture').length, 1);
});

test('fresh independent unchanged-source executions reproduce the complete frozen fixture exactly', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/fal-music-generation.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureFalMusicGeneration(root), frozen);
});
