// Independent literal ordinary-success assertions for pinned MiniMax source callbacks.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMinimaxMusicGeneration } from './capture-minimax-music-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureMinimaxMusicGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const rawBytes = 'AP+AAQL+EQ==';
const standardBody = { model: 'music-2.6', prompt: 'Morning melody 歌 😀', lyrics_optimizer: true,
  stream: true, output_format: 'hex', audio_setting: { sample_rate: 44100, bitrate: 256000, format: 'mp3' } };
const lyricBody = (model, lyrics) => { const { lyrics_optimizer, ...body } = standardBody; return { ...body, model, lyrics }; };
const instrumentalBody = (() => { const { lyrics_optimizer, ...body } = standardBody;
  return { ...body, model: 'music-2.6-free', is_instrumental: true }; })();
// Expectations are explicit source-contract cases, not copied from the frozen output.
const expected = [
  ['inline-default', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['source-default-timeout', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['portal-model-lyrics', lyricBody('music-cover-free', 'Verse 歌 😀\nChorus'), 'audio/mpeg', 'track-1.mp3',
    { taskId: 'task-歌曲', instrumental: false, requestedLyrics: true }, ['Returned verse 歌 😀']],
  ['instrumental-blank-lyrics', instrumentalBody, 'audio/mpeg', 'track-1.mp3', { instrumental: true }],
  ['blank-model-default', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['nested-audio-hex-lyrics', lyricBody('music-2.6', 'Source lyrics'), 'audio/mpeg', 'track-1.mp3',
    { taskId: 'nested-task', instrumental: false, requestedLyrics: true }, ['Nested lyrics 雪 😀']],
  ['top-inline-precedence', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['top-url-precedence', standardBody, 'Audio/WAV; codecs=pcm', 'track-1.wav',
    { audioUrl: 'https://audio.example.test/track', instrumental: false }, ['Download lyric']],
  ['nested-url-precedence', standardBody, 'application/octet-stream', 'track-1.mp3',
    { audioUrl: 'https://audio.example.test/track', instrumental: false }, ['Nested URL lyric']],
  ['audio-candidate-url', standardBody, 'audio/ogg', 'track-1.ogg',
    { taskId: 'url-task', audioUrl: 'HTTPS://audio.example.test/candidate', instrumental: false }],
  ['download-default-mime', standardBody, 'audio/mpeg', 'track-1.mp3',
    { audioUrl: 'https://audio.example.test/track', instrumental: false }],
  ['direct-audio-raw-mime', standardBody, 'Audio/WAV; codecs=pcm', 'track-1.wav', { instrumental: false }],
  ['direct-audio-alias', standardBody, 'audio/x-m4a', 'track-1.m4a', { instrumental: false }],
  ['sse-chunks-completion-aggregate', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['sse-completion-first', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['sse-cross-http-chunks', { ...standardBody, model: 'music-cover' }, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['configured-origin-portal', { ...standardBody, model: 'custom/vendor/music' }, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['duration-unused', standardBody, 'audio/mpeg', 'track-1.mp3', { instrumental: false }],
  ['json-opaque-chunks-unicode', standardBody, 'audio/mpeg', 'track-1.mp3',
    { taskId: 'task-雪', instrumental: false }, ['雪 😀\n歌 café']],
];

test('both registered IDs retain the complete four-model descriptor and ordinary capabilities', () => {
  assert.deepEqual(capture.providers, ['minimax', 'minimax-portal'].map(id => ({ id, label: 'MiniMax',
    defaultModel: 'music-2.6', models: ['music-2.6', 'music-2.6-free', 'music-cover', 'music-cover-free'],
    capabilities: { generate: { maxTracks: 1, supportsLyrics: true, supportsInstrumental: true,
      supportsFormat: true, supportedFormats: ['mp3'] }, edit: { enabled: false } } })));
});

test('19 successful callbacks preserve complete literal requests, exact opaque audio and source result maps', () => {
  assert.deepEqual(capture.observations.map(row => row.id), expected.map(row => row[0]));
  for (const [id, body, mimeType, fileName, metadata, lyrics] of expected) {
    const row = rows.get(id);
    const custom = id === 'configured-origin-portal';
    assert.deepEqual(row.requests, [{ url: custom ? 'https://api.minimaxi.com/v1/music_generation' : 'https://api.minimax.io/v1/music_generation',
      body, timeoutMs: id === 'source-default-timeout' ? 300000 : 12345, pinDns: false, allowPrivateNetwork: false,
      dispatcherPolicy: { fixture: 'synthetic-successful-policy' },
      headers: { authorization: 'Bearer synthetic-minimax-fixture-key', 'content-type': 'application/json', ...(custom ? { 'x-context': 'ordinary' } : {}) },
      method: 'POST' }], id);
    assert.deepEqual(row.result, { tracks: [{ mimeType, fileName, bytesBase64: rawBytes }],
      ...(lyrics === undefined ? {} : { lyrics }), model: body.model, metadata }, id);
    assert.deepEqual(row.inputAfter, row.input, id);
    assert.deepEqual(row.releases, { post: 1, download: row.download ? 1 : 0 }, id);
    assert.deepEqual(row.maxBytesCalls, [{ kind: 'audio', maxBytes: custom ? 32768 : 16777216 }], id);
  }
});

test('actual JSON selection keeps top and nested precedence and plain or hex-decoded lyrics without extra metadata', () => {
  const top = rows.get('top-inline-precedence');
  assert.equal(top.response.payload.audio, '00ff800102fe11');
  assert.equal(top.response.payload.data.audio, 'AABB');
  assert.equal(top.result.tracks[0].bytesBase64, rawBytes);
  assert.deepEqual(top.result.metadata, { instrumental: false });
  assert.equal(Object.hasOwn(top.result, 'lyrics'), false);
  assert.equal(rows.get('top-url-precedence').response.payload.audio, 'AABB');
  assert.equal(rows.get('top-url-precedence').downloadCalls[0].url, 'https://audio.example.test/track');
  assert.equal(rows.get('nested-url-precedence').downloadCalls[0].url, 'https://audio.example.test/track');
  assert.equal(rows.get('audio-candidate-url').downloadCalls[0].url, 'HTTPS://audio.example.test/candidate');
  assert.deepEqual(rows.get('nested-audio-hex-lyrics').result.lyrics, ['Nested lyrics 雪 😀']);
  assert.deepEqual(rows.get('json-opaque-chunks-unicode').result.lyrics, ['雪 😀\n歌 café']);
});

test('actual media download wrapper uses one declared successful retry operation and preserves raw MIME without track source metadata', () => {
  for (const id of ['top-url-precedence', 'nested-url-precedence', 'audio-candidate-url', 'download-default-mime']) {
    const row = rows.get(id);
    const url = id === 'audio-candidate-url' ? 'HTTPS://audio.example.test/candidate' : 'https://audio.example.test/track';
    assert.deepEqual(row.downloadCalls, [{ url, init: { method: 'GET' }, timeoutMs: 12345,
      options: { dispatcherPolicy: { fixture: 'synthetic-successful-policy' } } }], id);
    assert.deepEqual(row.retryCalls, [{ provider: 'minimax', stage: 'download' }], id);
    assert.deepEqual(row.statusCalls, [{ status: 200, label: 'MiniMax music generation failed' },
      { status: 200, label: 'MiniMax generated music download failed' }], id);
    assert.deepEqual(row.binaryCalls, [{ label: 'MiniMax generated music download', kind: 'audio', maxBytes: 16777216,
      timeoutMs: 12345, contentType: row.download.contentType ?? null }], id);
    assert.equal(Object.hasOwn(row.result.tracks[0], 'metadata'), false, id);
  }
  assert.equal(rows.get('nested-url-precedence').result.tracks[0].mimeType, 'application/octet-stream');
  assert.equal(rows.get('direct-audio-raw-mime').result.tracks[0].mimeType, 'Audio/WAV; codecs=pcm');
  assert.equal(rows.get('direct-audio-alias').result.tracks[0].fileName, 'track-1.m4a');
});

test('actual completed SSE handles CRLF, aggregate completion and first completion audio while preserving byte boundaries', () => {
  const aggregate = rows.get('sse-chunks-completion-aggregate');
  assert.equal(Buffer.from(aggregate.response.chunksBase64[0], 'base64').toString(),
    ': ordinary comment\r\n' +
    'data: {"data":{"audio":"00ff80","status":1},"base_resp":{"status_code":0}}\r\n\r\n' +
    'data: {"data":{"audio":"0102fe11","status":"1"}}\r\n' +
    'data: {"data":{"audio":"00ff800102fe11","status":2}}\r\n' +
    'data: [DONE]');
  assert.equal(aggregate.result.tracks[0].bytesBase64, rawBytes);
  assert.equal(rows.get('sse-completion-first').result.tracks[0].bytesBase64, rawBytes);
  const split = rows.get('sse-cross-http-chunks');
  assert.equal(split.response.chunksBase64.length, 114);
  assert.deepEqual(split.streams, [{ label: 'post', chunksRead: 114, readerReleaseLockCount: 1, readerCancelCount: 0, lockedAfter: false }]);
  assert.equal(split.result.tracks[0].bytesBase64, rawBytes);
});

test('native body readers release consumed locks and configuration boundaries remain explicit synthetic inputs', () => {
  for (const row of capture.observations) {
    for (const stream of row.streams) {
      assert.equal(stream.lockedAfter, false, row.id + ':' + stream.label);
      assert.equal(stream.readerCancelCount, 0, row.id + ':' + stream.label);
      assert.equal(stream.readerReleaseLockCount, stream.chunksRead ? 1 : 0, row.id + ':' + stream.label);
    }
    const custom = row.id === 'configured-origin-portal';
    assert.deepEqual(row.sanitizeCalls, [custom ? { headers: { 'X-Context': ' ordinary ' } } : null], row.id);
    const cfg = { models: { providers: { [row.providerId]: custom ? {
      baseUrl: ' https://API.MINIMAXI.COM:443/anthropic/v1?unused=yes#fragment ', request: { headers: { 'X-Context': ' ordinary ' } },
    } : {} } }, ...(custom ? { agents: { defaults: { mediaMaxMb: 0.03125 } } } : {}) };
    assert.deepEqual(row.configCalls, [{ req: { cfg, providerId: row.providerId, agentDir: '/synthetic/minimax-agent',
      authStore: { fixture: 'synthetic-key-store' }, capability: 'audio' }, missingApiKeyMessage: 'MiniMax API key missing',
      jsonContentType: false, baseUrl: custom ? 'https://api.minimaxi.com' : 'https://api.minimax.io',
      defaultBaseUrl: 'https://api.minimax.io', provider: row.providerId, capability: 'audio',
      ...(custom ? { request: { headers: { 'X-Context': ' ordinary ' } } } : {}) }], row.id);
  }
  assert.equal(rows.get('json-opaque-chunks-unicode').streams[1].chunksRead, 80);
  assert.equal(rows.get('source-default-timeout').hostComparable, false);
  assert.equal(Object.hasOwn(rows.get('source-default-timeout').input, 'timeoutMs'), false);
  assert.deepEqual(rows.get('duration-unused').requests[0].body, standardBody);
});

test('18 whole unchanged modules and two exact region projections preserve complete executable and import provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.sourceRecords.filter(row => row.executed && row.wholeModule).length, 18);
  assert.deepEqual(capture.sourceRecords.filter(row => row.executed && !row.wholeModule).map(row => row.path).sort(),
    ['src/media-understanding/shared.ts', 'src/media/configured-max-bytes.ts']);
  for (const path of ['extensions/minimax/music-generation-provider.ts', 'extensions/minimax/media-provider-runtime.ts',
    'src/music-generation/provider-assets.ts', 'packages/media-core/src/mime.ts', 'src/infra/http-response-body.ts',
    'packages/normalization-core/src/response-bytes.ts']) assert.ok(capture.sourceRecords.some(row => row.path === path && row.wholeModule));
  assert.deepEqual(capture.sourceRecords.find(row => row.path === 'LICENSE'), {
    path: 'LICENSE', sha256: hash(readFileSync(join(root, 'LICENSE'))), executed: false, provenanceOnly: true,
  });
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sha256, hash(bytes), row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let code = bytes.toString();
    if (row.projection) {
      const region = bytes.subarray(row.projection.startByte, row.projection.endByte);
      assert.equal(row.projection.sourceRegionSha256, hash(region), row.path);
      code = row.projection.prelude + region.toString();
      assert.equal(row.projection.generatedCode, code, row.path);
      assert.equal(row.projection.generatedSha256, hash(code), row.path);
    }
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(code, { mode: 'transform', sourceMap: false })), row.path);
  }
  for (const binding of capture.importBindings) {
    assert.ok(binding.importer && binding.specifier);
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    if (binding.source) assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))));
    if (binding.origin) assert.equal(binding.originSha256, hash(readFileSync(join(root, binding.origin))));
  }
  assert.deepEqual(capture.dynamicImports, []);
  assert.deepEqual(capture.deferredCalls, []);
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-minimax-music-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  assert.equal(capture.limits.length, 8);
  assert.ok(capture.limits.some(value => value.includes('synthetic POST release callback')));
  assert.ok(capture.limits.some(value => value.includes('does not claim host replay of every vector')));
});

test('fresh independent source executions reproduce every frozen raw observation and provenance record', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/minimax-music-generation.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  const fresh = await captureMinimaxMusicGeneration(root);
  assert.deepEqual(fresh, fixture);
});
