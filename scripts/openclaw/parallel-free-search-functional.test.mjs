// Ordinary pinned free callbacks. Parent executes this suite; no real network.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureParallelFreeSearch } from './capture-parallel-free-search.mjs';

const root = process.env.OPENCLAW_PARALLEL_FREE_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_PARALLEL_FREE_FIXTURE;
const capture = await captureParallelFreeSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => {
  const result = capture.groups.find(row => row.id === id);
  assert.ok(result, id);
  return result;
};
const first = id => group(id).steps[0];
const toolArgs = id => first(id).request.body.params.arguments;
const without = (value, ...keys) => Object.fromEntries(Object.entries(value)
  .filter(([key]) => !keys.includes(key)));

test('verifies entire pinned checkout, complete modules, license and harness dependency hashes', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.equal(capture.checkout.before.verified, true);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/parallel/src/parallel-free-web-search-provider.ts',
    'extensions/parallel/src/parallel-free-web-search-provider.runtime.ts',
    'extensions/parallel/src/parallel-web-search-provider.ts',
    'extensions/parallel/src/parallel-search-normalize.ts',
    'extensions/parallel/src/parallel-free-web-search-provider.shared.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/agents/tools/web-shared.ts', 'src/agents/tools/common.ts',
    'src/agents/tools/web-search-output.ts', 'src/security/external-content.ts',
    'src/utils.ts', 'src/infra/plain-object.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.wholeModule, true, row.path);
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256,
      digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
  }
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.match(capture.license.text, /MIT License/);
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.equal(capture.harness.sha256,
    digest(readFileSync(new URL('./capture-parallel-free-search.mjs', import.meta.url))));
  for (const dependency of capture.harnessDependencies) assert.equal(dependency.sha256,
    digest(readFileSync(new URL('../../' + dependency.path, import.meta.url))), dependency.path);
  for (const facade of capture.facades) assert.equal(facade.sha256, digest(facade.generatedCode));
});

test('loads actual pinned TypeBox and records explicit ordinary platform fixtures', () => {
  assert.equal(capture.typebox.version, '1.3.37');
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  assert.ok(capture.typebox.files.length > 1);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  const bytes = readFileSync(join(root, capture.pluginFixture.path));
  assert.equal(capture.pluginFixture.gitBlob, blob(bytes));
  assert.equal(capture.pluginFixture.sha256, digest(bytes));
  assert.equal(capture.pluginFixture.version, '2026.10.5');
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualSharedCache', 'actualMcpSerializerParser', 'actualJsonParser'])
    assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'productionNetworkInvoked',
    'actualPluginVersionDiscovery', 'pluginRegistrationInvoked']) assert.equal(capture.boundaries[key], false, key);
  assert.ok(capture.stubs.some(row => row.export === 'readProviderTextResponse' && row.kind === 'ordinary-platform-fixture'));
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'successful-text-reader-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'plugin-version-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'literal-config-dir-fixture'), row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier.endsWith('parallel-free-web-search-provider.runtime.js')), row.id);
  }
});

test('free factory advertises exact imported paid schema with free session bound and descriptor', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'parallel-free');
  assert.equal(row.providerMetadata.label, 'Parallel Search (Free)');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.equal(row.descriptor.parameters.properties.session_id.maxLength, 100);
  assert.equal(row.descriptor.parameters.properties.client_model.maxLength, 100);
  assert.equal(row.descriptor.parameters.properties.objective.maxLength, 5000);
  assert.equal(row.descriptor.parameters.properties.search_queries.maxItems, 5);
  assert.equal(row.descriptor.parameters.properties.count.maximum, 40);
  assert.deepEqual(row.descriptor.parameters.required, ['objective', 'search_queries']);
  assert.equal(row.descriptor.parameters.additionalProperties, false);
  assert.match(row.descriptor.description, /Parallel's free Search MCP/);
  assert.match(row.descriptor.description, /prior result's `sessionId`/);
});

test('serializes initialize, initialized notification and tracked tool call for every uncached callback', () => {
  for (const row of capture.groups) for (const step of row.steps) {
    assert.deepEqual(step.argumentsAfter, step.arguments);
    assert.deepEqual(step.setupAfter, step.setup);
    assert.equal(step.requests.length, step.cached ? 0 : 3, row.id);
    if (step.cached) { assert.equal(step.request, null); continue; }
    assert.deepEqual(step.requests.map(request => request.body.method),
      ['initialize', 'notifications/initialized', 'tools/call']);
    const [init, notification, call] = step.requests;
    assert.deepEqual(init.body.params, { protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'openclaw-parallel', version: '2026.10.5' } });
    assert.equal(init.body.jsonrpc, '2.0');
    assert.deepEqual(notification.body, { jsonrpc: '2.0', method: 'notifications/initialized' });
    assert.equal(call.body.params.name, 'web_search');
    assert.equal(call.body.jsonrpc, '2.0');
    assert.notEqual(init.body.id, call.body.id);
    assert.equal(call.body.params.arguments.session_id, step.searchSessionId);
    assert.notEqual(step.searchSessionId, init.body.id);
    assert.notEqual(step.searchSessionId, call.body.id);
    assert.equal(Object.hasOwn(call.body.params.arguments, 'count'), false);
    assert.equal(Object.hasOwn(call.body.params.arguments, 'client_model'), false);
    assert.deepEqual(step.request, call);
    for (const request of step.requests) {
      assert.equal(request.url, 'https://search.parallel.ai/mcp');
      assert.equal(request.method, 'POST');
      assert.equal(request.path, '/mcp');
      assert.equal(request.bodyText, JSON.stringify(request.body));
      assert.equal(request.headers['User-Agent'], capture.pluginFixture.userAgent);
      assert.equal(request.headers.Accept, 'application/json, text/event-stream');
      assert.equal(request.headers['Content-Type'], 'application/json');
      assert.equal(request.response.status, 200);
    }
    assert.equal(step.providerResult.tookMs, 21);
  }
});

