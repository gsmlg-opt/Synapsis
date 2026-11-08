// Ordinary successful callbacks from complete unchanged pinned Brave modules.
// HTTP/platform bindings are fixtures; this is not production transport assembly.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { Buffer } from 'node:buffer';
import { createHash, hash as nativeHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const BRAVE_REFERENCE_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const BRAVE_REFERENCE_CLOCK = '2026-10-27T12:00:00.000Z';
const factory = 'extensions/brave/src/brave-web-search-provider.ts';
const runtime = 'extensions/brave/src/brave-web-search-provider.runtime.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const baseUrl = 'http://127.0.0.1:18181/proxy';
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));

const allowedSources = new Set([
  factory, runtime, 'extensions/brave/web-search-shared.ts', common, readers,
  'src/agents/tools/web-shared.ts', 'src/agents/tools/web-search-provider-config.ts',
  'src/config/plugin-web-search-config.ts', 'src/config/web-search-legacy-provider-keys.ts',
  'src/plugin-sdk/provider-web-search-config-contract.ts',
  'src/plugin-sdk/provider-web-search-contract-fields.ts', 'src/plugin-sdk/provider-web-search-schema.ts',
  'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts', 'src/shared/regexp.ts',
  'src/param-key.ts', 'src/agents/tool-input-error.ts', 'src/infra/map-size.ts',
  'src/utils/normalize-secret-input.ts', 'src/secrets/provider-credential-values.ts',
  'src/infra/diagnostic-flags.ts', 'src/infra/diagnostic-flags-env.ts',
  'src/security/external-content.ts', 'src/security/external-content-source.ts',
  ...['number-coercion', 'string-coerce', 'record-coerce', 'string-normalization',
    'response-bytes', 'text-decoding', 'node-crypto', 'stable-stringify', 'utf16-slice']
    .map(name => normalization + name + '.ts'),
]);

