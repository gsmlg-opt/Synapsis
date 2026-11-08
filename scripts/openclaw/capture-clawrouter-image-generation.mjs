// Whole pinned ClawRouter callback/catalog and helper sources; successful synthetic I/O only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const CLAWROUTER_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/clawrouter/image-generation-provider.ts';
const catalog = 'extensions/clawrouter/image-model-catalog.ts';
const base = 'extensions/clawrouter/base-url.ts';
const urls = 'src/image-generation/openai-compatible-image-urls.ts';
const assets = 'src/image-generation/image-assets.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const constants = 'packages/media-core/src/constants.ts';
const base64 = 'packages/media-core/src/base64.ts';
const caps = 'src/media/configured-max-bytes.ts';
const shared = 'src/media-understanding/shared.ts';
const errors = 'src/agents/provider-http-errors.ts';
const wholeSources = [entry, catalog, base, assets, urls, number, strings, records, base64, constants];
const provenancePaths = ['extensions/clawrouter/openclaw.plugin.json', 'extensions/clawrouter/index.ts',
  'src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugin-sdk/ssrf-runtime.ts',
  'src/image-generation/types.ts', 'src/agents/provider-request-config.ts',
  'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts',
  'src/infra/http-response-body.ts', 'src/infra/http-response-body-timeout.ts'];
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), CLAWROUTER_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', CLAWROUTER_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source); const stat = lstatSync(file); const symlink = stat.isSymbolicLink();
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', source + ' mode');
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, mode, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])), receipt: {
    verified: true, commit: CLAWROUTER_IMAGE_GENERATION_PIN,
    tree: git(root, ['rev-parse', `${CLAWROUTER_IMAGE_GENERATION_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const models = ['openai/gpt-image-2.5-flare', 'openai/gpt-image-2.5-flare-2026-09-08',
  'openai/gpt-image-2.5-sunburst', 'openai/gpt-image-2.5-sunburst-2026-09-08'];
const prompt = ' Draw a small blue square. ';
const limits = { maxPromptCharacters: 32000, maxImages: 10, dimensionMultiple: 16,
  minPixels: 655360, maxPixels: 8294400, maxEdge: 3840, maxAspectRatio: 3 };
function catalogResponse(selectedLimits = limits, affordability = 'exact-covered') {
  return { version: 'clawrouter.client-catalog.v1', providers: [{ id: 'openai', allowed: true,
    executable: true, models: models.map(id => ({ id, displayName: '  Ordinary ' + id + '  ',
      capabilities: ['image.generation'], pricing: { unit: 'image_token', generation: { ...selectedLimits } } })),
    offers: models.map(modelId => ({ endpoint: 'images_generations', modelId, transport: 'http',
      routeKind: 'unified', route: '/v1/images/generations', eligible: true, affordability })) }] };
}
function vectors() {
  const row = (id, input = {}, extra = {}) => ({ id, hostComparable: extra.hostComparable ?? true,
    ...(extra.adaptationReason ? { adaptationReason: extra.adaptationReason } : {}),
    input: { prompt, model: models[0], ...(extra.defaults ? {} : { timeoutMs: 30000 }), ...input },
    config: { baseUrl: 'https://router.example.test', ...extra.config },
    catalogResponse: extra.catalogResponse ?? catalogResponse(),
    response: extra.response ?? { json: { data: Array.from({ length: input.count ?? 1 }, () => ({ b64_json: png })) }, downloads: [] },
    ...(extra.services ? { services: extra.services } : {}) });
  const rows = [row('minimal'), row('fractional-timeout', { timeoutMs: 30000.9 })];
  models.slice(1).forEach((model, i) => rows.push(row('model-' + (i + 1), { model })));
  rows.push(row('base-v1', {}, { config: { baseUrl: 'https://router.example.test/v1/' } }),
    row('base-prefix-trim', {}, { config: { baseUrl: ' \uFEFFhttps://router.example.test/resource/v1///\u00a0' } }));
  for (let count = 1; count <= 10; count++) rows.push(row('count-' + count, { count }));
  rows.push(row('fewer-results', { count: 2 }, { response: { json: { data: [{ b64_json: png }] }, downloads: [] } }),
    row('catalog-lowered-limits', { prompt: '蓝🌕', count: 2, size: '32x32' }, { catalogResponse: catalogResponse({
      maxPromptCharacters: 2, maxImages: 2, dimensionMultiple: 8, minPixels: 1024,
      maxPixels: 2048, maxEdge: 64, maxAspectRatio: 2 }, 'request-dependent') }),
    row('prompt-unicode-whitespace', { prompt: '  绘画 🌕 e\u0301\n' }),
    row('empty-references', { inputImages: [] }));
  ['1024x1024', '1536x1024', '1024x1536', 'auto'].forEach((size, i) => rows.push(row('size-' + i, { size })));
  ['low', 'medium', 'high', 'xhigh', 'max', 'auto'].forEach((quality, i) => rows.push(row('quality-' + i, { quality })));
  ['png', 'jpeg', 'webp'].forEach((outputFormat, i) => rows.push(row('format-' + i, { outputFormat })));
  ['auto', 'opaque', 'transparent'].forEach((background, i) => rows.push(row('background-' + i, { background })));
  rows.push(row('openai-options', { providerOptions: { openai: { background: 'transparent', moderation: 'low',
    outputCompression: 0, user: ' ordinary user ' } } }),
    row('background-top-priority', { background: 'opaque', providerOptions: { openai: { background: 'transparent' } } }),
    row('background-nullish', { background: null, providerOptions: { openai: { background: 'transparent' } } }),
    row('inline-jpeg', {}, { response: { json: { data: [{ b64_json: jpeg }] }, downloads: [] } }),
    row('inline-webp', {}, { response: { json: { data: [{ b64_json: webp }] }, downloads: [] } }));
  for (const [kind, bytes] of [['png', png], ['jpeg', jpeg], ['webp', webp]])
    rows.push(row('explicit-' + kind, {}, { response: { json: { created: 17, model: 'ignored-service-model', usage: { count: 1 },
      data: [{ b64_json: bytes, mime_type: ' image/' + kind + ' ', revised_prompt: '  Revised ordinary prompt.\n',
        file_name: 'ignored-name.bin', metadata: { ignored: true } }] }, downloads: [] } }));
  rows.push(row('base64-unpadded', {}, { response: { json: { data: [{ b64_json: png.replace(/=+$/, '') }] }, downloads: [] } }),
    row('base64-whitespace', {}, { response: { json: { data: [{ b64_json: ' \n' + png.slice(0, 12) + '\t' + png.slice(12) + '\r ' }] }, downloads: [] } }),
    row('ordered-url-results', { count: 2 }, { response: { json: { data: [
      { url: 'https://router.example.test/results/ignored-first.jpg', revised_prompt: ' First. ' },
      { url: 'https://images.example.test/ignored-second.webp', revised_prompt: ' Second. ' }] }, downloads: [
        { bytesBase64: png, mimeType: 'Image/PNG; charset=binary' },
        { bytesBase64: png, mimeType: 'image/png' }] } }),
    row('repeat-fresh-catalog-first', {}, { catalogResponse: catalogResponse({ ...limits, maxImages: 2 }) }),
    row('repeat-fresh-catalog-second', { count: 3 }, { catalogResponse: catalogResponse({ ...limits, maxImages: 3 }, 'request-dependent') }),
    row('source-only-default-timeout', {}, { defaults: true, hostComparable: false,
      adaptationReason: 'Raw callback 180000ms default; inactive host requires explicit finite timeout.' }),
    row('source-only-configured-header', {}, { hostComparable: false,
      adaptationReason: 'Literal successful configured-request/header facades; production policy normalization unexecuted.',
      config: { headers: { 'X-Fixture-Provider': ' provider ' }, request: { headers: { 'X-Fixture-Request': ' request ' } } },
      services: { sanitizedRequest: { headers: { 'X-Fixture-Request': 'request' } },
        sanitizedProviderHeaders: { 'X-Fixture-Provider': 'provider' }, resolvedHeaders: { 'X-Fixture-Request': 'request' } } }));
  return rows;
}

class ClawRouterHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, TextDecoder, URL,
      fetch: () => { throw Error('Real network outside source oracle'); },
      __platform: { now: () => this.current.now,
        unused: () => { throw Error('Uninvoked boundary outside ordinary raw callback'); },
        key: params => { const atMs = this.current.now; this.current.now += 2;
          this.current.keyCalls.push({ provider: params.provider, cfg: plain(params.cfg), modelId: params.modelId,
            capability: params.capability, agentDir: params.agentDir ?? null, store: params.store ?? null,
            atMs, implementation: 'successful-explicit-synthetic-key-facade' }); return { apiKey: 'synthetic-explicit-key' }; },
        sanitize: request => this.sanitize(request), config: params => this.config(params),
        guarded: (...args) => this.guarded(...args), fetch: params => this.fetch(params),
        merge: (...policies) => { this.current.policyCalls.push({ inputs: plain(policies.map(value => value ?? null)),
          output: null, implementation: 'successful-unenforced-policy-facade' }); return undefined; },
        status: (response, label) => { assert.equal(response.status, 200); this.current.statusCalls.push({ label,
          status: 200, atMs: this.current.now, implementation: 'successful-status-facade' }); },
        read: (response, maxBytes, options) => this.read(response, maxBytes, options) } },
      { codeGeneration: { strings: false, wasm: false } });
    new vm.Script('Date.now=()=>globalThis.__platform.now();').runInContext(this.context, { timeout: 200 });
    this.sourceRecords = new Map(); this.importBindings = new Map(); this.dynamicImports = [];
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const source = relative(this.root, file); assert.ok(wholeSources.includes(source), source);
    const bytes = readFileSync(file); assert.equal(hash(bytes), this.tracked.get(source), source);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(bytes), executed: true, wholeModule: true,
      transformation: transform, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: specifier => { this.dynamicImports.push({ importer: source, specifier });
        throw Error('Undeclared ClawRouter dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:clawrouter:' + key, code);
  }
  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module',
      source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }
  alias(importer, specifier, source, exports) {
    return this.binding(importer, specifier, 'whole-source-export-alias', exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:' + source)};`,
      { source, sourceSha256: this.tracked.get(source) });
  }
  projection(importer, specifier, source, selections, prelude, exports) {
    const original = readFileSync(join(this.root, source)); assert.equal(hash(original), this.tracked.get(source));
    const regions = selections.map(([startMarker, endMarker]) => {
      const startByte = original.indexOf(startMarker); const endByte = endMarker === null ? original.length : original.indexOf(endMarker, startByte);
      assert.ok(startByte >= 0 && endByte > startByte, source);
      assert.equal(original.indexOf(startMarker, startByte + 1), -1, source + ' unique region');
      return { startByte, endByte, sourceRegionSha256: hash(original.subarray(startByte, endByte)) };
    });
    const generated = prelude + '\n' + regions.map(row => original.subarray(row.startByte, row.endByte).toString()).join('\n');
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source + ':' + regions[0].startByte, { path: source, sha256: hash(original), executed: true,
      wholeModule: false, projection: { regions, prelude, generatedCode: generated, generatedSha256: hash(generated) },
      transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-regions-projection', exports, executable,
      { source, sourceSha256: this.tracked.get(source) });
  }
  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:clawrouter:') && specifier.startsWith('capture:source:'))
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (parent.startsWith('capture:clawrouter:') && specifier === 'capture:deadlines')
      return this.projection(parent, specifier, shared,
        [['export function createProviderOperationDeadline(', '/** Resolves a static or lazy request timeout']],
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError']);
    if (parent.startsWith('capture:clawrouter:') && specifier === 'capture:post-wrappers')
      return this.projection(parent, specifier, shared, [
        ['function resolveGuardedRequestOptions(', 'async function fetchProviderOperation('],
        ['type GuardedPostRequestRetryOptions =', '// Keep the shipped transcription name'],
      ], 'const fetchWithTimeoutGuarded=globalThis.__platform.guarded;\nconst isTransientProviderHttpStatus=globalThis.__platform.unused;\nconst createProviderHttpError=globalThis.__platform.unused;\nconst executeProviderOperationWithRetry=globalThis.__platform.unused;',
      ['postJsonRequest', 'postMultipartRequest']);
    if (parent.startsWith('capture:clawrouter:') && specifier === 'capture:readers')
      return this.projection(parent, specifier, errors, [
        ['const PROVIDER_RESPONSE_MAX_BYTES =', 'const SHORT_BEARER_TOKEN_PATTERN ='],
        ['function readProviderResponseBytes(', 'type ProviderHttpErrorOptions ='],
        ['export async function readProviderJsonResponse<T>(', 'export async function readProviderJsonObjectResponse('],
        ['// One HTTP media type,', null],
      ], 'const readResponseWithLimit=globalThis.__platform.read;\nconst mediaKindFromMime=globalThis.__platform.unused;',
      ['readProviderJsonResponse', 'readProviderBinaryResponse']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation')
      return this.binding(importer, specifier, 'whole-source-export-alias',
        ['inlineOpenAiCompatibleImageUrls', 'parseOpenAiCompatibleImageResponse', 'resolveInlineImageJsonResponseMaxBytes', 'sniffImageMimeType'],
        `export {parseOpenAiCompatibleImageResponse,resolveInlineImageJsonResponseMaxBytes,sniffImageMimeType} from 'capture:source:${assets}';\nexport {inlineOpenAiCompatibleImageUrls} from 'capture:source:${urls}';`);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime')
      return this.projection(importer, specifier, caps, [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']],
        `import {maxBytesForKind} from 'capture:source:${constants}';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if ([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-auth-runtime')
      return this.binding(importer, specifier, 'successful-explicit-synthetic-key-facade', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.key;');
    if ([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime')
      return this.binding(importer, specifier, 'whole-source-export-alias', ['asOptionalRecord', 'normalizeOptionalString'],
        `export {asOptionalRecord} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`);
    if ([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http')
      return this.binding(importer, specifier, 'source-deadline-post-json-and-successful-config-guard-facades',
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'postJsonRequest', 'readProviderJsonResponse',
          'fetchWithTimeoutGuarded', 'resolveProviderHttpRequestConfigWithOriginTrust', 'sanitizeConfiguredModelProviderRequest'],
        `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs} from 'capture:deadlines';
export {postJsonRequest} from 'capture:post-wrappers';
export {readProviderJsonResponse} from 'capture:readers';
export const fetchWithTimeoutGuarded=globalThis.__platform.guarded;
export const resolveProviderHttpRequestConfigWithOriginTrust=globalThis.__platform.config;
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;`);
    if (([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/ssrf-runtime') ||
        (importer === urls && specifier === '../infra/net/ssrf.js'))
      return this.binding(importer, specifier, 'successful-unenforced-policy-facade', ['mergeSsrFPolicies'],
        'export const mergeSsrFPolicies=globalThis.__platform.merge;');
    if (importer === urls && specifier === '../infra/net/fetch-guard.js')
      return this.binding(importer, specifier, 'successful-no-network-guarded-fetch-facade', ['fetchWithSsrFGuard'],
        'export const fetchWithSsrFGuard=globalThis.__platform.fetch;');
    if (importer === urls && specifier === '../agents/provider-http-errors.js')
      return this.binding(importer, specifier, 'source-binary-reader-and-successful-status-facade',
        ['assertOkOrThrowHttpError', 'readProviderBinaryResponse'],
        `export {readProviderBinaryResponse} from 'capture:readers';\nexport const assertOkOrThrowHttpError=globalThis.__platform.status;`);
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared ClawRouter image import: ${importer} -> ${specifier}`);
  }
  sanitize(request) {
    const providerHeaders = request && Object.hasOwn(request, 'headers') && request.headers === this.current.providerHeaders;
    const output = providerHeaders ? (this.current.services.sanitizedProviderHeaders
      ? { headers: this.current.services.sanitizedProviderHeaders } : undefined) : this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null,
      implementation: 'successful-configured-request-sanitizer-facade' }); return output;
  }
  config(params) {
    const atMs = this.current.now; this.current.now += 3;
    const headers = new Headers(this.current.services.resolvedHeaders);
    const output = { baseUrl: params.baseUrl, headers: Object.fromEntries(headers), allowPrivateNetwork: false,
      trustConfiguredBaseUrlOrigin: false };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, transport: params.transport,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl, request: params.request ?? null, output,
      atMs, implementation: 'successful-provider-http-request-config-facade' });
    return { ...output, headers, dispatcherPolicy: undefined };
  }
  async guarded(url, init, timeoutMs, fetchFn, options) {
    assert.equal(fetchFn, this.context.fetch);
    this.current.guardCalls.push({ url, timeoutMs, options: options ?? null,
      implementation: 'successful-no-network-fetchWithTimeoutGuarded-facade' });
    return this.fetch({ url, init, timeoutMs, ...options });
  }
  async fetch(params) {
    const kind = params.init?.method === 'POST' ? 'post' : params.url.endsWith('/catalog') ? 'catalog' : 'download';
    const receipt = { url: params.url, method: params.init?.method ?? 'GET',
      headers: params.init?.headers ? Object.fromEntries(new Headers(params.init.headers)) : {},
      timeoutMs: params.timeoutMs ?? null, atMs: this.current.now,
      auditContext: params.auditContext ?? null, dispatcherPolicy: params.dispatcherPolicy ?? null, releaseCount: 0 };
    let response;
    if (kind === 'post') {
      assert.equal(typeof params.init.body, 'string');
      Object.assign(receipt, { kind: 'json', rawBody: params.init.body, body: JSON.parse(params.init.body), jsonBody: JSON.parse(params.init.body) });
      this.current.request = receipt; this.current.now += 7;
      response = new Response(JSON.stringify(this.current.response.json), { status: 200, headers: { 'content-type': 'application/json' } });
    } else if (kind === 'catalog') {
      assert.equal(params.init?.body, undefined);
      this.current.catalogRequest = receipt; this.current.now += 4;
      response = new Response(JSON.stringify(this.current.catalogResponse), { status: 200, headers: { 'content-type': 'application/json' } });
    } else {
      assert.equal(params.init?.body, undefined);
      const download = this.current.response.downloads[this.current.downloads.length]; assert.ok(download);
      this.current.downloads.push(receipt); this.current.now += 5;
      response = new Response(Buffer.from(download.bytesBase64, 'base64'), { status: 200,
        headers: { 'content-type': download.mimeType } });
    }
    this.current.responses.set(response, { kind, receipt });
    return { response, release: async () => {
      receipt.releaseCount++; receipt.releasedAtMs = this.current.now;
      this.current.releaseCalls.push({ kind, url: receipt.url, releaseCount: receipt.releaseCount, atMs: this.current.now });
    } };
  }
  async read(response, maxBytes, options) {
    const { kind, receipt } = this.current.responses.get(response); receipt.maxBytes = maxBytes;
    const timeoutMs = typeof options?.timeoutMs === 'function' ? options.timeoutMs() : options?.timeoutMs;
    this.current.readerCalls.push({ kind, maxBytes, timeoutMs, chunkTimeoutMs: options?.chunkTimeoutMs ?? null,
      hasOnIdleTimeout: typeof options?.onIdleTimeout === 'function', hasOnOverflow: typeof options?.onOverflow === 'function',
      atMs: this.current.now, implementation: 'successful-lower-body-reader-facade' });
    const bytes = Buffer.from(await response.arrayBuffer()); assert.ok(bytes.length <= maxBytes);
    this.current.now += kind === 'download' ? 2 : 3; return bytes;
  }
  async run(vector) {
    this.current = { response: plain(vector.response), catalogResponse: plain(vector.catalogResponse),
      services: plain(vector.services ?? {}), downloads: [], responses: new Map(), now: 100000,
      readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], policyCalls: [], guardCalls: [], releaseCalls: [] };
    const input = plain(vector.input);
    const req = { ...input, provider: 'clawrouter', cfg: { models: { providers: { clawrouter: plain(vector.config) } } } };
    this.current.providerHeaders = req.cfg.models.providers.clawrouter.headers;
    const cfgBefore = plain(req.cfg); this.context.__req = req; let timer;
    try {
      const promise = new vm.Script('__provider.generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('ClawRouter fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      assert.deepEqual(plain(after), vector.input);
      assert.equal(this.current.request.releaseCount, 1); assert.equal(this.current.catalogRequest.releaseCount, 1);
      assert.ok(this.current.downloads.every(row => row.releaseCount === 1));
      return plain({ ...vector, inputAfter: plain(after), catalogRequest: this.current.catalogRequest,
        request: this.current.request, downloads: this.current.downloads,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls, configCalls: this.current.configCalls,
        sanitizeCalls: this.current.sanitizeCalls, keyCalls: this.current.keyCalls, policyCalls: this.current.policyCalls,
        guardCalls: this.current.guardCalls, releaseCalls: this.current.releaseCalls, releaseCount: this.current.releaseCalls.length,
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { key: 2, config: 3, catalog: 4, catalogRead: 3, post: 7, jsonRead: 3, download: 5, binaryRead: 2 },
          sameProviderInstance: true } });
    } finally { clearTimeout(timer); }
  }
}

