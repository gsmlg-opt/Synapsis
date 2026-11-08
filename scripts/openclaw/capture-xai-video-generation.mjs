// Pinned complete xAI video provider and real shared polling/assets under synthetic successful I/O.
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

export const XAI_VIDEO_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/xai/video-generation-provider.ts';
const metadata = 'extensions/xai/capability-provider-metadata.ts';
const metadataFactory = 'extensions/xai/capability-provider-metadata-factory.ts';
const assets = 'src/media-generation/provider-assets.ts';
const imageAssets = 'src/image-generation/image-assets.ts';
const deadlines = 'src/media-understanding/shared.ts';
const caps = 'src/media/configured-max-bytes.ts';
const duration = 'src/video-generation/duration-support.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const nonce = '00000000-0000-4000-8000-000000000001';
const wholeSources = [entry, assets, imageAssets, duration, 'src/video-generation/capabilities.ts',
  'src/shared/positive-duration.ts', number, strings, records,
  'packages/normalization-core/src/string-normalization.ts', 'packages/media-core/src/base64.ts',
  'packages/media-core/src/constants.ts', 'packages/media-core/src/mime.ts', 'packages/media-core/src/file-name.ts'];
const provenancePaths = ['src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/video-generation.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/number-runtime.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/agents/provider-http-errors.ts', 'src/infra/http-body.ts',
  'src/infra/backoff.ts', 'src/infra/net/fetch-guard.ts', 'src/provider-runtime/operation-retry.ts',
  'extensions/xai/index.ts', 'extensions/xai/openclaw.plugin.json'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), XAI_VIDEO_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', XAI_VIDEO_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: XAI_VIDEO_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${XAI_VIDEO_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// Tiny protocol bytes; no video decoding, visual quality or production reader claim.
const mp4 = Buffer.from([0, 0, 0, 20, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0, 109, 112, 52, 50]).toString('base64');
const webm = Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x84, 0x42, 0x82, 0x84, 0x77, 0x65, 0x62, 0x6d]).toString('base64');
const avi = Buffer.from([0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x41, 0x56, 0x49, 0x20]).toString('base64');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';

function vectors() {
  const base = (id, input = {}, options = {}) => ({ id, hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    timeoutSemantics: options.omitTimeout ? 'source-only-omitted-timeout-stage-budgets' : 'explicit-shared-total-budget',
    input: { prompt: ' Make the blue square turn slowly. ', ...(options.omitTimeout ? {} : { timeoutMs: 30000 }), ...input },
    config: { baseUrl: 'https://api.x.ai/v1', ...options.config },
    response: { submit: { request_id: ' req-video-1 ' },
      polls: options.polls ?? [{ status: 'done', video: { url: ' https://assets.example.test/generated-video ' } }],
      download: { url: 'https://assets.example.test/generated-video', bytesBase64: options.bytesBase64 ?? mp4,
        ...(options.omitContentType ? {} : { contentType: options.contentType ?? 'video/mp4' }) } },
  });
  const frame = { url: ' https://assets.example.test/frame.png ' };
  const video = [{ url: ' https://assets.example.test/input.mp4 ' }];
  return [
    base('default-text'),
    base('explicit-model-prompt', { model: ' Vendor/Video-X ', prompt: '  Preserve this exact prompt.\n' }),
    base('duration-rounded', { durationSeconds: 8.6 }),
    base('duration-minimum', { durationSeconds: 0.6 }),
    base('duration-maximum', { durationSeconds: 99 }),
    ...['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'].map(ratio => base('ratio-' + ratio.replace(':', '-'), { aspectRatio: ` ${ratio} ` })),
    base('generic-1080p', { resolution: ' 1080P ' }),
    ...['grok-imagine-video-1.5', 'grok-imagine-video-1.5-preview', 'grok-imagine-video-1.5-2026-05-30'].map((model, index) =>
      base('v15-' + ['canonical', 'preview', 'dated'][index], { model, resolution: '1080p', inputImages: [{ ...frame, role: 'FIRST_FRAME' }] })),
    base('frame-url', { inputImages: [frame] }),
    base('frame-explicit-ratio', { inputImages: [frame], aspectRatio: '9:16', resolution: '720P' }),
    base('frame-bytes-default-mime', { inputImages: [{ bytesBase64: png }] }),
    base('frame-bytes-explicit-mime', { inputImages: [{ bytesBase64: png, mimeType: ' image/png ' }] }),
    base('frame-url-preferred', { inputImages: [{ ...frame, bytesBase64: png, mimeType: 'image/png' }] }),
    base('ordered-references', { durationSeconds: 15, resolution: '1080p', inputImages: [
      { url: ' https://assets.example.test/ref-one ', role: ' ReFeReNcE_ImAgE ' },
      { bytesBase64: png, role: 'REFERENCE_IMAGE' },
      { url: 'https://assets.example.test/ref-three', role: 'reference_image' }] }),
    base('seven-references', { durationSeconds: 10, inputImages: Array.from({ length: 7 }, (_, index) =>
      ({ url: `https://assets.example.test/ref-${index + 1}`, role: 'reference_image' })) }),
    base('remote-video-edit', { inputVideos: video, aspectRatio: '1:1', resolution: '720p' }),
    base('remote-video-extend-minimum', { inputVideos: video, durationSeconds: 1 }),
    base('remote-video-extend-rounded', { inputVideos: video, durationSeconds: 5.6 }),
    base('remote-video-extend-maximum', { inputVideos: video, durationSeconds: 99 }),
    base('custom-base', { model: 'custom-video' }, { config: { baseUrl: ' https://video.example.test/custom/v2/// ' } }),
    base('pending-processing-done', {}, { polls: [{ status: 'pending' }, { status: 'processing' },
      { status: ' DoNe ', video: { url: ' https://assets.example.test/generated-video ' } }] }),
    base('webm-output', {}, { contentType: 'Video/WebM; charset=binary', bytesBase64: webm }),
    base('avi-synonym-output', {}, { contentType: 'video/vnd.avi', bytesBase64: avi }),
    base('default-output-mime', {}, { omitContentType: true }),
    base('explicit-media-cap', {}, { config: { mediaMaxMb: 2.25 } }),
    base('omitted-timeout-stage-budgets', {}, { omitTimeout: true, hostComparable: false,
      adaptationReason: 'Pinned source omits the outer deadline when timeoutMs is absent and resets download stage budget. Synapsis requires an explicit finite total timeout.',
      polls: [{ status: 'pending' }, { status: 'done', video: { url: 'https://assets.example.test/generated-video' } }] }),
  ];
}

class VideoGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, URL,
      fetch: () => { throw Error('Network is outside the video fixture boundary'); },
      crypto: { randomUUID: () => { this.current.nonceCalls += 1; return nonce; } },
      __platform: { path, now: () => this.current.now,
        sleep: async ms => {
          assert.ok(Number.isFinite(ms) && ms > 0 && ms <= 5000);
          assert.ok(this.current.sleeps.length < 120);
          this.current.sleeps.push({ atMs: this.current.now, durationMs: ms });
          this.current.now += ms;
        },
        post: params => this.post(params), fetch: (url, init, timeoutMs, _fetchFn, options) => this.fetchResponse(url, init, timeoutMs, options),
        config: params => this.config(params),
        retry: async params => { this.current.retryCalls.push({ provider: params.provider, stage: params.stage, atMs: this.current.now }); return params.operation(); },
        status: async (response, label) => { assert.equal(response.status, 200); this.current.statusCalls.push({ label, atMs: this.current.now }); },
        readJson: async (response, label, options) => {
          this.current.readerCalls.push({ kind: 'json', label, options: plain(options), atMs: this.current.now });
          return response.json();
        },
        readBinary: async (response, label, kind, options) => {
          this.current.readerCalls.push({ kind: 'binary', label, mediaKind: kind, maxBytes: options.maxBytes,
            chunkTimeoutMs: options.chunkTimeoutMs, timeoutMs: options.timeoutMs(), atMs: this.current.now });
          const bytes = Buffer.from(await response.arrayBuffer());
          this.current.now += 13;
          return bytes;
        } } }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script('Date.now = () => globalThis.__platform.now();').runInContext(this.context, { timeout: 200 });
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
      importModuleDynamically: specifier => {
        this.dynamicImports.push({ importer: source, specifier });
        throw Error(`Undeclared video dynamic import: ${source} -> ${specifier}`);
      } });
    this.modules.set(file, mod);
    return mod;
  }

  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:video-generation:' + key, code);
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

  projectedDeadlines() {
    return this.projection('capture:shared', 'capture:deadlines', deadlines,
      'export function createProviderOperationDeadline(', 'export async function pollProviderOperationJson<',
      `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';
const DEFAULT_GUARDED_HTTP_TIMEOUT_MS = 60000;
const sleepWithAbort = globalThis.__platform.sleep;`,
      ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError',
        'createProviderOperationTimeoutResolver', 'waitProviderOperationPollInterval', 'pollProviderOperation']);
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:video-generation:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:video-generation:') && specifier === 'capture:deadlines') {
      this.projectionEdge(parent, specifier, deadlines);
      return this.projectedDeadlines();
    }
    if (parent.startsWith('capture:video-generation:') && specifier === 'capture:video-metadata-factory') {
      this.projectionEdge(parent, specifier, metadataFactory);
      return this.projectedMetadataFactory();
    }
    if (specifier === 'node:path' && ['packages/media-core/src/mime.ts', 'packages/media-core/src/file-name.ts'].includes(importer)) {
      return this.binding(importer, specifier, 'actual-platform-builtin', ['default'],
        'export default globalThis.__platform.path;', { platform: 'node:path (Linux POSIX)' });
    }
    if (importer === entry && specifier === './capability-provider-metadata.js') {
      return this.projection(importer, specifier, metadata,
        'export function createXaiVideoGenerationProviderMetadata()', 'export function createXaiRealtimeVoiceProviderMetadata()',
        `import {createXaiVideoGenerationProviderMetadata as createXaiVideoGenerationProviderMetadataCore} from 'capture:video-metadata-factory';
export {DEFAULT_XAI_VIDEO_BASE_URL,DEFAULT_XAI_VIDEO_MODEL,XAI_VIDEO_ASPECT_RATIOS,XAI_VIDEO_DEFAULT_TIMEOUT_MS,isXaiVideo15Model} from 'capture:video-metadata-factory';
const isProviderApiKeyConfiguredAsync = async () => { throw Error('Uninvoked video metadata account lookup'); };`,
        ['createXaiVideoGenerationProviderMetadata', 'DEFAULT_XAI_VIDEO_BASE_URL', 'DEFAULT_XAI_VIDEO_MODEL',
          'XAI_VIDEO_ASPECT_RATIOS', 'XAI_VIDEO_DEFAULT_TIMEOUT_MS', 'isXaiVideo15Model']);
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.alias(importer, specifier, imageAssets,
      ['resolveImageSourceUrl'], 'src/plugin-sdk/image-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/number-runtime') return this.alias(importer, specifier, number,
      ['resolvePositiveTimerTimeoutMs'], 'src/plugin-sdk/number-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.binding(importer, specifier,
      'whole-source-export-alias', ['isRecord', 'normalizeOptionalString'],
      `export {isRecord} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`,
      { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/video-generation') return this.alias(importer, specifier, duration,
      ['normalizeVideoGenerationDuration'], 'src/plugin-sdk/video-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      return this.binding(importer, specifier, 'source-region-export-alias', ['downloadGeneratedVideoAsset', 'resolveGeneratedMediaMaxBytes'],
        `export {downloadGeneratedVideoAsset} from 'capture:source:${assets}';\nexport {resolveGeneratedMediaMaxBytes} from 'capture:video-caps';`,
        { origin: 'src/plugin-sdk/media-generation-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
    }
    if (parent.startsWith('capture:video-generation:') && specifier === 'capture:video-caps') {
      this.projectionEdge(parent, specifier, caps);
      return this.projection('capture:shared', specifier, caps,
      'const MB = 1024 * 1024;', '/** Reads channel/account media caps',
      `import {maxBytesForKind} from 'capture:source:packages/media-core/src/constants.ts';`, ['resolveGeneratedMediaMaxBytes']);
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http') {
      return this.binding(importer, specifier, 'successful-transport-config-reader-fixture',
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutResolver',
          'waitProviderOperationPollInterval', 'pollProviderOperation', 'postJsonRequest', 'fetchWithTimeoutGuarded',
          'resolveProviderApiKeyHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest', 'assertOkOrThrowHttpError',
          'readProviderJsonObjectResponse', 'executeProviderOperationWithRetry'],
        `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs,createProviderOperationTimeoutResolver,waitProviderOperationPollInterval,pollProviderOperation} from 'capture:deadlines';
export const postJsonRequest=globalThis.__platform.post;
export const fetchWithTimeoutGuarded=globalThis.__platform.fetch;
export const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;
export function sanitizeConfiguredModelProviderRequest(){return undefined;}
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const readProviderJsonObjectResponse=globalThis.__platform.readJson;
export const executeProviderOperationWithRetry=globalThis.__platform.retry;`,
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
          boundary: 'Actual shared deadlines/polling re-exported. Lower config/account/header/status/transport/retry/JSON reader bodies are successful facades, not production service proof.' });
    }
    if (importer === assets && specifier === '../media-understanding/shared.js') return this.binding(importer, specifier,
      'source-region-export-alias-with-uninvoked-download-facade',
      ['createProviderOperationDeadline', 'createProviderOperationTimeoutResolver', 'fetchProviderDownloadResponse'],
      `export {createProviderOperationDeadline,createProviderOperationTimeoutResolver} from 'capture:deadlines';
export async function fetchProviderDownloadResponse(){throw Error('Uninvoked fallback video download');}`,
      { source: deadlines, sourceSha256: this.tracked.get(deadlines), boundary: 'Provider supplies fetchResponse; fallback download function remains uninvoked.' });
    if (importer === assets && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier,
      'successful-native-binary-reader-fixture', ['readProviderBinaryResponse'],
      'export const readProviderBinaryResponse=globalThis.__platform.readBinary;',
      { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    if (importer === assets && specifier === '../infra/http-body.js') return this.binding(importer, specifier,
      'uninvoked-dependency-facade', ['readResponseWithLimit'],
      "export async function readResponseWithLimit(){throw Error('Uninvoked generic video reader');}",
      { source: 'src/infra/http-body.ts', sourceSha256: this.tracked.get('src/infra/http-body.ts'), originalSourceExecuted: false });
    const packages = {
      '@openclaw/normalization-core/number-coercion': number,
      '@openclaw/normalization-core/string-coerce': strings,
      '@openclaw/normalization-core/record-coerce': records,
      '@openclaw/normalization-core/string-normalization': 'packages/normalization-core/src/string-normalization.ts',
      '@openclaw/media-core/base64': 'packages/media-core/src/base64.ts',
      '@openclaw/media-core/constants': 'packages/media-core/src/constants.ts',
      '@openclaw/media-core/mime': 'packages/media-core/src/mime.ts',
    };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared video-generation import: ${importer} -> ${specifier}`);
  }

  projectionEdge(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'complete-source-region-import',
      source, sourceSha256: this.tracked.get(source) });
  }

  projectedMetadataFactory() {
    return this.projection('capture:shared', 'capture:video-metadata-factory', metadataFactory,
      'export const DEFAULT_XAI_VIDEO_BASE_URL =', 'export type XaiRealtimeTranscriptionEncoding',
      `import {normalizeOptionalString} from 'capture:source:${strings}';`,
      ['createXaiVideoGenerationProviderMetadata', 'DEFAULT_XAI_VIDEO_BASE_URL', 'DEFAULT_XAI_VIDEO_MODEL',
        'XAI_VIDEO_ASPECT_RATIOS', 'XAI_VIDEO_DEFAULT_TIMEOUT_MS', 'isXaiVideo15Model']);
  }

  config(params) {
    assert.equal(params.provider, 'xai');
    assert.equal(params.capability, 'video');
    this.current.configCalls.push({ provider: params.provider, capability: params.capability,
      baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl });
    return { baseUrl: (params.baseUrl ?? params.defaultBaseUrl).trim().replace(/\/+$/, ''),
      headers: new Headers({ 'x-fixture-header': 'synthetic-config' }), allowPrivateNetwork: false };
  }

  handle(receipt, response) {
    this.current.requests.push(receipt);
    return { response, release: async () => { receipt.releaseCount += 1; receipt.releasedAtMs = this.current.now; } };
  }

  async post(params) {
    const receipt = { stage: 'submit', url: params.url, method: 'POST', atMs: this.current.now,
      timeoutMs: params.timeoutMs, headers: Object.fromEntries(params.headers), jsonBody: plain(params.body),
      bodyKeyOrder: Object.keys(params.body), releaseCount: 0 };
    this.current.now += 7;
    return this.handle(receipt, new Response(JSON.stringify(this.current.response.submit), { status: 200,
      headers: { 'content-type': 'application/json' } }));
  }

  async fetchResponse(url, init, timeoutMs, options) {
    const stage = options.auditContext === 'xai-video-status' ? 'poll' : 'download';
    assert.ok(['xai-video-status', 'xai-video-download'].includes(options.auditContext));
    const receipt = { stage, url, method: init.method, atMs: this.current.now, timeoutMs,
      headers: Object.fromEntries(new Headers(init.headers)), releaseCount: 0 };
    this.current.now += 11;
    if (stage === 'poll') {
      const payload = this.current.response.polls[this.current.pollIndex++];
      assert.ok(payload, 'declared successful poll response');
      return this.handle(receipt, new Response(JSON.stringify(payload), { status: 200,
        headers: { 'content-type': 'application/json' } }));
    }
    const fixture = this.current.response.download;
    assert.equal(url, fixture.url);
    return this.handle(receipt, new Response(Buffer.from(fixture.bytesBase64, 'base64'), { status: 200,
      headers: fixture.contentType ? { 'content-type': fixture.contentType } : {} }));
  }

  async run(vector) {
    this.current = { response: plain(vector.response), requests: [], readerCalls: [], statusCalls: [], retryCalls: [],
      configCalls: [], sleeps: [], nonceCalls: 0, now: 100000, pollIndex: 0 };
    const input = plain(vector.input);
    for (const key of ['inputImages', 'inputVideos']) if (input[key]) input[key] = input[key].map(({ bytesBase64, ...asset }) =>
      ({ ...asset, ...(bytesBase64 ? { buffer: Buffer.from(bytesBase64, 'base64') } : {}) }));
    const req = { ...input, provider: 'xai', cfg: { models: { providers: { xai: { baseUrl: vector.config.baseUrl } } },
      ...(vector.config.mediaMaxMb ? { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } } : {}) } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildXaiVideoGenerationProvider().generateVideo(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Video fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      for (const key of ['inputImages', 'inputVideos']) if (after[key]) after[key] = after[key].map(({ buffer, ...asset }) =>
        ({ ...asset, ...(buffer ? { bytesBase64: buffer.toString('base64') } : {}) }));
      const inputAfter = plain(after);
      assert.deepEqual(inputAfter, vector.input);
      assert.equal(this.current.pollIndex, vector.response.polls.length);
      assert.equal(this.current.nonceCalls, 1);
      assert.ok(this.current.requests.every(request => request.releaseCount === 1));
      return { ...vector, inputAfter,
        result: plain({ ...result, videos: result.videos.map(({ buffer, ...video }) => ({ ...video, bytesBase64: buffer.toString('base64') })) }),
        requests: this.current.requests, readerCalls: this.current.readerCalls, statusCalls: this.current.statusCalls,
        retryCalls: this.current.retryCalls, configCalls: this.current.configCalls, nonceCalls: this.current.nonceCalls,
        clock: { kind: 'synthetic-Date.now-and-sleepWithAbort', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { submit: 7, pollOrDownload: 11, binaryRead: 13 }, sleeps: this.current.sleeps } };
    } finally { clearTimeout(timer); }
  }
}

export async function captureXaiVideoGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new VideoGenerationHarness(root, before.tracked);
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
  return { schemaVersion: 1, referencePin: XAI_VIDEO_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-xai-video-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    protocol: { pollIntervalMs: 5000, maxPollAttempts: 120, deterministicRandomUUID: nonce },
    limits: [
      'Complete unchanged buildXaiVideoGenerationProvider and generateVideo callback execute with whole original provider-assets, image URL/bytes, duration/capability, number, normalization and MIME modules. Four complete original source regions provide video metadata wrapper/factory, configured cap, and shared deadline/poll helpers, with byte offsets and source/generated/executable hashes.',
      'All 58,558 tracked reference blobs are verified before/after; source, executable, exporter, shared harness, runtime and explicit import-binding hashes are recorded. Provenance-only SDK/service/registration files are not executed.',
      'Actual shared deadline and polling functions run with synthetic Date.now and sleepWithAbort; synthetic service costs advance time. No real waiting, timeout enforcement, socket, timer cancellation, retry, auth, account/profile, policy or TLS proof. Poll limit 120 is source provenance; ordinary vectors exercise immediate and pending/processing completion only.',
      'Lower transport/config/account/header/status/JSON/binary reader services are explicit successful facades. Native Response.json/arrayBuffer exercises exact bytes; cap parameters and chunkTimeoutMs are recorded without executing the production bounded stream reader or validating overflow.',
      'Deterministic crypto.randomUUID facade emits one fixed valid UUID per submit. It proves source placement on POST only, not cryptographic randomness or replay behavior. Poll/download headers are observed from unchanged actual provider code.',
      'Explicit finite timeout vectors execute a shared total budget. The omitted-timeout stage-reset vector is source-only and hostComparable=false; Synapsis requires explicit finite total timeout and does not adopt the omitted-timeout behavior.',
      'Tiny MP4/WebM/RIFF AVI/image protocol fixtures do not prove codec validity or visual quality. Capture result keeps complete videos/model/metadata shape, serializing each buffer solely as bytesBase64 for JSON.',
      'Inactive source oracle only: no video tool/catalog/config enablement, durable media/jobs/reference integration, real provider request, or whole P10/reference-goal completion.',
    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const outIndex = args.indexOf('--out');
  assert.equal(outIndex, 1, 'usage: capture-xai-video-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3);
  assert.ok(args[2], 'explicit --out path required');
  const result = await captureXaiVideoGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
