// Ordinary DeepSeek callbacks from complete unchanged pinned OpenClaw modules.
// HTTP, successful JSON parsing, literal configuration and clock are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/deepseek/web-search-provider.ts';
const runtime = 'extensions/deepseek/web-search-provider.runtime.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const extraSources = new Set([factory, runtime, output, 'src/plugin-sdk/provider-web-search-contract.ts']);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT', 'MAX_SEARCH_COUNT',
      'postTrustedWebToolsJson', 'readCachedSearchPayload', 'readConfiguredSecretString',
      'resolveSearchCacheTtlMs', 'resolveSearchCount', 'resolveSearchTimeoutSeconds',
      'writeCachedSearchPayload'], common),
    from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
    from(['readProviderEnvValue'], 'src/secrets/provider-credential-values.ts'),
    from(['mergeScopedSearchConfig', 'resolveProviderWebSearchPluginConfig'],
      'src/agents/tools/web-search-provider-config.ts'),
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields'],
    'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonObjectResponse} from "deepseek:platform";',
};

class DeepseekCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    this.context.Headers = Headers;
  }

  source(path) {
    if (!extraSources.has(path)) return super.source(path);
    if (!this.modules.has(path)) this.modules.set(path,
      new vm.SourceTextModule(this.verifiedSource(path), {
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
    const id = 'deepseek:typebox:' + relative(this.typeboxRoot, file);
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
      readProviderJsonObjectResponse: async (response, label) => {
        record('successful-json-fixture', { label });
        return response.json();
      },
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records actual common request/serialization and timeout; supplies successful synthetic Response and advances synthetic clock7ms; network, policy and timers unexecuted',
      readProviderJsonObjectResponse: 'successful fixture Response.json; production bounded parser and object/error checks unexecuted',
    };
    return this.synthetic('deepseek:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    if (specifier === 'deepseek:platform') return this.platform();
    if (importer === common && specifier === './web-guarded-fetch.js') {
      const path = 'src/agents/tools/web-guarded-fetch.ts';
      this.verifiedSource(path, false);
      link('explicit-successful-http-fixture', path);
      return this.platform();
    }
    if (importer === 'src/plugin-sdk/provider-web-search-contract.ts' && specifier === './provider-enable-config.js') {
      this.verifiedSource('src/plugin-sdk/provider-enable-config.ts', false);
      link('unused-selection-service', 'src/plugin-sdk/provider-enable-config.ts');
      return this.deferred(importer, specifier, ['enablePluginInConfig']);
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      const path = 'src/web-search/runtime-error.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier,
        ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
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
    if (importer.startsWith('deepseek:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('deepseek:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(provenance, false);
      if (specifier === sdk + 'provider-http') this.verifiedSource('src/agents/provider-http-errors.ts', false);
      const generatedCode = facades[specifier];
      const id = 'deepseek:facade:' + specifier;
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

const row = (n, extra = {}) => ({ title: ` Source ${n} 😀 `, url: `https://source.example/${n}`,
  summary: ` Model summary ${n} 文 `, snippet: ` UI snippet ${n} `,
  date: '2026-10-17T00:00:00+00:00', site_name: ' Source publication ',
  content: 'Full content is not part of search output', rerank_score: 0.9, ...extra });
const payload = count => ({ results: Array.from({ length: count }, (_, index) => row(index + 1)) });
const step = arguments_ => ({ arguments: arguments_ });
function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) =>
    rows.push({ id, steps: [step(args)], httpPayload: payload(3), ...options });
  add('search-default');
  add('operator-query', { query: ' OpenClaw site:github.com -site:archive.example lang:en after:2026 "release notes" ' });
  add('unicode-query', { query: ' 界😀e\u0301 👩‍💻 ordinary search ' });
  add('configured-count', undefined, { searchConfig: { maxResults: 2 }, httpPayload: payload(2) });
  add('explicit-count', { query: 'explicit count', count: 4 },
    { searchConfig: { maxResults: 2 }, httpPayload: payload(4) });
  add('configured-timeout', undefined, { searchConfig: { timeoutSeconds: 7 } });
  add('ordered-metadata', { query: 'ordered source results', count: 3 }, { httpPayload: { results: [
    row(1, { title: ' First 😀 ', url: ' https://SOURCE.EXAMPLE:443/ordinary?q=hello%20world ',
      summary: ' Model summary ', date: ' 2026-10-17T00:00:00+00:00 ', site_name: ' Journal 文 ' }),
    row(2, { title: ' Second ', url: 'https://two.example', summary: ' \t ',
      snippet: ' UI fallback ', date: '2026-10-18', site_name: ' Second site ' }),
    { title: ' Third ', url: 'https://three.example/ordinary', summary: ' Third summary ' },
  ] } });
  add('successful-empty', undefined, { httpPayload: { results: [] } });
  add('same-cache-reuse', undefined, { steps: [
    step({ query: ' same cache query ', count: 3 }), step({ query: 'same cache query', count: 3 }),
  ] });
  add('empty-cache-reuse', undefined, { httpPayload: { results: [] }, steps: [
    step({ query: 'same empty query' }), step({ query: 'same empty query' }),
  ] });
  return rows;
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['title', 'snippet', 'siteName'].includes(field) ? unwrap(value) : value;
  if (Array.isArray(value)) return value.map(item => unwrapResult(item, unwrap));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}
function portable(value) {
  const copy = plain(value);
  delete copy.externalContent;
  return copy;
}

export async function captureDeepseekSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new DeepseekCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new DeepseekCapture(root, recipe.httpPayload);
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createDeepSeekWebSearchProvider();
    const config = { plugins: { entries: { deepseek: { config: { webSearch: {
      apiKey: 'fixture-deepseek-key',
    } } } } } };
    const searchConfig = { cacheTtlMinutes: 15, ...recipe.searchConfig };
    const setup = { config, searchConfig };
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
      assert.equal(providerResult.provider, 'deepseek', recipe.id);
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      const publicResult = plain(normalize({ result: providerResult, provider: 'deepseek', query: original.query }));
      assert.equal(publicResult.kind, 'results', recipe.id);
      const publicUnwrappedResult = unwrapResult(publicResult, unwrap);
      steps.push({ arguments: original, argumentsAfter: plain(args), clock, setup: plain(setup),
        request: requests[0] ?? null, providerResult, providerPortableResult: portable(providerResult),
        publicResult, publicUnwrappedResult, publicPortableResult: portable(publicUnwrappedResult),
        cached: providerResult.cached === true, cumulativeRequests: capture.requests.length });
    }
    groups.push({ id: recipe.id, setup: originalSetup, setupAfter: plain(setup),
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, autoDetectOrder: provider.autoDetectOrder }),
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
    harness: { path: 'scripts/openclaw/capture-deepseek-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, deterministic clock/randomBytes and literal-config fixture; own audited DeepSeek facades/platform/TypeBox loading' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    invocations: ['createDeepSeekWebSearchProvider()',
      'createDeepSeekWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider,query:authoredArguments.query})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true,
      publicCallbackInvoked: true, actualCommonPost: true, actualSharedCache: true,
      genericNormalizerInvoked: true, actualBoundedSuccessReader: false,
      productionNetworkInvoked: false, pluginRegistrationInvoked: false, fixtureEnvironment: {},
      unwrap: 'provider outputs are retained unchanged; publicPortableResult uses actual source unwrapWebSearchOutputText for prose and removes only top-level externalContent; original framed publicResult remains',
      limits: [
        'All58558 tracked source blobs verified before/after; executed means whole module evaluated, not all exports or branches called',
        'Actual factory, lazy provider runtime, shared config merge/readers/cache, request builder and generic output normalization execute unchanged',
        'Successful endpoint callback and Response.json object are explicit platform fixtures; bounded JSON reader, network, endpoint policy and timers unexecuted',
        'Literal available configuration fixture; actual secret discovery/resolution and selection-time hooks unexecuted; process.env is empty',
        'Synthetic HTTP advances synthetic clock7ms; cache callbacks use actual source with fixture clock; deterministic randomBytes supply stable prose framing',
        'Provider runtime privately trims query; generic public normalizer retains authored query supplied by harness, including whitespace and cache-hit variants',
        'Only ordinary positive source observations; no excluded negative/error/failure/security/permission/auth/TLS/budget/truncation/threshold/crash/race or real-provider tests',
        'No plugin registration/runtime assembly, Synapsis production execution, native Worker/Concord or provider deployment acceptance',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source,
      gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureDeepseekSearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}
