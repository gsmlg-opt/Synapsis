// Ordinary successful search callbacks from whole unchanged pinned OpenClaw modules.
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
const factory = 'extensions/firecrawl/src/firecrawl-search-provider.ts';
const output = 'src/agents/tools/web-search-output.ts';
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
  index, client, results, markdown, output,
  'extensions/firecrawl/src/firecrawl-fetch-provider.ts',
  'extensions/firecrawl/src/firecrawl-fetch-provider-shared.ts',
  factory,
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
    'export {readResponseText,withSelfHostedWebToolsEndpoint,withStrictWebToolsEndpoint} from "firecrawl-search:platform";',
  ].join('\n'),
  [sdk + 'number-runtime']: from(['asNonNegativeFiniteNumber', 'asPositiveFiniteNumber',
    'parseDateStringTimestampMs', 'parseFiniteNumber', 'resolveIntegerOption'], normalization + 'number-coercion.ts'),
  [sdk + 'node-crypto-runtime']: from(['sha256Hex'], normalization + 'node-crypto.ts'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'plugin-config-runtime']: from(['resolvePluginConfigObject'], 'src/plugin-sdk/plugin-config-runtime.ts'),
  [sdk + 'provider-http']: 'export {ProviderHttpError,readProviderJsonObjectResponse} from "firecrawl-search:platform";',
  [sdk + 'secret-input']: from(['normalizeSecretInput'], 'src/utils/normalize-secret-input.ts'),
  [sdk + 'secret-ref-readonly']: 'export {resolveReadOnlyEnvSecretRef} from "firecrawl-search:platform";',
  [sdk + 'ssrf-runtime']: 'export {SsrFBlockedError,isBlockedHostnameOrIp,isPrivateIpAddress,resolvePinnedHostnameWithPolicy} from "firecrawl-search:platform";',
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

