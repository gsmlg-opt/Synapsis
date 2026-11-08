// Independent ordinary expectations; successful platform services are fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureGrokSearch, unframeGrokSearchText } from './capture-grok-search.mjs';

const root = process.env.OPENCLAW_GROK_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_GROK_FIXTURE
  ?? fileURLToPath(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/grok-search.json', import.meta.url));
const capture = await captureGrokSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => { const row = capture.groups.find(item => item.id === id); assert.ok(row, id); return row; };
const first = id => group(id).steps[0];
const allSteps = () => capture.groups.flatMap(row => row.steps);
const withoutCache = value => { const copy = { ...value }; delete copy.cached; return copy; };
const stamp = { untrusted: true, source: 'web_search', provider: 'grok', wrapped: true };
const frame = text => '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n'
  + text + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
const canonicalModel = new Map([
  ['grok-4.3', 'grok-4.3'], ['grok-4.6', 'grok-4.6'], ['grok-4.7-latest', 'grok-4.7'],
  ['grok-4.20', 'grok-4.20'], ['grok-4-fast', 'grok-4-fast'], ['grok-latest', 'grok-latest'],
  ['grok-code-fast', 'grok-build-0.1'], ['grok-4-fast-reasoning', 'grok-4-fast'],
  ['grok-custom-search', 'grok-custom-search'], ['grok-4.7', 'grok-4.7'],
]);
const endpoints = new Map([
  ['official-base', 'https://api.x.ai/v1/responses'], ['official-root', 'https://api.x.ai/responses'],
  ['official-trailing-slashes', 'https://api.x.ai/v1/responses'],
  ['custom-root', 'https://proxy.example/responses'], ['custom-prefix', 'https://proxy.example/grok/v2/responses'],
  ['full-responses-endpoint', 'https://proxy.example/v1/responses/responses'],
]);
const parsedAnswers = new Map([
  ['ordered-answer-citations', { content: ' First ordinary paragraph. Second ordinary paragraph. Third ordinary paragraph. ',
    citations: ['https://source.example/one', 'https://source.example/three'] }],
  ['annotation-citation-order', { content: 'First second.', citations: ['https://source.example/two', 'https://source.example/one'] }],
  ['ordinary-canonical-citations', { content: 'Canonical ordinary answer.',
    citations: ['https://source.example/ordinary', 'https://bare.example'] }],
  ['output-text-fallback', { content: ' Ordinary fallback answer. ', citations: [] }],
  ['direct-output-text', { content: 'Direct ordinary answer.', citations: [] }],
  ['answer-without-citations', { content: 'Ordinary answer without citations.', citations: [] }],
  ['inline-ordinary-utf16', { content: 'A😀BC', citations: ['https://source.example/one'],
    inlineCitations: [{ start_index: 1, end_index: 3, url: 'https://source.example/one' },
      { start_index: 3, end_index: 5, url: 'https://source.example/two' }] }],
  ['inline-ordered-citations', { content: 'First ordinary answer.', citations: ['https://source.example/one'],
    inlineCitations: [{ start_index: 0, end_index: 5, url: 'https://source.example/one' },
      { start_index: 6, end_index: 14, url: 'https://source.example/two' }] }],
]);
const defaultAnswer = { content: ' Ordinary web answer. ', citations: ['https://source.example/one'] };

function expectedEndpoint(row, item) {
  if (endpoints.has(row.id)) return endpoints.get(row.id);
  const base = item.setup.config.plugins.entries.xai.config.webSearch.baseUrl;
  return base ? base.trim().replace(/\/+$/, '') + '/responses' : 'https://api.x.ai/v1/responses';
}
function expectedModel(item) {
  const model = item.setup.config.plugins.entries.xai.config.webSearch.model?.trim() ?? 'grok-4.7';
  assert.ok(canonicalModel.has(model), model); return canonicalModel.get(model);
}
function expectedAnswer(row, item) {
  const answer = parsedAnswers.get(row.id) ?? defaultAnswer;
  const inline = item.setup.config.plugins.entries.xai.config.webSearch.inlineCitations === true;
  return { content: answer.content, citations: [...answer.citations],
    ...(inline ? { inlineCitations: answer.inlineCitations ?? [
      { start_index: 1, end_index: 9, url: 'https://source.example/one' },
    ] } : {}) };
}

test('verifies every tracked pinned blob, executable source, SDK target, TypeBox graph, harness and license', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/xai/web-search.ts', 'extensions/xai/web-search-provider-shared.ts',
    'extensions/xai/src/web-search-provider.runtime.ts', 'extensions/xai/src/web-search-shared.ts',
    'extensions/xai/src/responses-tool-shared.ts', 'extensions/xai/src/tool-config-shared.ts',
    'extensions/xai/model-definitions.ts', 'extensions/xai/model-id.ts', 'extensions/xai/runtime-model-compat.ts',
    'extensions/xai/model-compat.ts', 'extensions/xai/provider-routing.ts', 'src/plugins/provider-model-compat.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-search-provider-config.ts', 'src/config/plugin-web-search-config.ts',
    'src/config/web-search-legacy-provider-keys.ts', 'src/agents/tools/common.ts', 'src/agents/tools/web-shared.ts',
    'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts', 'packages/normalization-core/src/node-crypto.ts',
    'src/plugin-sdk/provider-web-search-config-contract.ts', 'src/plugin-sdk/provider-web-search-contract-fields.ts',
    'src/plugin-sdk/provider-web-search-schema.ts', 'src/security/external-content.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const path of ['src/agents/tools/web-guarded-fetch.ts', 'src/agents/provider-http-errors.ts',
    'src/utils/fetch-timeout.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
    'src/agents/tools/web-search-provider-credentials.ts', 'src/config/types.secrets.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, false, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.gitBlob, blob(bytes), row.path);
    assert.equal(row.executableSha256, digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true);
  }
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.license.sha256, digest(capture.license.text));
  assert.equal(capture.license.gitBlob, blob(Buffer.from(capture.license.text)));
  assert.match(capture.license.text, /MIT License/);
  assert.equal(capture.manifest.sha256, digest(readFileSync(join(root, capture.manifest.path))));
  assert.equal(capture.manifest.gitBlob, blob(readFileSync(join(root, capture.manifest.path))));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-grok-search.mjs', import.meta.url))));
  assert.equal(capture.harnessDependencies[0].sha256, digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))));
  for (const row of capture.facades) {
    assert.equal(row.sha256, digest(row.generatedCode));
    assert.ok(capture.sources.some(source => source.path === row.provenance), row.provenance);
    for (const match of row.generatedCode.matchAll(/capture:source:([^";]+)/g)) {
      assert.equal(capture.sources.find(source => source.path === match[1])?.executed, true, match[1]);
    }
  }
  assert.equal(capture.typebox.version, '1.3.37'); assert.equal(capture.typebox.files.length, 372);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('audits the successful service fixtures and keeps platform/host qualification explicitly deferred', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked', 'actualProviderRequestBuilder',
    'actualBaseUrlHelper', 'actualCountReaders', 'actualConfigMerge', 'actualModelNormalization', 'actualModelReasoning',
    'actualSourceCache', 'genericNormalizerInvoked', 'actualUnwrapInvoked', 'actualTypeBox']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'actualBoundedSuccessReader', 'actualEndpointPolicy', 'actualCredentialResolution',
    'actualDeadline', 'productionNetworkInvoked', 'pluginRegistrationInvoked', 'hostInstalled']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const name of ['withTrustedWebToolsEndpoint', 'readProviderJsonObjectResponse', 'buildTimeoutAbortSignal',
    'resolveApiKeyForProvider', 'resolveWebSearchProviderCredential']) assert.ok(capture.stubs.some(row => row.export === name
      && row.kind === 'ordinary-platform-fixture'), name);
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    const requests = row.steps.filter(item => item.request !== null).length;
    assert.equal(row.audit.filter(item => item.kind === 'successful-http-fixture').length, requests, row.id);
    assert.equal(row.audit.filter(item => item.kind === 'successful-json-fixture').length, requests, row.id);
    for (const kind of ['successful-timeout-fixture', 'timeout-cleanup', 'provider-auth-success-fixture',
      'configured-literal-key-fixture']) assert.equal(row.audit.filter(item => item.kind === kind).length, row.steps.length, row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import' && item.specifier === './src/web-search-provider.runtime.js'), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    const timeouts = row.audit.filter(item => item.kind === 'successful-timeout-fixture');
    assert.deepEqual(timeouts, row.steps.map(item => ({ kind: 'successful-timeout-fixture',
      timeoutMs: (item.setup.searchConfig.timeoutSeconds ?? 60) * 1000, operation: 'xAI web search' })));
  }
});

