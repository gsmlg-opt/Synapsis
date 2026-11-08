// Ordinary paid Parallel source callbacks; no network or production assembly acceptance.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureParallelSearch, unframeParallelSearchText } from './capture-parallel-search.mjs';

const root = process.env.OPENCLAW_PARALLEL_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_PARALLEL_FIXTURE;
const capture = await captureParallelSearch(root);
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
const withoutGeneratedSession = value => {
  const copy = { ...value };
  delete copy.sessionId;
  return copy;
};

test('retains complete pinned source, all Git blobs, actual TypeBox and license provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/parallel/src/parallel-web-search-provider.ts',
    'extensions/parallel/src/parallel-web-search-provider.runtime.ts',
    'extensions/parallel/src/parallel-search-normalize.ts',
    'extensions/parallel/src/parallel-free-web-search-provider.shared.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/agents/tools/common.ts', 'src/shared/lazy-runtime.ts',
    'src/plugin-sdk/provider-web-search-contract.ts',
    'src/plugin-sdk/provider-web-search-contract-fields.ts',
    'src/plugin-sdk/provider-web-search-schema.ts', 'src/security/external-content.ts',
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
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-parallel-search.mjs', import.meta.url))));
  assert.equal(capture.harnessDependencies[0].sha256,
    digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))));
  const packageBytes = readFileSync(join(root, capture.pluginFixture.path));
  assert.equal(capture.pluginFixture.sha256, digest(packageBytes));
  assert.equal(capture.pluginFixture.gitBlob, blob(packageBytes));
  assert.equal(capture.pluginFixture.version, JSON.parse(packageBytes).version);
  assert.equal(capture.typebox.version, '1.3.37');
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('labels unchanged source and explicit fixture boundaries without claiming Synapsis projection equivalence', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualSharedEndpoint', 'actualSharedCache',
    'genericNormalizerInvoked']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'productionNetworkInvoked',
    'pluginRegistrationInvoked', 'actualPluginVersionDiscovery']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  assert.ok(capture.stubs.some(row => row.export === 'readProviderJsonResponse' && row.kind === 'ordinary-platform-fixture'));
  assert.ok(capture.stubs.some(row => row.export === 'ProviderHttpError' && row.behavior === 'throws if invoked'));
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-http-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-json-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier.endsWith('parallel-web-search-provider.runtime.js')), row.id);
    assert.ok(row.audit.some(item => item.kind === 'plugin-version-fixture' && item.version === '2026.10.5'), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.deepEqual(step.setupAfter, step.setup);
      assert.equal(step.providerResult.provider, 'parallel');
      assert.equal(step.genericResult.kind, 'results');
      assert.equal(step.genericResult.query, step.arguments.query ?? '');
      assert.deepEqual(step.providerResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'parallel' });
      assert.deepEqual(step.genericResult.externalContent, step.providerResult.externalContent);
      assert.equal(Object.hasOwn(step.providerPortableResult, 'externalContent'), false);
      assert.equal(Object.hasOwn(step.genericPortableResult, 'externalContent'), false);
    }
  }
});

test('constructs the exact Parallel objective/search_queries/session/client schema and descriptor', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'parallel');
  assert.equal(row.providerMetadata.label, 'Parallel Search');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.equal(row.providerMetadata.autoDetectOrder, 75);
  const schema = row.descriptor.parameters;
  assert.deepEqual(Object.keys(schema.properties), ['objective', 'search_queries', 'count', 'session_id', 'client_model']);
  assert.deepEqual(schema.required, ['objective', 'search_queries']);
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.objective.type, 'string');
  assert.equal(schema.properties.objective.maxLength, 5000);
  assert.equal(schema.properties.search_queries.type, 'array');
  assert.deepEqual(schema.properties.search_queries.items, { type: 'string', maxLength: 200 });
  assert.equal(schema.properties.search_queries.minItems, 1);
  assert.equal(schema.properties.search_queries.maxItems, 5);
  assert.equal(schema.properties.count.type, 'integer');
  assert.equal(schema.properties.count.minimum, 1);
  assert.equal(schema.properties.count.maximum, 40);
  assert.equal(schema.properties.session_id.maxLength, 1000);
  assert.equal(schema.properties.client_model.maxLength, 100);
  assert.equal(row.descriptor.description,
    "Search the web using Parallel. Returns ranked, LLM-optimized dense excerpts from web sources. Pass an `objective` describing the underlying question along with 2-3 short keyword `search_queries` (Parallel's recommended pairing). For multi-step research, thread the prior result's `sessionId` back in as `session_id` to keep Parallel's context grouped.");
});

