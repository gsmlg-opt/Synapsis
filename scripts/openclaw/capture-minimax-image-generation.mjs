// Whole pinned MiniMax image/media modules and postJsonResponse under named successful I/O facades.
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

export const MINIMAX_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/minimax/image-generation-provider.ts';
const mediaRuntime = 'extensions/minimax/media-provider-runtime.ts';
const postResponse = 'src/media-understanding/provider-json-post.ts';
const assets = 'src/image-generation/image-assets.ts';
const caps = 'src/media/configured-max-bytes.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const base64 = 'packages/media-core/src/base64.ts';
const constants = 'packages/media-core/src/constants.ts';
const registration = 'extensions/minimax/index.ts';
const manifest = 'extensions/minimax/openclaw.plugin.json';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, mediaRuntime, postResponse, assets, strings, records, base64, constants];
const provenancePaths = [registration, manifest, 'src/plugin-sdk/image-generation.ts',
  'src/plugin-sdk/media-generation-runtime.ts', 'src/plugin-sdk/media-runtime.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/media-understanding/shared.ts', 'src/agents/provider-http-errors.ts',
  'src/plugins/provider-auth-availability.ts', 'src/agents/provider-request-config.ts',
  'src/infra/net/ssrf.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MINIMAX_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MINIMAX_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: MINIMAX_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${MINIMAX_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const defaultBase = 'https://api.minimax.io';
function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, providerId: options.providerId ?? 'minimax',
    hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt: ' Draw a small blue square. ', ...(options.defaults ? {} : { model: 'image-01', timeoutMs: 30000 }), ...input },
    config: { baseUrl: 'https://api.minimax.io/anthropic', effectiveBaseUrl: defaultBase, ...options.config },
    response: { json: options.json ?? { data: { image_base64: [png] } } },
    ...(options.services ? { services: options.services } : {}) });
  return [
    base('default-count'),
    base('explicit-model-prompt', { model: ' Vendor/Image-X ', prompt: '  Preserve this exact prompt.\n' }),
    base('minimax-prefixed-model', { model: ' minimax/image-01 ' }),
    base('portal-provider', {}, { providerId: 'minimax-portal' }),
    base('count-one', { count: 1 }),
    base('count-nine', { count: 9 }),
    ...['1:1', '16:9', '4:3', '3:2', '2:3', '3:4', '9:16', '21:9'].map(ratio =>
      base('aspect-' + ratio.replace(':', '-'), { aspectRatio: ratio })),
    base('aspect-js-trim', { aspectRatio: '\uFEFF 16:9\u00a0' }),
    base('input-default-mime', { inputImages: [{ bytesBase64: jpeg }] }),
    base('input-raw-mime-filename-ignored', { inputImages: [{ bytesBase64: png, mimeType: ' Image/PNG; Mode=RGB ', fileName: ' 绘图/输入.png ' }] }),
    base('ordered-opaque-results', { count: 9 }, { json: { data: { image_base64: [jpeg, webp, opaque, png] } } }),
    base('base64-unpadded', {}, { json: { data: { image_base64: [png.replace(/=+$/, '')] } } }),
    base('base64-whitespace', {}, { json: { data: { image_base64: [' \n' + png.slice(0, 12) + ' \t' + png.slice(12) + '\n '] } } }),
    base('metadata-ignored', {}, { json: { data: { image_base64: [png], ignored: 'data metadata' },
      metadata: { success_count: 27, failed_count: 0, mime_type: 'image/jpeg' }, id: 'ignored-response-id',
      base_resp: { status_code: 0, status_msg: 'normal success' }, model: 'ignored-response-model',
      usage: { total_tokens: 42 } } }),
    base('configured-cn-region', {}, { config: { baseUrl: ' https://api.minimaxi.com/anthropic ', effectiveBaseUrl: 'https://api.minimaxi.com' } }),
    base('portal-configured-cn-region', {}, { providerId: 'minimax-portal',
      config: { baseUrl: 'https://api.minimaxi.com/v1', effectiveBaseUrl: 'https://api.minimaxi.com' } }),
    base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
    base('media-cap-larger', {}, { config: { mediaMaxMb: 80.25 } }),
    base('source-only-default-model-timeout', {}, { defaults: true, hostComparable: false,
      adaptationReason: 'Source fallback model image-01 and absent POST timeout only. Host protocol requires explicit effective model and finite timeout; lower HTTP timeout defaults do not execute.' }),
    base('source-only-configured-header', {}, { hostComparable: false,
      adaptationReason: 'Source consumes literal successful sanitizer/config outputs; actual configured-header/request normalization does not execute.',
      config: { request: { headers: { 'X-Fixture-Render': ' normal ' } } },
      services: { sanitizedRequest: { headers: { 'X-Fixture-Render': 'normal' } }, resolvedHeaders: { 'X-Fixture-Render': 'normal' } } }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, Uint8Array, Headers, Response, URL,
      process: Object.freeze({ env: Object.freeze({}) }),
      fetch: () => { throw Error('Network is outside this image fixture boundary'); },
      __platform: { post: params => this.post(params), config: params => this.config(params),
        sanitize: request => this.sanitize(request),
        status: async (response, label, options) => {
          assert.equal(response.status, 200);
          this.current.statusCalls.push({ label, options: options ?? null, atMs: this.current.now });
        },
        readJson: async (response, label, options) => {
          this.current.readerCalls.push({ kind: 'json', label, maxBytes: options.maxBytes, atMs: this.current.now });
          this.current.request.maxBytes = options.maxBytes;
          const result = await response.json(); this.current.now += 3; return result;
        },
      } }, { codeGeneration: { strings: false, wasm: false } });
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
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.alias(importer, specifier,
      assets, ['resolveInlineImageJsonResponseMaxBytes'], 'src/plugin-sdk/image-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') return this.projection(importer, specifier, caps,
      'const MB = 1024 * 1024;', '/** Reads channel/account media caps',
      `import {maxBytesForKind} from 'capture:source:${constants}';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-runtime') return this.alias(importer, specifier,
      base64, ['canonicalizeBase64'], 'src/plugin-sdk/media-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') return this.binding(importer, specifier,
      'uninvoked-availability-facade', ['isProviderApiKeyConfiguredAsync'],
      `export async function isProviderApiKeyConfiguredAsync(){throw Error('Uninvoked MiniMax image availability lookup');}`,
      { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http') return this.alias(importer, specifier,
      postResponse, ['postJsonResponse'], 'src/plugin-sdk/provider-http.ts');
    if (importer === mediaRuntime && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.binding(importer, specifier,
      'whole-source-export-alias', ['asOptionalRecord', 'normalizeOptionalString', 'readStringField'],
      `export {asOptionalRecord,readStringField} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`,
      { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    if (importer === mediaRuntime && specifier === 'openclaw/plugin-sdk/provider-http') return this.binding(importer, specifier,
      'successful-config-sanitizer-and-uninvoked-transport-facades',
      ['assertOkOrThrowHttpError', 'executeProviderOperationWithRetry', 'fetchWithTimeoutGuarded',
        'resolveProviderApiKeyHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest'],
      `export const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export function executeProviderOperationWithRetry(){throw Error('Uninvoked MiniMax image retry service');}
export function fetchWithTimeoutGuarded(){throw Error('Uninvoked MiniMax image guarded fetch service');}`,
      { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
        boundary: 'Credentials/config/request policy/sanitization are explicitly successful literal facades; retry and guarded fetch stay uninvoked.' });
    if (importer === postResponse && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier,
      'successful-status-and-native-json-reader-facades',
      ['assertOkOrThrowHttpError', 'readProviderJsonObjectResponse', 'readProviderJsonResponse'],
      `export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const readProviderJsonResponse=globalThis.__platform.readJson;
export function readProviderJsonObjectResponse(){throw Error('Uninvoked MiniMax image object-only reader');}`,
      { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    if (importer === postResponse && specifier === './shared.js') return this.binding(importer, specifier,
      'successful-post-transport-facade', ['postJsonRequest'], 'export const postJsonRequest=globalThis.__platform.post;',
      { source: 'src/media-understanding/shared.ts', sourceSha256: this.tracked.get('src/media-understanding/shared.ts'), originalSourceExecuted: false });
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared MiniMax image import: ${importer} -> ${specifier}`);
  }

  sanitize(request) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null,
      implementation: 'successful-configured-request-sanitizer-facade' });
    return output;
  }

  config(params) {
    const headers = new Headers({ Authorization: 'Bearer synthetic-explicit-key', 'Content-Type': 'application/json',
      ...this.current.services.resolvedHeaders });
    const output = { baseUrl: params.baseUrl, headers: Object.fromEntries(headers) };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl, jsonContentType: params.jsonContentType,
      missingApiKeyMessage: params.missingApiKeyMessage, request: params.request ?? null, output,
      implementation: 'successful-explicit-credential-http-config-policy-facade' });
    this.current.keyCalls.push({ provider: params.provider, implementation: 'literal-synthetic-credential-in-config-facade' });
    return { baseUrl: params.baseUrl, headers };
  }

  async post(params) {
    const receipt = { url: params.url, method: 'POST', body: plain(params.body), headers: Object.fromEntries(params.headers),
      ...(params.timeoutMs !== undefined ? { timeoutMs: params.timeoutMs } : {}), atMs: this.current.now, releaseCount: 0 };
    this.current.request = receipt; this.current.now += 7;
    return { response: new Response(JSON.stringify(this.current.response.json), { status: 200, headers: { 'content-type': 'application/json' } }),
      release: async () => {
        receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now;
        this.current.releaseCalls.push({ atMs: this.current.now, releaseCount: receipt.releaseCount });
      } };
  }

  async run(vector) {
    this.current = { response: plain(vector.response), services: plain(vector.services ?? {}),
      request: undefined, readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], releaseCalls: [], now: 100000 };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) =>
      ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') }));
    const req = { ...input, cfg: { models: { providers: { [vector.providerId]: {
      baseUrl: vector.config.baseUrl, ...(vector.config.request ? { request: vector.config.request } : {}) } } },
      ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req; this.context.__providerId = vector.providerId;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildMinimaxImageGenerationProvider(__providerId).generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('MiniMax image fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) =>
        ({ ...image, bytesBase64: buffer.toString('base64') }));
      const inputAfter = plain(after);
      assert.deepEqual(inputAfter, vector.input);
      assert.equal(this.current.request.releaseCount, 1);
      assert.equal(this.current.configCalls[0].baseUrl, vector.config.effectiveBaseUrl);
      return { ...vector, inputAfter, request: this.current.request,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        releaseCount: this.current.request.releaseCount, releaseCalls: this.current.releaseCalls,
        readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls,
        configCalls: this.current.configCalls, sanitizeCalls: this.current.sanitizeCalls, keyCalls: this.current.keyCalls,
        clock: { kind: 'synthetic-service-clock', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { post: 7, jsonRead: 3 } } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureMinimaxImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ImageGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const providerDescriptors = ['minimax', 'minimax-portal'].map(providerId => {
    harness.context.__providerId = providerId;
    return harness.call('(()=>{const {generateImage,isConfiguredAsync,...descriptor}=__exports.buildMinimaxImageGenerationProvider(__providerId);return descriptor;})()');
  });
  const registrationText = readFileSync(join(root, registration), 'utf8');
  const registrationCalls = [
    'api.registerImageGenerationProvider(buildMinimaxImageGenerationProvider());',
    'api.registerImageGenerationProvider(buildMinimaxImageGenerationProvider("minimax-portal"));',
  ];
  for (const call of registrationCalls) assert.ok(registrationText.includes(call));
  const manifestData = JSON.parse(readFileSync(join(root, manifest), 'utf8'));
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: MINIMAX_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-minimax-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    vmEnvironment: { processEnv: {}, frozen: true, hostEnvironmentRead: false },
    registrationProvenance: { executed: false, source: registration, sourceSha256: before.tracked.get(registration),
      calls: registrationCalls, manifest, manifestSha256: before.tracked.get(manifest),
      manifestProviders: manifestData.providers, manifestImageGenerationProviders: manifestData.contracts.imageGenerationProviders,
      limit: 'Both IDs register in the same minimax plugin; no separate minimax-portal index or manifest exists at this pin. Registration and plugin assembly do not execute.' },
    serviceFacadeLedger: [
      { name: 'resolveProviderApiKeyHttpRequestConfig', executed: false, kind: 'successful-explicit-credential-http-config-policy-facade', limit: 'Returns literal synthetic Bearer/content-type headers and the source-selected effective base. Credentials/account discovery, HTTP config and policy implementations do not execute.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, kind: 'successful-configured-request-sanitizer-facade', limit: 'Records input and returns only literal per-vector output; configured-request normalization does not execute.' },
      { name: 'postJsonRequest', executed: false, kind: 'successful-post-transport-facade', limit: 'Records source request and returns native status-200 Response with release; no actual HTTP, network, lower timeouts or transport serialization.' },
      { name: 'assertOkOrThrowHttpError/readProviderJsonResponse', executed: false, kind: 'successful-status-and-native-json-reader-facades', limit: 'Native Response.json consumes successful body; actual bounded reader/status behavior is not executed. Byte cap is an observed parameter.' },
      { name: 'isProviderApiKeyConfiguredAsync/executeProviderOperationWithRetry/fetchWithTimeoutGuarded/readProviderJsonObjectResponse', executed: false, kind: 'uninvoked-service-facades', limit: 'Exports exist only for complete module linking and throw if called; availability, retry, other media fetch and object-only reading remain uninvoked.' },
    ],
    limits: [
      'Complete unchanged MiniMax image-generation-provider.ts, media-provider-runtime.ts and provider-json-post.ts execute. Whole image-assets, canonical Base64 module, constants and normalization modules execute. A complete original configured-max-bytes source region supplies cap functions with exact spans and source/generated/executable hashes.',
      'All 58,558 tracked reference blobs, modes and symlinks are verified before and after. Every binding, exporter, unchanged shared FactoryHarness, fixed Node24.22.1 executable and original source has hash receipts. Registration and SDK/service/policy provenance do not execute.',
      'Real source request/model/count/aspect-ratio, raw first-input MIME/data URL, Base64 normalization and ordered PNG result projection execute. Descriptor maxInputImages=1 is metadata. Source review shows callback inputImages.at(0); no multiple-input callback or dispatcher truncation case is executed.',
      'Whole postJsonResponse executes its successful status/read/finally release sequence with named lower POST, status and native JSON reader facades. Production bounded stream reading, HTTP serialization and lower timeout implementation remain unexecuted; caps are observed arguments.',
      'VM process.env is frozen empty and never receives host environment. Ordinary CN region selection uses configured provider baseUrl only, separately recording effectiveBaseUrl for image endpoint protocol comparison. No environment override or credential/account behavior is claimed.',
      'Configured-header and omitted-model/timeout rows are hostComparable=false. The former consumes literal sanitizer/config outputs; the latter observes image-01 and absent POST timeout only. Host comparison requires explicit effective base, model and finite timeout, with no source lower HTTP default claim.',
      'Tiny opaque protocol bytes establish exact byte/MIME/order projection only, not codec validity or image quality. Only ordinary successful padded/unpadded/whitespace Base64 and successful metadata are exercised; no empty/malformed/overflow/negative/failure/cancel/crash/auth/TLS/security/permission or real-provider cases.',
      'Inactive independent source oracle only; no tool/catalog activation, durable media/jobs/storage/delivery, plugin assembly or complete P10/reference-goal claim.',
    ], providerDescriptors, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-minimax-image-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureMinimaxImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
