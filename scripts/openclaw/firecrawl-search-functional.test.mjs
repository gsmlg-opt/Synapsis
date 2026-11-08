// Ordinary successful search contracts observed through unchanged pinned modules.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureFirecrawlSearch, portableSearchResult, unframeSearchText } from './capture-firecrawl-search.mjs';

const root = process.env.OPENCLAW_FIRECRAWL_SEARCH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_FIRECRAWL_SEARCH_FIXTURE;
const capture = await captureFirecrawlSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => {
  const result = capture.groups.find(item => item.id === id);
  assert.ok(result, id);
  return result;
};
const first = id => group(id).steps[0];
const result = id => first(id).providerPortableResult;

test('executes unchanged whole search factory/client/config/readers/wrappers/normalizer with exact provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.boundaries.fullSourceModules, true);
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  for (const path of [
    'extensions/firecrawl/index.ts', 'extensions/firecrawl/src/firecrawl-search-provider.ts',
    'extensions/firecrawl/src/firecrawl-client.ts', 'src/agents/tools/web-search-output.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/config/plugin-web-search-config.ts',
    'src/plugin-sdk/plugin-config-runtime.ts', 'src/security/external-content.ts',
    'packages/normalization-core/src/number-coercion.ts',
    'packages/normalization-core/src/record-coerce.ts',
  ]) assert.equal(capture.sources.find(item => item.path === path)?.executed, true, path);
  for (const source of capture.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(digest(bytes), source.sourceSha256, source.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      source.executableSha256, source.path);
    assert.equal(source.wholeModule, true);
  }
  for (const facade of capture.facades) assert.equal(digest(facade.generatedCode), facade.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const item of capture.typebox.files) {
    assert.equal(digest(readFileSync(join(typeboxRoot, item.path.slice('typebox/'.length)))), item.sha256);
  }
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(item => item.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(item => !item.executed).length);
  assert.equal(capture.counts.groups, 41);
  assert.equal(capture.counts.callbacks, 47);
  assert.equal(capture.counts.httpCallbacks, 43);
});

test('actual registration constructs paid/free generic providers and the dedicated count100 schema', () => {
  const registration = group('dedicated-default').registration;
  assert.equal(registration.pluginId, 'firecrawl');
  assert.deepEqual(registration.providers, [{ id: 'firecrawl', label: 'Firecrawl Search' },
    { id: 'firecrawl-free', label: 'Firecrawl Search (Free)' }]);
  assert.deepEqual(registration.tools, [{ name: 'firecrawl_search' }, { name: 'firecrawl_scrape' }]);
  const generic = group('generic-paid-default').descriptor.parameters;
  assert.deepEqual(Object.keys(generic.properties), ['query', 'count']);
  assert.equal(generic.properties.count.maximum, 10);
  assert.equal(generic.additionalProperties, false);
  assert.deepEqual(group('generic-free-default').descriptor.parameters, generic);
  const dedicated = group('dedicated-default').descriptor;
  assert.equal(dedicated.name, 'firecrawl_search');
  assert.equal(dedicated.resultContentSource, 'network');
  assert.deepEqual(Object.keys(dedicated.parameters.properties), ['query', 'count', 'sources', 'categories',
    'includeDomains', 'excludeDomains', 'tbs', 'location', 'country', 'scrapeResults', 'timeoutSeconds']);
  assert.deepEqual(dedicated.parameters.required, ['query']);
  assert.equal(dedicated.parameters.properties.count.maximum, 100);
  assert.equal(dedicated.parameters.additionalProperties, false);
});

test('whole client sends exact ordinary POST defaults and each surface retains its query contract', () => {
  for (const surface of ['generic-paid', 'generic-free']) {
    const step = first(`${surface}-default`);
    assert.deepEqual(step.request.body, { query: ' ordinary generic search ', limit: 5 });
    assert.equal(step.providerResult.query, step.arguments.query);
    assert.equal(step.publicPortableResult.query, step.arguments.query);
    assert.deepEqual(first(`${surface}-configured-search-policy`).request.body,
      { query: 'configured source defaults', limit: 5 });
    assert.equal(first(`${surface}-configured-search-policy`).request.timeoutSeconds, 30);
  }
  assert.deepEqual(first('dedicated-default').request.body, { query: 'ordinary dedicated search', limit: 5 });
  assert.equal(result('dedicated-default').query, 'ordinary dedicated search');
  for (const row of capture.groups) {
    assert.deepEqual(row.configAfter, row.config);
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments, row.id);
      if (step.request === null) continue;
      assert.equal(step.request.url, 'https://api.firecrawl.dev/v2/search');
      assert.equal(step.request.path, '/v2/search');
      assert.equal(step.request.method, 'POST');
      assert.deepEqual(step.request.query, {});
      assert.equal(step.request.bodyText, JSON.stringify(step.request.body));
      assert.deepEqual(step.request.headers, row.provider === 'firecrawl-free'
        ? { 'Content-Type': 'application/json' }
        : { 'Content-Type': 'application/json', Authorization: 'Bearer fixture-firecrawl-key' });
    }
  }
});