test('serializes normalized paid POST fields and the source-composed user agent from explicit fixtures', () => {
  const normal = first('search-default');
  assert.equal(normal.request.url, 'https://api.parallel.ai/v1/search');
  assert.equal(normal.request.method, 'POST');
  assert.equal(normal.request.path, '/v1/search');
  assert.deepEqual(normal.request.query, {});
  assert.deepEqual(normal.request.body, {
    search_queries: ['ordinary keyword research', 'alternate keyword sources'],
    advanced_settings: { max_results: 5 }, objective: 'search-default',
  });
  assert.equal(normal.request.timeoutSeconds, 30);
  assert.equal(normal.providerResult.tookMs, 7);
  assert.equal(capture.pluginFixture.platform, 'linux');
  assert.equal(capture.pluginFixture.userAgent, 'openclaw-parallel/2026.10.5 (linux)');
  for (const row of capture.groups) for (const step of row.steps) {
    if (!step.request) continue;
    assert.deepEqual(step.request.headers, {
      Accept: 'application/json', 'Content-Type': 'application/json',
      'x-api-key': step.setup.config.plugins.entries.parallel.config.webSearch.apiKey,
      'User-Agent': 'openclaw-parallel/2026.10.5 (linux)',
    }, row.id);
    assert.deepEqual(JSON.parse(step.request.bodyText), step.request.body, row.id);
    assert.deepEqual(step.request.body.search_queries, step.providerPortableResult.searchQueries, row.id);
    assert.equal(step.request.body.objective, step.providerPortableResult.objective, row.id);
    assert.equal(step.request.body.session_id, step.arguments.session_id?.trim(), row.id);
    assert.equal(step.request.body.client_model, step.arguments.client_model?.trim(), row.id);
  }
  assert.equal(first('configured-timeout').request.timeoutSeconds, 7);
});

test('privately normalizes objective, query order, duplicates and optional context without changing authored arguments', () => {
  const normalized = first('normalized-pair');
  assert.equal(normalized.request.body.objective, 'Understand ordinary research 文');
  assert.deepEqual(normalized.request.body.search_queries, ['first keyword phrase', 'second keyword phrase']);
  assert.equal(normalized.arguments.objective, '  Understand ordinary research 文  ');
  assert.equal(normalized.arguments.search_queries.length, 5);
  assert.deepEqual(first('unicode-pair').request.body, {
    objective: '界😀e\u0301 👩‍💻 ordinary objective',
    search_queries: ['界😀e\u0301 research', '👩‍💻 ordinary sources'],
    advanced_settings: { max_results: 5 },
  });
  assert.deepEqual(first('optional-context').request.body, {
    objective: 'optional supplied context', search_queries: ['ordinary keyword research', 'alternate keyword sources'],
    advanced_settings: { max_results: 3 }, session_id: 'prior-session-文', client_model: 'gpt-6-astra',
  });
  assert.equal(Object.hasOwn(first('search-default').request.body, 'session_id'), false);
  assert.equal(Object.hasOwn(first('search-default').request.body, 'client_model'), false);
});

test('uses configured numeric counts, numeric argument tokens and local ordered result slicing', () => {
  for (const [id, count] of [['search-default', 5], ['configured-count', 2],
    ['configured-count-fraction', 3], ['configured-count-string', 5], ['explicit-count', 4],
    ['numeric-count-token', 3]]) {
    const step = first(id);
    assert.equal(step.request.body.advanced_settings.max_results, count, id);
    assert.equal(step.providerResult.count, count, id);
    assert.equal(step.providerResult.results.length, count, id);
    assert.equal(step.genericResult.count, count, id);
    assert.deepEqual(step.providerPortableResult.results.map(row => row.url),
      group(id).httpPayload.results.slice(0, count).map(row => row.url), id);
  }
});

