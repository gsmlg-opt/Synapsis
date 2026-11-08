// Ordinary successful scrape callbacks from whole unchanged pinned OpenClaw modules.
// Successful HTTP, parser, literal config and clock boundaries are explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { isProxy } from 'node:util/types';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const index = 'extensions/firecrawl/index.ts';
const client = 'extensions/firecrawl/src/firecrawl-client.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const results = 'src/agents/tools/tool-results.ts';
const external = 'src/security/external-content.ts';
const markdown = 'src/agents/tools/web-fetch-utils.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const additionalSources = new Set([
  index, client, results, markdown,
  'extensions/firecrawl/src/firecrawl-fetch-provider.ts',
  'extensions/firecrawl/src/firecrawl-fetch-provider-shared.ts',
  'extensions/firecrawl/src/firecrawl-search-provider.ts',
  'src/agents/schema/string-enum.ts', 'src/plugin-sdk/plugin-entry.ts', 'src/plugin-sdk/lazy-value.ts',
  'src/plugin-sdk/provider-web-search-contract.ts', 'src/plugin-sdk/provider-enable-config.ts',
  'src/config/plugins-allowlist.ts', 'src/utils/boolean.ts', 'src/plugins/capability-provider.types.ts',
  'src/plugin-sdk/plugin-config-runtime.ts', 'src/config/runtime-config-capture-state.ts',
  'src/plugins/config-state.ts', 'src/plugins/config-activation-shared.ts',
  'src/plugins/config-normalization-shared.ts', 'src/plugins/plugin-policy-id.ts',
  'src/plugins/slots.ts', 'src/plugins/default-enablement.ts', 'src/shared/immutable-data.ts',
  'src/infra/deep-merge.ts', 'src/infra/plain-object.ts', 'src/infra/prototype-keys.ts',
]);
const facades = {
  [sdk + 'channel-actions']: from(['optionalStringEnum'], 'src/agents/schema/string-enum.ts'),
  [sdk + 'plugin-entry']: from(['definePluginEntry'], 'src/plugin-sdk/plugin-entry.ts'),
  [sdk + 'param-readers']: from(['readPositiveIntegerParam'], readers),
  [sdk + 'provider-web-fetch-contract']: from(['enablePluginInConfig'], 'src/plugin-sdk/provider-enable-config.ts'),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields', 'enablePluginInConfig',
    'WEB_SEARCH_QUERY_COUNT_PROPERTIES'], 'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'collection-input-runtime']: from(['ensureRecord'], normalization + 'record-coerce.ts'),
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'readCachedSearchPayload', 'resolveSearchCacheTtlMs',
      'resolveSiteName', 'writeCachedSearchPayload'], common),
    from(['readNonNegativeIntegerParam', 'readPositiveIntegerParam', 'readStringArrayParam',
      'readToolStringParam as readStringParam'], readers),
    from(['jsonResult'], results),
  ].join('\n'),
  [sdk + 'provider-web-fetch']: [from(['markdownToText'], markdown),
    from(['resolvePositiveTimeoutSeconds'], 'src/agents/tools/web-shared.ts'),
    'export {readResponseText,withSelfHostedWebToolsEndpoint,withStrictWebToolsEndpoint} from "scrape:platform";',
  ].join('\n'),
  [sdk + 'number-runtime']: from(['asNonNegativeFiniteNumber', 'asPositiveFiniteNumber',
    'parseDateStringTimestampMs', 'parseFiniteNumber', 'resolveIntegerOption'], normalization + 'number-coercion.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'plugin-config-runtime']: from(['resolvePluginConfigObject'], 'src/plugin-sdk/plugin-config-runtime.ts'),
  [sdk + 'provider-http']: 'export {ProviderHttpError,readProviderJsonObjectResponse} from "scrape:platform";',
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "scrape:platform";',
  [sdk + 'ssrf-runtime']: 'export {SsrFBlockedError,isBlockedHostnameOrIp,isPrivateIpAddress,resolvePinnedHostnameWithPolicy} from "scrape:platform";',
  [sdk + 'security-runtime']: from(['truncateSanitizedExternalContent', 'wrapExternalContent', 'wrapWebContent'], external),
  [sdk + 'string-coerce-runtime']: [
    from(['asRecord', 'asOptionalObjectRecord', 'asOptionalRecord', 'readStringField'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString'], normalization + 'string-coerce.ts'),
    from(['asBoolean'], 'src/utils/boolean.ts'),
  ].join('\n'),
  '@openclaw/normalization-core': [from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts')].join('\n'),
};
const unusedImports = [
  [markdown, '../../../packages/markdown-core/src/html-scanner.js', ['RAW_TEXT_TAGS', 'readRawTextOpenTagName',
    'findRawTextOpenTagStart', 'startsLikeHtmlTag', 'readTagToken', 'readRawTextBounds', 'skipRawTextElement']],
  [markdown, '../../infra/unicode-visibility.js', ['stripInvisibleUnicode']],
  [markdown, '../../shared/html-entities.js', ['decodeHtmlEntities']],
  [markdown, './web-fetch-attributes.js', ['readHtmlAttribute']],
  [markdown, './web-fetch-visibility.js', ['sanitizeHtml']],
  ['src/plugin-sdk/plugin-entry.ts', '../plugins/config-schema.js', ['buildJsonPluginConfigSchema', 'buildPluginConfigSchema', 'emptyPluginConfigSchema']],
  ['src/config/runtime-config-capture-state.ts', './resolution-facts.js', ['cloneConfigWithResolutionFacts']],
  ['src/plugins/config-normalization-shared.ts', '../channels/ids.js', ['normalizeChatChannelId']],
];

class ScrapeCapture extends BraveCapture {
  constructor(root, payload) {
    super(root);
    this.payload = payload;
    this.dependencies = new Map();
    this.generatedFacades = new Map();
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
    const id = 'scrape:typebox:' + relative(this.typeboxRoot, file);
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
    const unused = name => () => { record('unused-service-invoked', { export: name }); throw Error('Unused: ' + name); };
    const endpoint = async (params, run) => {
      record('successful-http-fixture', { timeoutSeconds: params.timeoutSeconds });
      const url = new URL(params.url);
      this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
        query: Object.fromEntries(url.searchParams), body: JSON.parse(params.init.body), bodyText: params.init.body,
        headers: plain(params.init.headers), timeoutSeconds: params.timeoutSeconds });
      this.nowMs += 7;
      return run({ response: Response.json(plain(this.payload)) });
    };
    const bindings = {
      withSelfHostedWebToolsEndpoint: endpoint,
      withStrictWebToolsEndpoint: endpoint,
      readProviderJsonObjectResponse: async (response, errorLabel, options) => {
        record('successful-json-fixture', { errorLabel, options: plain(options ?? {}) });
        return response.json();
      },
      resolveReadOnlyEnvSecretRef: ({ value, normalizeValue }) => {
        record('literal-fixture-string-resolution', { valueKind: typeof value });
        assert.equal(typeof value, 'string');
        return { status: 'available', value: normalizeValue(value) };
      },
      isBlockedHostnameOrIp: hostname => {
        record('fixed-public-fixture-host', { hostname });
        return false;
      },
      isPrivateIpAddress: unused('isPrivateIpAddress'),
      resolvePinnedHostnameWithPolicy: unused('resolvePinnedHostnameWithPolicy'),
      readResponseText: unused('readResponseText'),
      ProviderHttpError: unused('ProviderHttpError'),
      SsrFBlockedError: unused('SsrFBlockedError'),
    };
    const descriptions = {
      withSelfHostedWebToolsEndpoint: 'unused self-hosted endpoint callback; production transport unexecuted',
      withStrictWebToolsEndpoint: 'records exact request built by whole client; synthetic successful Response and clock +7ms; production network/policy/timers unexecuted',
      readProviderJsonObjectResponse: 'records actual errorLabel/maxBytes; successful fixture Response.json; bounded production parser unexecuted',
      resolveReadOnlyEnvSecretRef: 'explicit available literal fixture string normalized by actual normalizeValue; secret discovery unexecuted',
      isBlockedHostnameOrIp: 'fixed false for known ordinary public fixture hosts; production policy unexecuted',
    };
    return this.synthetic('scrape:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service',
        behavior: descriptions[name] ?? 'unused; throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'scrape:platform') return this.platform();
    if (specifier === 'node:util/types') {
      link('native-platform', specifier);
      return this.synthetic(specifier, { isProxy }, { isProxy: { kind: 'native-platform', behavior: 'actual node:util/types:isProxy' } });
    }
    const deferred = unusedImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false);
      link('explicit-unused-import', path);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (importer === readers && specifier === './tool-results.js') {
      link('executed-whole-module', results);
      return this.source(results);
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve('typebox'));
      let root = dirname(file);
      while (!existsSync(join(root, 'package.json'))) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json'));
      const pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox'); assert.equal(pkg.version, '1.3.37');
      this.typeboxRoot = root; this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file));
      return this.typeboxModule(file);
    }
    if (importer.startsWith('scrape:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('scrape:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk) ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'scrape:facade:' + specifier;
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
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN,
    tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}

