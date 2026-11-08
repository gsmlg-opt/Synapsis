// Ordinary successful Unicode budget observations from complete pinned modules.
// HTTP/config/clock bindings are explicit fixtures; this is not runtime assembly.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import {
  BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture,
} from './capture-brave-search-filters.mjs';

const output = 'src/agents/tools/web-search-output.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const shared = 'src/agents/tools/web-shared.ts';
const external = 'src/security/external-content.ts';
const normalization = 'packages/normalization-core/src/';
const tavily = 'extensions/tavily/src/tavily-client.ts';
const firecrawl = 'extensions/firecrawl/src/firecrawl-client.ts';
const brave = 'extensions/brave/src/brave-web-search-provider.ts';
const sdk = 'openclaw/plugin-sdk/';
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const additionalSources = new Set([
  output, tavily, firecrawl, 'extensions/tavily/src/config.ts', 'src/utils/boolean.ts',
]);
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const facades = {
  [sdk + 'number-runtime']: from([
    'asNonNegativeFiniteNumber', 'asPositiveFiniteNumber', 'parseDateStringTimestampMs',
    'parseFiniteNumber', 'resolveIntegerOption',
  ], normalization + 'number-coercion.ts'),
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'buildSearchCacheKey', 'DEFAULT_SEARCH_COUNT',
      'parseWebSearchTimeFilters', 'readCachedSearchPayload', 'readConfiguredSecretString',
      'readWebSearchApiKey', 'readWebSearchQueryAndCount', 'resolveSearchCacheTtlMs',
      'resolveSearchCount', 'resolveSearchTimeoutSeconds', 'resolveSiteName',
      'writeCachedSearchPayload'], common),
    from(['readToolStringParam as readStringParam'], 'src/agents/tools/common.ts'),
    from(['normalizeCacheKey', 'readCache', 'writeCache', 'resolvePositiveTimeoutSeconds'], shared),
    from(['wrapWebContent'], external),
    'export {postTrustedWebToolsJson,formatCliCommand,withSelfHostedWebToolsEndpoint,withTrustedWebToolsEndpoint} from "unicode:platform";',
  ].join('\n'),
  [sdk + 'provider-web-fetch']: [
    from(['resolvePositiveTimeoutSeconds'], shared),
    'export {markdownToText,readResponseText,withSelfHostedWebToolsEndpoint,withStrictWebToolsEndpoint} from "unicode:platform";',
  ].join('\n'),
  [sdk + 'provider-http']: 'export {ProviderHttpError,assertOkOrThrowProviderError,readProviderJsonResponse,readProviderJsonObjectResponse} from "unicode:platform";',
  [sdk + 'security-runtime']: from([
    'truncateSanitizedExternalContent', 'wrapExternalContent', 'wrapWebContent',
  ], external),
  [sdk + 'string-coerce-runtime']: [
    from(['isRecord', 'asRecord', 'asNonArrayRecord', 'asOptionalObjectRecord',
      'asOptionalRecord', 'readStringField'], normalization + 'record-coerce.ts'),
    from(['normalizeLowercaseStringOrEmpty', 'normalizeOptionalString'], normalization + 'string-coerce.ts'),
    from(['asBoolean'], 'src/utils/boolean.ts'),
  ].join('\n'),
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-input-runtime']: 'export {assertPluginCapabilitySecretAvailable} from "unicode:platform";',
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "unicode:platform";',
  [sdk + 'plugin-config-runtime']: 'export {resolvePluginConfigObject} from "unicode:platform";',
  [sdk + 'ssrf-runtime']: 'export {SsrFBlockedError,assertHttpUrlTargetsPrivateNetwork,isBlockedHostnameOrIp,isPrivateIpAddress,resolvePinnedHostnameWithPolicy} from "unicode:platform";',
};

