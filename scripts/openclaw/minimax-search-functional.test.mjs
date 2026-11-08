// Ordinary successful source callbacks; no network or production assembly acceptance.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureMinimaxSearch, unframeMiniMaxSearchText } from './capture-minimax-search.mjs';

const root = process.env.OPENCLAW_MINIMAX_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_MINIMAX_FIXTURE;
const capture = await captureMinimaxSearch(root);
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

test('retains complete pinned source, Git blobs, actual TypeBox and license provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/minimax/src/minimax-web-search-provider.ts',
    'extensions/minimax/src/minimax-web-search-provider.runtime.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/agents/tools/common.ts', 'src/shared/lazy-runtime.ts',
    'src/plugin-sdk/provider-web-search-config-contract.ts',
    'src/plugin-sdk/provider-web-search-schema.ts',
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
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-minimax-search.mjs', import.meta.url))));
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

test('labels whole-source execution, unused services and synthetic platform boundaries', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualSharedEndpoint', 'actualSharedCache',
    'actualRegionSelection', 'genericNormalizerInvoked']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'productionNetworkInvoked',
    'pluginRegistrationInvoked']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  assert.ok(capture.stubs.some(row => row.export === 'readProviderJsonResponse' && row.kind === 'ordinary-platform-fixture'));
  assert.ok(capture.stubs.some(row => row.export === 'formatProviderHttpErrorMessage' && row.behavior === 'throws if invoked'));
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-http-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-json-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier.endsWith('minimax-web-search-provider.runtime.js')), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.equal(step.providerResult.provider, 'minimax');
      assert.equal(step.publicResult.kind, 'results');
      assert.equal(step.publicResult.query, step.arguments.query);
      assert.deepEqual(step.publicResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'minimax' });
      assert.equal(Object.hasOwn(step.providerPortableResult, 'externalContent'), false);
      assert.equal(Object.hasOwn(step.publicPortableResult, 'externalContent'), false);
    }
  }
});

test('constructs the unchanged MiniMax factory descriptor and query/count schema', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'minimax');
  assert.equal(row.providerMetadata.label, 'MiniMax Search');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.equal(row.providerMetadata.autoDetectOrder, 15);
  assert.deepEqual(Object.keys(row.descriptor.parameters.properties), ['query', 'count']);
  assert.equal(row.descriptor.parameters.properties.query.type, 'string');
  assert.equal(row.descriptor.parameters.properties.count.type, 'integer');
  assert.equal(row.descriptor.parameters.properties.count.minimum, 1);
  assert.equal(row.descriptor.parameters.properties.count.maximum, 10);
  assert.match(row.descriptor.description, /MiniMax Search API/);
});

test('serializes only q while counts control the local organic slice', () => {
  const normal = first('search-default');
  assert.equal(normal.request.url, 'https://api.minimax.io/v1/coding_plan/search');
  assert.equal(normal.request.method, 'POST');
  assert.equal(normal.request.path, '/v1/coding_plan/search');
  assert.deepEqual(normal.request.query, {});
  assert.deepEqual(normal.request.body, { q: 'search-default' });
  assert.equal(normal.request.timeoutSeconds, 30);
  assert.equal(normal.providerResult.tookMs, 7);
  for (const [id, count] of [['search-default', 5], ['configured-count', 2],
    ['configured-count-string', 5], ['explicit-count', 4], ['numeric-count-token', 3]]) {
    const step = first(id);
    assert.equal(step.providerResult.count, count, id);
    assert.equal(step.providerResult.results.length, count, id);
    assert.equal(step.publicResult.count, count, id);
  }
  for (const row of capture.groups) for (const step of row.steps) {
    if (!step.request) continue;
    assert.deepEqual(step.request.body, { q: step.arguments.query.trim() }, row.id);
    assert.deepEqual(JSON.parse(step.request.bodyText), step.request.body, row.id);
    assert.deepEqual(Object.keys(step.request.body), ['q'], row.id);
  }
  assert.equal(first('configured-timeout').request.timeoutSeconds, 7);
});

test('executes default, explicit region and source model URL region selection', () => {
  for (const id of ['search-default', 'endpoint-explicit-global', 'endpoint-model-global']) {
    assert.equal(first(id).request.url, 'https://api.minimax.io/v1/coding_plan/search', id);
  }
  for (const id of ['endpoint-explicit-cn', 'endpoint-model-cn', 'endpoint-portal-cn']) {
    assert.equal(first(id).request.url, 'https://api.minimaxi.com/v1/coding_plan/search', id);
  }
});

test('keeps authored public queries while the private reader trims operators and Unicode', () => {
  for (const id of ['operator-query', 'unicode-query']) {
    const step = first(id);
    assert.equal(step.request.body.q, step.arguments.query.trim());
    assert.equal(step.providerPortableResult.query, step.arguments.query.trim());
    assert.equal(step.publicPortableResult.query, step.arguments.query);
  }
  assert.match(first('operator-query').request.body.q, /site:github.com -site:archive.example lang:en/);
  assert.equal(first('unicode-query').request.body.q, '界😀e\u0301 👩‍💻 ordinary search');
});

