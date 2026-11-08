// Independent complete ordinary expectations; platform services are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureSearxngSearch, unframeSearxngSearchText } from './capture-searxng-search.mjs';

const root = process.env.OPENCLAW_SEARXNG_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_SEARXNG_FIXTURE
  ?? fileURLToPath(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/searxng-search.json', import.meta.url));
const capture = await captureSearxngSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => { const row = capture.groups.find(item => item.id === id); assert.ok(row, id); return row; };
const first = id => group(id).steps[0];
const stamp = { untrusted: true, source: 'web_search', provider: 'searxng', wrapped: true };
const frame = text => '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n'
  + text + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
const hits = new Map([
  ['same-query-repeated', [false, true]], ['query-case-identity', [false, false, true]],
  ['query-interior-space-identity', [false, false, true]], ['count-identity', [false, false, true]],
  ['base-identity', [false, false, true]], ['base-case-identity', [false, false, true]],
  ['base-query-identity', [false, false, true]], ['base-normalized-equivalence', [false, true]],
  ['categories-identity', [false, false, true]], ['language-identity', [false, false, true]],
  ['cache-off', [false, false]], ['cache-off-on', [false, false, true]], ['cache-on-off-on', [false, false, true]],
]);
const ordinaryResults = [
  { title: ' First ordinary title ', url: 'https://docs.example/one', snippet: ' First ordinary snippet. ',
    siteName: 'docs.example', img_src: 'https://images.example/one.png' },
  { title: 'Second ordinary title', url: 'https://news.example/two', snippet: 'Second ordinary snippet.', siteName: 'news.example' },
];
const optionalResults = [
  { title: 'Image source', url: 'https://images.example/item', snippet: '', siteName: 'images.example', img_src: 'https://images.example/thumb.png' },
  { title: 'Text source', url: 'https://docs.example/two', snippet: 'Ordinary text.', siteName: 'docs.example' },
];
const emptyGroups = new Set(['empty-general-no-retry', 'empty-includes-general-no-retry', 'empty-unspecified-no-retry']);
const endpointPaths = new Map([
  ['base-prefix', '/meta/v2/search'], ['base-already-search', '/meta/search'],
  ['base-trailing-slashes', '/meta/search'], ['base-query-reset', '/meta/search'],
]);
function expectedOptions(id, n) {
  if (id === 'configured-options') return { categories: 'news,science', language: 'de' };
  if (id === 'argument-options') return { categories: 'science,news', language: 'fr' };
  if (id === 'categories-identity') return { categories: n === 1 ? 'science' : 'news' };
  if (id === 'language-identity') return { language: n === 1 ? 'de' : 'en' };
  if (id === 'empty-category-general-retry') return { categories: 'news,science' };
  if (id === 'empty-general-no-retry') return { categories: 'general' };
  if (id === 'empty-includes-general-no-retry') return { categories: 'news, General' };
  return {};
}
function expectedRequests(row, item, n) {
  if ((hits.get(row.id) ?? [false])[n]) return [];
  let path = endpointPaths.get(row.id) ?? '/search';
  if (row.id === 'base-identity' && n === 1) path = '/meta/search';
  if (row.id === 'base-case-identity') path = n === 1 ? '/meta/search' : '/Meta/search';
  const options = expectedOptions(row.id, n);
  const categories = row.id === 'empty-category-general-retry' ? [options.categories, 'general'] : [options.categories];
  return categories.map(category => {
    const query = { q: item.arguments.query.trim(), format: 'json',
      ...(category ? { categories: category } : {}), ...(options.language ? { language: options.language } : {}) };
    return { url: 'https://search.example' + path + '?' + new URLSearchParams(query), method: 'GET', path, query,
      headers: { accept: 'application/json' }, timeoutSeconds: row.id === 'configured-timeout' ? 9 : 20,
      signalSupplied: false };
  });
}
function expectedProvider(row, item, n) {
  const results = emptyGroups.has(row.id) ? [] : row.id === 'ordered-optional-content' ? optionalResults : ordinaryResults;
  return { query: item.arguments.query.trim(), provider: 'searxng', count: results.length,
    tookMs: row.id === 'empty-category-general-retry' ? 14 : 7,
    results: results.map(value => ({ ...value })), ...((hits.get(row.id) ?? [false])[n] ? { cached: true } : {}) };
}

test('verifies all pinned blobs, unchanged module bodies, every facade/deferred provenance, TypeBox and license', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of ['extensions/searxng/web-search-provider.ts',
    'extensions/searxng/src/searxng-search-provider.ts', 'extensions/searxng/src/searxng-client.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/web-shared.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-web-search-contract-fields.ts',
    'src/plugin-sdk/provider-web-search-config-contract.ts', 'src/plugin-sdk/provider-web-search-schema.ts',
    'src/plugin-sdk/provider-enable-config.ts', 'src/config/plugins-allowlist.ts',
    'src/config/plugin-web-search-config.ts', 'src/config/web-search-legacy-provider-keys.ts',
    'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts', 'src/security/external-content.ts',
    'src/utils/normalize-secret-input.ts']) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const path of ['src/plugin-sdk/secret-ref-readonly.ts', 'src/config/types.secrets.ts',
    'src/agents/tools/web-guarded-fetch.ts', 'src/infra/net/ssrf.ts', 'src/agents/provider-http-errors.ts',
    'src/infra/fs-safe.ts', 'packages/media-core/src/mime.ts', 'src/web-search/runtime-error.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, false, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256, digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true);
  }
  for (const row of capture.facades) {
    assert.equal(row.sha256, digest(row.generatedCode));
    assert.ok(capture.sources.some(source => source.path === row.provenance), row.provenance);
    for (const match of row.generatedCode.matchAll(/capture:source:([^";]+)/g)) {
      assert.equal(capture.sources.find(source => source.path === match[1])?.executed, true, match[1]);
    }
  }
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.match(capture.license.text, /MIT License/);
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-searxng-search.mjs', import.meta.url))));
  assert.equal(capture.harnessDependencies[0].sha256, digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))));
  assert.equal(capture.typebox.version, '1.3.37'); assert.equal(capture.typebox.files.length, 372);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('audits only successful explicit literal/platform fixtures with excluded services unexecuted', () => {
  for (const key of ['fullSourceModules', 'publicEntrypointInvoked', 'factoryInvoked', 'publicCallbackInvoked',
    'actualLazyClient', 'actualProviderRequestBuilder', 'actualBaseUrlHelper', 'actualCountReaders',
    'actualConfigReaders', 'actualSourceCache', 'genericNormalizerInvoked', 'actualUnwrapInvoked', 'actualTypeBox']) {
    assert.equal(capture.boundaries[key], true, key);
  }
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'actualEndpointClassifiers', 'actualEndpointPolicy',
    'actualCredentialResolution', 'actualDeadline', 'productionNetworkInvoked', 'pluginRegistrationInvoked', 'hostInstalled']) {
    assert.equal(capture.boundaries[key], false, key);
  }
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const name of ['resolveReadOnlyEnvSecretRef', 'isBlockedHostnameOrIp', 'resolvePinnedHostnameWithPolicy',
    'isPrivateIpAddress', 'withTrustedWebSearchEndpoint', 'readResponseText']) assert.ok(capture.stubs.some(row =>
    row.export === name && row.kind === 'ordinary-platform-fixture'), name);
  for (const row of capture.groups) {
    assert.deepEqual(row.setupAfter, row.setup, row.id);
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import'
      && item.importer === 'extensions/searxng/src/searxng-search-provider.ts' && item.specifier === './searxng-client.js'), row.id);
    for (const kind of ['configured-literal-base-fixture', 'fixed-hostname-classification',
      'synthetic-public-address', 'fixed-address-classification']) assert.equal(
      row.audit.filter(item => item.kind === kind).length, row.steps.length, row.id);
    const requestCount = row.steps.reduce((n, item) => n + item.requests.length, 0);
    assert.equal(row.audit.filter(item => item.kind === 'successful-http-fixture').length, requestCount, row.id);
    assert.deepEqual(row.audit.filter(item => item.kind === 'successful-short-text-fixture'),
      Array.from({ length: requestCount }, () => ({ kind: 'successful-short-text-fixture', maxBytes: 1_000_000 })), row.id);
    assert.deepEqual(row.audit.filter(item => item.kind === 'configured-literal-base-fixture'), row.steps.map(item => ({
      kind: 'configured-literal-base-fixture', value: item.setup.config.plugins.entries.searxng.config.webSearch.baseUrl,
      path: 'plugins.entries.searxng.config.webSearch.baseUrl', expectedEnvId: 'SEARXNG_BASE_URL',
    })), row.id);
  }
});

