// Complete pinned Microsoft Foundry image provider under synthetic successful I/O.
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

export const MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/microsoft-foundry/image-generation-provider.ts';
const foundryShared = 'extensions/microsoft-foundry/shared.ts';
const assets = 'src/image-generation/image-assets.ts';
const blob = 'src/plugin-sdk/blob-runtime.ts';
const expect = 'src/plugin-sdk/expect-runtime.ts';
const caps = 'src/media/configured-max-bytes.ts';
const shared = 'src/media-understanding/shared.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const constants = 'packages/media-core/src/constants.ts';
const base64 = 'packages/media-core/src/base64.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, assets, blob, expect, number, strings, records, base64, constants];
const provenancePaths = ['extensions/microsoft-foundry/openclaw.plugin.json',
  'extensions/microsoft-foundry/index.ts', 'extensions/microsoft-foundry/runtime.ts',
  'src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
  'src/plugins/provider-auth-availability.ts', 'src/agents/provider-http-errors.ts',
  'src/agents/provider-request-config.ts', 'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const defaultModel = 'MAI-Image-2.5';
const defaultBase = 'https://foundry.example.test';
function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt: ' Draw a small blue square. ', model: defaultModel,
      ...(options.defaults ? {} : { timeoutMs: 30000 }), ...input },
    config: { baseUrl: defaultBase, ...options.config },
    response: { json: options.json ?? { data: [{ b64_json: png }] } },
    ...(options.services ? { services: options.services } : {}) });
  const edit = (bytesBase64 = png, extra = {}) => ({ inputImages: [{ bytesBase64, ...extra }] });
  const inline = (bytes = png, extra = {}) => ({ data: [{ b64_json: bytes, ...extra }] });
  return [
    base('default-count-size'),
    base('explicit-count-one', { count: 1 }),
    base('model-2.5-flash', { model: 'MAI-Image-2.5-flash' }),
    base('model-2e', { model: 'MAI-Image-2e' }),
    base('model-2', { model: 'MAI-Image-2' }),
    base('model-2-efficient', { model: 'MAI-Image-2-efficient' }),
    base('trimmed-model-prompt', { model: ' MAI-Image-2.5 ', prompt: '  Preserve this exact prompt.\n' }),
    base('prefixed-model', { model: ' microsoft-foundry/Custom/Model ' }),
    base('custom-deployment-generation-metadata', { model: ' draw-prod ' },
      { config: { models: [{ id: 'draw-prod', name: 'MAI-Image-2e' }] } }),
    base('custom-deployment-generation-no-metadata', { model: 'draw-prod' }),
    base('javascript-whitespace', { model: '\uFEFFMAI-Image-2.5\u00a0' },
      { config: { baseUrl: '\uFEFFhttps://foundry.example.test/openai/v1///\u00a0' } }),
    base('size-768', { size: '768x768' }),
    base('size-768x1365', { size: '768x1365' }),
    base('size-1365x768', { size: '1365x768' }),
    base('size-800x1000', { size: '800x1000' }),
    base('size-leading-zeros', { size: '00768x00768' }),
    base('unused-options', { aspectRatio: '16:9', resolution: '2K', quality: 'high', outputFormat: 'jpeg', background: 'opaque',
      providerOptions: { 'microsoft-foundry': { quality: 'low' } } }),
    base('endpoint-openai-v1', {}, { config: { baseUrl: 'https://foundry.example.test/openai/v1/' } }),
    base('endpoint-anthropic', {}, { config: { baseUrl: 'https://foundry.example.test/anthropic/v1/' } }),
    base('endpoint-prefix', {}, { config: { baseUrl: 'https://foundry.example.test/resource/openai/v1/' } }),
    base('endpoint-query-trailing', {}, { config: { baseUrl: ' https://foundry.example.test/resource///?api-version=fixture#ordinary ' } }),
    base('endpoint-hostcase-defaultport', {}, { config: { baseUrl: 'https://FOUNDRY.EXAMPLE.TEST:443/openai/v1' } }),
    base('endpoint-existing-mai-v1', {}, { config: { baseUrl: 'https://foundry.example.test/mai/v1/' } }),
    base('edit-default-png', edit()),
    base('edit-flash', { model: 'MAI-Image-2.5-flash', ...edit() }),
    base('edit-jpeg', edit(jpeg, { mimeType: 'image/jpeg' })),
    base('edit-jpg', edit(jpeg, { mimeType: ' Image/JPG ' })),
    base('edit-trimmed-name', edit(png, { mimeType: 'image/png', fileName: ' source.png ' })),
    base('edit-path-name', edit(png, { mimeType: 'image/png', fileName: ' 绘图/输入.png ' })),
    base('edit-custom-deployment-metadata', { model: 'edit-prod', ...edit() },
      { config: { models: [{ id: 'other-prod', name: 'MAI-Image-2' }, { id: 'edit-prod', name: ' MAI-Image-2.5-flash ' }] } }),
    base('edit-unused-size-options', { count: 1, size: '800x1000', aspectRatio: '16:9', resolution: '2K', quality: 'high',
      outputFormat: 'jpeg', background: 'opaque', providerOptions: { 'microsoft-foundry': { quality: 'low' } }, ...edit() }),
    base('response-explicit-mime', {}, { json: inline(jpeg, { mime_type: ' Image/WEBP; codec=fixture ', revised_prompt: ' Explicit ' }) }),
    base('response-sniff-jpeg', {}, { json: inline(jpeg, { revised_prompt: ' Revised ordinary prompt. ' }) }),
    base('response-sniff-webp', {}, { json: inline(webp) }),
    base('response-png-fallback', {}, { json: inline(opaque, { revised_prompt: ' \t ' }) }),
    base('base64-unpadded', {}, { json: inline(png.replace(/=+$/, '')) }),
    base('base64-whitespace', {}, { json: inline(' \n' + png.slice(0, 12) + ' \t' + png.slice(12) + '\n ') }),
    base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
    base('media-cap-larger', {}, { config: { mediaMaxMb: 80.25 } }),
    base('source-only-default-timeout', {}, { defaults: true, hostComparable: false,
      adaptationReason: 'Pinned source supplies 600000ms per-request timeout with mandatory explicit model and public base. Synapsis requires finite explicit total timeout.' }),
    base('source-only-configured-header', {}, { hostComparable: false,
      adaptationReason: 'Configured request sanitizer/resolver are named successful facades. Literal header consumption is observed; actual header/request-policy normalization does not execute.',
      config: { request: { headers: { 'X-Fixture-Render': ' normal ', 'Content-Type': 'text/plain' } } },
      services: { sanitizedRequest: { headers: { 'X-Fixture-Render': 'normal', 'Content-Type': 'text/plain' } },
        resolvedHeaders: { 'X-Fixture-Render': 'normal', 'Content-Type': 'text/plain' } } }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, URL, FormData, Blob,
      fetch: () => { throw Error('Network is outside this fixture boundary'); },
      __platform: { now: () => this.current.now,
        unused: () => { throw Error('Uninvoked service outside ordinary image callback'); },
        key: params => { this.current.keyCalls.push({ provider: params.provider,
          cfg: plain(params.cfg), agentDir: params.agentDir ?? null, store: params.store ?? null,
          implementation: 'successful-explicit-synthetic-key-facade' }); return { apiKey: 'synthetic-explicit-key' }; },
        config: params => this.config(params), sanitize: request => this.sanitize(request),
        fetch: (...args) => this.post(...args),
        guardedOptions: params => {
          const output = { allowPrivateNetwork: params.allowPrivateNetwork };
          this.current.guardCalls.push({ allowPrivateNetwork: params.allowPrivateNetwork,
            ssrfPolicy: params.ssrfPolicy ?? null, dispatcherPolicy: params.dispatcherPolicy ?? null,
            output, implementation: 'successful-guarded-options-attribution-facade' }); return output;
        },
        status: async (response, label) => {
          assert.equal(response.status, 200);
          this.current.statusCalls.push({ label, status: response.status, atMs: this.current.now,
            implementation: 'successful-status-facade' });
        },
        readJson: async (response, label, options) => {
          this.current.readerCalls.push({ kind: 'json', label, maxBytes: options.maxBytes,
            atMs: this.current.now, implementation: 'successful-native-response-json-facade' });
          this.current.capCalls.push({ maxBytes: options.maxBytes, atMs: this.current.now,
            implementation: 'source-inline-cap-parameter-observation' });
          this.current.request.maxBytes = options.maxBytes;
          const result = await response.json(); this.current.now += 3; return result;
        },
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

  projection(importer, specifier, source, selections, prelude, exports) {
    const original = readFileSync(join(this.root, source));
    assert.equal(hash(original), this.tracked.get(source));
    const regions = selections.map(([startMarker, endMarker]) => {
      const startByte = original.indexOf(startMarker);
      const endByte = original.indexOf(endMarker, startByte);
      assert.ok(startByte >= 0 && endByte > startByte, source);
      assert.equal(original.indexOf(startMarker, startByte + 1), -1, 'unique complete source region');
      return { startByte, endByte, sourceRegionSha256: hash(original.subarray(startByte, endByte)) };
    });
    const generated = prelude + '\n' + regions.map(row => original.subarray(row.startByte, row.endByte).toString()).join('\n');
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source + ':' + regions[0].startByte, { path: source, sha256: hash(original), executed: true, wholeModule: false,
      projection: { regions, prelude, generatedCode: generated, generatedSha256: hash(generated) },
      transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-regions-projection', exports, executable,
      { source, sourceSha256: this.tracked.get(source) });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:image-generation:') && specifier.startsWith('capture:source:'))
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (parent.startsWith('capture:image-generation:') && specifier === 'capture:deadlines')
      return this.projection(parent, specifier, shared,
        [['export function createProviderOperationDeadline(', '/** Resolves a static or lazy request timeout']],
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError']);
    if (parent.startsWith('capture:image-generation:') && specifier === 'capture:post-wrappers')
      return this.projection(parent, specifier, shared,
        [['type GuardedPostRequestRetryOptions =', '// Keep the shipped transcription name']],
        'const resolveGuardedRequestOptions=globalThis.__platform.guardedOptions;\nconst fetchWithTimeoutGuarded=globalThis.__platform.fetch;\nconst isTransientProviderHttpStatus=globalThis.__platform.unused;\nconst createProviderHttpError=globalThis.__platform.unused;\nconst executeProviderOperationWithRetry=globalThis.__platform.unused;',
        ['postJsonRequest', 'postMultipartRequest']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/blob-runtime')
      return this.alias(importer, specifier, blob, ['bufferToBlobPart'], blob);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/expect-runtime')
      return this.alias(importer, specifier, expect, ['expectDefined'], expect);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation')
      return this.alias(importer, specifier, assets,
        ['imageSourceUploadFileName', 'parseOpenAiCompatibleImageResponse', 'resolveInlineImageJsonResponseMaxBytes'],
        'src/plugin-sdk/image-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/string-coerce-runtime')
      return this.alias(importer, specifier, strings, ['normalizeOptionalString', 'normalizeOptionalLowercaseString'],
        'src/plugin-sdk/string-coerce-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime')
      return this.projection(importer, specifier, caps,
        [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']],
        `import {maxBytesForKind} from 'capture:source:${constants}';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if (importer === entry && specifier === './shared.js')
      return this.projection(importer, specifier, foundryShared, [
        ['export const PROVIDER_ID =', 'export const DEFAULT_GPT5_API ='],
        ['export function isFoundryMaiImageModel(', 'function supportsFoundryReasoningContent('],
        ['export function normalizeFoundryEndpoint(', 'export function resolveFoundryApi('],
        ['export function extractFoundryEndpoint(', 'export function resolveFoundryModelCapabilities('],
      ], `import {normalizeOptionalString,normalizeOptionalLowercaseString} from 'capture:source:${strings}';\nexport const isFoundryProviderApi=globalThis.__platform.unused;`,
      ['PROVIDER_ID', 'DEFAULT_API', 'isFoundryMaiImageModel', 'normalizeFoundryEndpoint', 'extractFoundryEndpoint', 'isFoundryProviderApi']);
    if (importer === entry && specifier === './runtime.js')
      return this.binding(importer, specifier, 'uninvoked-runtime-auth-facade', ['prepareFoundryRuntimeAuth'],
        'export const prepareFoundryRuntimeAuth=globalThis.__platform.unused;',
        { source: 'extensions/microsoft-foundry/runtime.ts', sourceSha256: this.tracked.get('extensions/microsoft-foundry/runtime.ts'), originalSourceExecuted: false });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth')
      return this.binding(importer, specifier, 'uninvoked-availability-facade', ['isProviderApiKeyConfiguredAsync'],
        'export const isProviderApiKeyConfiguredAsync=globalThis.__platform.unused;',
        { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth-runtime')
      return this.binding(importer, specifier, 'successful-explicit-synthetic-key-facade', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.key;',
        { source: 'src/plugin-sdk/provider-auth-runtime.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth-runtime.ts'), originalSourceExecuted: false });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http')
      return this.binding(importer, specifier, 'source-deadline-post-wrappers-and-successful-config-status-reader-facades',
        ['assertOkOrThrowHttpError', 'createProviderOperationDeadline', 'postJsonRequest', 'postMultipartRequest',
          'readProviderJsonResponse', 'resolveProviderHttpRequestConfig', 'resolveProviderOperationTimeoutMs', 'sanitizeConfiguredModelProviderRequest'],
        `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs} from 'capture:deadlines';
export {postJsonRequest,postMultipartRequest} from 'capture:post-wrappers';
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const readProviderJsonResponse=globalThis.__platform.readJson;
export const resolveProviderHttpRequestConfig=globalThis.__platform.config;
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;`,
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false });
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared Microsoft Foundry image import: ${importer} -> ${specifier}`);
  }

  sanitize(request) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null,
      implementation: 'successful-configured-request-sanitizer-facade' });
    return output;
  }

  config(params) {
    // Consume the original Foundry normalizer's actual resolvedBaseUrl argument.
    const headers = new Headers(params.defaultHeaders);
    for (const [key, value] of Object.entries(this.current.services.resolvedHeaders ?? {})) headers.set(key, value);
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, transport: params.transport,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl, allowPrivateNetwork: params.allowPrivateNetwork,
      defaultHeaders: plain(params.defaultHeaders), request: params.request ?? null,
      output: { baseUrl: params.baseUrl, headers: Object.fromEntries(headers), allowPrivateNetwork: params.allowPrivateNetwork },
      implementation: 'successful-provider-http-request-config-facade' });
    return { baseUrl: params.baseUrl, headers, allowPrivateNetwork: params.allowPrivateNetwork };
  }

  async post(url, init, timeoutMs, _fetchFn, guardedOptions) {
    assert.equal(init.method, 'POST');
    const multipart = init.body instanceof FormData;
    let body;
    if (multipart) {
      body = [];
      for (const [name, value] of init.body.entries()) {
        body.push(typeof value === 'string' ? { name, value } : { name, fileName: value.name,
          mimeType: value.type, size: value.size, bytesBase64: Buffer.from(await value.arrayBuffer()).toString('base64') });
      }
    } else {
      assert.equal(typeof init.body, 'string', 'original postJsonRequest serializes the source body');
      body = JSON.parse(init.body);
    }
    const receipt = { url, method: init.method, kind: multipart ? 'multipart' : 'json', body,
      ...(multipart ? { multipartBoundary: { rawHttpExecuted: false,
        format: 'ordered native FormData fields and exact Blob bytes/name/type; no generated HTTP boundary compared' } }
        : { rawBody: init.body, jsonBody: plain(body) }),
      headers: Object.fromEntries(init.headers), timeoutMs, atMs: this.current.now, releaseCount: 0 };
    this.current.request = receipt; this.current.now += 7;
    assert.deepEqual(guardedOptions, { allowPrivateNetwork: false });
    return { response: new Response(JSON.stringify(this.current.response.json), { status: 200,
      headers: { 'content-type': 'application/json' } }),
      release: async () => { receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now;
        this.current.releaseCalls.push({ releaseCount: receipt.releaseCount, atMs: this.current.now }); } };
  }

  async run(vector) {
    this.current = { response: plain(vector.response), services: plain(vector.services ?? {}), request: undefined,
      readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], guardCalls: [], releaseCalls: [], capCalls: [], now: 100000 };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) =>
      ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') }));
    const req = { ...input, provider: 'microsoft-foundry', cfg: {
      models: { providers: { 'microsoft-foundry': { baseUrl: vector.config.baseUrl,
        ...(vector.config.models ? { models: vector.config.models } : {}),
        ...(vector.config.request ? { request: vector.config.request } : {}) } } },
      ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}),
    } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildMicrosoftFoundryImageGenerationProvider().generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Image fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) =>
        ({ ...image, bytesBase64: buffer.toString('base64') }));
      const inputAfter = plain(after);
      assert.deepEqual(inputAfter, vector.input);
      assert.equal(this.current.request.releaseCount, 1);
      return { ...vector, inputAfter, request: this.current.request, releaseCount: this.current.request.releaseCount,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls,
        configCalls: this.current.configCalls, sanitizeCalls: this.current.sanitizeCalls, keyCalls: this.current.keyCalls,
        guardCalls: this.current.guardCalls, releaseCalls: this.current.releaseCalls, capCalls: this.current.capCalls,
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now, serviceCostsMs: { post: 7, jsonRead: 3 } } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureMicrosoftFoundryImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ImageGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const providerDescriptor = harness.call('(()=>{const {generateImage,isConfiguredAsync,...descriptor}=__exports.buildMicrosoftFoundryImageGenerationProvider();return descriptor;})()');
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: MICROSOFT_FOUNDRY_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-microsoft-foundry-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    serviceFacadeLedger: [
      { name: 'resolveApiKeyForProvider', executed: false, kind: 'successful-explicit-synthetic-key-facade', limit: 'Fixed synthetic explicit ordinary key used only as api-key header context; credentials/config/profile discovery unexecuted.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, kind: 'successful-configured-request-sanitizer-facade', limit: 'Literal successful outputs only; request-policy implementation unexecuted.' },
      { name: 'resolveProviderHttpRequestConfig', executed: false, kind: 'successful-provider-http-request-config-facade', limit: 'Uses actual source-normalized baseUrl with native Headers and literal successful header outputs; actual header/config policy unexecuted.' },
      { name: 'resolveGuardedRequestOptions/fetchWithTimeoutGuarded', executed: false, kind: 'successful-guarded-options-attribution-and-transport-facades', limit: 'Original postJsonRequest/postMultipartRequest serialize/pass body; transport observes ordered native FormData or JSON and returns native successful Response. No raw HTTP/network.' },
      { name: 'assertOkOrThrowHttpError/readProviderJsonResponse', executed: false, kind: 'successful-status-native-response-json-facades', limit: 'Status 200 and native Response.json only; production bounded reader unexecuted. Source computed byte cap is recorded as a parameter.' },
      { name: 'isProviderApiKeyConfiguredAsync/prepareFoundryRuntimeAuth/isFoundryProviderApi', executed: false, kind: 'uninvoked-availability-runtime-auth-facades', limit: 'Availability, credentials/env/runtime-auth, Entra dynamic branch and endpoint environment fallback not executed; source review/provenance only.' },
    ],
    limits: [
      'Complete unchanged 295-line Microsoft Foundry image-generation-provider executes. Whole original image-assets/blob/expect/number/string/record/base64/constants execute. Four source projection modules select complete original cap/deadline/HTTP-wrapper regions and separate Foundry constants/model-name/normalize/extract regions with exact byte spans and generated/executable hashes. Unrelated shared auth/model code does not execute.',
      'All 58,558 tracked reference blobs, modes and symlinks verified before and after; exporter, unchanged shared FactoryHarness, fixed Node24.22.1, original modules, source regions and every import have reconstructable receipts. Registration/manifest and SDK/security/service provenance do not imply execution.',
      'All callbacks use explicit public endpoint and explicit model. Original endpoint normalizer feeds actual resolvedBaseUrl into config facade; /mai/v1 is always appended including an already-present /mai/v1. Root/openai/v1/anthropic/prefix/query/trailing/hostcase/default-port ordinary endpoints are covered without policy assertions.',
      'Original model metadata exact id lookup, JS trim/prefix retention, five known MAI model names, valid generation sizes, count absent/one, one result, one input and 2.5/flash edits execute. Unused controls are absent from bodies; edits ignore valid size. No failure/negative/mixed/overflow/cancel/crash execution.',
      'Native FormData and Blob preserve ordered model/prompt/image plus exact bytes/MIME/name; default PNG, JPEG/JPG normalization and helper filename prefix are observed. Raw multipart HTTP serialization and boundary are outside this abstraction.',
      'Original response parser sniffs JPEG/PNG/WEBP with PNG fallback; explicit MIME wins and revised prompts trim. Filename prefix is microsoft-foundry-image. Valid canonical/unpadded/whitespace Base64 only; no URL downloads or real provider requests. Tiny protocol bytes establish transformations, not codec validity or visual quality.',
      'Original deadline helpers use deterministic UTC epoch Date.now; default 600000ms is source-only. Real cap helpers use source maxCount one, 64MiB floor and configured 80.25MiB. Cap parameters do not prove production bounded stream reading. Original try/finally releases the successful response exactly once.',
      'Two hostComparable=false rows cover omitted timeout with mandatory model and configured-header literal consumption. Ordinary JSON forces application/json and multipart deletes Content-Type. Header/request policy normalization is unexecuted.',
      'Credentials/env/runtime-auth, availability/isConfigured, Entra dynamic branch, environment endpoint fallback, auth/security/permissions/TLS/proxy/private-policy behavior are provenance/source-review only and are not executed or validated.',
      'Inactive independent source oracle only; no tool/catalog enablement, durable media/jobs/storage/delivery, real-provider evidence or complete P10/reference-goal claim.',
    ], providerDescriptor, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-microsoft-foundry-image-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureMicrosoftFoundryImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