test('preserves raw provider row and related-query whitespace, with actual public normalization', () => {
  const step = first('ordered-metadata');
  const providerRows = [
    { title: ' First 😀 ', url: ' https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world ',
      description: ' First description 文 ', published: ' 2026-10-17 ', siteName: 'www.source.example' },
    { title: ' Second ', url: 'https://two.example', description: ' Second description ',
      published: '2026-10-18', siteName: 'two.example' },
    { title: ' Third ', url: 'https://three.example/ordinary', description: ' Third description ', siteName: 'three.example' },
  ];
  assert.deepEqual(withoutTime(step.providerPortableResult), {
    query: 'ordered source results', provider: 'minimax', count: 3, results: providerRows,
    relatedSearches: [' First related 文 ', 'Second related 😀', '  Third related  '],
  });
  assert.deepEqual(withoutTime(step.publicPortableResult), {
    kind: 'results', query: 'ordered source results', provider: 'minimax', count: 3, results: [
      { title: 'First 😀', url: 'https://www.source.example/ordinary?q=hello%20world',
        snippet: 'First description 文', siteName: 'www.source.example' },
      { title: 'Second', url: 'https://two.example/', snippet: 'Second description',
        published: '2026-10-18', siteName: 'two.example' },
      { title: 'Third', url: 'https://three.example/ordinary', snippet: 'Third description', siteName: 'three.example' },
    ],
  });
  assert.equal(step.providerUnwrappedResult.results[0].title, 'First 😀');
  assert.deepEqual(step.providerUnwrappedResult.relatedSearches, ['First related 文', 'Second related 😀', 'Third related']);
  assert.equal(Object.hasOwn(step.publicResult, 'relatedSearches'), false);
  for (const [index, row] of providerRows.entries()) {
    assert.equal(unframeMiniMaxSearchText(step.providerResult.results[index].title), row.title);
    assert.equal(unframeMiniMaxSearchText(step.providerResult.results[index].description), row.description);
  }
  for (const [index, text] of step.providerPortableResult.relatedSearches.entries()) {
    assert.equal(unframeMiniMaxSearchText(step.providerResult.relatedSearches[index]), text);
  }
  assert.match(step.providerResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.match(step.publicResult.results[0].snippet, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
});

test('accepts sparse nullish fields, empty or missing organic and ordinary status zero', () => {
  const step = first('sparse-results');
  assert.deepEqual(step.providerPortableResult.results, [
    { title: '', url: 'https://sparse.example/one', description: '', siteName: 'sparse.example' },
    { title: 'Title only', url: 'https://sparse.example/two', description: '', siteName: 'sparse.example' },
    { title: '', url: 'https://sparse.example/three', description: 'Description only', published: '2026-10-19', siteName: 'sparse.example' },
  ]);
  assert.deepEqual(step.publicPortableResult.results, step.providerPortableResult.results
    .map(({ description, ...row }) => ({ ...row, snippet: description })));
  for (const id of ['successful-empty', 'successful-missing-organic']) {
    assert.deepEqual(withoutTime(first(id).providerPortableResult), {
      provider: 'minimax', query: id, count: 0, results: [],
    });
    assert.deepEqual(withoutTime(first(id).publicPortableResult), {
      kind: 'results', provider: 'minimax', query: id, count: 0, results: [],
    });
  }
  assert.equal(first('successful-status-zero').providerResult.count, 2);
  assert.equal(first('successful-status-zero').publicResult.count, 2);
});

test('reuses source cache for ordinary and empty success and distinguishes count identity', () => {
  for (const id of ['same-cache-reuse', 'empty-cache-reuse']) {
    const [initial, repeated] = group(id).steps;
    assert.equal(initial.cached, false);
    assert.equal(repeated.cached, true);
    assert.equal(repeated.request, null);
    assert.equal(repeated.cumulativeRequests, 1);
    assert.deepEqual(repeated.providerPortableResult, { ...initial.providerPortableResult, cached: true });
    assert.deepEqual(repeated.publicPortableResult, { ...initial.publicPortableResult,
      query: repeated.arguments.query, cached: true });
  }
  const [two, four, twoAgain] = group('count-cache-identity').steps;
  assert.equal(two.providerResult.count, 2);
  assert.equal(four.providerResult.count, 4);
  assert.equal(four.cached, false);
  assert.deepEqual(two.request.body, four.request.body);
  assert.equal(twoAgain.request, null);
  assert.equal(twoAgain.cumulativeRequests, 2);
  assert.deepEqual(twoAgain.providerPortableResult, { ...two.providerPortableResult, cached: true });
});

test('fresh complete capture equals the frozen fixture when supplied', () => {
  assert.equal(capture.counts.groups, 21);
  assert.equal(capture.counts.callbacks, 25);
  assert.equal(capture.counts.httpBearingCallbacks, 22);
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('a fresh CLI capture exactly reproduces independent module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-minimax-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
