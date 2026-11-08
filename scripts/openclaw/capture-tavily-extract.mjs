// Ordinary extraction callbacks from complete unchanged pinned OpenClaw modules.
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
  index, client, results, 'extensions/tavily/src/config.ts',
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
  [sdk + 'provider-http']: 'export {readProviderJsonResponse} from "extract:platform";',
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-input-runtime']: 'export {assertPluginCapabilitySecretAvailable} from "extract:platform";',
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "extract:platform";',
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

class ExtractCapture extends BraveCapture {
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
    const id = 'extract:typebox:' + relative(this.typeboxRoot, file);
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
    return this.synthetic('extract:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: 'ordinary-platform-fixture', behavior: descriptions[name] }])));
  }

  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'extract:platform') return this.platform();
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
    if (importer.startsWith('extract:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot,
        dirname(importer.slice('extract:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk)
        ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier];
      const id = 'extract:facade:' + specifier;
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
  return { verified: true, commit: BRAVE_REFERENCE_PIN,
    tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}

// Exact single envelope removal; never trim extraction prose or image values.
export function unframeExtractText(text) {
  if (text === '') return text;
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Fetch\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Fetch envelope');
  return match[2];
}
function unframeResult(result) {
  return { ...plain(result), results: result.results.map(row => ({ ...row,
    rawContent: unframeExtractText(row.rawContent),
    ...(typeof row.content === 'string' ? { content: unframeExtractText(row.content) } : {}),
    ...(row.images ? { images: row.images.map(unframeExtractText) } : {}),
  })) };
}

const one = 'https://source.example/one';
const two = 'https://source.example/two';
const img = n => `https://images.example/${n}.png`;
const payload = rows => ({ results: rows, response_time: 0.125, request_id: 'fixture-request', usage: { credits: 1 } });
const simplePayload = () => payload([{ url: one, raw_content: ' Ordinary passage 😀 \n',
  title: 'vendor title omitted', score: 0.9, vendor_field: 'omitted' }]);
const step = (args, elapsedMs = 0, configPatch) => ({ arguments: args, elapsedMs,
  ...(configPatch ? { configPatch } : {}) });

function recipes() {
  const args = { urls: [one] };
  const rows = [
    { id: 'basic-default', steps: [step({ urls: [` ${one} `] })] },
    { id: 'basic-proxy', baseUrl: ' https://extract.example/proxy/ ', steps: [step(args)] },
    { id: 'ordered-options', steps: [step({ urls: [` ${two} `, one, two], query: ' focused query ',
      extract_depth: 'advanced', chunks_per_source: 5, include_images: true })],
    httpPayload: payload([
      { url: two, raw_content: ' Second raw ', content: ' Second content ', images: [img(2), img(1)] },
      { url: one, raw_content: ' First raw ', content: '', images: [] },
      { url: two, raw_content: ' Duplicate raw ' },
    ]) },
    { id: 'empty-content', steps: [step(args)], httpPayload: payload([
      { url: one, raw_content: '', content: '', images: [] }, { url: two },
    ]) },
    { id: 'url-canonicalization', steps: [step(args)], httpPayload: payload([
      { url: 'https://SOURCE.EXAMPLE:443/ordinary?q=hello%20world', raw_content: 'Canonical' },
      { url: 'https://bare.example', raw_content: 'Bare host' },
    ]) },
  ];
  for (const count of [20, 21]) rows.push({ id: `results-${count}`, steps: [step(args)],
    httpPayload: payload(Array.from({ length: count }, (_, n) => ({ url: `https://source.example/${n + 1}`, raw_content: `Row ${n + 1}` }))) });
  for (const count of [20, 21]) rows.push({ id: `images-shared-${count}`, steps: [step({ ...args, include_images: true })],
    httpPayload: payload([
      { url: one, raw_content: 'One', images: Array.from({ length: 12 }, (_, n) => img(n + 1)) },
      { url: two, raw_content: 'Two', images: Array.from({ length: count - 12 }, (_, n) => img(n + 13)) },
    ]) });
  rows.push({ id: 'unicode-whitespace', steps: [step(args)], httpPayload: payload([
    { url: one, raw_content: ' \t界😀e\u0301 👩‍💻 \n', content: '\n Content 😀 \t' },
  ]) });
  for (const extra of ['', 'overflow']) rows.push({ id: `budget-shared-${extra || 'exact'}`, steps: [step(args)],
    httpPayload: payload([
      { url: one, raw_content: 'A'.repeat(12_000), content: 'B'.repeat(7_999) },
      { url: two, raw_content: 'C' + extra, content: '' },
    ]) });
  for (const [name, raw, content] of [
    ['emoji', '😀'.repeat(10_001), 'later'],
    ['emoji-leftover', '界'.repeat(19_999) + '😀tail', 'Zlater'],
    ['combining', 'e\u0301'.repeat(10_000) + 'A', 'later'],
    ['zwj', 'x'.repeat(19_996) + '👩‍💻', 'Qlater'],
  ]) rows.push({ id: `unicode-${name}`, steps: [step(args)],
    httpPayload: payload([{ url: one, raw_content: raw, content }, { url: two, raw_content: 'later' }]) });
  rows.push({ id: 'cache-options', steps: [
    step(args), step({ urls: [` ${one} `], include_images: false }, 20),
    step({ ...args, query: ' focused ' }, 40), step({ ...args, query: 'focused' }, 60),
    step({ ...args, query: 'focused', extract_depth: 'basic' }, 80),
    step({ ...args, query: 'focused', extract_depth: 'advanced' }, 100),
    step({ ...args, query: 'focused', extract_depth: 'advanced', chunks_per_source: 1 }, 120),
    step({ ...args, query: 'focused', extract_depth: 'advanced', chunks_per_source: 5 }, 140),
    step({ ...args, query: 'focused', extract_depth: 'advanced', chunks_per_source: 5, include_images: true }, 160),
    step(args, 180),
  ] });
  rows.push({ id: 'cache-url-order', steps: [step({ urls: [one, two, one] }),
    step({ urls: [two, one, one] }, 20), step({ urls: [one, two, one] }, 40)] });
  rows.push({ id: 'cache-expiry-search-ttl-zero', searchConfig: { cacheTtlMinutes: 0 }, steps: [
    step(args), step(args, 20), step(args, 900_006), step(args, 900_007), step(args, 900_027),
  ] });
  return rows;
}

export async function captureTavilyExtract(root = '/tmp/openclaw-488631c') {
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
  const groups = [];
  let typeboxVersion;
  for (const recipe of recipes()) {
    const capture = new ExtractCapture(root, recipe.httpPayload ?? simplePayload());
    const module = capture.source(index);
    await capture.evaluate(module);
    let config = { plugins: { entries: { tavily: { config: { webSearch: {
      apiKey: 'fixture-tavily-key', ...(recipe.baseUrl ? { baseUrl: recipe.baseUrl } : {}),
    } } } } }, tools: { web: { search: recipe.searchConfig ?? {} } } };
    const configBefore = plain(config);
    const registered = [], providers = [];
    module.namespace.default.register({ config,
      registerWebSearchProvider: provider => providers.push({ id: provider.id, label: provider.label }),
      registerTool: (factory, options) => registered.push({ factory, options: plain(options) }),
    });
    const registration = { pluginId: module.namespace.default.id, providers,
      tools: registered.map(row => row.options),
      boundary: 'actual plugin.register on explicit API fixture; full host registry and assembly unexecuted' };
    const selected = registered.find(row => row.options.name === 'tavily_extract');
    assert.ok(selected);
    const tool = selected.factory({ getRuntimeConfig: () => config });
    const descriptor = { name: tool.name, label: tool.label, resultContentSource: tool.resultContentSource,
      description: tool.description, parameters: plain(tool.parameters) };
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + item.elapsedMs;
      if (item.configPatch) config = { ...config, ...item.configPatch };
      const args = plain(item.arguments), argumentsBefore = plain(args), requestCount = capture.requests.length;
      const toolResult = plain(await tool.execute(`extract-${recipe.id}-${n}`, args));
      assert.deepEqual(args, argumentsBefore);
      assert.deepEqual(JSON.parse(toolResult.content[0].text), toolResult.details);
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      steps.push({ arguments: argumentsBefore, argumentsAfter: plain(args),
        clock: new Date(originMs + item.elapsedMs).toISOString(), request: requests[0] ?? null,
        cached: toolResult.details.cached === true, cumulativeRequests: capture.requests.length,
        toolResult, result: toolResult.details, resultUnframed: unframeResult(toolResult.details) });
    }
    assert.deepEqual(config, configBefore);
    groups.push({ id: recipe.id, config: configBefore, configAfter: plain(config), registration,
      descriptor, httpPayload: capture.payload, steps, audit: capture.audit });
    typeboxVersion = capture.typeboxVersion;
    merge(capture);
  }
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-tavily-extract.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'complete-module pin-verified loader, source/platform provenance and deterministic randomBytes wrapper markers' }],
    source: index, invocation: 'defaultPlugin.register(apiFixture) -> registered tavily_extract factory(ctx) -> execute(callId, rawArguments)',
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: true,
      factoryInvoked: true, publicCallbackInvoked: true, actualJsonResult: true,
      actualExtractCache: true, actualCommonPost: true, genericNormalizerInvoked: false,
      productionNetworkInvoked: false, fixtureEnvironment: {},
      unwrap: 'exact single Web Fetch frame removal from rawContent/content/images; no trim; all keys, metadata and tookMs retained',
      limits: [
        'Tracked source tree blobs verified before and after; source entries distinguish loaded execution from provenance only',
        'Plugin registration runs against a minimal explicit API fixture; host registry/eligibility/assembly unexecuted',
        'definePluginEntry executes with real lazy-value helper; unused lazy empty config schema and unrelated services throw if invoked',
        'Actual common request/headers/serialization/success branch execute; trusted endpoint callback and Response.json parser are fixtures',
        'Literal fixture secret availability and resolution only; no environment, credential discovery or production configuration writes',
        'Synthetic clock advances 7ms per HTTP; timeout/maxBytes are recorded parameters, timer and bounded parser execution unverified',
        'Only ordinary successful local inputs; no negative/error/permission/auth/TLS/security/real-provider/failure/cancel/crash-recovery tests',
        'Worker persistence/replay and host implementation equivalence belong to independent host acceptance',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0) },
    manifest: { path: 'extensions/tavily/openclaw.plugin.json',
      sha256: digest(readFileSync(join(root, 'extensions/tavily/openclaw.plugin.json'))),
      content: JSON.parse(readFileSync(join(root, 'extensions/tavily/openclaw.plugin.json'), 'utf8')) },
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root, 'LICENSE'))),
      text: readFileSync(join(root, 'LICENSE'), 'utf8') },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1];
    else output = args[n + 1];
  }
  const captured = await captureTavilyExtract(root);
  const json = JSON.stringify(captured, null, 2) + '\n';
  if (output) writeFileSync(output, json);
  else process.stdout.write(json);
}