test('echoes only assigned MCP transport sessions and supported negotiated versions', () => {
  for (const row of capture.groups) for (const step of row.steps.filter(item => !item.cached)) {
    const [init, notification, call] = step.requests;
    assert.equal(Object.hasOwn(init.headers, 'Mcp-Session-Id'), false);
    assert.equal(Object.hasOwn(init.headers, 'MCP-Protocol-Version'), false);
    for (const request of [notification, call]) {
      if (row.serverRecipe.transportSessionId === null)
        assert.equal(Object.hasOwn(request.headers, 'Mcp-Session-Id'), false);
      else assert.equal(request.headers['Mcp-Session-Id'], row.serverRecipe.transportSessionId);
      assert.equal(request.headers['MCP-Protocol-Version'], row.serverRecipe.protocolVersion);
    }
    assert.notEqual(step.searchSessionId, row.serverRecipe.transportSessionId);
  }
  assert.equal(group('stateless-server').serverRecipe.transportSessionId, null);
  assert.equal(first('negotiated-version').requests[2].headers['MCP-Protocol-Version'], '2025-03-26');
});

test('normalizes ordinary objective, query pairs, optional model and supplied search session', () => {
  assert.equal(toolArgs('normalized-pair').objective, 'Understand ordinary research 文');
  assert.deepEqual(toolArgs('normalized-pair').search_queries, ['first keyword phrase', 'second keyword phrase']);
  assert.equal(toolArgs('unicode-pair').objective, '界😀e\u0301 👩‍💻 ordinary objective');
  assert.deepEqual(toolArgs('unicode-pair').search_queries, ['界😀e\u0301 research', '👩‍💻 ordinary sources']);
  assert.equal(toolArgs('optional-context').session_id, 'prior-session-文');
  assert.equal(toolArgs('optional-context').model_name, 'gpt-6-astra');
  assert.equal(first('optional-context').providerResult.sessionId, 'prior-session-文');
  assert.equal(Object.hasOwn(toolArgs('search-default'), 'model_name'), false);
});

test('uses ordinary keyword-only and CLI query fallbacks without altering authored arguments', () => {
  assert.equal(toolArgs('keywords-only').objective, 'first keyword phrase second keyword phrase');
  assert.equal(Object.hasOwn(first('keywords-only').providerResult, 'objective'), false);
  assert.equal(toolArgs('cli-query-fallback').objective, 'ordinary CLI query 文');
  assert.deepEqual(toolArgs('cli-query-fallback').search_queries, ['ordinary CLI query 文']);
  assert.equal(toolArgs('cli-query-with-objective').objective, 'CLI research objective');
  assert.deepEqual(toolArgs('cli-query-with-objective').search_queries, ['CLI keyword phrase']);
  assert.deepEqual(toolArgs('query-with-pair').search_queries, ['ordinary keyword research', 'alternate keyword sources']);
  assert.equal(first('query-with-pair').genericResult.query, ' authored generic query ');
});

test('applies ordinary result counts locally and passes configured timeout to all three requests', () => {
  assert.equal(first('search-default').providerResult.count, 5);
  assert.equal(first('configured-count').providerResult.count, 2);
  assert.equal(first('explicit-count').providerResult.count, 4);
  assert.equal(first('optional-context').providerResult.count, 3);
  for (const request of first('configured-timeout').requests) assert.equal(request.timeoutSeconds, 7);
  for (const row of capture.groups) for (const step of row.steps) {
    assert.ok(step.providerResult.count < 10);
    assert.ok(row.httpPayload.results.length < 10);
  }
});

test('prefers structured content and accepts successful JSON text fallback', () => {
  const priority = first('structured-content-priority');
  assert.equal(priority.providerResult.searchId, group('structured-content-priority').httpPayload.search_id);
  assert.equal(priority.providerPortableResult.results[0].title, ' Source 1 😀 ');
  const envelope = priority.request.response.envelope;
  assert.ok(envelope.result.structuredContent);
  assert.equal(JSON.parse(envelope.result.content[0].text).search_id, 'unused-text-search');
  const fallback = first('json-text-fallback');
  assert.equal(Object.hasOwn(fallback.request.response.envelope.result, 'structuredContent'), false);
  assert.equal(fallback.providerResult.searchId, group('json-text-fallback').httpPayload.search_id);
  assert.equal(fallback.providerPortableResult.results[0].title, ' Source 1 😀 ');
});

