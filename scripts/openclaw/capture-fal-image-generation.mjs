// Whole pinned FAL callback and helper sources; successful synthetic I/O only.
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

export const FAL_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/fal/image-generation-provider.ts';
const http = 'extensions/fal/http-config.ts';
const assets = 'src/image-generation/image-assets.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const constants = 'packages/media-core/src/constants.ts';
const base64 = 'packages/media-core/src/base64.ts';
const caps = 'src/media/configured-max-bytes.ts';
const shared = 'src/media-understanding/shared.ts';
const errors = 'src/agents/provider-http-errors.ts';
const config = 'src/agents/provider-request-config.ts';
const wholeSources = [entry, http, assets, number, strings, records, base64, constants];
const provenancePaths = ['extensions/fal/openclaw.plugin.json', 'extensions/fal/index.ts',
  'extensions/fal/provider-contract-api.ts', 'extensions/fal/onboard.ts',
  'src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/response-limit-runtime.ts',
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugin-sdk/provider-auth.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/infra/net/fetch-guard.ts',
  'src/infra/http-response-body.ts'];
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), FAL_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', FAL_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    verified: true, commit: FAL_IMAGE_GENERATION_PIN,
    tree: git(root, ['rev-parse', `${FAL_IMAGE_GENERATION_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

const defaultModel = 'fal-ai/flux/dev';
const defaultBase = 'https://fal.example.test';
const prompt = ' Draw a small blue square. ';
const sizes = ['1024x1024', '1024x1536', '1536x1024', '1024x1792', '1792x1024'];
const ratios = ['1:1', '2:3', '3:2', '2.35:1', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '21:9', '4:1', '1:4', '8:1', '1:8'];
const nano = ['21:9', '16:9', '3:2', '4:3', '5:4', '1:1', '4:5', '3:4', '2:3', '9:16'];
const nano2 = [...nano, '4:1', '1:4', '8:1', '1:8'];
const krea = ['1:1', '4:3', '3:2', '16:9', '2.35:1', '4:5', '2:3', '9:16'];
const grok = ['2:1', '20:9', '19.5:9', '16:9', '4:3', '3:2', '1:1', '2:3', '3:4', '9:16', '9:19.5', '9:20', '1:2'];
const gpt25 = ['openai/gpt-image-2.5/flare/text-to-image', 'openai/gpt-image-2.5/flare/edit',
  'openai/gpt-image-2.5/sunburst/text-to-image', 'openai/gpt-image-2.5/sunburst/edit'];
function references(count, extras = {}) {
  return { inputImages: Array.from({ length: count }, (_, index) => ({
    bytesBase64: Buffer.from([index + 1, 240, 32]).toString('base64'), ...extras,
  })) };
}
function vectors() {
  const base = (id, input = {}, options = {}) => {
    const count = input.count ?? 1;
    return { id, hostComparable: options.hostComparable ?? true,
      ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
      input: { prompt, ...(options.defaults ? {} : { model: defaultModel, timeoutMs: 30000 }), ...input },
      config: { baseUrl: defaultBase, ...options.config },
      response: options.response ?? { json: { images: Array.from({ length: count }, (_, i) => ({ url: `https://images.example.test/${i + 1}` })) },
        downloads: Array.from({ length: count }, (_, i) => ({ bytesBase64: Buffer.from([i + 11, 22, 33]).toString('base64'), mimeType: 'image/png' })) },
      ...(options.services ? { services: options.services } : {}),
    };
  };
  const rows = [base('flux-default'), base('fractional-timeout', { timeoutMs: 30000.9 }), base('trim-model-base', { model: '\uFEFFfal-ai/flux/dev\u00a0', prompt: '  Keep prompt\n' },
    { config: { baseUrl: '\uFEFFhttps://fal.example.test/render///\u00a0' } }),
  base('flux-auto-edit', references(1)),
  base('flux-explicit-edit', { model: 'fal-ai/flux/dev/image-to-image', resolution: '2K', ...references(1) }),
  base('custom-preserved-edit', { model: 'fal-ai/custom/edit', size: '1024x1536', ...references(1) }),
  base('custom-preserved-middle', { model: 'fal-ai/custom/image-to-image/revision', ...references(1) }),
  base('reference-mime-name', references(1, { mimeType: ' Image/JPEG; mode=fixture ', fileName: 'ignored/source.jpg' })),
  base('reference-blank-mime', references(1, { mimeType: '  ', fileName: 'ignored.webp' })),
  base('count-two', { count: 2 }), base('count-three', { count: 3 }), base('count-four-jpeg', { count: 4, outputFormat: 'jpeg' }),
  base('explicit-png-count-one', { count: 1, outputFormat: 'png' }),
  base('geometry-precedence', { size: ' 01024X01536 ', aspectRatio: '16:9', resolution: '4K' }),
  base('generic-gpt-text', { model: 'openai/gpt-image-2', size: '1536x1024' }),
  base('generic-gpt-auto-edit-max', { model: 'openai/gpt-image-2', aspectRatio: '16:9', resolution: '4K', ...references(10) }),
  base('generic-gpt-explicit-edit', { model: 'openai/gpt-image-2/edit', ...references(1) }),
  base('generic-gpt-text-suffix-edit', { model: 'openai/gpt-image-2/text-to-image', ...references(1) }),
  base('media-cap-floor', {}, { config: { mediaMaxMb: 2.25 } }),
  base('media-cap-larger', {}, { config: { mediaMaxMb: 80.25 } })];
  sizes.forEach((size, i) => rows.push(base(`flux-size-${i}`, { size })));
  ratios.forEach((aspectRatio, i) => rows.push(base(`flux-ratio-${i}`, { aspectRatio })));
  ['1K', '2K', '4K'].forEach((resolution, i) => {
    rows.push(base(`flux-resolution-${i}`, { resolution }));
    rows.push(base(`flux-ratio-resolution-${i}`, { aspectRatio: '9:16', resolution }));
  });
  gpt25.forEach((model, i) => {
    rows.push(base(`gpt25-model-${i}`, { model }));
    rows.push(base(`gpt25-edit-${i}`, { model, ...references(i === 0 ? 16 : 1) }));
  });
  rows.push(base('gpt25-auto', { model: gpt25[0], size: 'auto' }));
  sizes.forEach((size, i) => rows.push(base(`gpt25-size-${i}`, { model: gpt25[0], size })));
  ratios.slice(0, 11).forEach((aspectRatio, i) => rows.push(base(`gpt25-ratio-${i}`, { model: gpt25[0], aspectRatio })));
  ['low', 'medium', 'high', 'xhigh', 'max', 'auto'].forEach((quality, i) => rows.push(base(`gpt25-quality-${i}`, { model: gpt25[0], quality })));
  ['png', 'jpeg', 'webp'].forEach((outputFormat, i) => rows.push(base(`gpt25-format-${i}`, { model: gpt25[0], outputFormat })));
  ['transparent', 'opaque', 'auto'].forEach((background, i) => rows.push(base(`gpt25-background-${i}`, { model: gpt25[0], background })));
  ['medium', 'large'].forEach((size, i) => {
    const model = `krea/v2/${size}/text-to-image`;
    rows.push(base(`krea-model-${i}`, { model }));
    rows.push(base(`krea-reference-${i}`, { model, count: 1, ...references(i === 0 ? 10 : 1) }));
  });
  krea.forEach((aspectRatio, i) => rows.push(base(`krea-ratio-${i}`, { model: 'krea/v2/medium/text-to-image', aspectRatio })));
  ['raw', 'low', 'medium', 'high', ' HIGH '].forEach((creativity, i) => rows.push(base(`krea-creativity-${i}`, {
    model: 'krea/v2/medium/text-to-image', providerOptions: { fal: { creativity } },
  })));
  rows.push(base('krea-size', { model: 'krea/v2/large/text-to-image', size: '1024x1536' }));
  for (const [family, model, allowed, max] of [
    ['nano', 'fal-ai/nano-banana', nano, 3], ['nano2', 'fal-ai/nano-banana-2', nano2, 14],
    ['lite', 'google/nano-banana-2-lite', nano2, 14], ['grok', 'xai/grok-imagine-image', grok, 3],
  ]) {
    rows.push(base(`${family}-generate`, { model }));
    rows.push(base(`${family}-auto-edit-max`, { model, ...references(max) }));
    rows.push(base(`${family}-explicit-edit`, { model: model + '/edit', ...references(1) }));
    rows.push(base(`${family}-size`, { model, size: '1024x1536' }));
    allowed.forEach((aspectRatio, i) => rows.push(base(`${family}-ratio-${i}`, { model, aspectRatio })));
  }
  ['1K', '2K', '4K'].forEach((resolution, i) => rows.push(base(`nano2-resolution-${i}`, { model: 'fal-ai/nano-banana-2', resolution })));
  ['1K', '2K'].forEach((resolution, i) => rows.push(base(`grok-resolution-${i}`, { model: 'xai/grok-imagine-image', resolution })));
  rows.push(base('grok-quality', { model: 'xai/grok-imagine-image/quality' }),
    base('grok-quality-auto-edit', { model: 'xai/grok-imagine-image/quality', ...references(1) }),
    base('grok-quality-explicit-edit', { model: 'xai/grok-imagine-image/quality/edit', ...references(3) }));
  rows.push(base('result-url-mime-metadata', { count: 4 }, { response: {
    json: { images: [
      { url: ' https://images.example.test/1 ', content_type: 'image/webp', file_name: 'ignored.webp', width: 999 },
      { url: 'https://images.example.test/2', b64_json: 'ignored' },
      { url: 'https://images.example.test/3' }, { url: 'https://images.example.test/4' },
    ], prompt: '  Actual provider prompt. \n', data: 'ignored', image: 'ignored' },
    downloads: [{ bytesBase64: '/9j/', mimeType: ' Image/JPEG; codec=fixture ' },
      { bytesBase64: 'UklGRgQAAABXRUJQ' }, { bytesBase64: 'AQID', mimeType: 'image/webp' },
      { bytesBase64: 'BAUG', mimeType: 'image/svg+xml; charset=UTF-8' }],
  } }));
  rows.push(base('result-blank-mime-prompt', {}, { response: {
    json: { images: [{ url: 'https://images.example.test/1' }], prompt: ' \t ' },
    downloads: [{ bytesBase64: '/9j/', mimeType: '  ' }],
  } }));
  rows.push(base('source-only-default-model-timeout', {}, { defaults: true, hostComparable: false,
    adaptationReason: 'Raw callback defaults model to flux/dev; absent total timeout leaves POST undefined and each GET at 30000ms. Host adapter requires explicit finite timeout/model.' }));
  rows.push(base('source-only-configured-header', {}, { hostComparable: false,
    adaptationReason: 'Successful literal configured header facade only; production request normalization/policy is unexecuted.',
    config: { request: { headers: { 'X-Fixture-Render': ' normal ' } } },
    services: { sanitizedRequest: { headers: { 'X-Fixture-Render': 'normal' } }, resolvedHeaders: { 'X-Fixture-Render': 'normal' } },
  }));
  return rows;
}

class FalHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, TextDecoder,
      __platform: { now: () => this.current.now,
        unused: () => { throw Error('Uninvoked service outside ordinary FAL callback'); },
        key: params => { this.current.keyCalls.push({ provider: params.provider, cfg: plain(params.cfg),
          agentDir: params.agentDir ?? null, store: params.store ?? null,
          implementation: 'successful-explicit-synthetic-key-facade' }); this.current.now += 2;
          return { apiKey: 'synthetic-explicit-key' }; },
        sanitize: request => this.sanitize(request), config: (params, normalizedBase) => this.config(params, normalizedBase),
        fetch: params => this.fetch(params), status: (response, label) => {
          assert.equal(response.status, 200); this.current.statusCalls.push({ label, status: 200, atMs: this.current.now,
            implementation: 'successful-status-facade' });
        }, read: (response, maxBytes, options) => this.read(response, maxBytes, options),
      } }, { codeGeneration: { strings: false, wasm: false } });
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
        throw Error('Undeclared FAL dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:fal:' + key, code);
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
      const startByte = original.indexOf(startMarker); const endByte = original.indexOf(endMarker, startByte);
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
    if (parent.startsWith('capture:fal:') && specifier.startsWith('capture:source:'))
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (parent.startsWith('capture:fal:') && specifier === 'capture:deadlines')
      return this.projection(parent, specifier, shared,
        [['export function createProviderOperationDeadline(', '/** Resolves a static or lazy request timeout']],
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError']);
    if (parent.startsWith('capture:fal:') && specifier === 'capture:json-reader')
      return this.projection(parent, specifier, errors, [
        ['const PROVIDER_RESPONSE_MAX_BYTES =', 'const SHORT_BEARER_TOKEN_PATTERN ='],
        ['function readProviderResponseBytes(', 'type ProviderHttpErrorOptions ='],
        ['export async function readProviderJsonResponse<T>(', 'export async function readProviderJsonObjectResponse('],
      ], 'const readResponseWithLimit=globalThis.__platform.read;', ['readProviderJsonResponse']);
    if (parent.startsWith('capture:fal:') && specifier === 'capture:base-url')
      return this.projection(parent, specifier, config,
        [['export function normalizeBaseUrl(baseUrl:', '// Header keys are compared case-insensitively']],
        '', ['normalizeBaseUrl']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation')
      return this.alias(importer, specifier, assets, ['imageFileExtensionForMimeType', 'toImageDataUrl']);
    if ([entry, http].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime')
      return this.binding(importer, specifier, 'whole-source-export-alias', ['isRecord', 'normalizeLowercaseStringOrEmpty', 'normalizeOptionalString'],
        `export {isRecord} from 'capture:source:${records}';export {normalizeLowercaseStringOrEmpty,normalizeOptionalString} from 'capture:source:${strings}';`);
    if (importer === entry && specifier === './http-config.js') return this.source(importer, specifier, http);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime')
      return this.projection(importer, specifier, caps, [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']],
        `import {maxBytesForKind} from 'capture:source:${constants}';`, ['resolveGeneratedImageDownloadMaxBytes']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http')
      return this.binding(importer, specifier, 'source-deadline-json-and-successful-status-facade',
        ['assertOkOrThrowHttpError', 'assertOkOrThrowProviderError', 'createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'readProviderJsonResponse'],
        `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs} from 'capture:deadlines';
export {readProviderJsonResponse} from 'capture:json-reader';
export const assertOkOrThrowHttpError=globalThis.__platform.status;export const assertOkOrThrowProviderError=globalThis.__platform.status;`);
    if (importer === http && specifier === 'openclaw/plugin-sdk/provider-http')
      return this.binding(importer, specifier, 'source-base-url-and-successful-config-facades',
        ['resolveProviderHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest'],
        `import {normalizeBaseUrl} from 'capture:base-url';
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;
export const resolveProviderHttpRequestConfig=params=>globalThis.__platform.config(params,normalizeBaseUrl(params.baseUrl,params.defaultBaseUrl));`);
    if (importer === http && specifier === 'openclaw/plugin-sdk/provider-auth-runtime')
      return this.binding(importer, specifier, 'successful-explicit-synthetic-key-facade', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.key;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth')
      return this.binding(importer, specifier, 'uninvoked-availability-facade', ['isProviderApiKeyConfiguredAsync'],
        'export const isProviderApiKeyConfiguredAsync=globalThis.__platform.unused;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/ssrf-runtime')
      return this.binding(importer, specifier, 'successful-no-network-guarded-fetch-facade', ['fetchWithSsrFGuard'],
        'export const fetchWithSsrFGuard=globalThis.__platform.fetch;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/response-limit-runtime')
      return this.binding(importer, specifier, 'successful-lower-body-reader-facade', ['readResponseWithLimit'],
        'export const readResponseWithLimit=globalThis.__platform.read;');
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared FAL image import: ${importer} -> ${specifier}`);
  }
  sanitize(request) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: request ?? null, output: output ?? null,
      implementation: 'successful-configured-request-sanitizer-facade' }); return output;
  }
  config(params, normalizedBase) {
    const headers = new Headers(params.defaultHeaders);
    for (const [key, value] of Object.entries(this.current.services.resolvedHeaders ?? {})) headers.set(key, value);
    const output = { baseUrl: normalizedBase, headers: Object.fromEntries(headers), dispatcherPolicy: null };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, transport: params.transport,
      baseUrl: params.baseUrl ?? null, defaultBaseUrl: params.defaultBaseUrl, allowPrivateNetwork: params.allowPrivateNetwork,
      defaultHeaders: plain(params.defaultHeaders), request: params.request ?? null, output,
      implementation: 'successful-provider-http-request-config-facade' });
    this.current.now += 3;
    return { baseUrl: normalizedBase, headers, dispatcherPolicy: undefined };
  }
  async fetch(params) {
    const post = params.init?.method === 'POST';
    const receipt = { url: params.url, method: params.init?.method ?? 'GET',
      headers: params.init?.headers ? Object.fromEntries(new Headers(params.init.headers)) : {},
      timeoutMs: params.timeoutMs ?? null, atMs: this.current.now, auditContext: params.auditContext,
      dispatcherPolicy: params.dispatcherPolicy ?? null, initSupplied: params.init !== undefined, releaseCount: 0 };
    let response;
    if (post) {
      assert.equal(typeof params.init.body, 'string');
      Object.assign(receipt, { kind: 'json', rawBody: params.init.body, body: JSON.parse(params.init.body), jsonBody: JSON.parse(params.init.body) });
      this.current.request = receipt; this.current.now += 7;
      response = new Response(JSON.stringify(this.current.response.json), { status: 200, headers: { 'content-type': 'application/json' } });
    } else {
      const index = this.current.downloads.length; const download = this.current.response.downloads[index];
      assert.ok(download, 'declared ordinary download'); this.current.downloads.push(receipt); this.current.now += 5;
      response = new Response(Buffer.from(download.bytesBase64, 'base64'), { status: 200,
        headers: download.mimeType === undefined ? {} : { 'content-type': download.mimeType } });
    }
    this.current.responses.set(response, receipt);
    return { response, release: async () => {
      receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now;
      this.current.releaseCalls.push({ kind: post ? 'post' : 'download', url: receipt.url,
        releaseCount: receipt.releaseCount, atMs: this.current.now });
    } };
  }
  async read(response, maxBytes, options) {
    const receipt = this.current.responses.get(response); assert.ok(receipt);
    const kind = receipt.method === 'POST' ? 'json' : 'binary'; receipt.maxBytes = maxBytes;
    this.current.readerCalls.push({ kind, maxBytes, chunkTimeoutMs: options?.chunkTimeoutMs ?? null,
      hasOnIdleTimeout: typeof options?.onIdleTimeout === 'function', hasOnOverflow: typeof options?.onOverflow === 'function',
      atMs: this.current.now, implementation: 'successful-lower-body-reader-facade' });
    const bytes = Buffer.from(await response.arrayBuffer()); assert.ok(bytes.length <= maxBytes);
    this.current.now += kind === 'json' ? 3 : 2; return bytes;
  }
  async run(vector) {
    this.current = { response: plain(vector.response), services: plain(vector.services ?? {}), request: undefined,
      downloads: [], readerCalls: [], statusCalls: [], configCalls: [], sanitizeCalls: [], keyCalls: [], releaseCalls: [],
      responses: new Map(), now: 100000 };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) => ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') }));
    const req = { ...input, provider: 'fal', cfg: { models: { providers: { fal: {
      baseUrl: vector.config.baseUrl, ...(vector.config.request ? { request: vector.config.request } : {}),
    } } }, ...(vector.config.mediaMaxMb !== undefined ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg); this.context.__req = req; let timer;
    try {
      const promise = new vm.Script('__exports.buildFalImageGenerationProvider().generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('FAL fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') }));
      assert.deepEqual(plain(after), vector.input);
      assert.equal(this.current.request.releaseCount, 1);
      assert.ok(this.current.downloads.every(row => row.releaseCount === 1));
      return { ...vector, inputAfter: plain(after), request: this.current.request, downloads: this.current.downloads,
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls, configCalls: this.current.configCalls,
        sanitizeCalls: this.current.sanitizeCalls, keyCalls: this.current.keyCalls, releaseCalls: this.current.releaseCalls,
        releaseCount: this.current.releaseCalls.length,
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { key: 2, config: 3, post: 7, jsonRead: 3, download: 5, binaryRead: 2 } } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureFalImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new FalHarness(root, before.tracked); await harness.load(entry);
  const providerDescriptor = harness.call('(()=>{const {generateImage,isConfiguredAsync,...descriptor}=__exports.buildFalImageGenerationProvider();return descriptor;})()');
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), source);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: FAL_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-fal-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    serviceFacadeLedger: [
      { name: 'resolveApiKeyForProvider', executed: false, limit: 'Fixed synthetic explicit key context; production credentials/env/profile discovery unexecuted.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, limit: 'Literal successful sanitized request facade; production policy unexecuted.' },
      { name: 'resolveProviderHttpRequestConfig', executed: false, limit: 'Original normalizeBaseUrl executes and feeds actual base; native Headers plus declared successful header output. Generic config/auth/transport policy unexecuted.' },
      { name: 'fetchWithSsrFGuard', executed: false, limit: 'No-network call-recording facade returns successful native Responses and release callbacks. No security/permission/TLS/proxy/DNS/redirect behavior executed.' },
      { name: 'assertOkOrThrowHttpError/assertOkOrThrowProviderError', executed: false, limit: 'Successful status-200 facade; production errors unexecuted.' },
      { name: 'readResponseWithLimit', executed: false, limit: 'Successful lower reader uses native Response.arrayBuffer for tiny bytes, records source-selected cap/idle options. Production bounded stream/timer enforcement unexecuted.' },
      { name: 'isProviderApiKeyConfiguredAsync', executed: false, limit: 'Uninvoked availability facade; manifest and registration are provenance only.' },
    ],
    staticMetadataContradictions: [
      'Krea inherits advertised maxCount 4 and png/jpeg formats, while callback permits count omitted/1 and no outputFormat override.',
      'Exact GPT Image 2.5 inherits 4:1,1:4,8:1,1:8 metadata; callback geometry rejects those extremes. Inventory only; no such callback executions.',
      'Flux edit advertises supportsAspectRatio but singular-image callback rejects aspectRatio. Positive edit rows omit it.',
      'Exact-only geometry metadata differs from prefix callback routing on nonenumerated paths; no outer runtime normalization executes.',
    ],
    limits: [
      'Complete unchanged 698-line FAL provider and complete 48-line HTTP context execute, including all eight descriptor models and all eight routing schemas. Whole original image-assets/number/string/record/base64/constants modules load; only helpers called by FAL establish callback evidence.',
      'Complete original cap/deadline/normalizeBaseUrl and 16MiB JSON cap/readProviderResponseBytes/readProviderJsonResponse regions execute with fatal TextDecoder and JSON.parse. Lower successful body-reader facade records original JSON idle 30000ms and binary cap arguments; no bounded stream/timer enforcement claim.',
      'All 58,558 tracked reference blobs, modes and symlinks verified before and after; original/generated/executable source regions, imports, fixed Node24.22.1, exporter and unchanged shared FactoryHarness have reconstructable receipts. Manifest/registration remain provenance only.',
      'Raw callback only. Explicit public base in every row, explicit model/finite timeout except one source-only defaults row. Configured header row is source-only synthetic ordinary context. Original base trim/trailing-slash normalization feeds the facade; no fabricated effective base.',
      'Every positive row stays inside descriptor and callback bounds: Krea count omitted/1, no explicit format/resolution; GPT2.5 no resolution or extreme ratios; Flux edits no ratio; empty resolution lists receive no override. One-factor values cover all families, routes, reference maxima and ordinary options without Cartesian expansion.',
      'Original POST JSON string and ordered URL GETs execute. GETs have no generation init/headers/dispatcherPolicy. Shared absolute deadline includes 5ms key/config cost; synthetic successful service costs record decreasing remaining timeout without timing out. Download releases each once before POST release once.',
      'Reference bytes become ordered data URLs; filenames ignored and missing/blank MIME defaults PNG. Output MIME trims while preserving case/parameters; absent/blank defaults PNG without sniffing. Source output names and optional trimmed metadata.prompt execute. Tiny bytes are protocol evidence, not image codec/visual validity.',
      'No retry/poll/upload/multipart/inline-output path, outer-runtime geometry normalization, failure/negative/mixed/overflow/cancel/crash/security/auth/permission/TLS/private-policy test or real provider/network request executes.',
      'Inactive independent source oracle only; no tool/catalog activation, storage/jobs/delivery or complete P10/reference-goal claim.',
    ], providerDescriptor, observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2); assert.equal(args.indexOf('--out'), 1);
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureFalImageGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
