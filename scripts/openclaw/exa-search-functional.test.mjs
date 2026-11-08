// Ordinary successful Exa provider/normalizer observations from unchanged pinned modules.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureExaSearch } from './capture-exa-search.mjs';

const root = process.env.OPENCLAW_EXA_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_EXA_FIXTURE;
const capture = await captureExaSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => {
  const row = capture.groups.find(item => item.id === id);
  assert.ok(row, id);
  return row;
};
const first = id => group(id).steps[0];
const normal = id => {
  const row = capture.normalizerCases.find(item => item.id === id);
  assert.ok(row, id);
  return row.publicPortableResult;
};

test('executes complete pinned Exa/config/cache/normalizer/byte-reader source with exact provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verified, true);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.actualBoundedSuccessReader, true);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  assert.equal(capture.boundaries.pluginRegistrationInvoked, false);
  for (const path of [
    'extensions/exa/src/exa-web-search-provider.ts',
    'extensions/exa/src/exa-web-search-provider.runtime.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/config/plugin-web-search-config.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/common.ts', 'src/infra/http-response-body.ts',
    'src/infra/http-response-body-timeout.ts', 'packages/normalization-core/src/response-bytes.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(digest(bytes), row.sourceSha256, row.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      row.executableSha256, row.path);
    assert.equal(row.wholeModule, true);
  }
  for (const row of capture.facades) assert.equal(digest(row.generatedCode), row.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) {
    assert.equal(digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.sha256);
  }
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-http-fixture'), row.id);
    for (const step of row.steps) assert.deepEqual(step.argumentsAfter, step.arguments);
  }
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('constructs the actual Exa provider and count100/content schema without inventing required fields', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'exa');
  assert.equal(row.providerMetadata.label, 'Exa Search');
  assert.deepEqual(Object.keys(row.descriptor.parameters.properties),
    ['query', 'count', 'freshness', 'date_after', 'date_before', 'type', 'contents']);
  assert.equal(row.descriptor.parameters.required, undefined);
  assert.equal(row.descriptor.parameters.additionalProperties, false);
  assert.equal(row.descriptor.parameters.properties.count.minimum, 1);
  assert.equal(row.descriptor.parameters.properties.count.maximum, 100);
  assert.deepEqual(row.descriptor.parameters.properties.type.enum,
    ['auto', 'neural', 'fast', 'deep', 'deep-reasoning', 'instant']);
  assert.equal(row.descriptor.parameters.properties.contents.additionalProperties, false);
});

test('sends exact default protocol and all six types while public normalization limits hundred results to ten', () => {
  const request = first('search-default').request;
  assert.equal(request.url, 'https://api.exa.ai/search');
  assert.equal(request.method, 'POST');
  assert.equal(request.timeoutSeconds, 30);
  assert.deepEqual(request.body, { query: 'search-default', numResults: 5, type: 'auto', contents: { highlights: true } });
  assert.deepEqual(request.headers, { Accept: 'application/json', 'Content-Type': 'application/json',
    'x-api-key': 'fixture-exa-key', 'x-exa-integration': 'openclaw' });
  for (const type of ['auto', 'neural', 'fast', 'deep', 'deep-reasoning', 'instant']) {
    assert.equal(first('type-' + type).request.body.type, type);
    assert.equal(first('type-' + type).request.body.query, 'type query');
  }
  const hundred = first('count-hundred');
  assert.equal(hundred.request.body.numResults, 100);
  assert.equal(hundred.providerResult.count, 100);
  assert.equal(hundred.publicResult.count, 10);
  assert.equal(hundred.publicResult.truncated, true);
  assert.equal(first('configured-count').request.body.numResults, 13);
  assert.equal(first('configured-count-string').request.body.numResults, 12);
});