test('parses valid ordinary POST SSE and multiline SSE through unchanged source parser', () => {
  for (const id of ['post-sse', 'post-sse-multiline']) {
    const step = first(id);
    for (const request of [step.requests[0], step.requests[2]]) {
      assert.equal(request.response.headers['content-type'], 'text/event-stream');
      assert.match(request.response.bodyText, /^event: message\ndata: /);
    }
    assert.equal(step.providerResult.searchId, group(id).httpPayload.search_id);
    assert.equal(step.providerPortableResult.results[0].title, ' Source 1 😀 ');
    assert.equal(step.requests[1].response.bodyText, '');
  }
  assert.match(first('post-sse-multiline').request.response.bodyText, /data: \{\ndata:   /);
});

test('preserves full raw frames, metadata and unframed body whitespace separately from generic output', () => {
  const step = first('ordered-metadata');
  const result = step.providerPortableResult;
  assert.equal(result.searchId, ' raw-search-id ');
  assert.equal(result.sessionId, step.searchSessionId);
  assert.deepEqual(result.warnings, group('ordered-metadata').httpPayload.warnings);
  assert.deepEqual(result.usage, group('ordered-metadata').httpPayload.usage);
  assert.equal(result.results[0].title, ' First 😀 ');
  assert.equal(result.results[0].url, ' https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world ');
  assert.equal(result.results[0].published, ' 2026-10-17 ');
  assert.deepEqual(result.results[0].excerpts, [' First paragraph 文 ', '\n Second paragraph 😀 \n']);
  assert.equal(result.results[0].description, ' First paragraph 文 \n\n\n Second paragraph 😀 \n');
  assert.match(step.providerResult.results[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.equal(step.providerUnwrappedResult.results[0].title, 'First 😀');
  assert.equal(step.genericResult.kind, 'results');
  assert.equal(step.genericResult.query, '');
  for (const key of ['searchId', 'sessionId', 'warnings', 'usage', 'objective', 'searchQueries'])
    assert.equal(Object.hasOwn(step.genericResult, key), false, key);
  assert.equal(Object.hasOwn(step.genericResult.results[0], 'excerpts'), false);
  assert.equal(Object.hasOwn(result, 'externalContent'), false);
  assert.equal(Object.hasOwn(step.genericPortableResult, 'externalContent'), false);
});

test('reuses ordinary generated-session, supplied-session and empty caches with correct session ownership', () => {
  for (const id of ['same-cache-generated-session', 'same-cache-supplied-session', 'empty-cache-reuse']) {
    const [a, b] = group(id).steps;
    assert.deepEqual([a.cached, b.cached], [false, true]);
    assert.deepEqual([a.requests.length, b.requests.length], [3, 0]);
    assert.deepEqual(without(b.providerPortableResult, 'cached', 'sessionId'),
      without(a.providerPortableResult, 'sessionId'));
  }
  assert.equal(Object.hasOwn(group('same-cache-generated-session').steps[1].providerResult, 'sessionId'), false);
  assert.equal(group('same-cache-supplied-session').steps[1].providerResult.sessionId, 'supplied-session');
  for (const id of ['successful-empty', 'successful-empty-minimal', 'empty-cache-reuse']) {
    assert.deepEqual(first(id).providerResult.results, []);
    assert.equal(first(id).providerResult.count, 0);
  }
});

test('keeps query order, objective, count, model and supplied search session in cache identity', () => {
  for (const id of ['count-cache-identity', 'objective-cache-identity', 'queries-cache-identity',
    'query-order-cache-identity', 'session-cache-identity', 'client-model-cache-identity']) {
    const [a, b, c] = group(id).steps;
    assert.deepEqual([a.cached, b.cached, c.cached], [false, false, true], id);
    assert.deepEqual([a.requests.length, b.requests.length, c.requests.length], [3, 3, 0], id);
    assert.deepEqual(without(c.providerPortableResult, 'cached'), without(a.providerPortableResult, 'sessionId'), id);
    assert.notDeepEqual(a.request.body.params.arguments, b.request.body.params.arguments, id);
  }
});

test('freezes ordinary observation counts and optional checked fixture without claiming host transport acceptance', () => {
  assert.equal(capture.counts.groups, 29);
  assert.equal(capture.counts.callbacks, 44);
  assert.equal(capture.counts.httpBearingCallbacks, 35);
  assert.equal(capture.counts.requests, 105);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
  assert.ok(capture.boundaries.limits.some(text => text.includes('Backplane strict envelope/version')));
  assert.ok(capture.boundaries.limits.some(text => text.includes('generic10')));
  assert.equal(capture.runtime, process.version);
  if (fixture) assert.deepEqual(JSON.parse(readFileSync(fixture, 'utf8')), capture);
});

test('fresh CLI capture exactly reproduces independent whole-module execution', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-parallel-free-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  assert.deepEqual(JSON.parse(cli), capture);
});