// SDK barrels are narrowed only by whole-module re-exports, never body selections.
const sharedExports = [
  'externalContentStamp', 'buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT',
  'parseWebSearchTimeFilters', 'readCachedSearchPayload', 'readConfiguredSecretString',
  'readWebSearchApiKey', 'readWebSearchQueryAndCount', 'resolveSearchCacheTtlMs',
  'resolveSearchCount', 'resolveSearchTimeoutSeconds', 'resolveSiteName', 'writeCachedSearchPayload',
];
const exportFrom = (names, target) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + target)};`;
const facades = {
  [sdk + 'provider-web-search']: [
    exportFrom(sharedExports, common),
    exportFrom(['readToolStringParam as readStringParam'], readers),
    exportFrom(['wrapWebContent'], 'src/security/external-content.ts'),
    'export {formatCliCommand,withSelfHostedWebToolsEndpoint,withTrustedWebToolsEndpoint} from "capture:platform";',
  ].join('\n'),
  [sdk + 'string-coerce-runtime']: [
    exportFrom(['asNonArrayRecord', 'asOptionalRecord'], normalization + 'record-coerce.ts'),
    exportFrom(['normalizeLowercaseStringOrEmpty', 'normalizeOptionalString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: exportFrom(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'diagnostic-flags']: exportFrom(['isDiagnosticFlagEnabled'], 'src/infra/diagnostic-flags.ts'),
  [sdk + 'node-crypto-runtime']: exportFrom(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'extension-shared']: 'export {buildTimeoutAbortSignal} from "capture:platform";',
  [sdk + 'provider-http']: 'export {assertOkOrThrowProviderError,readProviderJsonResponse} from "capture:platform";',
  [sdk + 'runtime-env']: 'export {createSubsystemLogger} from "capture:platform";',
  [sdk + 'ssrf-runtime']: 'export {assertHttpUrlTargetsPrivateNetwork,isBlockedHostnameOrIp,isPrivateIpAddress,resolvePinnedHostnameWithPolicy} from "capture:platform";',
  '@openclaw/normalization-core': [
    exportFrom(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    exportFrom(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};

const deferredImports = [
  [readers, '@openclaw/media-core/mime', ['detectMime']],
  [readers, '../../infra/fs-safe.js', ['readLocalFileSafely']],
  [readers, './tool-results.js', ['textResult', 'jsonResult']],
  [common, '../provider-http-errors.js', ['createProviderErrorTextRedactor', 'ProviderHttpError']],
];

export class BraveCapture {
  constructor(root) {
    this.root = resolve(root);
    this.modules = new Map();
    this.sources = new Map();
    this.aliases = new Map();
    this.stubBindings = new Map();
    this.audit = [];
    this.requests = [];
    this.nowMs = Date.parse(BRAVE_REFERENCE_CLOCK);
    const clock = this;
    class FixtureDate extends Date {
      constructor(...args) { super(...(args.length ? args : [clock.nowMs])); }
      static now() { return clock.nowMs; }
    }
    this.context = vm.createContext({
      Date: FixtureDate, URL, TextEncoder, TextDecoder, Buffer,
      process: { env: {} },
    }, { codeGeneration: { strings: false, wasm: false } });
  }

  verifiedSource(path, executed = true) {
    const bytes = readFileSync(join(this.root, path));
    const pinned = execFileSync('git', ['show', `${BRAVE_REFERENCE_PIN}:${path}`], { cwd: this.root });
    assert.deepEqual(bytes, pinned, `pinned source: ${path}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    const previous = this.sources.get(path);
    this.sources.set(path, {
      path, sourceSha256: digest(bytes), executableSha256: digest(executable),
      wholeModule: true, executed: executed || previous?.executed === true,
    });
    return executable;
  }

  source(path) {
    assert.ok(allowedSources.has(path), `audited whole-module source: ${path}`);
    if (!this.modules.has(path)) {
      const module = new vm.SourceTextModule(this.verifiedSource(path), {
        context: this.context, identifier: path,
        importModuleDynamically: async specifier => {
          this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
          const target = this.import(specifier, path);
          await this.evaluate(target);
          return target;
        },
      });
      this.modules.set(path, module);
    }
    return this.modules.get(path);
  }

  synthetic(id, bindings, descriptions) {
    if (!this.modules.has(id)) {
      for (const [name, description] of Object.entries(descriptions)) {
        this.stubBindings.set(`${id}:${name}`, { module: id, export: name, ...description,
          bindingSha256: digest(String(bindings[name])) });
      }
      const module = new vm.SyntheticModule(Object.keys(bindings), function () {
        for (const [name, value] of Object.entries(bindings)) this.setExport(name, value);
      }, { context: this.context, identifier: id });
      this.modules.set(id, module);
    }
    return this.modules.get(id);
  }

  deferred(owner, specifier, names) {
    const bindings = Object.fromEntries(names.map(name => [name, () => {
      this.audit.push({ kind: 'unused-service-invoked', importer: owner, specifier, export: name });
      throw Error(`Capture does not execute ${specifier}:${name}`);
    }]));
    return this.synthetic(`capture:deferred:${owner}:${specifier}`, bindings,
      Object.fromEntries(names.map(name => [name, { kind: 'unused-platform-service', behavior: 'throws if invoked' }])));
  }

  platform() {
    const record = (name, args = {}) => this.audit.push({ kind: 'platform', export: name, ...args });
    const endpoint = async (params, run) => {
      record('fixture-http');
      const url = new URL(params.url);
      this.requests.push({ method: params.init.method, path: url.pathname, query: Object.fromEntries(url.searchParams) });
      const index = this.requests.length;
      const row = { url: `https://example.com/source-${index}`, title: 'Reference source',
        description: 'Reference description', page_age: '2025-01-02' };
      const payload = url.pathname.endsWith('/llm/context')
        ? { grounding: { generic: [{ url: row.url, title: row.title, snippets: [row.description] }] },
          sources: { [row.url]: { age: ['', '2025-01-02', 'recent', '2025-01-02T12:00:00Z'] } } }
        : { web: { results: [row] } };
      return run({ response: Response.json(payload) });
    };
    const bindings = {
      buildTimeoutAbortSignal: () => {
        record('buildTimeoutAbortSignal');
        return { signal: undefined, cleanup: () => record('timeout-cleanup') };
      },
      assertHttpUrlTargetsPrivateNetwork: async () => record('assertHttpUrlTargetsPrivateNetwork'),
      isBlockedHostnameOrIp: () => { throw Error('Unused endpoint classifier'); },
      isPrivateIpAddress: () => { throw Error('Unused endpoint classifier'); },
      resolvePinnedHostnameWithPolicy: () => { throw Error('Unused endpoint classifier'); },
      withSelfHostedWebToolsEndpoint: endpoint,
      withTrustedWebToolsEndpoint: endpoint,
      assertOkOrThrowProviderError: () => record('assertOkOrThrowProviderError'),
      readProviderJsonResponse: async response => {
        record('readProviderJsonResponse');
        return response.json();
      },
      createSubsystemLogger: () => { record('createSubsystemLogger'); return { info: () => {} }; },
      formatCliCommand: () => { throw Error('Unused CLI formatting'); },
    };
    const behavior = {
      buildTimeoutAbortSignal: 'ordinary-success no-timer binding; cleanup recorded; deadlines unverified',
      assertHttpUrlTargetsPrivateNetwork: 'fixed local fixture endpoint classification; production classifier unexecuted',
      isBlockedHostnameOrIp: 'unused; throws if invoked',
      isPrivateIpAddress: 'unused; throws if invoked',
      resolvePinnedHostnameWithPolicy: 'unused; throws if invoked',
      withSelfHostedWebToolsEndpoint: 'records request and returns synthetic successful Response; no sockets',
      withTrustedWebToolsEndpoint: 'same fixture transport; production endpoint wrappers unexecuted',
      assertOkOrThrowProviderError: 'successful fixture response boundary; production HTTP assertion unexecuted',
      readProviderJsonResponse: 'fixture Response.json(); production bounded HTTP parser unexecuted',
      createSubsystemLogger: 'no-op fixture logger',
      formatCliCommand: 'unused; throws if invoked',
    };
    return this.synthetic('capture:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'platform-http-fixture', behavior: behavior[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => {
      this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
      return target;
    };
    if (specifier === 'capture:platform') return this.platform();
    if (specifier.startsWith('capture:source:')) return this.source(specifier.slice('capture:source:'.length));
    if (specifier === 'node:crypto' || specifier === 'node:buffer') {
      link('native-platform', specifier);
      const bindings = specifier === 'node:buffer' ? { Buffer } : {
        createHash, hash: nativeHash, randomBytes: size => Buffer.alloc(size, 0x42),
      };
      return this.synthetic(specifier, bindings, Object.fromEntries(Object.keys(bindings).map(name => [name, {
        kind: name === 'randomBytes' ? 'deterministic-platform' : 'native-platform',
        behavior: name === 'randomBytes' ? 'Buffer.alloc(size,0x42), stable wrapper markers' : `actual ${specifier}:${name}`,
      }])));
    }
    const deferred = deferredImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      link('unused-platform-service', deferred[2]);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (importer === common && specifier === '../../config/types.secrets.js') {
      link('literal-config-fixture', 'capture:literal-config');
      this.verifiedSource('src/config/types.secrets.ts', false);
      return this.synthetic('capture:literal-config', {
        normalizeResolvedSecretInputString: ({ value }) => {
          this.audit.push({ kind: 'literal-config-fixture', valueKind: typeof value });
          return value;
        },
      }, { normalizeResolvedSecretInputString: { kind: 'literal-config-fixture',
        behavior: 'passes explicit fixture string through; secret resolution unexecuted' } });
    }
    if (facades[specifier]) {
      link('whole-module-re-export-facade', 'capture:facade:' + specifier);
      const provenance = specifier.startsWith(sdk)
        ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts'
        : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const id = 'capture:facade:' + specifier;
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(facades[specifier], {
        context: this.context, identifier: id,
      }));
      return this.modules.get(id);
    }
    if (specifier === sdk + 'provider-web-search-config-contract') {
      return this.source(link('whole-module-alias', 'src/plugin-sdk/provider-web-search-config-contract.ts'));
    }
    if (specifier.startsWith('@openclaw/normalization-core/')) {
      return this.source(link('whole-module-alias', normalization + specifier.split('/').at(-1) + '.ts'));
    }
    if (specifier.startsWith('.')) {
      const path = relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      link('relative-whole-module', path);
      return this.source(path);
    }
    throw Error(`Unaudited capture import: ${importer} -> ${specifier}`);
  }

  async evaluate(module) {
    if (module.status === 'unlinked') await module.link((specifier, owner) => this.import(specifier, owner.identifier));
    if (module.status === 'linked') await module.evaluate({ timeout: 2_000 });
    assert.equal(module.status, 'evaluated', module.identifier);
  }

  async group(recipe) {
    const module = this.source(factory);
    await this.evaluate(module);
    const setup = { config: { plugins: { entries: { brave: { config: { webSearch: {
      apiKey: 'fixture-brave-key', baseUrl, mode: recipe.mode,
    } } } } } }, searchConfig: { cacheTtlMinutes: 15, maxResults: 5 } };
    const tool = module.namespace.createBraveWebSearchProvider().createTool(setup);
    const steps = [];
    for (const item of recipe.steps) {
      this.nowMs = Date.parse(item.clock ?? BRAVE_REFERENCE_CLOCK);
      const args = plain(item.arguments);
      const before = plain(args);
      const count = this.requests.length;
      const result = plain(await tool.execute(args));
      assert.deepEqual(args, before, 'callback preserves raw input');
      assert.equal(result.provider, 'brave', 'ordinary callback success');
      assert.equal(result.count, 1);
      const requests = this.requests.slice(count);
      assert.ok(requests.length <= 1);
      steps.push({ arguments: before, clock: new Date(this.nowMs).toISOString(),
        request: requests[0] ?? null, cached: result.cached === true,
        cumulativeRequests: this.requests.length, result });
    }
    return { id: recipe.id, mode: recipe.mode, setup,
      descriptor: { description: tool.description, parameters: plain(tool.parameters) },
      steps, audit: this.audit };
  }
}