test('normalizes ordinary endpoint paths and schemeless hosts while preserving query and removing fragment', () => {
  for (const id of ['path', 'path-trailing-slashes', 'search-path', 'schemeless']) {
    assert.equal(first('endpoint-' + id).request.url, 'https://proxy.example/exa/search');
  }
  assert.equal(first('endpoint-query-fragment').request.url,
    'https://proxy.example/exa/search?tenant=ordinary');
  assert.equal(first('endpoint-http').request.url, 'http://proxy.example/exa/search');
  assert.equal(first('endpoint-blank-default').request.url, 'https://api.exa.ai/search');
  assert.equal(first('endpoint-uppercase-default-port').request.url,
    'https://exa.example/proxy/search?ordinary=yes');
});

test('normalizes successful date aliases and UTC freshness with month clamp and leap-year rollover', () => {
  for (const id of ['bounded', 'after', 'before', 'same-day']) {
    const rows = group('dates-' + id).steps;
    assert.deepEqual(rows.map(row => row.cached), [false, true]);
    if (id !== 'before') assert.equal(rows[0].request.body.startPublishedDate, '2025-01-02');
    if (id !== 'after') assert.equal(rows[0].request.body.endPublishedDate,
      id === 'same-day' ? '2025-01-02' : '2025-01-31');
  }
  for (const [freshness, expected] of [
    ['day', '2026-10-26T12:00:00.000Z'], ['week', '2026-10-20T12:00:00.000Z'],
    ['month', '2026-09-27T12:00:00.000Z'], ['year', '2025-10-27T12:00:00.000Z'],
  ]) {
    const rows = group('freshness-' + freshness).steps;
    assert.equal(rows[0].request.body.startPublishedDate, expected);
    assert.deepEqual(rows.map(row => row.cached), [false, true]);
  }
  assert.equal(first('freshness-month-clamp').request.body.startPublishedDate, '2025-02-28T23:45:12.345Z');
  assert.equal(first('freshness-month-leap-clamp').request.body.startPublishedDate, '2024-02-29T23:45:12.345Z');
  assert.equal(first('freshness-year-leap-rollover').request.body.startPublishedDate, '2023-03-01T23:45:12.345Z');
});

test('preserves boolean and object content choices including nested query whitespace and canonical cache order', () => {
  assert.deepEqual(first('contents-empty-default').request.body.contents, { highlights: true });
  assert.deepEqual(first('contents-booleans').request.body.contents, { text: false, highlights: true, summary: false });
  assert.deepEqual(first('contents-text-object').request.body.contents, { text: { maxCharacters: 42 } });
  assert.deepEqual(first('contents-highlights-object').request.body.contents, { highlights: {
    maxCharacters: 51, query: '  exact highlights query \n', numSentences: 3, highlightsPerUrl: 2,
  } });
  assert.deepEqual(first('contents-summary-object').request.body.contents,
    { summary: { query: '  exact summary query \n' } });
  assert.deepEqual(first('contents-empty-objects').request.body.contents, { text: {}, highlights: {}, summary: {} });
  assert.deepEqual(group('contents-canonical-cache').steps.map(row => row.cached), [false, true]);
  assert.deepEqual(group('contents-default-cache').steps.map(row => row.cached), [false, true, true]);
});

test('retains exact provider prose and source metadata before the generic closed projection', () => {
  const row = first('result-fallbacks');
  const result = row.providerPortableResult;
  assert.equal(result.results[0].title, '  literal title 😀  ');
  assert.equal(row.providerUnwrappedResult.results[0].title, 'literal title 😀');
  assert.equal(result.results[0].description, 'first\nsecond\nfirst');
  assert.equal(result.results[0].summary, 'summary retained');
  assert.equal(result.results[0].siteName, 'www.source.example');
  assert.equal(result.results[0].published, ' 2025-02-03 ');
  assert.deepEqual(result.results[0].highlightScores, [0, 0.2, -0.5]);
  assert.deepEqual(result.results.map(item => item.description),
    ['first\nsecond\nfirst', 'Summary fallback', 'Text fallback', '', 'summary']);
  assert.equal(result.results[1].summary, 'Summary fallback');
  assert.equal(row.publicPortableResult.results[0].title, 'literal title 😀');
  assert.equal(row.publicPortableResult.results[0].summary, undefined);
  assert.equal(row.publicPortableResult.results[0].highlightScores, undefined);
  assert.deepEqual(first('result-records-before-slice').providerPortableResult.results.map(item => item.title), ['First', 'Second']);
});

