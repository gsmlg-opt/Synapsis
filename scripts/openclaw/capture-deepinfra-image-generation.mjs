// Complete pinned DeepInfra image provider and shared factory/helpers under synthetic successful I/O.
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

export const DEEPINFRA_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/deepinfra/image-generation-provider.ts';
const factory = 'src/image-generation/openai-compatible-image-provider.ts';
const assets = 'src/image-generation/image-assets.ts';
const urls = 'src/image-generation/openai-compatible-image-urls.ts';
const models = 'extensions/deepinfra/media-models.ts';
const manifest = 'extensions/deepinfra/openclaw.plugin.json';
const blob = 'src/plugin-sdk/blob-runtime.ts';
const caps = 'src/media/configured-max-bytes.ts';
const deadlines = 'src/media-understanding/shared.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, models, factory, assets, urls, blob, number, strings, records,
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts'];
const provenancePaths = [manifest, 'src/plugin-sdk/image-generation.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugins/provider-auth-availability.ts',
  'src/agents/provider-http-errors.ts', 'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts',
  'src/agents/provider-request-config.ts', 'extensions/deepinfra/index.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), DEEPINFRA_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', DEEPINFRA_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source);
    const stat = lstatSync(file);
    const symlink = stat.isSymbolicLink();
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', source + ' executable mode');
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, mode, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: DEEPINFRA_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${DEEPINFRA_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const defaultModel = 'black-forest-labs/FLUX-1-schnell';
const defaultBase = 'https://api.deepinfra.com/v1/openai';
function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt: ' Draw a small blue square. ', ...(options.defaults ? {} : { model: defaultModel, timeoutMs: 30000 }), ...input },
    config: { baseUrl: defaultBase, ...options.config },
    response: { json: options.json ?? { data: [{ b64_json: png }] },
      ...(options.rawChunks ? { rawChunks: options.rawChunks } : {}) },
    ...(options.services ? { services: options.services } : {}), downloads: options.downloads ?? [] });
  const inline = (bytes = png, extra = {}) => ({ b64_json: bytes, ...extra });
  const url = index => `https://assets.example.test/image-${index}`;
  const download = (index, contentType = 'image/png', bodyBase64 = png) => ({ url: url(index), contentType, bodyBase64 });
  return [
    base('default-count-size'),
    base('explicit-model-prompt', { model: ' Vendor/Image-X ', prompt: '  Preserve this exact prompt.\n' }),
    base('deepinfra-prefixed-model', { model: ' deepinfra/black-forest-labs/FLUX-1-dev ' }),
    base('count-four', { count: 4 }),
    base('size-512', { size: '512x512' }),
    base('size-1024', { size: '1024x1024' }),
    base('size-portrait', { size: '1024x1792' }),
    base('size-landscape', { size: '1792x1024' }),
    base('size-trim', { size: ' 1024x1792 ' }),
    base('unused-options', { aspectRatio: '16:9', resolution: '2K', quality: 'high', outputFormat: 'jpeg', background: 'opaque',
      providerOptions: { deepinfra: { quality: 'low' } } }),
    base('edit-defaults', { inputImages: [{ bytesBase64: png }] }),
    base('edit-explicit-size-count', { count: 4, size: ' 512x512 ', inputImages: [{ bytesBase64: png }] }),
    base('edit-explicit-mime-filename', { inputImages: [{ bytesBase64: jpeg, mimeType: ' Image/JPEG; mode=RGB ', fileName: ' input.jpg ' }] }),
    base('edit-unicode-path-name', { inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: ' 绘图/输入.png ' }] }),
    base('edit-default-jpeg-filename', { inputImages: [{ bytesBase64: jpeg, mimeType: ' image/jpeg ' }] }),
    base('custom-base', { model: ' deepinfra/Custom/Model ' }, { config: { baseUrl: ' https://images.example.test/custom/v2/// ' } }),
    base('javascript-whitespace', { model: '\uFEFFdeepinfra/Vendor/Image-X\u00a0', size: '\uFEFF512x512\u00a0' },
      { config: { baseUrl: '\uFEFFhttps://images.example.test/js/v3///\u00a0' } }),
    base('ordered-inline-sniff-prompts', { count: 4 }, { json: { data: [inline(jpeg, { revised_prompt: ' First ' }),
      inline(png, { revised_prompt: ' \t ' }), inline(webp, { revised_prompt: ' Third ' }), inline(opaque, { revised_prompt: ' Fourth ' })],
      usage: { total_tokens: 42 }, metadata: { ignored: true } } }),
    base('explicit-mime-wins', {}, { json: { data: [inline(jpeg, { mime_type: ' Image/WEBP; codec=fixture ', revised_prompt: ' Explicit ' })] } }),
    base('base64-unpadded', {}, { json: { data: [inline(png.replace(/=+$/, ''))] } }),
    base('base64-whitespace', {}, { json: { data: [inline(' \n' + png.slice(0, 12) + ' \t' + png.slice(12) + '\n ')] } }),
    base('four-ordered-downloads', { count: 4 }, { json: { data: [1, 2, 3, 4].map(index => ({ url: ` ${url(index)} `, revised_prompt: ` Download ${index} ` })) },
      downloads: [download(1, 'Image/JPEG; mode=RGB', jpeg), download(2, 'image/webp; charset=binary', webp), download(3), download(4, 'IMAGE/AVIF; codec=av1', opaque)] }),
    base('edit-one-download', { inputImages: [{ bytesBase64: png }] }, { json: { data: [{ url: url(1), revised_prompt: ' Edited ' }] },
      downloads: [download(1, 'image/jpeg', jpeg)] }),
    base('json-bom-raw-chunks', {}, { rawChunks: ['77u/', 'eyJkYXRhIjpbeyJiNjRfanNvbiI6Ig==',
      Buffer.from(png).toString('base64'), 'In1dfQ=='] }),
    base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
    base('media-cap-larger', {}, { config: { mediaMaxMb: 80.25 } }),
    base('source-only-default-model-timeout', {}, { defaults: true, hostComparable: false,
      adaptationReason: 'Pinned source supplies black-forest-labs/FLUX-1-schnell and a 60000ms read deadline; POST timeoutMs remains absent. Synapsis requires explicit effective model and finite total timeout.' }),
    base('source-only-configured-header', {}, { hostComparable: false,
      adaptationReason: 'Configured request sanitizer/resolver are named successful service facades; this observes source consumption of their literal outputs, not request-policy/header normalization equivalence.',
      config: { request: { headers: { 'X-Fixture-Render': ' normal ' } } },
      services: { sanitizedRequest: { headers: { 'X-Fixture-Render': 'normal' } }, resolvedHeaders: { 'X-Fixture-Render': 'normal' } } }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, URL, FormData, Blob, ReadableStream,
      fetch: () => { throw Error('Network is outside this image fixture boundary'); },
      __platform: { now: () => this.current.now, post: params => this.post(params),
        config: params => this.config(params), sanitize: request => this.sanitize(request), get: params => this.download(params),
        status: async (response, label, options) => {
          assert.equal(response.status, 200);
          this.current.statusCalls.push({ label, timeoutMs: options.bodyTimeoutMs(), atMs: this.current.now });
        },
        readJson: async (response, label, options) => {
          const receipt = { kind: 'json', label, maxBytes: options.maxBytes, timeoutMs: options.timeoutMs(), atMs: this.current.now };
          this.current.readerCalls.push(receipt);
          this.current.request.maxBytes = options.maxBytes;
          const result = await response.json(); this.current.now += 3; return result;
        },
        readBinary: async (response, label, kind, options) => {
          const receipt = { kind: 'binary', label, mediaKind: kind, maxBytes: options.maxBytes, timeoutMs: options.timeoutMs(), atMs: this.current.now };
          this.current.readerCalls.push(receipt);
          this.current.downloads.at(-1).maxBytes = options.maxBytes;
          const result = Buffer.from(await response.arrayBuffer()); this.current.now += 13; return result;
        },
        policy: (...policies) => { this.current.policyCalls.push(plain(policies)); return { fixture: 'merged-success-policy' }; },
      } }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script('Date.now = () => globalThis.__platform.now();').runInContext(this.context, { timeout: 200 });
    this.sourceRecords = new Map(); this.importBindings = new Map(); this.dynamicImports = [];
  }

  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const source = relative(this.root, file);
    assert.ok(wholeSources.includes(source), `declared whole source: ${source}`);
    const bytes = readFileSync(file);
    assert.equal(hash(bytes), this.tracked.get(source), source);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(bytes), executed: true, wholeModule: true,
      transformation: transform, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: specifier => {
        this.dynamicImports.push({ importer: source, specifier });
        throw Error(`Undeclared image dynamic import: ${source} -> ${specifier}`);
      } });
    this.modules.set(file, mod);
    return mod;
  }

  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:image-generation:' + key, code);
  }

  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module',
      source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }

  alias(importer, specifier, source, exports, origin) {
    return this.binding(importer, specifier, 'whole-source-export-alias', exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:' + source)};`,
      { source, sourceSha256: this.tracked.get(source), ...(origin ? { origin, originSha256: this.tracked.get(origin) } : {}) });
  }

  projection(importer, specifier, source, startMarker, endMarker, prelude, exports) {
    const original = readFileSync(join(this.root, source));
    assert.equal(hash(original), this.tracked.get(source));
    const start = original.indexOf(startMarker);
    const end = original.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start, source);
    assert.equal(original.indexOf(startMarker, start + 1), -1, 'unique original source region');
    const selected = original.subarray(start, end);
    const generated = prelude + '\n' + selected.toString();
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(original), executed: true, wholeModule: false,
      projection: { startByte: start, endByte: end, sourceRegionSha256: hash(selected), prelude,
        generatedCode: generated, generatedSha256: hash(generated) },
      transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-region-projection', exports, executable,
      { source, sourceSha256: this.tracked.get(source) });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:image-generation:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:image-generation:') && specifier === 'capture:deadlines') {
      return this.projection(parent, specifier, deadlines,
        'export function createProviderOperationDeadline(', '/** Resolves a static or lazy request timeout',
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError']);
    }
    if (importer === models && specifier === './openclaw.plugin.json') {
      const bytes = readFileSync(join(this.root, manifest));
      assert.equal(hash(bytes), this.tracked.get(manifest));
      return this.binding(importer, specifier, 'original-json-data-export', ['default'],
        `export default ${JSON.stringify(JSON.parse(bytes.toString()))};`,
        { source: manifest, sourceSha256: hash(bytes), originalSourceExecuted: false,
          boundary: 'Whole original JSON parsed as media model constant data; no registration is executed.' });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/blob-runtime') return this.alias(importer, specifier, blob,
      ['bufferToBlobPart'], blob);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.binding(importer, specifier,
      'whole-source-export-alias', ['createOpenAiCompatibleImageGenerationProvider', 'imageSourceUploadFileName'],
      `export {createOpenAiCompatibleImageGenerationProvider} from 'capture:source:${factory}';\nexport {imageSourceUploadFileName} from 'capture:source:${assets}';`,
      { origin: 'src/plugin-sdk/image-generation.ts', originSha256: this.tracked.get('src/plugin-sdk/image-generation.ts') });
    if ([entry, models, factory].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.alias(importer, specifier, strings,
      ['normalizeOptionalString', 'normalizeOptionalLowercaseString'], 'src/plugin-sdk/string-coerce-runtime.ts');
    if (importer === factory && specifier === '../media/configured-max-bytes.js') return this.projection(importer, specifier, caps,
      'const MB = 1024 * 1024;', '/** Reads channel/account media caps',
      `import {maxBytesForKind} from 'capture:source:packages/media-core/src/constants.ts';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if (importer === factory && specifier === '../plugin-sdk/provider-auth-runtime.js') return this.binding(importer, specifier,
      'successful-explicit-key-fixture', ['resolveApiKeyForProvider'],
      `export async function resolveApiKeyForProvider(params){globalThis.__platform.keyCall(params);return {apiKey:'synthetic-explicit-key'};}`,
      { source: 'src/plugin-sdk/provider-auth-runtime.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth-runtime.ts'), originalSourceExecuted: false,
        boundary: 'Explicit successful key service only; account/profile discovery is not executed.' });
    if (importer === factory && specifier === '../plugins/provider-auth-availability.js') return this.binding(importer, specifier,
      'uninvoked-availability-fixture', ['isProviderApiKeyConfigured', 'isProviderApiKeyConfiguredAsync'],
      `export function isProviderApiKeyConfigured(){throw Error('Uninvoked image availability lookup');}\nexport async function isProviderApiKeyConfiguredAsync(){throw Error('Uninvoked async image availability lookup');}`,
      { source: 'src/plugins/provider-auth-availability.ts', sourceSha256: this.tracked.get('src/plugins/provider-auth-availability.ts'), originalSourceExecuted: false });
    if (importer === factory && specifier === '../plugin-sdk/provider-http.js') return this.binding(importer, specifier,
      'successful-transport-config-status-reader-fixture',
      ['assertOkOrThrowHttpError', 'createProviderOperationDeadline', 'postJsonRequest', 'postMultipartRequest',
        'readProviderJsonResponse', 'resolveProviderHttpRequestConfig', 'resolveProviderOperationTimeoutMs', 'sanitizeConfiguredModelProviderRequest'],
      `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs} from 'capture:deadlines';
export const postJsonRequest=globalThis.__platform.post;
export const postMultipartRequest=globalThis.__platform.post;
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const readProviderJsonResponse=globalThis.__platform.readJson;
export const resolveProviderHttpRequestConfig=globalThis.__platform.config;
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;`,
      { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
        boundary: 'Real complete deadline functions re-exported; successful JSON/multipart POST, sanitizer, request resolver, status and reader are explicitly named facades. Request-policy normalization does not execute.' });
    if (importer === urls && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier,
      'successful-native-binary-status-reader-fixture', ['assertOkOrThrowHttpError', 'readProviderBinaryResponse'],
      'export const assertOkOrThrowHttpError=globalThis.__platform.status;\nexport const readProviderBinaryResponse=globalThis.__platform.readBinary;',
      { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    if (importer === urls && specifier === '../infra/net/fetch-guard.js') return this.binding(importer, specifier,
      'successful-native-download-fixture', ['fetchWithSsrFGuard'], 'export const fetchWithSsrFGuard=globalThis.__platform.get;',
      { source: 'src/infra/net/fetch-guard.ts', sourceSha256: this.tracked.get('src/infra/net/fetch-guard.ts'), originalSourceExecuted: false });
    if (importer === urls && specifier === '../infra/net/ssrf.js') return this.binding(importer, specifier,
      'successful-policy-attribution-fixture', ['mergeSsrFPolicies'], 'export const mergeSsrFPolicies=globalThis.__platform.policy;',
      { source: 'src/infra/net/ssrf.ts', sourceSha256: this.tracked.get('src/infra/net/ssrf.ts'), originalSourceExecuted: false,
        boundary: 'Policy inputs are recorded as successful service attribution; no policy implementation is executed.' });
    const packages = { '@openclaw/media-core/base64': 'packages/media-core/src/base64.ts',
      '@openclaw/media-core/constants': 'packages/media-core/src/constants.ts',
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared image-generation import: ${importer} -> ${specifier}`);
  }

  sanitize(request) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null,
      implementation: 'successful-configured-request-sanitizer-facade' });
    return output;
  }

  config(params) {
    const headers = new Headers(params.defaultHeaders);
    for (const [key, value] of Object.entries(this.current.services.resolvedHeaders ?? {})) headers.set(key, value);
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, transport: params.transport,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl, request: params.request ?? null,
      output: { baseUrl: params.baseUrl, headers: Object.fromEntries(headers) },
      implementation: 'successful-provider-http-request-config-facade' });
    return { baseUrl: params.baseUrl, headers, allowPrivateNetwork: params.allowPrivateNetwork };
  }

  async post(params) {
    let body;
    if (params.body instanceof FormData) {
      body = [];
      for (const [name, value] of params.body.entries()) {
        body.push(typeof value === 'string' ? { name, value } : {
          name, fileName: value.name, mimeType: value.type,
          size: value.size, bytesBase64: Buffer.from(await value.arrayBuffer()).toString('base64') });
      }
    } else body = plain(params.body);
    const multipart = params.body instanceof FormData;
    const receipt = { url: params.url, method: 'POST', kind: multipart ? 'multipart' : 'json', body,
      ...(multipart ? { multipartBoundary: { rawHttpExecuted: false, format: 'ordered native FormData fields and exact Blob bytes/name/type; no generated HTTP boundary compared' } } : { jsonBody: plain(params.body) }),
      headers: Object.fromEntries(params.headers), ...(params.timeoutMs !== undefined ? { timeoutMs: params.timeoutMs } : {}), atMs: this.current.now, releaseCount: 0 };
    this.current.request = receipt; this.current.now += 7;
    const responseBytes = this.current.response.rawChunks
      ? this.current.response.rawChunks.map(chunk => Buffer.from(chunk, 'base64'))
      : [Buffer.from(JSON.stringify(this.current.response.json))];
    const stream = new ReadableStream({ start(controller) {
      for (const bytes of responseBytes) controller.enqueue(bytes);
      controller.close();
    } });
    return { response: new Response(stream, { status: 200, headers: { 'content-type': 'application/json' } }),
      release: async () => { receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now; } };
  }

  async download(params) {
    const fixture = this.current.downloadFixtures[this.current.downloads.length];
    assert.ok(fixture, 'declared successful image download');
    assert.equal(params.url, fixture.url);
    const receipt = { ...fixture, url: params.url, method: params.init.method, timeoutMs: params.timeoutMs,
      atMs: this.current.now, releaseCount: 0 };
    this.current.downloads.push(receipt); this.current.now += 11;
    return { response: new Response(Buffer.from(fixture.bodyBase64, 'base64'), { status: 200,
      headers: { 'content-type': fixture.contentType } }),
      release: async () => { receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now; } };
  }

  async run(vector) {
    this.current = { response: plain(vector.response), downloadFixtures: plain(vector.downloads), downloads: [],
      services: plain(vector.services ?? {}), request: undefined, readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], policyCalls: [], now: 100000 };
    this.context.__platform.keyCall = params => { this.current.keyCalls.push({ provider: params.provider }); };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) =>
      ({ ...image, ...(bytesBase64 !== undefined ? { buffer: Buffer.from(bytesBase64, 'base64') } : {}) }));
    const req = { ...input, provider: 'deepinfra', cfg: { models: { providers: { deepinfra: { baseUrl: vector.config.baseUrl, ...(vector.config.request ? { request: vector.config.request } : {}) } } },
      ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildDeepInfraImageGenerationProvider().generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Image fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) =>
        ({ ...image, ...(buffer ? { bytesBase64: buffer.toString('base64') } : {}) }));
      const inputAfter = plain(after);
      assert.deepEqual(inputAfter, vector.input);
      assert.equal(this.current.downloads.length, vector.downloads.length);
      assert.ok(this.current.downloads.every(row => row.releaseCount === 1));
      assert.equal(this.current.request.releaseCount, 1);
      const { downloads: _fixtures, ...portable } = vector;
      return { ...portable, inputAfter, request: this.current.request, downloads: this.current.downloads,
        releaseCount: this.current.request.releaseCount,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls,
        configCalls: this.current.configCalls, sanitizeCalls: this.current.sanitizeCalls, keyCalls: this.current.keyCalls, policyCalls: this.current.policyCalls,
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { post: 7, jsonRead: 3, download: 11, binaryRead: 13 } } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureDeepInfraImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ImageGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const providerDescriptor = harness.call('(()=>{const {generateImage,isConfigured,isConfiguredAsync,...descriptor}=__exports.buildDeepInfraImageGenerationProvider();return descriptor;})()');
  const constructorObservations = [
    { id: 'source-only-empty-catalog', hostComparable: false, options: { imageGenModels: [] } },
    { id: 'source-only-custom-catalog', hostComparable: false, options: { imageGenModels: [
      { id: 'Vendor/First', name: 'First', tags: ['image'], pricing: { per_image_unit: 0.01 } },
      { id: 'Other/Second', name: 'Second', tags: [], pricing: {} } ] } },
  ].map(row => {
    harness.context.__options = plain(row.options);
    return { ...row, adaptationReason: 'Constructor-only source catalog input; no host catalog/config discovery claim.',
      descriptor: harness.call('(()=>{const {generateImage,isConfigured,isConfiguredAsync,...descriptor}=__exports.buildDeepInfraImageGenerationProvider(__options);return descriptor;})()') };
  });
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: DEEPINFRA_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-deepinfra-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    serviceFacadeLedger: [
      { name: 'resolveApiKeyForProvider', executed: false, kind: 'successful-explicit-key-fixture', limit: 'Synthetic explicit key only; credential/profile/config discovery unexecuted.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, kind: 'successful-configured-request-sanitizer-facade', limit: 'Records argument and returns only literal per-vector output; actual request policy/sanitization unexecuted.' },
      { name: 'resolveProviderHttpRequestConfig', executed: false, kind: 'successful-provider-http-request-config-facade', limit: 'Accepts source-normalized URL, native Headers(defaultHeaders), optional literal header output; actual configured-header/request normalization unexecuted.' },
      { name: 'postJsonRequest/postMultipartRequest/fetchWithSsrFGuard', executed: false, kind: 'successful-transport-fixture', limit: 'Records actual source JSON or native FormData/Blob plus GET; native Response only, no raw HTTP/network.' },
      { name: 'assertOkOrThrowHttpError/readProviderJsonResponse/readProviderBinaryResponse', executed: false, kind: 'successful-status-reader-fixture', limit: 'Native Response.json/arrayBuffer under status 200, no production bounded reader or failed status semantics.' },
      { name: 'mergeSsrFPolicies', executed: false, kind: 'successful-policy-attribution-fixture', limit: 'Records successful input attribution only; no policy/permission semantics exercised.' },
    ],
    limits: [
      'Complete unchanged DeepInfra image-generation-provider and media-models execute with original JSON manifest data; whole shared OpenAI-compatible factory, image-assets, URL inliner, blob-runtime, base64/constants and normalization modules execute. Two complete original source regions supply cap helpers and deadline functions with exact byte spans and source/generated/executable hashes.',
      'All 58,558 tracked reference blobs, modes and symlinks are verified before and after. Explicit imports, original JSON data, exporter, unchanged shared FactoryHarness and fixed Node24.22.1 runtime have receipts. Registration and provenance-only SDK/request-policy/service modules do not execute.',
      'Real source request/count/model/size/MIME/filename/ordered response transformations execute. Native Node FormData and Blob retain ordered fields and exact file bytes/type/name; raw HTTP multipart serialization/boundary is outside this abstraction.',
      'Real deadline helpers use deterministic Date.now; successful service POST/GET/status/key/config/sanitize/read bodies are named facades. Native Response.json consumes successful raw chunks including BOM. Byte caps are observed parameters; production bounded stream reader and real network unexecuted.',
      'Configured-request helpers were inspected but not executed. The sole configured-header row is hostComparable=false and consumes explicit literal successful outputs. No claim of header policy normalization, auth, security, permissions, TLS, proxy or private-network behavior.',
      'Source-only omitted model/timeout row is hostComparable=false: source fallback model is black-forest-labs/FLUX-1-schnell, total read deadline is 60000ms, POST timeoutMs is absent. Host comparison requires explicit effective configuration, model and finite timeout; no saved policy/default-provider claim.',
      'Tiny protocol bytes establish exact byte/MIME/order projection, not codec validity or visual quality. Only canonical padded/unpadded/whitespace Base64 ordinary success rows; no mixed, overflow, negative/failure/cancel/crash or real-provider execution.',
      'Inactive independent source oracle only; no tool/catalog enablement, durable media/jobs/storage/delivery, real-provider evidence or complete P10/reference-goal claim.',
    ], providerDescriptor, constructorObservations, observations };

}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-deepinfra-image-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureDeepInfraImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
