// Ordinary valid synthetic success cases only; no provider connection or auth-flow checks.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenAIImageGeneration } from './capture-openai-image-generation.mjs';

const root = '/tmp/openclaw-488631c';
const capture = await captureOpenAIImageGeneration(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const body = row => row.request.jsonBody ?? Object.fromEntries(row.request.formEntries.filter(part => Object.hasOwn(part, 'value')).map(part => [part.name, part.value]));
const names = ['default-size', 'explicit-count', 'legacy-closest-size', 'native-closest-size',
  'flexible-gpt-image-2', 'flexible-dated-model', 'flexible-gpt-image-2.5', 'auto-gpt-image-2.5',
  'jpeg-options', 'webp-options', 'png-options', 'custom-prefix', 'edit-one', 'edit-many-native-mime',
  'ordered-inline', 'ordered-urls', 'mixed-inline-url', 'usage-zero-nested', 'usage-absent',
  'azure-default-version', 'azure-explicit-version-edit', 'source-only-transparent-reroute'];

test('22 complete direct-source executions retain inputs, ordered outputs and successful release receipts', () => {
  assert.deepEqual(capture.observations.map(row => row.id), names);
  for (const row of capture.observations) {
    assert.deepEqual(row.inputAfter, row.input, row.id);
    assert.equal(row.request.method, 'POST', row.id);
    assert.equal(row.request.timeoutMs, 12345, row.id);
    assert.equal(row.releaseCount, 1, row.id);
    assert.equal(row.result.images.length, row.input.count ?? 1, row.id);
    assert.equal(row.result.model, row.id === 'source-only-transparent-reroute' ? 'gpt-image-1.5' : row.input.model, row.id);
    assert.equal(body(row).prompt, ' Draw a small blue square. ', row.id);
    const count = row.input.count ?? 1;
    assert.deepEqual(row.readerCalls[0], { kind: 'json', maxBytes: Math.ceil(67108864 * count * 4 / 3) + 1048576, timeoutMs: 12345 }, row.id);
    assert.deepEqual(row.downloads.map(download => download.url), row.response.downloads.map(download => download.url), row.id);
    for (const download of row.downloads) assert.deepEqual(download, { url: download.url, method: 'GET', timeoutMs: 12345,
      maxBytes: 67108864, releaseCount: 1 }, row.id);
    assert.equal(row.readerCalls.length, 1 + row.downloads.length, row.id);
  }
});

test('ordinary generation bodies retain explicit model/count, defaults and exact field insertion order', () => {
  assert.deepEqual(rows.get('default-size').request.jsonBody, { model: 'gpt-image-1.5',
    prompt: ' Draw a small blue square. ', n: 1, size: '1024x1024' });
  assert.deepEqual(Object.keys(rows.get('default-size').request.jsonBody), ['model', 'prompt', 'n', 'size']);
  assert.equal(rows.get('explicit-count').request.jsonBody.n, 4);
  assert.equal(rows.get('explicit-count').result.images.length, 4);
  for (const row of capture.observations.filter(row => !row.id.startsWith('azure-') && row.id !== 'custom-prefix')) {
    assert.equal(row.request.url, `https://api.openai.com/v1/images/${row.input.inputImages ? 'edits' : 'generations'}`, row.id);
  }
});

test('actual legacy/native/flexible/auto size helpers supply normalized geometry and metadata', () => {
  const expected = [
    ['legacy-closest-size', '1536x1024', { requestedSize: '1600x900', normalizedSize: '1536x1024' }],
    ['native-closest-size', '1536x1024', { requestedSize: '2048x1536', normalizedSize: '1536x1024' }],
    ['flexible-gpt-image-2', '1600x960'], ['flexible-dated-model', '1600x960'],
    ['flexible-gpt-image-2.5', '1600x960'], ['auto-gpt-image-2.5', 'auto'],
  ];
  for (const [id, size, metadata] of expected) {
    assert.equal(body(rows.get(id)).size, size, id);
    assert.deepEqual(rows.get(id).result.metadata, metadata, id);
  }
  assert.equal(rows.get('flexible-gpt-image-2.5').request.jsonBody.quality, 'xhigh');
  assert.equal(rows.get('auto-gpt-image-2.5').request.jsonBody.quality, 'max');
});

test('output formats, provider-option precedence, compression and user are source-owned', () => {
  const jpeg = rows.get('jpeg-options');
  assert.equal(jpeg.input.background, 'opaque');
  assert.deepEqual(jpeg.request.jsonBody, { model: 'gpt-image-1.5', prompt: ' Draw a small blue square. ', n: 1,
    size: '1024x1024', quality: 'high', output_format: 'jpeg', background: 'auto', moderation: 'low',
    output_compression: 73, user: 'fixture-user' });
  assert.deepEqual(Object.keys(jpeg.request.jsonBody), ['model', 'prompt', 'n', 'size', 'quality', 'output_format',
    'background', 'moderation', 'output_compression', 'user']);
  assert.equal(jpeg.result.images[0].mimeType, 'image/jpeg');
  assert.equal(jpeg.result.images[0].fileName, 'image-1.jpg');
  assert.equal(jpeg.result.images[0].revisedPrompt, 'Refined square.');
  const webp = rows.get('webp-options');
  assert.equal(webp.request.jsonBody.output_compression, 80);
  assert.equal(webp.result.images[0].mimeType, 'image/webp');
  assert.equal(webp.result.images[0].fileName, 'image-1.webp');
  assert.equal(rows.get('png-options').input.providerOptions.openai.outputCompression, 80);
  assert.deepEqual(rows.get('png-options').request.jsonBody, { model: 'gpt-image-1.5', prompt: ' Draw a small blue square. ',
    n: 1, size: '1024x1024', output_format: 'png', background: 'transparent' });
});

test('custom prefixes retain selected model, unsnapped ordinary size and whole source base resolver', () => {
  const row = rows.get('custom-prefix');
  assert.equal(row.config.baseUrl, ' https://images.example.test/custom/v2/// ');
  assert.equal(row.request.url, 'https://images.example.test/custom/v2/images/generations');
  assert.deepEqual(row.request.jsonBody, { model: 'Vendor/Image-X', prompt: ' Draw a small blue square. ',
    n: 1, size: '1280x720', quality: 'high' });
  assert.equal(row.result.metadata, undefined);
});

test('native multipart edits preserve ordered fields, POSIX basename, default filenames, MIME and bytes', () => {
  const one = rows.get('edit-one');
  assert.deepEqual(one.request.formEntries.slice(0, 4), [{ name: 'model', value: 'gpt-image-1.5' },
    { name: 'prompt', value: ' Draw a small blue square. ' }, { name: 'n', value: '1' }, { name: 'size', value: '1024x1024' }]);
  assert.equal(one.request.formEntries[4].fileName, 'square.png');
  assert.equal(one.input.inputImages[0].fileName, '  photos/day/square.png  ');
  const many = rows.get('edit-many-native-mime');
  assert.deepEqual(many.request.formEntries.map(part => part.name), ['model', 'prompt', 'n', 'size', 'quality', 'output_format', 'image[]', 'image[]', 'image[]']);
  const files = many.request.formEntries.filter(part => part.name === 'image[]');
  assert.deepEqual(files.map(part => [part.fileName, part.mimeType, part.size]), [
    ['image-1.png', 'image/png', 68], ['image-2.jpg', 'image/jpeg; colorspace=rgb', 517], ['image-3.webp', 'image/webp', 42] ]);
  assert.deepEqual(files.map(part => part.bytesBase64), many.input.inputImages.map(image => image.bytesBase64));
});

test('actual asset parser and sequential URL inlining preserve MIME, bytes, prompt trimming and order', () => {
  const inline = rows.get('ordered-inline');
  assert.deepEqual(inline.result.images.map(image => [image.mimeType, image.fileName, image.revisedPrompt]), [
    ['image/png', 'image-1.png', 'First'], ['Image/JPEG; mode=RGB', 'image-2.jpg', undefined], ['image/webp', 'image-3.webp', undefined] ]);
  assert.deepEqual(inline.result.images.map(image => image.bytesBase64), inline.response.json.data.map(image => image.b64_json));
  const urls = rows.get('ordered-urls');
  assert.deepEqual(urls.result.images.map(image => [image.mimeType, image.fileName, image.revisedPrompt]), [
    ['image/jpeg', 'image-1.jpg', 'One'], ['image/webp', 'image-2.webp', 'Two'] ]);
  assert.deepEqual(urls.result.images.map(image => image.bytesBase64), urls.response.downloads.map(image => image.bytesBase64));
  const mixed = rows.get('mixed-inline-url');
  assert.deepEqual(mixed.result.images.map(image => image.mimeType), ['image/png', 'image/jpeg', 'image/webp']);
  assert.deepEqual(mixed.result.images.map(image => image.bytesBase64), [mixed.response.json.data[0].b64_json,
    mixed.response.downloads[0].bytesBase64, mixed.response.json.data[2].b64_json]);
  assert.deepEqual(mixed.downloads.map(image => image.url), ['https://assets.example.test/middle']);
});

test('actual usage projection keeps zero and nested counts while absence stays absent', () => {
  assert.deepEqual(rows.get('usage-zero-nested').result.metadata, { usage: {
    input_tokens: 0, output_tokens: 2, total_tokens: 2,
    input_tokens_details: { text_tokens: 0, image_tokens: 0 }, output_tokens_details: { text_tokens: 0, image_tokens: 2 } } });
  assert.equal(Object.hasOwn(rows.get('usage-absent').result, 'metadata'), false);
});

test('Azure uses deployment endpoints/default or explicit fixture versions and omits model body', () => {
  const normal = rows.get('azure-default-version');
  assert.equal(normal.request.url, 'https://images.openai.azure.com/openai/deployments/square-deployment/images/generations?api-version=2024-12-01-preview');
  assert.deepEqual(normal.request.jsonBody, { prompt: ' Draw a small blue square. ', n: 1, size: '2048x1152' });
  assert.deepEqual(normal.result.metadata, { requestedSize: '1600x900', normalizedSize: '2048x1152' });
  const edit = rows.get('azure-explicit-version-edit');
  assert.equal(edit.request.url, 'https://images.openai.azure.com/openai/deployments/square-deployment/images/edits?api-version=2025-04-01-preview');
  assert.deepEqual(edit.request.formEntries.map(part => part.name), ['prompt', 'n', 'size', 'image[]']);
  assert.equal(edit.result.model, 'square-deployment');
});

test('source default transparent reroute is an explicit host adaptation with its own comparison flag', () => {
  const row = rows.get('source-only-transparent-reroute');
  assert.equal(row.input.model, 'gpt-image-2');
  assert.equal(row.request.jsonBody.model, 'gpt-image-1.5');
  assert.equal(row.result.model, 'gpt-image-1.5');
  assert.equal(row.hostComparable, false);
  assert.match(row.adaptationReason, /preserves the explicit selected model/);
  assert.equal(capture.observations.filter(row => row.hostComparable).length, 21);
});

test('whole modules, complete original projections and generated aliases reconstruct exact executable provenance', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = capture.sourceRecords.filter(row => row.executed);
  assert.equal(executed.filter(row => row.wholeModule).length, 15);
  assert.equal(executed.filter(row => !row.wholeModule).length, 3);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (!row.executed) continue;
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
  for (const module of ['extensions/openai/image-generation-provider.ts', 'extensions/openai/image-generation-response.ts',
    'src/image-generation/image-assets.ts', 'src/image-generation/openai-compatible-image-urls.ts']) {
    assert.ok(executed.some(row => row.path === module && row.wholeModule), module);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-openai-image-generation.mjs', import.meta.url))));
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
});

test('complete tracked reference tree remains fixed and synthetic lower service boundaries are explicit', () => {
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.deepEqual(capture.sourceTree.after, capture.sourceTree.before);
  for (const text of ['complete original source regions', 'bounded stream reader', 'native FormData/Blob/File',
    'synthetic VM process.env', 'hostComparable=false', 'Inactive provider groundwork']) {
    assert.ok(capture.limits.some(limit => limit.includes(text)), text);
  }
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-native-http-reader-fixture'));
  assert.ok(capture.importBindings.some(row => row.kind === 'successful-native-download-fixture'));
  assert.ok(capture.dynamicImports.some(row => row.specifier === './image-generation-response.js'));
});

test('fresh independent complete-source executions reproduce every frozen field', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-image-generation.json', import.meta.url)));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureOpenAIImageGeneration(root), frozen);
});