function recipes() {
  const step = (query, options = {}, clock) => ({ arguments: { query, ...options }, ...(clock ? { clock } : {}) });
  const group = (id, mode, steps) => ({ id, mode, steps });
  const rows = [group('locale-canonical-cache', 'web', [
    step('locale', { country: ' de ', language: ' JA ', ui_lang: 'eN-us' }),
    step('locale', { country: 'DE', search_lang: 'jp', ui_lang: 'en-US' }),
    step('locale', { country: 'DE', search_lang: 'jp', ui_lang: 'en-US', count: 5 }),
    step('locale', { country: 'US', search_lang: 'jp', ui_lang: 'en-US' }),
    step('locale', { country: 'DE', search_lang: 'jp', ui_lang: 'en-US', count: 3 }),
    step('locale', { country: 'DE', search_lang: 'jp', ui_lang: 'en-GB' }),
  ]), group('swapped-locale-cache', 'web', [
    step('swapped', { search_lang: 'en-US', ui_lang: 'ja' }),
    step('swapped', { search_lang: 'jp', ui_lang: 'en-US' }),
  ]), group('explicit-language-precedence', 'web', [
    step('precedence', { search_lang: ' DE ', language: 'fr' }),
    step('precedence', { search_lang: 'de' }),
  ]), group('country-all', 'web', [step('all', { country: ' all ' })]),
  group('dual-purpose-locale', 'web', [
    step('dual-purpose', { search_lang: 'en-gb', ui_lang: 'pt-BR' }),
  ])];
  for (const [alias, canonical] of [['zh', 'zh-hans'], ['zh-cn', 'zh-hans'], ['zh-sg', 'zh-hans'],
    ['zh-hk', 'zh-hant'], ['zh-tw', 'zh-hant']]) {
    rows.push(group('language-' + alias, 'web', [
      step('alias', { language: alias.toUpperCase() }), step('alias', { search_lang: canonical }),
    ]));
  }
  for (const mode of ['web', 'llm-context']) {
    rows.push(group(`${mode}-freshness-cache`, mode, [
      ...[[' Day ', 'pd'], ['WEEK', 'pw'], ['month', 'pm'], ['YEAR', 'py']]
        .flatMap(([name, shortcut]) => [step('freshness', { freshness: name }),
          step('freshness', { freshness: shortcut.toUpperCase() })]),
    ]));
    rows.push(group(`${mode}-bounded-date-cache`, mode, [
      step('bounded', { date_after: ' 1/2/2025 ', date_before: '1/31/2025' }),
      step('bounded', { date_after: '2025-01-02', date_before: '2025-01-31' }),
      step('bounded', { date_after: '2025-01-02', date_before: '2025-02-01' }),
    ]));
    rows.push(group(`${mode}-freshness-range-cache`, mode, [
      step('range', { freshness: ' 2025-01-02to2025-01-31 ' }),
      step('range', { freshness: '2025-01-02to2025-01-31' }),
    ]));
    rows.push(group(`${mode}-same-day`, mode, [
      step('same-day', { date_after: '2025-01-02', date_before: '2025-01-02' }),
    ]));
    rows.push(group(`${mode}-after-only-cache`, mode, [
      step('after', { date_after: '1/2/2025' }), step('after', { date_after: '2025-01-02' }),
    ]));
    rows.push(group(`${mode}-utc-rollover`, mode, [
      step('rollover', { date_after: '2025-01-02' }, '2026-10-27T23:59:59.000Z'),
      step('rollover', { date_after: '2025-01-02' }, '2026-10-28T00:00:01.000Z'),
    ]));
  }
  rows.push(group('web-before-only-cache', 'web', [
    step('before', { date_before: '1/31/2025' }), step('before', { date_before: '2025-01-31' }),
  ]));
  return rows;
}

