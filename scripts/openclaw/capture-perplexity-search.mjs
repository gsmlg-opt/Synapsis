// Ordinary provider callbacks and output normalization from complete pinned modules.
// HTTP, policy, parsing and literal-secret bindings are explicit fixture boundaries.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/perplexity/src/perplexity-web-search-provider.ts';
const shared = 'extensions/perplexity/src/perplexity-web-search-provider.shared.ts';
const runtime = 'extensions/perplexity/src/perplexity-web-search-provider.runtime.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT',
      'isoToPerplexityDate', 'normalizeFreshness', 'parseWebSearchTimeFilters',
      'readCachedSearchPayload', 'readConfiguredSecretString', 'readWebSearchQueryAndCount',
      'resolveSearchCacheTtlMs', 'resolveSearchCount', 'resolveSearchTimeoutSeconds',
      'resolveSiteName', 'throwWebSearchApiError', 'withTrustedWebSearchEndpoint',
      'writeCachedSearchPayload'], common),
    from(['readPositiveIntegerParam', 'readStringArrayParam', 'readToolStringParam as readStringParam'], readers),
    from(['readProviderEnvValue'], 'src/secrets/provider-credential-values.ts'),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeLowercaseStringOrEmpty', 'normalizeOptionalString'], normalization + 'string-coerce.ts'),
    from(['uniqueStrings'], normalization + 'string-normalization.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonResponse,resolveProviderRequestHeaders} from "perplexity:platform";',
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};

class PerplexityCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
  }

  source(path) {
    if (![factory, shared, runtime, output].includes(path)) return super.source(path);
    if (!this.modules.has(path)) {
      this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
        context: this.context, identifier: path,
        importModuleDynamically: async specifier => {
          this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
          const target = this.import(specifier, path);
          await this.evaluate(target);
          return target;
        },
      }));
    }
    return this.modules.get(path);
  }

  // Same generic actual-dependency loading facility used by the Unicode capture.
  typeboxModule(file) {
    assert.ok(file === this.typeboxRoot || file.startsWith(this.typeboxRoot + sep));
    const id = 'perplexity:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file);
      const path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }

  platform() {
    const record = (kind, detail = {}) => this.audit.push({ kind, ...detail });
    const bindings = {
      withTrustedWebToolsEndpoint: async (params, run) => {
        record('successful-http-fixture', { timeoutSeconds: params.timeoutSeconds });
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          body: JSON.parse(params.init.body), headers: plain(params.init.headers),
          timeoutSeconds: params.timeoutSeconds });
        return run({ response: Response.json(plain(this.payload)) });
      },
      readProviderJsonResponse: async response => {
        record('successful-json-fixture');
        return response.json();
      },
      resolveProviderRequestHeaders: params => {
        record('header-policy-fixture', { input: plain(params), returns: 'undefined' });
        return undefined;
      },
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records exact request and timeout; supplies successful synthetic Response; network, endpoint policy and deadline execution unverified',
      readProviderJsonResponse: 'successful fixture Response.json; production bounded parser unexecuted',
      resolveProviderRequestHeaders: 'records policy input and returns undefined; unchanged source runtime applies its own defaultHeaders fallback; production policy unexecuted',
    };
    return this.synthetic('perplexity:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    if (specifier === 'perplexity:platform') return this.platform();
    if (importer === common && specifier === './web-guarded-fetch.js') {
      const path = 'src/agents/tools/web-guarded-fetch.ts';
      this.verifiedSource(path, false);
      link('explicit-successful-http-fixture', path);
      return this.platform();
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
    if (importer.startsWith('perplexity:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      const owner = importer.slice('perplexity:typebox:'.length);
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(owner), specifier)));
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      const path = 'src/web-search/runtime-error.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier, ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk)
        ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      if (specifier === sdk + 'provider-http') {
        this.verifiedSource('src/agents/provider-request-config.ts', false);
        this.verifiedSource('src/agents/provider-http-errors.ts', false);
      }
      const generatedCode = facades[specifier];
      const id = 'perplexity:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id,
        new vm.SourceTextModule(generatedCode, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
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
      const [mode, type, blob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
      const file = join(root, path);
      const symlink = lstatSync(file).isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      assert.ok(realpathSync(file).startsWith(root + sep));
      const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
      return { path, gitBlob: blob, sha256: digest(bytes) };
    });
  return { verified: true, commit: BRAVE_REFERENCE_PIN,
    tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}

const searchPayload = () => ({ results: Array.from({ length: 12 }, (_, index) => ({
  title: ` Source ${index + 1} 😀 `, url: `https://source.example/${index + 1}`,
  snippet: ` Ordinary passage ${index + 1} 文 `, date: '2025-01-02',
})) });
const chatPayload = (extra = {}) => ({ choices: [{ message: { content: ' Grounded answer 😀 ' } }],
  citations: ['https://citation.example/b', 'https://citation.example/a', 'https://citation.example/b'], ...extra });
const step = (arguments_, policy, elapsedMs) => ({ arguments: arguments_,
  ...(policy ? { policy } : {}), ...(elapsedMs !== undefined ? { elapsedMs } : {}) });

function recipes() {
  const rows = [];
  const search = (id, steps = [step({ query: id })], options = {}) =>
    rows.push({ id, mode: 'search_api', steps, ...options });
  const chat = (id, options = {}, steps = [step({ query: id })]) =>
    rows.push({ id, mode: 'chat_completions', providerConfig: { baseUrl: 'https://api.perplexity.ai', ...options.providerConfig },
      steps, ...options });
  search('search-default');
  search('search-options-allow', [step({ query: ' structured options ', count: 2, country: ' US ',
    language: ' EN ', date_after: '2025-01-02', date_before: '1/31/2025',
    domain_filter: [' alpha.example ', 'alpha.example', 'beta.example'],
    max_tokens: 1_000_000, max_tokens_per_page: 1 })], { searchConfig: { timeoutSeconds: 12 } });
  search('search-options-deny', [step({ query: 'deny domains', count: 1,
    domain_filter: ['-alpha.example', '-alpha.example', '-beta.example'], max_tokens: 1, max_tokens_per_page: 2 })]);
  search('search-configured-count', undefined, { searchConfig: { maxResults: 3 } });
  search('search-count-ten', [step({ query: 'search-count-ten', count: 10 })]);
  search('search-freshness-aliases', [' PD ', 'day', 'pw', 'WEEK', 'pm', 'month', 'py', 'year']
    .map(freshness => step({ query: 'same freshness query', freshness, count: 2 })));
  for (const [name, dates] of [
    ['bounded', [{ date_after: '2025-01-02', date_before: '2025-01-31' }, { date_after: '1/2/2025', date_before: '1/31/2025' }]],
    ['after', [{ date_after: '2025-01-02' }, { date_after: '1/2/2025' }]],
    ['before', [{ date_before: '2025-01-31' }, { date_before: '1/31/2025' }]],
    ['same-day', [{ date_after: '2025-01-02', date_before: '2025-01-02' }, { date_after: '1/2/2025', date_before: '1/2/2025' }]],
  ]) search('search-dates-' + name, dates.map(date => step({ query: 'same dates query', ...date })));
  search('search-blank-overrides', undefined, { providerConfig: { baseUrl: ' ', model: ' ' } });
  chat('chat-direct-default');
  chat('chat-direct-model', { providerConfig: { model: ' perplexity/sonar-reasoning-pro ' } });
  chat('chat-custom-model', { providerConfig: { baseUrl: ' https://router.example/proxy/ ', model: 'perplexity/sonar-reasoning-pro' } });
  chat('chat-openrouter', { providerConfig: { baseUrl: 'https://openrouter.ai/api/v1' } });
  chat('chat-freshness', {}, [step({ query: 'chat-freshness', count: 2, freshness: ' PW ' })]);
  chat('chat-top-citations', { payload: chatPayload({ choices: [{ message: {
    content: ' Grounded answer 😀 ', annotations: [{ type: 'url_citation', url: 'https://ignored.example/source' }],
  } }] }) });
  chat('chat-annotations', { payload: { choices: [
    { message: { content: ' Annotation answer 文 ', annotations: [
      { type: 'url_citation', url_citation: { url: ' https://citation.example/nested ' } },
      { type: 'url_citation', url: 'https://citation.example/flat' },
    ] } },
    { message: { content: 'Other choice', annotations: [
      { type: 'url_citation', url: 'https://citation.example/nested' },
      { type: 'url_citation', url_citation: { url: 'https://citation.example/later' } },
    ] } },
  ] } });
  chat('chat-empty-citations', { payload: chatPayload({ citations: [] }) });
  for (const mode of ['search', 'chat']) {
    const add = mode === 'search' ? search : (id, steps, options) => chat(id, options, steps);
    add(mode + '-cache-count', [1, 10, 1].map(count => step({ query: 'cache count', count })));
    add(mode + '-cache-policy', [
      step({ query: 'policy', count: 2 }, {}, 0),
      step({ query: 'policy', count: 2 }, { timeoutSeconds: 4, maxResults: 9 }, 1),
      step({ query: 'policy', count: 2 }, { cacheTtlMinutes: 0, timeoutSeconds: 7 }, 2),
      step({ query: 'policy', count: 2 }, { cacheTtlMinutes: 0 }, 3),
      step({ query: 'policy', count: 2 }, {}, 4),
      step({ query: 'policy', count: 2 }, { cacheTtlMinutes: 1 / 60_000 }, 5),
      step({ query: 'policy', count: 2 }, {}, 5),
    ]);
  }
  search('search-query-whitespace-cache', [step({ query: ' ordinary query ', count: 1 }),
    step({ query: 'ordinary query', count: 1 })]);
  chat('chat-query-whitespace-cache', {}, [step({ query: ' ordinary query ', count: 1 }),
    step({ query: 'ordinary query', count: 10 })]);
  return rows;
}

function normalizerRecipes() {
  const citation = 'https://citation.example/one';
  return [
    { id: 'answer-ordered-citations', content: 'Ordered answer', citations: [
      'https://citation.example/b', 'https://citation.example/a', 'https://citation.example/b'] },
    { id: 'answer-body-emoji', content: '😀'.repeat(12_000), citations: [citation, 'https://citation.example/two'] },
    { id: 'answer-body-combining', content: 'e\u0301'.repeat(12_000), citations: [citation] },
    { id: 'answer-body-zwj', content: '👩‍💻'.repeat(6_000), citations: [citation] },
    { id: 'answer-citation-limit', content: 'Cited answer', citations: Array.from({ length: 21 },
      (_, index) => `https://citation.example/${index + 1}`) },
    { id: 'answer-title-budget', content: 'Ordinary answer', citations: [
      { url: citation, title: '界'.repeat(21_000) },
      { url: 'https://citation.example/two', title: 'Later title' }] },
    { id: 'answer-empty-citations', content: 'Uncited answer', citations: [] },
    { id: 'answer-short-unicode', content: ' \t界😀e\u0301 👩‍💻 \n', citations: [citation] },
    { id: 'answer-url-canonicalization', content: 'Canonical sources', citations: [
      { url: 'https://CITATION.EXAMPLE:443/ordinary?q=hello%20world', title: ' Ordinary title ' },
      'https://Source.Example:443/path#section'] },
    { id: 'answer-title-order', content: 'Ordinary answer', citations: [
      { url: 'https://citation.example/b', title: ' Title B ' },
      { url: 'https://citation.example/a', title: 'Title A' }] },
    { id: 'answer-body-emoji-leftover', content: '😀'.repeat(12_000), citations: [
      { url: 'https://citation.example/two2', title: 'Z title' }] },
    { id: 'answer-citations-exhaust-body', content: 'Nonempty ordinary answer',
      citations: Array.from({ length: 20 }, (_, index) => {
        const prefix = `https://citation.example/${index + 1}/`;
        return prefix + 'x'.repeat(1_000 - prefix.length);
      }) },
  ];
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['title', 'description', 'snippet', 'content', 'siteName'].includes(field)
    ? unwrap(value) : value;
  if (Array.isArray(value)) return value.map(item => unwrapResult(item, unwrap));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}

export async function capturePerplexitySearch(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root);
  const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const merge = capture => {
    for (const [key, value] of capture.sources) {
      const previous = sources.get(key);
      sources.set(key, { ...value, executed: value.executed || previous?.executed === true });
    }
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  };
  const normalizer = new PerplexityCapture(root);
  const module = normalizer.source(output);
  await normalizer.evaluate(module);
  const normalize = module.namespace.normalizeWebSearchOutput;
  const unwrap = module.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new PerplexityCapture(root,
      recipe.payload ?? (recipe.mode === 'search_api' ? searchPayload() : chatPayload()));
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createPerplexityWebSearchProvider();
    const config = { plugins: { entries: { perplexity: { config: { webSearch: {
      apiKey: 'fixture-perplexity-key', ...recipe.providerConfig,
    } } } } } };
    const searchConfig = { cacheTtlMinutes: 15, maxResults: 5, ...recipe.searchConfig };
    const setup = { config, searchConfig };
    const metadata = plain(provider.resolveRuntimeMetadata({ ...setup,
      resolvedCredential: { source: 'config', value: config.plugins.entries.perplexity.config.webSearch.apiKey } }));
    assert.equal(metadata.perplexityTransport, recipe.mode, recipe.id);
    const initialTool = provider.createTool({ ...setup, runtimeMetadata: metadata });
    const steps = [];
    for (const item of recipe.steps) {
      capture.nowMs = originMs + (item.elapsedMs ?? 0);
      const currentSetup = { config, searchConfig: { ...searchConfig, ...item.policy } };
      const tool = provider.createTool({ ...currentSetup, runtimeMetadata: metadata });
      const arguments_ = plain(item.arguments);
      const original = plain(arguments_);
      const requestCount = capture.requests.length;
      const providerResult = plain(await tool.execute(arguments_));
      assert.deepEqual(arguments_, original);
      assert.equal(providerResult.provider, 'perplexity');
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      const publicResult = plain(normalize({ result: providerResult, provider: 'perplexity', query: original.query }));
      assert.equal(publicResult.kind, recipe.mode === 'search_api' ? 'results' : 'answer');
      steps.push({ arguments: original, argumentsAfter: plain(arguments_),
        clock: new Date(capture.nowMs).toISOString(), setup: currentSetup,
        request: requests[0] ?? null, providerResult,
        providerUnwrappedResult: unwrapResult(providerResult, unwrap), publicResult,
        publicUnwrappedResult: unwrapResult(publicResult, unwrap), cached: providerResult.cached === true,
        cumulativeRequests: capture.requests.length });
    }
    groups.push({ id: recipe.id, mode: recipe.mode, setup, metadata,
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayload: plain(capture.payload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  const normalizerCases = normalizerRecipes().map(recipe => {
    const providerResult = { provider: 'perplexity', model: 'perplexity/sonar-pro',
      query: recipe.id, tookMs: 0, content: recipe.content, citations: recipe.citations };
    const publicResult = plain(normalize({ result: providerResult, provider: 'perplexity', query: recipe.id }));
    return { id: recipe.id, query: recipe.id, providerResult, publicResult,
      publicUnwrappedResult: unwrapResult(publicResult, unwrap) };
  });
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-perplexity-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported complete-module BraveCapture loader; own source/facade/platform and actual TypeBox facilities' }],
    invocations: ['createPerplexityWebSearchProvider().resolveRuntimeMetadata(setup)',
      'createPerplexityWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider,query})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false,
      factoryInvoked: true, runtimeMetadataInvoked: true, publicCallbackInvoked: true,
      genericNormalizerInvoked: true, actualSharedCache: true,
      productionNetworkInvoked: false, pluginRegistrationInvoked: false, fixtureEnvironment: {},
      unwrap: 'original unwrapWebSearchOutputText only for prose fields; all semantic fields, metadata stamp and tookMs retained',
      limits: [
        'Whole tracked source tree blobs verified before and after; only loaded source modules marked executed',
        'Successful HTTP/JSON and header policy are explicit fixtures; deadlines are recorded parameters, not executed timers',
        'Literal configuration normalization uses inherited explicit fixture; actual secret resolution and discovery unexecuted',
        'resolveProviderRequestHeaders returns undefined; unchanged runtime defaultHeaders expression supplies fixture headers',
        'Only ordinary valid successful source callbacks and normalizer inputs; no security/permission/auth/TLS/negative/mixed/real-provider tests',
        'Full plugin registration, runtime assembly, production policy/network, native Worker persistence/replay and real-provider behavior unverified',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0),
      normalizerCases: normalizerCases.length },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) },
    groups, normalizerCases,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await capturePerplexitySearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}
