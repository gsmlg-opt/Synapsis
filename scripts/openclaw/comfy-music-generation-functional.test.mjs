// Literal source-contract plans; no capture vector or host implementation supplies expectations.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureComfyMusicGeneration, COMFY_MUSIC_GENERATION_PIN } from './capture-comfy-music-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureComfyMusicGeneration(root);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
const base = 'https://comfy.example.test';
const prompt = ' Compose a small blue melody. ';
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const audio = 'AAECA//+gH8=';
const graph = (text = prompt) => ({
  '3': { class_type: 'KSampler', inputs: { seed: 731, steps: 20, model: ['4', 0] } },
  '6': { class_type: 'CLIPTextEncode', inputs: { text, clip: ['4', 1] } },
  '8': { class_type: 'LoadImage', inputs: { image: 'original.png' } },
  '9': { class_type: 'SaveAudio', inputs: { filename_prefix: 'ComfyUI', audio: ['3', 0] } },
});
const ordinaryHistory = { outputs: { '9': { audio: [{ filename: 'output.mp3' }] } }, status: { completed: true } };
// Node metadata is a literal expected-stage aid only; the music callback removes it from tracks.
const image = (fileName = 'output.mp3', nodeId = '9', bytesBase64 = audio, mimeType = 'audio/mpeg') => ({
  mimeType, fileName, metadata: { nodeId, promptId: 'job-17' }, bytesBase64,
});
const uploadFields = (bytesBase64, mimeType, fileName) => [
  { name: 'image', fileName, mimeType, bytesBase64 }, { name: 'type', value: 'input' }, { name: 'overwrite', value: 'true' },
];
const plans = [
  ['local-generate'], ['cloud-generate', { cloud: true }],
  ['prompt-unicode-whitespace', { text: '  音乐 🌕 e\u0301\n' }],
  ['custom-model-label', { model: 'custom display label' }],
  ['blank-model-default'], ['null-model-default'], ['omitted-model-default'],
  ['fractional-timeout'], ['empty-references'], ['ignored-raw-music-options'],
  ['local-history-pending', { pendingLocal: true }],
  ['cloud-status-pending', { cloud: true, statuses: ['pending', 'running', 'completed'] }],
  ['nested-history', { histories: [{ 'job-17': ordinaryHistory }] }],
  ['history-outputs-terminal', { histories: [{ outputs: { '9': { audio: [{ filename: 'output.mp3' }] } } }] }],
  ['output-name-fallback', { histories: [{ outputs: { '9': { audio: [{ name: ' fallback.music ' }] } }, status: { completed: true } }],
    images: [image('fallback.music')] }],
  ['output-filename-priority', { histories: [{ outputs: { '9': { audio: [{ filename: ' chosen.raw ', name: 'ignored.wav' }] } }, status: { completed: true } }],
    images: [image('chosen.raw')] }],
  ['encoded-output-query', { histories: [{ outputs: { '9': { audio: [{ filename: ' 曲 +#?.mp3 ', subfolder: ' folder /一 ', type: ' temp ' }] } }, status: { completed: true } }],
    images: [image('曲 +#?.mp3')], queries: ['filename=%E6%9B%B2+%2B%23%3F.mp3&subfolder=folder+%2F%E4%B8%80&type=temp'] }],
  ['output-node-selector', { histories: [{ outputs: { '9': { audio: [{ filename: 'unselected.mp3' }] }, z: { audio: [{ filename: 'selected.mp3' }] } }, status: { completed: true } }],
    images: [image('selected.mp3', 'z')] }],
  ['output-order-integer-keys', { histories: [{ outputs: { '2': { audio: [{ filename: 'two.mp3' }] }, '10': { audio: [{ filename: 'ten.mp3' }] } }, status: { completed: true } }],
    images: [image('two.mp3', '2'), image('ten.mp3', '10', 'QUJD')] }],
  ['output-order-string-keys', { histories: [{ outputs: { z: { audio: [{ filename: 'z.mp3' }] }, a: { audio: [{ filename: 'a.mp3' }] } }, status: { completed: true } }],
    images: [image('z.mp3', 'z'), image('a.mp3', 'a', 'QUJD')] }],
  ['output-order-integer-and-string-keys', { histories: [{ outputs: { '2': { audio: [{ filename: 'two.mp3' }] },
    '10': { audio: [{ filename: 'ten.mp3' }] }, z: { audio: [{ filename: 'z.mp3' }] }, a: { audio: [{ filename: 'a.mp3' }] } }, status: { completed: true } }],
    images: [image('two.mp3', '2'), image('ten.mp3', '10', 'QUJD'), image('z.mp3', 'z', 'REVG'), image('a.mp3', 'a', 'R0hJ')] }],
  ['output-order-within-node', { histories: [{ outputs: { '9': { audio: [{ filename: 'first.mp3' }, { filename: 'second.mp3' }] } }, status: { completed: true } }],
    images: [image('first.mp3'), image('second.mp3', '9', 'QUJD')] }],
  ['audio-bucket-selection', { histories: [{ outputs: { '9': { images: [{ filename: 'ignore.png' }], gifs: [{ filename: 'ignore.gif' }], videos: [{ filename: 'ignore.mp4' }], audio: [{ filename: 'output.mp3' }] } }, status: { completed: true } }] }],
  ['base-prefix-normalization', { apiBase: 'https://comfy.example.test/resource/v1', rawBase: ' \uFEFFhttps://comfy.example.test/resource/v1///\u00a0' }],
  ['output-missing-mime', { images: [image('output.mp3', '9', audio, 'application/octet-stream')] }],
  ['output-mime-parameters', { images: [image('output.mp3', '9', audio, 'Audio/MPEG; profile="ordinary"')] }],
  ['output-wav-raw-filename', { histories: [{ outputs: { '9': { audio: [{ filename: 'opaque.original' }] } }, status: { completed: true } }],
    images: [image('opaque.original', '9', audio, 'audio/wav')] }],
  ['alternate-prompt-binding', { alternatePrompt: 'positive' }],
  ['repeat-workflow-first', { text: 'first independent prompt' }], ['repeat-workflow-second', { text: 'second independent prompt' }],
  ['local-upload-default-mime', { upload: uploadFields(png, 'image/png', 'input.png') }],
  ['local-upload-null-mime', { upload: uploadFields(png, 'image/png', 'input.png') }],
  ['cloud-upload-named', { cloud: true, upload: uploadFields(png, 'image/png', 'reference +.png'),
    uploadResponse: { name: ' uploaded fallback.png ' }, uploadedName: 'uploaded fallback.png', alternateImage: 'reference', statuses: ['pending', 'completed'] }],
  ['upload-filename-priority', { upload: uploadFields(png, 'image/png', 'source.png'),
    uploadResponse: { filename: ' chosen.png ', name: 'ignored.png' }, uploadedName: 'chosen.png' }],
  ['source-only-seed-binding', { sourceOnly: true, seedInput: 'seed' }],
  ['source-only-alternate-seed-binding', { sourceOnly: true, seedInput: 'noise_seed' }],
  ['source-only-default-timeout', { sourceOnly: true, timeoutMs: 300000 }],
  ['source-only-configured-timeout', { sourceOnly: true, timeoutMs: 45000 }],
  ['source-only-configured-header', { sourceOnly: true, header: true }],
  ['source-only-music-overlay', { sourceOnly: true, alternatePrompt: 'caption' }],
  ['source-only-media-config-small', { sourceOnly: true, cap: 1310720 }],
  ['source-only-media-config-large', { sourceOnly: true, cap: 84148224 }],
];

