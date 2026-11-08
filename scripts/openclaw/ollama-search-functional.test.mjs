// Ordinary successful pinned-source callbacks; synthetic HTTP and literal config only.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureOllamaSearch, unframeOllamaSearchText } from './capture-ollama-search.mjs';

const root = process.env.OPENCLAW_OLLAMA_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_OLLAMA_FIXTURE;
const capture = await captureOllamaSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => {
  const result = capture.groups.find(row => row.id === id);
  assert.ok(result, id);
  return result;
};
const first = id => group(id).steps[0];
const withoutTime = value => {
  const copy = { ...value };
  delete copy.tookMs;
  return copy;
};

test('retains whole pinned modules, all tracked blobs, actual TypeBox and license provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/ollama/web-search-contract-api.ts',
    ...['web-search-provider', 'web-search-provider-registration', 'web-search-provider.runtime',
      'web-search-contract', 'defaults', 'provider-base-url', 'provider-models', 'model-reasoning']
      .map(name => 'extensions/ollama/src/' + name + '.ts'),
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/web-fetch-utils.ts',
    'src/shared/lazy-runtime.ts', 'src/plugin-sdk/provider-web-search-contract.ts',
    'src/plugin-sdk/provider-web-search-contract-fields.ts', 'src/plugin-sdk/provider-web-search-schema.ts',
    'src/security/external-content.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256,
      digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true, row.path);
  }
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.match(capture.license.text, /MIT License/);
  for (const row of capture.facades) assert.equal(row.sha256, digest(row.generatedCode));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-ollama-search.mjs', import.meta.url))));
  assert.equal(capture.harnessDependencies[0].sha256,
    digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))));
  assert.equal(capture.typebox.version, '1.3.37');
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('declares actual whole-source helpers and explicit platform/configuration boundaries', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualBaseUrlHelper', 'actualCountReaders',
    'genericNormalizerInvoked', 'actualUnwrapInvoked', 'actualTypeBox', 'hostSharedCacheAdaptation']) {
    assert.equal(capture.boundaries[key], true, key);
  }
  for (const key of ['bodyProjections', 'sourceProviderCache', 'actualBoundedSuccessReader',
    'actualEndpointPolicy', 'actualCredentialResolution', 'productionNetworkInvoked',
    'pluginRegistrationInvoked']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const name of ['fetchWithSsrFGuard', 'readProviderJsonResponse', 'buildOllamaBaseUrlSsrFPolicy']) {
    assert.ok(capture.stubs.some(row => row.export === name && row.kind === 'ordinary-platform-fixture'), name);
  }
  assert.ok(capture.stubs.some(row => row.export === 'fetchOllamaModels' && row.behavior === 'throws if invoked'));
  assert.ok(capture.stubs.some(row => row.export === 'createStaleWhileRevalidateCache'
    && row.kind === 'ordinary-platform-initialization-fixture'));
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.equal(row.audit.filter(item => item.kind === 'successful-http-fixture').length, row.steps.length);
    assert.equal(row.audit.filter(item => item.kind === 'successful-json-fixture').length, row.steps.length);
    assert.equal(row.audit.filter(item => item.kind === 'successful-release-fixture').length, row.steps.length);
    assert.equal(row.audit.filter(item => item.kind === 'model-cache-initialization-fixture').length, 1);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import'
      && item.specifier.endsWith('web-search-provider.runtime.js')), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.deepEqual(step.setup, row.setup);
      assert.equal(step.providerResult.provider, 'ollama');
      assert.equal(step.genericResult.kind, 'results');
      assert.equal(step.genericResult.query, step.arguments.query);
      assert.deepEqual(step.genericResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'ollama' });
      assert.equal(Object.hasOwn(step.providerPortableResult, 'externalContent'), false);
      assert.equal(Object.hasOwn(step.genericPortableResult, 'externalContent'), false);
      assert.deepEqual(step.publicResult, step.genericResult);
      assert.deepEqual(step.publicUnwrappedResult, step.genericUnwrappedResult);
      assert.deepEqual(step.publicPortableResult, step.genericPortableResult);
    }
  }
});

test('constructs actual lazy factory descriptor and closed query/count schema', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'ollama');
  assert.equal(row.providerMetadata.label, 'Ollama Web Search');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.equal(row.providerMetadata.autoDetectOrder, 110);
  assert.deepEqual(row.descriptor, {
    description: "Search the web using Ollama's web search API. Returns titles, URLs, and snippets from the configured Ollama host.",
    parameters: { type: 'object', properties: {
      query: { type: 'string', description: 'Search query string.' },
      count: { type: 'integer', description: 'Number of results to return (1-10).', minimum: 1, maximum: 10 },
    }, required: ['query'], additionalProperties: false },
  });
});

test('serializes query/max_results with source default five independent of search config', () => {
  for (const [id, count] of [['search-default', 5], ['explicit-count', 4],
    ['numeric-count-token', 3], ['configured-count-ignored', 5]]) {
    const step = first(id);
    assert.equal(step.request.body.max_results, count, id);
    assert.equal(step.providerResult.count, count, id);
    assert.equal(step.genericResult.count, count, id);
  }
  assert.equal(group('configured-count-ignored').setup.searchConfig.maxResults, 2);
  assert.equal(group('configured-timeout-ignored').setup.searchConfig.timeoutSeconds, 7);
  for (const row of capture.groups) for (const step of row.steps) {
    assert.equal(step.request.method, 'POST', row.id);
    assert.deepEqual(step.request.query, {}, row.id);
    assert.deepEqual(Object.keys(step.request.body), ['query', 'max_results'], row.id);
    assert.equal(step.request.body.query, step.arguments.query.trim(), row.id);
    assert.deepEqual(JSON.parse(step.request.bodyText), step.request.body, row.id);
    assert.equal(step.request.timeoutMs, 15_000, row.id);
    assert.equal(step.request.auditContext, 'ollama-web-search.search', row.id);
    assert.equal(step.providerResult.tookMs, 7, row.id);
    assert.equal(step.genericResult.tookMs, 7, row.id);
  }
});