test('constructs exact provider metadata and actual query/count/categories/language schema', () => {
  const metadata = { id: 'searxng', label: 'SearXNG Search', hint: 'Self-hosted meta-search with no API key required',
    onboardingScopes: ['text-inference'], requiresCredential: true, credentialLabel: 'SearXNG Base URL',
    envVars: ['SEARXNG_BASE_URL'], placeholder: 'http://localhost:8080', signupUrl: 'https://docs.searxng.org/',
    autoDetectOrder: 200, credentialPath: 'plugins.entries.searxng.config.webSearch.baseUrl',
    credentialNote: 'For the SearXNG JSON API to work, make sure your SearXNG instance\nhas the json format enabled in its settings.yml under search.formats.',
    inactiveSecretPaths: ['plugins.entries.searxng.config.webSearch.baseUrl'] };
  const descriptor = { description: 'Search the web using a self-hosted SearXNG instance. Returns titles, URLs, and snippets.',
    parameters: { type: 'object', properties: {
      query: { type: 'string', description: 'Search query string.' },
      count: { type: 'integer', description: 'Number of results to return (1-10).', minimum: 1, maximum: 10 },
      categories: { type: 'string', description: 'Optional comma-separated search categories such as general, news, or science.' },
      language: { type: 'string', description: 'Optional language code for results such as en, de, or fr.' },
    }, additionalProperties: false } };
  for (const row of capture.groups) { assert.deepEqual(row.providerMetadata, metadata, row.id); assert.deepEqual(row.descriptor, descriptor, row.id); }
});