test('constructs the exact Grok metadata and actual query/count schema with no required field', () => {
  assert.deepEqual(group('search-default').providerMetadata, {
    id: 'grok', label: 'Grok (xAI)', hint: 'Uses xAI OAuth or API key · xAI web-grounded responses',
    onboardingScopes: ['text-inference'], credentialLabel: 'xAI API key', envVars: ['XAI_API_KEY'],
    authProviderId: 'xai', placeholder: 'xai-...', signupUrl: 'https://console.x.ai/',
    docsUrl: 'https://docs.openclaw.ai/tools/web', autoDetectOrder: 30,
    credentialPath: 'plugins.entries.xai.config.webSearch.apiKey',
  });
  const descriptor = { description: 'Search the web using xAI Grok. Returns AI-synthesized answers with citations from real-time web search.',
    parameters: { type: 'object', properties: {
      query: { type: 'string', description: 'Search query string.' },
      count: { type: 'number', description: 'Number of results to return (1-10).', minimum: 1, maximum: 10 },
    }, additionalProperties: false } };
  for (const row of capture.groups) assert.deepEqual(row.descriptor, descriptor, row.id);
});

test('builds complete ordinary Responses request maps with default/custom/alias model reasoning and endpoint semantics', () => {
  for (const row of capture.groups) for (const item of row.steps) {
    if (item.request === null) continue;
    const model = expectedModel(item), reasoning = ['grok-4.3', 'grok-4.6', 'grok-4.7'].includes(model);
    const body = { model, input: [{ role: 'user', content: item.arguments.query.trim() }],
      tools: [{ type: 'web_search' }], store: false, ...(reasoning ? { reasoning: { effort: 'low' } } : {}) };
    const url = expectedEndpoint(row, item);
    assert.deepEqual(item.request, { url, method: 'POST', path: new URL(url).pathname, query: {},
      body, bodyText: JSON.stringify(body), headers: { accept: 'application/json', authorization: 'Bearer fixture-grok-key',
        'content-type': 'application/json' }, timeoutSeconds: item.setup.searchConfig.timeoutSeconds ?? 60,
      signalSupplied: false }, row.id);
  }
  assert.equal(first('configured-timeout').request.timeoutSeconds, 9);
  assert.equal(first('model-grok-4.7-latest').request.body.model, 'grok-4.7');
  assert.equal(first('model-grok-code-fast').request.body.model, 'grok-build-0.1');
  assert.equal(first('full-responses-endpoint').request.url, 'https://proxy.example/v1/responses/responses');
});

