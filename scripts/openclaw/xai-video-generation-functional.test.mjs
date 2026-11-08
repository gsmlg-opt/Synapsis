// Ordinary source-oracle behavior only. No real provider, auth, policy or transport tests.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureXaiVideoGeneration, XAI_VIDEO_GENERATION_PIN } from './capture-xai-video-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureXaiVideoGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const body = id => rows.get(id).requests[0].jsonBody;
const names = ['default-text', 'explicit-model-prompt', 'duration-rounded', 'duration-minimum', 'duration-maximum',
  'ratio-1-1', 'ratio-16-9', 'ratio-9-16', 'ratio-4-3', 'ratio-3-4', 'ratio-3-2', 'ratio-2-3',
  'generic-1080p', 'v15-canonical', 'v15-preview', 'v15-dated', 'frame-url', 'frame-explicit-ratio',
  'frame-bytes-default-mime', 'frame-bytes-explicit-mime', 'frame-url-preferred', 'ordered-references', 'seven-references',
  'remote-video-edit', 'remote-video-extend-minimum', 'remote-video-extend-rounded', 'remote-video-extend-maximum',
  'custom-base', 'pending-processing-done', 'webm-output', 'avi-synonym-output', 'default-output-mime', 'explicit-media-cap', 'omitted-timeout-stage-budgets'];

test('34 complete-source executions preserve inputs, full outputs and submit/poll/download release receipts', () => {
  assert.deepEqual(capture.observations.map(row => row.id), names);
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 33);
  for (const row of capture.observations) {
    assert.deepEqual(row.inputAfter, row.input, row.id);
    assert.deepEqual(row.requests.map(request => request.stage), ['submit', ...row.response.polls.map(() => 'poll'), 'download'], row.id);
    assert.equal(row.requests[0].method, 'POST', row.id);
    assert.ok(row.requests.slice(1).every(request => request.method === 'GET'), row.id);
    assert.ok(row.requests.every(request => request.releaseCount === 1), row.id);
    assert.equal(row.requests[0].releasedAtMs, row.clock.endMs, row.id);
    assert.equal(row.requests.at(-1).releasedAtMs, row.clock.endMs, row.id);
    assert.deepEqual(row.requests.slice(1, -1).map(request => request.url),
      row.response.polls.map(() => row.requests[0].url.replace(/\/videos\/(?:generations|edits|extensions)$/, '/videos/req-video-1')), row.id);
    assert.equal(row.requests.at(-1).url, row.response.download.url, row.id);
    assert.equal(row.result.videos.length, 1, row.id);
    assert.deepEqual(Object.keys(row.result), ['videos', 'model', 'metadata'], row.id);
    assert.deepEqual(Object.keys(row.result.videos[0]), ['mimeType', 'fileName', 'bytesBase64'], row.id);
    assert.equal(row.result.videos[0].bytesBase64, row.response.download.bytesBase64, row.id);
    assert.equal(row.result.model, row.input.model?.trim() ?? 'grok-imagine-video', row.id);
    assert.equal(row.result.metadata.requestId, 'req-video-1', row.id);
    assert.equal(row.result.metadata.status, row.response.polls.at(-1).status.trim(), row.id);
    assert.equal(row.result.metadata.videoUrl, row.response.download.url, row.id);
    assert.equal(row.readerCalls.filter(call => call.kind === 'json').length, row.response.polls.length + 1, row.id);
    assert.deepEqual(row.retryCalls.map(call => call.stage), [...row.response.polls.map(() => 'poll'), 'download'], row.id);
  }
});

