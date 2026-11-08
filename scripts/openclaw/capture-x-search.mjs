// Ordinary successful x_search callbacks from complete unchanged pinned modules.
// Literal credential/config, successful HTTP/parser and clock are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/xai/x-search.ts';
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
  factory, 'extensions/xai/x-search-tool-shared.ts', 'extensions/xai/src/x-search-shared.ts',
  'extensions/xai/src/x-search-config.ts', 'extensions/xai/src/tool-auth-shared.ts',
  'extensions/xai/src/tool-config-shared.ts', 'extensions/xai/src/responses-tool-shared.ts',
  'extensions/xai/src/web-search-shared.ts', 'extensions/xai/model-definitions.ts',
  'extensions/xai/model-id.ts', 'extensions/xai/runtime-model-compat.ts',
  'extensions/xai/model-compat.ts', 'extensions/xai/provider-routing.ts', 'extensions/xai/provider-id.ts',
  'src/shared/global-singleton.ts', 'src/plugins/provider-model-compat.ts', results,
]);
const facades = {
  [sdk + 'global-singleton']: from(['resolveGlobalMap'], 'src/shared/global-singleton.ts'),
  [sdk + 'provider-web-search']: [
    from(['normalizeToIsoDate', 'postTrustedWebToolsJson'], common),
    from(['readCache', 'resolveCacheTtlMs', 'resolveTimeoutSeconds', 'writeCache'], 'src/agents/tools/web-shared.ts'),
    from(['readStringArrayParam', 'readToolStringParam as readStringParam'], readers),
    from(['jsonResult'], results), from(['wrapWebContent'], external),
  ].join('\n'),
  [sdk + 'provider-model-shared']: from(['applyModelCompatPatch'], 'src/plugins/provider-model-compat.ts'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord', 'asOptionalRecord', 'isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeOptionalLowercaseString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'security-runtime']: from(['truncateSanitizedExternalContent'], external),
  [sdk + 'text-utility-runtime']: from(['truncateUtf16Safe'], normalization + 'utf16-slice.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonObjectResponse} from "x-search:platform";',
  [sdk + 'runtime-config-snapshot']: 'export {getRuntimeConfigSnapshot} from "x-search:platform";',
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "x-search:platform";',
  [sdk + 'secret-input']: 'export {coerceSecretRef,normalizeSecretInputString,readProviderEnvValue,resolveNonEnvSecretRefApiKeyMarker} from "x-search:platform";',
  [sdk + 'model-ref-parse']: 'export {normalizeProviderId} from "x-search:platform";',
};
const unusedImports = [
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/openai-completions-compat', ['resolveOpenAICompletionsCompat'], 'packages/ai/src/internal/openai-completions-compat.ts'],
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/tool-schema', ['extractToolSchemaModelCompat', 'resolveUnsupportedToolSchemaKeywords'], 'packages/ai/src/internal/tool-schema.ts'],
  ['src/plugins/provider-model-compat.ts', '../agents/model-compat-catalog.js', ['normalizeModelTransportBaseUrl']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-attribution.js', ['resolveProviderRequestCapabilities']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-request-config.js', ['getModelProviderRequestRouteFacts']],
];

class XSearchCapture extends BraveCapture {
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
    const id = 'x-search:typebox:' + relative(this.typeboxRoot, file);
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
          bodyText: params.init.body, headers: Object.fromEntries(params.init.headers), timeoutSeconds: params.timeoutSeconds });
        this.nowMs += 7;
        return run({ response: Response.json(plain(this.payload)) });
      },
      readProviderJsonObjectResponse: async (response, errorLabel, options) => {
        record('successful-json-fixture', { errorLabel, options: plain(options ?? {}) }); return response.json();
      },
      resolveReadOnlyEnvSecretRef: ({ value, normalizeValue }) => {
        record('literal-fixture-string-resolution', { valueKind: typeof value }); assert.equal(typeof value, 'string');
        return { status: 'available', value: normalizeValue(value) };
      },
      normalizeSecretInputString: value => { assert.equal(typeof value, 'string'); return value.trim(); },
      coerceSecretRef: unused('coerceSecretRef'), readProviderEnvValue: unused('readProviderEnvValue'),
      resolveNonEnvSecretRefApiKeyMarker: unused('resolveNonEnvSecretRefApiKeyMarker'),
      getRuntimeConfigSnapshot: unused('getRuntimeConfigSnapshot'), normalizeProviderId: unused('normalizeProviderId'),
    };
    const descriptions = {
      withTrustedWebToolsEndpoint: 'exact request from actual common module; successful synthetic Response; synthetic clock+7ms; network/policy/timers unexecuted',
      readProviderJsonObjectResponse: 'successful fixture Response.json with actual label/options recorded; production parser unexecuted',
      resolveReadOnlyEnvSecretRef: 'explicit available literal fixture string normalized by supplied normalizer; credential discovery unexecuted',
      normalizeSecretInputString: 'only explicit fixture string trim; production secret normalization unexecuted',
    };
    return this.synthetic('x-search:platform', bindings, Object.fromEntries(Object.keys(bindings).map(name => [name,
      { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service', behavior: descriptions[name] ?? 'unused; throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'x-search:platform') return this.platform();
    if (importer === common && specifier === './web-guarded-fetch.js') {
      const path = 'src/agents/tools/web-guarded-fetch.ts'; this.verifiedSource(path, false);
      link('explicit-successful-http-fixture', path); return this.platform();
    }
    if (importer === readers && specifier === './tool-results.js') {
      link('executed-whole-module', results); return this.source(results);
    }
    const deferred = unusedImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = deferred[3] ?? relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false); link('explicit-unused-import', path);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (specifier === './openclaw.plugin.json' && importer.startsWith('extensions/xai/')) {
      const path = 'extensions/xai/openclaw.plugin.json';
      const bytes = readFileSync(join(this.root, path));
      assert.deepEqual(bytes, execFileSync('git', ['show', `${BRAVE_REFERENCE_PIN}:${path}`], { cwd: this.root }));
      link('actual-pinned-json-module', path);
      return this.synthetic('x-search:manifest', { default: JSON.parse(bytes) },
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
    if (importer.startsWith('x-search:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('x-search:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts'; this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'x-search:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t'), [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path), symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: digest(bytes) };
  });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN, tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}
export function unframeXSearchText(text) {
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope'); return match[2];
}
export function portableXSearchResult(result) {
  const output = plain(result); output.content = unframeXSearchText(output.content); delete output.externalContent; return output;
}
const query = 'Find operational updates';
const url = n => `https://x.example/status/${n}`;
const block = (text, annotations = []) => ({ type: 'output_text', text, annotations });
const message = (...content) => ({ type: 'message', content });
const payload = (...content) => ({ output: [message(...content)] });
const basePayload = () => ({ ...payload(block(' Ordinary answer 😀 \n', [{ type: 'url_citation', url: url(1) }])),
  inline_citations: [{ start_index: 1, end_index: 9, url: url(1) }] });
function recipes() {
  const args = { query };
  const step = (arguments_, extra = {}) => ({ arguments: arguments_, ...extra });
  const rows = [
    { id: 'basic-default', steps: [step({ query: ` ${query} ` })] },
    { id: 'full-allowed-options', xSearch: { inlineCitations: true, maxTurns: 4.9, timeoutSeconds: 17 },
      steps: [step({ query, allowed_x_handles: [' @Alpha ', 'Beta'], from_date: ' 2024-02-29 ', to_date: '2026-10-28',
        enable_image_understanding: true, enable_video_understanding: true })] },
    { id: 'excluded-options', steps: [step({ query, excluded_x_handles: ['@Alpha', 'Beta'],
      enable_image_understanding: false, enable_video_understanding: false })] },
    { id: 'empty-optional-values', steps: [step({ query, allowed_x_handles: [], from_date: ' ', to_date: '' })] },
    { id: 'twenty-handles', steps: [step({ query, allowed_x_handles: Array.from({ length: 20 }, (_, n) => 'author' + n) })] },
    { id: 'ordered-duplicate-handles', steps: [step({ query, allowed_x_handles: ['Beta', 'Alpha', 'Beta'] })] },
    { id: 'fallback-endpoint', webSearch: { baseUrl: ' https://proxy.example/v1/// ' }, steps: [step(args)] },
    { id: 'owned-endpoint', webSearch: { baseUrl: 'https://fallback.example/v1' },
      xSearch: { baseUrl: ' https://owned.example/custom/// ' }, steps: [step(args)] },
    { id: 'repeat-cache-hit', steps: [step(args), step(args)] },
    { id: 'cache-disabled', xSearch: { cacheTtlMinutes: 0 }, steps: [step(args), step(args)] },
    { id: 'cache-expiration', xSearch: { cacheTtlMinutes: 0.001 }, steps: [step(args), step(args, { atMs: 66 }), step(args, { atMs: 67 })] },
    { id: 'cache-shortened-read', xSearch: { cacheTtlMinutes: 1 }, steps: [step(args),
      step(args, { atMs: 100, xSearch: { cacheTtlMinutes: 0.001 } }), step(args, { atMs: 120 })] },
    { id: 'cache-timeout-independent', steps: [step(args), step(args, { xSearch: { timeoutSeconds: 11 } })] },
    { id: 'cache-key-filter-order', steps: [step({ query, allowed_x_handles: ['Alpha', 'Beta'] }),
      step({ query, allowed_x_handles: ['Beta', 'Alpha'] }), step({ query, allowed_x_handles: ['Alpha', 'Beta'] })] },
    { id: 'cache-key-variants', steps: [step(args), step(args, { xSearch: { model: 'grok-4.3' } }),
      step(args, { xSearch: { baseUrl: 'https://other.example/v1' } }), step(args, { xSearch: { inlineCitations: true } }),
      step(args, { xSearch: { maxTurns: 2 } }), step({ query, enable_image_understanding: true }),
      step({ query, enable_video_understanding: true }), step({ query, from_date: '2025-01-01' }),
      step({ query, to_date: '2025-12-31' }), step({ query: query.toLowerCase() }), step(args)] },
    { id: 'cache-credential-key', steps: [step(args), step(args, { apiKey: 'fixture-x-search-second-key' }), step(args)] },
    { id: 'cache-hundred-entry-cap', steps: [
      ...Array.from({ length: 101 }, (_, n) => step({ query: query + ' ' + n })), step({ query: query + ' 0' })] },
    { id: 'adjacent-blocks', httpPayload: { output: [message(block('First '), block('Second😀')), block(' Third')] }, steps: [step(args)] },
    { id: 'output-text-fallback', httpPayload: { output_text: ' Fallback answer 😀 ' }, steps: [step(args)] },
    { id: 'message-before-fallback', httpPayload: { ...payload(block('Block answer')), output_text: 'Fallback answer' }, steps: [step(args)] },
    { id: 'direct-output-text', httpPayload: { output: [block('Direct answer')] }, steps: [step(args)] },
    { id: 'top-citation-precedence', httpPayload: { ...payload(block('Answer', [{ type: 'url_citation', url: url(2) }])),
      citations: [url(1), url(1), url(3)] }, steps: [step(args)] },
    { id: 'annotation-citation-order', httpPayload: payload(block('First', [{ type: 'url_citation', url: url(2) },
      { type: 'url_citation', url: url(2) }]), block('Second', [{ type: 'url_citation', url: url(1) }])), steps: [step(args)] },
    { id: 'citation-canonical-url', httpPayload: { ...payload(block('Canonical answer')),
      citations: ['https://X.EXAMPLE:443/path with space?q=ordinary text#section', 'https://bare.example'] }, steps: [step(args)] },
    { id: 'twenty-citations', httpPayload: { ...payload(block('Twenty source answer')),
      citations: Array.from({ length: 21 }, (_, n) => url(n)) }, steps: [step(args)] },
    { id: 'citation-thousand-scan', httpPayload: { ...payload(block('Repeated ordinary citations')),
      citations: [...Array(1_000).fill(url(1)), url(2)] }, steps: [step(args)] },
    { id: 'annotation-thousand-scan', httpPayload: payload(block('Repeated ordinary annotations',
      [...Array.from({ length: 1_000 }, () => ({ type: 'url_citation', url: url(1) })),
        { type: 'url_citation', url: url(2) }])), steps: [step(args)] },
    { id: 'inline-utf16-offsets', xSearch: { inlineCitations: true }, httpPayload: { ...payload(block('A😀BC')), inline_citations: [
      { start_index: 1, end_index: 3, url: url(1) }, { start_index: 3, end_index: 5, url: url(2) },
      { start_index: 5, end_index: 5, url: url(3) }] }, steps: [step(args)] },
    { id: 'inline-empty-array', xSearch: { inlineCitations: true }, httpPayload: { ...payload(block('Answer')), inline_citations: [] }, steps: [step(args)] },
    { id: 'inline-twenty-cap', xSearch: { inlineCitations: true }, httpPayload: { ...payload(block('Answer')),
      inline_citations: Array.from({ length: 21 }, (_, n) => ({ start_index: 0, end_index: 6, url: url(n) })) }, steps: [step(args)] },
  ];
  for (const model of ['grok-4.3', 'grok-4.3-latest', 'grok-latest', 'grok-4.5', 'grok-4.6', 'grok-4.7', 'grok-4.20',
    'grok-4-fast', 'grok-5', 'grok-4.8-0115', 'grok-code-fast-1']) rows.push({ id: 'model-' + model,
      xSearch: { model: ' ' + model + ' ' }, steps: [step(args)] });
  for (const [name, text] of [
    ['below', 'A'.repeat(19_999)], ['exact', 'A'.repeat(20_000)], ['over', 'A'.repeat(20_001)],
    ['emoji', 'A'.repeat(19_999) + '😀tail'], ['combining', 'e\u0301'.repeat(10_001)],
    ['zwj', 'A'.repeat(19_996) + '👩‍💻tail'],
  ]) rows.push({ id: 'text-' + name, httpPayload: payload(block(text)), steps: [step(args)] });
  rows.push({ id: 'contiguous-truncation', xSearch: { inlineCitations: true }, httpPayload: {
    output: [message(block('A'.repeat(19_999), [{ type: 'url_citation', url: url(1) }]),
      block('😀tail', [{ type: 'url_citation', url: url(2) }]), block('Z', [{ type: 'url_citation', url: url(3) }]))],
    inline_citations: [{ start_index: 19_998, end_index: 19_999, url: url(1) }],
  }, steps: [step(args)] });
  return rows;
}

export async function captureXSearch(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root); const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const groups = []; let typeboxVersion;
  for (const recipe of recipes()) {
    const capture = new XSearchCapture(root, recipe.httpPayload ?? basePayload());
    const module = capture.source(factory); await capture.evaluate(module);
    const steps = []; let descriptor;
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + (item.atMs ?? n * 20);
      const config = { plugins: { entries: { xai: { config: {
        webSearch: { apiKey: item.apiKey ?? 'fixture-x-search-key', ...recipe.webSearch },
        xSearch: { ...recipe.xSearch, ...item.xSearch },
      } } } } };
      const configBefore = plain(config), runtimeConfig = plain(config);
      const tool = module.namespace.createXSearchTool({ config, runtimeConfig }); assert.ok(tool);
      const currentDescriptor = { name: tool.name, label: tool.label, resultContentSource: tool.resultContentSource,
        description: tool.description, parameters: plain(tool.parameters) };
      descriptor ??= currentDescriptor; assert.deepEqual(currentDescriptor, descriptor);
      const clock = new Date(capture.nowMs).toISOString(), args = plain(item.arguments), argumentsBefore = plain(args);
      const requestCount = capture.requests.length;
      const toolResult = plain(await tool.execute(`x-search-${recipe.id}-${n}`, args));
      assert.deepEqual(args, argumentsBefore); assert.deepEqual(config, configBefore); assert.deepEqual(runtimeConfig, configBefore);
      assert.deepEqual(JSON.parse(toolResult.content[0].text), toolResult.details);
      const requests = capture.requests.slice(requestCount); assert.ok(requests.length <= 1);
      steps.push({ config: configBefore, configAfter: plain(config), arguments: argumentsBefore, argumentsAfter: plain(args), clock,
        request: requests[0] ?? null, cumulativeRequests: capture.requests.length, toolResult, result: toolResult.details,
        resultPortable: portableXSearchResult(toolResult.details) });
    }
    groups.push({ id: recipe.id, descriptor, httpPayload: capture.payload, steps, audit: capture.audit });
    typeboxVersion = capture.typeboxVersion;
    for (const [key, value] of capture.sources) sources.set(key, { ...value, executed: value.executed || sources.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  }
  const after = checkout(root); assert.deepEqual(after, before);
  return { version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-x-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'whole-module verified loader, deterministic clock and wrapper randomBytes, exact source/platform provenance' }],
    source: factory, invocation: 'actual createXSearchTool({config,runtimeConfig}) -> execute(callId, rawArguments)',
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: false,
      factoryInvoked: true, publicCallbackInvoked: true, actualJsonResult: true, actualCache: true,
      actualResponsesBuilder: true, actualResponseProjection: true, actualModelCompat: true,
      productionNetworkInvoked: false, fixtureEnvironment: {},
      portableComparison: 'separate resultPortable only strips exact single reference frame from content and deletes externalContent; all other keys remain including tookMs',
      limits: [
        '58558 tracked source blobs checked before/after; executed means whole module loaded/evaluated, not every export invoked',
        'Standalone tool factory/callback run with resolved config; plugin.register and full host assembly unexecuted',
        'Actual response request body, model normalization/compat, response projection, UTF16 helpers, wrappers and cache execute',
        'Successful HTTP and Response.json are explicit fixtures, clock advances7ms; production parser/network/policy/timers unexecuted',
        'Only available literal fixture strings use trim; production credentials, authentication, environment discovery and runtime-config IO unexecuted',
        'Unused model compat transport/attribution/schema helpers throw if invoked; actual applyModelCompatPatch runs',
        'Ordinary positive fixtures only; no security/permission/auth/TLS/negative/mixed/failure/cancel/crash-recovery/real-provider tests',
        'Reference sanitation/framing is preserved; host portable comparison deliberately removes frame/externalContent; broad WHATWG equivalence and native persistence require separate evidence',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0) },
    manifest: { path: 'extensions/xai/openclaw.plugin.json', sha256: digest(readFileSync(join(root, 'extensions/xai/openclaw.plugin.json'))),
      content: JSON.parse(readFileSync(join(root, 'extensions/xai/openclaw.plugin.json'), 'utf8')) },
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root, 'LICENSE'))), text: readFileSync(join(root, 'LICENSE'), 'utf8') },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: typeboxVersion, files: sorted(dependencies.values()) }, groups };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2); let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1]; else output = args[n + 1];
  }
  const json = JSON.stringify(await captureXSearch(root), null, 2) + '\n';
  if (output) writeFileSync(output, json); else process.stdout.write(json);
}
