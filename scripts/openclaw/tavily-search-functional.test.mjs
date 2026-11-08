// Positive ordinary source oracle; no Synapsis runtime or live provider is imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureTavilySearch, portableSearchResult, unframeSearchText } from './capture-tavily-search.mjs';

const root = process.env.OPENCLAW_TAVILY_SEARCH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_TAVILY_SEARCH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/tavily-search.json', import.meta.url);
const capture = await captureTavilySearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => {
  const item = capture.groups.find(item => item.id === id);
  assert.ok(item, id);
  return item;
};
const first = id => group(id).steps[0];
const result = id => first(id).providerPortableResult;

test('executes complete unchanged plugin/factory/client/config/readers/cache/normalizer with exact provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.typebox.files.length, 372);
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  assert.equal(capture.boundaries.actualCommonPost, true);
  for (const path of ['extensions/tavily/index.ts', 'extensions/tavily/src/tavily-search-provider.ts',
    'extensions/tavily/src/tavily-client.ts', 'extensions/tavily/src/config.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/web-shared.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
    'src/config/plugin-web-search-config.ts', 'src/security/external-content.ts',
    'packages/normalization-core/src/utf16-slice.ts']) {
    assert.equal(capture.sources.find(item => item.path === path)?.executed, true, path);
  }
  for (const item of capture.sources) {
    const bytes = readFileSync(join(root, item.path));
    assert.equal(digest(bytes), item.sourceSha256, item.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      item.executableSha256, item.path);
    assert.equal(item.wholeModule, true);
  }
  for (const item of capture.facades) assert.equal(digest(item.generatedCode), item.sha256);
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-tavily-search.mjs', import.meta.url))));
  for (const item of capture.harnessDependencies) {
    assert.equal(digest(readFileSync(new URL('../../' + item.path, import.meta.url))), item.sha256);
  }
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const item of capture.typebox.files) {
    assert.equal(digest(readFileSync(join(typeboxRoot, item.path.slice('typebox/'.length)))), item.sha256);
  }
  assert.deepEqual(capture.counts, { executedWholeModules: 41, provenanceOnlyModules: 17,
    groups: 40, callbacks: 53, httpCallbacks: 46 });
});

test('actual registration constructs exact generic count20 and dedicated rich search schemas', () => {
  const registration = group('dedicated-default').registration;
  assert.equal(registration.pluginId, 'tavily');
  assert.deepEqual(registration.providers, [{ id: 'tavily', label: 'Tavily Search' }]);
  assert.deepEqual(registration.tools, [{ name: 'tavily_search' }, { name: 'tavily_extract' }]);
  const generic = group('generic-default').descriptor.parameters;
  assert.deepEqual(Object.keys(generic.properties), ['query', 'count']);
  assert.equal(generic.properties.count.maximum, 20);
  assert.equal(generic.additionalProperties, false);
  const dedicated = group('dedicated-default').descriptor;
  assert.equal(dedicated.name, 'tavily_search');
  assert.equal(dedicated.resultContentSource, 'network');
  assert.deepEqual(Object.keys(dedicated.parameters.properties), ['query', 'search_depth', 'topic',
    'max_results', 'include_answer', 'time_range', 'include_domains', 'exclude_domains']);
  assert.deepEqual(dedicated.parameters.required, ['query']);
  assert.equal(dedicated.parameters.properties.max_results.maximum, 20);
  assert.equal(dedicated.parameters.additionalProperties, false);
  assert.deepEqual(dedicated.parameters.properties.topic.enum, ['general', 'news', 'finance']);
});