export async function captureBraveSearchFilters(root = '/tmp/openclaw-488631c') {
  const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  assert.equal(head, BRAVE_REFERENCE_PIN);
  const groups = [];
  const sources = new Map(), aliases = new Map(), stubs = new Map();
  for (const recipe of recipes()) {
    const capture = new BraveCapture(root);
    groups.push(await capture.group(recipe));
    for (const [key, value] of capture.sources) sources.set(key, value);
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
  }
  const sort = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL(import.meta.url))) },
    source: factory, export: 'createBraveWebSearchProvider',
    invocation: 'createBraveWebSearchProvider().createTool(setup).execute(arguments)',
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    boundaries: {
      factoryInvoked: true, callbackInvoked: true, fullSourceModules: true,
      bodyProjections: false, actualSharedCache: true, productionNetworkInvoked: false,
      clock: 'Date construction and Date.now use a synthetic UTC clock; recorded rollover steps advance it',
      fixtureEnvironment: {},
      limits: ['HTTP wrappers, response parsing, endpoint classification and deadline machinery are fixture bindings',
        'literal fixture config does not exercise secret resolution',
        'factory callback evidence does not prove plugin discovery, registration or runtime assembly',
        'only ordinary successful locale/time/cache paths are captured'],
    },
    sources: sort(sources.values()), aliases: sort(aliases.values()),
    facades: Object.entries(facades).map(([specifier, code]) => ({ specifier, generatedCode: code, sha256: digest(code) })),
    stubs: sort(stubs.values()), groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', output] = process.argv.slice(2);
  const capture = await captureBraveSearchFilters(root);
  const json = JSON.stringify(capture, null, 2) + '\n';
  if (output) writeFileSync(output, json);
  else process.stdout.write(json);
}
