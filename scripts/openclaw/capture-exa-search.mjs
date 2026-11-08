// Ordinary provider callbacks and output normalization from complete pinned modules.
// HTTP and literal-secret bindings are fixtures; actual bounded success JSON reader executes.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/exa/src/exa-web-search-provider.ts';
const runtime = 'extensions/exa/src/exa-web-search-provider.runtime.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const extraSources = new Set([factory, runtime, output, 'src/plugin-sdk/provider-web-search-contract.ts',
  'src/infra/http-response-body.ts', 'src/infra/http-response-body-timeout.ts',
  normalization + 'error-coercion.ts']);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT',
      'parseIsoDateRange', 'readCachedSearchPayload', 'readWebSearchApiKey',
      'resolveSearchCacheTtlMs', 'resolveSearchTimeoutSeconds', 'resolveSiteName',
      'withTrustedWebSearchEndpoint', 'writeCachedSearchPayload'], common),
    from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
    from(['mergeScopedSearchConfig', 'resolveProviderWebSearchPluginConfig'],
      'src/agents/tools/web-search-provider-config.ts'),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    from(['asOptionalRecord', 'asOptionalObjectRecord', 'isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeOptionalLowercaseString'], normalization + 'string-coerce.ts'),
    from(['normalizeTrimmedStringList'], normalization + 'string-normalization.ts'),
  ].join('\n'),
  [sdk + 'number-runtime']: from(['parseStrictPositiveInteger'], normalization + 'number-coercion.ts'),
  [sdk + 'response-limit-runtime']: from(['readResponseWithLimit'], 'src/infra/http-response-body.ts'),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields'],
    'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {ProviderHttpError,readProviderResponseErrorText,redactProviderResponseErrorText} from "exa:unused-errors";',
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};

class ExaCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
  }

  source(path) {
    if (!extraSources.has(path)) return super.source(path);
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
    const id = 'exa:typebox:' + relative(this.typeboxRoot, file);
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
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records exact request and timeout; supplies successful synthetic Response; network, endpoint policy and deadline execution unverified',
    };
    return this.synthetic('exa:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    if (specifier === 'exa:platform') return this.platform();
    if (specifier === 'exa:unused-errors') {
      for (const path of ['src/agents/provider-http-errors.ts', 'src/agents/provider-response-errors.ts']) {
        if (existsSync(join(this.root, path))) this.verifiedSource(path, false);
      }
      return this.deferred(importer, specifier,
        ['ProviderHttpError', 'readProviderResponseErrorText', 'redactProviderResponseErrorText']);
    }
    if (importer === 'src/plugin-sdk/provider-web-search-contract.ts' && specifier === './provider-enable-config.js') {
      this.verifiedSource('src/plugin-sdk/provider-enable-config.ts', false);
      return this.deferred(importer, specifier, ['enablePluginInConfig']);
    }
    if (importer === 'src/infra/http-response-body-timeout.ts' && specifier === './abort-signal.js') {
      this.verifiedSource('src/infra/abort-signal.ts', false);
      return this.deferred(importer, specifier, ['racePromiseWithAbortSignal']);
    }
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
    if (importer.startsWith('exa:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      const owner = importer.slice('exa:typebox:'.length);
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
        this.verifiedSource('src/agents/provider-http-errors.ts', false);
      }
      const generatedCode = facades[specifier];
      const id = 'exa:facade:' + specifier;
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

const searchPayload = (count = 12) => ({ results: Array.from({ length: count }, (_, index) => ({
  title: ` Source ${index + 1} 😀 `, url: `https://www.source.example/${index + 1}`,
  highlights: [` First passage ${index + 1} 文 `, ` Second passage ${index + 1} `],
  summary: ` Summary ${index + 1} `, text: ` Full text ${index + 1} `,
  publishedDate: '2025-01-02T12:34:56Z', highlightScores: [0.75, index / 100],
})) });
const step = (arguments_, policy, elapsedMs, clock) => ({ arguments: arguments_,
  ...(policy ? { policy } : {}), ...(elapsedMs !== undefined ? { elapsedMs } : {}),
  ...(clock ? { clock } : {}) });

function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) =>
    rows.push({ id, steps: [step(args)], ...options });
  add('search-default');
  for (const type of ['auto', 'neural', 'fast', 'deep', 'deep-reasoning', 'instant']) {
    add('type-' + type, { query: ' type query ', count: 2, type });
  }
  add('count-hundred', { query: 'hundred results', count: 100 }, { payload: searchPayload(105) });
  add('configured-count', undefined, { searchConfig: { maxResults: 13 }, payload: searchPayload(15) });
  add('configured-count-string', undefined, { searchConfig: { maxResults: '12' }, payload: searchPayload(15) });
  for (const [id, baseUrl] of [
    ['path', 'https://proxy.example/exa'], ['path-trailing-slashes', 'https://proxy.example/exa///'],
    ['search-path', 'https://proxy.example/exa/search/'],
    ['query-fragment', ' https://proxy.example/exa?tenant=ordinary#section '],
    ['schemeless', 'proxy.example/exa'], ['http', 'http://proxy.example/exa'],
    ['blank-default', '   '],
    ['uppercase-default-port', 'HTTPS://EXA.EXAMPLE:443/proxy///?ordinary=yes#fragment'],
  ]) add('endpoint-' + id, undefined, { providerConfig: { baseUrl } });
  for (const [id, dates] of [
    ['bounded', { date_after: '2025-01-02', date_before: '2025-01-31' }],
    ['after', { date_after: '2025-01-02' }], ['before', { date_before: '2025-01-31' }],
    ['same-day', { date_after: '2025-01-02', date_before: '2025-01-02' }],
  ]) add('dates-' + id, { query: 'date range', ...dates }, { steps: [
    step({ query: ' date range ', count: 2, ...dates }),
    step({ query: 'date range', count: 2,
      ...(dates.date_after ? { date_after: ' 1/2/2025 ' } : {}),
      ...(dates.date_before ? { date_before: dates.date_before === '2025-01-02' ? '1/2/2025' : '1/31/2025' } : {}) }),
  ] });
  for (const freshness of ['day', 'week', 'month', 'year']) {
    add('freshness-' + freshness, undefined, { steps: [
      step({ query: 'freshness ' + freshness, count: 2, freshness: ` ${freshness.toUpperCase()} ` }),
      step({ query: 'freshness ' + freshness, count: 2, freshness }),
    ] });
  }
  add('freshness-month-clamp', undefined, { steps: [
    step({ query: 'month clamp', freshness: 'month' }, undefined, undefined, '2025-03-31T23:45:12.345Z'),
  ] });
  add('freshness-month-leap-clamp', undefined, { steps: [
    step({ query: 'leap clamp', freshness: 'month' }, undefined, undefined, '2024-03-31T23:45:12.345Z'),
  ] });
  add('freshness-year-leap-rollover', undefined, { steps: [
    step({ query: 'year rollover', freshness: 'year' }, undefined, undefined, '2024-02-29T23:45:12.345Z'),
  ] });
  add('contents-empty-default', { query: 'contents empty', contents: {} });
  add('contents-booleans', { query: 'contents flags', contents: { text: false, highlights: true, summary: false } });
  add('contents-text-object', { query: 'text content', contents: { text: { maxCharacters: 42 } } });
  add('contents-highlights-object', { query: 'highlights content', contents: { highlights: {
    maxCharacters: 51, query: '  exact highlights query \n', numSentences: 3, highlightsPerUrl: 2,
  } } });
  add('contents-summary-object', { query: 'summary content', contents: { summary: { query: '  exact summary query \n' } } });
  add('contents-empty-objects', { query: 'empty content objects', contents: { text: {}, highlights: {}, summary: {} } });
  add('contents-all-sections', { query: 'all sections', contents: {
    summary: { query: 'Summary focus' }, text: { maxCharacters: 100 },
    highlights: { query: 'Highlights focus', highlightsPerUrl: 1, numSentences: 2, maxCharacters: 30 },
  } });
  add('contents-canonical-cache', undefined, { steps: [
    step({ query: 'canonical content', contents: { summary: { query: 'focus' },
      highlights: { highlightsPerUrl: 2, query: 'focus', maxCharacters: 17, numSentences: 1 }, text: { maxCharacters: 9 } } }),
    step({ query: 'canonical content', contents: { text: { maxCharacters: 9 },
      highlights: { maxCharacters: 17, query: 'focus', numSentences: 1, highlightsPerUrl: 2 }, summary: { query: 'focus' } } }),
  ] });
  add('contents-default-cache', undefined, { steps: [
    step({ query: 'same defaults' }), step({ query: 'same defaults', contents: {} }),
    step({ query: 'same defaults', contents: { highlights: true } }),
  ] });
  add('result-fallbacks', { query: 'result fallbacks', count: 5 }, { payload: { results: [
    { title: '  literal title 😀  ', url: 'https://www.source.example/highlights',
      highlights: [' first ', ' ', ' second ', 'first'], summary: '  summary retained  ', text: 'Text fallback',
      highlightScores: [0, 0.2, -0.5], publishedDate: ' 2025-02-03 ' },
    { title: '', url: 'https://source.example/summary', highlights: [], summary: ' Summary fallback ' },
    { title: 'Text', url: 'https://source.example/text', highlights: [], summary: ' ', text: ' Text fallback ' },
    { title: 'Empty', url: 'https://source.example/empty', highlights: [] },
    { title: 'Summary score', url: 'https://source.example/score', summary: 'summary', highlightScores: [1.25], publishedDate: '' },
  ] } });
  add('result-records-before-slice', { query: 'record results', count: 2 }, { payload: { results: [
    null, 'provider marker', { title: 'First', url: 'https://source.example/first', text: 'One' },
    7, { title: 'Second', url: 'https://source.example/second', text: 'Two' },
    { title: 'Third', url: 'https://source.example/third', text: 'Three' },
  ] } });
  add('cache-count', undefined, { steps: [1, 100, 1].map(count => step({ query: 'cache count', count })),
    payload: searchPayload(101) });
  add('cache-types', undefined, { steps: ['auto', 'neural', 'auto'].map(type => step({ query: 'cache types', type })) });
  add('cache-policy', undefined, { steps: [
    step({ query: 'cache policy', count: 2 }, {}, 0),
    step({ query: 'cache policy', count: 2 }, { timeoutSeconds: 4, maxResults: 9 }, 1),
    step({ query: 'cache policy', count: 2 }, { cacheTtlMinutes: 0, timeoutSeconds: 7 }, 2),
    step({ query: 'cache policy', count: 2 }, { cacheTtlMinutes: 0 }, 3),
    step({ query: 'cache policy', count: 2 }, {}, 4),
    step({ query: 'cache policy', count: 2 }, { cacheTtlMinutes: 1 / 60_000 }, 5),
    step({ query: 'cache policy', count: 2 }, {}, 5),
  ] });
  add('query-whitespace-cache', undefined, { steps: [
    step({ query: '  ordinary query \n', count: 1 }), step({ query: 'ordinary query', count: 1 }),
  ] });
  for (const [id, unit] of [['emoji', '😀'], ['combining', 'e\u0301'], ['zwj', '👩‍💻']]) {
    add('callback-results-body-' + id, { query: 'callback-results-body-' + id, count: 2 }, {
      payload: { results: [
        { title: unit.repeat(12_000), url: 'https://source.example/first', highlights: [unit.repeat(12_000)] },
        { title: 'Later title', url: 'https://source.example/second', highlights: ['Later snippet'] },
      ] },
    });
  }
  add('callback-results-short-unicode', { query: 'callback-results-short-unicode', count: 2 }, {
    payload: { results: [
      { title: ' \t界😀e\u0301 👩‍💻 \n', url: 'https://source.example/first', highlights: [' 界😀e\u0301 👩‍💻 '] },
      { title: 'Later title', url: 'https://source.example/second', highlights: ['Later snippet'] },
    ] },
  });
  add('callback-results-url-normalization', { query: 'callback-results-url-normalization', count: 1 }, {
    payload: { results: [
      { title: ' Ordinary title ', url: 'https://SOURCE.EXAMPLE:443/ordinary?q=hello%20world', highlights: [' Description '] },
    ] },
  });
  add('callback-results-eleven', { query: 'callback-results-eleven', count: 11 }, { payload: searchPayload(11) });
  return rows;
}