export async function captureClawRouterImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ClawRouterHarness(root, before.tracked); await harness.load(entry);
  new vm.Script('globalThis.__provider=__exports.buildClawRouterImageGenerationProvider();').runInContext(harness.context, { timeout: 200 });
  const providerDescriptor = harness.call('(()=>{const {generateImage,...descriptor}=__provider;return descriptor;})()');
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), source);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: CLAWROUTER_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-clawrouter-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    serviceFacadeLedger: [
      { name: 'resolveApiKeyForProvider', executed: false, limit: 'Fixed synthetic key context only; production credential/env/profile discovery unexecuted.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, limit: 'Literal successful outputs; production configured-request normalization unexecuted.' },
      { name: 'resolveProviderHttpRequestConfigWithOriginTrust', executed: false, limit: 'Consumes original ClawRouter normalized base; successful literal Headers/config context, no production policy equivalence.' },
      { name: 'fetchWithTimeoutGuarded/fetchWithSsrFGuard/mergeSsrFPolicies', executed: false, limit: 'Exact imported signatures recorded; no-network successful Response/release producers. SSRF/TLS/proxy/DNS/redirect and permission policy unexecuted.' },
      { name: 'assertOkOrThrowHttpError', executed: false, limit: 'Successful status-200 facade only. ClawRouter own catalog/POST successful assertions execute unchanged.' },
      { name: 'readResponseWithLimit', executed: false, limit: 'Native arrayBuffer successful tiny-byte facade records source cap/idle/lazy timeout arguments; production bounded stream/timer enforcement unexecuted.' },
    ],
    limits: [
      'Whole unchanged provider189/catalog304/base10, image-assets275/URLinliner105, base64/number/string/record/constants execute. Live catalog parser and per-row limits are original source; every request fetches freshly on the same provider instance.',
      'Complete source cap/deadline/JSON POST wrapper and guarded-option regions execute. Original fatal UTF8 JSON reader and binary-content/reader helpers execute over an explicitly substituted successful lower body reader.',
      'Whole original number-coercion source defines timer ceiling 2147000000ms, floor and minimum1; modest fractional positive timeout is exercised, no extreme timeout/overflow case executes.',
      'All 58558 tracked blobs/modes/symlinks verified before and after. Original/generated/transformed sources, import/export bindings, exporter, shared harness and fixed Node24.22.1 have reconstructable receipts.',
      'Raw callback only. Every hostComparable row has explicit model/public base/finite timeout. Default timeout and configured header examples are source-only. Same synthetic key on catalog and POST is request-context tracing, not credential/auth-policy verification.',
      'Four exact models, counts1..10, lower positive live limits, valid geometry/auto/omitted size, six qualities, three formats/backgrounds, exact OpenAI options including compression0 and nullish precedence; modest Unicode code-point prompts preserve whitespace.',
      'Homogeneous inline PNG/JPEG/WebP inferred and exact MIME, trimmed revised prompts and valid base64 variants execute. Ordered all-URL PNG results use clean GET headers, sequential read/releases, per-image source cap and final generation release.',
      'Positive synthetic clock tracks key/config/catalog/body/POST/download stages and decreasing total deadline without expiration. Tiny magic-signature bytes are protocol evidence, not image codec/visual validation.',
      'No security/permission/authTLS/negative/mixed/overflow/real-provider/failure/cancel/crash execution cases; no requests beyond requested response count, activation/tools/catalog registration/jobs/storage/delivery or full production policy/reader equivalence.',
    ], providerDescriptor, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2); assert.equal(args.indexOf('--out'), 1);
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureClawRouterImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