test('uses actual shared cache for prepared query/type/count/content and caller-limited TTL', () => {
  assert.deepEqual(group('cache-count').steps.map(row => row.cached), [false, false, true]);
  assert.deepEqual(group('cache-types').steps.map(row => row.cached), [false, false, true]);
  const policy = group('cache-policy').steps;
  assert.deepEqual(policy.map(row => row.cached), [false, true, false, false, true, false, true]);
  assert.equal(policy[2].request.timeoutSeconds, 7);
  assert.equal(policy[4].providerResult.tookMs, policy[0].providerResult.tookMs);
  const query = group('query-whitespace-cache').steps;
  assert.deepEqual(query.map(row => row.cached), [false, true]);
  assert.equal(query[0].providerResult.query, 'ordinary query');
  assert.equal(query[0].publicResult.query, '  ordinary query \n');
  assert.equal(query[1].publicResult.query, 'ordinary query');
});

test('normalizer reserves all retained URLs before scalar-safe shared20000 UTF16 prose', () => {
  const emoji = normal('results-body-emoji');
  const urlUnits = emoji.results.reduce((sum, row) => sum + row.url.length, 0);
  assert.equal(emoji.results[0].title, '😀'.repeat(Math.floor((20_000 - urlUnits) / 2)));
  assert.equal(emoji.truncated, true);
  for (const id of ['results-body-emoji', 'results-body-combining', 'results-body-zwj']) {
    const result = normal(id);
    const proseUnits = result.results.reduce((sum, row) => sum + row.url.length + row.title.length +
      (row.snippet?.length ?? 0) + (row.siteName?.length ?? 0), 0);
    assert.ok(proseUnits <= 20_000);
    for (const row of result.results) assert.equal(row.title.isWellFormed(), true);
    assert.equal(result.results[1].url, 'https://source.example/second');
  }
  assert.equal(normal('results-short-unicode').results[0].title, '界😀e\u0301 👩‍💻');
  assert.equal(normal('results-eleven').count, 10);
  assert.equal(normal('results-eleven').truncated, true);
  assert.equal(normal('results-url-normalization').results[0].url,
    'https://source.example/ordinary?q=hello%20world');
});

test('runs Unicode budgets, URL canonicalization and eleven-row caps through actual successful Exa callbacks', () => {
  for (const id of ['emoji', 'combining', 'zwj']) {
    const step = first('callback-results-body-' + id);
    assert.ok(step.providerPortableResult.results[0].title.length > 20_000);
    assert.ok(step.providerPortableResult.results[0].description.length > 20_000);
    assert.equal(step.publicPortableResult.truncated, true);
    assert.equal(step.publicPortableResult.results[1].url, 'https://source.example/second');
    assert.equal(step.publicPortableResult.results[0].title.isWellFormed(), true);
  }
  assert.equal(first('callback-results-short-unicode').publicPortableResult.results[0].title, '界😀e\u0301 👩‍💻');
  const url = first('callback-results-url-normalization');
  assert.equal(url.providerPortableResult.results[0].siteName, 'source.example');
  assert.equal(url.publicPortableResult.results[0].url, 'https://source.example/ordinary?q=hello%20world');
  const eleven = first('callback-results-eleven');
  assert.equal(eleven.providerPortableResult.count, 11);
  assert.equal(eleven.publicPortableResult.count, 10);
  assert.equal(eleven.publicPortableResult.truncated, true);
});

test('fresh complete capture equals the frozen source fixture', () => {
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
  else assert.equal(capture.groups.length, 50);
});
