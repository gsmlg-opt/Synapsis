// Positive ordinary source oracle. No Synapsis implementation is imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureTavilyExtract, unframeExtractText } from './capture-tavily-extract.mjs';

const root = process.env.OPENCLAW_TAVILY_EXTRACT_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_TAVILY_EXTRACT_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/tavily-extract.json', import.meta.url);
const capture = await captureTavilyExtract(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => {
  const row = capture.groups.find(row => row.id === id);
  assert.ok(row, id);
  return row;
};
const first = id => group(id).steps[0];
const result = id => first(id).resultUnframed;
const units = row => row.results.reduce((sum, entry) =>
  sum + entry.rawContent.length + (entry.content?.length ?? 0), 0);
const one = 'https://source.example/one';
const two = 'https://source.example/two';

test('executes pin-verified complete plugin, factory, readers, client, config, cache, wrappers and jsonResult modules', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  assert.equal(capture.boundaries.pluginRegistrationInvoked, true);
  assert.equal(capture.boundaries.actualCommonPost, true);
  assert.equal(capture.boundaries.actualJsonResult, true);
  assert.equal(capture.boundaries.actualExtractCache, true);
  assert.equal(capture.boundaries.genericNormalizerInvoked, false);
  for (const path of [
    'extensions/tavily/index.ts', 'extensions/tavily/src/config.ts',
    'extensions/tavily/src/tavily-client.ts', 'extensions/tavily/src/tavily-search-provider.ts',
    'src/agents/schema/string-enum.ts', 'src/plugin-sdk/plugin-entry.ts', 'src/plugin-sdk/lazy-value.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/web-shared.ts',
    'src/config/plugin-web-search-config.ts', 'src/security/external-content.ts',
    'packages/normalization-core/src/utf16-slice.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(digest(bytes), row.sourceSha256, row.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      row.executableSha256, row.path);
    assert.equal(row.wholeModule, true);
  }
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
  for (const row of capture.facades) assert.equal(digest(row.generatedCode), row.sha256);
  for (const row of [capture.manifest, capture.license]) assert.equal(digest(readFileSync(join(root, row.path))), row.sha256);
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.deepEqual(capture.manifest.content, JSON.parse(readFileSync(join(root, capture.manifest.path), 'utf8')));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-tavily-extract.mjs', import.meta.url))));
  for (const row of capture.harnessDependencies) assert.equal(digest(readFileSync(new URL('../../' + row.path, import.meta.url))), row.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.sha256);
  assert.ok(capture.typebox.files.length > 300);
});

test('actual plugin registration exposes the exact extraction schema and descriptor', () => {
  const { descriptor, registration } = group('basic-default');
  assert.equal(registration.pluginId, 'tavily');
  assert.deepEqual(registration.providers, [{ id: 'tavily', label: 'Tavily Search' }]);
  assert.deepEqual(registration.tools, [{ name: 'tavily_search' }, { name: 'tavily_extract' }]);
  assert.equal(descriptor.name, 'tavily_extract');
  assert.equal(descriptor.label, 'Tavily Extract');
  assert.equal(descriptor.resultContentSource, 'network');
  assert.equal(descriptor.description, 'Extract clean content from one or more URLs using Tavily. Handles JS-rendered pages. Supports query-focused chunking.');
  const schema = descriptor.parameters;
  assert.deepEqual(Object.keys(schema.properties), ['urls', 'query', 'extract_depth', 'chunks_per_source', 'include_images']);
  assert.deepEqual(schema.required, ['urls']);
  assert.equal(schema.additionalProperties, false);
  assert.deepEqual(schema.properties.urls.items, { type: 'string' });
  assert.equal(schema.properties.urls.minItems, 1);
  assert.equal(schema.properties.urls.maxItems, 20);
  assert.deepEqual(schema.properties.extract_depth.enum, ['basic', 'advanced']);
  assert.equal(schema.properties.chunks_per_source.type, 'integer');
  assert.equal(schema.properties.chunks_per_source.minimum, 1);
  assert.equal(schema.properties.chunks_per_source.maximum, 5);
  assert.equal(schema.properties.include_images.type, 'boolean');
  assert.equal(schema.properties.format, undefined);
  for (const row of capture.groups) assert.deepEqual(row.descriptor, descriptor);
});

test('actual common HTTP builder records exact default and proxy requests and 64MiB parse parameter', () => {
  const request = first('basic-default').request;
  assert.equal(request.url, 'https://api.tavily.com/extract');
  assert.equal(request.path, '/extract');
  assert.equal(request.method, 'POST');
  assert.equal(request.timeoutSeconds, 60);
  assert.deepEqual(request.body, { urls: [one] });
  assert.equal(request.bodyText, JSON.stringify(request.body));
  assert.deepEqual(request.headers, { accept: 'application/json', authorization: 'Bearer fixture-tavily-key',
    'content-type': 'application/json', 'x-client-source': 'openclaw' });
  assert.equal(first('basic-proxy').request.url, 'https://extract.example/proxy/extract');
  assert.equal(first('basic-proxy').request.timeoutSeconds, 60);
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false);
    assert.deepEqual(row.configAfter, row.config);
    const httpCalls = row.audit.filter(item => item.kind === 'successful-http-fixture');
    const parserCalls = row.audit.filter(item => item.kind === 'successful-json-fixture');
    assert.equal(httpCalls.length, row.steps.at(-1).cumulativeRequests);
    assert.equal(parserCalls.length, httpCalls.length);
    for (const item of parserCalls) assert.deepEqual(item,
      { kind: 'successful-json-fixture', errorLabel: 'Tavily Extract', options: { maxBytes: 67_108_864 } });
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.equal(step.result.tookMs, 7);
      assert.deepEqual(step.toolResult.details, step.result);
      assert.deepEqual(step.toolResult.content, [{ type: 'text', text: JSON.stringify(step.result, null, 2) }]);
      assert.deepEqual(step.result.externalContent,
        { untrusted: true, source: 'web_fetch', provider: 'tavily', wrapped: true });
    }
  }
});

