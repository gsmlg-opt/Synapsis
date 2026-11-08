// Ordinary Ollama callbacks from complete unchanged pinned OpenClaw modules.
// Successful HTTP/JSON/release, literal configuration, policy and clock are fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/ollama/src/web-search-provider.ts';
const runtime = 'extensions/ollama/src/web-search-provider.runtime.ts';
const models = 'extensions/ollama/src/provider-models.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const fetchUtils = 'src/agents/tools/web-fetch-utils.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const extraSources = new Set([factory, runtime, models, output, fetchUtils,
  'extensions/ollama/web-search-contract-api.ts',
  ...['web-search-provider-registration', 'web-search-contract', 'defaults', 'provider-base-url', 'model-reasoning']
    .map(name => 'extensions/ollama/src/' + name + '.ts'),
  'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-enable-config.ts',
  'src/config/plugins-allowlist.ts']);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'resolveSearchCount', 'resolveSiteName'], common),
    from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
    from(['resolveProviderWebSearchPluginConfig'], 'src/agents/tools/web-search-provider-config.ts'),
    from(['readResponseText'], 'src/agents/tools/web-shared.ts'),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
    from(['truncateWebFetchText as truncateText'], fetchUtils),
    'export {resolveWebSearchProviderCredential} from "ollama:literal-config";',
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule', 'createLazyRuntimeSurface'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: [
    'export {readProviderJsonResponse} from "ollama:platform";',
    'export {ProviderHttpError,redactProviderResponseErrorText} from "ollama:unused-http-errors";',
  ].join('\n'),
  [sdk + 'provider-auth']: 'export {isNonSecretApiKeyMarker,normalizeOptionalSecretInput} from "ollama:literal-config";',
  [sdk + 'provider-auth-runtime']: 'export {resolveEnvApiKey} from "ollama:literal-config";',
  [sdk + 'secret-input']: 'export {coerceSecretRef} from "ollama:literal-config";',
  [sdk + 'ssrf-runtime']: 'export {fetchWithSsrFGuard} from "ollama:platform";',
};

class OllamaCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
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
    const id = 'ollama:typebox:' + relative(this.typeboxRoot, file);
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
      fetchWithSsrFGuard: async params => {
        this.audit.push({ kind: 'successful-http-fixture', timeoutMs: params.timeoutMs });
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), body: JSON.parse(params.init.body),
          bodyText: params.init.body, headers: plain(params.init.headers),
          timeoutMs: params.timeoutMs, auditContext: params.auditContext });
        this.nowMs += 7;
        return { response: Response.json(plain(this.payload)), release: async () => {
          this.audit.push({ kind: 'successful-release-fixture' });
        } };
      },
      readProviderJsonResponse: async (response, label) => {
        this.audit.push({ kind: 'successful-json-fixture', label });
        return response.json();
      },
      buildOllamaBaseUrlSsrFPolicy: () => {
        this.audit.push({ kind: 'policy-fixture', behavior: 'opaque trusted fixture policy' });
        return Object.freeze({ fixturePolicy: 'trusted-ordinary-endpoint' });
      },
    };
    const descriptions = {
      fetchWithSsrFGuard: 'records unchanged provider request and fixed timeout; synthetic successful Response, fixture release and clock+7ms; real network, guard, deadlines and cancellation unexecuted',
      readProviderJsonResponse: 'successful fixture Response.json; production bounded parser and error checks unexecuted',
      buildOllamaBaseUrlSsrFPolicy: 'opaque policy token; actual policy/SSRF/security behavior unexecuted',
    };
    return this.synthetic('ollama:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  literalConfig() {
    const record = name => this.audit.push({ kind: 'literal-config-fixture', export: name });
    const bindings = {
      resolveWebSearchProviderCredential: ({ credentialValue }) => {
        record('resolveWebSearchProviderCredential');
        assert.ok(credentialValue === undefined || typeof credentialValue === 'string');
        return credentialValue;
      },
      normalizeOptionalSecretInput: value => {
        record('normalizeOptionalSecretInput');
        assert.ok(value === undefined || typeof value === 'string');
        return value;
      },
      isNonSecretApiKeyMarker: () => { record('isNonSecretApiKeyMarker'); return false; },
      resolveEnvApiKey: () => { record('resolveEnvApiKey'); return undefined; },
      coerceSecretRef: () => { record('coerceSecretRef'); return undefined; },
    };
    return this.synthetic('ollama:literal-config', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'literal-config-fixture',
        behavior: 'only explicit ordinary fixture literals/absence; no actual credentials, marker filtering, env discovery, SecretRef or secret resolution' }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    const deferred = (path, names, kind = 'unused-platform-service') => {
      this.verifiedSource(path, false);
      link(kind, path);
      return this.deferred(importer, specifier, names);
    };
    if (specifier === 'ollama:platform') return this.platform();
    if (specifier === 'ollama:literal-config') return this.literalConfig();
    if (importer === runtime && specifier === './provider-models.js') {
      const generatedCode = [from(['resolveOllamaApiBase'], models),
        'export {buildOllamaBaseUrlSsrFPolicy} from "ollama:platform";',
        'export {fetchOllamaModels} from "ollama:unused-model-discovery";'].join('\n');
      const id = 'ollama:facade:provider-models';
      this.generatedFacades.set(id, { specifier, provenance: models, generatedCode, sha256: digest(generatedCode) });
      link('whole-base-url-helper-and-explicit-policy-fixture', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode,
        { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    if (specifier === 'ollama:unused-model-discovery') return deferred(models, ['fetchOllamaModels']);
    if (specifier === sdk + 'provider-web-search-contract') {
      const path = 'src/plugin-sdk/provider-web-search-contract.ts';
      link('whole-module-alias', path);
      return this.source(path);
    }
    if (specifier === sdk + 'collection-runtime') {
      const path = 'src/plugin-sdk/collection-runtime.ts';
      this.verifiedSource(path, false);
      link('explicit-unused-model-cache-initialization-fixture', path);
      return this.synthetic('ollama:model-cache-initialization', {
        createStaleWhileRevalidateCache: options => {
          this.audit.push({ kind: 'model-cache-initialization-fixture',
            maxEntries: options.maxEntries, maxPending: String(options.maxPending), ttlMs: String(options.ttlMs),
            cacheable: typeof options.cacheable });
          return Object.freeze({ fixture: 'unused-model-discovery-cache' });
        },
      }, { createStaleWhileRevalidateCache: { kind: 'ordinary-platform-initialization-fixture',
        behavior: 'records whole provider-models module body initialization only; discovery/cache methods unexecuted' } });
    }
    if ([sdk + 'model-ref-parse', sdk + 'provider-model-shared'].includes(specifier)) {
      return deferred('src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts', ['isCloudModelRef']);
    }
    if (specifier === sdk + 'error-runtime') return deferred('src/plugin-sdk/error-runtime.ts', ['toErrorObject']);
    if (specifier === sdk + 'provider-catalog-live-runtime') return deferred('src/plugin-sdk/provider-catalog-live-runtime.ts', ['LiveModelCatalogHttpError']);
    if (specifier === 'ollama:unused-http-errors') {
      return deferred('src/agents/provider-http-errors.ts', ['ProviderHttpError', 'redactProviderResponseErrorText']);
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      return deferred('src/web-search/runtime-error.ts', ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
    }
    const unusedFetchImports = {
      '../../../packages/markdown-core/src/html-scanner.js': ['RAW_TEXT_TAGS', 'readRawTextOpenTagName',
        'findRawTextOpenTagStart', 'startsLikeHtmlTag', 'readTagToken', 'readRawTextBounds', 'skipRawTextElement'],
      '../../infra/unicode-visibility.js': ['stripInvisibleUnicode'],
      '../../shared/html-entities.js': ['decodeHtmlEntities'],
      './web-fetch-attributes.js': ['readHtmlAttribute'],
      './web-fetch-visibility.js': ['sanitizeHtml'],
    };
    if (importer === fetchUtils && unusedFetchImports[specifier]) {
      const path = relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      return deferred(path, unusedFetchImports[specifier], 'unused-html-service');
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
    if (importer.startsWith('ollama:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('ollama:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier];
      const id = 'ollama:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode,
        { context: this.context, identifier: id }));
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

const row = (n, extra = {}) => ({ title: ` Source ${n} 😀 `, url: `https://www.source.example/${n}`,
  content: ` Search description ${n} 文 `, date: '2026-10-17', ...extra });
const payload = count => ({ results: Array.from({ length: count }, (_, index) => row(index + 1)) });
const step = args => ({ arguments: args });
function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) =>
    rows.push({ id, steps: [step(args)], httpPayload: payload(6), ...options });
  add('search-default');
  add('operator-query', { query: ' OpenClaw site:github.com -site:archive.example lang:en after:2026 "release notes" ' });
  add('unicode-query', { query: ' 界😀e\u0301 👩‍💻 ordinary search ' });
  add('explicit-count', { query: 'ordinary explicit count', count: 4 });
  add('numeric-count-token', { query: 'ordinary numeric token', count: ' 3 ' });
  add('configured-count-ignored', undefined, { searchConfig: { maxResults: 2 } });
  add('configured-timeout-ignored', undefined, { searchConfig: { timeoutSeconds: 7 } });
  add('endpoint-plugin-prefix', undefined, { providerConfig: { baseUrl: ' http://127.0.0.1:18181/proxy/v1/// ' } });
  add('endpoint-model-base-url', undefined, { modelConfig: { baseUrl: ' http://127.0.0.1:18182/model/V1/ ' } });
  add('endpoint-model-baseURL', undefined, { modelConfig: { baseURL: ' http://127.0.0.1:18183/alternate/v1/// ' } });
  add('endpoint-model-base-url-precedence', undefined, { modelConfig: {
    baseUrl: 'http://127.0.0.1:18184/primary/v1', baseURL: 'http://127.0.0.1:18185/alternate/v1',
  } });
  add('endpoint-plugin-precedence', undefined, { providerConfig: { baseUrl: 'http://127.0.0.1:18186/plugin/V1/' },
    modelConfig: { baseUrl: 'http://127.0.0.1:18187/model/v1' } });
  add('direct-hosted', undefined, { providerConfig: { baseUrl: ' https://ollama.com/v1/// ' },
    modelConfig: { apiKey: 'fixture-ollama-key' } });
  add('direct-hosted-prefix', undefined, { providerConfig: { baseUrl: 'https://ollama.com/trusted/V1/' },
    modelConfig: { apiKey: 'fixture-ollama-key' } });
  add('ordered-metadata', { query: 'ordered source results' }, { httpPayload: { results: [
    { title: ' First 😀 ', url: ' https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world ',
      content: ' First description 文 ', published: '2026-10-17', siteName: 'ignored.example', extra: 'ignored' },
    { title: ' Second ', url: 'https://two.example', content: ' Second description ', date: '2026-10-18' },
    { title: ' Third ', url: 'https://three.example/ordinary', content: ' Third description' },
  ], metadata: { request: 'ordinary-success' } } });
  add('sparse-results', undefined, { httpPayload: { results: [
    { url: 'https://sparse.example/one' },
    { title: ' Title only ', url: 'https://sparse.example/two', content: null },
    { title: null, url: 'https://sparse.example/three', content: ' Description only ' },
  ] } });
  add('successful-empty', undefined, { httpPayload: { results: [] } });
  add('successful-missing-results', undefined, { httpPayload: {} });
  add('same-query-repeated', undefined, { steps: [
    step({ query: ' same ordinary query ', count: 3 }), step({ query: 'same ordinary query', count: 3 }),
  ] });
  add('count-sequence', undefined, { steps: [
    step({ query: 'count ordinary query', count: 2 }), step({ query: 'count ordinary query', count: 4 }),
    step({ query: 'count ordinary query', count: 2 }),
  ] });
  add('endpoint-prefix-ending-v1', undefined, { providerConfig: {
    baseUrl: 'http://ordinary.example/proxy/v1/v1///',
  } });
  return rows;
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['title', 'snippet', 'siteName'].includes(field) ? unwrap(value) : value;
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

// Transport adaptation: remove one exact pinned frame without interpreting its body.
export function unframeOllamaSearchText(text) {
  if (text === '') return text;
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope');
  return match[2];
}
function providerPortable(value) {
  const copy = portable(value);
  copy.results = copy.results.map(row => ({ ...row,
    title: unframeOllamaSearchText(row.title), snippet: unframeOllamaSearchText(row.snippet),
  }));
  return copy;
}

export async function captureOllamaSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new OllamaCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new OllamaCapture(root, recipe.httpPayload);
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createOllamaWebSearchProvider();
    const config = { plugins: { entries: { ollama: { config: { webSearch: {
      ...recipe.providerConfig,
    } } } } } };
    if (recipe.modelConfig) config.models = { providers: { ollama: plain(recipe.modelConfig) } };
    const setup = { config, searchConfig: { maxResults: 5, ...recipe.searchConfig } };
    const originalSetup = plain(setup);
    const initialTool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString();
      const args = plain(item.arguments), original = plain(args), requestCount = capture.requests.length;
      const tool = provider.createTool(setup);
      const providerResult = plain(await tool.execute(args));
      assert.deepEqual(args, original);
      assert.deepEqual(setup, originalSetup);
      assert.equal(providerResult.provider, 'ollama', recipe.id);
      const requests = capture.requests.slice(requestCount);
      assert.equal(requests.length, 1, 'ordinary first successful request for every source callback');
      const genericResult = plain(normalize({ result: providerResult, provider: 'ollama', query: original.query }));
      assert.equal(genericResult.kind, 'results', recipe.id);
      const providerUnwrappedResult = unwrapResult(providerResult, unwrap);
      const genericUnwrappedResult = unwrapResult(genericResult, unwrap);
      const genericPortableResult = portable(genericUnwrappedResult);
      steps.push({ arguments: original, argumentsAfter: plain(args), clock, setup: plain(setup),
        request: requests[0], providerResult, providerUnwrappedResult,
        providerPortableResult: providerPortable(providerResult),
        genericResult, genericUnwrappedResult, genericPortableResult,
        publicResult: genericResult, publicUnwrappedResult: genericUnwrappedResult,
        publicPortableResult: genericPortableResult, cumulativeRequests: capture.requests.length });
    }
    groups.push({ id: recipe.id, setup: originalSetup, setupAfter: plain(setup),
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, requiresCredential: provider.requiresCredential,
        envVars: provider.envVars, placeholder: provider.placeholder, signupUrl: provider.signupUrl,
        docsUrl: provider.docsUrl, autoDetectOrder: provider.autoDetectOrder, credentialPath: provider.credentialPath }),
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayload: plain(capture.payload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-ollama-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, synthetic clock/randomBytes; own audited Ollama facades, literal-config/platform/model-initialization fixtures and actual TypeBox loading' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    invocations: ['createOllamaWebSearchProvider()',
      'createOllamaWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider,query:authoredArguments.query})',
      'unwrapWebSearchOutputText(providerAndGenericProse)'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true,
      publicCallbackInvoked: true, actualProviderRequestBuilder: true, actualBaseUrlHelper: true,
      actualCountReaders: true, genericNormalizerInvoked: true, actualUnwrapInvoked: true,
      actualTypeBox: true, sourceProviderCache: false, hostSharedCacheAdaptation: true,
      actualBoundedSuccessReader: false, actualEndpointPolicy: false, actualCredentialResolution: false,
      productionNetworkInvoked: false, pluginRegistrationInvoked: false, fixtureEnvironment: {},
      unwrap: 'providerPortableResult removes one exact pinned Web Search envelope from title/snippet; providerUnwrappedResult and genericUnwrappedResult independently use actual source unwrap for title/snippet/siteName; genericPortableResult removes only top-level externalContent; original framed results remain; public fields alias generic fields',
      limits: [
        'All58558 tracked source blobs verified before/after; executed means whole module evaluated, not all exports or branches called',
        'Actual unchanged factory, contract, lazy runtime, config/base URL helpers, common positive count/string readers, short result normalization, generic normalizer and source unwrap execute',
        'Whole provider-models module supplies actual resolveOllamaApiBase; model cache body initialization is explicit fixture; discovery and policy exports are not invoked',
        'Successful synthetic Response, JSON reader and release are explicit fixtures; production network, parser, DNS/proxy/SSRF/policy, deadlines and cancellation unexecuted',
        'Only explicit ordinary literal/absent configuration bindings; actual marker filtering, credential/SecretRef resolution and ambient env discovery unexecuted; process.env is empty',
        'Direct hosted literal credential is an ordinary successful request fixture only; no authentication behavior or credential segregation qualification',
        'Source fixed15000ms per request; source default count5 ignores searchConfig.maxResults and timeoutSeconds; host original-deadline timeout configuration is an adaptation',
        'Source Ollama provider has no cache; every repeated source callback makes a synthetic HTTP request; Synapsis shared cache and authored publicquery are explicit host adaptations',
        'Provider privately trims query/title/url/content; generic normalizer retains authored query and canonicalizes URLs; metadata not returned by source remains absent',
        'All payloads have under10 rows and all content under300UTF16units; no count boundary, long snippet, truncation, budget, threshold, failure, fallback404, auth error, crash, cancel or race execution',
        'Unused HTTP errors, model services and HTML services are deferred throwing bindings; full sanitizer/framing/Unicode/URL and plugin assembly qualification remain deferred',
        'No Synapsis production execution, native Worker/Concord, remote provider, deployment or release acceptance',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((sum, row) => sum + row.steps.filter(step => step.request !== null).length, 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source,
      gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureOllamaSearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}
