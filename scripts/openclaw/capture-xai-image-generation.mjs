// Complete pinned xAI image provider and shared factory/helpers under synthetic successful I/O.
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

export const XAI_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/xai/image-generation-provider.ts';
const factory = 'src/image-generation/openai-compatible-image-provider.ts';
const assets = 'src/image-generation/image-assets.ts';
const urls = 'src/image-generation/openai-compatible-image-urls.ts';
const metadata = 'extensions/xai/capability-provider-metadata.ts';
const metadataFactory = 'extensions/xai/capability-provider-metadata-factory.ts';
const models = 'extensions/xai/model-definitions.ts';
const manifest = 'extensions/xai/openclaw.plugin.json';
const caps = 'src/media/configured-max-bytes.ts';
const deadlines = 'src/media-understanding/shared.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, factory, assets, urls, number, strings, records,
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts'];
const provenancePaths = [metadata, manifest, 'src/plugin-sdk/image-generation.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugins/provider-auth-availability.ts',
  'src/agents/provider-http-errors.ts', 'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts',
  'extensions/xai/index.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), XAI_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', XAI_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: XAI_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${XAI_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = Buffer.from([255, 216, 255, 224, 0, 16, 74, 70, 73, 70]).toString('base64');
const opaque = Buffer.from('opaque image protocol bytes').toString('base64');
const ratios = ['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3', '2:1', '1:2', '19.5:9', '9:19.5', '20:9', '9:20'];
function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt: ' Draw a small blue square. ', ...(options.defaults ? {} : { model: 'grok-imagine-image', timeoutMs: 30000 }), ...input },
    config: { baseUrl: 'https://api.x.ai/v1', ...options.config },
    response: { json: options.json ?? { data: [{ b64_json: png }] } },
    downloads: options.downloads ?? [] });
  const inline = (bytes = png, extra = {}) => ({ b64_json: bytes, ...extra });
  const url = index => `https://assets.example.test/image-${index}`;
  const download = (index, contentType = 'image/png', bodyBase64 = png) => ({ url: url(index), contentType, bodyBase64 });
  return [
    base('default-count'),
    base('explicit-model-prompt', { model: ' Vendor/Image-X ', prompt: '  Preserve this exact prompt.\n' }),
    base('count-four', { count: 4 }),
    base('count-seven-clamped', { count: 7 }),
    ...ratios.map(ratio => base('aspect-' + ratio.replaceAll(':', '-'), { aspectRatio: ` ${ratio} ` })),
    base('unsupported-aspect-omitted', { aspectRatio: ' 5:4 ' }),
    base('resolution-1k', { resolution: ' 1K ' }),
    base('resolution-2k', { resolution: ' 2K ' }),
    base('resolution-custom', { resolution: ' Ultra-HD ' }),
    base('unused-options', { size: '1024x768', quality: 'high', outputFormat: 'jpeg', background: 'opaque',
      providerOptions: { xai: { outputFormat: 'webp', quality: 'low' } } }),
    base('edit-url', { inputImages: [{ url: ' https://assets.example.test/input-one ', fileName: 'first.png' }] }),
    base('edit-bytes-default-mime', { inputImages: [{ bytesBase64: opaque, fileName: 'opaque.jpg' }] }),
    base('edit-bytes-explicit-mime', { inputImages: [{ bytesBase64: jpeg, mimeType: ' Image/JPEG; mode=RGB ', fileName: 'input.jpg' }] }),
    base('edit-url-preferred', { inputImages: [{ url: ' https://assets.example.test/preferred ', bytesBase64: png, mimeType: 'image/png' }] }),
    base('edit-three-ordered', { inputImages: [{ url: ' https://assets.example.test/one ' },
      { bytesBase64: jpeg, mimeType: ' image/jpeg ', fileName: 'two.jpg' }, { bytesBase64: opaque }] }),
    base('custom-base', { model: ' Custom/Model ' }, { config: { baseUrl: ' https://images.example.test/custom/v2/// ' } }),
    base('javascript-whitespace', { model: '\uFEFFVendor/Image-X\u00a0', aspectRatio: '\uFEFF16:9\u00a0', resolution: '\uFEFF2K\u00a0' },
      { config: { baseUrl: '\uFEFFhttps://images.example.test/js/v3///\u00a0' } }),
    base('ordered-inline-mime-prompts', {}, { json: { data: [inline(png, { revised_prompt: ' First ' }),
      inline(jpeg, { mime_type: ' Image/JPEG; mode=RGB ', revised_prompt: ' \t ' }),
      inline(opaque, { mime_type: 'image/webp', revised_prompt: ' Third ' })], usage: { total_tokens: 42 }, metadata: { ignored: true } } }),
    base('base64-unpadded', {}, { json: { data: [inline(png.replace(/=+$/, ''))] } }),
    base('base64-whitespace', {}, { json: { data: [inline(' \n' + png.slice(0, 12) + ' \t' + png.slice(12) + '\n ')] } }),
    base('jpeg-default-png-no-sniff', {}, { json: { data: [inline(jpeg)] } }),
    base('opaque-default-png', {}, { json: { data: [inline(opaque)] } }),
    base('six-inline-preserved', { count: 7 }, { json: { data: Array.from({ length: 6 }, (_, index) => inline(png, { revised_prompt: ` Item ${index + 1} ` })) } }),
    base('four-ordered-downloads', {}, { json: { data: [1, 2, 3, 4].map(index => ({ url: ` ${url(index)} `, revised_prompt: ` Download ${index} ` })) },
      downloads: [download(1, 'Image/JPEG; mode=RGB', jpeg), download(2, 'image/webp; charset=binary', opaque), download(3), download(4, 'IMAGE/AVIF; codec=av1', opaque)] }),
    base('mixed-inline-downloads', {}, { json: { data: [inline(png), { url: url(2) }, inline(jpeg, { mime_type: 'image/jpeg' }), { url: url(4) }] },
      downloads: [download(2, 'image/webp', opaque), download(4)] }),
    base('inline-preferred-over-url', {}, { json: { data: [inline(png, { url: url(1) })] } }),
    base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
    base('media-cap-larger', {}, { config: { mediaMaxMb: 80.25 } }),
    base('source-only-default-model-timeout', {}, { defaults: true, hostComparable: false,
      adaptationReason: 'Pinned source supplies grok-imagine-image and 600000ms; Synapsis requires explicit model and finite total timeout.' }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, URL,
      fetch: () => { throw Error('Network is outside this image fixture boundary'); },
      __platform: { now: () => this.current.now, post: params => this.post(params),
        config: params => this.config(params), get: params => this.download(params),
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
    if (parent.startsWith('capture:image-generation:') && specifier === 'capture:image-models') return this.projectedModels(parent, specifier);
    if (importer === entry && specifier === './model-definitions.js') return this.projectedModels(importer, specifier);
    if (parent.startsWith('capture:image-generation:') && specifier === 'capture:manifest') {
      const bytes = readFileSync(join(this.root, manifest));
      assert.equal(hash(bytes), this.tracked.get(manifest));
      return this.binding(parent, specifier, 'original-json-data-export', ['default'],
        `export default ${JSON.stringify(JSON.parse(bytes.toString()))};`,
        { source: manifest, sourceSha256: hash(bytes), originalSourceExecuted: false,
          boundary: 'Whole original JSON parsed as model constant data; no registration is executed.' });
    }
    if (importer === entry && specifier === './capability-provider-metadata.js') {
      return this.projection(importer, specifier, metadataFactory,
        'export const XAI_IMAGE_DEFAULT_TIMEOUT_MS =', 'export function createXaiMediaUnderstandingProviderMetadata()',
        `import {XAI_DEFAULT_IMAGE_MODEL,XAI_IMAGE_MODELS} from 'capture:image-models';`,
        ['XAI_IMAGE_DEFAULT_TIMEOUT_MS', 'XAI_SUPPORTED_IMAGE_ASPECT_RATIOS', 'createXaiImageGenerationProviderMetadata']);
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.binding(importer, specifier,
      'whole-source-export-alias', ['createOpenAiCompatibleImageGenerationProvider', 'resolveImageSourceUrl'],
      `export {createOpenAiCompatibleImageGenerationProvider} from 'capture:source:${factory}';\nexport {resolveImageSourceUrl} from 'capture:source:${assets}';`,
      { origin: 'src/plugin-sdk/image-generation.ts', originSha256: this.tracked.get('src/plugin-sdk/image-generation.ts') });
    if ([entry, factory].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.alias(importer, specifier, strings,
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
export async function postMultipartRequest(){throw Error('Uninvoked image multipart transport');}
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const readProviderJsonResponse=globalThis.__platform.readJson;
export const resolveProviderHttpRequestConfig=globalThis.__platform.config;
export function sanitizeConfiguredModelProviderRequest(){throw Error('Uninvoked configured-request sanitizer');}`,
      { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
        boundary: 'Real complete deadline functions re-exported; lower successful POST/config/status/reader bodies are facades.' });
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

  projectedModels(importer, specifier) {
    return this.projection(importer, specifier, models,
      'export const XAI_BASE_URL =', 'export const XAI_DEFAULT_CONTEXT_WINDOW =',
      `import manifest from 'capture:manifest';`, ['XAI_BASE_URL', 'XAI_DEFAULT_IMAGE_MODEL', 'XAI_IMAGE_MODELS']);
  }

  config(params) {
    this.current.configCalls.push({ provider: params.provider, capability: params.capability,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl });
    return { baseUrl: params.baseUrl.trim(), headers: new Headers(params.defaultHeaders),
      allowPrivateNetwork: params.allowPrivateNetwork };
  }

  async post(params) {
    const receipt = { url: params.url, method: 'POST', body: plain(params.body), jsonBody: plain(params.body),
      headers: Object.fromEntries(params.headers), timeoutMs: params.timeoutMs, atMs: this.current.now, releaseCount: 0 };
    this.current.request = receipt; this.current.now += 7;
    return { response: new Response(JSON.stringify(this.current.response.json), { status: 200,
      headers: { 'content-type': 'application/json' } }),
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
      request: undefined, readerCalls: [], statusCalls: [], configCalls: [], keyCalls: [], policyCalls: [], now: 100000 };
    this.context.__platform.keyCall = params => { this.current.keyCalls.push({ provider: params.provider }); };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) =>
      ({ ...image, ...(bytesBase64 !== undefined ? { buffer: Buffer.from(bytesBase64, 'base64') } : {}) }));
    const req = { ...input, provider: 'xai', cfg: { models: { providers: { xai: { baseUrl: vector.config.baseUrl } } },
      ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildXaiImageGenerationProvider().generateImage(__req)').runInContext(this.context, { timeout: 1000 });
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
        configCalls: this.current.configCalls, keyCalls: this.current.keyCalls, policyCalls: this.current.policyCalls,
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { post: 7, jsonRead: 3, download: 11, binaryRead: 13 } } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureXaiImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ImageGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const providerDescriptor = harness.call('(()=>{const {generateImage,isConfigured,isConfiguredAsync,...descriptor}=__exports.buildXaiImageGenerationProvider();return descriptor;})()');
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: XAI_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-xai-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    limits: [
      'Complete unchanged 83-line xAI provider, whole OpenAI-compatible factory, whole image-assets and whole URL inliner execute. Whole base64, constants, number and string/record normalization modules execute; four complete original source regions supply metadata constants/full image metadata function, model constants, generated-image cap helpers and deadline functions, each with original byte spans and source/generated/executable hashes.',
      'All 58,558 tracked reference blobs, modes and symlinks are verified before and after. Explicit import bindings, original JSON model data, exporter, unchanged shared FactoryHarness and fixed Node runtime are hashed; provenance-only registration/SDK/service modules are not executed.',
      'Real deadline functions run against deterministic Date.now. Successful POST, GET, status, explicit-key/config, policy attribution and body-read facades use native Headers/URL/Response/json/arrayBuffer, advancing the clock and recording actual remaining budgets. No real network or production bounded stream reader is executed; byte caps are recorded parameters.',
      'The source-only-default-model-timeout vector is hostComparable=false: original source defaults are grok-imagine-image and 600000ms, while the host requires explicit model and finite timeout.',
      'Tiny protocol bytes prove byte/MIME/order projection, not codec validity or visual quality. Standard canonical/unpadded/whitespace Base64 positive cases exercise the original general helper; no URL-safe acceptance claim.',
      'Inactive independent source oracle only: no tool/catalog/config enablement, durable media/jobs/storage/delivery integration, real-provider behavior or full P10/reference-goal completion.',
    ], providerDescriptor, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-xai-image-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureXaiImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
