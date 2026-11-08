// Ordinary free Parallel callbacks from complete unchanged pinned OpenClaw modules.
// This HTTP helper supplies synthetic responses; it is never a host MCP client.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, hash as nativeHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

import { unframeParallelSearchText } from './capture-parallel-search.mjs';

const paidFactory = 'extensions/parallel/src/parallel-web-search-provider.ts';
const factory = 'extensions/parallel/src/parallel-free-web-search-provider.ts';
const runtime = 'extensions/parallel/src/parallel-free-web-search-provider.runtime.ts';
const shared = 'extensions/parallel/src/parallel-search-normalize.ts';
const freeShared = 'extensions/parallel/src/parallel-free-web-search-provider.shared.ts';
const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const extraSources = new Set([paidFactory, factory, runtime, shared, freeShared, output, 'src/utils.ts', 'src/infra/plain-object.ts',
  'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-enable-config.ts',
  'src/config/plugins-allowlist.ts']);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT',
      'readCachedSearchPayload', 'readWebSearchApiKey', 'resolveSearchCacheTtlMs',
      'resolveSearchTimeoutSeconds', 'resolveSiteName', 'withTrustedWebSearchEndpoint',
      'writeCachedSearchPayload'], common),
    from(['readPositiveIntegerParam', 'readStringArrayParam', 'readToolStringParam as readStringParam'], readers),
    from(['mergeScopedSearchConfig', 'resolveProviderWebSearchPluginConfig'],
      'src/agents/tools/web-search-provider-config.ts'),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord', 'asOptionalObjectRecord', 'asOptionalRecord', 'isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeBoundedOptionalString'], normalization + 'string-coerce.ts'),
    from(['filterStringEntries'], normalization + 'string-normalization.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'number-runtime']: from(['resolveIntegerOption'], normalization + 'number-coercion.ts'),
  [sdk + 'text-utility-runtime']: [
    from(['truncateUtf16Safe'], normalization + 'utf16-slice.ts'),
    from(['tryParseJson as safeParseJson'], 'src/utils.ts'),
  ].join('\n'),
  [sdk + 'provider-http']: [
    'export {readProviderTextResponse} from "parallel:platform";',
    'export {ProviderHttpError,readResponseTextLimited} from "parallel:unused-http-errors";',
  ].join('\n'),
};

