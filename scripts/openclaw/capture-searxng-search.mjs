// Complete unchanged pinned SearXNG modules; only short successful platform fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const entrypoint = 'extensions/searxng/web-search-provider.ts';
const factory = 'extensions/searxng/src/searxng-search-provider.ts';
const client = 'extensions/searxng/src/searxng-client.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const shared = 'src/agents/tools/web-shared.ts';
const output = 'src/agents/tools/web-search-output.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const literalBase = 'https://search.example';
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const additionalSources = new Set([entrypoint, factory, client, output,
  'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-enable-config.ts',
  'src/config/plugins-allowlist.ts']);
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'DEFAULT_SEARCH_COUNT', 'readCachedSearchPayload', 'resolveSearchCount',
      'resolveSiteName', 'writeCachedSearchPayload'], common),
    from(['DEFAULT_CACHE_TTL_MINUTES', 'resolveCacheTtlMs', 'resolveTimeoutSeconds'], shared),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
    'export {readResponseText,withSelfHostedWebSearchEndpoint,withTrustedWebSearchEndpoint} from "searxng:platform";',
  ].join('\n'),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields',
    'WEB_SEARCH_QUERY_COUNT_PROPERTIES'], 'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'param-readers']: from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
  [sdk + 'string-coerce-runtime']: [
    from(['asOptionalObjectRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "searxng:platform";',
  [sdk + 'ssrf-runtime']: 'export {assertHttpUrlTargetsPrivateNetwork,isBlockedHostnameOrIp,isPrivateIpAddress,resolvePinnedHostnameWithPolicy} from "searxng:platform";',
  [sdk + 'provider-http']: 'export {ProviderHttpError} from "searxng:platform";',
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};
const deferredImports = [
  [readers, '@openclaw/media-core/mime', ['detectMime'], 'packages/media-core/src/mime.ts'],
  [readers, '../../infra/fs-safe.js', ['readLocalFileSafely']],
  [readers, './tool-results.js', ['textResult', 'jsonResult']],
  [common, '../provider-http-errors.js', ['createProviderErrorTextRedactor', 'ProviderHttpError']],
  [output, '../../web-search/runtime-error.js', ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']],
];

class SearxngCapture extends BraveCapture {
  constructor(root, payloads) {
    super(root);
    this.payloads = payloads;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
  }
  source(path) {
    if (!additionalSources.has(path)) return super.source(path);
    if (!this.modules.has(path)) this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
      context: this.context, identifier: path,
      importModuleDynamically: async specifier => {
        this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
        const target = this.import(specifier, path); await this.evaluate(target); return target;
      },
    }));
    return this.modules.get(path);
  }
  typeboxModule(file) {
    assert.ok(file.startsWith(this.typeboxRoot + sep));
    const id = 'searxng:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file), path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  platform() {
    const record = (kind, details = {}) => this.audit.push({ kind, ...details });
    const unused = name => () => { record('unused-service-invoked', { export: name }); throw Error('Unused: ' + name); };
    const bindings = {
      resolveReadOnlyEnvSecretRef: params => {
        assert.equal(typeof params.value, 'string');
        assert.ok(params.value.trim().startsWith('https://'));
        assert.equal(params.path, 'plugins.entries.searxng.config.webSearch.baseUrl');
        assert.equal(params.expectedEnvId, 'SEARXNG_BASE_URL');
        assert.equal(params.cfg.plugins.entries.searxng.config.webSearch.baseUrl, params.value);
        record('configured-literal-base-fixture', { value: params.value, path: params.path, expectedEnvId: params.expectedEnvId });
        return { status: 'available', value: params.normalizeValue(params.value) };
      },
      isBlockedHostnameOrIp: hostname => { record('fixed-hostname-classification', { hostname }); return false; },
      resolvePinnedHostnameWithPolicy: async (hostname, options) => {
        record('synthetic-public-address', { hostname, options: plain(options) });
        return { addresses: ['93.184.216.34'] };
      },
      isPrivateIpAddress: address => { record('fixed-address-classification', { address }); return false; },
      withTrustedWebSearchEndpoint: async (params, run) => {
        const url = new URL(params.url);
        record('successful-http-fixture', { url: params.url });
        const payload = this.payloads[Math.min(this.requests.length, this.payloads.length - 1)];
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: Object.fromEntries(new Headers(params.init.headers)),
          timeoutSeconds: params.timeoutSeconds, signalSupplied: params.signal !== undefined });
        this.nowMs += 7;
        return run(new Response(JSON.stringify(payload), { headers: { 'content-type': 'application/json' } }));
      },
      readResponseText: async (response, options) => {
        record('successful-short-text-fixture', plain(options));
        const text = await response.text();
        return { text, truncated: false, bytesRead: Buffer.byteLength(text) };
      },
      assertHttpUrlTargetsPrivateNetwork: unused('assertHttpUrlTargetsPrivateNetwork'),
      withSelfHostedWebSearchEndpoint: unused('withSelfHostedWebSearchEndpoint'),
      ProviderHttpError: unused('ProviderHttpError'),
    };
    const descriptions = {
      resolveReadOnlyEnvSecretRef: 'only explicit configured HTTPS string/path/env-id; calls actual normalizeValue; fixed available status; source env/SecretRef discovery unexecuted',
      isBlockedHostnameOrIp: 'fixed false for fixture hostname; production classifier unexecuted',
      resolvePinnedHostnameWithPolicy: 'records source options; fixed synthetic public address 93.184.216.34; actual DNS/pinning/policy unexecuted',
      isPrivateIpAddress: 'fixed false for synthetic fixture address; production IP classifier unexecuted',
      withTrustedWebSearchEndpoint: 'records full actual GET request; synthetic successful Response; clock+7ms; production network/guard/TLS/deadline unexecuted',
      readResponseText: 'successful fixed short text with truncated=false and native byte length; actual bounded HTTP reader unexecuted',
    };
    return this.synthetic('searxng:platform', bindings, Object.fromEntries(Object.keys(bindings).map(name => [name,
      { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service',
        behavior: descriptions[name] ?? 'throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'searxng:platform') {
      for (const path of ['src/plugin-sdk/secret-ref-readonly.ts', 'src/plugin-sdk/secret-ref-readonly.internal.ts',
        'src/config/types.secrets.ts', 'src/agents/tools/web-guarded-fetch.ts', 'src/infra/net/ssrf.ts',
        'src/agents/provider-http-errors.ts']) this.verifiedSource(path, false);
      return this.platform();
    }
    const deferred = deferredImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = deferred[3] ?? relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false); link('explicit-unused-import', path);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve('typebox'));
      let root = dirname(file); while (!existsSync(join(root, 'package.json'))) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json')), pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox'); assert.equal(pkg.version, '1.3.37');
      this.typeboxRoot = root; this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file)); return this.typeboxModule(file);
    }
    if (importer.startsWith('searxng:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('searxng:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk) ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'searxng:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t'), [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path), symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(blob(bytes), gitBlob, path);
    return { path, gitBlob, sha256: digest(bytes) };
  });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN, tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}
