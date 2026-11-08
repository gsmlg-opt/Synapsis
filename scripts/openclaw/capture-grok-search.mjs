// Ordinary Grok web_search from complete unchanged pinned modules.
// Authentication services, successful HTTP/JSON, deadlines and clock are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/xai/web-search.ts';
const runtime = 'extensions/xai/src/web-search-provider.runtime.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const configHelpers = 'src/agents/tools/web-search-provider-config.ts';
const output = 'src/agents/tools/web-search-output.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const additionalSources = new Set([
  factory, runtime, output, 'extensions/xai/web-search-provider-shared.ts',
  'extensions/xai/src/responses-tool-shared.ts', 'extensions/xai/src/web-search-shared.ts',
  'extensions/xai/src/tool-config-shared.ts', 'extensions/xai/src/x-search-config.ts',
  'extensions/xai/src/x-search-shared.ts', 'extensions/xai/model-definitions.ts',
  'extensions/xai/model-id.ts', 'extensions/xai/runtime-model-compat.ts',
  'extensions/xai/model-compat.ts', 'extensions/xai/provider-routing.ts', 'extensions/xai/provider-id.ts',
  'src/plugins/provider-model-compat.ts',
]);
const facades = {
  [sdk + 'provider-web-search']: [
    from(['postTrustedWebToolsJson', 'readWebSearchQueryAndCount', 'resolveSearchCacheTtlMs'], common),
    from(['getScopedCredentialValue', 'mergeScopedSearchConfig', 'resolveProviderWebSearchPluginConfig'], configHelpers),
    from(['normalizeCacheKey', 'readCache', 'resolveTimeoutSeconds', 'writeCache'], 'src/agents/tools/web-shared.ts'),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
    'export {formatCliCommand,resolveWebSearchProviderCredential} from "grok:platform";',
  ].join('\n'),
  [sdk + 'provider-model-shared']: from(['applyModelCompatPatch'], 'src/plugins/provider-model-compat.ts'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord', 'asOptionalRecord', 'isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeOptionalLowercaseString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'security-runtime']: from(['truncateSanitizedExternalContent'], 'src/security/external-content.ts'),
  [sdk + 'text-utility-runtime']: from(['truncateUtf16Safe'], normalization + 'utf16-slice.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonObjectResponse} from "grok:platform";',
  [sdk + 'extension-shared']: 'export {buildTimeoutAbortSignal} from "grok:platform";',
  [sdk + 'provider-auth']: 'export {coerceSecretRef,listUsableProviderAuthProfileIdsAsync} from "grok:platform";',
  [sdk + 'provider-auth-runtime']: 'export {isProviderAuthError,resolveApiKeyForProvider} from "grok:platform";',
  [sdk + 'model-ref-parse']: 'export {normalizeProviderId} from "grok:platform";',
};
const unusedImports = [
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/openai-completions-compat', ['resolveOpenAICompletionsCompat'], 'packages/ai/src/internal/openai-completions-compat.ts'],
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/tool-schema', ['extractToolSchemaModelCompat', 'resolveUnsupportedToolSchemaKeywords'], 'packages/ai/src/internal/tool-schema.ts'],
  ['src/plugins/provider-model-compat.ts', '../agents/model-compat-catalog.js', ['normalizeModelTransportBaseUrl']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-attribution.js', ['resolveProviderRequestCapabilities']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-request-config.js', ['getModelProviderRequestRouteFacts']],
  [output, '../../web-search/runtime-error.js', ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']],
];

class GrokCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    this.context.Headers = Headers;
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
    const id = 'grok:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file), path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  platform() {
    const record = (kind, detail = {}) => this.audit.push({ kind, ...detail });
    const unused = name => () => { record('unused-service-invoked', { export: name }); throw Error('Unused: ' + name); };
    const bindings = {
      withTrustedWebToolsEndpoint: async (params, run) => {
        record('successful-http-fixture', { timeoutSeconds: params.timeoutSeconds });
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), body: JSON.parse(params.init.body),
          bodyText: params.init.body, headers: Object.fromEntries(new Headers(params.init.headers)),
          timeoutSeconds: params.timeoutSeconds, signalSupplied: params.signal !== undefined });
        this.nowMs += 7;
        return run({ response: Response.json(plain(this.payload)) });
      },
      readProviderJsonObjectResponse: async (response, errorLabel) => {
        record('successful-json-fixture', { errorLabel }); return response.json();
      },
      buildTimeoutAbortSignal: params => {
        assert.equal(params.signal, undefined);
        record('successful-timeout-fixture', plain(params));
        return { signal: undefined, cleanup: () => record('timeout-cleanup') };
      },
      resolveApiKeyForProvider: async params => {
        assert.equal(params.provider, 'xai');
        assert.equal(params.cfg.plugins.entries.xai.config.webSearch.apiKey, 'fixture-grok-key');
        assert.equal(params.signal, undefined);
        record('provider-auth-success-fixture', { provider: params.provider, mode: 'api-key' });
        return { apiKey: 'fixture-grok-key', mode: 'api-key' };
      },
      resolveWebSearchProviderCredential: params => {
        assert.deepEqual(plain(params), { credentialValue: 'fixture-grok-key',
          path: 'plugins.entries.xai.config.webSearch.apiKey', envVars: [] });
        record('configured-literal-key-fixture', plain(params));
        return 'fixture-grok-key';
      },
      coerceSecretRef: unused('coerceSecretRef'),
      listUsableProviderAuthProfileIdsAsync: unused('listUsableProviderAuthProfileIdsAsync'),
      isProviderAuthError: unused('isProviderAuthError'), formatCliCommand: unused('formatCliCommand'),
      normalizeProviderId: unused('normalizeProviderId'),
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'records actual source request; synthetic successful Response; clock+7ms; production network/guard/release/deadline unexecuted',
      readProviderJsonObjectResponse: 'successful fixture Response.json; production bounded JSON parser/error checking unexecuted',
      buildTimeoutAbortSignal: 'records requested operation/timeoutMs; no signal or timer; cleanup recorded; real timeout/cancellation unexecuted',
      resolveApiKeyForProvider: 'explicit successful literal fake key and api-key mode only; actual auth/env/profile/OAuth/credential discovery unexecuted',
      resolveWebSearchProviderCredential: 'only exact explicit literal fake key/path/empty envVars; production credential normalization/resolution unexecuted',
    };
    return this.synthetic('grok:platform', bindings, Object.fromEntries(Object.keys(bindings).map(name => [name,
      { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service',
        behavior: descriptions[name] ?? 'throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'grok:platform') {
      // Every replaced service retains its exact source provenance, including SDK barrel targets.
      for (const path of ['src/agents/tools/web-search-provider-credentials.ts',
        'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
        'src/plugin-sdk/extension-shared.ts', 'src/agents/provider-http-errors.ts',
        'src/utils/fetch-timeout.ts', 'src/agents/model-auth-runtime-shared.ts',
        'src/agents/model-auth.ts', 'src/plugins/runtime/runtime-model-auth.runtime.ts',
        'src/plugins/provider-auth-availability.ts', 'src/config/types.secrets.ts',
        'packages/model-catalog-core/src/provider-id.ts',
        'src/cli/command-format.ts']) this.verifiedSource(path, false);
      return this.platform();
    }
    if (importer === common && specifier === './web-guarded-fetch.js') {
      const path = 'src/agents/tools/web-guarded-fetch.ts'; this.verifiedSource(path, false);
      link('explicit-successful-http-fixture', path); return this.platform();
    }
    const deferred = unusedImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = deferred[3] ?? relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false); link('explicit-unused-import', path);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (specifier === './openclaw.plugin.json' && importer.startsWith('extensions/xai/')) {
      const path = 'extensions/xai/openclaw.plugin.json', bytes = readFileSync(join(this.root, path));
      assert.deepEqual(bytes, execFileSync('git', ['show', `${BRAVE_REFERENCE_PIN}:${path}`], { cwd: this.root }));
      this.manifest = { path, sha256: digest(bytes), gitBlob: blob(bytes) };
      link('actual-pinned-json-module', path);
      return this.synthetic('grok:manifest', { default: JSON.parse(bytes) },
        { default: { kind: 'actual-pinned-json-module', behavior: 'actual JSON.parse of complete pinned manifest' } });
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
    if (importer.startsWith('grok:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('grok:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts'; this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'grok:facade:' + specifier;
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
export function unframeGrokSearchText(text) {
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope'); return match[2];
}
function portableProvider(result) {
  const copy = plain(result); copy.content = unframeGrokSearchText(copy.content); delete copy.externalContent; return copy;
}
function unwrapResult(value, unwrap, field) {
  if (typeof value === 'string') return ['content', 'title'].includes(field) ? unwrap(value) : value;
  if (Array.isArray(value)) return value.map(item => unwrapResult(item, unwrap, field));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, item]) => [key, unwrapResult(item, unwrap, key)]));
  return value;
}
const block = (text, annotations = []) => ({ type: 'output_text', text, annotations });
const message = (...content) => ({ type: 'message', content });
const payload = (...content) => ({ output: [message(...content)] });
const ordinaryPayload = () => ({ ...payload(block(' Ordinary web answer. ')), citations: ['https://source.example/one'],
  inline_citations: [{ start_index: 1, end_index: 9, url: 'https://source.example/one' }] });
const step = (args, providerConfig, searchConfig) => ({ arguments: args,
  ...(providerConfig ? { providerConfig } : {}), ...(searchConfig ? { searchConfig } : {}) });
function recipes() {
  const rows = [];
  const add = (id, args = { query: id }, options = {}) => rows.push({ id, steps: [step(args)], httpPayload: ordinaryPayload(), ...options });
  add('search-default');
  add('authored-query', { query: ' OpenClaw site:github.com "release notes" ' });
  add('explicit-count', { query: 'ordinary explicit count', count: 4 });
  add('numeric-count-token', { query: 'ordinary numeric count', count: ' 3 ' });
  add('configured-count-ignored', undefined, { searchConfig: { maxResults: 2 } });
  add('configured-timeout', undefined, { searchConfig: { timeoutSeconds: 9 } });
  for (const model of ['grok-4.3', 'grok-4.6', 'grok-4.7-latest', 'grok-4.20', 'grok-4-fast',
    'grok-latest', 'grok-code-fast', 'grok-4-fast-reasoning', 'grok-custom-search']) {
    add('model-' + model, undefined, { providerConfig: { model: ' ' + model + ' ' } });
  }
  for (const [id, baseUrl] of [
    ['official-base', 'https://api.x.ai/v1'], ['official-root', 'https://api.x.ai/'],
    ['official-trailing-slashes', ' https://api.x.ai/v1/// '],
    ['custom-root', 'https://proxy.example/'], ['custom-prefix', 'https://proxy.example/grok/v2///'],
    ['full-responses-endpoint', 'https://proxy.example/v1/responses/'],
  ]) add(id, undefined, { providerConfig: { baseUrl } });
  add('inline-enabled', undefined, { providerConfig: { inlineCitations: true } });
  add('inline-disabled', undefined, { providerConfig: { inlineCitations: false } });
  add('same-query-repeated', undefined, { steps: [step({ query: ' same ordinary query ' }), step({ query: 'same ordinary query' })] });
  add('query-case-identity', undefined, { steps: [step({ query: 'Ordinary Case Query' }),
    step({ query: 'ordinary case query' }), step({ query: ' Ordinary Case Query ' })] });
  add('query-interior-space-identity', undefined, { steps: [step({ query: 'ordinary  spaced query' }),
    step({ query: 'ordinary spaced query' }), step({ query: 'ordinary  spaced query' })] });
  add('count-only-cache', undefined, { steps: [step({ query: 'ordinary count cache', count: 2 }),
    step({ query: 'ordinary count cache', count: ' 4 ' }), step({ query: 'ordinary count cache' })] });
  for (const [id, initial, changed] of [
    ['model-request-identity', { model: 'grok-4.7' }, { model: 'grok-4.3' }],
    ['base-request-identity', { baseUrl: 'https://proxy.example/one' }, { baseUrl: 'https://proxy.example/two' }],
    ['base-case-identity', { baseUrl: 'https://proxy.example/Case' }, { baseUrl: 'https://proxy.example/case' }],
    ['inline-request-identity', { inlineCitations: false }, { inlineCitations: true }],
  ]) add(id, undefined, { steps: [step({ query: 'ordinary request identity' }, initial),
    step({ query: 'ordinary request identity' }, changed), step({ query: 'ordinary request identity' }, initial)] });
  add('cache-off-on', undefined, { steps: [step({ query: 'ordinary cache toggle' }),
    step({ query: 'ordinary cache toggle' }, undefined, { cacheTtlMinutes: 0 }),
    step({ query: 'ordinary cache toggle' })] });
  add('model-alias-cache', undefined, { steps: [step({ query: 'ordinary model alias' }, { model: 'grok-4.7-latest' }),
    step({ query: 'ordinary model alias' }, { model: 'grok-4.7' })] });
  add('ordered-answer-citations', { query: 'ordered grounded answer' }, { httpPayload: {
    output: [message(block(' First ordinary paragraph. ', [{ type: 'url_citation', url: 'https://source.example/two' }]),
      block('Second ordinary paragraph.')), block(' Third ordinary paragraph. ')],
    citations: ['https://source.example/one', 'https://source.example/one', 'https://source.example/three'],
    output_text: 'Ordinary fallback is not selected.',
  } });
  add('annotation-citation-order', undefined, { httpPayload: payload(block('First ', [
    { type: 'url_citation', url: 'https://source.example/two' }, { type: 'url_citation', url: 'https://source.example/two' }]),
  block('second.', [{ type: 'url_citation', url: 'https://source.example/one' }])) });
  add('ordinary-canonical-citations', undefined, { httpPayload: { ...payload(block('Canonical ordinary answer.')),
    citations: ['https://SOURCE.EXAMPLE:443/ordinary', 'https://bare.example', 'https://source.example/ordinary'] } });
  add('output-text-fallback', undefined, { httpPayload: { output_text: ' Ordinary fallback answer. ' } });
  add('direct-output-text', undefined, { httpPayload: { output: [block('Direct ordinary answer.')] } });
  add('answer-without-citations', undefined, { httpPayload: payload(block('Ordinary answer without citations.')) });
  add('inline-ordered-citations', undefined, { providerConfig: { inlineCitations: true }, httpPayload: {
    ...payload(block('First ordinary answer.')), citations: ['https://source.example/one'], inline_citations: [
      { start_index: 0, end_index: 5, url: 'https://SOURCE.EXAMPLE:443/one' },
      { start_index: 6, end_index: 14, url: 'https://source.example/two' }],
  } });
  add('inline-ordinary-utf16', undefined, { providerConfig: { inlineCitations: true }, httpPayload: {
    ...payload(block('A😀BC')), citations: ['https://source.example/one'], inline_citations: [
      { start_index: 1, end_index: 3, url: 'https://source.example/one' },
      { start_index: 3, end_index: 5, url: 'https://source.example/two' }],
  } });
  return rows;
}
function makeSetup(recipe, item = {}) {
  return { config: { plugins: { entries: { xai: { config: { webSearch: {
    apiKey: 'fixture-grok-key', ...recipe.providerConfig, ...item.providerConfig,
  } } } } } }, searchConfig: { cacheTtlMinutes: 15, maxResults: 5, ...recipe.searchConfig, ...item.searchConfig } };
}

export async function captureGrokSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new GrokCapture(root);
  const outputModule = normalizer.source(output); await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput, unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  let manifest;
  for (const recipe of recipes()) {
    const capture = new GrokCapture(root, recipe.httpPayload), module = capture.source(factory);
    await capture.evaluate(module);
    const provider = module.namespace.createXaiWebSearchProvider();
    const setup = makeSetup(recipe, recipe.steps[0]), setupBefore = plain(setup), initialTool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString(), stepSetup = makeSetup(recipe, item), originalSetup = plain(stepSetup);
      const args = plain(item.arguments), original = plain(args), requestCount = capture.requests.length;
      const result = plain(await provider.createTool(stepSetup).execute(args));
      assert.deepEqual(args, original); assert.deepEqual(stepSetup, originalSetup); assert.equal(result.provider, 'grok', recipe.id);
      const requests = capture.requests.slice(requestCount), cacheHit = result.cached === true;
      assert.equal(requests.length, cacheHit ? 0 : 1, recipe.id);
      const generic = plain(normalize({ result, provider: 'grok', query: original.query }));
      assert.equal(generic.kind, 'answer', recipe.id);
      const providerUnwrappedResult = unwrapResult(result, unwrap), genericUnwrappedResult = unwrapResult(generic, unwrap);
      const genericPortableResult = plain(genericUnwrappedResult); delete genericPortableResult.externalContent;
      steps.push({ arguments: original, argumentsAfter: plain(args), clock, clockAfter: new Date(capture.nowMs).toISOString(),
        setup: originalSetup, setupAfter: plain(stepSetup), request: requests[0] ?? null, cacheHit,
        providerResult: result, providerUnwrappedResult, providerPortableResult: portableProvider(result),
        genericResult: generic, genericUnwrappedResult, genericPortableResult,
        publicResult: generic, publicUnwrappedResult: genericUnwrappedResult, publicPortableResult: genericPortableResult,
        cumulativeRequests: capture.requests.length });
    }
    assert.deepEqual(setup, setupBefore);
    groups.push({ id: recipe.id, setup: setupBefore, setupAfter: plain(setup),
      providerMetadata: plain(Object.fromEntries(['id', 'label', 'hint', 'onboardingScopes', 'credentialLabel',
        'envVars', 'authProviderId', 'placeholder', 'signupUrl', 'docsUrl', 'autoDetectOrder', 'credentialPath']
        .map(key => [key, provider[key]]))),
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayload: plain(recipe.httpPayload), steps, audit: plain(capture.audit) });
    manifest = capture.manifest; merge(capture);
  }
  merge(normalizer);
  const after = checkout(root); assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  assert.equal(dependencies.size, 372, 'actual full TypeBox module graph plus package metadata');
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-grok-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, synthetic clock/randomBytes; Grok owns audited facades, literal-key/service fixtures and actual TypeBox graph' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() }, manifest,
    source: factory, export: 'createXaiWebSearchProvider',
    invocations: ['createXaiWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider:"grok",query:authoredArguments.query})',
      'unwrapWebSearchOutputText(providerAndGenericProse)'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true, publicCallbackInvoked: true,
      actualProviderRequestBuilder: true, actualBaseUrlHelper: true, actualCountReaders: true,
      actualConfigMerge: true, actualModelNormalization: true, actualModelReasoning: true,
      actualSourceCache: true, genericNormalizerInvoked: true, actualUnwrapInvoked: true, actualTypeBox: true,
      actualBoundedSuccessReader: false, actualEndpointPolicy: false, actualCredentialResolution: false,
      actualDeadline: false, productionNetworkInvoked: false, pluginRegistrationInvoked: false,
      hostInstalled: false, fixtureEnvironment: {},
      syntheticClock: 'Date construction/Date.now; successful POST advances7ms; no actual timers',
      portableNormalization: 'provider exact one-frame adaptation retains spacing/model/inline; actual source unwrap trims prose; generic portable removes only externalContent after source unwrap; public aliases generic',
      limits: [
        'All58558 tracked pinned blobs verified before/after; executed denotes unchanged whole-module evaluation, not every branch/export',
        'Actual factory, contract/config merge, lazy runtime, query/count/cache/timeout readers, SHA256, model alias/catalog/compat/reasoning, endpoint and Responses request/parser execute',
        'Source endpoint always appends /responses after trimming/trailing slash removal, even for a full responses endpoint',
        'Source normalizeCacheKey trims whole identity and preserves query/model/endpoint case; query reader trims outer whitespace and preserves interior spacing',
        'Source count is validated then ignored; configured maxResults ignored; source cache hits preserve original provider payload and perform no HTTP',
        'Only successful explicit fake literal key/auth-service/JSON/HTTP/no-timer fixtures; actual auth/env/profile/OAuth/SecretRef/network/guard/release/parser deadlines unexecuted',
        'Provider grok web_search differs from dedicated x_search provider xai; provider keeps model/inlineCitations while closed generic answer drops them and retains authored public query',
        'Short ordinary text and fewer than10 citations per payload; no security/permission/authTLS/negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race/real-provider execution',
        'Full WHATWG/Unicode/sanitizer/framing/platform/plugin assembly and Synapsis host/runtime/Worker/Concord remain unqualified; host not installed; full P0-P15 incomplete',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length, groups: groups.length,
      callbacks: groups.reduce((n, row) => n + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.request !== null).length, 0),
      cacheHitCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.cacheHit).length, 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source, gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureGrokSearch(root), json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json); else process.stdout.write(json);
}
