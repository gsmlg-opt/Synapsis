// Ordinary successful code_execution callbacks from complete unchanged pinned modules.
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

const factory = 'extensions/xai/code-execution.ts';
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
  factory, 'extensions/xai/code-execution-tool-shared.ts', 'extensions/xai/src/code-execution-shared.ts',
  'extensions/xai/src/code-execution-config.ts', 'extensions/xai/src/tool-auth-shared.ts',
  'extensions/xai/src/tool-config-shared.ts', 'extensions/xai/src/responses-tool-shared.ts',
  'extensions/xai/src/web-search-shared.ts', 'extensions/xai/model-definitions.ts',
  'extensions/xai/model-id.ts', 'extensions/xai/runtime-model-compat.ts',
  'extensions/xai/model-compat.ts', 'extensions/xai/provider-routing.ts', 'extensions/xai/provider-id.ts',
  'src/plugins/provider-model-compat.ts', results,
  'src/plugin-sdk/plugin-config-runtime.ts', 'src/config/runtime-config-capture-state.ts',
  'src/plugins/config-state.ts', 'src/plugins/config-normalization-shared.ts',
  'src/plugins/default-enablement.ts', 'src/plugins/plugin-policy-id.ts', 'src/plugins/slots.ts',
  'src/infra/deep-merge.ts', 'src/infra/plain-object.ts', 'src/infra/prototype-keys.ts',
]);
const facades = {
  [sdk + 'global-singleton']: from(['resolveGlobalMap'], 'src/shared/global-singleton.ts'),
  [sdk + 'provider-web-search']: [
    from(['postTrustedWebToolsJson'], common),
    from(['readToolStringParam as readStringParam'], readers),
    from(['jsonResult'], results),
  ].join('\n'),
  [sdk + 'plugin-config-runtime']: from(['resolvePluginConfigObject'], 'src/plugin-sdk/plugin-config-runtime.ts'),
  [sdk + 'provider-model-shared']: from(['applyModelCompatPatch'], 'src/plugins/provider-model-compat.ts'),
  [sdk + 'string-coerce-runtime']: [
    from(['asNonArrayRecord', 'asOptionalRecord', 'asOptionalObjectRecord', 'isRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeOptionalLowercaseString'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'security-runtime']: from(['truncateSanitizedExternalContent'], external),
  [sdk + 'text-utility-runtime']: from(['truncateUtf16Safe'], normalization + 'utf16-slice.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'provider-http']: 'export {readProviderJsonObjectResponse} from "code-execution:platform";',
  [sdk + 'runtime-config-snapshot']: 'export {getRuntimeConfigSnapshot} from "code-execution:platform";',
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "code-execution:platform";',
  [sdk + 'secret-input']: 'export {coerceSecretRef,normalizeSecretInputString,readProviderEnvValue,resolveNonEnvSecretRefApiKeyMarker} from "code-execution:platform";',
  [sdk + 'model-ref-parse']: 'export {normalizeProviderId} from "code-execution:platform";',
};
const unusedImports = [
  ['src/config/runtime-config-capture-state.ts', './resolution-facts.js', ['cloneConfigWithResolutionFacts']],
  ['src/config/runtime-config-capture-state.ts', '../shared/immutable-data.js', ['freezeJsonSnapshot']],
  ['src/plugins/config-state.ts', '../shared/immutable-data.js', ['freezeJsonSnapshot']],
  ['src/plugins/config-state.ts', './config-activation-shared.js', ['resolveMemorySlotDecisionShared', 'resolvePluginActivationStateShared']],
  ['src/plugins/config-normalization-shared.ts', '../channels/ids.js', ['normalizeChatChannelId']],
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/openai-completions-compat', ['resolveOpenAICompletionsCompat'], 'packages/ai/src/internal/openai-completions-compat.ts'],
  ['src/plugins/provider-model-compat.ts', '@openclaw/ai/internal/tool-schema', ['extractToolSchemaModelCompat', 'resolveUnsupportedToolSchemaKeywords'], 'packages/ai/src/internal/tool-schema.ts'],
  ['src/plugins/provider-model-compat.ts', '../agents/model-compat-catalog.js', ['normalizeModelTransportBaseUrl']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-attribution.js', ['resolveProviderRequestCapabilities']],
  ['src/plugins/provider-model-compat.ts', '../agents/provider-request-config.js', ['getModelProviderRequestRouteFacts']],
];

class CodeExecutionCapture extends BraveCapture {
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
    const id = 'code-execution:typebox:' + relative(this.typeboxRoot, file);
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
    return this.synthetic('code-execution:platform', bindings, Object.fromEntries(Object.keys(bindings).map(name => [name,
      { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service', behavior: descriptions[name] ?? 'unused; throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'code-execution:platform') return this.platform();
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
      return this.synthetic('code-execution:manifest', { default: JSON.parse(bytes) },
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
    if (importer.startsWith('code-execution:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('code-execution:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts'; this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'code-execution:facade:' + specifier;
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
const task = 'Calculate totals for the supplied data';
const url = n => `https://analysis.example/source/${n}`;
const block = (text, annotations = []) => ({ type: 'output_text', text, annotations });
const message = (...content) => ({ type: 'message', content });
const interpreter = () => ({ type: 'code_interpreter_call', id: 'fixture-python-call', status: 'completed' });
const payload = (...content) => ({ output: [interpreter(), message(...content)] });
const basePayload = () => payload(block(' Ordinary analysis 😀 \n', [{ type: 'url_citation', url: url(1) }]));
function recipes() {
  const step = (arguments_, extra = {}) => ({ arguments: arguments_, ...extra });
  const args = { task };
  const rows = [
    { id: 'basic-default', steps: [step({ task: ` ${task} ` })] },
    { id: 'full-config', codeExecution: { maxTurns: 4.9, timeoutSeconds: 17.5 }, steps: [step(args)] },
    { id: 'same-task-no-cache', steps: [step(args), step(args), step(args)] },
    { id: 'web-base-does-not-select-endpoint', webSearch: { baseUrl: 'https://proxy.example/v1' }, steps: [step(args)] },
    { id: 'runtime-config-precedence', codeExecution: { model: 'grok-4.7', maxTurns: 7 },
      runtimeCodeExecution: { model: 'grok-4.3', maxTurns: 2, timeoutSeconds: 11 }, steps: [step(args)] },
    { id: 'source-config-fallback', codeExecution: { model: 'grok-4.3', maxTurns: 3, timeoutSeconds: 19 },
      runtimeCodeExecution: null, steps: [step(args)] },
    { id: 'ordinary-data-task', steps: [step({ task: '  Total this CSV:\nitem,value\nalpha,12\nbeta,30\n  ' })] },
    { id: 'adjacent-blocks', httpPayload: { output: [interpreter(), message(block('First '), block('Second😀')), block(' Third')] }, steps: [step(args)] },
    { id: 'direct-output-text', httpPayload: { output: [block('Direct answer')] }, steps: [step(args)] },
    { id: 'output-text-fallback', httpPayload: { output_text: ' Fallback answer 😀 ' }, steps: [step(args)] },
    { id: 'message-before-fallback', httpPayload: { ...payload(block('Block answer')), output_text: 'Fallback answer' }, steps: [step(args)] },
    { id: 'whitespace-answer', httpPayload: { output_text: ' \t\n ' }, steps: [step(args)] },
    { id: 'top-citation-precedence', httpPayload: { ...payload(block('Answer', [{ type: 'url_citation', url: url(2) }])), citations: [url(1), url(1), url(3)] }, steps: [step(args)] },
    { id: 'annotation-citation-order', httpPayload: payload(block('First', [{ type: 'url_citation', url: url(2) }, { type: 'url_citation', url: url(2) }]), block('Second', [{ type: 'url_citation', url: url(1) }])), steps: [step(args)] },
    { id: 'citation-canonical-url', httpPayload: { ...payload(block('Canonical answer')), citations: ['https://ANALYSIS.example:443/path with space?q=ordinary text#part', 'https://bare.example'] }, steps: [step(args)] },
    { id: 'twenty-citations', httpPayload: { ...payload(block('Twenty citations')), citations: Array.from({ length: 21 }, (_, n) => url(n)) }, steps: [step(args)] },
    { id: 'citation-thousand-scan', httpPayload: { ...payload(block('Repeated citations')), citations: [...Array(1_000).fill(url(1)), url(2)] }, steps: [step(args)] },
    { id: 'annotation-thousand-scan', httpPayload: payload(block('Repeated annotations', [...Array.from({ length: 1_000 }, () => ({ type: 'url_citation', url: url(1) })), { type: 'url_citation', url: url(2) }])), steps: [step(args)] },
    { id: 'citation-exact-url-budget', httpPayload: { ...payload(block('Long source URL')), citations: ['https://analysis.example/' + 'a'.repeat(2_048 - 'https://analysis.example/'.length)] }, steps: [step(args)] },
    { id: 'ordered-output-types', httpPayload: { output: [{ type: 'reasoning' }, interpreter(), message(block('Analysis complete')), interpreter(), { type: 'reasoning' }, message(block('.'))] }, steps: [step(args)] },
    { id: 'message-output-type', httpPayload: { output: [message(block('Analysis without an interpreter call'))] }, steps: [step(args)] },
    { id: 'inline-input-not-public-output', httpPayload: { ...payload(block('Analysis')), inline_citations: [{ url: url(1), start_index: 0, end_index: 8 }] }, steps: [step(args)] },
    { id: 'long-ascii-no-cap', httpPayload: payload(block('A'.repeat(25_001))), steps: [step(args)] },
    { id: 'long-unicode-fallback-no-cap', httpPayload: { output_text: '😀'.repeat(10_001) + 'e\u0301👩‍💻' }, steps: [step(args)] },
    { id: 'long-adjacent-no-cap', httpPayload: payload(block('A'.repeat(12_000)), block('B'.repeat(12_001), [{ type: 'url_citation', url: url(7) }])), steps: [step(args)] },
  ];
  for (const model of ['grok-4.3', 'grok-4.3-latest', 'grok-latest', 'grok-4.5', 'grok-4.5-latest', 'grok-4.6', 'grok-4.7', 'grok-4.7-latest', 'grok-4.20', 'grok-4-fast', 'grok-5', 'grok-4.8-0115', 'grok-code-fast-1', 'grok-build-latest', 'grok-4-fast-reasoning']) {
    rows.push({ id: 'model-' + model, codeExecution: { model: ' ' + model + ' ' }, steps: [step(args)] });
  }
  return rows;
}
export async function captureCodeExecution(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root); const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const groups = []; let typeboxVersion;
  for (const recipe of recipes()) {
    const capture = new CodeExecutionCapture(root, recipe.httpPayload ?? basePayload());
    const module = capture.source(factory); await capture.evaluate(module);
    const steps = []; let descriptor;
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const config = { plugins: { entries: { xai: { config: {
        webSearch: { apiKey: 'fixture-code-execution-key', ...recipe.webSearch },
        codeExecution: { ...recipe.codeExecution },
      } } } } };
      const configBefore = plain(config), runtimeConfig = plain(config);
      if (recipe.runtimeCodeExecution === null) delete runtimeConfig.plugins.entries.xai.config.codeExecution;
      else if (recipe.runtimeCodeExecution) runtimeConfig.plugins.entries.xai.config.codeExecution = plain(recipe.runtimeCodeExecution);
      const runtimeBefore = plain(runtimeConfig);
      const tool = module.namespace.createCodeExecutionTool({ config, runtimeConfig }); assert.ok(tool);
      const currentDescriptor = { name: tool.name, label: tool.label, description: tool.description, parameters: plain(tool.parameters) };
      descriptor ??= currentDescriptor; assert.deepEqual(currentDescriptor, descriptor);
      const clock = new Date(capture.nowMs).toISOString(), args = plain(item.arguments), argumentsBefore = plain(args);
      const requestCount = capture.requests.length;
      const toolResult = plain(await tool.execute(`code-execution-${recipe.id}-${n}`, args));
      assert.deepEqual(args, argumentsBefore); assert.deepEqual(config, configBefore); assert.deepEqual(runtimeConfig, runtimeBefore);
      assert.deepEqual(JSON.parse(toolResult.content[0].text), toolResult.details);
      const requests = capture.requests.slice(requestCount); assert.equal(requests.length, 1);
      steps.push({ config: configBefore, configAfter: plain(config), runtimeConfig: runtimeBefore, runtimeConfigAfter: plain(runtimeConfig),
        arguments: argumentsBefore, argumentsAfter: plain(args), clock, request: requests[0], cumulativeRequests: capture.requests.length,
        toolResult, result: toolResult.details, resultPortable: plain(toolResult.details) });
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
    harness: { path: 'scripts/openclaw/capture-code-execution.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs', sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'verified whole-module loader, deterministic clock, exact source/platform provenance; no body projections' }],
    source: factory, invocation: 'actual createCodeExecutionTool({config,runtimeConfig}) -> execute(callId, rawArguments)',
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: false, factoryInvoked: true,
      publicCallbackInvoked: true, actualJsonResult: true, noCache: true, actualResponsesBuilder: true, actualResponseProjection: true,
      actualModelCompat: true, actualPluginConfigNormalization: true, productionNetworkInvoked: false, fixtureEnvironment: {},
      portableComparison: 'resultPortable is an identity JSON clone of full source details; code_execution adds no frame, stamp, inline citations or text cap',
      limits: [
        '58558 tracked source blobs checked before/after; executed means complete module evaluated, not every export invoked',
        'Standalone factory/callback with ordinary resolved source/runtime configs; plugin.register/full host assembly unexecuted',
        'Actual request body/model normalization/compat/response projection/plugin config normalization execute',
        'Successful HTTP and Response.json are explicit fixtures; synthetic clock advances7ms; production bounded parser/network/policy/timers unexecuted',
        'Available literal fixture string uses trim; production credentials/authentication/environment discovery/runtime-config IO unexecuted',
        'Unused model compat transport/attribution/schema, plugin activation/channel lookup, capture publication/clone/freezing imports throw if invoked',
        'No security/permission/auth/TLS/negative/mixed/failure/cancel/crash-recovery/real-provider tests',
        'No local Python execution; response output types are fixture provider reports, not proof of real remote execution',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length, provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0) },
    manifest: { path: 'extensions/xai/openclaw.plugin.json', sha256: digest(readFileSync(join(root, 'extensions/xai/openclaw.plugin.json'))), content: JSON.parse(readFileSync(join(root, 'extensions/xai/openclaw.plugin.json'), 'utf8')) },
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root, 'LICENSE'))), text: readFileSync(join(root, 'LICENSE'), 'utf8') },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: typeboxVersion, files: sorted(dependencies.values()) }, groups };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2); let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1]; else output = args[n + 1];
  }
  const json = JSON.stringify(await captureCodeExecution(root), null, 2) + '\n';
  if (output) writeFileSync(output, json); else process.stdout.write(json);
}