class FirecrawlSearchCapture extends BraveCapture {
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
    const id = 'firecrawl-search:typebox:' + relative(this.typeboxRoot, file);
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
      withSelfHostedWebToolsEndpoint: unused('withSelfHostedWebToolsEndpoint'),
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
      isBlockedHostnameOrIp: unused('isBlockedHostnameOrIp'),
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
    };
    return this.synthetic('firecrawl-search:platform', bindings, Object.fromEntries(Object.keys(bindings)
      .map(name => [name, { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service',
        behavior: descriptions[name] ?? 'unused; throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'firecrawl-search:platform') return this.platform();
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
    if (importer.startsWith('firecrawl-search:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('firecrawl-search:typebox:'.length)), specifier)));
    }
    if (importer === output && specifier === '../../web-search/runtime-error.js') {
      const path = 'src/web-search/runtime-error.ts';
      this.verifiedSource(path, false);
      link('unused-error-service', path);
      return this.deferred(importer, specifier,
        ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']);
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk) ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'firecrawl-search:facade:' + specifier;
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

// Portable comparison is explicit: preserve every actual result field except
// the reference stamp, removing only the exact deterministic Web Search frame.
export function unframeSearchText(value) {
  const start = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Search\n---\n';
  const end = '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
  if (!value.startsWith(start)) return value;
  assert.ok(value.endsWith(end), 'exact pinned Web Search envelope');
  return value.slice(start.length, -end.length);
}
function mapResultText(result, transform) {
  const copy = plain(result);
  for (const row of copy.results) {
    for (const key of ['title', 'description', 'content', 'snippet', 'siteName']) {
      if (typeof row[key] === 'string') row[key] = transform(row[key]);
    }
  }
  return copy;
}
export function portableSearchResult(result) {
  const copy = plain(result);
  delete copy.externalContent;
  return copy;
}
const row = (n, extra = {}) => ({ title: `Source ${n}`, url: `https://www.source.example/${n}`,
  description: `Passage ${n}`, publishedDate: '2026-01-02T03:04:05.678Z', ...extra });
const searchPayload = (count = 3) => ({ success: true, data: Array.from({ length: count }, (_, n) => row(n + 1)) });
const step = arguments_ => ({ arguments: arguments_ });
function recipes() {
  const rows = [];
  const add = (id, surface, arguments_, options = {}) => rows.push({ id, surface,
    steps: options.steps ?? [step(arguments_ ?? { query: id })], ...options });
  for (const surface of ['generic-paid', 'generic-free']) {
    add(`${surface}-default`, surface, { query: ' ordinary generic search ' });
    add(`${surface}-ten`, surface, { query: 'generic ten', count: 10 }, { httpPayload: searchPayload(12) });
    add(`${surface}-configured-search-policy`, surface, { query: 'configured source defaults' }, {
      searchConfig: { maxResults: 9, timeoutSeconds: 7 },
    });
  }
  add('dedicated-default', 'dedicated', { query: ' ordinary dedicated search ' });
  add('dedicated-count-hundred', 'dedicated', { query: 'hundred', count: 100 }, { httpPayload: searchPayload(101) });
  add('dedicated-count-twelve', 'dedicated', { query: 'twelve', count: 12 }, { httpPayload: searchPayload(12) });
  add('dedicated-full-include', 'dedicated', {
    query: ' full include query ', count: 8, sources: [' web ', '', 'news', 'images'],
    categories: [' github ', 'research'], includeDomains: [' source.example ', 'docs.example'],
    tbs: ' qdr:w ', location: ' San Francisco,California,United States ', country: ' US ',
    scrapeResults: true, timeoutSeconds: 7,
  }, { httpPayload: { success: true, data: [row(1, { markdown: ' Full Markdown 😀 \n' })] } });
  add('dedicated-full-exclude', 'dedicated', {
    query: 'full exclude query', count: 2, sources: ['news'], categories: ['research'],
    excludeDomains: ['archive.example', ' old.example '], tbs: 'sbd:1',
    location: 'Germany', country: 'DE', scrapeResults: false, timeoutSeconds: 11,
  });
  add('dedicated-snake-case-readers', 'dedicated', {
    query: 'snake case', include_domains: [' source.example '], timeout_seconds: 4,
    sources: [' web '], categories: [' research '], tbs: ' qdr:d ', country: ' JP ',
    scrapeResults: true,
  });
  add('dedicated-empty-options', 'dedicated', {
    query: 'empty options', sources: [' ', ''], categories: [], includeDomains: [],
    excludeDomains: [' '], tbs: ' ', location: '', country: '\t', scrapeResults: false,
  });
  add('dedicated-scientific-count-timeout', 'dedicated', {
    query: 'ordinary numeric tokens', count: '2.e0', timeoutSeconds: '3.e0',
  });
  add('endpoint-replacement', 'dedicated', { query: 'endpoint' }, {
    pluginConfig: { webSearch: { baseUrl: ' https://api.firecrawl.dev/proxy/path?ordinary=yes#section ' } },
  });
  const envelopeRows = [row(1), row(2)];
  for (const [id, httpPayload] of [
    ['data-array', { success: true, data: envelopeRows }],
    ['results-array', { success: true, results: envelopeRows }],
    ['nested-results', { success: true, data: { results: envelopeRows } }],
    ['nested-data', { success: true, data: { data: envelopeRows } }],
    ['sources', { success: true, data: { web: [row('web')], news: [row('news')], images: [row('images')] } }],
    ['legacy-web', { success: true, web: { results: envelopeRows } }],
    ['empty-sources', { success: true, data: { web: [], news: [], images: [] } }],
    ['empty-data-precedence', { success: true, data: [], results: [row('later')] }],
    ['data-precedence', { success: true, data: envelopeRows, results: [row('later')] }],
    ['results-precedence', { success: true, results: envelopeRows, data: { results: [row('later')] } }],
    ['nested-results-precedence', { success: true, data: { results: envelopeRows, data: [row('later')], web: [row('last')] } }],
    ['nested-data-precedence', { success: true, data: { data: envelopeRows, web: [row('later')] } }],
  ]) add(`envelope-${id}`, 'dedicated', { query: `envelope ${id}`, count: 10 }, { httpPayload });
  const fallbackPayload = { success: true, data: [
    { url: '', sourceURL: 'https://www.fallback.example/first', title: '', description: '', snippet: ' Snippet 😀 ',
      markdown: '', content: ' Content fallback \n', publishedDate: '', published: '2026-01-02T03:04:05.678Z',
      metadata: { title: ' Metadata title 😀 ', sourceURL: 'https://unused.example/', publishedTime: '2025-02-03' } },
    { url: '', sourceURL: '', sourceUrl: 'https://source.example/second', title: 'Second', description: '',
      snippet: '', summary: 'Summary fallback', markdown: '', content: '', text: 'Text fallback',
      publishedDate: '', published: '', metadata: { publishedTime: '2026-02-03 04:05:06+00:00' } },
    { url: '', sourceURL: '', sourceUrl: '', title: '', description: '', metadata: {
      sourceURL: 'https://www.metadata.example/third', title: 'Third metadata',
      publishedTime: '', publishedDate: '2026-03-04T05:06:07Z' } },
    { url: 'https://source.example/fourth', title: 'Fourth', publishedDate: '2026-04-05',
      published: '2025-01-01', metadata: { title: 'Unused', publishedTime: '2024-01-01' } },
    { url: 'https://bare.example', title: 'Bare origin', snippet: 'Bare snippet' },
    { url: 'https://SOURCE.EXAMPLE:443/ordinary path?q=hello world#section', title: 'Canonical URL' },
  ] };
  add('result-empty-field-fallbacks', 'dedicated', { query: 'fallbacks', count: 10, scrapeResults: true }, { httpPayload: fallbackPayload });
  add('result-content-disabled', 'dedicated', { query: 'content disabled', count: 10, scrapeResults: false }, { httpPayload: fallbackPayload });
  add('result-unicode-whitespace', 'dedicated', { query: 'unicode whitespace', scrapeResults: true }, {
    httpPayload: { success: true, data: [row(1, { title: ' \t標題😀e\u0301 👩‍💻 \n',
      description: ' \t本文界😀 \n', markdown: ' \t# Literal Markdown 😀\n ', publishedDate: '2026-01-02T03:04:05+00:00' })] },
  });
  for (const [id, unit] of [['emoji', '😀'], ['combining', 'e\u0301'], ['zwj', '👩‍💻']]) {
    for (const surface of ['dedicated', 'generic-paid']) {
      add(`${surface}-budget-${id}`, surface, { query: `${surface} budget ${id}`, count: 2,
        ...(surface === 'dedicated' ? { scrapeResults: true } : {}) }, {
        httpPayload: { success: true, data: [row(1, { title: unit.repeat(12_000),
          description: unit.repeat(12_000), markdown: unit.repeat(12_000) }), row(2)] },
      });
    }
  }
  add('dedicated-budget-order', 'dedicated', { query: 'ordered budget', count: 2, scrapeResults: true }, {
    httpPayload: { success: true, data: [row(1, { title: 'T'.repeat(10_000), description: 'D'.repeat(8_000),
      markdown: 'C'.repeat(2_001) }), row(2)] },
  });
  add('dedicated-cache-normalized-options', 'dedicated', undefined, { steps: [
    step({ query: ' cached options ', sources: [' web ', ''], tbs: ' qdr:d ', timeoutSeconds: 7 }),
    step({ query: 'cached options', sources: ['web'], tbs: 'qdr:d', timeoutSeconds: 3 }),
  ] });
  add('dedicated-cache-count-options', 'dedicated', undefined, { steps: [
    step({ query: 'cache count', count: 1 }), step({ query: 'cache count', count: 2 }),
    step({ query: 'cache count', count: 1 }), step({ query: 'cache count', count: 1, scrapeResults: true }),
  ] });
  for (const surface of ['generic-paid', 'generic-free']) add(`${surface}-cache`, surface, undefined, { steps: [
    step({ query: 'generic cache' }), step({ query: 'generic cache' }),
  ] });
  return rows;
}

export async function captureFirecrawlSearch(root = '/tmp/openclaw-488631c') {
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
  const normalizer = new FirecrawlSearchCapture(root);
  const outputModule = normalizer.source(output);
  await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput;
  const unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new FirecrawlSearchCapture(root, recipe.httpPayload ?? searchPayload());
    const module = capture.source(index);
    await capture.evaluate(module);
    const config = { plugins: { entries: { firecrawl: { config: {
      ...recipe.pluginConfig,
      webFetch: { apiKey: 'fixture-firecrawl-key', ...recipe.pluginConfig?.webFetch },
    } } } }, tools: { web: { search: { cacheTtlMinutes: 15, ...recipe.searchConfig } } } };
    const configBefore = plain(config);
    const registered = [], providers = [], fetchProviders = [];
    module.namespace.default.register({ config,
      registerWebFetchProvider: provider => fetchProviders.push({ id: provider.id, label: provider.label }),
      registerWebSearchProvider: provider => providers.push(provider),
      registerTool: tool => registered.push(tool),
    });
    const dedicated = recipe.surface === 'dedicated';
    const providerId = recipe.surface === 'generic-free' ? 'firecrawl-free' : 'firecrawl';
    const provider = providers.find(item => item.id === providerId);
    assert.ok(provider);
    const setup = { config, searchConfig: config.tools.web.search };
    const tool = dedicated ? registered.find(item => item.name === 'firecrawl_search') : provider.createTool(setup);
    assert.ok(tool);
    const descriptor = plain({ name: tool.name, label: tool.label, resultContentSource: tool.resultContentSource,
      description: tool.description, parameters: tool.parameters });
    const registration = { pluginId: module.namespace.default.id, fetchProviders,
      providers: providers.map(item => ({ id: item.id, label: item.label })),
      tools: registered.map(item => ({ name: item.name })),
      boundary: 'actual default plugin.register(apiFixture) constructs tools/providers; full host registry and assembly unexecuted' };
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + (item.elapsedMs ?? n * 20);
      const clock = new Date(capture.nowMs).toISOString();
      const args = plain(item.arguments), argumentsBefore = plain(args), requestCount = capture.requests.length;
      const raw = dedicated ? await tool.execute(`search-${recipe.id}-${n}`, args) : await tool.execute(args);
      const toolResult = dedicated ? plain(raw) : null;
      const providerResult = plain(dedicated ? raw.details : raw);
      assert.equal(providerResult.provider, providerId, recipe.id);
      assert.deepEqual(args, argumentsBefore);
      if (dedicated) assert.deepEqual(JSON.parse(toolResult.content[0].text), providerResult);
      const requests = capture.requests.slice(requestCount);
      assert.ok(requests.length <= 1);
      const providerUnframedResult = mapResultText(providerResult, unframeSearchText);
      const providerUnwrappedResult = mapResultText(providerResult, unwrap);
      const publicResult = plain(normalize({ result: providerResult, provider: providerId, query: argumentsBefore.query }));
      assert.equal(publicResult.kind, 'results', recipe.id);
      const publicUnwrappedResult = mapResultText(publicResult, unwrap);
      steps.push({ arguments: argumentsBefore, argumentsAfter: plain(args), clock,
        request: requests[0] ?? null, cumulativeRequests: capture.requests.length, cached: providerResult.cached === true,
        toolResult, providerResult, providerUnframedResult, providerUnwrappedResult,
        providerPortableResult: portableSearchResult(providerUnframedResult), publicResult, publicUnwrappedResult,
        publicPortableResult: portableSearchResult(publicUnwrappedResult) });
    }
    assert.deepEqual(config, configBefore);
    groups.push({ id: recipe.id, surface: recipe.surface, provider: providerId,
      config: configBefore, configAfter: plain(config), setup: plain(setup), registration, descriptor,
      providerMetadata: plain({ id: provider.id, label: provider.label, hint: provider.hint,
        onboardingScopes: provider.onboardingScopes, requiresCredential: provider.requiresCredential }),
      httpPayload: plain(capture.payload), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root);
  assert.deepEqual(after, before);
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-firecrawl-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported pin-verified complete-module loader and deterministic randomBytes; copied capture-only Firecrawl scrape loader facilities in this new file' }],
    invocations: ['defaultPlugin.register(apiFixture)', 'createFirecrawlWebSearchProvider().createTool(setup).execute(arguments)',
      'createFirecrawlFreeWebSearchProvider().createTool(setup).execute(arguments)',
      'registered firecrawl_search.execute(callId,arguments)', 'whole runFirecrawlSearch(params)',
      'normalizeWebSearchOutput({result,provider,query})'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, pluginRegistrationInvoked: true,
      paidAndFreeProviderCallbacksInvoked: true, dedicatedCallbackInvoked: true, actualJsonResult: true,
      genericNormalizerInvoked: true, actualSharedCache: true, actualPluginConfigReader: true,
      productionNetworkInvoked: false, fixtureEnvironment: {},
      unwrap: 'providerUnframedResult removes exact single deterministic Web Search frames without trim; providerPortableResult additionally removes only the top-level externalContent stamp; public variants use actual source unwrapWebSearchOutputText; complete framed originals retained',
      publicProjection: 'actual source generic normalizer is also observed after dedicated results as a separate comparison; dedicated callback returns its original jsonResult, not this generic projection',
      limits: [
        'All58558 tracked source blobs verified before/after; executed means whole module evaluated, not every export or branch called',
        'Actual plugin.register, paid/free provider factories, dedicated factory and whole shared search client execute; scrape callbacks remain unexecuted',
        'Successful HTTP and Response.json parser are explicit fixtures; production bounded reader/network/endpoint policy/timers unexecuted',
        'Literal resolved configuration only; actual secret/environment discovery and all alternate endpoint policy services remain unexecuted',
        'Timeouts are observed request values; fixed clock cache evidence does not establish native lifecycle or real-time cleanup',
        'Scientific numeric tokens and snake_case reader aliases exercise the raw dedicated callback; the declared source schema retains camelCase integer parameters',
        'Only ordinary valid successful data/callbacks; no security/permission/auth/TLS/negative/mixed/real-provider/failure/cancel/crash tests',
        'Full host assembly, native Worker/persistence/replay, complete sanitizer/WHATWG equivalence and real provider acceptance require independent verification',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(item => item.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(item => !item.executed).length,
      groups: groups.length, callbacks: groups.reduce((sum, item) => sum + item.steps.length, 0),
      httpCallbacks: groups.reduce((sum, item) => sum + item.steps.filter(part => part.request !== null).length, 0) },
    sources: sorted(sources.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()),
    stubs: sorted(stubs.values()), typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', destination;
  for (let n = 0; n < args.length; n += 2) {
    assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE');
    if (args[n] === '--source') root = args[n + 1]; else destination = args[n + 1];
  }
  const json = JSON.stringify(await captureFirecrawlSearch(root), null, 2) + '\n';
  if (destination) writeFileSync(destination, json); else process.stdout.write(json);
}