test('actual common POST preserves endpoint prefixes and default protocol while source query contracts differ', () => {
  assert.deepEqual(first('generic-default').request.body, { query: ' ordinary Tavily query ', max_results: 5 });
  assert.deepEqual(first('dedicated-default').request.body, { query: 'ordinary Tavily query', max_results: 5 });
  assert.equal(first('endpoint-proxy').request.url, 'https://search.example/proxy/search');
  for (const surface of ['generic', 'dedicated']) {
    const request = first(`${surface}-configured-search-defaults`).request;
    assert.equal(request.body.max_results, 5);
    assert.equal(request.timeoutSeconds, 30);
  }
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    const http = row.audit.filter(item => item.kind === 'successful-http-fixture');
    const parsers = row.audit.filter(item => item.kind === 'successful-json-fixture');
    assert.equal(http.length, row.steps.at(-1).cumulativeRequests);
    assert.equal(parsers.length, http.length);
    for (const parser of parsers) assert.deepEqual(parser,
      { kind: 'successful-json-fixture', errorLabel: 'Tavily Search', options: {} });
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.deepEqual(step.configAfter, step.configBefore);
      assert.equal(step.providerResult.tookMs, 7);
      if (step.request === null) continue;
      assert.equal(step.request.method, 'POST');
      assert.deepEqual(step.request.query, {});
      assert.equal(step.request.bodyText, JSON.stringify(step.request.body));
      assert.deepEqual(step.request.headers, { accept: 'application/json', authorization: 'Bearer fixture-tavily-key',
        'content-type': 'application/json', 'x-client-source': 'openclaw' });
    }
  }
});

test('dedicated readers forward depth/topic/time/domain/answer knobs and omit empty accepted options', () => {
  assert.deepEqual(first('dedicated-full-options').request.body, { query: 'full options', max_results: 20,
    search_depth: 'advanced', topic: 'news', include_answer: true, time_range: 'week',
    include_domains: ['source.example', 'docs.example'], exclude_domains: ['archive.example'] });
  for (const depth of ['basic', 'advanced']) assert.equal(first(`depth-${depth}`).request.body.search_depth, depth);
  for (const topic of ['general', 'news', 'finance']) assert.equal(first(`topic-${topic}`).request.body.topic, topic);
  for (const time of ['day', 'week', 'month', 'year']) assert.equal(first(`time-${time}`).request.body.time_range, time);
  assert.equal(first('answer-true').request.body.include_answer, true);
  assert.equal(Object.hasOwn(first('answer-false').request.body, 'include_answer'), false);
  assert.deepEqual(first('dedicated-empty-options').request.body, { query: 'empty options', max_results: 5 });
  assert.equal(first('dedicated-scientific-count').request.body.max_results, 2);
  assert.equal(first('generic-scientific-count').request.body.max_results, 2);
});

test('complete ISO suffixes and exact RFC news dates survive with ordinary canonical URLs', () => {
  const rows = result('result-full-dates').results;
  assert.deepEqual(rows.map(row => row.published), ['2025-01-02T03:04:05.000Z',
    '2026-02-03T04:05:06.789Z', '2026-03-04 05:06:07+00:00', '2026-04-05', undefined, undefined]);
  assert.deepEqual(rows[4], { title: '', url: 'https://bare.example', snippet: '', score: 0 });
  assert.deepEqual(rows[5], { title: ' Canonical title ',
    url: 'https://source.example/ordinary%20path?q=hello%20world#section', snippet: ' Canonical snippet ' });
  assert.equal(first('result-full-dates').publicPortableResult.results[4].url, 'https://bare.example/');
  assert.equal(first('result-full-dates').publicPortableResult.results[0].published, rows[0].published);
});

test('source slices first count and keeps dedicated twenty rows separate from generic public ten rows', () => {
  for (const surface of ['generic', 'dedicated']) {
    const step = first(`${surface}-twenty`);
    assert.equal(step.request.body.max_results, 20);
    assert.equal(step.providerResult.count, 20);
    assert.equal(step.providerResult.truncated, true);
    assert.equal(step.publicResult.count, 10);
    assert.equal(step.publicResult.truncated, true);
    assert.deepEqual(step.providerPortableResult.results.map(row => row.title),
      Array.from({ length: 20 }, (_, n) => `Source ${n + 1}`));
  }
  assert.deepEqual(result('result-first-count').results.map(row => row.title), ['Source 1', 'Source 2']);
  assert.equal(result('result-first-count').truncated, true);
  for (const row of capture.groups) for (const step of row.steps) {
    if (row.surface === 'dedicated') {
      assert.deepEqual(step.toolResult.details, step.providerResult);
      assert.deepEqual(step.toolResult.content, [{ type: 'text', text: JSON.stringify(step.providerResult, null, 2) }]);
    } else assert.equal(step.toolResult, null);
  }
});

