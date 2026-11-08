// Ordinary successful pinned-source callbacks; all transport and policy are fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { captureGeminiSearch, unframeGeminiSearchText } from './capture-gemini-search.mjs';

const root = process.env.OPENCLAW_GEMINI_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_GEMINI_FIXTURE;
const capture = await captureGeminiSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const group = id => {
  const result = capture.groups.find(row => row.id === id);
  assert.ok(result, id);
  return result;
};
const first = id => group(id).steps[0];
const allSteps = () => capture.groups.flatMap(row => row.steps);
const plain = value => JSON.parse(JSON.stringify(value));
const withoutCache = value => {
  const copy = plain(value);
  delete copy.cached;
  return copy;
};
const googleSearch = step => step.request.body.tools[0].google_search;
const requestText = step => step.request.body.contents[0].parts[0].text;

test('retains whole unchanged pinned modules, all58558 tracked blobs, full TypeBox and license', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, process.version);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  for (const path of [
    'extensions/google/src/gemini-web-search-provider.ts',
    'extensions/google/src/gemini-web-search-provider.runtime.ts',
    'extensions/google/src/google-api-base-url.ts', 'extensions/google/google-api-client-header.ts',
    'src/agents/tools/web-search-citation-redirect.ts', 'src/agents/tools/web-search-output.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/config/plugin-web-search-config.ts', 'src/agents/tools/common.ts',
    'src/agents/tools/web-shared.ts', 'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts',
    'src/plugin-sdk/provider-web-search-config-contract.ts',
    'src/plugin-sdk/provider-web-search-contract-fields.ts', 'src/plugin-sdk/provider-web-search-schema.ts',
    'src/security/external-content.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const path of ['src/agents/tools/web-guarded-fetch.ts',
    'src/agents/provider-request-config.ts', 'src/agents/provider-attribution.ts',
    'extensions/google/provider-policy.ts', 'src/agents/provider-http-errors.ts',
    'src/agents/provider-request-header-redaction.ts', 'src/config/types.secrets.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, false, path);
  }
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
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-gemini-search.mjs', import.meta.url))));
  assert.equal(capture.harnessDependencies[0].sha256,
    digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))));
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.typebox.files.length, 372);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256,
    digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.path);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
});