// Only the exact pinned single envelope is removed; prose is never trimmed.
export function unframeScrapeText(text) {
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Fetch\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Fetch envelope');
  return match[2];
}
export function unframeScrapeResult(result) {
  const output = plain(result);
  for (const key of ['text', 'title', 'warning']) if (key in output) output[key] = unframeScrapeText(output[key]);
  return output;
}
// Comparison changes only reference externalContent and framing-dependent length.
// rawLength and every other result key survive, including unexpected fields.
export function portableScrapeResult(resultUnframed) {
  const output = plain(resultUnframed);
  delete output.externalContent;
  output.length = output.text.length;
  return output;
}
const url = 'https://source.example/article';
const simplePayload = () => ({ success: true, data: {
  markdown: ' Ordinary passage 😀 \n', metadata: { title: 'Page title', sourceURL: url, statusCode: 200 },
}, warning: 'Provider notice', vendor_field: 'not projected' });
const payload = (text, metadata = {}, extra = {}) => ({ success: true, data: { markdown: text, metadata }, ...extra });
const step = args => ({ arguments: args });
function recipes() {
  const args = { url };
  const rows = [
    { id: 'basic-default', steps: [step({ url: ` ${url} ` })] },
    { id: 'endpoint-replacement', pluginConfig: { webSearch: { baseUrl: ' https://api.firecrawl.dev/proxy/nested?ordinary=1#fragment ' } }, steps: [step(args)] },
    { id: 'configured-defaults', pluginConfig: { webFetch: { onlyMainContent: false, maxAgeMs: 0, timeoutSeconds: 17 } }, steps: [step(args)] },
    { id: 'full-options-false-zero', pluginConfig: { webFetch: { onlyMainContent: true, maxAgeMs: 99, timeoutSeconds: 17 } },
      steps: [step({ url, extractMode: ' text ', maxChars: 100, onlyMainContent: false,
        maxAgeMs: 0, proxy: ' stealth ', storeInCache: false, timeoutSeconds: 3 })] },
    { id: 'full-options-true', pluginConfig: { webFetch: { onlyMainContent: false, maxAgeMs: 0, timeoutSeconds: 17 } },
      steps: [step({ url, extractMode: 'markdown', maxChars: 200, onlyMainContent: true,
        maxAgeMs: 12_345, proxy: 'basic', storeInCache: true, timeoutSeconds: 9 })] },
    { id: 'repeat-no-local-cache', steps: [step(args), step(args), step(args)] },
    { id: 'text-ascii-ordered-prefix', steps: [step({ url, extractMode: 'text' })],
      httpPayload: payload('١. Arabic\n１. Fullwidth\n1. ASCII\n١٢. Kept') },
    { id: 'unicode-whitespace', steps: [step(args)], httpPayload: payload(' \t界😀e\u0301 👩‍💻 \n',
      { title: ' \t標題😀 \n' }, { warning: '\n Notice 😀 \t' }) },
    { id: 'fallback-content', steps: [step(args)], httpPayload: { success: true,
      data: { markdown: '', content: ' Fallback content 😀 \n', statusCode: '202.8', url: 'https://FALLBACK.EXAMPLE:443/path with space' } } },
    { id: 'direct-factory-scientific-numbers', steps: [step({ url, maxChars: '1.e2', timeoutSeconds: '3.e0' })],
      httpPayload: payload('N'.repeat(101), { statusCode: '2.e2' }) },
    { id: 'status-metadata-precedence', steps: [step(args)], httpPayload: { success: true,
      data: { markdown: 'Status body', statusCode: 204, metadata: { statusCode: ' 201.9 ' } } } },
    { id: 'status-absent-url-input', steps: [step(args)], httpPayload: payload('Absent metadata') },
    { id: 'canonical-source-url', steps: [step(args)], httpPayload: payload('Canonical URL',
      { sourceURL: 'https://SOURCE.EXAMPLE:443/ordinary path?q=hello world#section' }) },
    { id: 'bare-origin-source-url', steps: [step(args)], httpPayload: payload('Bare URL', { sourceURL: 'https://bare.example' }) },
  ];
  const prose = '# Heading\n\nA [linked page](https://links.example/page) and `inline code`.\n\n- first\n* second\n+ third\n1. fourth\n\n![diagram](https://images.example/a.png)\nEnd.\n';
  const texts = {
    prose,
    'fenced-code': 'Before\n```js\n# literal heading\n- literal list\n[code](https://code.example) `kept`\n```\nAfter',
    'adjacent-fences': '```a\nfirst\n``````b\nsecond\n```\nAfter',
    'unclosed-fence': 'Before\n```js\n# literal heading\n- literal list\n',
    'unclosed-inline-fence': 'Before ```inline ordinary prose',
    'line-boundaries': 'Start\r# CR heading\r- CR unordered\r1. CR ordered\u2028## LS heading\u2028* LS unordered\u20282. LS ordered\u2029### PS heading\u2029+ PS unordered\u20293. PS ordered\nEnd',
    'whitespace': ' \tHeading  text \r\n\r\n\r\n  Next\tline \n ',
  };
  for (const [name, text] of Object.entries(texts)) for (const extractMode of ['markdown', 'text']) {
    rows.push({ id: `${extractMode}-${name}`, steps: [step({ url, extractMode })], httpPayload: payload(text) });
  }
  for (const [name, text, options, fetchConfig] of [
    ['default-full', 'A'.repeat(49_999), {}, {}],
    ['default-exact', 'A'.repeat(50_000), {}, {}],
    ['default-overflow', 'A'.repeat(50_001), {}, {}],
    ['raised-cap-default', 'D'.repeat(50_001), {}, { maxCharsCap: 60_000 }],
    ['raised-both', 'D'.repeat(50_001), { maxChars: 60_000 }, { maxCharsCap: 60_000 }],
    ['explicit-default-cap', 'A'.repeat(50_001), { maxChars: 60_000 }, {}],
    ['lower-cap', 'B'.repeat(201), { maxChars: 500 }, { maxCharsCap: 200 }],
    ['explicit-lower', 'C'.repeat(201), { maxChars: 100 }, { maxCharsCap: 200 }],
    ['emoji', '😀'.repeat(51), { maxChars: 101 }, {}],
    ['combining', 'e\u0301'.repeat(51), { maxChars: 101 }, {}],
    ['zwj', 'x'.repeat(97) + '👩‍💻tail', { maxChars: 101 }, {}],
  ]) rows.push({ id: `body-${name}`, fetchConfig, steps: [step({ url, ...options })], httpPayload: payload(text) });
  for (const [name, title, warning] of [
    ['full', 'T'.repeat(2_000), 'W'.repeat(1_999)],
    ['exact', 'T'.repeat(2_500), 'W'.repeat(1_500)],
    ['overflow', 'T'.repeat(2_500), 'W'.repeat(1_501)],
    ['title-overflow', 'T'.repeat(4_001), 'later'],
    ['emoji', '😀'.repeat(2_001), 'later'],
    ['emoji-leftover', '界'.repeat(3_999) + '😀tail', 'Zlater'],
    ['combining', 'e\u0301'.repeat(2_001), 'later'],
    ['zwj', 'x'.repeat(3_996) + '👩‍💻', 'Qlater'],
  ]) rows.push({ id: `metadata-${name}`, steps: [step(args)], httpPayload: payload('Body', { title }, { warning }) });
  return rows;
}

