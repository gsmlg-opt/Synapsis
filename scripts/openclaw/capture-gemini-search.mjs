// Ordinary Gemini callbacks from complete unchanged pinned OpenClaw modules.
// Successful HTTP/JSON, literal configuration, request policy and clock are fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/google/src/gemini-web-search-provider.ts';
const runtime = 'extensions/google/src/gemini-web-search-provider.runtime.ts';
const baseUrlHelper = 'extensions/google/src/google-api-base-url.ts';
const clientHeaders = 'extensions/google/google-api-client-header.ts';
const citationRedirect = 'src/agents/tools/web-search-citation-redirect.ts';
const guardedFetch = 'src/agents/tools/web-guarded-fetch.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const extraSources = new Set([factory, runtime, baseUrlHelper, clientHeaders, citationRedirect, output]);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'buildSearchCacheKey', 'buildUnsupportedSearchFilterResponse',
      'MAX_SEARCH_COUNT', 'parseWebSearchTimeFilters', 'readCachedSearchPayload',
      'resolveSearchCacheTtlMs', 'resolveSearchTimeoutSeconds', 'withTrustedWebSearchEndpoint',
      'writeCachedSearchPayload'], common),
    from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
    from(['resolveCitationRedirectUrl'], citationRedirect),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
    'export {readConfiguredSecretString,readProviderEnvValue} from "gemini:literal-config";',
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
    from(['isRecord'], normalization + 'record-coerce.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: [
    'export {readProviderJsonObjectResponse,resolveProviderRequestHeaders} from "gemini:platform";',
    'export {createProviderHttpError,formatProviderHttpErrorMessage,ProviderHttpError,',
    'redactProviderResponseErrorText,truncateErrorDetail} from "gemini:unused-http-errors";',
  ].join('\n'),
  [sdk + 'secret-input-runtime']: 'export {normalizeResolvedSecretInputString} from "gemini:unused-secret-resolution";',
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};

class GeminiCapture extends BraveCapture {
  constructor(root, payload, redirectMap = {}) {
    super(root);
    this.payload = payload;
    this.redirectMap = redirectMap;
    this.headRequests = [];
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    this.context.Headers = Headers;
  }