function expectedStages(plan) {
  const stages = [];
  const json = (kind, path, label, payload, body) => stages.push({ kind, path, label, responseJson: JSON.stringify(payload),
    ...(body ? { jsonBody: body, rawBody: JSON.stringify(body) } : {}) });
  const prepared = graph(plan.text ?? prompt);
  if (plan.alternatePrompt) { prepared['6'].inputs.text = 'original prompt'; prepared['6'].inputs[plan.alternatePrompt] = prompt; }
  if (plan.seedInput) prepared['3'].inputs[plan.seedInput] = 42;
  const beforeNetwork = JSON.parse(JSON.stringify(prepared));
  if (plan.upload) prepared['8'].inputs[plan.alternateImage ?? 'image'] = plan.uploadedName ?? 'uploaded.png';
  const api = plan.cloud ? '/api' : '';
  if (plan.upload) { json('upload', api + '/upload/image', 'Comfy image upload failed', plan.uploadResponse ?? { filename: 'uploaded.png' }); stages.at(-1).fields = plan.upload; }
  json('prompt', api + '/prompt', 'Comfy workflow submit failed', { prompt_id: ' job-17 ' },
    { prompt: prepared, ...(plan.cloud ? { extra_data: { api_key_comfy_org: 'synthetic-comfy-key' } } : {}) });
  if (plan.cloud) for (const status of plan.statuses ?? ['completed']) {
    json('status', '/api/job/job-17/status', 'Comfy status lookup failed', { status });
    if (status !== 'completed') stages.push({ sleep: 100 });
  }
  const histories = plan.histories ?? (plan.pendingLocal ? [{}, ordinaryHistory] : [ordinaryHistory]);
  histories.forEach((payload, index) => {
    json('history', plan.cloud ? '/api/history_v2/job-17' : '/history/job-17', 'Comfy history lookup failed', payload);
    if (index < histories.length - 1) stages.push({ sleep: 100 });
  });
  const images = plan.images ?? [image()];
  images.forEach((asset, index) => stages.push({ kind: 'download',
    path: api + '/view?' + (plan.queries?.[index] ?? `filename=${asset.fileName}&subfolder=&type=output`),
    label: 'Comfy output download failed', bytesBase64: asset.bytesBase64 }));
  return { stages, images, prepared, beforeNetwork, histories };
}