test('default text and explicit identifiers/prompts preserve source-owned defaults and exact body key order', () => {
  assert.deepEqual(body('default-text'), { model: 'grok-imagine-video', prompt: ' Make the blue square turn slowly. ',
    duration: 8, aspect_ratio: '16:9', resolution: '480p' });
  assert.deepEqual(rows.get('default-text').requests[0].bodyKeyOrder, ['model', 'prompt', 'duration', 'aspect_ratio', 'resolution']);
  assert.equal(body('explicit-model-prompt').model, 'Vendor/Video-X');
  assert.equal(body('explicit-model-prompt').prompt, '  Preserve this exact prompt.\n');
  assert.equal(rows.get('default-text').requests[0].url, 'https://api.x.ai/v1/videos/generations');
  assert.equal(rows.get('default-text').result.metadata.mode, 'generate');
  assert.equal(body('duration-rounded').duration, 9);
  assert.equal(body('duration-minimum').duration, 1);
  assert.equal(body('duration-maximum').duration, 15);
});

test('all seven aspect ratios and generic 1080p normalization execute through actual source helpers', () => {
  for (const ratio of ['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3']) {
    assert.equal(body('ratio-' + ratio.replace(':', '-')).aspect_ratio, ratio);
  }
  assert.equal(body('generic-1080p').resolution, '720p');
});

test('canonical, preview and dated 1.5 identifiers keep a single first frame and permit 1080p', () => {
  const models = ['grok-imagine-video-1.5', 'grok-imagine-video-1.5-preview', 'grok-imagine-video-1.5-2026-05-30'];
  for (const [index, id] of ['v15-canonical', 'v15-preview', 'v15-dated'].entries()) {
    const row = rows.get(id);
    assert.equal(row.requests[0].jsonBody.model, models[index]);
    assert.equal(row.result.model, models[index]);
    assert.deepEqual(row.requests[0].jsonBody.image, { url: 'https://assets.example.test/frame.png' });
    assert.equal(row.requests[0].jsonBody.resolution, '1080p');
    assert.equal(Object.hasOwn(row.requests[0].jsonBody, 'aspect_ratio'), false);
    assert.deepEqual(row.requests[0].bodyKeyOrder, ['model', 'prompt', 'image', 'duration', 'resolution']);
  }
});

test('image URL preference, inline bytes/default MIME and inherited or explicit frame ratio use the real image helper', () => {
  const url = 'https://assets.example.test/frame.png';
  assert.deepEqual(body('frame-url').image, { url });
  assert.deepEqual(body('frame-url-preferred').image, { url });
  for (const id of ['frame-bytes-default-mime', 'frame-bytes-explicit-mime']) {
    assert.equal(body(id).image.url, 'data:image/png;base64,' + rows.get(id).input.inputImages[0].bytesBase64);
    assert.equal(Object.hasOwn(body(id), 'aspect_ratio'), false);
  }
  assert.equal(Object.hasOwn(body('frame-url'), 'aspect_ratio'), false);
  assert.equal(body('frame-explicit-ratio').aspect_ratio, '9:16');
  assert.equal(body('frame-explicit-ratio').resolution, '720p');
});

test('ordered case-insensitive references include the seven-image boundary and ten-second duration cap', () => {
  assert.deepEqual(body('ordered-references').reference_images, [
    { url: 'https://assets.example.test/ref-one' },
    { url: 'data:image/png;base64,' + rows.get('ordered-references').input.inputImages[1].bytesBase64 },
    { url: 'https://assets.example.test/ref-three' },
  ]);
  assert.equal(body('ordered-references').duration, 10);
  assert.equal(body('ordered-references').aspect_ratio, '16:9');
  assert.equal(body('ordered-references').resolution, '720p');
  assert.equal(rows.get('ordered-references').result.metadata.mode, 'referenceToVideo');
  assert.deepEqual(body('seven-references').reference_images,
    Array.from({ length: 7 }, (_, index) => ({ url: `https://assets.example.test/ref-${index + 1}` })));
  assert.equal(body('seven-references').duration, 10);
  assert.deepEqual(rows.get('seven-references').requests[0].bodyKeyOrder,
    ['model', 'prompt', 'reference_images', 'duration', 'aspect_ratio', 'resolution']);
});