export function unframeSearxngSearchText(text) {
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope'); return match[2];
}
function mapProse(value, adapt, field) {
  if (typeof value === 'string') return ['title', 'snippet', 'siteName'].includes(field) && value ? adapt(value, field) : value;
  if (Array.isArray(value)) return value.map(item => mapProse(item, adapt, field));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, mapProse(item, adapt, key)]));
  return value;
}
const ordinaryPayload = () => ({ results: [
  { title: ' First ordinary title ', url: 'https://docs.example/one', content: ' First ordinary snippet. ', img_src: 'https://images.example/one.png' },
  { title: 'Second ordinary title', url: 'https://news.example/two', content: 'Second ordinary snippet.' },
] });
const step = (args, providerConfig, searchConfig) => ({ arguments: args,
  ...(providerConfig ? { providerConfig } : {}), ...(searchConfig ? { searchConfig } : {}) });
function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) => rows.push({ id, steps: [step(args)], httpPayloads: [ordinaryPayload()], ...options });
  add('search-default');
  add('authored-query', { query: ' OpenClaw site:github.com "release notes" ' });
  add('explicit-count', { query: 'ordinary explicit count', count: 3 });
  add('numeric-count-token', { query: 'ordinary numeric count', count: ' 4 ' });
  add('configured-count', undefined, { searchConfig: { maxResults: 2 } });
  add('configured-timeout', undefined, { searchConfig: { timeoutSeconds: 9 } });
  add('context-search-options-ignored', undefined, { contextSearchConfig: { maxResults: 3, timeoutSeconds: 9, cacheTtlMinutes: 0 } });
  for (const [id, baseUrl] of [['base-root', 'https://search.example/'],
    ['base-prefix', 'https://search.example/meta/v2'], ['base-already-search', 'https://search.example/meta/search'],
    ['base-trailing-slashes', ' https://search.example/meta/// '],
    ['base-query-reset', 'https://search.example/meta/search?old=value&format=html']]) add(id, undefined, { providerConfig: { baseUrl } });
  add('configured-options', undefined, { providerConfig: { categories: ' news,science ', language: ' de ' } });
  add('argument-options', { query: 'ordinary options', categories: ' science,news ', language: ' fr ' },
    { providerConfig: { categories: 'general', language: 'en' } });
  add('ordered-optional-content', undefined, { httpPayloads: [{ results: [
    { title: 'Image source', url: 'https://images.example/item', img_src: 'https://images.example/thumb.png' },
    { title: 'Text source', url: 'https://docs.example/two', content: 'Ordinary text.' },
  ] }] });
  add('same-query-repeated', undefined, { steps: [step({ query: ' same ordinary query ' }), step({ query: 'same ordinary query' })] });
  add('query-case-identity', undefined, { steps: [step({ query: 'Ordinary Case Query' }), step({ query: 'ordinary case query' }), step({ query: ' Ordinary Case Query ' })] });
  add('query-interior-space-identity', undefined, { steps: [step({ query: 'ordinary  spaced query' }), step({ query: 'ordinary spaced query' }), step({ query: 'ordinary  spaced query' })] });
  add('count-identity', undefined, { steps: [step({ query: 'ordinary count identity', count: 3 }), step({ query: 'ordinary count identity', count: 4 }), step({ query: 'ordinary count identity', count: ' 3 ' })] });
  add('base-identity', undefined, { steps: [step({ query: 'ordinary base identity' }), step({ query: 'ordinary base identity' }, { baseUrl: 'https://search.example/meta' }), step({ query: 'ordinary base identity' })] });
  add('base-case-identity', undefined, { steps: [step({ query: 'ordinary base case' }, { baseUrl: 'https://search.example/Meta' }), step({ query: 'ordinary base case' }, { baseUrl: 'https://search.example/meta' }), step({ query: 'ordinary base case' }, { baseUrl: 'https://search.example/Meta' })] });
  add('base-query-identity', undefined, { steps: [step({ query: 'ordinary base query' }, { baseUrl: 'https://search.example/search?old=one' }), step({ query: 'ordinary base query' }, { baseUrl: 'https://search.example/search?old=two' }), step({ query: 'ordinary base query' }, { baseUrl: 'https://search.example/search?old=one' })] });
  add('base-normalized-equivalence', undefined, { steps: [step({ query: 'ordinary base equivalence' }), step({ query: 'ordinary base equivalence' }, { baseUrl: ' https://search.example/// ' })] });
  add('categories-identity', undefined, { steps: [step({ query: 'ordinary category identity', categories: 'news' }), step({ query: 'ordinary category identity', categories: 'science' }), step({ query: 'ordinary category identity', categories: ' news ' })] });
  add('language-identity', undefined, { steps: [step({ query: 'ordinary language identity', language: 'en' }), step({ query: 'ordinary language identity', language: 'de' }), step({ query: 'ordinary language identity', language: ' en ' })] });
  add('cache-off', undefined, { searchConfig: { cacheTtlMinutes: 0 }, steps: [step({ query: 'ordinary cache off' }), step({ query: 'ordinary cache off' })] });
  add('cache-off-on', undefined, { steps: [step({ query: 'ordinary cache off on' }, undefined, { cacheTtlMinutes: 0 }), step({ query: 'ordinary cache off on' }), step({ query: 'ordinary cache off on' })] });
  add('cache-on-off-on', undefined, { steps: [step({ query: 'ordinary cache on off on' }), step({ query: 'ordinary cache on off on' }, undefined, { cacheTtlMinutes: 0 }), step({ query: 'ordinary cache on off on' })] });
  add('empty-category-general-retry', { query: 'ordinary empty category', categories: ' news,science ' }, { httpPayloads: [{ results: [] }, ordinaryPayload()] });
  add('empty-general-no-retry', { query: 'ordinary empty general', categories: 'general' }, { httpPayloads: [{ results: [] }] });
  add('empty-includes-general-no-retry', { query: 'ordinary empty category list', categories: 'news, General' }, { httpPayloads: [{ results: [] }] });
  add('empty-unspecified-no-retry', undefined, { httpPayloads: [{ results: [] }] });
  return rows;
}
function makeSetup(recipe, item = {}) {
  const searchConfig = { cacheTtlMinutes: 15, ...recipe.searchConfig, ...item.searchConfig };
  return { config: { tools: { web: { search: searchConfig } }, plugins: { entries: { searxng: { config: { webSearch: {
    baseUrl: literalBase, ...recipe.providerConfig, ...item.providerConfig,
  } } } } } }, searchConfig: plain(recipe.contextSearchConfig ?? searchConfig) };
}

