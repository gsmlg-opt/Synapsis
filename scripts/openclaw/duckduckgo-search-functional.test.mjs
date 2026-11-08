// Independent ordinary expectations; no production parser or normalizer builds the oracle.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureDuckDuckGoSearch, unframeDuckDuckGoSearchText } from './capture-duckduckgo-search.mjs';

const root = process.env.OPENCLAW_DUCKDUCKGO_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_DUCKDUCKGO_FIXTURE
  ?? fileURLToPath(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/duckduckgo-search.json', import.meta.url));
const capture = await captureDuckDuckGoSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => { const row = capture.groups.find(item => item.id === id); assert.ok(row, id); return row; };
const first = id => group(id).steps[0];
const stamp = { untrusted: true, source: 'web_search', provider: 'duckduckgo', wrapped: true };
const frame = text => '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n'
  + text + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
const hits = new Map([
  ['configured-count', [false, true, false, true]], ['context-search-options-ignored', [false, true]],
  ['same-query-repeated', [false, true]], ['query-case-identity', [false, false, true]],
  ['query-interior-space-identity', [false, false, true]], ['count-identity', [false, false, true]],
  ['region-identity', [false, false, true]], ['effective-region-identity', [false, true, true]],
  ['cache-off', [false, false]], ['cache-off-on', [false, false, true]],
  ['cache-on-off-on', [false, false, true]], ['empty-cache-reuse', [false, true]],
  ['ordinary-protocol-relative', [false, true]],
]);
const ordinaryResults = [
  { title: 'First ordinary title', url: 'https://www.docs.example/one', snippet: 'First ordinary snippet.', siteName: 'www.docs.example' },
  { title: 'Second ordinary title', url: 'https://news.example/two', snippet: 'Second ordinary snippet.', siteName: 'news.example' },
];
const changedResults = [
  { title: 'Changed second response', url: 'https://changed.example/two', snippet: 'Fresh ordinary content.', siteName: 'changed.example' },
];
const specialResults = new Map([
  ['ordinary-protocol-relative', [
    { title: 'Relative source', url: '//www.relative.example/guide', snippet: 'Relative ordinary snippet.' },
  ]],
  ['ordinary-redirect-links', [
    { title: 'Redirected title', url: 'https://www.redirect.example/guide?a=1&b=2', snippet: 'Redirected snippet.', siteName: 'www.redirect.example' },
    { title: 'Direct entity URL', url: 'https://direct.example/guide?a=1&b=2', snippet: 'Direct snippet.', siteName: 'direct.example' },
  ]],
  ['ordinary-highlight-spacing', [
    { title: 'OpenClaw source guide', url: 'https://www.highlight.example/title', snippet: 'Read highlights with spacing .', siteName: 'www.highlight.example' },
    { title: 'Second inword', url: 'https://second.example/guide', snippet: 'Second plain snippet.', siteName: 'second.example' },
  ]],
  ['ordinary-entities-once', [
    { title: 'A & B <guide> "quote" \'apostrophe\' \' \' /   - -- ... © 😀 &lt;',
      url: 'https://entities.example/guide?a=1&b=2', snippet: 'One  two & A B &amp;', siteName: 'entities.example' },
  ]],
  ['ordinary-optional-snippets', [
    { title: 'No snippet first', url: 'https://www.optional.example/one', snippet: '', siteName: 'www.optional.example' },
    { title: 'Snippet second', url: 'https://www.optional.example/two', snippet: 'Second snippet belongs here.', siteName: 'www.optional.example' },
  ]],
  ['successful-empty', []], ['empty-cache-reuse', []],
]);
const expectedIds = [
  'search-default', 'authored-query', 'explicit-count', 'numeric-count-token', 'configured-count',
  'configured-timeout', 'context-search-options-ignored', 'configured-region', 'argument-region',
  'blank-region-fallback', 'same-query-repeated', 'query-case-identity', 'query-interior-space-identity',
  'count-identity', 'region-identity', 'effective-region-identity', 'cache-off', 'cache-off-on',
  'cache-on-off-on', 'ordinary-protocol-relative', 'ordinary-redirect-links', 'ordinary-highlight-spacing',
  'ordinary-entities-once', 'ordinary-optional-snippets', 'successful-empty', 'empty-cache-reuse',
];
function expectedRegion(id, n) {
  if (['configured-region', 'blank-region-fallback'].includes(id)) return 'de-de';
  if (id === 'argument-region') return 'uk-en';
  if (id === 'region-identity') return n === 1 ? 'de-de' : 'us-en';
  if (id === 'effective-region-identity') return 'us-en';
  return undefined;
}
function expectedRequests(row, item, n) {
  if ((hits.get(row.id) ?? [false])[n]) return [];
  const region = expectedRegion(row.id, n);
  // This constant is an unchanged wire observation in a complete ordinary GET map.
  const query = { q: item.arguments.query.trim(), ...(region ? { kl: region } : {}), kp: '-1' };
  return [{ url: 'https://html.duckduckgo.com/html?' + new URLSearchParams(query),
    method: 'GET', path: '/html', query,
    headers: { 'user-agent': 'openclaw-duckduckgo/2026.10.5 (+https://docs.openclaw.ai)' },
    timeoutSeconds: 20, signalSupplied: false }];
}
function expectedProvider(row, item, n) {
  const changed = (row.id === 'cache-off' && n === 1)
    || (row.id === 'cache-off-on' && n >= 1) || (row.id === 'cache-on-off-on' && n === 1);
  const results = specialResults.get(row.id) ?? (changed ? changedResults : ordinaryResults);
  return { query: item.arguments.query.trim(), provider: 'duckduckgo', count: results.length,
    tookMs: 7, results: results.map(value => ({ ...value })),
    ...((hits.get(row.id) ?? [false])[n] ? { cached: true } : {}) };
}
function packageRoot(name) {
  if (name === 'entities' && process.env.OPENCLAW_DUCKDUCKGO_ENTITIES) {
    return realpathSync(process.env.OPENCLAW_DUCKDUCKGO_ENTITIES);
  }
  let path = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve(name)));
  while (!existsSync(join(path, 'package.json'))) path = dirname(path);
  return path;
}