test('remote video edit omits duration while provided extension duration rounds and clamps to 2..10', () => {
  const edit = rows.get('remote-video-edit');
  assert.deepEqual(body('remote-video-edit'), { model: 'grok-imagine-video', prompt: ' Make the blue square turn slowly. ',
    video: { url: 'https://assets.example.test/input.mp4' } });
  assert.equal(edit.requests[0].url, 'https://api.x.ai/v1/videos/edits');
  assert.equal(edit.result.metadata.mode, 'edit');
  assert.deepEqual(edit.requests[0].bodyKeyOrder, ['model', 'prompt', 'video']);
  for (const [id, duration] of [['remote-video-extend-minimum', 2], ['remote-video-extend-rounded', 6], ['remote-video-extend-maximum', 10]]) {
    assert.equal(body(id).duration, duration, id);
    assert.equal(rows.get(id).requests[0].url, 'https://api.x.ai/v1/videos/extensions', id);
    assert.equal(rows.get(id).result.metadata.mode, 'extend', id);
    assert.deepEqual(rows.get(id).requests[0].bodyKeyOrder, ['model', 'prompt', 'video', 'duration']);
  }
  const custom = rows.get('custom-base');
  assert.equal(custom.requests[0].url, 'https://video.example.test/custom/v2/videos/generations');
  assert.equal(custom.requests[1].url, 'https://video.example.test/custom/v2/videos/req-video-1');
  assert.equal(custom.requests[0].jsonBody.model, 'custom-video');
});

test('actual polling reads immediately and waits only between pending/processing completion checks', () => {
  const immediate = rows.get('default-text');
  assert.deepEqual(immediate.clock.sleeps, []);
  assert.deepEqual(immediate.requests.map(request => request.atMs), [100000, 100007, 100018]);
  const pending = rows.get('pending-processing-done');
  assert.deepEqual(pending.clock.sleeps, [{ atMs: 100018, durationMs: 5000 }, { atMs: 105029, durationMs: 5000 }]);
  assert.deepEqual(pending.requests.map(request => request.atMs), [100000, 100007, 105018, 110029, 110040]);
  assert.equal(pending.result.metadata.status, 'DoNe');
  assert.equal(pending.clock.endMs, 110064);
  const shared = capture.sourceRecords.find(row => row.path === 'src/media-understanding/shared.ts');
  assert.ok(shared.projection.generatedCode.includes('for (let attempt = 0; attempt < params.maxAttempts; attempt += 1)'));
  assert.ok(capture.sourceRecords.find(row => row.path === 'extensions/xai/video-generation-provider.ts').wholeModule);
  const provider = readFileSync(join(root, 'extensions/xai/video-generation-provider.ts'), 'utf8');
  assert.match(provider, /const POLL_INTERVAL_MS = 5_000;/);
  assert.match(provider, /const MAX_POLL_ATTEMPTS = 120;/);
  assert.deepEqual({ pollIntervalMs: capture.protocol.pollIntervalMs, maxPollAttempts: capture.protocol.maxPollAttempts },
    { pollIntervalMs: 5000, maxPollAttempts: 120 });
});

test('shared explicit deadline shrinks across submit/poll/download and binary reader under synthetic clock', () => {
  for (const row of capture.observations.filter(row => row.hostComparable)) {
    assert.equal(row.timeoutSemantics, 'explicit-shared-total-budget', row.id);
    assert.equal(row.clock.kind, 'synthetic-Date.now-and-sleepWithAbort');
    for (const request of row.requests) assert.equal(request.timeoutMs, 130000 - request.atMs, row.id);
    const reader = row.readerCalls.at(-1);
    assert.equal(reader.timeoutMs, 130000 - reader.atMs, row.id);
  }
  assert.deepEqual(rows.get('pending-processing-done').requests.map(request => request.timeoutMs), [30000, 29993, 24982, 19971, 19960]);
  const omitted = rows.get('omitted-timeout-stage-budgets');
  assert.equal(omitted.hostComparable, false);
  assert.equal(omitted.timeoutSemantics, 'source-only-omitted-timeout-stage-budgets');
  assert.match(omitted.adaptationReason, /explicit finite total timeout/);
  assert.deepEqual(omitted.requests.map(request => request.timeoutMs), [600000, 600000, 594989, 600000]);
  assert.equal(omitted.readerCalls.at(-1).timeoutMs, 599989);
});