export async function captureFirecrawlScrape(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root);
  const before = checkout(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const groups = [];
  let typeboxVersion;
  for (const recipe of recipes()) {
    const capture = new ScrapeCapture(root, recipe.httpPayload ?? simplePayload());
    const module = capture.source(index);
    await capture.evaluate(module);
    const config = { plugins: { entries: { firecrawl: { config: {
      ...recipe.pluginConfig,
      webFetch: { apiKey: 'fixture-firecrawl-key', ...recipe.pluginConfig?.webFetch },
    } } } }, tools: { web: { fetch: recipe.fetchConfig ?? {} } } };
    const configBefore = plain(config);
    const registered = [], providers = [], fetchProviders = [];
    module.namespace.default.register({ config,
      registerWebFetchProvider: provider => fetchProviders.push({ id: provider.id, label: provider.label }),
      registerWebSearchProvider: provider => providers.push({ id: provider.id, label: provider.label }),
      registerTool: tool => registered.push(tool),
    });
    const registration = { pluginId: module.namespace.default.id, fetchProviders, providers,
      tools: registered.map(tool => ({ name: tool.name })),
      boundary: 'actual default plugin.register(apiFixture) constructs tools/providers; full host registry and assembly unexecuted' };
    const tool = registered.find(tool => tool.name === 'firecrawl_scrape');
    assert.ok(tool);
    const descriptor = { name: tool.name, label: tool.label, resultContentSource: tool.resultContentSource,
      description: tool.description, parameters: plain(tool.parameters) };
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString();
      const args = plain(item.arguments), argumentsBefore = plain(args), requestCount = capture.requests.length;
      const toolResult = plain(await tool.execute(`scrape-${recipe.id}-${n}`, args));
      assert.deepEqual(args, argumentsBefore);
      assert.deepEqual(JSON.parse(toolResult.content[0].text), toolResult.details);
      const requests = capture.requests.slice(requestCount);
      assert.equal(requests.length, 1);
      const resultUnframed = unframeScrapeResult(toolResult.details);
      steps.push({ arguments: argumentsBefore, argumentsAfter: plain(args), clock, request: requests[0],
        cumulativeRequests: capture.requests.length, toolResult, result: toolResult.details,
        resultUnframed, resultPortable: portableScrapeResult(resultUnframed) });
    }
    assert.deepEqual(config, configBefore);
    groups.push({ id: recipe.id, config: configBefore, configAfter: plain(config), registration,
      descriptor, httpPayload: capture.payload, steps, audit: capture.audit });
    typeboxVersion = capture.typeboxVersion;
    for (const [key, value] of capture.sources) sources.set(key, { ...value, executed: value.executed || sources.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  }
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-firecrawl-scrape.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'complete-module pin-verified loader, source/platform provenance and deterministic randomBytes frame IDs' }],
    source: index, invocation: 'defaultPlugin.register(apiFixture) -> registered firecrawl_scrape tool -> execute(callId, rawArguments)',
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: true,
      factoryInvoked: true, publicCallbackInvoked: true, actualJsonResult: true, actualMarkdownToText: true,
      actualPluginConfigReader: true, localResultCache: false, productionNetworkInvoked: false, fixtureEnvironment: {},
      unwrap: 'exact single Web Fetch frame removal from text/title/warning; no trim or field deletion; original framed length retained',
      portableComparison: 'only separate resultPortable removes reference externalContent and replaces length with unframed text UTF16 length; rawLength and all other keys retained',
      limits: [
        'All 58558 tracked source blobs verified before and after; source executed means whole module loaded/evaluated, not every export called',
        'Full plugin registration and provider/tool constructors run on minimal API fixture; generic fetch/search execution and host assembly unexecuted',
        'Whole config reader/runtime/config normalization modules execute against explicit resolved config; unused capture cloning/channel services throw if invoked',
        'Whole web-fetch-utils module executes actual markdownToText and normalizeWhitespace; unused HTML services explicitly throw if invoked',
        'Whole standalone client executes request serialization, endpoint replacement, option resolution, status/content/URL parsing and result wrappers',
        'HTTP callbacks and successful Response.json parser are fixtures; maxBytes/timeouts recorded, production bounded parser/policy/network/timers unexecuted',
        'Literal fixture credential normalization only; environment and secret discovery unexecuted; no production config writes',
        'Known ordinary public hosts have explicit fixed classifier fixture; production security policy unexecuted and no security tests',
        'The direct-factory-scientific-numbers group exercises accepted raw callback numeric strings, bypassing model schema; declared model parameters remain integers',
        'Only positive ordinary local success cases; no permission/auth/TLS/negative/mixed/real-provider/failure/cancel/crash-recovery tests',
        'Worker persistence/replay and host equivalence require independent host acceptance; source framing/sanitation and full WHATWG equivalence are separate boundaries',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, row) => sum + row.steps.length, 0) },
    manifest: { path: 'extensions/firecrawl/openclaw.plugin.json',
      sha256: digest(readFileSync(join(root, 'extensions/firecrawl/openclaw.plugin.json'))),
      content: JSON.parse(readFileSync(join(root, 'extensions/firecrawl/openclaw.plugin.json'), 'utf8')) },
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root, 'LICENSE'))), text: readFileSync(join(root, 'LICENSE'), 'utf8') },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1]; else output = args[n + 1];
  }
  const json = JSON.stringify(await captureFirecrawlScrape(root), null, 2) + '\n';
  if (output) writeFileSync(output, json); else process.stdout.write(json);
}