test('verifies unchanged pinned whole modules, actual entity/TypeBox dependencies, facades and attribution', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of ['extensions/duckduckgo/web-search-provider.ts',
    'extensions/duckduckgo/src/ddg-search-provider.ts', 'extensions/duckduckgo/src/ddg-client.ts',
    'src/shared/html-entities.ts', 'src/agents/tools/web-search-output.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/common.ts',
    'src/agents/tools/web-shared.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts', 'src/security/external-content.ts',
    'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-web-search-contract-fields.ts',
    'src/plugin-sdk/provider-web-search-schema.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256,
      digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true, row.path);
  }
  for (const row of capture.facades) {
    assert.equal(row.sha256, digest(row.generatedCode));
    assert.ok(capture.sources.some(source => source.path === row.provenance), row.provenance);
    for (const match of row.generatedCode.matchAll(/capture:source:([^";]+)/g)) {
      assert.equal(capture.sources.find(source => source.path === match[1])?.executed, true, match[1]);
    }
  }
  for (const name of ['entities', 'typebox']) {
    const path = packageRoot(name), pkg = JSON.parse(readFileSync(join(path, 'package.json'), 'utf8'));
    assert.equal(pkg.name, name);
    assert.equal(capture[name].version, name === 'entities' ? '8.1.0' : '1.3.37');
    assert.equal(pkg.version, capture[name].version);
    assert.ok(capture[name].files.some(row => row.path === name + '/package.json'));
    assert.ok(capture[name].files.some(row => row.path ===
      (name === 'entities' ? 'entities/dist/index.js' : 'typebox/build/index.mjs')));
    for (const row of capture[name].files) assert.equal(row.sha256,
      digest(readFileSync(join(path, row.path.slice(name.length + 1)))), row.path);
  }
  assert.ok(capture.entities.files.some(row => row.path === 'entities/LICENSE'));
  const pinnedLock = capture.entities.artifact.pinnedLock;
  assert.equal(pinnedLock.path, 'pnpm-lock.yaml');
  const lock = readFileSync(join(root, pinnedLock.path));
  assert.equal(pinnedLock.sha256, digest(lock));
  assert.equal(pinnedLock.gitBlob, blob(lock));
  assert.ok(lock.toString().includes(pinnedLock.integrity));
  assert.equal(capture.entities.artifact.tarball.integrity, pinnedLock.integrity);
  assert.equal('sha512-' + Buffer.from(capture.entities.artifact.tarball.sha512, 'hex').toString('base64'),
    pinnedLock.integrity);
  const plugin = readFileSync(join(root, 'extensions/duckduckgo/package.json'));
  assert.equal(capture.pluginFixture.path, 'extensions/duckduckgo/package.json');
  assert.equal(capture.pluginFixture.sha256, digest(plugin));
  assert.equal(capture.pluginFixture.gitBlob, blob(plugin));
  assert.equal(capture.pluginFixture.version, '2026.10.5');
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.match(capture.license.text, /MIT License/);
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-duckduckgo-search.mjs', import.meta.url))));
  for (const row of capture.harnessDependencies) assert.equal(row.sha256,
    digest(readFileSync(fileURLToPath(new URL('../../' + row.path, import.meta.url)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('records successful HTML text, HTTP and package-version facades at the real lazy client boundary', () => {
  for (const name of ['withTrustedWebSearchEndpoint', 'readProviderTextResponse',
    'createRequire', 'readPluginPackageVersion']) {
    assert.ok(capture.stubs.some(row => row.export === name && row.kind === 'ordinary-platform-fixture'), name);
  }
  for (const row of capture.groups) {
    const requests = row.steps.flatMap(item => item.requests);
    assert.deepEqual(row.audit.filter(item => item.kind === 'successful-http-fixture'),
      requests.map(item => ({ kind: 'successful-http-fixture', url: item.url })), row.id);
    assert.deepEqual(row.audit.filter(item => item.kind === 'successful-short-text-fixture'),
      requests.map(() => ({ kind: 'successful-short-text-fixture', label: 'DuckDuckGo search' })), row.id);
    assert.deepEqual(row.audit.filter(item => item.kind === 'plugin-require-fixture'),
      [{ kind: 'plugin-require-fixture' }], row.id);
    assert.deepEqual(row.audit.filter(item => item.kind === 'plugin-version-fixture'),
      [{ kind: 'plugin-version-fixture', version: '2026.10.5' }], row.id);
  }
});

test('checks exact keyless provider metadata and ordinary query/count/region descriptor fields', () => {
  const metadata = { id: 'duckduckgo', label: 'DuckDuckGo Search (experimental)',
    hint: 'Free web search fallback with no API key required', onboardingScopes: ['text-inference'],
    requiresCredential: false, envVars: [], placeholder: '(no key needed)',
    signupUrl: 'https://duckduckgo.com/', docsUrl: 'https://docs.openclaw.ai/tools/web',
    autoDetectOrder: 100, credentialPath: '', inactiveSecretPaths: [] };
  for (const row of capture.groups) {
    assert.deepEqual(row.providerMetadata, metadata, row.id);
    assert.equal(row.descriptor.description,
      'Search the web using DuckDuckGo. Returns titles, URLs, and snippets with no API key required.');
    const properties = row.descriptor.parameters.properties;
    assert.deepEqual(properties.query, { type: 'string', description: 'Search query string.' });
    assert.deepEqual(properties.count, { type: 'integer', description: 'Number of results to return (1-10).', minimum: 1, maximum: 10 });
    assert.deepEqual(properties.region, { type: 'string', description: 'Optional DuckDuckGo region code such as us-en, uk-en, or de-de.' });
  }
});

test('compares every full ordinary GET, region precedence, current query and cache identity', () => {
  assert.deepEqual(capture.groups.map(row => row.id), expectedIds);
  for (const row of capture.groups) {
    assert.deepEqual(row.setupAfter, row.setup, row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import'
      && item.importer === 'extensions/duckduckgo/src/ddg-search-provider.ts' && item.specifier === './ddg-client.js'), row.id);
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
  assert.equal(first('explicit-count').arguments.count, 3);
  assert.equal(first('numeric-count-token').arguments.count, ' 4 ');
  assert.equal(first('configured-count').setup.config.tools.web.search.maxResults, 3);
  assert.equal(first('configured-timeout').setup.config.tools.web.search.timeoutSeconds, 9);
  assert.deepEqual(first('context-search-options-ignored').setup.searchConfig,
    { maxResults: 3, timeoutSeconds: 9, cacheTtlMinutes: 0 });
  assert.equal(first('configured-region').request.query.kl, 'de-de');
  assert.equal(first('argument-region').request.query.kl, 'uk-en');
  assert.equal(first('blank-region-fallback').request.query.kl, 'de-de');
});

test('independently compares complete provider and generic framed, unwrapped, portable and public maps', () => {
  for (const row of capture.groups) for (const [n, item] of row.steps.entries()) {
    const provider = expectedProvider(row, item, n);
    const providerFramed = { ...provider, externalContent: stamp, results: provider.results.map(result => ({ ...result,
      title: frame(result.title), snippet: result.snippet ? frame(result.snippet) : '' })) };
    const providerUnwrapped = { ...provider, externalContent: stamp };
    let generic, genericFramed, genericUnwrapped;
    if (row.id === 'ordinary-protocol-relative') {
      generic = { kind: 'raw', provider: 'duckduckgo', data: provider };
      genericFramed = { kind: 'raw', provider: 'duckduckgo', data: providerFramed };
      genericUnwrapped = { kind: 'raw', provider: 'duckduckgo', data: providerUnwrapped };
    } else {
      generic = { kind: 'results', provider: 'duckduckgo', query: item.arguments.query, count: provider.count,
        tookMs: 7, results: provider.results.map(result => ({ ...result })), ...(provider.cached ? { cached: true } : {}) };
      genericFramed = { ...generic, externalContent: stamp, results: generic.results.map(result => ({ ...result,
        title: frame(result.title), snippet: result.snippet ? frame(result.snippet) : '',
        ...(result.siteName ? { siteName: frame(result.siteName) } : {}) })) };
      genericUnwrapped = { ...generic, externalContent: stamp };
    }
    assert.deepEqual(item.providerPortableResult, provider, row.id);
    assert.deepEqual(item.providerResult, providerFramed, row.id);
    assert.deepEqual(item.providerUnwrappedResult, providerUnwrapped, row.id);
    assert.deepEqual(item.genericPortableResult, generic, row.id);
    assert.deepEqual(item.genericResult, genericFramed, row.id);
    assert.deepEqual(item.genericUnwrappedResult, genericUnwrapped, row.id);
    assert.deepEqual(item.publicResult, genericFramed, row.id);
    assert.deepEqual(item.publicUnwrappedResult, genericUnwrapped, row.id);
    assert.deepEqual(item.publicPortableResult, generic, row.id);
    for (const [i, result] of provider.results.entries()) assert.equal(
      unframeDuckDuckGoSearchText(item.providerResult.results[i].title), result.title);
  }
  assert.equal(first('authored-query').providerPortableResult.query, 'OpenClaw site:github.com "release notes"');
  assert.equal(first('authored-query').genericPortableResult.query, ' OpenClaw site:github.com "release notes" ');
  assert.deepEqual(group('cache-on-off-on').steps.map(item => item.providerPortableResult.results),
    [ordinaryResults, changedResults, ordinaryResults]);
  assert.deepEqual(group('cache-off-on').steps.map(item => item.providerPortableResult.results),
    [ordinaryResults, changedResults, changedResults]);
});

test('retains short ordinary HTML inputs and complete final fixture integrity', () => {
  for (const row of capture.groups) {
    for (const html of row.httpPayloads) {
      assert.equal(typeof html, 'string');
      assert.ok(html.length < 1000, row.id);
      assert.ok([...html.matchAll(/class="[^"]*\bresult__a\b/g)].length <= 2, row.id);
    }
    for (const item of row.steps) assert.ok(item.arguments.query.length < 100, row.id);
  }
  assert.equal(capture.counts.groups, capture.groups.length);
  assert.equal(capture.counts.callbacks, capture.groups.reduce((n, row) => n + row.steps.length, 0));
  assert.equal(capture.counts.httpRequests, capture.groups.reduce((n, row) => n
    + row.steps.reduce((total, item) => total + item.requests.length, 0), 0));
  assert.equal(capture.counts.cacheHitCallbacks, capture.groups.reduce((n, row) => n
    + row.steps.filter(item => item.cacheHit).length, 0));
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('fresh CLI equals module capture and supplied final fixture exactly', () => {
  const fresh = JSON.parse(execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-duckduckgo-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 180_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  }));
  assert.deepEqual(fresh, capture);
  assert.deepEqual(fresh, JSON.parse(readFileSync(fixture, 'utf8')));
});