test('audits explicit fixtures and deferred services without claiming production policy or transport', () => {
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked',
    'actualProviderRequestBuilder', 'actualBaseUrlHelper', 'actualClientHeaderHelper',
    'actualCountReaders', 'actualTimeFilters', 'actualSourceCache', 'actualCitationRedirectHelper',
    'genericNormalizerInvoked', 'actualUnwrapInvoked', 'actualTypeBox']) {
    assert.equal(capture.boundaries[key], true, key);
  }
  for (const key of ['bodyProjections', 'actualRequestHeaderPolicy', 'actualBoundedSuccessReader',
    'actualEndpointPolicy', 'actualCredentialResolution', 'productionNetworkInvoked',
    'pluginRegistrationInvoked']) assert.equal(capture.boundaries[key], false, key);
  assert.deepEqual(capture.boundaries.fixtureEnvironment, {});
  for (const name of ['withTrustedWebToolsEndpoint', 'withStrictWebToolsEndpoint',
    'readProviderJsonObjectResponse', 'resolveProviderRequestHeaders']) {
    assert.ok(capture.stubs.some(row => row.export === name && row.kind === 'ordinary-platform-fixture'), name);
  }
  assert.ok(capture.stubs.some(row => row.export === 'readConfiguredSecretString'
    && row.kind === 'literal-config-fixture'));
  assert.ok(capture.stubs.some(row => row.export === 'readProviderEnvValue'
    && row.kind === 'environment-absence-fixture'));
  for (const name of ['createProviderHttpError', 'ProviderHttpError', 'truncateErrorDetail',
    'normalizeResolvedSecretInputString', 'formatWebSearchNotConfiguredMessage', 'detectMime']) {
    assert.ok(capture.stubs.some(row => row.export === name && row.behavior === 'throws if invoked'), name);
  }
  assert.equal(capture.stubs.some(row => row.export === 'resolveCitationRedirectUrl'), false);
  assert.ok(capture.aliases.some(row => row.importer === 'src/agents/tools/web-search-citation-redirect.ts'
    && row.specifier === './web-guarded-fetch.js' && row.kind === 'explicit-successful-endpoint-fixture'));
  assert.ok(capture.aliases.some(row => row.importer === 'extensions/google/google-api-client-header.ts'
    && row.specifier === './provider-policy.js'));
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false, row.id);
    const httpCount = row.steps.filter(item => item.request !== null).length;
    for (const kind of ['successful-http-fixture', 'successful-json-fixture',
      'successful-endpoint-fixture-completed', 'request-header-policy-fixture']) {
      assert.equal(row.audit.filter(item => item.kind === kind).length, httpCount, row.id + ':' + kind);
    }
    assert.equal(row.audit.filter(item => item.kind === 'literal-config-fixture'
      && item.export === 'readConfiguredSecretString').length, row.steps.length, row.id);
    assert.equal(row.audit.some(item => item.kind === 'environment-absence-fixture'), false, row.id);
    assert.ok(row.audit.some(item => item.kind === 'dynamic-import'
      && item.specifier.endsWith('gemini-web-search-provider.runtime.js')), row.id);
    assert.deepEqual(row.setupAfter, row.setup);
    for (const item of row.steps) {
      assert.deepEqual(item.argumentsAfter, item.arguments);
      assert.deepEqual(item.setupAfter, item.setup);
      assert.equal(item.providerResult.provider, 'gemini');
      assert.equal(item.genericResult.kind, 'answer');
      assert.equal(item.genericResult.query, item.arguments.query);
      assert.deepEqual(item.genericResult.externalContent,
        { untrusted: true, source: 'web_search', wrapped: true, provider: 'gemini' });
      assert.equal(Object.hasOwn(item.providerPortableResult, 'externalContent'), false);
      assert.equal(Object.hasOwn(item.genericPortableResult, 'externalContent'), false);
      assert.equal(Object.hasOwn(item.genericResult, 'model'), false);
      assert.deepEqual(item.publicResult, item.genericResult);
      assert.deepEqual(item.publicUnwrappedResult, item.genericUnwrappedResult);
      assert.deepEqual(item.publicPortableResult, item.genericPortableResult);
      assert.equal(item.genericPortableResult.content, item.providerPortableResult.content.trim());
      assert.equal(item.providerUnwrappedResult.content, item.providerPortableResult.content.trim());
      assert.equal(item.cacheHit, item.providerResult.cached === true);
      assert.equal(item.providerCached, item.cacheHit);
      assert.equal(item.genericCached, item.cacheHit);
    }
  }
});

test('constructs exact source descriptor with unsupported country/language metadata and time fields', () => {
  const row = group('search-default');
  assert.equal(row.providerMetadata.id, 'gemini');
  assert.equal(row.providerMetadata.label, 'Gemini (Google Search)');
  assert.deepEqual(row.providerMetadata.onboardingScopes, ['text-inference']);
  assert.deepEqual(row.providerMetadata.envVars, ['GEMINI_API_KEY']);
  assert.equal(row.providerMetadata.autoDetectOrder, 20);
  assert.equal(row.providerMetadata.credentialPath, 'plugins.entries.google.config.webSearch.apiKey');
  assert.deepEqual(row.descriptor, {
    description: 'Search the web using Gemini with Google Search grounding. Returns AI-synthesized answers with citations from Google Search.',
    parameters: { type: 'object', properties: {
      query: { type: 'string', description: 'Search query string.' },
      count: { type: 'integer', description: 'Number of results to return (1-10).', minimum: 1, maximum: 10 },
      country: { type: 'string', description: 'Not supported by Gemini.' },
      language: { type: 'string', description: 'Not supported by Gemini.' },
      freshness: { type: 'string', description: 'Filter Gemini search freshness: week, month, and year use hard Google Search time ranges; day prioritizes the last 24 hours as a recency hint.' },
      date_after: { type: 'string', description: 'Only ground with results published after this date (YYYY-MM-DD).' },
      date_before: { type: 'string', description: 'Only ground with results published before this date (YYYY-MM-DD).' },
    }, required: ['query'] },
  });
});

