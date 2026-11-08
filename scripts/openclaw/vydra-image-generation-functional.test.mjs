// Handwritten full ordinary-success plans. No host implementation or capture-vector imports.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureVydraImageGeneration, VYDRA_IMAGE_GENERATION_PIN } from './capture-vydra-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const captured = await captureVydraImageGeneration(root);
const rows = new Map(captured.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const prompt = '  draw a cat\n猫 🌕  ', base = 'https://vydra.example.test/api/v1';
const A = 'https://vydra.example.test/images/a.png', B = 'https://vydra.example.test/images/b.png', C = 'https://vydra.example.test/images/c.png';
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3E//Z';
const webp = 'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AA/vuUAAA=';
const submitted = { jobId: 'job-1', status: 'completed', imageUrl: A };
const plan = (id, options = {}) => ({ id, submitted, polls: [], urls: [A], jobId: 'job-1', status: 'completed', ...options });
const plans = [
  plan('minimal'), plan('count-one-empty-inputs'), plan('trimmed-model'), plan('fractional-timeout', { timeout: 30000.9 }),
  plan('base-custom-path', { api: 'https://vydra.example.test/custom' }), plan('base-root-path'),
  plan('url-only', { submitted: { imageUrl: A }, jobId: null }),
  plan('trimmed-metadata', { submitted: { id: ' id-1 ', status: ' Completed ', imageUrl: ' ' + A + ' ' }, jobId: 'id-1' }),
  plan('job-id-priority', { submitted: { jobId: ' primary ', id: 'secondary', status: 'completed', imageUrl: A }, jobId: 'primary' }),
  plan('poll-immediate', { submitted: { jobId: 'job-1', status: 'queued' }, polls: [{ status: 'completed', imageUrl: A }] }),
  plan('poll-processing-completed', { submitted: { jobId: 'job-1', status: 'queued' }, polls: [{ status: 'processing' }, { id: ' finished-1 ', status: ' Completed ', imageUrl: A }], jobId: 'finished-1' }),
  plan('poll-url-completes-processing', { submitted: { id: ' job-1 ', status: 'queued' }, polls: [{ status: 'processing', imageUrl: A }], status: 'processing' }),
  plan('queued-url-completes', { submitted: { jobId: 'job-1', status: 'queued', imageUrl: A }, status: 'queued' }),
  plan('url-key-imageUrl', { submitted: { imageUrl: A }, jobId: null }),
  plan('url-key-imageUrls', { submitted: { imageUrls: [A] }, jobId: null }),
  plan('url-key-resultUrl', { submitted: { resultUrl: A }, jobId: null }),
  plan('url-key-resultUrls', { submitted: { resultUrls: [A] }, jobId: null }),
  plan('url-key-outputUrl', { submitted: { outputUrl: A }, jobId: null }),
  plan('url-key-outputUrls', { submitted: { outputUrls: [A] }, jobId: null }),
  plan('url-key-url', { submitted: { url: A }, jobId: null }),
  plan('url-key-urls', { submitted: { urls: [A] }, jobId: null }),
  plan('recurse-key-output', { submitted: { output: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-outputs', { submitted: { outputs: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-result', { submitted: { result: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-results', { submitted: { results: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-data', { submitted: { data: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-asset', { submitted: { asset: { imageUrl: A } }, jobId: null }),
  plan('recurse-key-assets', { submitted: { assets: { imageUrl: A } }, jobId: null }),
  plan('ordered-fixed-keys', { submitted: { url: C, resultUrl: B, imageUrl: A }, urls: [A, B, C], jobId: null }),
  plan('ordered-nested-url-arrays', { submitted: { imageUrls: [[A, B], [' ' + A + ' ', C]] }, urls: [A, B, C], jobId: null }),
  plan('ordered-root-before-recursion', { submitted: { output: { imageUrl: B }, imageUrl: A }, urls: [A, B], jobId: null }),
  plan('ordered-recursion-keys', { submitted: { data: { imageUrl: B }, output: { imageUrl: A } }, urls: [A, B], jobId: null }),
  plan('depth-five', { submitted: { output: [{ result: { data: { assets: { imageUrl: A } } } }] }, jobId: null }),
  plan('split-png-body', { chunks: [7, 13, 48] }),
  plan('jpeg-body', { bytes: jpeg, mime: 'image/jpeg', fileName: 'image-1.jpg' }),
  plan('webp-body', { bytes: webp, mime: 'image/webp', fileName: 'image-1.webp' }),
  plan('raw-parameterized-mime', { mime: 'Image/PNG; charset=binary' }), plan('default-png-mime'),
  plan('small-configured-cap'), plan('larger-configured-cap', { cap: 84148224 }), plan('ignored-ordinary-options'),
  plan('source-only-omitted-model'),
  plan('source-only-omitted-timeout', { timeout: null, submitted: { jobId: 'job-1', status: 'queued' }, polls: [{ status: 'processing' }, { status: 'completed', imageUrl: A }] }),
  plan('source-only-omitted-base', { api: 'https://www.vydra.ai/api/v1', submitted: { imageUrl: 'https://www.vydra.ai/images/a.png' }, urls: ['https://www.vydra.ai/images/a.png'], jobId: null }),
  plan('source-only-canonical-base', { api: 'https://www.vydra.ai/api/v1', submitted: { imageUrl: 'https://www.vydra.ai/images/a.png' }, urls: ['https://www.vydra.ai/images/a.png'], jobId: null }),
  plan('source-only-configured-header', { traceHeader: true }),
];
const body = { prompt, model: 'text-to-image' };
const jsonLength = value => Buffer.byteLength(JSON.stringify(value));
const request = (kind, url, timeoutMs, atMs, releasedAtMs, headers, extra = {}) => ({ kind, url,
  method: kind === 'post' ? 'POST' : 'GET', headers, timeoutMs, atMs,
  auditContext: kind === 'poll' ? 'vydra-job-status' : kind === 'download' ? 'vydra-media-download' : null,
  releaseCount: 1, ...(kind === 'post' ? { rawBody: JSON.stringify(body), body } : {}),
  maxBytes: kind === 'download' ? 67108864 : 16777216, releasedAtMs, ...extra });
const read = (kind, bytes, timeoutMs, atMs, extra = {}) => ({ kind, maxBytes: kind === 'download' ? 67108864 : 16777216,
  timeoutMs, chunkTimeoutMs: kind === 'download' ? 0 : 30000, hasOnIdleTimeout: true, hasOnOverflow: true,
  atMs, chunkLengths: [bytes], bytesRead: bytes, implementation: 'successful-lower-body-reader-facade', ...extra });
const event = (kind, stage, url, atMs) => ({ kind, stage, url, atMs });

test('46 independent full wire, result, reader, release and stage-budget plans', () => {
  assert.equal(plans.length, 46); assert.deepEqual([...rows.keys()], plans.map(row => row.id));
  for (const p of plans) {
    const row = rows.get(p.id), api = p.api ?? base, target = p.urls[0], total = p.timeout === undefined ? 30000 : p.timeout;
    // Full wire headers trace a literal successful context, not a key/policy contract.
    const headers = { authorization: 'Bearer synthetic-explicit-key', 'content-type': 'application/json', ...(p.traceHeader ? { 'x-ordinary-trace': 'fixture' } : {}) };
    const postUrl = api + '/models/grok-imagine', pollUrl = api + '/jobs/job-1';
    const expectedRequests = [request('post', postUrl, total ?? 60000, 100005, 100015, headers)];
    const expectedReaders = [read('post', jsonLength(p.submitted), null, 100012)];
    const expectedEvents = [event('request', 'post', postUrl, 100005), event('release', 'post', postUrl, 100015)];
    const statusCalls = [{ label: 'Vydra image generation failed', status: 200, atMs: 100012, implementation: 'successful-status-facade' }];
    let now = 100015;
    for (let i = 0; i < p.polls.length; i++) {
      const remaining = total === null ? 120000 : 30000 - (now - 100015);
      expectedRequests.push(request('poll', pollUrl, remaining, now, now + 7, headers));
      expectedReaders.push(read('poll', jsonLength(p.polls[i]), remaining - (total === null ? 0 : 4), now + 4));
      statusCalls.push({ label: 'Vydra job status request failed', status: 200, atMs: now + 4, implementation: 'successful-status-facade' });
      expectedEvents.push(event('request', 'poll', pollUrl, now), event('release', 'poll', pollUrl, now + 7));
      now += 7;
      if (i + 1 < p.polls.length) { expectedEvents.push({ kind: 'wait', durationMs: 2500, atMs: now, implementation: 'synthetic-wait-facade' }); now += 2500; }
    }
    const downloadBudget = total === null ? 120000 : 30000, bytes = Buffer.from(p.bytes ?? png, 'base64').length;
    expectedRequests.push(request('download', target, downloadBudget, now, now + 7, headers, { maxBytes: p.cap ?? 67108864 }));
    expectedReaders.push(read('download', bytes, downloadBudget - 5, now + 5, { maxBytes: p.cap ?? 67108864, chunkLengths: p.chunks ?? [bytes] }));
    expectedEvents.push(event('request', 'download', target, now), event('release', 'download', target, now + 7));
    statusCalls.push({ label: 'Vydra image download failed', status: 200, atMs: now + 5, implementation: 'successful-status-facade' });
    assert.deepEqual(row.requests, expectedRequests, p.id + ' full wire');
    assert.deepEqual(row.readerCalls, expectedReaders, p.id + ' complete body-read receipts');
    assert.deepEqual(row.events, expectedEvents, p.id + ' ordered lifetime and waits');
    assert.deepEqual(row.statusCalls, statusCalls, p.id + ' successful status boundary');
    assert.deepEqual(row.retryCalls, p.polls.map(() => ({ stage: 'poll', implementation: 'successful-first-execution-retry-facade' })), p.id);
    assert.deepEqual(row.extractedUrls, p.urls, p.id + ' full ordered deduplicated URL projection');
    assert.deepEqual(row.result, { images: [{ mimeType: p.mime ?? 'image/png', fileName: p.fileName ?? 'image-1.png', bytesBase64: p.bytes ?? png }], model: 'grok-imagine',
      metadata: { ...(p.jobId === null ? {} : { jobId: p.jobId }), imageUrl: target, status: p.status } }, p.id + ' full callback result');
    assert.deepEqual(row.inputAfter, row.input, p.id + ' request unchanged');
    assert.deepEqual(row.configAfter, row.config, p.id + ' provider config unchanged');
    assert.deepEqual(row.clock, { kind: 'synthetic-Date.now', startMs: 100000, endMs: now + 7,
      serviceCostsMs: { key: 2, config: 3, post: 7, poll: 4, jsonRead: 3, download: 5, binaryRead: 2 } }, p.id);
    assert.deepEqual(row.response.submitted, p.submitted, p.id + ' literal submission payload');
    assert.deepEqual(row.response.polls, p.polls, p.id + ' literal polling payloads');
  }
});

test('source descriptor and static speech-only capability catalog stay distinct', () => {
  assert.deepEqual(captured.providerDescriptor, { id: 'vydra', label: 'Vydra', defaultModel: 'grok-imagine', models: ['grok-imagine'],
    capabilities: { generate: { maxCount: 1, supportsSize: false, supportsAspectRatio: false, supportsResolution: false },
      edit: { enabled: false, maxCount: 1, maxInputImages: 0, supportsSize: false, supportsAspectRatio: false, supportsResolution: false } } });
  assert.deepEqual(captured.capabilityCatalog, { keys: ['speechProviders'], imageProvidersPresent: false });
  assert.deepEqual(captured.observations.filter(row => !row.hostComparable).map(row => row.id), [
    'source-only-omitted-model', 'source-only-omitted-timeout', 'source-only-omitted-base', 'source-only-canonical-base', 'source-only-configured-header']);
  for (const row of captured.observations.filter(row => row.hostComparable)) {
    assert.equal(row.input.model.trim(), 'grok-imagine'); assert.ok(Number.isFinite(row.input.timeoutMs) && row.input.timeoutMs > 0);
    assert.ok(row.config.baseUrl);
  }
  assert.equal(captured.serviceFacadeLedger.length, 7); assert.ok(captured.serviceFacadeLedger.every(row => row.executed === false && row.limit));
});

test('every original/region/generated/transformed/import/export/runtime receipt reconstructs independently', () => {
  assert.equal(VYDRA_IMAGE_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.referencePin, VYDRA_IMAGE_GENERATION_PIN); assert.deepEqual(captured.dynamicImports, []);
  assert.deepEqual(captured.sourceTree.after, captured.sourceTree.before); assert.equal(captured.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(captured.sourceRecords.filter(row => row.wholeModule).map(row => row.path).sort(), [
    'extensions/vydra/index.ts', 'extensions/vydra/shared.ts', 'extensions/vydra/defaults.ts', 'extensions/vydra/capability-catalog.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/media-core/src/constants.ts', 'src/media-understanding/provider-json-post.ts'].sort());
  assert.deepEqual(captured.sourceRecords.filter(row => row.executed && !row.wholeModule).map(row => row.path).sort(), [
    'src/media-understanding/shared.ts', 'src/agents/provider-http-errors.ts',
    'src/media/configured-max-bytes.ts', 'packages/media-core/src/mime.ts'].sort());
  for (const row of captured.sourceRecords) {
    const bytes = readFileSync(join(root, row.path)); assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let original = bytes.toString();
    if (!row.wholeModule) { const p = row.projection;
      original = p.prelude + '\n' + p.regions.map(region => { const selected = bytes.subarray(region.startByte, region.endByte);
        assert.equal(hash(selected), region.sourceRegionSha256); return selected.toString(); }).join('\n');
      assert.equal(original, p.generatedCode); assert.equal(hash(original), p.generatedSha256);
    }
    assert.equal(hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  for (const binding of captured.importBindings) { if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    if (binding.source) assert.equal(hash(readFileSync(join(root, binding.source))), binding.sourceSha256); }
  assert.equal(captured.exporter.sha256, hash(readFileSync(new URL('./capture-vydra-image-generation.mjs', import.meta.url))));
  assert.equal(captured.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.deepEqual({ executable: captured.runtime.executable, version: captured.runtime.version }, {
    executable: '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node', version: '24.22.1' });
  assert.equal(captured.runtime.sha256, hash(readFileSync(captured.runtime.executable)));
  assert.ok(captured.limits.some(row => row.includes('2147000000ms')));
  assert.ok(captured.limits.some(row => row.includes('not decoded codec or visual-quality validation')));
});

test('two fresh captures equal frozen fixture including complete provenance and ordinary I/O ledgers', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/vydra-image-generation.json', import.meta.url)));
  assert.deepEqual(captured, fixture); assert.deepEqual(await captureVydraImageGeneration(root), fixture);
});