test('preserves ordered duplicate URLs, options, content and images without generic search projection', () => {
  const step = first('ordered-options');
  assert.deepEqual(step.arguments.urls, [` ${two} `, one, two]);
  assert.deepEqual(step.request.body, { urls: [two, one, two], query: 'focused query', extract_depth: 'advanced',
    chunks_per_source: 5, include_images: true });
  assert.deepEqual(step.resultUnframed.results, [
    { url: two, rawContent: ' Second raw ', content: ' Second content ', images: ['https://images.example/2.png', 'https://images.example/1.png'] },
    { url: one, rawContent: ' First raw ', content: '', images: [] },
    { url: two, rawContent: ' Duplicate raw ' },
  ]);
  assert.deepEqual(Object.keys(result('basic-default')), ['provider', 'count', 'tookMs', 'externalContent', 'results']);
  assert.deepEqual(result('basic-default').results, [{ url: one, rawContent: ' Ordinary passage 😀 \n' }]);
  assert.deepEqual(result('empty-content').results, [
    { url: one, rawContent: '', content: '', images: [] }, { url: two, rawContent: '' },
  ]);
  assert.deepEqual(result('url-canonicalization').results, [
    { url: 'https://source.example/ordinary?q=hello%20world', rawContent: 'Canonical' },
    { url: 'https://bare.example', rawContent: 'Bare host' },
  ]);
});

test('caps provider success rows and applies one shared image budget in row order', () => {
  for (const count of [20, 21]) {
    const rows = result(`results-${count}`);
    assert.equal(rows.count, 20);
    assert.equal(rows.results.length, 20);
    assert.equal(rows.truncated, count === 21 ? true : undefined);
    assert.deepEqual(rows.results.map(row => row.url), Array.from({ length: 20 }, (_, n) => `https://source.example/${n + 1}`));
    assert.deepEqual(first(`results-${count}`).arguments.urls, [one]);
    const images = result(`images-shared-${count}`);
    assert.deepEqual(images.results.map(row => row.images.length), [12, 8]);
    assert.deepEqual(images.results.flatMap(row => row.images), Array.from({ length: 20 }, (_, n) => `https://images.example/${n + 1}.png`));
    assert.equal(images.truncated, count === 21 ? true : undefined);
  }
});