class ParallelFreeCapture extends BraveCapture {
  constructor(root, recipe) {
    super(root);
    this.recipe = recipe;
    this.uuidCounter = 0;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    this.context.Headers = Headers;
    this.context.process.platform = 'linux';
    this.pluginVersion = JSON.parse(readFileSync(join(root, 'extensions/parallel/package.json'))).version;
    assert.equal(this.pluginVersion, '2026.10.5');
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
    const id = 'parallel:typebox:' + relative(this.typeboxRoot, file);
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
        const body = JSON.parse(params.init.body);
        const recipe = this.recipe;
        const protocolVersion = recipe.protocolVersion;
        let envelope;
        let responseText;
        const headers = {};
        if (body.method === 'initialize') {
          envelope = { jsonrpc: '2.0', id: body.id, result: {
            protocolVersion, capabilities: { tools: {} },
            serverInfo: { name: 'parallel-free-source-fixture', version: '1.0.0' },
          } };
          if (recipe.transportSessionId !== null) headers['mcp-session-id'] = recipe.transportSessionId;
        } else if (body.method === 'notifications/initialized') {
          // Successful notification body is read by the callback only. It is
          // never passed to selectMcpEnvelope and is not a parser-negative case.
          responseText = '';
        } else {
          assert.equal(body.method, 'tools/call');
          assert.equal(body.params.name, 'web_search');
          const payload = plain(recipe.httpPayload);
          let result;
          if (recipe.toolContent === 'json-text') {
            result = { content: [{ type: 'text', text: JSON.stringify(payload) }] };
          } else {
            result = { structuredContent: payload };
            if (recipe.toolContent === 'structured-priority') {
              result.content = [{ type: 'text', text: JSON.stringify({
                search_id: 'unused-text-search', results: [{
                  title: 'Unused text alternative', url: 'https://unused.example',
                  excerpts: ['Unused ordinary text alternative'],
                }],
              }) }];
            }
          }
          envelope = { jsonrpc: '2.0', id: body.id, result };
        }
        if (responseText === undefined) {
          if (recipe.responseFormat === 'json') {
            responseText = JSON.stringify(envelope);
            headers['content-type'] = 'application/json';
          } else {
            const json = JSON.stringify(envelope, null, recipe.responseFormat === 'sse-multiline' ? 2 : 0);
            responseText = 'event: message\n' + json.split('\n').map(line => 'data: ' + line).join('\n') + '\n\n';
            headers['content-type'] = 'text/event-stream';
          }
        }
        const request = { url: params.url, method: params.init.method,
          path: new URL(params.url).pathname, body, bodyText: params.init.body,
          headers: plain(params.init.headers), timeoutSeconds: params.timeoutSeconds,
          response: { status: 200, headers: plain(headers), bodyText: responseText,
            ...(envelope ? { envelope: plain(envelope) } : {}) } };
        this.requests.push(request);
        this.audit.push({ kind: 'successful-http-fixture', method: body.method,
          timeoutSeconds: params.timeoutSeconds, responseFormat: recipe.responseFormat });
        this.nowMs += 7;
        return run({ response: new Response(responseText, { status: 200, headers }) });
      },
      readProviderTextResponse: async (response, label) => {
        this.audit.push({ kind: 'successful-text-reader-fixture', label });
        return response.text();
      },
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records unchanged source MCP POST serializer and supplies successful synthetic JSON/SSE Response; each POST advances fixture clock7ms; host MCP/network/policy/timers unexecuted',
      readProviderTextResponse: 'successful fixture Response.text; production bounded reader unexecuted; actual source envelope selector and tool payload parser execute unchanged',
    };
    return this.synthetic('parallel:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`,
      { importer, specifier, kind, target });
    if (specifier === 'parallel:platform') return this.platform();
    if (specifier === 'node:crypto') {
      link('native-crypto-and-explicit-uuid-fixture', specifier);
      const bindings = { createHash, hash: nativeHash,
        randomBytes: size => Buffer.alloc(size, 0x42),
        randomUUID: () => {
          const value = '00000000-0000-4000-8000-' + String(++this.uuidCounter).padStart(12, '0');
          this.audit.push({ kind: 'uuid-fixture', value });
          return value;
        } };
      return this.synthetic('parallel-free:crypto', bindings, Object.fromEntries(
        Object.keys(bindings).map(name => [name, {
          kind: ['randomUUID', 'randomBytes'].includes(name) ? 'deterministic-platform' : 'native-platform',
          behavior: name === 'randomUUID' ? 'monotonic distinct RFC4122-shaped fixture UUID, audited'
            : name === 'randomBytes' ? 'Buffer.alloc(size,0x42), stable wrapper markers' : 'actual node:crypto:' + name,
        }])));
    }
    if (importer === 'src/utils.ts') {
      const unused = {
        'node:fs': ['default'], 'node:os': ['default'], 'node:path': ['default'],
        '@openclaw/normalization-core/home-dir': ['normalizeHomeDirValue'],
        './infra/home-dir.js': ['resolveEffectiveHomeDir', 'resolveUserPath'],
        './infra/home-display.js': ['shortenPathWithHome'],
        './utils/sleep.js': ['sleep'], '@openclaw/fs-safe/advanced': ['pathExists'],
      };
      if (specifier === './infra/config-dir.js') {
        this.verifiedSource('src/infra/config-dir.ts', false);
        link('literal-module-initialization-fixture', 'src/infra/config-dir.ts');
        return this.synthetic('parallel-free:config-dir', {
          resolveConfigDir: () => {
            this.audit.push({ kind: 'literal-config-dir-fixture' });
            return '/fixture/openclaw';
          },
        }, { resolveConfigDir: { kind: 'ordinary-platform-fixture',
          behavior: 'literal unused CONFIG_DIR initializer while whole src/utils.ts supplies actual tryParseJson; host discovery unexecuted' } });
      }
      if (unused[specifier]) {
        if (specifier.startsWith('.')) this.verifiedSource(
          relative(this.root, resolve(this.root, 'src', specifier)).replace(/\.js$/, '.ts'), false);
        else if (specifier === '@openclaw/normalization-core/home-dir')
          this.verifiedSource(normalization + 'home-dir.ts', false);
        link('unused-utils-service', specifier);
        return this.deferred(importer, specifier, unused[specifier]);
      }
    }
    if (specifier === sdk + 'provider-web-search-contract') {
      const path = 'src/plugin-sdk/provider-web-search-contract.ts';
      link('whole-module-alias', path);
      return this.source(path);
    }
    if (specifier === 'node:module') {
      link('explicit-plugin-version-fixture', 'node:module');
      return this.synthetic('parallel:node-module', {
        createRequire: () => {
          this.audit.push({ kind: 'plugin-require-fixture' });
          return () => { throw Error('Plugin package resolver is outside this capture'); };
        },
      }, { createRequire: { kind: 'ordinary-platform-fixture',
        behavior: 'provides unused require token to explicit plugin-version fixture; package discovery unexecuted' } });
    }
    if (specifier === sdk + 'extension-shared') {
      const path = 'src/plugin-sdk/extension-shared.ts';
      this.verifiedSource(path, false);
      link('explicit-plugin-version-fixture', path);
      return this.synthetic('parallel:plugin-version', {
        readPluginPackageVersion: () => {
          this.audit.push({ kind: 'plugin-version-fixture', version: this.pluginVersion });
          return this.pluginVersion;
        },
      }, { readPluginPackageVersion: { kind: 'ordinary-platform-fixture',
        behavior: 'explicit version from pin-verified extensions/parallel/package.json; actual package discovery unexecuted' } });
    }
    if ([sdk + 'logging-core', sdk + 'security-runtime'].includes(specifier)) {
      const path = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier,
        specifier.endsWith('logging-core') ? ['redactToolPayloadText'] : ['redactSensitiveText']);
    }
    if (importer === common && specifier === './web-guarded-fetch.js') {
      const path = 'src/agents/tools/web-guarded-fetch.ts';
      this.verifiedSource(path, false);
      link('explicit-successful-http-fixture', path);
      return this.platform();
    }
    if (specifier === 'parallel:unused-http-errors') {
      const path = 'src/agents/provider-http-errors.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier, ['ProviderHttpError', 'readResponseTextLimited']);
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
    if (importer.startsWith('parallel:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('parallel:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(provenance, false);
      if (specifier === sdk + 'provider-http') {
        this.verifiedSource('src/media-understanding/shared.ts', false);
        this.verifiedSource('src/agents/provider-http-errors.ts', false);
      }
      const generatedCode = facades[specifier];
      const id = 'parallel:facade:' + specifier;
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

const row = (n, extra = {}) => ({ title: ` Source ${n} 😀 `,
  url: `https://www.source.example/${n}`, publish_date: '2026-10-17',
  excerpts: [` First excerpt ${n} 文 `, ` Second excerpt ${n} 😀 `], ...extra });
const payload = count => ({ search_id: 'fixture-search-id', session_id: 'unused-server-search-session',
  results: Array.from({ length: count }, (_, index) => row(index + 1)),
  warnings: [' ordinary advisory ', { message: 'fixture notice' }],
  usage: [{ name: 'search', count: 1 }, { name: 'excerpts', count: 2 }] });
const args = (objective = 'ordinary research', extra = {}) => ({ objective,
  search_queries: ['ordinary keyword research', 'alternate keyword sources'], ...extra });
const step = arguments_ => ({ arguments: arguments_ });
function recipes() {
  const rows = [];
  const add = (id, arguments_ = args(id), options = {}) => rows.push({ id,
    steps: [step(arguments_)], protocolVersion: '2025-06-18',
    transportSessionId: 'fixture-mcp-transport-session', responseFormat: 'json',
    toolContent: 'structured', httpPayload: payload(6), ...options });
  add('search-default');
  add('normalized-pair', args('  Understand ordinary research 文  ', {
    search_queries: ['  first keyword phrase  ', 'second keyword phrase', 'first keyword phrase', '  ', 'second keyword phrase'],
  }));
  add('unicode-pair', args(' 界😀e\u0301 👩‍💻 ordinary objective ', {
    search_queries: [' 界😀e\u0301 research ', ' 👩‍💻 ordinary sources '],
  }));
  add('optional-context', args(' optional supplied context ', {
    session_id: ' prior-session-文 ', client_model: ' gpt-6-astra ', count: 3,
  }));
  add('configured-count', undefined, { searchConfig: { maxResults: 2 } });
  add('explicit-count', args('explicit count', { count: 4 }), { searchConfig: { maxResults: 2 } });
  add('configured-timeout', undefined, { searchConfig: { timeoutSeconds: 7 } });
  add('structured-content-priority', undefined, { toolContent: 'structured-priority' });
  add('json-text-fallback', undefined, { toolContent: 'json-text' });
  add('post-sse', undefined, { responseFormat: 'sse' });
  add('post-sse-multiline', undefined, { responseFormat: 'sse-multiline', toolContent: 'json-text' });
  add('stateless-server', undefined, { transportSessionId: null });
  add('negotiated-version', undefined, { protocolVersion: '2025-03-26' });
  add('keywords-only', { search_queries: [' first keyword phrase ', 'second keyword phrase'] });
  add('cli-query-fallback', { query: '  ordinary CLI query 文  ', count: 2 });
  add('cli-query-with-objective', { objective: ' CLI research objective ', query: ' CLI keyword phrase ' });
  add('query-with-pair', args(' paired objective ', { query: ' authored generic query ' }));
  add('ordered-metadata', args('ordered source results', { count: 3 }), { httpPayload: {
    ...payload(0), search_id: ' raw-search-id ', results: [
      row(1, { title: ' First 😀 ', url: ' https://WWW.SOURCE.EXAMPLE:443/ordinary?q=hello%20world ',
        publish_date: ' 2026-10-17 ', excerpts: [' First paragraph 文 ', '\n Second paragraph 😀 \n'] }),
      row(2, { title: ' Second ', url: 'https://two.example', publish_date: '2026-10-18',
        excerpts: [' Second description ', ' Final ordered excerpt '] }),
      { title: ' Third ', url: 'https://three.example/ordinary', excerpts: [] },
    ],
  } });
  add('successful-empty', undefined, { httpPayload: payload(0) });
  add('successful-empty-minimal', undefined, { httpPayload: { results: [] } });
  add('same-cache-generated-session', undefined, { steps: [
    step(args(' same cache objective ', { search_queries: [' same cache query ', 'other query'] })),
    step(args('same cache objective', { search_queries: ['same cache query', 'other query', 'same cache query'] })),
  ] });
  add('same-cache-supplied-session', undefined, { steps: [
    step(args('same supplied session', { session_id: ' supplied-session ', client_model: ' gpt-6-astra ' })),
    step(args('same supplied session', { session_id: 'supplied-session', client_model: 'gpt-6-astra' })),
  ] });
  add('empty-cache-reuse', undefined, { httpPayload: payload(0), steps: [
    step(args('same empty query')), step(args('same empty query')),
  ] });
  for (const [id, change] of [
    ['count-cache-identity', { count: 4 }],
    ['objective-cache-identity', { objective: 'second objective' }],
    ['queries-cache-identity', { search_queries: ['different keyword phrase'] }],
    ['query-order-cache-identity', { search_queries: ['alternate keyword sources', 'ordinary keyword research'] }],
    ['session-cache-identity', { session_id: 'supplied-context' }],
    ['client-model-cache-identity', { client_model: 'gpt-6-astra' }],
  ]) add(id, undefined, { steps: [
    step(args(id, { count: 2 })), step(args(id, { count: 2, ...change })), step(args(id, { count: 2 })),
  ] });
  return rows;
}

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['title', 'description', 'snippet', 'siteName', 'excerpts'].includes(field) ? unwrap(value) : value;
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
function providerPortable(value) {
  const copy = portable(value);
  copy.results = copy.results.map(row => ({ ...row,
    title: unframeParallelSearchText(row.title),
    description: unframeParallelSearchText(row.description),
    ...(row.excerpts ? { excerpts: row.excerpts.map(unframeParallelSearchText) } : {}),
  }));
  return copy;
}

export async function captureParallelFreeSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new ParallelFreeCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new ParallelFreeCapture(root, recipe);
    const factoryModule = capture.source(factory);
    await capture.evaluate(factoryModule);
    const provider = factoryModule.namespace.createParallelFreeWebSearchProvider();
    const setup = { config: { plugins: { entries: { parallel: { config: { webSearch: {} } } } } },
      searchConfig: { cacheTtlMinutes: 15, ...recipe.searchConfig } };
    const originalSetup = plain(setup);
    const tool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 100;
      const clock = new Date(capture.nowMs).toISOString();
      const arguments_ = plain(item.arguments), original = plain(arguments_);
      const requestCount = capture.requests.length;
      const providerResult = plain(await tool.execute(arguments_));
      assert.deepEqual(arguments_, original);
      assert.deepEqual(setup, originalSetup);
      assert.equal(providerResult.provider, 'parallel-free', recipe.id);
      const requests = capture.requests.slice(requestCount);
      assert.equal(requests.length, providerResult.cached ? 0 : 3);
      const request = requests.find(row => row.body.method === 'tools/call') ?? null;
      const genericQuery = typeof original.query === 'string' ? original.query : '';
      const genericResult = plain(normalize({ result: providerResult, provider: 'parallel-free', query: genericQuery }));
      assert.equal(genericResult.kind, 'results', recipe.id);
      steps.push({ arguments: original, argumentsAfter: plain(arguments_), clock,
        setup: originalSetup, setupAfter: plain(setup), requests, request,
        searchSessionId: request?.body.params.arguments.session_id ?? providerResult.sessionId ?? null,
        providerResult, providerUnwrappedResult: unwrapResult(providerResult, unwrap),
        providerPortableResult: providerPortable(providerResult), genericQuery,
        genericResult, genericUnwrappedResult: unwrapResult(genericResult, unwrap),
        genericPortableResult: portable(unwrapResult(genericResult, unwrap)),
        cached: providerResult.cached === true, cumulativeRequests: capture.requests.length });
    }
    groups.push({ id: recipe.id, setup: originalSetup, setupAfter: plain(setup),
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, configPath: provider.configPath,
        requiresCredential: provider.requiresCredential, envVars: provider.envVars }),
      descriptor: { description: tool.description, parameters: plain(tool.parameters) },
      serverRecipe: plain({ protocolVersion: recipe.protocolVersion,
        transportSessionId: recipe.transportSessionId, responseFormat: recipe.responseFormat,
        toolContent: recipe.toolContent, httpPayload: recipe.httpPayload }),
      httpPayload: plain(recipe.httpPayload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  const packageBytes = readFileSync(join(root, 'extensions/parallel/package.json'));
  assert.deepEqual(packageBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:extensions/parallel/package.json`]));
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-parallel-free-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [
      { path: 'scripts/openclaw/capture-brave-search-filters.mjs',
        sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
        reuse: 'whole-module loader, pin source hashes, deterministic clock and literal config fixture' },
      { path: 'scripts/openclaw/capture-parallel-search.mjs',
        sha256: digest(readFileSync(new URL('./capture-parallel-search.mjs', import.meta.url))),
        reuse: 'exported exact-frame unframing helper only; paid capture callback is not invoked' },
    ],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    pluginFixture: { path: 'extensions/parallel/package.json', gitBlob: blob(packageBytes),
      sha256: digest(packageBytes), version: JSON.parse(packageBytes).version, platform: 'linux',
      userAgent: `openclaw-parallel/${JSON.parse(packageBytes).version} (linux)` },
    invocations: ['createParallelFreeWebSearchProvider()',
      'createParallelFreeWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider,query:authoredArguments.query ?? ""})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true,
      publicCallbackInvoked: true, actualProviderRequestBuilder: true, actualSharedEndpoint: true,
      actualSharedCache: true, actualMcpSerializerParser: true, actualJsonParser: true,
      genericNormalizerInvoked: true, actualPluginVersionDiscovery: false,
      actualBoundedSuccessReader: false, productionNetworkInvoked: false,
      pluginRegistrationInvoked: false, fixtureEnvironment: {},
      unwrap: 'providerPortableResult removes exact pinned frames preserving body whitespace; providerUnwrappedResult and genericUnwrappedResult use source unwrap which trims prose; raw frames remain separately',
      limits: [
        'All58558 tracked source blobs verified before/after; whole module evaluation does not imply every branch/export executes',
        'Actual free factory/runtime/shared cache/normalization, free session constant and exact imported paid schema factory execute unchanged',
        'Actual free JSON-RPC serializer/envelope selector/tool payload parser and src/utils.ts tryParseJson execute unchanged',
        'Synthetic successful HTTP and Response.text are explicit fixtures; no hand-written host MCP client or source network execution',
        'Each uncached callback initializes, notifies initialized, then calls web_search; successful empty notification body never enters envelope parser',
        'Fixture UUIDs separate search session, initialize id and call id; only assigned MCP transport session and negotiated supported version echo in follow-ups',
        'Whole src/utils.ts has literal unused CONFIG_DIR initialization fixture and unused deferred host/path/filesystem services; only successful tryParseJson exercised',
        'Plugin version is pin-verified2026.10.5 and platformlinux; actual discovery and selection hooks remain unexecuted',
        'Every count and result list stays below10 with short ordinary strings; local count slices results and never enters MCP tool arguments',
        'Generated search session is omitted from cached copy; supplied search session persists; ordinary cache keys distinguish objective/query order/count/model/session',
        'Provider output retains complete metadata/excerpts and whitespace; source generic projection is separate and does not establish host public equivalence',
        'Synapsis host uses full provider factory projection plus kind rather than the source generic10 schema; official Backplane1.10.57 owns host MCP transport',
        'Backplane strict envelope/version host contract differs from source last-envelope fallback; malformed/unmatched-id/parser fallback paths are not executed',
        'Host clientInfo and User-Agent branding and resource cleanup differ; this capture establishes source observations only',
        'No credential segregation, auth/security/permission/TLS, negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race or real-provider execution',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((sum, row) => sum + row.steps.filter(step => step.request !== null).length, 0),
      requests: groups.reduce((sum, row) => sum + row.steps.reduce((n, step) => n + step.requests.length, 0), 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source,
      gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureParallelFreeSearch(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json);
  else process.stdout.write(json);
}

