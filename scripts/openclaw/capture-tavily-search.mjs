// Ordinary search callbacks from complete unchanged pinned OpenClaw modules.
// Successful HTTP, literal secret and clock boundaries are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const index = 'extensions/tavily/index.ts';
const output = 'src/agents/tools/web-search-output.ts';
const client = 'extensions/tavily/src/tavily-client.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const results = 'src/agents/tools/tool-results.ts';
const external = 'src/security/external-content.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const additionalSources = new Set([
  index, client, results, output, 'extensions/tavily/src/config.ts',
  'extensions/tavily/src/tavily-search-provider.ts', 'src/agents/schema/string-enum.ts',
  'src/plugin-sdk/plugin-entry.ts', 'src/plugin-sdk/lazy-value.ts',
  'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-enable-config.ts',
  'src/config/plugins-allowlist.ts', 'src/plugins/capability-provider.types.ts',
]);
const facades = {
  [sdk + 'channel-actions']: from(['optionalStringEnum'], 'src/agents/schema/string-enum.ts'),
  [sdk + 'plugin-entry']: from(['definePluginEntry'], 'src/plugin-sdk/plugin-entry.ts'),
  [sdk + 'param-readers']: from(['readPositiveIntegerParam'], readers),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields'], 'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'postTrustedWebToolsJson', 'readCachedSearchPayload',
      'resolveSearchCacheTtlMs', 'writeCachedSearchPayload'], common),
    from(['normalizeCacheKey', 'readCache', 'writeCache', 'resolvePositiveTimeoutSeconds'], 'src/agents/tools/web-shared.ts'),
    from(['readPositiveIntegerParam', 'readStringArrayParam', 'readToolStringParam as readStringParam'], readers),
    from(['jsonResult'], results),
  ].join('\n'),
  [sdk + 'number-runtime']: from(['parseDateStringTimestampMs', 'resolveIntegerOption'], normalization + 'number-coercion.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonResponse} from "tavily-search:platform";',
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-input-runtime']: 'export {assertPluginCapabilitySecretAvailable} from "tavily-search:platform";',
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "tavily-search:platform";',
  [sdk + 'security-runtime']: from(['truncateSanitizedExternalContent', 'wrapExternalContent', 'wrapWebContent'], external),
  [sdk + 'string-coerce-runtime']: [
    from(['isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};

class TavilySearchCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    // The real successful common request builder uses Headers; no fetch is exposed.
    this.context.Headers = Headers;
  }

  source(path) {
    if (!additionalSources.has(path)) return super.source(path);
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
    assert.ok(file.startsWith(this.typeboxRoot + sep));
    const id = 'tavily-search:typebox:' + relative(this.typeboxRoot, file);
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
          query: Object.fromEntries(url.searchParams), body: JSON.parse(params.init.body),
          bodyText: params.init.body, headers: Object.fromEntries(params.init.headers),
          timeoutSeconds: params.timeoutSeconds });
        this.nowMs += 7;
        return run({ response: Response.json(plain(this.payload)) });
      },
      readProviderJsonResponse: async (response, errorLabel, options) => {
        record('successful-json-fixture', { errorLabel, options: plain(options) });
        return response.json();
      },
      assertPluginCapabilitySecretAvailable: () => record('literal-fixture-config-availability'),
      resolveReadOnlyEnvSecretRef: ({ value, normalizeValue }) => {
        record('literal-fixture-string-resolution', { valueKind: typeof value });
        assert.equal(typeof value, 'string');
        return { status: 'available', value: normalizeValue(value) };
      },
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records exact request built by actual common module; supplies successful synthetic Response and advances synthetic clock 7ms; network, policy and timer execution unverified',
      readProviderJsonResponse: 'records actual label/maxBytes and uses successful fixture Response.json; production bounded parser unexecuted',
      assertPluginCapabilitySecretAvailable: 'explicit available literal fixture; production availability unexecuted',
      resolveReadOnlyEnvSecretRef: 'explicit literal fixture string normalized by actual supplied normalizeValue; production secret discovery unexecuted',
    };
    return this.synthetic('tavily-search:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'tavily-search:platform') return this.platform();
    if (importer === readers && specifier === './tool-results.js') {
      link('executed-whole-module', results);
      return this.source(results);
    }
    if (importer === 'src/plugin-sdk/plugin-entry.ts' && specifier === '../plugins/config-schema.js') {
      const path = 'src/plugins/config-schema.ts';
      this.verifiedSource(path, false);
      link('unused-lazy-config-schema-service', path);
      return this.deferred(importer, specifier, ['emptyPluginConfigSchema', 'buildJsonPluginConfigSchema', 'buildPluginConfigSchema']);
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
      while (!existsSync(join(root, 'package.json'))) root = dirname(root);
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
    if (importer.startsWith('tavily-search:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('tavily-search:typebox:'.length)), specifier)));
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      const path = 'src/web-search/runtime-error.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier,
        ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk)
        ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier];
      const id = 'tavily-search:facade:' + specifier;
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
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN,
    tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}

// Remove only the exact pinned deterministic Web Search envelope. Provider
// whitespace remains meaningful; public projections use the actual source unwrap.
export function unframeSearchText(value) {
  const start = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n';
  const end = '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
  if (!value.startsWith(start)) return value;
  assert.ok(value.endsWith(end), 'exact pinned Web Search frame');
  return value.slice(start.length, -end.length);
}
function mapResultText(result, transform) {
  const copy = plain(result);
  for (const row of copy.results) for (const key of ['title', 'snippet', 'siteName']) {
    if (typeof row[key] === 'string') row[key] = transform(row[key]);
  }
  if (typeof copy.answer === 'string') copy.answer = transform(copy.answer);
  return copy;
}
export function portableSearchResult(result) {
  const copy = plain(result);
  delete copy.externalContent;
  return copy;
}
const row = (n, extra = {}) => ({ title: `Source ${n}`, url: `https://source.example/${n}`,
  content: `Passage ${n}`, score: 0.9, published_date: '2026-01-02T03:04:05.678Z', ...extra });
const payload = (count = 3, extra = {}) => ({ results: Array.from({ length: count }, (_, n) => row(n + 1)),
  response_time: 0.125, request_id: 'ordinary-fixture', ...extra });
const step = (arguments_, options = {}) => ({ arguments: arguments_, ...options });
function recipes() {
  const rows = [];
  const add = (id, surface, args, options = {}) => rows.push({ id, surface,
    steps: options.steps ?? [step(args ?? { query: id })], ...options });
  for (const surface of ['generic', 'dedicated']) {
    add(`${surface}-default`, surface, { query: ' ordinary Tavily query ' });
    add(`${surface}-twenty`, surface, { query: 'twenty', [surface === 'generic' ? 'count' : 'max_results']: 20 },
      { httpPayload: payload(21) });
    add(`${surface}-configured-search-defaults`, surface, { query: 'source defaults' },
      { searchConfig: { maxResults: 9, timeoutSeconds: 7 } });
  }
  add('dedicated-full-options', 'dedicated', { query: ' full options ', max_results: 20,
    search_depth: ' advanced ', topic: ' news ', include_answer: true, time_range: ' week ',
    include_domains: [' source.example ', '', 'docs.example'], exclude_domains: [' archive.example '] },
  { httpPayload: payload(20, { answer: ' Ordinary answer 😀 \n' }) });
  for (const depth of ['basic', 'advanced']) add(`depth-${depth}`, 'dedicated', {
    query: `depth ${depth}`, search_depth: depth,
  });
  for (const topic of ['general', 'news', 'finance']) add(`topic-${topic}`, 'dedicated', { query: `topic ${topic}`, topic });
  for (const time of ['day', 'week', 'month', 'year']) add(`time-${time}`, 'dedicated', {
    query: `time ${time}`, time_range: time,
  });
  add('answer-true', 'dedicated', { query: 'answer enabled', include_answer: true },
    { httpPayload: payload(1, { answer: ' Answer enabled ' }) });
  add('answer-false', 'dedicated', { query: 'answer disabled', include_answer: false });
  add('answer-returned-without-optin', 'dedicated', { query: 'provider answer', include_answer: false },
    { httpPayload: payload(1, { answer: ' Ordinary provider answer ' }) });
  add('dedicated-empty-options', 'dedicated', { query: ' empty options ', search_depth: ' ', topic: '',
    time_range: '\t', include_domains: ['', ' '], exclude_domains: [], include_answer: false });
  add('dedicated-scientific-count', 'dedicated', { query: 'raw numeric reader', max_results: '2.e0' });
  add('generic-scientific-count', 'generic', { query: 'raw numeric reader', count: '2e0' });
  add('endpoint-proxy', 'dedicated', { query: 'proxy' }, { baseUrl: ' https://search.example/proxy/ ' });
  add('result-full-dates', 'dedicated', { query: 'ordinary dates', max_results: 6 }, {
    httpPayload: { results: [
      row(1, { published_date: 'Thu, 02 Jan 2025 03:04:05 GMT' }),
      row(2, { published_date: '2026-02-03T04:05:06.789Z' }),
      row(3, { published_date: '2026-03-04 05:06:07+00:00' }),
      row(4, { published_date: '2026-04-05' }),
      { title: '', content: '', url: 'https://bare.example', score: 0 },
      { url: 'https://SOURCE.EXAMPLE:443/ordinary path?q=hello world#section', title: ' Canonical title ', content: ' Canonical snippet ' },
    ] },
  });
  add('result-unicode-whitespace', 'dedicated', { query: 'Unicode', include_answer: true }, {
    httpPayload: { results: [row(1, { title: ' \t標題😀e\u0301 👩‍💻 \n', content: ' \t本文界😀 \n' })],
      answer: ' \tAnswer 界😀e\u0301 👩‍💻 \n' },
  });
  add('result-first-count', 'dedicated', { query: 'first count', max_results: 2 }, { httpPayload: payload(3) });
  add('result-empty-success', 'dedicated', { query: 'ordinary empty', include_answer: true },
    { httpPayload: { results: [], answer: ' Answer without result rows ' } });
  for (const [id, unit] of [['emoji', '😀'], ['combining', 'e\u0301'], ['zwj', '👩‍💻']]) {
    for (const surface of ['generic', 'dedicated']) add(`${surface}-budget-${id}`, surface,
      { query: `${surface} ${id}`, [surface === 'generic' ? 'count' : 'max_results']: 2,
        ...(surface === 'dedicated' ? { include_answer: true } : {}) }, {
        httpPayload: { results: [row(1, { title: unit.repeat(12_000), content: unit.repeat(12_000) }), row(2)],
          answer: 'Later answer' },
      });
  }
  add('budget-answer-after-rows', 'dedicated', { query: 'answer budget', max_results: 2, include_answer: true }, {
    httpPayload: { results: [row(1, { title: 'T'.repeat(8_000), content: 'S'.repeat(8_000) }),
      row(2, { title: 'U'.repeat(1_000), content: 'V'.repeat(1_000) })], answer: 'A'.repeat(2_001) },
  });
  add('cache-repeat-dedicated', 'dedicated', undefined, { steps: [
    step({ query: ' cached query ', search_depth: ' basic ', include_domains: [' source.example ', ''] }),
    step({ query: 'cached query', search_depth: 'basic', include_domains: ['source.example'] }),
  ] });
  add('cache-repeat-generic', 'generic', undefined, { steps: [
    step({ query: ' authored query ' }), step({ query: ' authored query ' }), step({ query: 'authored query' }),
  ] });
  add('cache-count', 'dedicated', undefined, { steps: [1, 2, 1].map(count =>
    step({ query: 'cache count', max_results: count })) });
  add('cache-options', 'dedicated', undefined, { steps: [
    step({ query: 'cache options' }), step({ query: 'cache options', include_answer: true }),
    step({ query: 'cache options', topic: 'news' }), step({ query: 'cache options' }),
  ] });
  add('cache-current-config', 'dedicated', undefined, { steps: [
    step({ query: 'current config' }),
    step({ query: 'current config' }, { baseUrl: 'https://proxy.example/tavily' }),
    step({ query: 'current config' }, { baseUrl: 'https://api.tavily.com' }),
  ] });
  add('cache-caller-settings', 'dedicated', undefined, { steps: [
    step({ query: 'caller settings' }),
    step({ query: 'caller settings' }, { searchConfig: { maxResults: 12, timeoutSeconds: 7 } }),
    step({ query: 'caller settings' }, { searchConfig: { cacheTtlMinutes: 0 } }),
    step({ query: 'caller settings' }, { searchConfig: { cacheTtlMinutes: 15 } }),
  ] });
  return rows;
}

export async function captureTavilySearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new TavilySearchCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new TavilySearchCapture(root, recipe.httpPayload ?? payload());
    const module = capture.source(index);
    await capture.evaluate(module);
    let config = { plugins: { entries: { tavily: { config: { webSearch: {
      apiKey: 'fixture-tavily-key', ...(recipe.baseUrl ? { baseUrl: recipe.baseUrl } : {}),
    } } } } }, tools: { web: { search: { cacheTtlMinutes: 15, ...recipe.searchConfig } } } };
    const initialConfig = plain(config), registered = [], providers = [];
    module.namespace.default.register({ config,
      registerWebSearchProvider: provider => providers.push(provider),
      registerTool: (factory, options) => registered.push({ factory, options: plain(options) }),
    });
    const provider = providers.find(item => item.id === 'tavily');
    assert.ok(provider);
    const dedicated = recipe.surface === 'dedicated';
    const factory = registered.find(item => item.options.name === 'tavily_search');
    assert.ok(factory);
    const dedicatedTool = dedicated ? factory.factory({ getRuntimeConfig: () => config }) : null;
    const initialTool = dedicatedTool ?? provider.createTool({ config, searchConfig: config.tools.web.search });
    const descriptor = plain({ name: initialTool.name, label: initialTool.label,
      resultContentSource: initialTool.resultContentSource, description: initialTool.description, parameters: initialTool.parameters });
    const registration = { pluginId: module.namespace.default.id,
      providers: providers.map(item => ({ id: item.id, label: item.label })),
      tools: registered.map(item => item.options),
      boundary: 'actual plugin.register constructs provider/tool factories on a minimal API fixture; host assembly unexecuted' };
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      if (item.baseUrl) config = { ...config, plugins: { entries: { tavily: { config: { webSearch: {
        ...config.plugins.entries.tavily.config.webSearch, baseUrl: item.baseUrl,
      } } } } } };
      if (item.searchConfig) config = { ...config, tools: { web: { search: {
        ...config.tools.web.search, ...item.searchConfig,
      } } } };
      const setup = { config, searchConfig: config.tools.web.search };
      const configBefore = plain(config);
      const tool = dedicatedTool ?? provider.createTool(setup);
      const args = plain(item.arguments), original = plain(args), requestCount = capture.requests.length;
      const clock = new Date(capture.nowMs).toISOString();
      const raw = dedicated ? await tool.execute(`search-${recipe.id}-${n}`, args) : await tool.execute(args);
      const toolResult = dedicated ? plain(raw) : null;
      const providerResult = plain(dedicated ? raw.details : raw);
      assert.deepEqual(args, original);
      assert.deepEqual(config, configBefore);
      assert.equal(providerResult.provider, 'tavily');
      if (dedicated) assert.deepEqual(JSON.parse(toolResult.content[0].text), providerResult);
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      const providerUnframedResult = mapResultText(providerResult, unframeSearchText);
      const publicResult = plain(normalize({ result: providerResult, provider: 'tavily', query: original.query }));
      assert.equal(publicResult.kind, 'results', recipe.id);
      const publicUnwrappedResult = mapResultText(publicResult, unwrap);
      steps.push({ arguments: original, argumentsAfter: plain(args), clock, setup: plain(setup),
        configBefore, configAfter: plain(config), request: requests[0] ?? null,
        cumulativeRequests: capture.requests.length, cached: providerResult.cached === true,
        toolResult, providerResult, providerUnframedResult,
        providerPortableResult: portableSearchResult(providerUnframedResult), publicResult, publicUnwrappedResult,
        publicPortableResult: portableSearchResult(publicUnwrappedResult) });
    }
    groups.push({ id: recipe.id, surface: recipe.surface, provider: 'tavily', config: initialConfig,
      configAfter: plain(config), registration, descriptor,
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, autoDetectOrder: provider.autoDetectOrder }),
      httpPayload: plain(capture.payload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-tavily-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported pin-verified whole-module loader and deterministic randomBytes; Tavily extract capture-only loader facilities copied into this new file' }],
    invocations: ['defaultPlugin.register(apiFixture)', 'createTavilyWebSearchProvider().createTool(setup).execute(arguments)',
      'registered tavily_search factory({getRuntimeConfig}).execute(callId,arguments)',
      'whole runTavilySearch(params)', 'normalizeWebSearchOutput({result,provider,query})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: true,
      genericAndDedicatedCallbacksInvoked: true, actualJsonResult: true, actualCommonPost: true,
      actualSharedCache: true, genericNormalizerInvoked: true, productionNetworkInvoked: false, fixtureEnvironment: {},
      unwrap: 'providerUnframedResult removes exact deterministic Web Search frames without trimming; providerPortableResult additionally removes only top-level externalContent; public variants use actual source unwrapWebSearchOutputText; complete framed originals retained',
      publicProjection: 'actual generic normalizer also observed after dedicated results as a separate comparison; original dedicated output remains full jsonResult',
      limits: [
        'All58558 tracked source blobs verified before/after; executed means complete module evaluated, not every export called',
        'Actual plugin registration, generic provider and dedicated tool factory/callback execute; extraction callbacks unexecuted',
        'Actual common request/headers/serialization and successful branch execute; endpoint callback and Response.json parser are explicit fixtures',
        'Literal available config bindings only; production discovery/availability, endpoint policy, bounded parser, timers/network unexecuted',
        'Declared source schemas use integer parameters; separate raw numeric strings exercise accepted readers, not a claim that the typed native schema admits them',
        'Generic source schema/count20 differs from the source generic public projection max10; authored generic query differs from dedicated reader trimming',
        'Controlled ordinary base URL/cache settings are harness-owned inputs; each step records actual config before/after source callback',
        'Only ordinary successful callbacks; no security/permission/auth/TLS/negative/mixed/real-provider/failure/cancel/crash tests',
        'Native Worker/persistence/replay, full sanitizer/WHATWG equivalence, runtime assembly and real-provider acceptance remain independent host work',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(item => item.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(item => !item.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, item) => sum + item.steps.length, 0),
      httpCallbacks: groups.reduce((sum, item) => sum + item.steps.filter(part => part.request !== null).length, 0) },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', destination;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1]; else destination = args[n + 1];
  }
  const json = JSON.stringify(await captureTavilySearch(root), null, 2) + '\n';
  if (destination) writeFileSync(destination, json); else process.stdout.write(json);
}