  source(path) {
    if (!extraSources.has(path)) return super.source(path);
    if (!this.modules.has(path)) this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
      context: this.context, identifier: path,
      importModuleDynamically: async specifier => {
        this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
        const target = this.import(specifier, path);
        await this.evaluate(target);
        return target;
      },
    }));
    return this.modules.get(path);
  }

  typeboxModule(file) {
    assert.ok(file === this.typeboxRoot || file.startsWith(this.typeboxRoot + sep));
    const id = 'gemini:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file);
      const path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }

  platform() {
    const bindings = {
      withTrustedWebToolsEndpoint: async (params, run) => {
        this.audit.push({ kind: 'successful-http-fixture', timeoutSeconds: params.timeoutSeconds });
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), body: JSON.parse(params.init.body),
          bodyText: params.init.body, headers: Object.fromEntries(new Headers(params.init.headers)),
          timeoutSeconds: params.timeoutSeconds, signalSupplied: params.signal !== undefined });
        this.nowMs += 7;
        const result = await run({ response: Response.json(plain(this.payload)), finalUrl: params.url });
        this.audit.push({ kind: 'successful-endpoint-fixture-completed' });
        return result;
      },
      withStrictWebToolsEndpoint: async (params, run) => {
        const finalUrl = this.redirectMap[params.url] ?? params.url;
        const request = { url: params.url, method: params.init.method, timeoutMs: params.timeoutMs, finalUrl };
        this.headRequests.push(request);
        this.audit.push({ kind: 'successful-head-fixture', ...request });
        return await run({ finalUrl });
      },
      readProviderJsonObjectResponse: async (response, label) => {
        this.audit.push({ kind: 'successful-json-fixture', label });
        return response.json();
      },
      resolveProviderRequestHeaders: params => {
        // This named policy fixture is deliberately not production endpoint classification.
        const headers = params.baseUrl === 'https://generativelanguage.googleapis.com/v1beta'
          ? { 'x-goog-api-client': 'openclaw/fixture-gemini-policy' } : undefined;
        this.audit.push({ kind: 'request-header-policy-fixture', parameters: plain(params),
          headers: headers ?? null });
        return headers;
      },
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records source POST, headers, body and requested timeout; synthetic successful Response and clock+7ms; production guards, release, network and deadlines unexecuted',
      withStrictWebToolsEndpoint: 'successful HEAD finalUrl mapping only; records all ordered calls and requested5000ms; production strict URL guard, redirects, network and deadlines unexecuted',
      readProviderJsonObjectResponse: 'successful fixture Response.json; production bounded JSON parser and error checks unexecuted',
      resolveProviderRequestHeaders: 'explicit ordinary request-header policy fixture: fixed x-goog-api-client for exact default official root, absent for custom roots; production policy/configuration/attribution unexecuted',
    };
    return this.synthetic('gemini:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  literalConfig() {
    const bindings = {
      readConfiguredSecretString: (value, path) => {
        this.audit.push({ kind: 'literal-config-fixture', export: 'readConfiguredSecretString', path,
          valueKind: typeof value });
        assert.equal(typeof value, 'string', 'only explicit ordinary literal fixture key');
        assert.equal(value, 'fixture-gemini-key');
        return value;
      },
      readProviderEnvValue: () => {
        this.audit.push({ kind: 'environment-absence-fixture', export: 'readProviderEnvValue' });
        return undefined;
      },
    };
    return this.synthetic('gemini:literal-config', bindings, {
      readConfiguredSecretString: { kind: 'literal-config-fixture',
        behavior: 'only explicit fake ordinary literal key; production credential normalization/resolution and SecretRef APIs unexecuted' },
      readProviderEnvValue: { kind: 'environment-absence-fixture',
        behavior: 'fixed absence; VM process.env is empty; production ambient environment discovery unexecuted' },
    });
  }

  facade(specifier, importer, provenance, generatedCode) {
    this.verifiedSource(provenance, false);
    const id = 'gemini:facade:' + specifier;
    this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
    this.aliases.set(`${importer}:${specifier}`, { importer, specifier,
      kind: 'whole-module-re-export-or-explicit-platform-facade', target: id });
    if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode,
      { context: this.context, identifier: id }));
    return this.modules.get(id);
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    const deferred = (path, names) => {
      this.verifiedSource(path, false);
      link('unused-platform-service', path);
      return this.deferred(importer, specifier, names);
    };
    if (specifier === 'gemini:platform') {
      this.verifiedSource('src/agents/provider-request-config.ts', false);
      this.verifiedSource('src/agents/provider-attribution.ts', false);
      return this.platform();
    }
    if (specifier === 'gemini:literal-config') {
      this.verifiedSource('src/secrets/provider-credential-values.ts', false);
      return this.literalConfig();
    }
    if (specifier === 'gemini:unused-http-errors') {
      this.verifiedSource('src/agents/provider-request-header-redaction.ts', false);
      return deferred('src/agents/provider-http-errors.ts', ['createProviderHttpError',
        'formatProviderHttpErrorMessage', 'ProviderHttpError', 'redactProviderResponseErrorText', 'truncateErrorDetail']);
    }
    if (specifier === 'gemini:unused-secret-resolution') {
      return deferred('src/config/types.secrets.ts', ['normalizeResolvedSecretInputString']);
    }
    if ([common, citationRedirect].includes(importer) && specifier === './web-guarded-fetch.js') {
      this.verifiedSource(guardedFetch, false);
      link('explicit-successful-endpoint-fixture', 'gemini:platform');
      return this.platform();
    }
    if (importer === clientHeaders && specifier === './provider-policy.js') {
      return this.facade(specifier, importer, 'extensions/google/provider-policy.ts',
        from(['DEFAULT_GOOGLE_API_BASE_URL'], baseUrlHelper));
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      return deferred('src/web-search/runtime-error.ts', ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve('typebox'));
      let root = dirname(file);
      while (!existsSync(join(root, 'package.json')) && dirname(root) !== root) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json'));
      const pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox');
      assert.equal(pkg.version, '1.3.37');
      this.typeboxRoot = root;
      this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file));
      return this.typeboxModule(file);
    }
    if (importer.startsWith('gemini:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('gemini:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) return this.facade(specifier, importer, specifier.startsWith(sdk)
      ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts', facades[specifier]);
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN])
    .split('\0').filter(Boolean).map(entry => {
      const [header, path] = entry.split('\t');
      const [mode, type, gitBlob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
      const file = join(root, path);
      const symlink = lstatSync(file).isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      assert.ok(realpathSync(file).startsWith(root + sep));
      const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(blob(bytes), gitBlob, path);
      return { path, gitBlob, sha256: digest(bytes) };
    });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN,
    tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}