test('canonicalizes ordinary configured endpoints while retaining their prefixes and query', () => {
  for (const [id, expected] of [
    ['endpoint-origin', 'https://parallel.example/v1/search'],
    ['endpoint-prefix', 'https://parallel.example/proxy/v1/search'],
    ['endpoint-full', 'https://parallel.example/proxy/v1/search'],
    ['endpoint-schemeless', 'https://parallel.example/proxy/v1/search'],
    ['endpoint-query', 'https://parallel.example/proxy/v1/search?lane=ordinary&lang=en'],
    ['endpoint-trailing', 'https://parallel.example/proxy/v1/search'],
    ['endpoint-full-trailing', 'https://parallel.example/proxy/v1/search'],
    ['endpoint-fragment', 'https://parallel.example/proxy/v1/search?lane=ordinary'],
  ]) assert.equal(first(id).request.url, expected, id);
  assert.deepEqual(first('endpoint-query').request.query, { lane: 'ordinary', lang: 'en' });
});

test('preserves ordered raw excerpts, joined descriptions, titles, dates and provider metadata', () => {
  const step = first('ordered-metadata');
  const providerRows = [
    { title: ' First 😀 ', url: ' https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world ',
      description: ' First paragraph 文 \n\n\n Second paragraph 😀 \n',
      siteName: 'www.source.example', published: ' 2026-10-17 ',
      excerpts: [' First paragraph 文 ', '\n Second paragraph 😀 \n'] },
    { title: ' Second ', url: 'https://two.example', description: ' Second description \n\n Final ordered excerpt ',
      siteName: 'two.example', published: '2026-10-18',
      excerpts: [' Second description ', ' Final ordered excerpt '] },
    { title: ' Third ', url: 'https://three.example/ordinary', description: '', siteName: 'three.example' },
  ];
  assert.deepEqual(withoutTime(step.providerPortableResult), {
    objective: 'ordered source results', searchQueries: ['ordinary keyword research', 'alternate keyword sources'],
    provider: 'parallel', count: 3, results: providerRows, searchId: ' raw-search-id ',
    sessionId: ' raw-session-id ', warnings: group('ordered-metadata').httpPayload.warnings,
    usage: group('ordered-metadata').httpPayload.usage,
  });
  for (const [index, row] of providerRows.entries()) {
    const framed = step.providerResult.results[index];
    assert.equal(unframeParallelSearchText(framed.title), row.title);
    assert.equal(unframeParallelSearchText(framed.description), row.description);
    assert.deepEqual(framed.excerpts?.map(unframeParallelSearchText), row.excerpts);
    if (framed.excerpts) assert.equal(framed.description, framed.excerpts.join('\n\n'));
  }
  assert.equal(step.providerUnwrappedResult.results[0].title, 'First 😀');
  assert.deepEqual(step.providerUnwrappedResult.results[0].excerpts,
    ['First paragraph 文', 'Second paragraph 😀']);
  assert.match(step.providerResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
});

test('records the generic source projection separately with authored query or empty string and no Parallel metadata', () => {
  const step = first('ordered-metadata');
  assert.equal(step.genericPortableResult.query, '');
  assert.equal(step.genericPortableResult.kind, 'results');
  assert.equal(step.genericPortableResult.results[0].title, 'First 😀');
  assert.equal(step.genericPortableResult.results[0].url,
    'https://www.source.example/ordinary?q=hello%20world');
  assert.equal(Object.hasOwn(step.genericPortableResult.results[0], 'published'), false);
  assert.equal(step.genericPortableResult.results[1].published, '2026-10-18');
  for (const key of ['objective', 'searchQueries', 'searchId', 'sessionId', 'warnings', 'usage']) {
    assert.equal(Object.hasOwn(step.genericResult, key), false, key);
    assert.equal(Object.hasOwn(step.providerResult, key), true, key);
  }
  for (const row of step.genericResult.results) {
    assert.equal(Object.hasOwn(row, 'excerpts'), false);
    assert.equal(Object.hasOwn(row, 'description'), false);
    assert.equal(typeof row.snippet, 'string');
  }
  assert.equal(first('query-with-pair').genericResult.query, ' authored generic query ');
  assert.equal(first('query-with-pair').providerResult.objective, 'ordinary paired objective');
  assert.deepEqual(first('query-with-pair').request.body.search_queries,
    ['ordinary keyword research', 'alternate keyword sources']);
});

test('supports the internal ordinary CLI query fallback and successful empty result arrays', () => {
  const cli = first('cli-query-fallback');
  assert.deepEqual(cli.request.body, { search_queries: ['ordinary CLI query 文'], advanced_settings: { max_results: 2 } });
  assert.equal(Object.hasOwn(cli.providerResult, 'objective'), false);
  assert.equal(cli.genericResult.query, '  ordinary CLI query 文  ');
  assert.deepEqual(first('cli-query-with-objective').request.body, {
    objective: 'CLI research objective', search_queries: ['CLI keyword phrase'], advanced_settings: { max_results: 5 },
  });
  for (const id of ['successful-empty', 'successful-empty-minimal']) {
    const empty = first(id);
    assert.equal(empty.providerResult.count, 0, id);
    assert.deepEqual(empty.providerResult.results, [], id);
    assert.equal(empty.genericResult.count, 0, id);
    assert.deepEqual(empty.genericResult.results, [], id);
  }
  assert.deepEqual(withoutTime(first('successful-empty-minimal').providerPortableResult), {
    objective: 'successful-empty-minimal', searchQueries: ['ordinary keyword research', 'alternate keyword sources'],
    provider: 'parallel', count: 0, results: [],
  });
});

test('reuses ordinary and empty source cache while removing only generated response session IDs', () => {
  for (const id of ['same-cache-generated-session', 'empty-cache-reuse', 'same-cache-supplied-session']) {
    const [initial, repeated] = group(id).steps;
    assert.equal(initial.cached, false, id);
    assert.equal(repeated.cached, true, id);
    assert.equal(repeated.request, null, id);
    assert.equal(repeated.cumulativeRequests, 1, id);
    const expected = id === 'same-cache-supplied-session'
      ? initial.providerPortableResult : withoutGeneratedSession(initial.providerPortableResult);
    assert.deepEqual(repeated.providerPortableResult, { ...expected, cached: true }, id);
    assert.equal(initial.providerResult.sessionId, 'fixture-session-id', id);
    assert.equal(Object.hasOwn(repeated.providerResult, 'sessionId'), id === 'same-cache-supplied-session', id);
    assert.deepEqual(repeated.genericPortableResult, { ...initial.genericPortableResult, cached: true }, id);
  }
});

test('distinguishes normalized count/objective/queries/order/session/model/endpoint cache identity', () => {
  for (const id of ['count-cache-identity', 'objective-cache-identity', 'queries-cache-identity',
    'query-order-cache-identity', 'session-cache-identity', 'client-model-cache-identity',
    'endpoint-cache-identity']) {
    const [initial, changed, repeated] = group(id).steps;
    assert.equal(initial.cached, false, id);
    assert.equal(changed.cached, false, id);
    assert.ok(changed.request, id);
    assert.equal(repeated.cached, true, id);
    assert.equal(repeated.request, null, id);
    assert.equal(repeated.cumulativeRequests, 2, id);
    assert.deepEqual(repeated.providerPortableResult,
      { ...withoutGeneratedSession(initial.providerPortableResult), cached: true }, id);
  }
  const [two, four] = group('count-cache-identity').steps;
  assert.equal(two.providerResult.count, 2);
  assert.equal(four.providerResult.count, 4);
  assert.equal(two.request.body.advanced_settings.max_results, 2);
  assert.equal(four.request.body.advanced_settings.max_results, 4);
  const endpoints = group('endpoint-cache-identity').steps;
  assert.equal(endpoints[0].request.url, 'https://parallel.example/one/v1/search');
  assert.equal(endpoints[1].request.url, 'https://parallel.example/two/v1/search?lane=ordinary');
  assert.equal(endpoints[2].request, null);
});

test('fresh complete capture equals the frozen fixture when supplied', () => {
  assert.equal(capture.counts.groups, 34);
  assert.equal(capture.counts.callbacks, 51);
  assert.equal(capture.counts.httpBearingCallbacks, 41);
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('a fresh CLI capture exactly reproduces independent module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-parallel-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