function normalizerRecipes() {
  const rows = (text) => [
    { title: text, url: 'https://source.example/first', description: 'Later snippet', siteName: 'source.example' },
    { title: 'Later title', url: 'https://source.example/second', description: 'Later snippet', siteName: 'source.example' },
  ];
  return [
    { id: 'results-body-emoji', results: rows('😀'.repeat(12_000)) },
    { id: 'results-body-combining', results: rows('e\u0301'.repeat(12_000)) },
    { id: 'results-body-zwj', results: rows('👩‍💻'.repeat(6_000)) },
    { id: 'results-short-unicode', results: rows(' \t界😀e\u0301 👩‍💻 \n') },
    { id: 'results-eleven', results: Array.from({ length: 11 }, (_, index) => ({
      title: 'Title ' + index, url: `https://source.example/${index}`, description: 'Description ' + index,
    })) },
    { id: 'results-url-normalization', results: [
      { title: ' Ordinary title ', url: 'https://SOURCE.EXAMPLE:443/ordinary?q=hello%20world',
        description: ' Description ', siteName: 'SOURCE.EXAMPLE' },
    ] },
  ];
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['title', 'description', 'snippet', 'content', 'summary', 'siteName'].includes(field)
    ? unwrap(value) : value;
  if (Array.isArray(value)) return value.map(item => unwrapResult(item, unwrap));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}