class UnicodeCapture extends BraveCapture {
  constructor(root, payload = {}) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
  }

  source(path) {
    if (!additionalSources.has(path)) return super.source(path);
    if (!this.modules.has(path)) {
      this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
        context: this.context, identifier: path,
        importModuleDynamically: specifier => {
          this.audit.push({ kind: 'unused-dynamic-import', importer: path, specifier });
          throw Error('Unicode capture has no dynamic client imports');
        },
      }));
    }
    return this.modules.get(path);
  }

  typeboxModule(file) {
    assert.ok(file === this.typeboxRoot || file.startsWith(this.typeboxRoot + sep));
    const id = 'unicode:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file);
      const path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), {
        context: this.context, identifier: id,
      }));
    }
    return this.modules.get(id);
  }

  platform() {
    const record = (name, detail = {}) => this.audit.push({ kind: 'unicode-platform', export: name, ...detail });
    const endpoint = async (params, run) => {
      record('fixture-http');
      const url = new URL(params.url);
      this.requests.push({ method: params.init.method, path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        ...(params.init.body ? { body: JSON.parse(params.init.body) } : {}) });
      return run({ response: Response.json(plain(this.payload)) });
    };
    const unused = name => () => {
      record('unused-service-invoked', { name });
      throw Error(`Unicode capture does not invoke ${name}`);
    };
    const bindings = {
      buildTimeoutAbortSignal: () => {
        record('buildTimeoutAbortSignal');
        return { signal: undefined, cleanup: () => record('timeout-cleanup') };
      },
      assertHttpUrlTargetsPrivateNetwork: async () => record('fixture-endpoint-classification'),
      withSelfHostedWebToolsEndpoint: endpoint,
      withTrustedWebToolsEndpoint: endpoint,
      withStrictWebToolsEndpoint: endpoint,
      postTrustedWebToolsJson: async (params, parse) => {
        record('fixture-http');
        const url = new URL(params.url);
        this.requests.push({ method: 'POST', path: url.pathname,
          query: Object.fromEntries(url.searchParams), body: plain(params.body) });
        return parse(Response.json(plain(this.payload)));
      },
      assertOkOrThrowProviderError: () => record('fixture-success-status'),
      readProviderJsonResponse: async response => { record('fixture-json-parser'); return response.json(); },
      readProviderJsonObjectResponse: async response => { record('fixture-json-parser'); return response.json(); },
      createSubsystemLogger: () => { record('fixture-logger'); return { info: () => {} }; },
      assertPluginCapabilitySecretAvailable: () => record('literal-fixture-config-availability'),
      resolveReadOnlyEnvSecretRef: ({ value }) => {
        record('literal-fixture-string-resolution', { valueKind: typeof value });
        return typeof value === 'string' && value ? { status: 'available', value } : { status: 'missing' };
      },
      resolvePluginConfigObject: (cfg, provider) => {
        record('fixture-plugin-config-projection', { provider });
        return cfg?.plugins?.entries?.[provider]?.config;
      },
      ProviderHttpError: unused('ProviderHttpError'),
      SsrFBlockedError: unused('SsrFBlockedError'),
      isBlockedHostnameOrIp: unused('isBlockedHostnameOrIp'),
      isPrivateIpAddress: unused('isPrivateIpAddress'),
      resolvePinnedHostnameWithPolicy: unused('resolvePinnedHostnameWithPolicy'),
      markdownToText: unused('markdownToText'),
      readResponseText: unused('readResponseText'),
      formatCliCommand: unused('formatCliCommand'),
    };
    const descriptions = Object.fromEntries(Object.keys(bindings).map(name => [name, {
      kind: 'unicode-ordinary-platform-fixture',
      behavior: name.startsWith('readProviderJson') ? 'successful fixture Response.json; production parser unexecuted'
        : name === 'resolveReadOnlyEnvSecretRef' ? 'literal fixture string only; real secret resolution unexecuted'
          : name === 'resolvePluginConfigObject' ? 'direct explicit fixture config projection; plugin runtime unexecuted'
            : 'synthetic ordinary-success platform binding; no production network, endpoint policy, deadline or error proof',
    }]));
    return this.synthetic('unicode:platform', bindings, descriptions);
  }

  import(specifier, importer) {
    const link = (kind, target) => {
      this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    };
    if (specifier === 'unicode:platform' || specifier === 'capture:platform') return this.platform();
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
    if (importer.startsWith('unicode:typebox:')) {
      assert.ok(specifier.startsWith('.'), 'TypeBox dependency is relative');
      const owner = importer.slice('unicode:typebox:'.length);
      const file = realpathSync(resolve(this.typeboxRoot, dirname(owner), specifier));
      return this.typeboxModule(file);
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      const path = 'src/web-search/runtime-error.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier, [
        'formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode',
      ]);
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(provenance, false);
      const code = facades[specifier];
      const id = 'unicode:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode: code, sha256: digest(code) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(code, {
        context: this.context, identifier: id,
      }));
      return this.modules.get(id);
    }
    return super.import(specifier, importer);
  }
}