test('actual dedicated readers trim all normal knobs, omit empty options and preserve include OR exclude', () => {
  const include = first('dedicated-full-include').request;
  assert.deepEqual(include.body, { query: 'full include query', limit: 8,
    sources: ['web', 'news', 'images'], categories: ['github', 'research'],
    includeDomains: ['source.example', 'docs.example'], tbs: 'qdr:w',
    location: 'San Francisco,California,United States', country: 'US',
    scrapeOptions: { formats: ['markdown'] } });
  assert.equal(include.timeoutSeconds, 7);
  assert.deepEqual(first('dedicated-full-exclude').request.body, { query: 'full exclude query', limit: 2,
    sources: ['news'], categories: ['research'], excludeDomains: ['archive.example', 'old.example'],
    tbs: 'sbd:1', location: 'Germany', country: 'DE' });
  assert.equal(first('dedicated-full-exclude').request.timeoutSeconds, 11);
  assert.deepEqual(first('dedicated-empty-options').request.body, { query: 'empty options', limit: 5 });
  assert.deepEqual(first('dedicated-snake-case-readers').request.body, { query: 'snake case', limit: 5,
    sources: ['web'], categories: ['research'], includeDomains: ['source.example'], tbs: 'qdr:d',
    country: 'JP', scrapeOptions: { formats: ['markdown'] } });
  assert.equal(first('dedicated-snake-case-readers').request.timeoutSeconds, 4);
  assert.deepEqual(first('dedicated-scientific-count-timeout').request.body,
    { query: 'ordinary numeric tokens', limit: 2 });
  assert.equal(first('dedicated-scientific-count-timeout').request.timeoutSeconds, 3);
});

test('all normal response envelopes retain deterministic precedence and web/news/images order', () => {
  for (const id of ['data-array', 'results-array', 'nested-results', 'nested-data', 'legacy-web',
    'data-precedence', 'results-precedence', 'nested-results-precedence', 'nested-data-precedence']) {
    assert.deepEqual(result(`envelope-${id}`).results.map(row => row.title), ['Source 1', 'Source 2'], id);
  }
  assert.deepEqual(result('envelope-sources').results.map(row => row.title),
    ['Source web', 'Source news', 'Source images']);
  assert.deepEqual(result('envelope-empty-sources').results, []);
  assert.deepEqual(result('envelope-empty-data-precedence').results, []);
});

test('empty optional fields fall through to sourceURL/metadata/snippet/content with complete valid timestamps', () => {
  const rows = result('result-empty-field-fallbacks').results;
  assert.deepEqual(rows[0], { title: ' Metadata title 😀 ', url: 'https://www.fallback.example/first',
    description: ' Snippet 😀 ', content: ' Content fallback \n',
    published: '2026-01-02T03:04:05.678Z', siteName: 'fallback.example' });
  assert.deepEqual(rows[1], { title: 'Second', url: 'https://source.example/second',
    description: 'Summary fallback', content: 'Text fallback',
    published: '2026-02-03 04:05:06+00:00', siteName: 'source.example' });
  assert.deepEqual(rows[2], { title: 'Third metadata', url: 'https://www.metadata.example/third',
    description: '', published: '2026-03-04T05:06:07Z', siteName: 'metadata.example' });
  assert.equal(rows[3].published, '2026-04-05');
  assert.equal(rows[4].url, 'https://bare.example');
  assert.equal(rows[5].url, 'https://source.example/ordinary%20path?q=hello%20world#section');
  assert.equal(first('result-empty-field-fallbacks').publicPortableResult.results[4].url, 'https://bare.example/');
  assert.equal(result('result-content-disabled').results.some(row => Object.hasOwn(row, 'content')), false);
  const publicRows = first('result-empty-field-fallbacks').publicPortableResult.results;
  assert.equal(publicRows[0].title, 'Metadata title 😀');
  assert.equal(publicRows[0].snippet, 'Snippet 😀');
  assert.equal(publicRows[0].published, '2026-01-02T03:04:05.678Z');
  assert.equal(publicRows[1].published, '2026-02-03 04:05:06+00:00');
});