// Remove only the exact deterministic framing emitted by the actual wrapper.
// Unlike the public source unwrap helper, this preserves provider prose whitespace.
function unframe(value) {
  const start = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n';
  const end = '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
  if (!value.startsWith(start)) return value;
  assert.ok(value.endsWith(end));
  return value.slice(start.length, -end.length);
}
function portable(value) {
  if (Array.isArray(value)) return value.map(portable);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .filter(([key]) => key !== 'externalContent').map(([key, item]) => [key, portable(item)]));
  return value;
}

export async function captureExaSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new ExaCapture(root);
  const module = normalizer.source(output);
  await normalizer.evaluate(module);
  const normalize = module.namespace.normalizeWebSearchOutput;
  const unwrap = module.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new ExaCapture(root, recipe.payload ?? searchPayload());
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createExaWebSearchProvider();
    const config = { plugins: { entries: { exa: { config: { webSearch: {
      apiKey: 'fixture-exa-key', ...recipe.providerConfig,
    } } } } } };
    const searchConfig = { cacheTtlMinutes: 15, maxResults: 5, ...recipe.searchConfig };
    const setup = { config, searchConfig };
    const initialTool = provider.createTool(setup);
    const steps = [];
    for (const item of recipe.steps) {
      capture.nowMs = item.clock ? Date.parse(item.clock) : originMs + (item.elapsedMs ?? 0);
      const currentSetup = { config, searchConfig: { ...searchConfig, ...item.policy } };
      const tool = provider.createTool(currentSetup);
      const arguments_ = plain(item.arguments);
      const original = plain(arguments_);
      const requestCount = capture.requests.length;
      const providerResult = plain(await tool.execute(arguments_));
      assert.deepEqual(arguments_, original);
      assert.equal(providerResult.provider, 'exa', recipe.id);
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      const publicResult = plain(normalize({ result: providerResult, provider: 'exa', query: original.query }));
      assert.equal(publicResult.kind, 'results', recipe.id);
      const providerUnwrappedResult = unwrapResult(providerResult, unwrap);
      const providerUnframedResult = unwrapResult(providerResult, unframe);
      const publicUnwrappedResult = unwrapResult(publicResult, unwrap);
      steps.push({ arguments: original, argumentsAfter: plain(arguments_),
        clock: new Date(capture.nowMs).toISOString(), setup: currentSetup,
        request: requests[0] ?? null, providerResult, providerUnwrappedResult, providerUnframedResult,
        providerPortableResult: portable(providerUnframedResult), publicResult, publicUnwrappedResult,
        publicPortableResult: portable(publicUnwrappedResult), cached: providerResult.cached === true,
        cumulativeRequests: capture.requests.length });
    }
    groups.push({ id: recipe.id, setup,
      providerMetadata: { id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: plain(provider.onboardingScopes), autoDetectOrder: provider.autoDetectOrder },
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayload: plain(capture.payload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  const normalizerCases = normalizerRecipes().map(recipe => {
    const providerResult = { provider: 'exa', query: recipe.id, tookMs: 0, count: recipe.results.length,
      results: recipe.results };
    const publicResult = plain(normalize({ result: providerResult, provider: 'exa', query: recipe.id }));
    const publicUnwrappedResult = unwrapResult(publicResult, unwrap);
    return { id: recipe.id, query: recipe.id, providerResult, publicResult,
      publicUnwrappedResult, publicPortableResult: portable(publicUnwrappedResult) };
  });
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-exa-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported complete-module BraveCapture loader; own source/facade/platform and actual TypeBox facilities' }],
    invocations: ['createExaWebSearchProvider()', 'createExaWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider,query})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false,
      factoryInvoked: true, publicCallbackInvoked: true,
      genericNormalizerInvoked: true, actualSharedCache: true, actualBoundedSuccessReader: true,
      productionNetworkInvoked: false, pluginRegistrationInvoked: false, fixtureEnvironment: {},
      unwrap: 'providerUnframedResult removes exact deterministic frames and preserves whitespace; providerPortableResult additionally removes externalContent only; public variants use actual source unwrapWebSearchOutputText; complete framed originals remain',
      limits: [
        'Whole tracked source tree blobs verified before and after; only loaded source modules marked executed',
        'Successful HTTP is an explicit fixture; the actual bounded byte reader and fatal UTF8/JSON success parser execute; deadlines recorded but not timed',
        'Literal configuration normalization uses inherited explicit fixture; actual secret resolution and discovery unexecuted',
        'Only ordinary valid successful callbacks and output normalization; no security/permission/auth/TLS/negative/mixed/real-provider tests',
        'Full plugin registration/runtime assembly, production network/policy, native Worker persistence/replay and real-provider behavior unverified',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0),
      normalizerCases: normalizerCases.length },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) },
    groups, normalizerCases,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureExaSearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}