test('removes only exact reference frames and preserves leading/trailing ordinary whitespace', () => {
  const row = first('unicode-whitespace');
  assert.equal(row.resultUnframed.results[0].rawContent, ' \t界😀e\u0301 👩‍💻 \n');
  assert.equal(row.resultUnframed.results[0].content, '\n Content 😀 \t');
  assert.equal(unframeExtractText(row.result.results[0].rawContent), row.resultUnframed.results[0].rawContent);
  assert.ok(row.result.results[0].rawContent.startsWith('\n<<<EXTERNAL_UNTRUSTED_CONTENT'));
  assert.ok(row.toolResult.content[0].text.includes('EXTERNAL_UNTRUSTED_CONTENT'));
  assert.equal(unframeExtractText(first('empty-content').result.results[1].rawContent), '');
});

test('shares exactly 20000 UTF16 units rawContent then content then later rows with scalar-safe boundaries', () => {
  const exact = result('budget-shared-exact');
  assert.equal(units(exact), 20_000);
  assert.equal(exact.results[0].rawContent, 'A'.repeat(12_000));
  assert.equal(exact.results[0].content, 'B'.repeat(7_999));
  assert.equal(exact.results[1].rawContent, 'C');
  assert.equal(exact.truncated, undefined);
  const overflow = result('budget-shared-overflow');
  assert.equal(units(overflow), 20_000);
  assert.equal(overflow.results[1].rawContent, 'C');
  assert.equal(overflow.truncated, true);
  assert.equal(result('unicode-emoji').results[0].rawContent, '😀'.repeat(10_000));
  const leftover = result('unicode-emoji-leftover');
  assert.equal(leftover.results[0].rawContent, '界'.repeat(19_999));
  assert.equal(leftover.results[0].content, 'Z');
  assert.equal(result('unicode-combining').results[0].rawContent, 'e\u0301'.repeat(10_000));
  const zwj = result('unicode-zwj');
  assert.equal(zwj.results[0].rawContent, 'x'.repeat(19_996) + '👩‍');
  assert.equal(zwj.results[0].content, 'Q');
  for (const id of ['unicode-emoji', 'unicode-emoji-leftover', 'unicode-combining', 'unicode-zwj']) {
    const row = result(id);
    assert.equal(units(row), 20_000);
    assert.equal(row.truncated, true);
    assert.equal(row.results[1].rawContent, '');
    for (const entry of row.results) {
      assert.equal(entry.rawContent.isWellFormed(), true);
      if (entry.content !== undefined) assert.equal(entry.content.isWellFormed(), true);
    }
  }
});

test('real extraction cache retains normalized repeat requests and partitions options and ordered URLs', () => {
  const options = group('cache-options').steps;
  assert.deepEqual(options.map(row => row.cached), [false, true, false, true, false, false, false, false, false, true]);
  assert.deepEqual(options.map(row => row.cumulativeRequests), [1, 1, 2, 2, 3, 4, 5, 6, 7, 7]);
  for (const [previous, hit] of [[0, 1], [2, 3], [0, 9]]) {
    assert.equal(options[hit].request, null);
    assert.deepEqual(options[hit].result, { ...options[previous].result, cached: true });
  }
  const order = group('cache-url-order').steps;
  assert.deepEqual(order.map(row => row.cached), [false, false, true]);
  assert.deepEqual(order.map(row => row.cumulativeRequests), [1, 2, 2]);
  assert.deepEqual(order[0].request.body.urls, [one, two, one]);
  assert.deepEqual(order[1].request.body.urls, [two, one, one]);
});

test('extraction cache keeps its fixed 15 minute TTL with search TTL zero and expires at insertion boundary', () => {
  const row = group('cache-expiry-search-ttl-zero');
  assert.equal(row.config.tools.web.search.cacheTtlMinutes, 0);
  assert.deepEqual(row.steps.map(step => step.cached), [false, true, true, false, true]);
  assert.deepEqual(row.steps.map(step => step.cumulativeRequests), [1, 1, 1, 2, 2]);
  const insertionMs = Date.parse(row.steps[0].clock) + row.steps[0].result.tookMs;
  assert.equal(Date.parse(row.steps[2].clock) - insertionMs, 899_999);
  assert.equal(Date.parse(row.steps[3].clock) - insertionMs, 900_000);
  assert.equal(row.steps[2].result.tookMs, row.steps[0].result.tookMs);
  assert.equal(row.steps[3].result.cached, undefined);
});

test('fresh independent capture equals frozen complete extraction fixture', () => {
  assert.equal(capture.counts.groups, 19);
  assert.equal(capture.counts.callbacks, 34);
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});