test('checks full provider/framed/unwrapped/portable and generic result maps for every ordinary callback', () => {
  for (const row of capture.groups) {
    const originals = new Map();
    for (const item of row.steps) {
      const model = expectedModel(item), inline = item.setup.config.plugins.entries.xai.config.webSearch.inlineCitations === true;
      const identity = JSON.stringify([expectedEndpoint(row, item), model, inline, item.arguments.query.trim()]);
      const cacheEnabled = item.setup.searchConfig.cacheTtlMinutes !== 0;
      const earlier = cacheEnabled ? originals.get(identity) : undefined, answer = expectedAnswer(row, item);
      const expected = earlier ?? { query: item.arguments.query.trim(), provider: 'grok', model, tookMs: 7, ...answer };
      if (!earlier && cacheEnabled) originals.set(identity, expected);
      const provider = { ...expected, ...(earlier ? { cached: true } : {}) };
      const generic = { kind: 'answer', provider: 'grok', query: item.arguments.query, tookMs: 7,
        content: expected.content.trim(), citations: expected.citations.map(url => ({ url: new URL(url).href })),
        ...(earlier ? { cached: true } : {}) };
      assert.deepEqual(item.argumentsAfter, item.arguments, row.id); assert.deepEqual(item.setupAfter, item.setup, row.id);
      assert.deepEqual(item.providerPortableResult, provider, row.id);
      assert.deepEqual(item.providerResult, { ...provider, content: frame(expected.content), externalContent: stamp }, row.id);
      assert.deepEqual(item.providerUnwrappedResult, { ...provider, content: expected.content.trim(), externalContent: stamp }, row.id);
      assert.deepEqual(item.genericPortableResult, generic, row.id);
      assert.deepEqual(item.genericResult, { ...generic, content: frame(generic.content), externalContent: stamp }, row.id);
      assert.deepEqual(item.genericUnwrappedResult, { ...generic, externalContent: stamp }, row.id);
      assert.deepEqual(item.publicResult, item.genericResult, row.id);
      assert.deepEqual(item.publicUnwrappedResult, item.genericUnwrappedResult, row.id);
      assert.deepEqual(item.publicPortableResult, generic, row.id);
      assert.equal(unframeGrokSearchText(item.providerResult.content), expected.content);
      assert.equal(item.cacheHit, Boolean(earlier), row.id);
      assert.equal(item.request === null, Boolean(earlier), row.id);
      assert.equal(item.clockAfter, new Date(Date.parse(item.clock) + (earlier ? 0 : 7)).toISOString(), row.id);
    }
  }
});