test('builds generateContent POST with source default/custom model and ordinary normalized roots', () => {
  const expected = [
    ['search-default', 'https://generativelanguage.googleapis.com/v1beta'],
    ['official-root', 'https://generativelanguage.googleapis.com/v1beta'],
    ['official-trailing-slashes', 'https://generativelanguage.googleapis.com/v1beta'],
    ['custom-prefix', 'https://proxy.example/gemini/v1beta'],
    ['custom-root', 'https://proxy.example'],
    ['model-base-url', 'https://model-proxy.example/google'],
    ['plugin-base-precedence', 'https://plugin-proxy.example/search'],
  ];
  for (const [id, base] of expected) {
    assert.equal(first(id).request.url, base + '/models/gemini-3.6-flash:generateContent', id);
    assert.equal(first(id).providerPortableResult.model, 'gemini-3.6-flash', id);
  }
  const custom = first('custom-model');
  assert.equal(custom.providerResult.model, 'gemini-3.1-pro-preview');
  assert.equal(custom.request.url,
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent');
  for (const item of allSteps().filter(item => item.request !== null)) {
    assert.equal(item.request.method, 'POST');
    assert.deepEqual(item.request.query, {});
    assert.deepEqual(Object.keys(item.request.body), ['contents', 'tools']);
    assert.deepEqual(JSON.parse(item.request.bodyText), item.request.body);
    assert.equal(item.request.headers['content-type'], 'application/json');
    assert.equal(item.request.headers['x-goog-api-key'], 'fixture-gemini-key');
    assert.equal(item.request.signalSupplied, false);
    assert.equal(item.request.timeoutSeconds, item.setup.searchConfig.timeoutSeconds ?? 30);
    assert.equal(item.providerResult.tookMs, 7);
    assert.equal(item.genericResult.tookMs, 7);
  }
  assert.equal(first('configured-timeout').request.timeoutSeconds, 9);
});

test('executes source client-header wrapper over named fixture policy and ordinary operator headers', () => {
  for (const id of ['search-default', 'official-root', 'official-trailing-slashes']) {
    assert.equal(first(id).request.headers['x-goog-api-client'], 'openclaw/fixture-gemini-policy');
  }
  for (const id of ['custom-prefix', 'custom-root', 'model-base-url', 'plugin-base-precedence']) {
    assert.equal(Object.hasOwn(first(id).request.headers, 'x-goog-api-client'), false);
  }
  assert.equal(first('ordinary-headers').request.headers['x-search-workspace'], 'ordinary workspace');
  assert.equal(first('ordinary-headers').request.headers['x-request-route'], 'search');
  const receipt = group('ordinary-headers').audit.find(item => item.kind === 'request-header-policy-fixture');
  assert.deepEqual(receipt.parameters, { provider: 'google', api: 'google-generative-ai',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta', capability: 'other', transport: 'http' });
});

test('validates ordinary count tokens while ignoring count in request/output and preserving authored query', () => {
  for (const id of ['search-default', 'explicit-count', 'numeric-count-token', 'configured-count-ignored']) {
    const item = first(id);
    assert.deepEqual(item.request.body, { contents: [{ parts: [{ text: item.arguments.query.trim() }] }],
      tools: [{ google_search: {} }] }, id);
    assert.equal(Object.hasOwn(item.providerResult, 'count'), false, id);
    assert.equal(Object.hasOwn(item.genericResult, 'count'), false, id);
  }
  assert.equal(first('explicit-count').arguments.count, 4);
  assert.equal(first('numeric-count-token').arguments.count, ' 3 ');
  assert.equal(group('configured-count-ignored').setup.searchConfig.maxResults, 2);
  const authored = first('authored-query');
  assert.equal(requestText(authored), 'OpenClaw site:github.com "release notes"');
  assert.equal(authored.providerPortableResult.query, authored.arguments.query.trim());
  assert.equal(authored.genericPortableResult.query, authored.arguments.query);
});

test('uses day recency hint and hard week/month/year second-precision ranges including aliases', () => {
  const hint = 'Prioritize web sources published in the last 24 hours.';
  for (const value of ['day', 'pd']) {
    const item = first('freshness-' + value);
    assert.deepEqual(googleSearch(item), {});
    assert.equal(requestText(item), item.arguments.query
      + '\n\nSearch recency instruction: ' + hint
      + ' If no matching recent sources are available, state that limitation and use the most relevant available sources.');
  }
  for (const [names, startTime] of [
    [['week', 'pw'], '2026-10-20T12:00:00Z'],
    [['month', 'pm'], '2026-09-27T12:00:00Z'],
    [['year', 'py'], '2025-10-27T12:00:00Z'],
  ]) for (const name of names) {
    const item = first('freshness-' + name);
    assert.deepEqual(googleSearch(item), { timeRangeFilter: { startTime, endTime: '2026-10-27T12:00:00Z' } });
    assert.equal(requestText(item), item.arguments.query);
  }
  const fractional = first('freshness-second-precision');
  assert.equal(fractional.clock, '2026-10-27T12:00:00.789Z');
  assert.deepEqual(googleSearch(fractional), { timeRangeFilter: {
    startTime: '2026-10-20T12:00:00Z', endTime: '2026-10-27T12:00:00Z',
  } });
});

test('normalizes ordinary explicit dates and sends inclusive before date as next-day exclusive end', () => {
  for (const [id, startTime, endTime] of [
    ['date-after', '2026-10-12T00:00:00Z', '2026-10-27T12:00:00Z'],
    ['date-before', '1970-01-01T00:00:00Z', '2026-10-19T00:00:00Z'],
    ['date-both', '2026-10-12T00:00:00Z', '2026-10-19T00:00:00Z'],
    ['date-accepted-slash-format', '2026-10-12T00:00:00Z', '2026-10-19T00:00:00Z'],
  ]) {
    const item = first(id);
    assert.deepEqual(googleSearch(item), { timeRangeFilter: { startTime, endTime } }, id);
    assert.equal(requestText(item), item.arguments.query);
  }
});

test('source cache reuses normalized query/filter identity and deliberately ignores count', () => {
  for (const id of ['same-query-repeated', 'count-only-cache', 'freshness-alias-cache', 'date-format-cache']) {
    const [initial, ...repeated] = group(id).steps;
    assert.equal(initial.cacheHit, false, id);
    assert.ok(initial.request, id);
    assert.equal(initial.providerResult.tookMs, 7, id);
    for (const item of repeated) {
      assert.equal(item.cacheHit, true, id);
      assert.equal(item.request, null, id);
      assert.deepEqual(item.headRequests, [], id);
      assert.equal(item.cumulativeRequests, 1, id);
      assert.equal(item.cumulativeHeadRequests, initial.headRequests.length, id);
      assert.deepEqual(withoutCache(item.providerPortableResult), initial.providerPortableResult, id);
      assert.deepEqual(withoutCache(item.genericPortableResult), {
        ...initial.genericPortableResult, query: item.arguments.query,
      }, id);
      assert.equal(item.clockAfter, item.clock, id);
    }
  }
  assert.deepEqual(group('count-only-cache').steps.map(item => item.arguments.count), [2, ' 4 ', undefined]);
});

test('source request cache distinguishes model/base/header identity and reuses returning original setup', () => {
  for (const id of ['model-request-identity', 'base-request-identity', 'header-request-identity']) {
    const [initial, changed, returning] = group(id).steps;
    assert.deepEqual([initial.cacheHit, changed.cacheHit, returning.cacheHit], [false, false, true], id);
    assert.deepEqual([initial.cumulativeRequests, changed.cumulativeRequests, returning.cumulativeRequests], [1, 2, 2], id);
    assert.ok(initial.request, id);
    assert.ok(changed.request, id);
    assert.equal(returning.request, null, id);
    assert.deepEqual(returning.headRequests, [], id);
    assert.deepEqual(withoutCache(returning.providerPortableResult), initial.providerPortableResult, id);
  }
  const model = group('model-request-identity').steps;
  assert.notEqual(model[0].request.url, model[1].request.url);
  assert.notEqual(model[0].providerResult.model, model[1].providerResult.model);
  const base = group('base-request-identity').steps;
  assert.notEqual(base[0].request.url, base[1].request.url);
  const headers = group('header-request-identity').steps;
  assert.equal(headers[0].request.url, headers[1].request.url);
  assert.equal(headers[0].request.headers['x-search-route'], 'one');
  assert.equal(headers[1].request.headers['x-search-route'], 'two');
});

test('executes actual redirect helper for every ordered citation and records requested HEAD deadlines', () => {
  for (const row of capture.groups) for (const item of row.steps) {
    const chunks = row.httpPayload.candidates[0].groundingMetadata?.groundingChunks ?? [];
    const raw = chunks.map(chunk => chunk.web);
    assert.ok(raw.length < 10, row.id);
    if (item.cacheHit) {
      assert.deepEqual(item.headRequests, [], row.id);
      continue;
    }
    assert.deepEqual(item.headRequests, raw.map(web => ({ url: web.uri, method: 'HEAD',
      timeoutMs: 5000, finalUrl: row.redirectMap[web.uri] ?? web.uri })), row.id);
    assert.deepEqual(item.providerPortableResult.citations, raw.map(web => ({
      url: row.redirectMap[web.uri] ?? web.uri,
      ...(typeof web.title === 'string' ? { title: web.title } : {}),
    })), row.id);
    const parts = row.httpPayload.candidates[0].content.parts;
    assert.equal(item.providerPortableResult.content, parts.map(part => part.text).join('\n'), row.id);
    assert.equal(unframeGeminiSearchText(item.providerResult.content), item.providerPortableResult.content, row.id);
    assert.equal(item.genericPortableResult.citations.length, raw.length, row.id);
  }
  const row = group('ordered-answer-citations');
  assert.equal(row.audit.filter(item => item.kind === 'successful-head-fixture').length, 4);
  const item = row.steps[0];
  assert.deepEqual(item.headRequests.map(request => request.url), [
    'https://grounding.example/one', 'https://grounding.example/two',
    'https://grounding.example/one', 'https://grounding.example/three',
  ]);
  assert.deepEqual(item.providerPortableResult.citations, [
    { url: 'https://publisher.example/article', title: ' First source ' },
    { url: 'https://grounding.example/two' },
    { url: 'https://publisher.example/article', title: ' Duplicate source ' },
    { url: 'https://third.example/news', title: 'Third source' },
  ]);
  assert.deepEqual(item.genericPortableResult.citations, [
    { url: 'https://publisher.example/article', title: 'First source' },
    { url: 'https://grounding.example/two' },
    { url: 'https://publisher.example/article', title: 'Duplicate source' },
    { url: 'https://third.example/news', title: 'Third source' },
  ]);
});

test('keeps full provider answer/model separately from source-unwrapped closed generic answer', () => {
  const item = first('ordered-answer-citations');
  const content = ' First ordinary paragraph. \nSecond ordinary paragraph.\n Third ordinary paragraph. ';
  assert.deepEqual(item.providerPortableResult, {
    query: 'ordered grounded answer', provider: 'gemini', model: 'gemini-3.6-flash', tookMs: 7,
    content, citations: [
      { url: 'https://publisher.example/article', title: ' First source ' },
      { url: 'https://grounding.example/two' },
      { url: 'https://publisher.example/article', title: ' Duplicate source ' },
      { url: 'https://third.example/news', title: 'Third source' },
    ],
  });
  assert.deepEqual(item.genericPortableResult, {
    kind: 'answer', provider: 'gemini', query: 'ordered grounded answer', tookMs: 7,
    content: content.trim(), citations: [
      { url: 'https://publisher.example/article', title: 'First source' },
      { url: 'https://grounding.example/two' },
      { url: 'https://publisher.example/article', title: 'Duplicate source' },
      { url: 'https://third.example/news', title: 'Third source' },
    ],
  });
  assert.match(item.providerResult.content, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.match(item.genericResult.content, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  assert.equal(item.providerResult.citations[0].title, ' First source ');
  assert.match(item.genericResult.citations[0].title, /<<<EXTERNAL_UNTRUSTED_CONTENT/);
  const noCitations = first('answer-without-citations');
  assert.deepEqual(noCitations.providerPortableResult.citations, []);
  assert.deepEqual(noCitations.genericPortableResult.citations, []);
  assert.deepEqual(noCitations.headRequests, []);
});

test('captures only short ordinary successful matrix and compares supplied final fixture', () => {
  assert.equal(capture.counts.groups, 36);
  assert.equal(capture.counts.callbacks, 47);
  assert.equal(capture.counts.httpBearingCallbacks, 39);
  assert.equal(capture.counts.cacheHitCallbacks, 8);
  assert.equal(capture.counts.headRequests, 78);
  assert.equal(new Set(capture.groups.map(row => row.id)).size, 36);
  for (const item of allSteps()) {
    assert.equal(Object.hasOwn(item.providerResult, 'error'), false);
    assert.equal(Object.hasOwn(item.genericResult, 'truncated'), false);
    assert.ok(item.arguments.query.length < 100);
    assert.ok(item.providerPortableResult.content.length < 300);
    assert.ok(item.providerResult.citations.length < 10);
    assert.equal(Object.hasOwn(item.arguments, 'country'), false);
    assert.equal(Object.hasOwn(item.arguments, 'language'), false);
  }
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});

test('independent fresh CLI capture reproduces module capture and supplied final fixture exactly', () => {
  const cli = execFileSync(process.execPath, ['--experimental-vm-modules',
    fileURLToPath(new URL('./capture-gemini-search.mjs', import.meta.url)), root], {
    encoding: 'utf8', timeout: 180_000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, NODE_NO_WARNINGS: '1' },
  });
  const fresh = JSON.parse(cli);
  assert.deepEqual(fresh, capture);
  if (fixture) assert.deepEqual(fresh, JSON.parse(readFileSync(fixture, 'utf8')));
});
