// Pinned complete direct image provider, native multipart, and synthetic successful HTTP.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path, { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const OPENAI_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openai/image-generation-provider.ts';
const response = 'extensions/openai/image-generation-response.ts';
const assets = 'src/image-generation/image-assets.ts';
const urls = 'src/image-generation/openai-compatible-image-urls.ts';
const geometry = 'src/media-generation/runtime-shared.ts';
const caps = 'src/media/configured-max-bytes.ts';
const shared = 'extensions/openai/shared.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, response, assets, urls,
  'extensions/openai/base-url.ts', 'extensions/openai/default-models.ts',
  'src/plugin-sdk/blob-runtime.ts', 'packages/media-core/src/base64.ts',
  'packages/media-core/src/constants.ts', 'packages/media-core/src/mime.ts',
  'packages/media-core/src/file-name.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/record-coerce.ts',
  'packages/normalization-core/src/utf16-slice.ts'];
const provenancePaths = ['src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/provider-http.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugin-sdk/provider-onboard.ts',
  'src/plugin-sdk/media-generation-runtime.ts', 'src/plugin-sdk/ssrf-policy.ts',
  'src/plugin-sdk/media-mime.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/agents/provider-http-errors.ts', 'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts',
  'src/infra/http-body.ts', 'extensions/openai/provider-policy-api.ts',
  'extensions/openai/index.ts', 'extensions/openai/openclaw.plugin.json'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENAI_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENAI_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: OPENAI_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${OPENAI_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// Small image payloads exercise protocol bytes only; no codec or visual-quality claim.
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==';
const webp = 'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA';

function vectors() {
  const input = { prompt: ' Draw a small blue square. ', model: 'gpt-image-1.5', timeoutMs: 12345 };
  const inline = (bytes = png, extra = {}) => ({ b64_json: bytes, ...extra });
  const base = (id, overrides = {}, json = { data: [inline()] }, options = {}) => ({ id,
    hostComparable: true, input: { ...input, ...overrides },
    config: { baseUrl: 'https://api.openai.com/v1', ...options.config },
    response: { json, downloads: options.downloads ?? [] },
    ...(options.apiVersion ? { config: { baseUrl: 'https://images.openai.azure.com/openai/v1/', apiVersion: options.apiVersion } } : {}),
    ...(options.hostComparable === false ? { hostComparable: false, adaptationReason: options.adaptationReason } : {}) });
  return [
    base('default-size'),
    base('explicit-count', { model: 'gpt-image-2', count: 4 }, { data: [inline(), inline(), inline(), inline()] }),
    base('legacy-closest-size', { model: 'gpt-image-1', size: '1600x900' }),
    base('native-closest-size', { size: '2048x1536' }),
    base('flexible-gpt-image-2', { model: 'gpt-image-2', size: '1600x960' }),
    base('flexible-dated-model', { model: 'gpt-image-2-2026-04-21', size: '1600x960' }),
    base('flexible-gpt-image-2.5', { model: 'gpt-image-2.5-flare', size: '1600x960', quality: 'xhigh' }),
    base('auto-gpt-image-2.5', { model: 'gpt-image-2.5-sunburst', size: 'auto', quality: 'max' }),
    base('jpeg-options', { outputFormat: 'jpeg', quality: 'high', background: 'opaque',
      providerOptions: { openai: { background: 'auto', moderation: 'low', outputCompression: 73, user: 'fixture-user' } } },
    { data: [inline(jpeg, { revised_prompt: ' \u00a0Refined square.\n ' })] }),
    base('webp-options', { outputFormat: 'webp', providerOptions: { openai: { outputCompression: 80 } } }, { data: [inline(webp)] }),
    base('png-options', { outputFormat: 'png', background: 'transparent',
      providerOptions: { openai: { outputCompression: 80 } } }),
    base('custom-prefix', { model: 'Vendor/Image-X', size: '1280x720', quality: 'high' }, undefined,
      { config: { baseUrl: ' https://images.example.test/custom/v2/// ' } }),
    base('edit-one', { inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: '  photos/day/square.png  ' }] }),
    base('edit-many-native-mime', { model: 'gpt-image-2.5-flare', count: 2, outputFormat: 'jpeg', quality: 'xhigh',
      inputImages: [{ bytesBase64: png }, { bytesBase64: jpeg, mimeType: ' Image/JPEG; ColorSpace=RGB ' },
        { bytesBase64: webp, mimeType: 'image/webp' }] }, { data: [inline(jpeg), inline(jpeg)] }),
    base('ordered-inline', { count: 3 }, { data: [inline(png, { mime_type: ' image/png ', revised_prompt: ' First ' }),
      inline(jpeg, { mime_type: 'Image/JPEG; mode=RGB', revised_prompt: ' \n ' }), inline(webp, { mime_type: 'image/webp' })] }),
    base('ordered-urls', { count: 2 }, { data: [{ url: 'https://assets.example.test/one', revised_prompt: ' One ' },
      { url: 'https://assets.example.test/two', revised_prompt: ' Two ' }] }, { downloads: [
      { url: 'https://assets.example.test/one', contentType: 'Image/JPEG; charset=binary', bytesBase64: jpeg },
      { url: 'https://assets.example.test/two', contentType: 'image/webp', bytesBase64: webp }] }),
    base('mixed-inline-url', { count: 3 }, { data: [inline(), { url: 'https://assets.example.test/middle' },
      inline(webp, { mime_type: 'image/webp', url: 'https://assets.example.test/unused-inline-url' })] }, { downloads: [
      { url: 'https://assets.example.test/middle', contentType: 'image/jpeg', bytesBase64: jpeg }] }),
    base('usage-zero-nested', {}, { data: [inline()], usage: { input_tokens: 0, output_tokens: 2, total_tokens: 2,
      input_tokens_details: { text_tokens: 0, image_tokens: 0 }, output_tokens_details: { text_tokens: 0, image_tokens: 2 } } }),
    base('usage-absent', {}, { data: [inline()] }),
    base('azure-default-version', { model: 'square-deployment', size: '1600x900' }, undefined,
      { config: { baseUrl: 'https://images.openai.azure.com/openai/v1/' } }),
    base('azure-explicit-version-edit', { model: 'square-deployment',
      inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: 'square.png' }] }, undefined,
    { apiVersion: '2025-04-01-preview' }),
    base('source-only-transparent-reroute', { model: 'gpt-image-2', background: 'transparent' }, undefined,
      { hostComparable: false,
        adaptationReason: 'Pinned public default gpt-image-2 transparently reroutes to gpt-image-1.5. Synapsis preserves the explicit selected model and requires a compatible selection before HTTP.' }),
  ];
}

class ImageGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, FormData, Blob, File, Headers, Response, URL,
      process: { env: {} }, fetch: () => { throw Error('Network is outside the image fixture boundary'); },
      __platform: { path, post: params => this.post(params), download: params => this.download(params),
        readJson: async (res, _label, options) => {
          this.current.readerCalls.push({ kind: 'json', maxBytes: options.maxBytes, timeoutMs: options.timeoutMs() });
          return res.json();
        },
        readBinary: async (res, _label, _kind, options) => {
          this.current.readerCalls.push({ kind: 'binary', maxBytes: options.maxBytes, timeoutMs: options.timeoutMs() });
          const download = this.current.downloads.at(-1);
          download.maxBytes = options.maxBytes;
          return Buffer.from(await res.arrayBuffer());
        } } }, { codeGeneration: { strings: false, wasm: false } });
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.dynamicImports = [];
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
      importModuleDynamically: async specifier => {
        this.dynamicImports.push({ importer: source, specifier });
        const dependency = this.import(specifier, file);
        if (dependency.status === 'unlinked') await dependency.link((name, importer) => this.import(name, importer.identifier));
        if (dependency.status === 'linked') await dependency.evaluate({ timeout: 1000 });
        assert.equal(dependency.status, 'evaluated');
        return dependency;
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

  unused(importer, specifier, exports, source) {
    return this.binding(importer, specifier, 'uninvoked-dependency-facade', exports,
      exports.map(name => `export function ${name}(){throw Error('Uninvoked image dependency: ${name}');}`).join('\n'),
      { source, sourceSha256: this.tracked.get(source), originalSourceExecuted: false });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:image-generation:') && specifier.startsWith('capture:source:')) {
      return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    }
    if (specifier === 'node:path' && [entry, 'packages/media-core/src/mime.ts', 'packages/media-core/src/file-name.ts'].includes(importer)) {
      return this.binding(importer, specifier, 'actual-platform-builtin', ['default'],
        'export default globalThis.__platform.path;', { platform: 'node:path (Linux POSIX)' });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/blob-runtime') return this.alias(importer, specifier, 'src/plugin-sdk/blob-runtime.ts', ['bufferToBlobPart']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-mime') return this.alias(importer, specifier, 'packages/media-core/src/mime.ts', ['extensionForMime'], 'src/plugin-sdk/media-mime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/number-runtime') return this.alias(importer, specifier, 'packages/normalization-core/src/number-coercion.ts', ['resolveIntegerOption']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/text-utility-runtime') return this.alias(importer, specifier, 'packages/normalization-core/src/utf16-slice.ts', ['truncateUtf16Safe']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/ssrf-policy') return this.binding(importer, specifier,
      'successful-policy-fixture', ['isPrivateNetworkOptInEnabled'], 'export function isPrivateNetworkOptInEnabled(){return false;}',
      { source: 'src/plugin-sdk/ssrf-policy.ts', sourceSha256: this.tracked.get('src/plugin-sdk/ssrf-policy.ts'), originalSourceExecuted: false });
    if (specifier === 'openclaw/plugin-sdk/provider-onboard' && [entry, 'extensions/openai/default-models.ts'].includes(importer)) {
      return this.unused(importer, specifier, ['resolveAgentModelFallbackValues', 'resolveAgentModelPrimaryValue',
        'applyAgentDefaultModelPrimary', 'ensureModelAllowlistEntry'], 'src/plugin-sdk/provider-onboard.ts');
    }
    if (importer === entry && specifier === './provider-policy-api.js') return this.unused(importer, specifier,
      ['resolveModelAuthPolicy'], 'extensions/openai/provider-policy-api.ts');
    if (importer === entry && specifier === './shared.js') return this.projection(importer, specifier, shared,
      'export function resolveConfiguredOpenAIBaseUrl(', '\ntype OpenAIResponsesProviderHooks',
      `import {normalizeOptionalString} from 'capture:source:packages/normalization-core/src/string-coerce.ts';\nimport {OPENAI_API_BASE_URL} from 'capture:source:extensions/openai/base-url.ts';`, ['resolveConfiguredOpenAIBaseUrl']);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth-runtime') return this.binding(importer, specifier,
      'successful-explicit-key-fixture', ['resolveApiKeyForProvider'],
      "export async function resolveApiKeyForProvider(){return {apiKey:'fixture-openai-images',mode:'api-key'};}",
      { source: 'src/plugin-sdk/provider-auth-runtime.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth-runtime.ts'),
        originalSourceExecuted: false, boundary: 'Fixed synthetic successful direct configuration only; credential lookup and profiles are not executed or tested.' });
    if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime' && [entry, response, 'extensions/openai/base-url.ts'].includes(importer)) {
      const code = `export {filterStringRecord,asOptionalRecord} from 'capture:source:packages/normalization-core/src/record-coerce.ts';\nexport {asSafeIntegerInRange} from 'capture:source:packages/normalization-core/src/number-coercion.ts';\nexport {normalizeOptionalString} from 'capture:source:packages/normalization-core/src/string-coerce.ts';`;
      return this.binding(importer, specifier, 'whole-source-export-alias', ['filterStringRecord', 'asOptionalRecord', 'asSafeIntegerInRange', 'normalizeOptionalString'], code,
        { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    }
    if (specifier === 'openclaw/plugin-sdk/provider-http' && [entry, response].includes(importer)) {
      return this.binding(importer, specifier, 'successful-native-http-reader-fixture',
        ['createProviderOperationDeadline', 'postJsonRequest', 'postMultipartRequest', 'resolveProviderHttpRequestConfig',
          'sanitizeConfiguredModelProviderRequest', 'assertOkOrThrowHttpError', 'readProviderJsonResponse', 'resolveProviderOperationTimeoutMs'], `
export function createProviderOperationDeadline(params){return params;}
export const postJsonRequest=globalThis.__platform.post;
export const postMultipartRequest=globalThis.__platform.post;
export function resolveProviderHttpRequestConfig(params){return {baseUrl:params.baseUrl.trim().replace(/\\/+$/,''),headers:{},allowPrivateNetwork:false};}
export function sanitizeConfiguredModelProviderRequest(){return undefined;}
export async function assertOkOrThrowHttpError(){}
export const readProviderJsonResponse=globalThis.__platform.readJson;
export function resolveProviderOperationTimeoutMs(params){return params.deadline.timeoutMs;}
`, { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'),
        originalSourceExecuted: false,
        boundary: 'Native successful Response.json, explicit config, fixed deadline and request recorder; production HTTP, bounded reader, retries and deadline enforcement unexecuted.' });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      const projectedGeometry = this.projection(importer, 'capture:geometry', geometry,
        'function normalizeSupportedValues<', '/** Chooses the closest supported resolution',
        `import {normalizeOptionalString} from 'capture:source:packages/normalization-core/src/string-coerce.ts';`, ['resolveClosestSize']);
      const projectedCaps = this.projection(importer, 'capture:caps', caps,
        'const MB = 1024 * 1024;', '/** Reads channel/account media caps',
        `import {maxBytesForKind} from 'capture:source:packages/media-core/src/constants.ts';`, ['resolveGeneratedImageDownloadMaxBytes']);
      this.modules.set('capture:image-geometry', projectedGeometry);
      this.modules.set('capture:image-caps', projectedCaps);
      return this.binding(importer, specifier, 'source-region-export-alias', ['resolveClosestSize', 'resolveGeneratedImageDownloadMaxBytes'],
        "export {resolveClosestSize} from 'capture:image-geometry';\nexport {resolveGeneratedImageDownloadMaxBytes} from 'capture:image-caps';",
        { origin: 'src/plugin-sdk/media-generation-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
    }
    if (parent.startsWith('capture:image-generation:') && ['capture:image-geometry', 'capture:image-caps'].includes(specifier)) return this.modules.get(specifier);
    if (importer === response && specifier === 'openclaw/plugin-sdk/image-generation') {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['inlineOpenAiCompatibleImageUrls', 'parseOpenAiCompatibleImageResponse', 'resolveInlineImageJsonResponseMaxBytes'],
        `export {inlineOpenAiCompatibleImageUrls} from 'capture:source:${urls}';\nexport {parseOpenAiCompatibleImageResponse,resolveInlineImageJsonResponseMaxBytes} from 'capture:source:${assets}';`,
        { origin: 'src/plugin-sdk/image-generation.ts', originSha256: this.tracked.get('src/plugin-sdk/image-generation.ts') });
    }
    if (importer === urls && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier,
      'successful-binary-reader-fixture', ['assertOkOrThrowHttpError', 'readProviderBinaryResponse'],
      'export async function assertOkOrThrowHttpError(){}\nexport const readProviderBinaryResponse=globalThis.__platform.readBinary;',
      { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    if (importer === urls && specifier === '../infra/net/fetch-guard.js') return this.binding(importer, specifier,
      'successful-native-download-fixture', ['fetchWithSsrFGuard'], 'export const fetchWithSsrFGuard=globalThis.__platform.download;',
      { source: 'src/infra/net/fetch-guard.ts', sourceSha256: this.tracked.get('src/infra/net/fetch-guard.ts'), originalSourceExecuted: false });
    if (importer === urls && specifier === '../infra/net/ssrf.js') return this.binding(importer, specifier,
      'successful-policy-fixture', ['mergeSsrFPolicies'], 'export function mergeSsrFPolicies(){return undefined;}',
      { source: 'src/infra/net/ssrf.ts', sourceSha256: this.tracked.get('src/infra/net/ssrf.ts'), originalSourceExecuted: false });
    const packages = {
      '@openclaw/normalization-core/number-coercion': 'packages/normalization-core/src/number-coercion.ts',
      '@openclaw/normalization-core/string-coerce': 'packages/normalization-core/src/string-coerce.ts',
      '@openclaw/normalization-core/record-coerce': 'packages/normalization-core/src/record-coerce.ts',
      '@openclaw/media-core/base64': 'packages/media-core/src/base64.ts',
      '@openclaw/media-core/constants': 'packages/media-core/src/constants.ts',
    };
    if (packages[specifier]) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared image-generation import: ${importer} -> ${specifier}`);
  }

  async post(params) {
    const request = { url: params.url, method: 'POST', timeoutMs: params.timeoutMs };
    if (params.body instanceof FormData) {
      request.formEntries = [];
      for (const [name, value] of params.body) {
        if (typeof value === 'string') request.formEntries.push({ name, value });
        else {
          assert.ok(value instanceof File);
          request.formEntries.push({ name, fileName: value.name, mimeType: value.type, size: value.size,
            bytesBase64: Buffer.from(await value.arrayBuffer()).toString('base64') });
        }
      }
      // Exercise native multipart serialization while omitting its random boundary.
      const serialized = Buffer.from(await new Response(params.body).arrayBuffer()).toString('latin1');
      const partMimes = [...serialized.matchAll(/Content-Type: ([^\r\n]+)/gi)].map(match => match[1]);
      assert.deepEqual(partMimes, request.formEntries.filter(row => row.fileName).map(row => row.mimeType));
    } else request.jsonBody = plain(params.body);
    this.current.requests.push(request);
    return { response: new Response(JSON.stringify(this.current.response.json), { status: 200,
      headers: { 'content-type': 'application/json' } }), release: async () => { this.current.releaseCount += 1; } };
  }

  async download(params) {
    const fixture = this.current.response.downloads[this.current.downloads.length];
    assert.ok(fixture, 'declared ordinary URL download');
    assert.equal(params.url, fixture.url);
    const receipt = { url: params.url, method: params.init.method, timeoutMs: params.timeoutMs, releaseCount: 0 };
    this.current.downloads.push(receipt);
    return { response: new Response(Buffer.from(fixture.bytesBase64, 'base64'), { status: 200,
      headers: { 'content-type': fixture.contentType } }), release: async () => { receipt.releaseCount += 1; } };
  }

  async run(vector) {
    this.current = { response: plain(vector.response), requests: [], downloads: [], releaseCount: 0, readerCalls: [] };
    this.context.process.env = vector.config.apiVersion ? { AZURE_OPENAI_API_VERSION: vector.config.apiVersion } : {};
    const { inputImages, ...input } = plain(vector.input);
    const req = { ...input, provider: 'openai', cfg: { models: { providers: { openai: {
      apiKey: 'fixture-openai-images', auth: 'api-key', baseUrl: vector.config.baseUrl } } } },
      ...(inputImages ? { inputImages: inputImages.map(({ bytesBase64, ...image }) => ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') })) } : {}) };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildOpenAIImageGenerationProvider({}).generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Image fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.equal(this.current.requests.length, 1);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, inputImages: afterImages, ...afterInput } = req;
      const inputAfter = { ...plain(afterInput), ...(afterImages ? { inputImages: afterImages.map(({ buffer, ...image }) =>
        ({ ...plain(image), bytesBase64: buffer.toString('base64') })) } : {}) };
      assert.deepEqual(inputAfter, vector.input);
      return { ...vector, inputAfter, request: this.current.requests[0],
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) =>
          ({ ...image, bytesBase64: buffer.toString('base64') })) }),
        downloads: this.current.downloads, releaseCount: this.current.releaseCount, readerCalls: this.current.readerCalls };
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenAIImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  const harness = new ImageGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source));
    assert.equal(hash(bytes), before.tracked.get(source), source);
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: OPENAI_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-openai-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt },
    transformation: transform, sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    limits: [
      'Complete unchanged provider.generateImage, response wrapper, asset parser, URL inlining, Blob helper, normalization/base64/numeric/MIME modules execute. Three complete original source regions provide configured base URL, geometry and download cap; byte offsets, source-region/generated/executable hashes reconstruct each projection.',
      'All 58,558 tracked reference blobs are verified before/after; source, executable, exporter, shared harness, runtime, per-import facade and source projection hashes are recorded.',
      'Lower HTTP, configuration/key lookup, account/profile/policy, status and bounded stream reader bodies are unexecuted synthetic successful facades. Native Response.json/arrayBuffer records limits and native FormData/Blob/File serializes actual bytes; no retry, timeout enforcement, real network, credential discovery or registration claim.',
      'Response cap is the actual source formula ceil(64 MiB * requested count * 4/3) + 1 MiB. Actual download cap is 64 MiB. Recorded limits do not verify production overflow or streaming behavior.',
      'Ordered multipart entries omit native random boundaries and File.lastModified. Filenames use Linux node:path basename; native Blob MIME lowercasing preserves parameters. Small image bytes are protocol fixtures without codec or visual-quality verification.',
      'Azure default version and explicit version execute through a per-vector synthetic VM process.env object; the host uses explicit config, with no real environment lookup or mutation.',
      'Source-only transparent gpt-image-2 reroute is hostComparable=false: Synapsis preserves selected model and requires explicit compatible selection. It is not a host equivalence or enabled model-routing claim.',
      'Inactive provider groundwork only: no tool/catalog/config enablement, files, durable media, task lifecycle, delivery, real provider or whole P10/reference-goal completion.',
    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-openai-image-generation.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureOpenAIImageGeneration(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