test('answer presence follows actual provider payload while generic normalization keeps its closed result branch', () => {
  assert.equal(result('answer-true').answer, ' Answer enabled ');
  assert.equal(result('answer-false').answer, undefined);
  assert.equal(result('answer-returned-without-optin').answer, ' Ordinary provider answer ');
  assert.deepEqual(result('result-empty-success').results, []);
  assert.equal(result('result-empty-success').answer, ' Answer without result rows ');
  assert.equal(first('answer-true').publicPortableResult.answer, undefined);
  assert.equal(first('answer-true').publicPortableResult.kind, 'results');
});

test('portable comparison removes exact frames and top-level stamp while preserving provider whitespace and all other keys', () => {
  for (const row of capture.groups) for (const step of row.steps) {
    const expected = structuredClone(step.providerResult);
    expected.results = expected.results.map(row => ({ ...row,
      title: unframeSearchText(row.title), snippet: unframeSearchText(row.snippet) }));
    if (typeof expected.answer === 'string') expected.answer = unframeSearchText(expected.answer);
    assert.deepEqual(step.providerUnframedResult, expected);
    delete expected.externalContent;
    assert.deepEqual(step.providerPortableResult, expected);
    assert.deepEqual(portableSearchResult({ ...step.providerUnframedResult, ordinaryExtra: 'kept' }),
      { ...expected, ordinaryExtra: 'kept' });
  }
  const unicode = result('result-unicode-whitespace');
  assert.equal(unicode.results[0].title, ' \t標題😀e\u0301 👩‍💻 \n');
  assert.equal(unicode.results[0].snippet, ' \t本文界😀 \n');
  assert.equal(unicode.answer, ' \tAnswer 界😀e\u0301 👩‍💻 \n');
});

test('shared provider UTF16 budget spends title/snippet rows before answer and public normalization reserves URLs first', () => {
  for (const id of ['emoji', 'combining', 'zwj']) for (const surface of ['generic', 'dedicated']) {
    const step = first(`${surface}-budget-${id}`), provider = step.providerPortableResult;
    assert.equal(provider.truncated, true);
    assert.ok(provider.results.reduce((sum, row) => sum + row.title.length + row.snippet.length, 0)
      + provider.answer.length <= 20_000);
    for (const row of provider.results) {
      assert.equal(row.title.isWellFormed(), true);
      assert.equal(row.snippet.isWellFormed(), true);
    }
    assert.equal(provider.answer.isWellFormed(), true);
    const generic = step.publicPortableResult;
    assert.ok(generic.results.reduce((sum, row) => sum + row.url.length + row.title.length + row.snippet.length, 0) <= 20_000);
    assert.equal(generic.results[1].url, 'https://source.example/2');
  }
  const ordered = result('budget-answer-after-rows');
  assert.equal(ordered.results[0].title, 'T'.repeat(8_000));
  assert.equal(ordered.results[0].snippet, 'S'.repeat(8_000));
  assert.equal(ordered.results[1].title, 'U'.repeat(1_000));
  assert.equal(ordered.results[1].snippet, 'V'.repeat(1_000));
  assert.equal(ordered.answer, 'A'.repeat(2_000));
  assert.equal(ordered.truncated, true);
  const generic = first('generic-budget-emoji').publicPortableResult;
  const reserved = generic.results.reduce((sum, row) => sum + row.url.length, 0);
  assert.equal(generic.results[0].title, '😀'.repeat(Math.floor((20_000 - reserved) / 2)));
});

test('real shared cache preserves count/options/current config and caller TTL interactions without credential variants', () => {
  for (const [id, expected] of [
    ['cache-repeat-dedicated', [false, true]], ['cache-repeat-generic', [false, true, false]],
    ['cache-count', [false, false, true]], ['cache-options', [false, false, false, true]],
    ['cache-current-config', [false, false, true]], ['cache-caller-settings', [false, true, false, true]],
  ]) assert.deepEqual(group(id).steps.map(step => step.cached), expected, id);
  const current = group('cache-current-config').steps;
  assert.equal(current[0].request.url, 'https://api.tavily.com/search');
  assert.equal(current[1].request.url, 'https://proxy.example/tavily/search');
  assert.equal(current[2].request, null);
  const dedicated = group('cache-repeat-dedicated').steps;
  assert.deepEqual(dedicated[1].providerResult, { ...dedicated[0].providerResult, cached: true });
  const generic = group('cache-repeat-generic').steps;
  assert.equal(generic[0].request.body.query, ' authored query ');
  assert.equal(generic[2].request.body.query, 'authored query');
});

test('fresh complete source capture equals the frozen fixture exactly', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});