test('checks every complete GET map, configured path/search reset, ordinary options/count/time and source cache identity', () => {
  for (const row of capture.groups) {
    let cumulative = 0;
    for (const [n, item] of row.steps.entries()) {
      const requests = expectedRequests(row, item, n); cumulative += requests.length;
      assert.deepEqual(item.argumentsAfter, item.arguments, row.id);
      assert.deepEqual(item.setupAfter, item.setup, row.id);
      assert.deepEqual(item.requests, requests, row.id);
      assert.deepEqual(item.request, requests[0] ?? null, row.id);
      assert.equal(item.cumulativeRequests, cumulative, row.id);
      assert.equal(item.cacheHit, (hits.get(row.id) ?? [false])[n], row.id);
      assert.equal(item.clockAfter, new Date(Date.parse(item.clock) + requests.length * 7).toISOString(), row.id);
    }
  }
  assert.equal(first('search-default').arguments.count, undefined);
  assert.equal(first('search-default').setup.config.tools.web.search.maxResults, undefined);
  assert.equal(first('explicit-count').arguments.count, 3);
  assert.equal(first('numeric-count-token').arguments.count, ' 4 ');
  assert.equal(first('configured-count').setup.config.tools.web.search.maxResults, 2);
  assert.equal(first('configured-timeout').request.timeoutSeconds, 9);
  assert.deepEqual(first('context-search-options-ignored').setup.searchConfig, { maxResults: 3, timeoutSeconds: 9, cacheTtlMinutes: 0 });
  assert.equal(first('context-search-options-ignored').request.timeoutSeconds, 20);
  assert.equal(group('base-query-identity').steps[0].request.url, group('base-query-identity').steps[1].request.url);
  assert.notEqual(group('base-query-identity').steps[0].setup.config.plugins.entries.searxng.config.webSearch.baseUrl,
    group('base-query-identity').steps[1].setup.config.plugins.entries.searxng.config.webSearch.baseUrl);
  assert.equal(first('base-query-reset').request.query.old, undefined);
  for (const row of capture.groups) for (const item of row.steps) for (const request of item.requests) {
    assert.equal(Object.hasOwn(request.query, 'count'), false, row.id);
  }
});