const genericRecipes = () => {
  const one = 'https://unicode.example/one';
  const row = (title, snippet, extra = {}) => ({ title, url: one, snippet, siteName: 'unicode.example', ...extra });
  return [
    { id: 'generic-emoji-budget', rows: [row('😀'.repeat(12_000), 'tail', { siteName: 'unicode.example' })] },
    { id: 'generic-combining-budget', rows: [row('e\u0301'.repeat(10_000), 'tail')] },
    { id: 'generic-zwj-budget', rows: [row('👩‍💻'.repeat(5_000), 'next')] },
    { id: 'generic-ten-urls-first', rows: Array.from({ length: 10 }, (_, index) => ({
      title: '😀'.repeat(12_000), url: `https://unicode.example/source-${index}`,
      snippet: 'passage', siteName: 'unicode.example',
    })) },
    { id: 'generic-short-unicode', rows: [row(' \t界😀e\u0301 \n', '👩‍💻文', { siteName: 'unicode.example' })] },
  ];
};

function providerRecipes() {
  const one = 'https://unicode.example/one', two = 'https://unicode.example/two';
  return [
    { id: 'tavily-emoji-leftover', provider: 'tavily', arguments: { count: 2 },
      httpPayload: { results: [
        { title: '界'.repeat(19_999), url: one, content: '😀tail', score: 0.9 },
        { title: 'Z', url: two, content: 'later', score: 0.8 },
      ], answer: 'answer' } },
    { id: 'tavily-combining-prefix', provider: 'tavily', arguments: { count: 1 },
      httpPayload: { results: [{ title: 'e\u0301'.repeat(10_000) + 'A', url: one, content: 'tail' }] } },
    { id: 'tavily-answer-prefix', provider: 'tavily', arguments: { count: 1, include_answer: true },
      httpPayload: { results: [{ title: 'A', url: one, content: '界'.repeat(19_996) }], answer: '😀XYZ' } },
    { id: 'firecrawl-emoji-leftover', provider: 'firecrawl', arguments: { count: 2, scrape_results: true },
      httpPayload: { success: true, data: { web: [
        { title: '界'.repeat(19_999), url: one, description: '😀tail', markdown: 'A🙂' },
        { title: 'Later', url: two, description: 'later', markdown: 'later' },
      ] } } },
    { id: 'firecrawl-combining-prefix', provider: 'firecrawl', arguments: { count: 1, scrape_results: true },
      httpPayload: { success: true, data: { web: [
        { title: 'e\u0301'.repeat(10_000) + 'A', url: one, description: 'tail', markdown: '# Tail' },
      ] } } },
    { id: 'brave-web-no-provider-cap', provider: 'brave', mode: 'web', arguments: { count: 2 },
      httpPayload: { web: { results: [
        { title: ' '.repeat(20_000), url: one, description: ' ' },
        { title: 'Later 😀 source', url: two, description: 'Visible 文 passage' },
      ] } } },
    { id: 'brave-llm-no-provider-cap', provider: 'brave', mode: 'llm-context', arguments: { count: 2 },
      httpPayload: { grounding: { generic: [
        { title: ' '.repeat(20_000), url: one, snippets: [' ', 'Other passage'] },
        { title: 'Later 😀 source', url: two, snippets: ['Visible 文 passage'] },
      ] }, sources: {} } },
  ];
}