test('provider count100 and dedicated payload stay distinct from the closed generic ten-row projection', () => {
  assert.equal(first('generic-paid-ten').request.body.limit, 10);
  assert.equal(result('generic-paid-ten').count, 10);
  assert.equal(first('generic-free-ten').request.body.limit, 10);
  const hundred = first('dedicated-count-hundred');
  assert.equal(hundred.request.body.limit, 100);
  assert.equal(hundred.providerResult.count, 100);
  assert.equal(hundred.publicResult.count, 10);
  assert.equal(hundred.publicResult.truncated, true);
  assert.equal(first('dedicated-count-twelve').providerResult.count, 12);
  assert.equal(first('dedicated-count-twelve').publicResult.count, 10);
  for (const group of capture.groups) for (const step of group.steps) {
    if (group.surface === 'dedicated') {
      assert.deepEqual(step.toolResult.details, step.providerResult);
      assert.deepEqual(step.toolResult.content, [{ type: 'text', text: JSON.stringify(step.providerResult, null, 2) }]);
    } else assert.equal(step.toolResult, null);
  }
});

test('explicit unframing preserves provider Unicode/whitespace and removes only reference metadata', () => {
  for (const group of capture.groups) for (const step of group.steps) {
    const expected = structuredClone(step.providerResult);
    expected.results = expected.results.map(row => Object.fromEntries(Object.entries(row).map(([key, value]) =>
      [key, ['title', 'description', 'content', 'siteName'].includes(key) && typeof value === 'string'
        ? unframeSearchText(value) : value])));
    assert.deepEqual(step.providerUnframedResult, expected);
    delete expected.externalContent;
    assert.deepEqual(step.providerPortableResult, expected);
    assert.deepEqual(portableSearchResult({ ...step.providerUnframedResult, ordinaryExtra: 'retained' }),
      { ...expected, ordinaryExtra: 'retained' });
  }
  const unicode = result('result-unicode-whitespace').results[0];
  assert.equal(unicode.title, ' \t標題😀e\u0301 👩‍💻 \n');
  assert.equal(unicode.description, ' \t本文界😀 \n');
  assert.equal(unicode.content, ' \t# Literal Markdown 😀\n ');
});

test('actual provider and generic UTF16 budgets retain full scalars with distinct allocation order', () => {
  for (const id of ['emoji', 'combining', 'zwj']) for (const surface of ['dedicated', 'generic-paid']) {
    const step = first(`${surface}-budget-${id}`);
    const provider = step.providerPortableResult;
    assert.equal(provider.truncated, true);
    assert.equal(provider.results[1].url, 'https://www.source.example/2');
    assert.ok(provider.results.reduce((sum, row) => sum + row.title.length + row.description.length
      + (row.content?.length ?? 0), 0) <= 20_000);
    for (const row of provider.results) for (const key of ['title', 'description', 'content']) {
      if (typeof row[key] === 'string') assert.equal(row[key].isWellFormed(), true);
    }
    const generic = step.publicPortableResult;
    assert.equal(generic.truncated, true);
    assert.ok(generic.results.reduce((sum, row) => sum + row.url.length + row.title.length
      + (row.snippet?.length ?? 0) + (row.siteName?.length ?? 0), 0) <= 20_000);
    assert.equal(generic.results[1].url, provider.results[1].url);
  }
  const provider = result('dedicated-budget-order');
  assert.equal(provider.results[0].title, 'T'.repeat(10_000));
  assert.equal(provider.results[0].description, 'D'.repeat(8_000));
  assert.equal(provider.results[0].content, 'C'.repeat(2_000));
  assert.equal(provider.results[1].title, '');
  assert.equal(provider.truncated, true);
  assert.equal(result('dedicated-budget-emoji').results[0].title, '😀'.repeat(10_000));
  const generic = first('generic-paid-budget-emoji').publicPortableResult;
  const reservedUrls = generic.results.reduce((sum, row) => sum + row.url.length, 0);
  assert.equal(generic.results[0].title, '😀'.repeat(Math.floor((20_000 - reservedUrls) / 2)));
});

test('actual shared cache canonicalizes ordinary reader output and excludes per-call timeout', () => {
  const normalized = group('dedicated-cache-normalized-options').steps;
  assert.deepEqual(normalized.map(step => step.cached), [false, true]);
  assert.equal(normalized[0].request.timeoutSeconds, 7);
  assert.equal(normalized[1].request, null);
  assert.deepEqual(normalized[1].providerResult, { ...normalized[0].providerResult, cached: true });
  assert.deepEqual(group('dedicated-cache-count-options').steps.map(step => step.cached), [false, false, true, false]);
  for (const surface of ['generic-paid', 'generic-free']) {
    assert.deepEqual(group(`${surface}-cache`).steps.map(step => step.cached), [false, true]);
  }
});

test('fresh complete capture equals frozen source fixture when supplied', () => {
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
  else assert.equal(capture.groups.length, 41);
});