test('42 literal full wire/result and lifetime plans cover original ordinary callback', () => {
  assert.equal(plans.length, 42);
  assert.deepEqual([...rows.keys()], plans.map(([id]) => id));
  for (const [id, plan = {}] of plans) {
    const row = rows.get(id), total = plan.timeoutMs ?? 30000;
    const { stages, images, prepared, beforeNetwork, histories } = expectedStages(plan);
    const headers = { 'content-type': 'application/json', ...(plan.cloud ? { 'x-api-key': 'synthetic-comfy-key' } : {}),
      ...(plan.header ? { 'x-ordinary': 'literal value' } : {}) };
    let now = 100003;
    const requests = [], readers = [], releases = [], statuses = [], sleeps = [];
    for (const stage of stages) {
      if (stage.sleep) { sleeps.push({ ms: stage.sleep, atMs: now }); now += stage.sleep; continue; }
      const binary = stage.kind === 'download';
      const requestHeaders = { ...headers };
      if (stage.kind === 'upload') delete requestHeaders['content-type'];
      const atMs = now, timeoutMs = total - (now - 100003);
      now += binary ? 5 : 7;
      statuses.push({ label: stage.label, atMs: now, remainingMs: total - (now - 100003), implementation: 'successful-status-facade' });
      const remainingBeforeMs = total - (now - 100003);
      const readAtMs = now;
      now += binary ? 2 : 3;
      readers.push({ kind: binary ? 'binary' : 'json', requestKind: stage.kind, atMs: readAtMs,
        maxBytes: binary ? plan.cap ?? 16777216 : 16777216,
        chunkTimeoutMs: binary ? remainingBeforeMs : 30000,
        remainingBeforeMs, remainingAfterMs: total - (now - 100003), hasOnOverflow: true, hasOnIdleTimeout: true,
        bytesBase64: binary ? stage.bytesBase64 : Buffer.from(stage.responseJson).toString('base64'),
        implementation: 'successful-lower-body-reader-facade' });
      const url = (plan.apiBase ?? base) + stage.path;
      requests.push({ kind: stage.kind, url, method: ['prompt', 'upload'].includes(stage.kind) ? 'POST' : 'GET',
        headers: requestHeaders, timeoutMs, atMs, auditContext: stage.kind === 'prompt' ? 'comfy-music-generate'
          : stage.kind === 'upload' ? 'comfy-music-upload' : binary ? 'comfy-music-download' : 'comfy-' + stage.kind,
        releaseCount: 1, bodyReadCount: 1, bodyUsedBeforeRead: false, bodyUsedAfterRead: true, ...(stage.fields ? { fields: stage.fields } : {}),
        ...(stage.rawBody ? { rawBody: stage.rawBody, jsonBody: stage.jsonBody } : {}),
        ...(binary ? {} : { responseJson: stage.responseJson }), releasedAtMs: now });
      releases.push({ kind: stage.kind, url, atMs: now, releaseCount: 1 });
    }
    assert.deepEqual(row.requests, requests, id + ' full wire order/JSON/multipart/GET');
    assert.deepEqual(row.result, { tracks: images.map(({ metadata, ...track }) => track), model: plan.model ?? 'workflow',
      metadata: { promptId: 'job-17', outputNodeIds: [...new Set(images.map(value => value.metadata.nodeId))], inputImageCount: plan.upload ? 1 : 0 } }, id + ' full result');
    assert.deepEqual(row.preparedBeforeNetwork, beforeNetwork, id + ' original preparation before upload/network');
    assert.deepEqual(row.preparedWorkflow, prepared, id + ' original graph mutation after upload');
    assert.deepEqual(row.readerCalls, readers, id + ' caps/deadlines');
    assert.deepEqual(row.statusCalls, statuses, id + ' status boundary');
    assert.deepEqual(row.releaseCalls, releases, id + ' full response lifetime');
    assert.deepEqual(row.sleepCalls, sleeps, id + ' finite monotonic sleeps');
    assert.deepEqual(row.historyJson, histories.map(value => JSON.stringify(value)), id + ' original ordered history JSON');
    assert.deepEqual(row.clock, { kind: 'synthetic-monotonic-performance.now', startMs: 100000, deadlineStartMs: 100003,
      endMs: now, serviceCostsMs: { config: 3, jsonFetch: 7, jsonRead: 3, download: 5, binaryRead: 2 } }, id);
    assert.deepEqual(row.inputAfter, row.input, id + ' input unchanged');
    assert.deepEqual(row.configAfter, row.projectedConfig, id + ' workflow clone/config unchanged');
    assert.equal(row.projectedConfig.plugins.entries.comfy.config.workflow['3'].inputs.seed, 731, id + ' baked seed');
    assert.equal(row.projectedConfig.plugins.entries.comfy.config.workflow['6'].inputs.text, 'original prompt', id);
    assert.equal(row.hostComparable, !plan.sourceOnly, id);
    if (plan.sourceOnly) assert.ok(row.adaptationReason.length > 20, id);
    else {
      assert.equal(row.config.mode, plan.cloud ? 'cloud' : 'local', id);
      assert.equal(row.config.baseUrl, plan.rawBase ?? 'https://comfy.example.test', id);
      assert.ok(row.input.model == null || typeof row.input.model === 'string', id);
      assert.ok(Number.isFinite(row.input.timeoutMs) && row.input.timeoutMs > 0, id);
    }
    assert.deepEqual(row.randomCalls, plan.seedInput ? [{ exclusiveMax: 281474976710655, value: 42,
      implementation: 'deterministic-randomInt-facade' }] : [], id);
  }
});