export async function captureSearxngSearch(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root);
  const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const merge = capture => {
    for (const [key, value] of capture.sources) sources.set(key, { ...value, executed: value.executed || sources.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  };
  const normalizer = new SearxngCapture(root);
  const outputModule = normalizer.source(output); await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput, unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new SearxngCapture(root, recipe.httpPayloads), module = capture.source(entrypoint);
    await capture.evaluate(module);
    const provider = module.namespace.createSearxngWebSearchProvider();
    const setup = makeSetup(recipe, recipe.steps[0]), setupBefore = plain(setup), initialTool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString(), stepSetup = makeSetup(recipe, item), originalSetup = plain(stepSetup);
      const args = plain(item.arguments), original = plain(args), requestCount = capture.requests.length;
      const result = plain(await provider.createTool(stepSetup).execute(args));
      assert.deepEqual(args, original); assert.deepEqual(stepSetup, originalSetup); assert.equal(result.provider, 'searxng', recipe.id);
      const requests = capture.requests.slice(requestCount), cacheHit = result.cached === true;
      assert.equal(requests.length === 0, cacheHit, recipe.id);
      const generic = plain(normalize({ result, provider: 'searxng', query: original.query }));
      assert.equal(generic.kind, 'results', recipe.id);
      const providerUnwrappedResult = mapProse(result, unwrap);
      const providerPortableResult = mapProse(result, (text, field) => field === 'siteName' ? text : unframeSearxngSearchText(text));
      delete providerPortableResult.externalContent;
      const genericUnwrappedResult = mapProse(generic, unwrap), genericPortableResult = plain(genericUnwrappedResult);
      delete genericPortableResult.externalContent;
      steps.push({ arguments: original, argumentsAfter: plain(args), setup: originalSetup, setupAfter: plain(stepSetup),
        clock, clockAfter: new Date(capture.nowMs).toISOString(), requests, request: requests[0] ?? null,
        cacheHit, cumulativeRequests: capture.requests.length,
        providerResult: result, providerUnwrappedResult, providerPortableResult,
        genericResult: generic, genericUnwrappedResult, genericPortableResult,
        publicResult: generic, publicUnwrappedResult: genericUnwrappedResult, publicPortableResult: genericPortableResult });
    }
    assert.deepEqual(setup, setupBefore);
    groups.push({ id: recipe.id, setup: setupBefore, setupAfter: plain(setup),
      providerMetadata: plain(Object.fromEntries(['id', 'label', 'hint', 'onboardingScopes', 'requiresCredential',
        'credentialLabel', 'envVars', 'placeholder', 'signupUrl', 'autoDetectOrder', 'credentialPath',
        'credentialNote', 'inactiveSecretPaths'].map(key => [key, provider[key]]))),
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayloads: plain(recipe.httpPayloads), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root); assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  assert.equal(dependencies.size, 372, 'actual full TypeBox module graph plus package metadata');
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-searxng-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, synthetic clock/randomBytes; SearXNG owns audited facades and successful literal/platform fixtures' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    source: entrypoint, export: 'createSearxngWebSearchProvider',
    invocations: ['createSearxngWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider:"searxng",query:authoredArguments.query})',
      'unwrapWebSearchOutputText(providerAndGenericProse)'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, publicEntrypointInvoked: true, factoryInvoked: true,
      publicCallbackInvoked: true, actualLazyClient: true, actualProviderRequestBuilder: true,
      actualBaseUrlHelper: true, actualCountReaders: true, actualConfigReaders: true, actualSourceCache: true,
      genericNormalizerInvoked: true, actualUnwrapInvoked: true, actualTypeBox: true,
      actualBoundedSuccessReader: false, actualEndpointClassifiers: false, actualEndpointPolicy: false,
      actualCredentialResolution: false, actualDeadline: false, productionNetworkInvoked: false,
      pluginRegistrationInvoked: false, hostInstalled: false, fixtureEnvironment: {},
      syntheticClock: 'Date construction/Date.now; each successful GET advances7ms; no actual timers',
      portableNormalization: 'provider portable removes exact title/snippet frame and stamp, preserving authored spacing/img_src/siteName; actual unwrap trims prose; generic portable removes stamp after actual unwrap; public aliases generic',
      limits: [
        'All58558 tracked pinned blobs verified before/after; executed means unchanged whole-module evaluation, not every branch/export',
        'Actual public entrypoint/factory/contract/config readers/lazy client/query/count/time/cache helpers/request/parser/siteName/output execute',
        'Only explicit configured literal HTTPS base URLs; config-literal SecretRef service fixed available; actual source env/SecretRef discovery unexecuted',
        'Endpoint classifiers fixed false/public address; trusted endpoint and short successful text reader are fixtures; no actual DNS/SSRF/guard/permission/auth/TLS/network/deadline checks',
        'Count defaults5, explicit3/4 and configured2; only one or two short ordinary results; no count slicing or boundary thresholds',
        'Source count affects parser/cache but is absent from GET; cache identity includes trimmed query with case/interior spaces preserved, count/categories/language/normalized base',
        'Cache hits preserve original payload and perform no HTTP; TTL0 disables reads/writes while retaining prior entries; no expiry/eviction/race qualification',
        'Successful empty category search retries general once; empty general/included-general/unspecified categories do not retry; no HTTP failures',
        'Provider retains img_src and plain siteName; closed generic results drop img_src, reframe siteName and preserve authored public query',
        'Security/permission/auth/TLS/negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race/real-provider/remote-MCP execution excluded',
        'Full WHATWG/Unicode/sanitizer/framing/platform/plugin assembly and Synapsis host/runtime/Worker/Concord remain unqualified; full P0-P15 incomplete',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length, groups: groups.length,
      callbacks: groups.reduce((n, row) => n + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.requests.length > 0).length, 0),
      httpRequests: groups.reduce((n, row) => n + row.steps.reduce((m, item) => m + item.requests.length, 0), 0),
      cacheHitCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.cacheHit).length, 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source, gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureSearxngSearch(root), json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json); else process.stdout.write(json);
}