test('nonce is submitted once and excluded from poll/download; configured headers are synthetic', () => {
  for (const row of capture.observations) {
    assert.equal(row.nonceCalls, 1);
    assert.deepEqual(row.requests[0].headers, { 'x-fixture-header': 'synthetic-config',
      'x-idempotency-key': '00000000-0000-4000-8000-000000000001' });
    for (const request of row.requests.filter(request => request.stage === 'poll')) {
      assert.deepEqual(request.headers, { 'x-fixture-header': 'synthetic-config' });
    }
    assert.deepEqual(row.requests.at(-1).headers, {});
  }
});

test('real provider-assets and MIME mapping keep exact MP4/WebM/AVI/default-MIME bytes and cap parameters', () => {
  for (const [id, mimeType, fileName] of [['default-text', 'video/mp4', 'video-1.mp4'],
    ['webm-output', 'Video/WebM; charset=binary', 'video-1.webm'], ['avi-synonym-output', 'video/vnd.avi', 'video-1.avi'],
    ['default-output-mime', 'video/mp4', 'video-1.mp4']]) {
    assert.equal(rows.get(id).result.videos[0].mimeType, mimeType);
    assert.equal(rows.get(id).result.videos[0].fileName, fileName);
    assert.equal(rows.get(id).result.videos[0].bytesBase64, rows.get(id).response.download.bytesBase64);
  }
  for (const row of capture.observations) {
    const reader = row.readerCalls.at(-1);
    assert.equal(reader.kind, 'binary');
    assert.equal(reader.mediaKind, 'video');
    assert.equal(reader.chunkTimeoutMs, 0);
    assert.equal(reader.maxBytes, row.id === 'explicit-media-cap' ? 2359296 : 16777216, row.id);
  }
});

test('source, exact whole-region projections and all explicit generated bindings reconstruct executable provenance', () => {
  assert.equal(capture.referencePin, XAI_VIDEO_GENERATION_PIN);
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.equal(executed.filter(row => row.wholeModule).length, 14);
  assert.equal(executed.filter(row => !row.wholeModule).length, 4);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let original = bytes.toString();
    if (!row.wholeModule) {
      const projection = row.projection;
      const selected = bytes.subarray(projection.startByte, projection.endByte);
      assert.equal(hash(selected), projection.sourceRegionSha256, row.path);
      original = projection.prelude + '\n' + selected.toString();
      assert.equal(original, projection.generatedCode, row.path);
      assert.equal(hash(original), projection.generatedSha256, row.path);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256);
    if (binding.origin) assert.equal(hash(readFileSync(join(root, binding.origin))), binding.originSha256);
  }
  for (const source of ['extensions/xai/video-generation-provider.ts', 'src/media-generation/provider-assets.ts',
    'src/image-generation/image-assets.ts', 'src/video-generation/duration-support.ts', 'packages/media-core/src/mime.ts']) {
    assert.ok(executed.some(row => row.path === source && row.wholeModule), source);
  }
  for (const source of ['extensions/xai/capability-provider-metadata.ts', 'extensions/xai/capability-provider-metadata-factory.ts',
    'src/media/configured-max-bytes.ts', 'src/media-understanding/shared.ts']) {
    assert.ok(executed.some(row => row.path === source && !row.wholeModule), source);
  }
  assert.deepEqual(capture.dynamicImports, []);
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-xai-video-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
});

test('entire tracked tree stays fixed and synthetic/uninvoked boundaries remain explicit', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['Four complete original source regions', 'synthetic Date.now and sleepWithAbort',
    'production bounded stream reader', 'Deterministic crypto.randomUUID facade', 'hostComparable=false',
    'no video tool/catalog/config enablement']) assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-transport-config-reader-fixture'));
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-native-binary-reader-fixture'));
});

test('fresh independent source executions reproduce the complete frozen JSON fixture', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/xai-video-generation.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureXaiVideoGeneration(root), frozen);
});
