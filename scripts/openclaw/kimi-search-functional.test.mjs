// Ordinary successful source callbacks; no network or production assembly acceptance.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureKimiSearch } from './capture-kimi-search.mjs';

const root = process.env.OPENCLAW_KIMI_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_KIMI_FIXTURE;
const capture = await captureKimiSearch(root);
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

test('retains complete pinned source, Git blob, dependency, manifest and license provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/moonshot/src/kimi-web-search-provider.ts',
    'extensions/moonshot/src/kimi-web-search-provider.runtime.ts',
    'extensions/moonshot/provider-catalog.ts', 'extensions/moonshot/provider-policy-api.ts',
    'src/agents/provider-request-config.ts', 'src/plugins/provider-catalog.ts',
    'packages/model-catalog-core/src/model-catalog-refs.ts',
    'packages/model-catalog-core/src/provider-id.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/agents/tools/common.ts', 'src/shared/lazy-runtime.ts',
    'src/plugin-sdk/provider-web-search-config-contract.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256,
      digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true, row.path);
  }
  assert.deepEqual(capture.dataSources.map(row => row.path), ['extensions/moonshot/openclaw.plugin.json']);
  for (const row of capture.dataSources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sha256, digest(bytes));
    assert.equal(row.gitBlob, blob(bytes));
  }
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.match(capture.license.text, /MIT License/);
  for (const row of capture.facades) assert.equal(row.sha256, digest(row.generatedCode));
  assert.equal(capture.typebox.version, '1.3.37');
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('labels whole-source execution and synthetic platform boundaries separately', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualSharedEndpoint', 'actualSharedCache',
    'actualNormalizeBaseUrl', 'actualMoonshotPolicy', 'actualManifestDefaultRef',
    'genericNormalizerInvoked']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'productionNetworkInvoked',
    'pluginRegistrationInvoked']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-http-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-json-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier.endsWith('kimi-web-search-provider.runtime.js')), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.equal(step.providerResult.provider, 'kimi');
      assert.equal(step.publicResult.kind, 'results');
      assert.equal(step.publicResult.query, step.arguments.query);
      assert.deepEqual(step.publicResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'kimi' });
    }
  }
});

test('constructs the original Kimi factory descriptor and query/count schema', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'kimi');
  assert.equal(row.providerMetadata.label, 'Kimi (Moonshot)');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.equal(row.providerMetadata.autoDetectOrder, 40);
  assert.deepEqual(Object.keys(row.descriptor.parameters.properties),
    ['query', 'count', 'country', 'language', 'freshness', 'date_after', 'date_before']);
  assert.equal(row.descriptor.parameters.properties.query.type, 'string');
  assert.equal(row.descriptor.parameters.properties.count.type, 'integer');
  assert.equal(row.descriptor.parameters.properties.count.minimum, 1);
  assert.equal(row.descriptor.parameters.properties.count.maximum, 10);
  assert.match(row.descriptor.description, /Kimi by Moonshot/);
});

test('records actual POST serialization and ordinary count/timeout readers', () => {
  const normal = first('search-default');
  assert.equal(normal.request.url, 'https://api.moonshot.ai/v1/tools/search');
  assert.equal(normal.request.method, 'POST');
  assert.equal(normal.request.path, '/v1/tools/search');
  assert.deepEqual(normal.request.query, {});
  assert.deepEqual(normal.request.body, { text_query: 'search-default', limit: 5 });
  assert.deepEqual(JSON.parse(normal.request.bodyText), normal.request.body);
  assert.equal(normal.request.timeoutSeconds, 30);
  assert.equal(normal.providerResult.tookMs, 7);
  assert.equal(first('configured-count').request.body.limit, 2);
  assert.equal(first('configured-count-string').request.body.limit, 5);
  assert.equal(first('explicit-count').request.body.limit, 4);
  assert.equal(first('numeric-count-token').request.body.limit, 3);
  assert.equal(first('configured-timeout').request.timeoutSeconds, 7);
});

test('executes Moonshot region selection and actual base URL normalization', () => {
  for (const id of ['search-default', 'endpoint-model-ai']) {
    assert.equal(first(id).request.url, 'https://api.moonshot.ai/v1/tools/search');
  }
  for (const id of ['endpoint-model-cn', 'endpoint-explicit-cn']) {
    assert.equal(first(id).request.url, 'https://api.moonshot.cn/v1/tools/search');
  }
  for (const id of ['endpoint-custom', 'endpoint-trailing-slashes']) {
    assert.equal(first(id).request.url, 'https://proxy.example/moonshot/v1/tools/search');
  }
});

test('keeps authored public queries while the real private reader trims ordinary operators and Unicode', () => {
  for (const id of ['operator-query', 'unicode-query']) {
    const step = first(id);
    assert.equal(step.request.body.text_query, step.arguments.query.trim());
    assert.equal(step.providerResult.query, step.arguments.query.trim());
    assert.equal(step.publicPortableResult.query, step.arguments.query);
  }
  assert.match(first('operator-query').request.body.text_query, /site:github.com -site:archive.example lang:en/);
  assert.equal(first('unicode-query').request.body.text_query, '界😀e\u0301 👩‍💻 ordinary search');
});

test('maps ordered descriptions, exact dates and URL-derived sites through actual output normalization', () => {
  const step = first('ordered-metadata');
  const providerRows = [
    { title: 'First 😀', url: 'https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world',
      description: 'First description 文', published: '2026-10-17', siteName: 'www.source.example' },
    { title: 'Second', url: 'https://two.example', description: 'Second description',
      published: '2026-10-18', siteName: 'two.example' },
    { title: 'Third', url: 'https://three.example/ordinary', description: 'Third description', siteName: 'three.example' },
  ];
  assert.deepEqual(withoutTime(step.providerPortableResult), {
    query: 'ordered source results', provider: 'kimi', count: 3, results: providerRows,
  });
  const publicRows = providerRows.map(({ description, ...row }) => ({
    ...row, url: new URL(row.url).href, snippet: description,
  }));
  assert.deepEqual(withoutTime(step.publicPortableResult), {
    kind: 'results', query: 'ordered source results', provider: 'kimi', count: 3, results: publicRows,
  });
  assert.match(step.providerResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.match(step.providerResult.results[0].description, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.match(step.publicResult.results[0].snippet, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.deepEqual(Object.keys(step.providerResult.results[0]), ['title', 'url', 'description', 'published', 'siteName']);
});

test('accepts sparse ordinary result rows and successful empty results', () => {
  const step = first('sparse-results');
  assert.deepEqual(step.providerPortableResult.results, [
    { title: '', url: 'https://sparse.example/one', description: '', siteName: 'sparse.example' },
    { title: 'Title only', url: 'https://sparse.example/two', description: '', siteName: 'sparse.example' },
    { title: '', url: 'https://sparse.example/three', description: 'Description only', published: '2026-10-19', siteName: 'sparse.example' },
  ]);
  assert.deepEqual(step.publicPortableResult.results, step.providerPortableResult.results.map(({ description, ...row }) => ({ ...row, snippet: description })));
  assert.deepEqual(withoutTime(first('successful-empty').publicPortableResult), {
    kind: 'results', provider: 'kimi', query: 'successful-empty', count: 0, results: [],
  });
});

test('reuses actual source cache for successful repeated results and empty results', () => {
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
});

test('fresh complete capture equals frozen fixture when supplied', () => {
  assert.equal(capture.counts.groups, 18);
  assert.equal(capture.counts.callbacks, 20);
  assert.equal(capture.counts.httpBearingCallbacks, 18);
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('a fresh CLI capture exactly reproduces independent module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-kimi-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