const prefixRecipes = () => [
  { id: 'supplementary-before-pair', value: 'A😀B', maxUnits: 2 },
  { id: 'supplementary-after-pair', value: 'A😀B', maxUnits: 3 },
  { id: 'supplementary-exact', value: 'A😀B', maxUnits: 4 },
  { id: 'supplementary-no-half', value: '😀B', maxUnits: 1 },
  { id: 'combining-scalar-boundary', value: 'e\u0301x', maxUnits: 1 },
  { id: 'zwj-scalar-boundary', value: '👩‍💻!', maxUnits: 3 },
  { id: 'bmp-boundary', value: '界文', maxUnits: 1 },
  { id: 'zero-budget', value: 'A', maxUnits: 0 },
];

function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') {
    return ['title', 'snippet', 'description', 'content', 'answer', 'siteName'].includes(field)
      ? unwrap(value) : value;
  }
  if (Array.isArray(value)) return value.map(item =>
    field === 'snippets' && typeof item === 'string' ? unwrap(item) : unwrapResult(item, unwrap));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}

export async function captureSearchUnicode(root = '/tmp/openclaw-488631c') {
  assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), BRAVE_REFERENCE_PIN);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  let typeboxVersion;
  const merge = capture => {
    for (const [key, value] of capture.sources) {
      const old = sources.get(key);
      sources.set(key, { ...value, executed: value.executed || old?.executed === true });
    }
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
    typeboxVersion ??= capture.typeboxVersion;
  };
  const genericCases = [], providerCases = [], prefixCases = [];
  const normalizer = new UnicodeCapture(root);
  const normalizerModule = normalizer.source(output);
  await normalizer.evaluate(normalizerModule);
  const normalize = normalizerModule.namespace.normalizeWebSearchOutput;
  const unwrap = normalizerModule.namespace.unwrapWebSearchOutputText;
  const externalModule = normalizer.source(external);
  await normalizer.evaluate(externalModule);
  const probe = 'ordinary-unicode-reference-frame-probe';
  const frame = externalModule.namespace.wrapWebContent(probe, 'web_search');
  assert.equal(frame.split(probe).length, 2);
  const [frameStart, frameEnd] = frame.split(probe);
  const unframe = value => value.startsWith(frameStart) && value.endsWith(frameEnd)
    ? value.slice(frameStart.length, value.length - frameEnd.length) : value;

  for (const recipe of genericRecipes()) {
    const providerResult = { results: recipe.rows, count: recipe.rows.length, tookMs: 0 };
    const query = recipe.id;
    const normalizedResult = plain(normalize({ result: plain(providerResult), provider: 'brave', query }));
    genericCases.push({ id: recipe.id, provider: 'brave', query, providerResult,
      normalizedResult, normalizedUnwrappedResult: unwrapResult(normalizedResult, unwrap) });
  }

  for (const recipe of providerRecipes()) {
    const capture = new UnicodeCapture(root, recipe.httpPayload);
    const arguments_ = { query: recipe.id, ...recipe.arguments };
    const before = plain(arguments_);
    const providerConfig = { apiKey: 'unicode-fixture-key', baseUrl: recipe.provider === 'firecrawl'
      ? 'https://api.firecrawl.dev' : 'http://127.0.0.1:18181/proxy', ...(recipe.mode ? { mode: recipe.mode } : {}) };
    const cfg = { tools: { web: { search: { cacheTtlMinutes: 0 } } },
      plugins: { entries: { [recipe.provider]: { config: { webSearch: providerConfig } } } } };
    let result, invocation;
    if (recipe.provider === 'brave') {
      const module = capture.source(brave);
      await capture.evaluate(module);
      const tool = module.namespace.createBraveWebSearchProvider().createTool({
        config: cfg, searchConfig: { cacheTtlMinutes: 0, maxResults: 5 },
      });
      result = await tool.execute(arguments_);
      invocation = 'createBraveWebSearchProvider().createTool(setup).execute(arguments)';
    } else if (recipe.provider === 'tavily') {
      const module = capture.source(tavily);
      await capture.evaluate(module);
      result = await module.namespace.runTavilySearch({ cfg, query: arguments_.query,
        maxResults: arguments_.count, includeAnswer: arguments_.include_answer });
      invocation = 'runTavilySearch(params)';
    } else {
      const module = capture.source(firecrawl);
      await capture.evaluate(module);
      result = await module.namespace.runFirecrawlSearch({ cfg, query: arguments_.query,
        count: arguments_.count, scrapeResults: arguments_.scrape_results });
      invocation = 'runFirecrawlSearch(params)';
    }
    assert.deepEqual(arguments_, before);
    result = plain(result);
    assert.equal(result.provider, recipe.provider);
    assert.equal(capture.requests.length, 1);
    const resultUnwrapped = unwrapResult(result, unwrap);
    const resultContentUnframed = unwrapResult(result, unframe);
    providerCases.push({ ...recipe, arguments: before, config: cfg, invocation,
      requests: plain(capture.requests), result, resultUnwrapped, resultContentUnframed,
      audit: plain(capture.audit) });
    const normalizedResult = plain(normalize({ result, provider: recipe.provider, query: before.query }));
    genericCases.push({ id: 'normalized-' + recipe.id, provider: recipe.provider,
      ...(recipe.mode ? { mode: recipe.mode } : {}),
      query: before.query, providerCaseId: recipe.id, providerResult: result,
      normalizedResult, normalizedUnwrappedResult: unwrapResult(normalizedResult, unwrap) });
    merge(capture);
  }

  const utf16Module = normalizer.source(normalization + 'utf16-slice.ts');
  await normalizer.evaluate(utf16Module);
  for (const recipe of prefixRecipes()) {
    const text = utf16Module.namespace.truncateUtf16Safe(recipe.value, recipe.maxUnits);
    const bounded = plain(externalModule.namespace.truncateSanitizedExternalContent(recipe.value, recipe.maxUnits));
    assert.equal(text, bounded.text, 'ordinary text is unchanged apart from its retained prefix');
    prefixCases.push({ ...recipe, text, ...bounded, usedUnits: bounded.text.length });
  }
  merge(normalizer);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-search-unicode.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported complete-module BraveCapture loader; subclass adds fixed client/output modules and explicit SDK/platform bindings' }],
    invocations: [
      'normalizeWebSearchOutput({result,provider,query})', 'truncateUtf16Safe(value,maxUnits)',
      'truncateSanitizedExternalContent(value,maxUnits)',
      'createBraveWebSearchProvider().createTool(setup).execute(arguments)',
      'runTavilySearch(params)', 'runFirecrawlSearch(params)',
    ],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    boundaries: {
      fullSourceModules: true, bodyProjections: false, genericNormalizerInvoked: true,
      completeClientSearchFunctionsInvoked: true, bravePublicCallbacksInvoked: true,
      productionNetworkInvoked: false,
      unwrap: 'Calls original unwrapWebSearchOutputText only for ordinary prose fields and snippets; retains metadata stamp, query, URL, dates and all other fields',
      providerUnframe: 'resultContentUnframed removes exactly one frame measured from actual wrapWebContent with an ordinary probe; preserves all leading/trailing prose whitespace, metadata stamp and other fields',
      limits: [
        'Successful JSON HTTP wrappers/parser/deadline/logger/endpoint/fixture literal configuration are explicit platform bindings',
        'Real secret resolution, network endpoint-policy machinery, error branches, registration, plugin discovery and runtime assembly are unexecuted',
        'Only valid ASCII HTTP URLs and ordinary well-formed Unicode text are exercised',
        'No marker/special-token, security/permission, auth/TLS, negative, mixed-suite or real-provider tests',
        'Generic error/answer/raw branches, URL canonicalization and full rich-output parity remain outside this fixture',
      ],
    },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), stubs: sorted(stubs.values()),
    facades: sorted(generated.values()), typebox: { version: typeboxVersion, files: sorted(dependencies.values()) },
    genericCases, providerCases, prefixCases,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', outputPath] = process.argv.slice(2);
  const capture = await captureSearchUnicode(root);
  const json = JSON.stringify(capture, null, 2) + '\n';
  if (outputPath) writeFileSync(outputPath, json);
  else process.stdout.write(json);
}