const ordinaryPayload = () => ({ candidates: [{
  content: { parts: [{ text: ' Ordinary grounded answer. ' }] },
  groundingMetadata: { groundingChunks: [
    { web: { uri: 'https://source.example/ordinary', title: ' Ordinary source ' } },
    { web: { uri: 'https://source.example/second' } },
  ] },
}] });
const step = (args, options = {}) => ({ arguments: args, ...options });
function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) => rows.push({ id,
    steps: [step(args)], httpPayload: ordinaryPayload(), redirectMap: {}, ...options });
  add('search-default');
  add('authored-query', { query: ' OpenClaw site:github.com "release notes" ' });
  add('explicit-count', { query: 'ordinary explicit count', count: 4 });
  add('numeric-count-token', { query: 'ordinary numeric count', count: ' 3 ' });
  add('configured-count-ignored', undefined, { searchConfig: { maxResults: 2 } });
  add('configured-timeout', undefined, { searchConfig: { timeoutSeconds: 9 } });
  add('custom-model', undefined, { providerConfig: { model: ' gemini-3.1-pro-preview ' } });
  add('official-root', undefined, { providerConfig: { baseUrl: 'https://generativelanguage.googleapis.com/' } });
  add('official-trailing-slashes', undefined, { providerConfig: {
    baseUrl: ' https://generativelanguage.googleapis.com/v1beta/// ',
  } });
  add('custom-prefix', undefined, { providerConfig: { baseUrl: 'https://proxy.example/gemini/v1beta///' } });
  add('custom-root', undefined, { providerConfig: { baseUrl: 'https://proxy.example/' } });
  add('model-base-url', undefined, { modelConfig: { baseUrl: 'https://model-proxy.example/google/' } });
  add('plugin-base-precedence', undefined, { providerConfig: { baseUrl: 'https://plugin-proxy.example/search/' },
    modelConfig: { baseUrl: 'https://model-proxy.example/unused/' } });
  add('ordinary-headers', undefined, { providerConfig: {
    headers: { 'X-Search-Workspace': ' ordinary workspace ', 'X-Request-Route': 'search' },
  } });
  for (const freshness of ['day', 'week', 'month', 'year', 'pd', 'pw', 'pm', 'py']) {
    add('freshness-' + freshness, { query: 'ordinary freshness ' + freshness, freshness });
  }
  add('freshness-second-precision', { query: 'ordinary second precision', freshness: 'week' }, {
    steps: [step({ query: 'ordinary second precision', freshness: 'week' },
      { clock: '2026-10-27T12:00:00.789Z' })],
  });
  add('date-after', { query: 'ordinary after date', date_after: '2026-10-12' });
  add('date-before', { query: 'ordinary before date', date_before: '2026-10-18' });
  add('date-both', { query: 'ordinary date range', date_after: '2026-10-12', date_before: '2026-10-18' });
  add('date-accepted-slash-format', { query: 'ordinary slash date range', date_after: '10/12/2026', date_before: '10/18/2026' });
  add('same-query-repeated', undefined, { steps: [
    step({ query: ' same ordinary query ' }), step({ query: 'same ordinary query' }),
  ] });
  add('count-only-cache', undefined, { steps: [
    step({ query: 'ordinary count cache', count: 2 }),
    step({ query: 'ordinary count cache', count: ' 4 ' }),
    step({ query: 'ordinary count cache' }),
  ] });
  add('freshness-alias-cache', undefined, { steps: [
    step({ query: 'ordinary alias cache', freshness: 'week' }),
    step({ query: 'ordinary alias cache', freshness: 'pw' }),
  ] });
  add('date-format-cache', undefined, { steps: [
    step({ query: 'ordinary date cache', date_after: '2026-10-12', date_before: '2026-10-18' }),
    step({ query: 'ordinary date cache', date_after: '10/12/2026', date_before: '10/18/2026' }),
  ] });
  for (const [id, initial, changed] of [
    ['model-request-identity', { model: 'gemini-3.6-flash' }, { model: 'gemini-3.1-pro-preview' }],
    ['base-request-identity', { baseUrl: 'https://proxy.example/one' }, { baseUrl: 'https://proxy.example/two' }],
    ['header-request-identity', { headers: { 'X-Search-Route': 'one' } }, { headers: { 'X-Search-Route': 'two' } }],
  ]) add(id, undefined, { steps: [
    step({ query: 'ordinary request identity' }, { providerConfig: initial }),
    step({ query: 'ordinary request identity' }, { providerConfig: changed }),
    step({ query: 'ordinary request identity' }, { providerConfig: initial }),
  ] });
  add('ordered-answer-citations', { query: 'ordered grounded answer' }, { httpPayload: { candidates: [{
    content: { parts: [{ text: ' First ordinary paragraph. ' }, { text: 'Second ordinary paragraph.' },
      { text: ' Third ordinary paragraph. ' }] },
    groundingMetadata: { groundingChunks: [
      { web: { uri: 'https://grounding.example/one', title: ' First source ' } },
      { web: { uri: 'https://grounding.example/two' } },
      { web: { uri: 'https://grounding.example/one', title: ' Duplicate source ' } },
      { web: { uri: 'https://grounding.example/three', title: 'Third source' } },
    ] },
  }, { content: { parts: [{ text: 'Ordinary alternative candidate is not selected.' }] } }] },
  redirectMap: { 'https://grounding.example/one': 'https://publisher.example/article',
    'https://grounding.example/three': 'https://third.example/news' } });
  add('answer-without-citations', undefined, { httpPayload: {
    candidates: [{ content: { parts: [{ text: 'Ordinary complete answer without citations.' }] } }],
  } });
  return rows;
}