test('literal descriptor and registration capture do not activate the native registry', () => {
  assert.deepEqual(capture.providerDescriptor, { id: 'comfy', label: 'ComfyUI', defaultModel: 'workflow', models: ['workflow'],
    capabilities: { generate: {}, edit: { enabled: true, maxInputImages: 1 } } });
  assert.deepEqual(capture.descriptorMethods, ['isConfigured', 'isConfiguredAsync', 'generateMusic']);
  assert.deepEqual(capture.registrationCalls, [
    { kind: 'definePluginEntry', id: 'comfy' }, { kind: 'provider-descriptor-only', id: 'comfy' },
    { kind: 'uninvoked-image-descriptor', id: 'comfy' }, { kind: 'music-callback-captured', id: 'comfy' },
    { kind: 'uninvoked-video-descriptor', id: 'comfy' },
  ]);
  for (const id of ['output-order-integer-keys', 'output-order-string-keys', 'output-order-within-node']) {
    assert.equal(Object.hasOwn(rows.get(id).input, 'count'), false, id + ' ordinary workflow result omits count');
  }
  assert.equal(rows.get('ignored-raw-music-options').input.instrumental, true);
  assert.equal(rows.get('ignored-raw-music-options').input.format, 'wav');
  assert.equal(rows.get('ignored-raw-music-options').input.lyrics, 'ignored lyric text');
  assert.deepEqual(rows.get('ignored-raw-music-options').preparedWorkflow, graph());
  assert.deepEqual(rows.get('repeat-workflow-first').preparedWorkflow, graph('first independent prompt'));
  assert.deepEqual(rows.get('repeat-workflow-second').preparedWorkflow, graph('second independent prompt'));
});

