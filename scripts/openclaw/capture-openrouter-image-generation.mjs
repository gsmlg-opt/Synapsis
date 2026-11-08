// Whole pinned OpenRouter image provider, request context and real JSON POST serialization under named successful I/O facades.
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

export const OPENROUTER_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openrouter/image-generation-provider.ts';
const context = 'extensions/openrouter/generation-request-context.ts';
const catalog = 'extensions/openrouter/provider-catalog.ts';
const defaults = 'extensions/openrouter/provider-defaults.ts';
const postResponse = 'src/media-understanding/provider-json-post.ts';
const shared = 'src/media-understanding/shared.ts';
const assets = 'src/image-generation/image-assets.ts';
const caps = 'src/media/configured-max-bytes.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const base64 = 'packages/media-core/src/base64.ts';
const constants = 'packages/media-core/src/constants.ts';
const registration = 'extensions/openrouter/index.ts';
const manifest = 'extensions/openrouter/openclaw.plugin.json';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, context, defaults, postResponse, assets, number, strings, records, base64, constants];
const provenancePaths = [registration, manifest, 'src/plugin-sdk/image-generation.ts',
  'src/plugin-sdk/media-generation-runtime.ts', 'src/plugin-sdk/number-runtime.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/agents/provider-http-errors.ts', 'src/plugins/provider-auth-availability.ts',
  'src/agents/provider-request-config.ts', 'src/infra/net/fetch-guard.ts',
  'src/infra/net/ssrf.ts', 'src/provider-runtime/operation-retry.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENROUTER_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENROUTER_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: OPENROUTER_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${OPENROUTER_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRg==';
const webp = 'UklGRgQAAABXRUJQ';
const opaque = 'b3BhcXVlIGltYWdlIHByb3RvY29sIGJ5dGVz';
const defaultBase = 'https://openrouter.ai/api/v1';
const customBase = 'https://images.example.com/v1';
const model = 'google/gemini-3.1-flash-image-preview';
const dataUrl = (bytes = png, mime = 'image/png') => `data:${mime};base64,${bytes}`;
const dedicated = (...entries) => ({ data: entries.length ? entries : [{ b64_json: png }] });
const chat = message => ({ choices: [{ message }] });
function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, providerId: 'openrouter', hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt: ' Draw a small blue square. ', ...(options.defaults ? {} : { model, timeoutMs: 30000 }), ...input },
    config: { baseUrl: defaultBase, effectiveBaseUrl: defaultBase, ...options.config },
    responses: (options.jsons ?? [options.json ?? dedicated()]).map(json => ({ json })),
    ...(options.completionOrder ? { fixtureControl: { kind: 'successful-responses-in-explicit-completion-order', completionOrder: options.completionOrder } } : {}),
    ...(options.services ? { services: options.services } : {}) });
  const custom = (id, input = {}, options = {}) => base(id, input, { config: { baseUrl: customBase, effectiveBaseUrl: customBase }, json: chat({ images: [{ image_url: { url: dataUrl() } }] }), ...options });
  const refs = [{ bytesBase64: jpeg }, { bytesBase64: png, mimeType: ' Image/PNG; Mode=RGB ', fileName: ' 绘图/输入.png ' },
    { bytesBase64: webp, mimeType: 'image/webp' }, { bytesBase64: opaque, mimeType: 'image/png' }, { bytesBase64: png, mimeType: 'image/png' }];
  return [base('default-count'),
    base('canonical-trailing-slashes', {}, { config: { baseUrl: defaultBase + '///' } }),
    base('legacy-root', {}, { config: { baseUrl: 'https://openrouter.ai/v1' } }),
    base('legacy-js-trim', {}, { config: { baseUrl: '\uFEFF https://openrouter.ai/v1///\u00a0' } }),
    base('canonical-js-trim', {}, { config: { baseUrl: '\uFEFF ' + defaultBase + '/\u00a0' } }),
    base('model-prompt-js-trim', { model: '\uFEFF google/gemini-3-pro-image-preview\u00a0', prompt: '  Preserve this exact prompt.\n' }),
    base('prefixed-model-geometry-ignored', { model: 'openrouter/google/gemini-3-pro-image-preview', aspectRatio: '16:9', resolution: '4K', size: '1024x1024' }),
    base('non-gemini-geometry-ignored', { model: 'openai/gpt-5.4-image-2', aspectRatio: '4:3', resolution: '2K', size: '1024x1024' }),
    base('dedicated-four-reverse-completion', { count: 4 }, { jsons: [dedicated({ b64_json: jpeg }), dedicated({ b64_json: png }), dedicated({ b64_json: webp }), dedicated({ b64_json: opaque })], completionOrder: [3, 2, 1, 0] }),
    custom('custom-chat-count-four', { count: 4 }, { json: chat({ images: [{ image_url: { url: dataUrl(jpeg, 'image/jpeg') } }, { imageUrl: { url: dataUrl() } }, { image_url: { url: dataUrl(webp, 'image/webp') } }, { image_url: { url: dataUrl(opaque) } }] }) }),
    ...['1:1','2:3','3:2','3:4','4:3','4:5','5:4','9:16','16:9','21:9'].map(ratio => base('aspect-' + ratio.replace(':', '-'), { aspectRatio: ratio })),
    ...['1K','2K','4K'].map(resolution => base('resolution-' + resolution, { resolution })),
    custom('chat-gemini-trimmed-geometry', { aspectRatio: '\uFEFF 16:9\u00a0', resolution: ' 4K ', size: '2048x2048' }),
    base('input-one-default-png', { inputImages: refs.slice(0, 1) }),
    base('input-five-raw-bytes-mime-name', { inputImages: refs }),
    custom('chat-input-five', { inputImages: refs }),
    base('dedicated-sniff-and-explicit-mime', {}, { json: dedicated({ b64_json: jpeg }, { b64_json: png }, { b64_json: webp }, { b64_json: jpeg, mime_type: ' Image/PNG; charset=binary ', revised_prompt: ' Revised prompt. ' }) }),
    base('dedicated-media-type-alias-precedence', {}, { json: dedicated({ b64_json: jpeg, media_type: 'image/webp', revised_prompt: ' Alias prompt ' }, { b64_json: webp, mime_type: 'image/jpeg', media_type: 'image/png' }) }),
    custom('chat-message-images-then-content-string', {}, { json: chat({ images: [{ imageUrl: { url: dataUrl(jpeg, 'image/jpeg') } }], content: 'before ' + dataUrl() + ' between ' + dataUrl(webp, 'image/webp') + ' after' }) }),
    custom('chat-content-array-image-url-variants', {}, { json: chat({ content: [{ type: 'text', text: 'rendered' }, { type: 'image_url', image_url: { url: dataUrl(jpeg, 'image/jpeg') } }, { type: 'image_url', imageUrl: { url: dataUrl() } }] }) }),
    custom('chat-base64-and-inline-variants', {}, { json: chat({ content: [{ b64_json: jpeg }, { inlineData: { data: webp, mimeType: ' image/webp ' } }, { inline_data: { data: jpeg, mime_type: 'image/jpeg' } }, { inline_data: { data: png } }] }) }),
    custom('chat-valid-precedence', {}, { json: chat({ images: [{ image_url: { url: dataUrl() }, imageUrl: { url: dataUrl(jpeg, 'image/jpeg') } }], content: [{ type: 'image_url', image_url: { url: dataUrl(webp, 'image/webp') }, b64_json: jpeg }, { b64_json: jpeg, inlineData: { data: png } }, { inlineData: { data: jpeg, mimeType: 'image/jpeg', mime_type: 'image/webp' }, inline_data: { data: png } }] }) }),
    custom('chat-choice-order-contiguous-filenames', {}, { json: { choices: [{ message: { images: [{ image_url: { url: dataUrl(jpeg, 'image/jpeg') } }], content: [{ b64_json: png }] } }, { message: { content: [{ inline_data: { data: webp, mime_type: 'image/webp' } }, { b64_json: opaque }] } }] } }),
    base('base64-unpadded', {}, { json: dedicated({ b64_json: png.replace(/=+$/, '') }) }),
    base('base64-whitespace', {}, { json: dedicated({ b64_json: ' \n' + png.slice(0, 12) + ' \t' + png.slice(12) + '\n ' }) }),
    custom('chat-data-url-case-parameters', {}, { json: chat({ images: [{ image_url: { url: 'DATA:Image/PNG;mode=RGB;BASE64,' + png } }] }) }),
    base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
    custom('media-cap-larger-chat-four', { count: 4 }, { config: { baseUrl: customBase, effectiveBaseUrl: customBase, mediaMaxMb: 80.25 } }),
    base('source-only-default-model-timeout', {}, { defaults: true, hostComparable: false, adaptationReason: 'Source default model and 180000ms timeout are source-only; host comparison requires explicit model and finite timeout.' }),
    base('source-only-configured-header', {}, { hostComparable: false, adaptationReason: 'Literal successful sanitizer/config outputs only; configured request normalization does not execute.', config: { request: { headers: { 'X-Fixture-Render': ' normal ' } } }, services: { sanitizedRequest: { headers: { 'X-Fixture-Render': 'normal' } }, resolvedHeaders: { 'X-Fixture-Render': 'normal' } } }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, Uint8Array, Headers, Response, URL,
      process: Object.freeze({ env: Object.freeze({}) }), fetch: () => { throw Error('Real network is outside this fixture boundary'); },
      __platform: { config: params => this.config(params), sanitize: request => this.sanitize(request),
        guardedOptions: params => { const output = { allowPrivateNetwork: false }; this.current.guardCalls.push({ allowPrivateNetwork: params.allowPrivateNetwork, implementation: 'successful-public-guard-options-facade', output }); return output; },
        fetch: (...args) => this.post(...args),
        unused: () => { throw Error('Uninvoked availability/retry/HTTP-error/object-reader facade'); },
        status: async (response, label, options) => { assert.equal(response.status, 200); this.current.statusCalls.push({ ordinal: this.responseOrdinals.get(response), label, options: options ?? null }); },
        readJson: async (response, label, options) => { const ordinal = this.responseOrdinals.get(response); this.current.readerCalls.push({ ordinal, kind: 'json', label, maxBytes: options.maxBytes }); this.current.requests[ordinal].maxBytes = options.maxBytes; return response.json(); },
      } }, { codeGeneration: { strings: false, wasm: false } });
    this.sourceRecords = new Map(); this.importBindings = new Map(); this.dynamicImports = [];
    this.responseOrdinals = new WeakMap();
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
    if (parent.startsWith('capture:image-generation:') && specifier.startsWith('capture:source:')) return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.alias(importer, specifier, assets,
      ['generatedImageAssetFromBase64','generatedImageAssetFromDataUrl','parseOpenAiCompatibleImageResponse','resolveInlineImageJsonResponseMaxBytes','toImageDataUrl'], 'src/plugin-sdk/image-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') return this.projection(importer, specifier, caps,
      'const MB = 1024 * 1024;', '/** Reads channel/account media caps', `import {maxBytesForKind} from 'capture:source:${constants}';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/number-runtime') return this.alias(importer, specifier, number, ['resolveIntegerOption'], 'src/plugin-sdk/number-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') return this.binding(importer, specifier, 'uninvoked-availability-facade', ['isProviderApiKeyConfiguredAsync'], 'export const isProviderApiKeyConfiguredAsync=globalThis.__platform.unused;', { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http') return this.alias(importer, specifier, postResponse, ['postJsonResponse'], 'src/plugin-sdk/provider-http.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.binding(importer, specifier, 'whole-source-export-alias', ['isRecord','normalizeOptionalString'], `export {isRecord} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`, { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    if ((importer === entry || importer === context) && specifier === './provider-catalog.js') return this.projection(importer, specifier, catalog,
      'const OPENROUTER_LEGACY_BASE_URL', 'export function resolveOpenRouterApiBaseUrl',
      `import {OPENROUTER_BASE_URL} from 'capture:source:${defaults}';\nexport {OPENROUTER_BASE_URL} from 'capture:source:${defaults}';`, ['normalizeOpenRouterBaseUrl','OPENROUTER_BASE_URL']);
    if (importer === context && specifier === 'openclaw/plugin-sdk/provider-http') return this.binding(importer, specifier, 'successful-config-and-sanitizer-facades', ['resolveProviderApiKeyHttpRequestConfig','sanitizeConfiguredModelProviderRequest'],
      'export const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;\nexport const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;', { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false });
    if (importer === postResponse && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier, 'successful-status-native-json-reader-and-uninvoked-object-reader-facades', ['assertOkOrThrowHttpError','readProviderJsonResponse','readProviderJsonObjectResponse'],
      'export const assertOkOrThrowHttpError=globalThis.__platform.status;\nexport const readProviderJsonResponse=globalThis.__platform.readJson;\nexport const readProviderJsonObjectResponse=globalThis.__platform.unused;', { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    if (importer === postResponse && specifier === './shared.js') return this.projection(importer, specifier, shared,
      'type GuardedPostRequestRetryOptions =', '// Keep the shipped transcription name',
      `const resolveGuardedRequestOptions=globalThis.__platform.guardedOptions;\nconst fetchWithTimeoutGuarded=globalThis.__platform.fetch;\nconst isTransientProviderHttpStatus=globalThis.__platform.unused;\nconst createProviderHttpError=globalThis.__platform.unused;\nconst executeProviderOperationWithRetry=globalThis.__platform.unused;`, ['postJsonRequest','postMultipartRequest']);
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared OpenRouter image import: ${importer} -> ${specifier}`);
  }

  sanitize(request) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null, implementation: 'successful-configured-request-sanitizer-facade' });
    return output;
  }

  config(params) {
    const headers = new Headers({ Authorization: 'Bearer synthetic-explicit-key', ...this.current.services.resolvedHeaders });
    if (params.jsonContentType) headers.set('Content-Type', 'application/json');
    const baseUrl = (params.baseUrl ?? params.defaultBaseUrl).trim().replace(/\/+$/, '');
    const output = { baseUrl, headers: Object.fromEntries(headers), allowPrivateNetwork: false };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, baseUrl: params.baseUrl ?? null,
      defaultBaseUrl: params.defaultBaseUrl, jsonContentType: params.jsonContentType, request: params.request ?? null,
      missingApiKeyMessage: params.missingApiKeyMessage, output, implementation: 'successful-explicit-credential-http-config-policy-facade' });
    this.current.keyCalls.push({ provider: params.provider, implementation: 'literal-synthetic-credential-in-config-facade' });
    return { ...output, headers };
  }

  post(url, init, timeoutMs, _fetchFn, guardedOptions) {
    assert.equal(init.method, 'POST');
    assert.equal(typeof init.body, 'string', 'whole source postJsonRequest serializes');
    const native = new Request(url, init);
    const ordinal = this.current.requests.length;
    const receipt = { ordinal, url: native.url, method: native.method, body: JSON.parse(init.body), rawBody: init.body,
      headers: Object.fromEntries(init.headers), wireHeaders: Object.fromEntries(native.headers), timeoutMs, releaseCount: 0 };
    this.current.requests.push(receipt);
    assert.deepEqual(guardedOptions, { allowPrivateNetwork: false });
    const promise = new Promise(resolveResponse => this.current.pending.push({ ordinal, resolveResponse }));
    if (this.current.pending.length === this.current.responses.length) {
      const state = this.current;
      void (async () => {
        // This named fixture control changes only successful response completion order, never provider code.
        for (const index of state.completionPlan) {
          const response = new Response(JSON.stringify(state.responses[index].json), { status: 200, headers: { 'content-type': 'application/json' } });
          this.responseOrdinals.set(response, index);
          state.completionOrder.push(index);
          state.pending[index].resolveResponse({ response, release: async () => {
            state.requests[index].releaseCount += 1;
            state.releaseCalls.push({ ordinal: index, releaseCount: state.requests[index].releaseCount });
          } });
          await new Promise(resolveTurn => setImmediate(resolveTurn));
        }
      })();
    }
    return promise;
  }

  async run(vector) {
    this.current = { services: plain(vector.services ?? {}), responses: plain(vector.responses), requests: [], pending: [],
      completionPlan: vector.fixtureControl?.completionOrder ?? vector.responses.map((_, i) => i), completionOrder: [],
      readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], guardCalls: [], releaseCalls: [] };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) => ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') }));
    const req = { ...input, cfg: { models: { providers: { openrouter: { baseUrl: vector.config.baseUrl,
      ...(vector.config.request ? { request: vector.config.request } : {}) } } },
      ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg); this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildOpenRouterImageGenerationProvider().generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('OpenRouter image fixture asynchronous deadline exceeded')), 5000); })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') }));
      const inputAfter = plain(after); assert.deepEqual(inputAfter, vector.input);
      assert.equal(this.current.requests.length, vector.responses.length);
      for (const request of this.current.requests) assert.equal(request.releaseCount, 1);
      const { pending: _pending, completionPlan: _plan, services: _services, responses: _responses, ...receipts } = this.current;
      return { ...vector, inputAfter, ...receipts,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }) };
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenrouterImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ImageGenerationHarness(root, before.tracked); await harness.load(entry);
  const providerDescriptors = [harness.call('(()=>{const {generateImage,isConfiguredAsync,...descriptor}=__exports.buildOpenRouterImageGenerationProvider();return descriptor;})()')];
  const registrationCalls = ['api.registerImageGenerationProvider(buildOpenRouterImageGenerationProvider());'];
  for (const call of registrationCalls) assert.ok(readFileSync(join(root, registration), 'utf8').includes(call));
  const manifestData = JSON.parse(readFileSync(join(root, manifest), 'utf8'));
  const observations = []; for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) { const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source)); sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true }); }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: OPENROUTER_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-openrouter-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    vmEnvironment: { processEnv: {}, frozen: true, hostEnvironmentRead: false },
    registrationProvenance: { executed: false, source: registration, sourceSha256: before.tracked.get(registration), calls: registrationCalls,
      manifest, manifestSha256: before.tracked.get(manifest), manifestProviders: manifestData.providers,
      manifestImageGenerationProviders: manifestData.contracts.imageGenerationProviders,
      limit: 'Actual OpenRouter registration call and manifest verified as provenance only; plugin assembly does not execute.' },
    serviceFacadeLedger: [
      { name: 'resolveProviderApiKeyHttpRequestConfig', executed: false, kind: 'successful-config-policy-credential-facade', limit: 'Literal synthetic credential, normalized explicit public base and raw context headers; actual credentials/config/request policy do not execute.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, kind: 'successful-sanitizer-facade', limit: 'Records input and returns literal vector output; no configured request normalization implementation.' },
      { name: 'resolveGuardedRequestOptions', executed: false, kind: 'successful-public-guard-options-facade', limit: 'Records and returns a public successful literal; no security, policy, private-network or permission behavior tested.' },
      { name: 'fetchWithTimeoutGuarded', executed: false, kind: 'native-request-and-successful-literal-response-facade', limit: 'Native Request observes actual source JSON string serialization and native wire headers. No HTTP connection, DNS, actual guarded fetch, timeouts or TLS executes.' },
      { name: 'assertOkOrThrowHttpError/readProviderJsonResponse', executed: false, kind: 'successful-status-and-native-json-reader-facades', limit: 'Native Response.json consumes literal success, recording source byte-cap arguments; actual bounded reading/status implementation does not execute.' },
      { name: 'isProviderApiKeyConfiguredAsync/readProviderJsonObjectResponse/isTransientProviderHttpStatus/createProviderHttpError/executeProviderOperationWithRetry', executed: false, kind: 'uninvoked-service-facades', limit: 'Complete source region links these named facades; each throws if called. Availability/retry/error/object reading remain unexecuted.' },
    ],
    limits: [
      'Whole unchanged OpenRouter image-generation-provider.ts and generation-request-context.ts, provider-defaults.ts, provider-json-post.ts, image-assets, Base64, constants, record/string/number modules execute. Complete original catalog normalizer, configured cap and guarded POST regions execute with exact source/generated/executable hashes.',
      'All 58558 tracked source blobs, modes and symlinks verified before and after. Exporter, shared unchanged FactoryHarness, fixed Node24.22.1, binding and original-source hashes are receipts. Registration and plugin/SDK/service provenance do not execute.',
      'Complete callback includes official canonical/legacy dedicated route and public custom-base chat route, request count concurrency, Gemini-only geometry, all input references, full dedicated/chat response extraction and ordered flatten. Reversed successful completion is a named fixture control; Promise.all preserves invocation order and dedicated filenames restart per response.',
      'Pinned source comment says postJsonRequest supplies JSON content type, but actual complete POST region only JSON.stringify serializes and forwards raw headers. With no explicit source content-type, native Request observes text/plain;charset=UTF-8. This source-comment discrepancy is recorded without changing source or adding a workaround.',
      'Config/key/sanitizer/guarded policy/status/bounded-reader/retry behavior is explicitly facaded. Whole POST JSON.stringify, native Request construction and native Response.json execute; actual HTTP and transport defaults beyond native Request header construction are unverified.',
      'Source-only omitted model/timeout and configured-header rows are hostComparable=false. Remaining rows supply model, timeout and effective public base. VM process.env is frozen empty, never host-derived.',
      'All cases are ordinary successful public requests, count 1..4, at most five input references and four total outputs. Tiny protocol bytes verify byte/MIME/name/order projection only, not codec validity or quality. No GET/download, negative/malformed/overflow/failure/cancel/crash/auth/TLS/security/permission/real-provider cases.',
      'Inactive independent reference oracle; no tool/catalog activation, durable media/jobs/storage/delivery, plugin assembly or complete P10/reference-goal claim.',
    ], providerDescriptors, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-openrouter-image-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureOpenrouterImageGeneration(args[0]); writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length, wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length, sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length, trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