test('checks independent full provider framed/unwrapped/portable and generic framed/unwrapped/portable maps', () => {
  for (const row of capture.groups) for (const [n, item] of row.steps.entries()) {
    const provider = expectedProvider(row, item, n);
    const providerFramed = { ...provider, externalContent: stamp, results: provider.results.map(result => ({ ...result,
      title: frame(result.title), snippet: result.snippet ? frame(result.snippet) : '' })) };
    const providerUnwrapped = { ...provider, externalContent: stamp, results: provider.results.map(result => ({ ...result,
      title: result.title.trim(), snippet: result.snippet.trim() })) };
    const generic = { kind: 'results', provider: 'searxng', query: item.arguments.query, count: provider.count,
      tookMs: provider.tookMs, results: provider.results.map(result => ({ title: result.title.trim(), url: result.url,
        snippet: result.snippet.trim(), siteName: result.siteName })), ...(provider.cached ? { cached: true } : {}) };
    const genericFramed = { ...generic, externalContent: stamp, results: generic.results.map(result => ({ ...result,
      title: frame(result.title), snippet: result.snippet ? frame(result.snippet) : '', siteName: frame(result.siteName) })) };
    const genericUnwrapped = { ...generic, externalContent: stamp };
    assert.deepEqual(item.providerPortableResult, provider, row.id);
    assert.deepEqual(item.providerResult, providerFramed, row.id);
    assert.deepEqual(item.providerUnwrappedResult, providerUnwrapped, row.id);
    assert.deepEqual(item.genericPortableResult, generic, row.id);
    assert.deepEqual(item.genericResult, genericFramed, row.id);
    assert.deepEqual(item.genericUnwrappedResult, genericUnwrapped, row.id);
    assert.deepEqual(item.publicResult, genericFramed, row.id);
    assert.deepEqual(item.publicUnwrappedResult, genericUnwrapped, row.id);
    assert.deepEqual(item.publicPortableResult, generic, row.id);
    for (const [i, result] of provider.results.entries()) assert.equal(unframeSearxngSearchText(item.providerResult.results[i].title), result.title);
  }
  assert.equal(first('authored-query').providerPortableResult.query, 'OpenClaw site:github.com "release notes"');
  assert.equal(first('authored-query').genericPortableResult.query, ' OpenClaw site:github.com "release notes" ');
  assert.equal(first('ordered-optional-content').providerResult.results[0].snippet, '');
  assert.equal(first('ordered-optional-content').providerResult.results[0].img_src, 'https://images.example/thumb.png');
  assert.equal(Object.hasOwn(first('ordered-optional-content').genericResult.results[0], 'img_src'), false);
});

test('ordinary successful empty-category retry and no-retry branches preserve complete request lists/results', () => {
  const retry = first('empty-category-general-retry');
  assert.deepEqual(retry.requests.map(request => request.query.categories), ['news,science', 'general']);
  assert.equal(retry.providerResult.tookMs, 14);
  assert.equal(retry.providerResult.count, 2);
  for (const id of emptyGroups) {
    assert.equal(first(id).requests.length, 1, id);
    assert.equal(first(id).providerResult.count, 0, id);
    assert.deepEqual(first(id).providerResult.results, [], id);
    assert.equal(first(id).genericResult.kind, 'results', id);
  }
});

test('qualifies only short ordinary fixtures and exact final capture', () => {
  assert.equal(capture.counts.groups, 32); assert.equal(capture.counts.callbacks, 55);
  assert.equal(capture.counts.httpBearingCallbacks, 43); assert.equal(capture.counts.httpRequests, 44);
  assert.equal(capture.counts.cacheHitCallbacks, 12);
  assert.equal(new Set(capture.groups.map(row => row.id)).size, 32);
  for (const row of capture.groups) {
    for (const payload of row.httpPayloads) {
      assert.ok(payload.results.length <= 2);
      assert.ok(JSON.stringify(payload).length < 600);
    }
    for (const item of row.steps) {
      assert.ok(item.arguments.query.length < 100);
      assert.equal(Object.hasOwn(item.providerResult, 'error'), false);
      assert.equal(Object.hasOwn(item.genericResult, 'truncated'), false);
      assert.ok(item.setup.config.plugins.entries.searxng.config.webSearch.baseUrl.trim().startsWith('https://'));
    }
  }
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('fresh independent CLI equals module capture and supplied final fixture exactly', () => {
  const fresh = JSON.parse(execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-searxng-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 180_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  }));
  assert.deepEqual(fresh, capture);
  assert.deepEqual(fresh, JSON.parse(readFileSync(fixture, 'utf8')));
});