test('validates then ignores ordinary count and retains authored public query separately from trimmed provider query', () => {
  assert.equal(first('explicit-count').arguments.count, 4);
  assert.equal(first('numeric-count-token').arguments.count, ' 3 ');
  assert.equal(group('configured-count-ignored').setup.searchConfig.maxResults, 2);
  for (const id of ['explicit-count', 'numeric-count-token', 'configured-count-ignored']) {
    const item = first(id);
    assert.equal(Object.hasOwn(item.request.body, 'count'), false);
    assert.equal(Object.hasOwn(item.providerResult, 'count'), false);
    assert.equal(Object.hasOwn(item.genericResult, 'count'), false);
  }
  const authored = first('authored-query');
  assert.equal(authored.providerPortableResult.query, 'OpenClaw site:github.com "release notes"');
  assert.equal(authored.genericPortableResult.query, ' OpenClaw site:github.com "release notes" ');
});

test('observes case-sensitive source identity, outer-space equivalence, count omission and original entry reuse', () => {
  const expectations = new Map([
    ['same-query-repeated', [false, true]], ['count-only-cache', [false, true, true]],
    ['query-case-identity', [false, false, true]], ['query-interior-space-identity', [false, false, true]],
    ['model-request-identity', [false, false, true]], ['base-request-identity', [false, false, true]],
    ['base-case-identity', [false, false, true]], ['inline-request-identity', [false, false, true]],
    ['model-alias-cache', [false, true]], ['cache-off-on', [false, false, true]],
  ]);
  for (const [id, hits] of expectations) {
    const row = group(id); assert.deepEqual(row.steps.map(item => item.cacheHit), hits, id);
    let requests = 0;
    for (const [n, item] of row.steps.entries()) {
      if (!hits[n]) requests++;
      assert.equal(item.cumulativeRequests, requests, id);
      if (hits[n]) {
        assert.equal(item.request, null, id);
        assert.deepEqual(withoutCache(item.providerPortableResult), row.steps[0].providerPortableResult, id);
      }
    }
  }
  assert.notEqual(group('query-case-identity').steps[0].request.body.input[0].content,
    group('query-case-identity').steps[1].request.body.input[0].content);
  assert.notEqual(group('base-case-identity').steps[0].request.url, group('base-case-identity').steps[1].request.url);
});

test('ordinary ordered blocks/top citations/annotation fallback/duplicates and inline retention have distinct generic maps', () => {
  assert.equal(first('ordered-answer-citations').providerPortableResult.content,
    ' First ordinary paragraph. Second ordinary paragraph. Third ordinary paragraph. ');
  assert.deepEqual(first('ordered-answer-citations').providerPortableResult.citations,
    ['https://source.example/one', 'https://source.example/three']);
  assert.deepEqual(first('annotation-citation-order').providerPortableResult.citations,
    ['https://source.example/two', 'https://source.example/one']);
  assert.deepEqual(first('ordinary-canonical-citations').genericPortableResult.citations,
    [{ url: 'https://source.example/ordinary' }, { url: 'https://bare.example/' }]);
  assert.equal(Object.hasOwn(first('inline-disabled').providerResult, 'inlineCitations'), false);
  assert.deepEqual(first('inline-enabled').providerPortableResult.inlineCitations,
    [{ start_index: 1, end_index: 9, url: 'https://source.example/one' }]);
  assert.equal(Object.hasOwn(first('inline-enabled').genericResult, 'inlineCitations'), false);
  assert.equal(Object.hasOwn(first('inline-enabled').genericResult, 'model'), false);
  const utf16 = first('inline-ordinary-utf16').providerPortableResult;
  assert.equal(utf16.content.length, 5);
  assert.equal(utf16.content.slice(1, 3), '😀');
  assert.equal(utf16.content.slice(3, 5), 'BC');
  assert.deepEqual(utf16.inlineCitations, parsedAnswers.get('inline-ordinary-utf16').inlineCitations);
});

test('qualifies only short ordinary successful matrix and exact final fixture', () => {
  assert.equal(capture.counts.groups, 41); assert.equal(capture.counts.callbacks, 59);
  assert.equal(capture.counts.httpBearingCallbacks, 48); assert.equal(capture.counts.cacheHitCallbacks, 11);
  assert.equal(new Set(capture.groups.map(row => row.id)).size, 41);
  assert.equal(allSteps().length, 59);
  for (const row of capture.groups) {
    assert.ok((row.httpPayload.citations?.length ?? 0) < 10);
    assert.ok((row.httpPayload.inline_citations?.length ?? 0) < 10);
    for (const item of row.steps) {
      assert.ok(item.arguments.query.length < 100); assert.ok(item.providerPortableResult.content.length < 300);
      assert.ok(item.providerResult.citations.length < 10);
      assert.equal(Object.hasOwn(item.providerResult, 'error'), false);
      assert.equal(Object.hasOwn(item.genericResult, 'truncated'), false);
    }
  }
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('independent fresh CLI equals module capture and supplied final fixture exactly', () => {
  const fresh = JSON.parse(execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-grok-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 180_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  }));
  assert.deepEqual(fresh, capture);
  assert.deepEqual(fresh, JSON.parse(readFileSync(fixture, 'utf8')));
});
