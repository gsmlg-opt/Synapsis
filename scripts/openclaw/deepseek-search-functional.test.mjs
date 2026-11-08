// Ordinary successful source callbacks; no network or production assembly acceptance.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureDeepseekSearch } from './capture-deepseek-search.mjs';

const root = process.env.OPENCLAW_DEEPSEEK_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_DEEPSEEK_FIXTURE;
const capture = await captureDeepseekSearch(root);
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

test('retains complete pinned source, Git blob, dependency and license provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/deepseek/web-search-provider.ts',
    'extensions/deepseek/web-search-provider.runtime.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/agents/tools/common.ts', 'src/shared/lazy-runtime.ts',
    'src/plugin-sdk/provider-web-search-contract.ts',
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
  assert.equal(capture.typebox.version, '1.3.37');
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('labels actual whole-source execution and synthetic platform boundaries separately', () => {
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.factoryInvoked, true);
  assert.equal(capture.boundaries.publicCallbackInvoked, true);
  assert.equal(capture.boundaries.actualCommonPost, true);
  assert.equal(capture.boundaries.actualSharedCache, true);
  assert.equal(capture.boundaries.genericNormalizerInvoked, true);
  assert.equal(capture.boundaries.actualBoundedSuccessReader, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  assert.equal(capture.boundaries.pluginRegistrationInvoked, false);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-http-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-json-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier.endsWith('web-search-provider.runtime.js')), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      assert.equal(step.providerResult.provider, 'deepseek');
      assert.equal(step.publicResult.kind, 'results');
      assert.equal(step.publicResult.query, step.arguments.query);
      assert.deepEqual(step.publicResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'deepseek' });
    }
  }
});

test('constructs the model-facing DeepSeek provider and original query/count schema', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'deepseek');
  assert.equal(row.providerMetadata.label, 'DeepSeek');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.deepEqual(Object.keys(row.descriptor.parameters.properties), ['query', 'count']);
  assert.deepEqual(row.descriptor.parameters.required, ['query']);
  assert.equal(row.descriptor.parameters.properties.query.minLength, 1);
  assert.equal(row.descriptor.parameters.properties.query.maxLength, 128);
  assert.equal(row.descriptor.parameters.properties.count.type, 'integer');
  assert.equal(row.descriptor.parameters.properties.count.minimum, 1);
  assert.equal(row.descriptor.parameters.properties.count.maximum, 10);
  assert.match(row.descriptor.description, /site:/);
});

test('uses the actual POST request builder and successful default/configured/explicit counts', () => {
  const normal = first('search-default');
  assert.equal(normal.request.url, 'https://api.deepseek.com/v1/tools/search');
  assert.equal(normal.request.method, 'POST');
  assert.equal(normal.request.path, '/v1/tools/search');
  assert.deepEqual(normal.request.query, {});
  assert.deepEqual(normal.request.body, { query: 'search-default', count: 5, need_content: false });
  assert.deepEqual(JSON.parse(normal.request.bodyText), normal.request.body);
  assert.equal(normal.request.timeoutSeconds, 30);
  assert.equal(normal.providerResult.tookMs, 7);
  assert.equal(first('configured-count').request.body.count, 2);
  assert.equal(first('explicit-count').request.body.count, 4);
  assert.equal(first('configured-timeout').request.timeoutSeconds, 7);
});

test('preserves ordinary operators and Unicode while keeping authored public queries', () => {
  for (const id of ['operator-query', 'unicode-query']) {
    const step = first(id);
    assert.equal(step.request.body.query, step.arguments.query.trim());
    assert.equal(step.providerResult.query, step.arguments.query.trim());
    assert.equal(step.publicPortableResult.query, step.arguments.query);
  }
  assert.match(first('operator-query').request.body.query, /site:github.com -site:archive.example lang:en/);
  assert.equal(first('unicode-query').request.body.query, '界😀e\u0301 👩‍💻 ordinary search');
});

test('maps ordered summaries and snippet fallback with ordinary normalized URLs and metadata', () => {
  const step = first('ordered-metadata');
  const expected = [
    { title: 'First 😀', url: 'https://source.example/ordinary?q=hello%20world',
      snippet: 'Model summary', published: '2026-10-17T00:00:00+00:00', siteName: 'Journal 文' },
    { title: 'Second', url: 'https://two.example/', snippet: 'UI fallback',
      published: '2026-10-18', siteName: 'Second site' },
    { title: 'Third', url: 'https://three.example/ordinary', snippet: 'Third summary' },
  ];
  assert.deepEqual(withoutTime(step.providerPortableResult), {
    query: 'ordered source results', provider: 'deepseek', count: 3, results: expected,
  });
  assert.deepEqual(withoutTime(step.publicPortableResult), {
    kind: 'results', query: 'ordered source results', provider: 'deepseek', count: 3, results: expected,
  });
  assert.match(step.publicResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.deepEqual(Object.keys(step.providerResult.results[0]), ['title', 'url', 'snippet', 'published', 'siteName']);
});

test('returns successful empty results and reuses actual source cache for ordinary repeated queries', () => {
  assert.deepEqual(withoutTime(first('successful-empty').publicPortableResult), {
    kind: 'results', provider: 'deepseek', query: 'successful-empty', count: 0, results: [],
  });
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

test('fresh complete capture equals the frozen source fixture when supplied', () => {
  assert.equal(capture.counts.groups, 10);
  assert.equal(capture.counts.callbacks, 12);
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('a fresh CLI capture exactly reproduces independent module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-deepseek-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