test('whole modules, complete regions, generated imports and runtime receipts reconstruct', () => {
  assert.equal(COMFY_MUSIC_GENERATION_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.referencePin, COMFY_MUSIC_GENERATION_PIN);
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  const expectedWhole = ['extensions/comfy/index.ts', 'extensions/comfy/workflow-runtime.ts', 'extensions/comfy/workflow-http.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/string-normalization.ts',
    'src/utils/boolean.ts', 'packages/media-core/src/constants.ts', 'packages/media-core/src/mime.ts',
    'packages/media-core/src/file-name.ts', 'src/plugin-sdk/blob-runtime.ts', 'packages/media-core/src/base64.ts'];
  assert.deepEqual(capture.sourceRecords.filter(value => value.wholeModule).map(value => value.path).sort(), expectedWhole.sort());
  const projected = capture.sourceRecords.filter(value => value.executed && !value.wholeModule);
  assert.equal(projected.length, 3);
  for (const row of capture.sourceRecords) {
    const source = readFileSync(join(root, row.path));
    assert.equal(row.sha256, hash(source), row.path);
    if (!row.executed) { assert.equal(row.provenanceOnly, true); continue; }
    let generated = source.toString();
    if (row.projection) {
      assert.ok(row.projection.justification.length > 60);
      const chunks = row.projection.regions.map(region => {
        const bytes = source.subarray(region.startByte, region.endByte);
        assert.equal(region.sourceRegionSha256, hash(bytes)); return bytes.toString();
      });
      generated = row.projection.prelude + '\n' + chunks.join('\n');
      assert.equal(row.projection.generatedCode, generated);
      assert.equal(row.projection.generatedSha256, hash(generated));
    }
    assert.equal(row.transformation, 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false })));
  }
  for (const binding of capture.importBindings) {
    assert.ok(binding.importer.length > 0 && binding.specifier.length > 0);
    if (binding.specifier.startsWith('openclaw/plugin-sdk/')) {
      const originalSdkPath = 'src/plugin-sdk/' + binding.specifier.split('/').at(-1) + '.ts';
      assert.ok(capture.sourceRecords.some(row => row.path === originalSdkPath), originalSdkPath + ' explicit import provenance');
    }
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    if (binding.source) assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))));
  }
  assert.deepEqual(capture.dynamicImports, []);
  assert.deepEqual(capture.observationSeams.map(row => [row.name, row.implementation]),
    [['structuredClone', 'native-primitive-with-reference-observation']]);
  assert.equal(capture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-comfy-music-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.ok(capture.serviceFacadeLedger.every(row => row.productionExecuted === false && row.limit.length > 30));
  assert.ok(capture.serviceFacadeLedger.some(row => row.name === 'readResponseWithLimit' && row.limit.includes('No reader-equivalence claim')));
});

test('two fresh captures are plain deterministic observations and match the CLI fixture', async () => {
  const second = await captureComfyMusicGeneration(root);
  assert.deepEqual(second, capture);
  assert.deepEqual(JSON.parse(JSON.stringify(capture)), capture);
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/comfy-music-generation.json', import.meta.url)));
  assert.deepEqual(fixture, capture);
});

test('music callback removes asset metadata and defaults reference MIME without changing request fields', () => {
  for (const row of rows.values()) {
    assert.ok(row.result.tracks.every(track => !Object.hasOwn(track, 'metadata')));
    assert.ok(row.configCalls.every(call => call.capability === 'audio'));
    assert.ok(row.requests.every(request => request.bodyReadCount === 1 && request.bodyUsedAfterRead));
    const downloadCaps = row.readerCalls.filter(call => call.kind === 'binary').map(call => call.maxBytes);
    const expectedCap = row.id === 'source-only-media-config-small' ? 1310720
      : row.id === 'source-only-media-config-large' ? 84148224 : 16777216;
    assert.ok(downloadCaps.every(cap => cap === expectedCap), row.id);
  }
  assert.equal(Object.hasOwn(rows.get('local-upload-default-mime').input.inputImages[0], 'mimeType'), false);
  assert.equal(rows.get('local-upload-null-mime').input.inputImages[0].mimeType, null);
  for (const id of ['local-upload-default-mime', 'local-upload-null-mime']) {
    assert.deepEqual(rows.get(id).requests.find(request => request.kind === 'upload').fields, uploadFields(png, 'image/png', 'input.png'));
  }
  assert.equal(rows.get('source-only-music-overlay').config.music.promptInputName, 'caption');
});

test('ordinary audio bucket selection omits nonaudio assets before any download', () => {
  const row = rows.get('audio-bucket-selection');
  assert.deepEqual(Object.keys(row.responsePlan.histories[0].outputs['9']), ['images', 'gifs', 'videos', 'audio']);
  assert.deepEqual(row.requests.filter(request => request.kind === 'download').map(request => request.url),
    ['https://comfy.example.test/view?filename=output.mp3&subfolder=&type=output']);
  assert.deepEqual(row.result.tracks, [{ mimeType: 'audio/mpeg', fileName: 'output.mp3', bytesBase64: audio }]);
});