test('routes successful local first requests and explicit hosted requests through actual base helpers', () => {
  assert.equal(first('search-default').request.url, 'http://127.0.0.1:11434/api/experimental/web_search');
  for (const [id, base] of [
    ['endpoint-plugin-prefix', 'http://127.0.0.1:18181/proxy'],
    ['endpoint-model-base-url', 'http://127.0.0.1:18182/model'],
    ['endpoint-model-baseURL', 'http://127.0.0.1:18183/alternate'],
    ['endpoint-model-base-url-precedence', 'http://127.0.0.1:18184/primary'],
    ['endpoint-plugin-precedence', 'http://127.0.0.1:18186/plugin'],
    ['endpoint-prefix-ending-v1', 'http://ordinary.example/proxy/v1'],
  ]) assert.equal(first(id).request.url, base + '/api/experimental/web_search', id);
  assert.equal(first('direct-hosted').request.url, 'https://ollama.com/api/web_search');
  assert.equal(first('direct-hosted-prefix').request.url, 'https://ollama.com/trusted/api/web_search');
});

test('privately trims authored operators and ordinary Unicode while generic query remains authored', () => {
  for (const id of ['operator-query', 'unicode-query']) {
    const step = first(id);
    assert.equal(step.request.body.query, step.arguments.query.trim());
    assert.equal(step.providerPortableResult.query, step.arguments.query.trim());
    assert.equal(step.genericPortableResult.query, step.arguments.query);
  }
  assert.match(first('operator-query').request.body.query, /site:github.com -site:archive.example lang:en/);
  assert.equal(first('unicode-query').request.body.query, '界😀e\u0301 👩‍💻 ordinary search');
});

test('keeps complete ordered short results, source trimming and URL hostname with independent generic normalization', () => {
  const step = first('ordered-metadata');
  const rows = [
    { title: 'First 😀', url: 'https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world',
      snippet: 'First description 文', siteName: 'www.source.example' },
    { title: 'Second', url: 'https://two.example', snippet: 'Second description', siteName: 'two.example' },
    { title: 'Third', url: 'https://three.example/ordinary', snippet: 'Third description', siteName: 'three.example' },
  ];
  assert.deepEqual(withoutTime(step.providerPortableResult), {
    query: 'ordered source results', provider: 'ollama', count: 3, results: rows,
  });
  assert.deepEqual(withoutTime(step.genericPortableResult), {
    kind: 'results', query: 'ordered source results', provider: 'ollama', count: 3, results: rows.map((row, index) => ({
      ...row, url: index === 0 ? 'https://www.source.example/ordinary?q=hello%20world'
        : index === 1 ? 'https://two.example/' : row.url,
    })),
  });
  assert.deepEqual(step.providerUnwrappedResult.results, rows);
  for (const [index, row] of rows.entries()) {
    assert.equal(unframeOllamaSearchText(step.providerResult.results[index].title), row.title);
    assert.equal(unframeOllamaSearchText(step.providerResult.results[index].snippet), row.snippet);
  }
  assert.match(step.providerResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.match(step.genericResult.results[0].siteName, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
});

test('represents successful sparse, empty and missing result payloads', () => {
  const step = first('sparse-results');
  const results = [
    { title: '', url: 'https://sparse.example/one', snippet: '', siteName: 'sparse.example' },
    { title: 'Title only', url: 'https://sparse.example/two', snippet: '', siteName: 'sparse.example' },
    { title: '', url: 'https://sparse.example/three', snippet: 'Description only', siteName: 'sparse.example' },
  ];
  assert.deepEqual(step.providerPortableResult.results, results);
  assert.deepEqual(step.genericPortableResult.results, results);
  for (const id of ['successful-empty', 'successful-missing-results']) {
    assert.deepEqual(withoutTime(first(id).providerPortableResult), {
      provider: 'ollama', query: id, count: 0, results: [],
    });
    assert.deepEqual(withoutTime(first(id).genericPortableResult), {
      kind: 'results', provider: 'ollama', query: id, count: 0, results: [],
    });
  }
});

test('repeated successful source callbacks each issue HTTP because source Ollama has no provider cache', () => {
  for (const id of ['same-query-repeated', 'count-sequence']) {
    for (const [index, step] of group(id).steps.entries()) {
      assert.ok(step.request, id);
      assert.equal(step.cumulativeRequests, index + 1, id);
      assert.equal(Object.hasOwn(step.providerResult, 'cached'), false, id);
      assert.equal(Object.hasOwn(step.genericResult, 'cached'), false, id);
      assert.equal(step.request.body.max_results, step.arguments.count, id);
    }
  }
  const [initial, repeated] = group('same-query-repeated').steps;
  assert.deepEqual(initial.request.body, repeated.request.body);
  assert.deepEqual(initial.providerPortableResult, repeated.providerPortableResult);
  const [two, four, twoAgain] = group('count-sequence').steps;
  assert.equal(two.providerPortableResult.count, 2);
  assert.equal(four.providerPortableResult.count, 4);
  assert.deepEqual(twoAgain.providerPortableResult, two.providerPortableResult);
});

test('fresh complete capture matches its frozen fixture when supplied', () => {
  assert.equal(capture.counts.groups, 21);
  assert.equal(capture.counts.callbacks, 24);
  assert.equal(capture.counts.httpBearingCallbacks, 24);
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('fresh CLI capture exactly reproduces independent module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-ollama-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