function makeSetup(recipe, item = {}) {
  const config = { plugins: { entries: { google: { config: { webSearch: {
    apiKey: 'fixture-gemini-key', ...recipe.providerConfig, ...item.providerConfig,
  } } } } } };
  if (recipe.modelConfig) config.models = { providers: { google: plain(recipe.modelConfig) } };
  return { config, searchConfig: { cacheTtlMinutes: 15, maxResults: 5, ...recipe.searchConfig } };
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['content', 'title'].includes(field) ? unwrap(value) : value;
  if (Array.isArray(value)) return value.map(item => unwrapResult(item, unwrap, field));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}
function portable(value) {
  const copy = plain(value);
  delete copy.externalContent;
  return copy;
}

// Transport adaptation: remove one exact pinned frame while retaining ordinary body spacing.
export function unframeGeminiSearchText(text) {
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope');
  return match[2];
}
function providerPortable(value) {
  const copy = portable(value);
  copy.content = unframeGeminiSearchText(copy.content);
  return copy;
}

export async function captureGeminiSearch(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root);
  const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const merge = capture => {
    for (const [key, value] of capture.sources) sources.set(key,
      { ...value, executed: value.executed || sources.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  };
  const normalizer = new GeminiCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new GeminiCapture(root, recipe.httpPayload, recipe.redirectMap);
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createGeminiWebSearchProvider();
    const setup = makeSetup(recipe, recipe.steps[0]), originalSetup = plain(setup);
    const initialTool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = item.clock ? Date.parse(item.clock) : originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString();
      const stepSetup = makeSetup(recipe, item), setupBefore = plain(stepSetup);
      const args = plain(item.arguments), original = plain(args);
      const requestCount = capture.requests.length, headCount = capture.headRequests.length;
      const tool = provider.createTool(stepSetup);
      const providerResult = plain(await tool.execute(args));
      assert.deepEqual(args, original);
      assert.deepEqual(stepSetup, setupBefore);
      assert.equal(providerResult.provider, 'gemini', recipe.id);
      const requests = capture.requests.slice(requestCount), headRequests = capture.headRequests.slice(headCount);
      assert.ok(requests.length <= 1, 'at most one ordinary POST per callback');
      const cacheHit = providerResult.cached === true;
      assert.equal(requests.length, cacheHit ? 0 : 1, recipe.id);
      if (cacheHit) assert.deepEqual(headRequests, [], 'source cache reuse avoids citation HEAD callbacks');
      const genericResult = plain(normalize({ result: providerResult, provider: 'gemini', query: original.query }));
      assert.equal(genericResult.kind, 'answer', recipe.id);
      const providerUnwrappedResult = unwrapResult(providerResult, unwrap);
      const genericUnwrappedResult = unwrapResult(genericResult, unwrap);
      const genericPortableResult = portable(genericUnwrappedResult);
      steps.push({ arguments: original, argumentsAfter: plain(args), clock, clockAfter: new Date(capture.nowMs).toISOString(),
        setup: setupBefore, setupAfter: plain(stepSetup), request: requests[0] ?? null, headRequests,
        cacheHit, providerCached: providerResult.cached ?? false, genericCached: genericResult.cached ?? false,
        providerResult, providerUnwrappedResult, providerPortableResult: providerPortable(providerResult),
        genericResult, genericUnwrappedResult, genericPortableResult,
        publicResult: genericResult, publicUnwrappedResult: genericUnwrappedResult,
        publicPortableResult: genericPortableResult, cumulativeRequests: capture.requests.length,
        cumulativeHeadRequests: capture.headRequests.length });
    }
    assert.deepEqual(setup, originalSetup);
    groups.push({ id: recipe.id, setup: originalSetup, setupAfter: plain(setup),
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, envVars: provider.envVars, placeholder: provider.placeholder,
        signupUrl: provider.signupUrl, docsUrl: provider.docsUrl, autoDetectOrder: provider.autoDetectOrder,
        credentialPath: provider.credentialPath }),
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayload: plain(capture.payload), redirectMap: plain(capture.redirectMap), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  assert.equal(dependencies.size, 372, 'actual full TypeBox module graph plus package metadata');
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-gemini-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, synthetic clock/randomBytes; own audited Gemini facades, successful endpoint/configuration/policy fixtures and actual TypeBox loading' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    invocations: ['createGeminiWebSearchProvider()',
      'createGeminiWebSearchProvider().createTool(setup).execute(arguments)',
      'resolveCitationRedirectUrl(eachOrderedCitation) through source runtime Promise.all batches of10',
      'normalizeWebSearchOutput({result,provider,query:authoredArguments.query})',
      'unwrapWebSearchOutputText(providerAndGenericProse)'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true,
      publicCallbackInvoked: true, actualProviderRequestBuilder: true, actualBaseUrlHelper: true,
      actualClientHeaderHelper: true, actualRequestHeaderPolicy: false, actualCountReaders: true,
      actualTimeFilters: true, actualSourceCache: true, actualCitationRedirectHelper: true,
      genericNormalizerInvoked: true, actualUnwrapInvoked: true, actualTypeBox: true,
      actualBoundedSuccessReader: false, actualEndpointPolicy: false, actualCredentialResolution: false,
      productionNetworkInvoked: false, pluginRegistrationInvoked: false, fixtureEnvironment: {},
      syntheticClock: 'Date construction/Date.now; POST fixture advances7ms, HEAD fixtures do not advance time',
      portableNormalization: 'provider exact one-frame adaptation retains content spacing/model; source unwrap trims prose; generic portable uses source unwrap and removes externalContent only; public aliases generic',
      limits: [
        'All58558 tracked source blobs verified before/after; executed means unchanged whole module evaluated, not every export/branch called',
        'Actual factory, contract/config merge, lazy runtime, base URL, count/string/date/freshness/cache, client-header wrapper, citation redirect, generic normalizer and source unwrap execute',
        'Source base URL normalizer contains query/hash/userinfo stripping; only ordinary official/custom root/path/trailing-slash inputs execute, no security-input qualification',
        'Google client-header wrapper executes with explicit request-header policy fixture; provider-policy default is whole-base-helper re-export, policy/attribution source is provenance-only',
        'Successful synthetic POST/HEAD/JSON/platform callbacks only; production network, DNS/proxy, strict URL guards/SSRF, policy, release, bounded parser and real deadlines unexecuted',
        'Only fake explicit literal key and ordinary string headers; VM process.env empty; actual auth, credentials, SecretRef and ambient environment discovery unexecuted',
        'Source count is validated but absent from request/output/cache key; config.maxResults ignored; source cache-hit calls issue neither POST nor citation HEAD',
        'Provider content is first-candidate ordered nonempty string text joined LF; all citation URLs/titles/order/duplicates survive ordinary successful source redirects',
        'Provider portable retains model and content spacing; actual source unwrap trims prose; generic answer intentionally drops model and retains authored public query',
        'Each payload has fewer than10 citations, short normal text and ordinary values; no security/permission/authTLS/negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race/real-network execution',
        'Unused error, SecretRef, media/filesystem services are deferred throwing bindings; no full platform/framing/Unicode/URL, plugin assembly or source security qualification',
        'No Gemini Synapsis host implementation, Worker/Concord, live provider, deployment or release acceptance; full P0-P15 remains incomplete',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((sum, row) => sum + row.steps.filter(item => item.request !== null).length, 0),
      cacheHitCallbacks: groups.reduce((sum, row) => sum + row.steps.filter(item => item.cacheHit).length, 0),
      headRequests: groups.reduce((sum, row) => sum + row.steps.reduce((n, item) => n + item.headRequests.length, 0), 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source,
      gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureGeminiSearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}
