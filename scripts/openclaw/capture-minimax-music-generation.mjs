// Unchanged pinned MiniMax music callback with explicit ordinary successful synthetic I/O.
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

export const MINIMAX_MUSIC_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/minimax/music-generation-provider.ts';
const httpConfig = 'extensions/minimax/media-provider-runtime.ts';
const assets = 'src/music-generation/provider-assets.ts';
const caps = 'src/media/configured-max-bytes.ts';
const shared = 'src/media-understanding/shared.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const base64 = 'packages/media-core/src/base64.ts';
const constants = 'packages/media-core/src/constants.ts';
const mime = 'packages/media-core/src/mime.ts';
const body = 'src/infra/http-response-body.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, httpConfig, assets, strings, records, numbers, base64, constants, mime,
  'packages/media-core/src/file-name.ts', body, 'src/infra/http-response-body-timeout.ts',
  'src/infra/abort-signal.ts', 'packages/retry/src/index.ts',
  'packages/normalization-core/src/response-bytes.ts', 'packages/normalization-core/src/text-decoding.ts',
  'packages/normalization-core/src/utf16-slice.ts', 'packages/normalization-core/src/error-coercion.ts'];
const provenancePaths = ['LICENSE', 'src/plugin-sdk/music-generation.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugin-sdk/provider-auth.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugin-sdk/provider-http.ts',
  'src/agents/provider-http-errors.ts', 'src/agents/provider-request-config.ts',
  'src/infra/http-body.ts', 'packages/normalization-core/src/index.ts',
  'src/music-generation/types.ts', 'extensions/minimax/index.ts', 'extensions/minimax/openclaw.plugin.json', 'src/plugin-sdk/media-mime.ts', 'src/plugin-sdk/response-limit-runtime.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MINIMAX_MUSIC_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MINIMAX_MUSIC_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: MINIMAX_MUSIC_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${MINIMAX_MUSIC_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

function vectors() {
  const bytes = Buffer.from([0, 255, 128, 1, 2, 254, 17]);
  const hex = bytes.toString('hex');
  const json = payload => ({ contentType: 'application/json', payload,
    chunksBase64: [Buffer.from(JSON.stringify(payload)).toString('base64')] });
  const raw = (contentType, chunks) => ({ contentType, chunksBase64: chunks.map(value => Buffer.from(value).toString('base64')) });
  const response = payload => json(payload ?? { audio: hex });
  const vector = (id, input = {}, options = {}) => ({ id, providerId: options.providerId ?? 'minimax',
    input: { prompt: ' \uFEFF Morning melody 歌 😀 \n', timeoutMs: 12345, ...input },
    config: options.config ?? {}, response: options.response ?? response(options.payload),
    ...(options.download ? { download: options.download } : {}),
    ...(options.sourceOnly ? { hostComparable: false,
      adaptationReason: 'Source omitted timeout defaults to 300000ms; host requires an explicit positive finite total timeout.' } : {}) });
  const url = 'https://audio.example.test/track';
  const sse = lines => raw('text/event-stream; charset=utf-8', [lines]);
  return [
    vector('inline-default'),
    vector('source-default-timeout', { timeoutMs: undefined }, { sourceOnly: true }),
    vector('portal-model-lyrics', { model: ' \uFEFF music-cover-free \u00A0', lyrics: ' \uFEFF Verse 歌 😀\nChorus \u00A0', format: 'mp3' },
      { providerId: 'minimax-portal', payload: { audio: hex.toUpperCase(), lyrics: ' \uFEFF Returned verse 歌 😀 \n', task_id: ' \uFEFF task-歌曲 \u00A0', base_resp: { status_code: 0 } } }),
    vector('instrumental-blank-lyrics', { instrumental: true, lyrics: ' \t\uFEFF ', model: 'music-2.6-free' }),
    vector('blank-model-default', { model: ' \uFEFF\u00A0 ', instrumental: false }),
    vector('nested-audio-hex-lyrics', { lyrics: ' Source lyrics ' },
      { payload: { data: { audio: ' \uFEFF' + hex + '\u00A0 ', lyrics: Buffer.from(' \uFEFF Nested lyrics 雪 😀 \n').toString('hex') }, task_id: ' nested-task ' } }),
    vector('top-inline-precedence', {}, { payload: { audio: hex, lyrics: '',
      data: { audio: 'AABB', lyrics: 'nested ignored' }, seed: 7, tags: ['ignored'], model: 'ignored' } }),
    vector('top-url-precedence', {}, { payload: { audio: 'AABB', audio_url: ' ' + url + ' ',
      data: { audio_url: 'https://audio.example.test/ignored' }, lyrics: ' Download lyric ' },
      download: raw('Audio/WAV; codecs=pcm', [bytes.subarray(0, 2), bytes.subarray(2)]) }),
    vector('nested-url-precedence', {}, { payload: { audio: 'AABB', audio_url: ' \t ', data: { audio_url: url, lyrics: ' Nested URL lyric ' } },
      download: raw('application/octet-stream', [bytes]) }),
    vector('audio-candidate-url', {}, { payload: { audio: ' HTTPS://audio.example.test/candidate ', task_id: ' url-task ' },
      download: raw('audio/ogg', [bytes]) }),
    vector('download-default-mime', {}, { payload: { data: { audio: url } },
      download: { chunksBase64: [bytes.toString('base64')] } }),
    vector('direct-audio-raw-mime', {}, { response: raw(' Audio/WAV; codecs=pcm ', [bytes.subarray(0, 1), bytes.subarray(1)]) }),
    vector('direct-audio-alias', {}, { response: raw('audio/x-m4a', [bytes]) }),
    vector('sse-chunks-completion-aggregate', {}, { response: sse(
      ': ordinary comment\r\n' +
      'data: ' + JSON.stringify({ data: { audio: hex.slice(0, 6), status: 1 }, base_resp: { status_code: 0 } }) + '\r\n\r\n' +
      'data: ' + JSON.stringify({ data: { audio: hex.slice(6), status: '1' } }) + '\r\n' +
      'data: ' + JSON.stringify({ data: { audio: hex, status: 2 } }) + '\r\n' +
      'data: [DONE]') }),
    vector('sse-completion-first', {}, { response: sse('data: ' + JSON.stringify({ data: { status: '2', audio: ' \uFEFF' + hex.toUpperCase() + '\u00A0 ' } }) + '\n') }),
    vector('sse-cross-http-chunks', { model: ' music-cover ' }, { response: (() => {
      const text = Buffer.from('data: ' + JSON.stringify({ data: { status: 1, audio: hex }, extra: '曲 😀' }) + '\n' +
        'data: ' + JSON.stringify({ data: { status: 2 } }) + '\n\ndata: [DONE]\n');
      return raw('text/event-stream', Array.from(text, value => Buffer.from([value])));
    })() }),
    vector('configured-origin-portal', { model: ' custom/vendor/music ', durationSeconds: 33.5, format: 'mp3' },
      { providerId: 'minimax-portal', config: { baseUrl: ' https://API.MINIMAXI.COM:443/anthropic/v1?unused=yes#fragment ',
        request: { headers: { 'X-Context': ' ordinary ' } }, mediaMaxMb: 0.03125 } }),
    vector('duration-unused', { durationSeconds: 18.75 }),
    vector('json-opaque-chunks-unicode', {}, { response: (() => {
      const payload = { audio: hex, lyrics: ' 雪 😀\n歌 café ', task_id: 'task-雪' };
      const encoded = Buffer.from(JSON.stringify(payload));
      return { contentType: 'application/json; charset=utf-8', payload,
        chunksBase64: Array.from(encoded, value => Buffer.from([value]).toString('base64')) };
    })() }),
  ].map(plain);
}

class MinimaxMusicHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    const fixtureNow = 1_800_000_000_000;
    class FixtureDate extends Date { static now() { return fixtureNow; } }
    this.context = vm.createContext({ Buffer, Uint8Array, TextDecoder, Headers, Response, URL,
      AbortController, AbortSignal, setTimeout, clearTimeout, Date: FixtureDate,
      fetch: () => { throw Error('Undeclared real MiniMax fetch'); },
      __path: path,
      __platform: { sanitize: params => this.sanitize(params), config: params => this.config(params), post: params => this.post(params),
        status: (...args) => this.status(...args), retry: params => this.retry(params), guarded: (...args) => this.guarded(...args),
        binary: (...args) => this.binary(...args), cap: (kind, value) => this.current.maxBytesCalls.push({ kind, maxBytes: value }) } },
    { codeGeneration: { strings: false, wasm: false } });
    new vm.Script('globalThis.__captureAudit=[];globalThis.__deferredCalls=[];').runInContext(this.context);
    this.sourceRecords = new Map();
    this.importBindings = new Map();
  }

  module(file) {
    const source = relative(this.root, file);
    assert.ok(wholeSources.includes(source), `declared whole source: ${source}`);
    if (!this.sourceRecords.has(source)) {
      const bytes = readFileSync(file);
      assert.equal(hash(bytes), this.tracked.get(source), source);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      this.sourceRecords.set(source, { path: source, sha256: hash(bytes), executed: true, wholeModule: true,
        transformation: transform, executableSha256: hash(executable) });
    }
    return super.module(file);
  }

  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:minimax-music:' + key, code);
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

  projection(name, source, startMarker, endMarker, prelude, exports) {
    const original = readFileSync(join(this.root, source));
    assert.equal(hash(original), this.tracked.get(source));
    const start = original.indexOf(startMarker);
    const end = original.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start);
    const selected = original.subarray(start, end);
    const generated = prelude + selected.toString();
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(original), executed: true, wholeModule: false,
      projection: { startByte: start, endByte: end, sourceRegionSha256: hash(selected), prelude,
        generatedCode: generated, generatedSha256: hash(generated) }, transformation: transform,
      executableSha256: hash(executable) });
    return this.binding('capture:shared', name, 'complete-source-region-projection', exports, executable,
      { source, sourceSha256: this.tracked.get(source) });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:minimax-music:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:minimax-music:') && specifier === 'capture:minimax-caps') {
      return this.projection(specifier, caps, 'const MB = 1024 * 1024;', '/**\n * Bounds a provider\'s download',
        `import {maxBytesForKind} from 'capture:source:${constants}';\n`, ['resolveGeneratedMediaMaxBytes']);
    }
    if (parent.startsWith('capture:minimax-music:') && specifier === 'capture:minimax-deadlines') {
      return this.projection(specifier, shared, 'export function createProviderOperationDeadline(',
        '/** Waits for the next poll interval',
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${numbers}';\nconst DEFAULT_GUARDED_HTTP_TIMEOUT_MS=60000;\n`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError', 'createProviderOperationTimeoutResolver']);
    }
    if ([entry, httpConfig].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['asOptionalRecord', 'readStringField', 'normalizeOptionalString'],
        `export {asOptionalRecord,readStringField} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`,
        { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/music-generation') {
      return this.alias(importer, specifier, assets, ['downloadGeneratedMusicAsset'], 'src/plugin-sdk/music-generation.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-mime') {
      return this.alias(importer, specifier, mime, ['extensionForMime'], 'src/plugin-sdk/media-mime.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/response-limit-runtime') {
      return this.alias(importer, specifier, body, ['readResponseWithLimit'], 'src/plugin-sdk/response-limit-runtime.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      return this.binding(importer, specifier, 'source-region-observing-export-alias', ['resolveGeneratedMediaMaxBytes'],
        `import {resolveGeneratedMediaMaxBytes as resolve} from 'capture:minimax-caps';\nexport function resolveGeneratedMediaMaxBytes(cfg,kind){const value=resolve(cfg,kind);globalThis.__platform.cap(kind,value);return value;}`,
        { source: caps, sourceSha256: this.tracked.get(caps), origin: 'src/plugin-sdk/media-generation-runtime.ts',
          originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') {
      return this.binding(importer, specifier, 'uninvoked-dependency-facade', ['isProviderApiKeyConfiguredAsync'],
        `export function isProviderApiKeyConfiguredAsync(){globalThis.__deferredCalls.push('isProviderApiKeyConfiguredAsync');throw Error('Uninvoked account configuration lookup');}`,
        { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    }
    if ([entry, httpConfig].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http') {
      const code = importer === entry
        ? `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs,createProviderOperationTimeoutError} from 'capture:minimax-deadlines';\nexport const postJsonRequest=globalThis.__platform.post;\nexport const assertOkOrThrowHttpError=globalThis.__platform.status;`
        : `export const assertOkOrThrowHttpError=globalThis.__platform.status;\nexport const executeProviderOperationWithRetry=globalThis.__platform.retry;\nexport const fetchWithTimeoutGuarded=globalThis.__platform.guarded;\nexport const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;\nexport const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;`;
      return this.binding(importer, specifier, 'source-deadlines-successful-config-transport-fixtures', importer === entry
        ? ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs', 'createProviderOperationTimeoutError', 'postJsonRequest', 'assertOkOrThrowHttpError']
        : ['assertOkOrThrowHttpError', 'executeProviderOperationWithRetry', 'fetchWithTimeoutGuarded', 'resolveProviderApiKeyHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest'], code,
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false });
    }
    if (importer === assets && specifier === '../agents/provider-http-errors.js') {
      return this.binding(importer, specifier, 'successful-binary-validator-fixture-actual-body-reader', ['readProviderBinaryResponse'],
        `import {readResponseWithLimit} from 'capture:source:${body}';\nexport async function readProviderBinaryResponse(response,label,kind,opts){globalThis.__platform.binary(response,label,kind,opts);return await readResponseWithLimit(response,opts.maxBytes,opts);}`,
        { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false,
          boundary: 'Synthetic ordinary binary content validation; actual bounded body consumption executes. No validation rejection or media sniffing qualification.' });
    }
    if (importer === assets && specifier === '../infra/http-body.js') {
      return this.alias(importer, specifier, body, ['readResponseWithLimit'], 'src/infra/http-body.ts');
    }
    if (importer === assets && specifier === '../media-understanding/shared.js') {
      return this.binding(importer, specifier, 'source-deadlines-uninvoked-default-download',
        ['createProviderOperationDeadline', 'createProviderOperationTimeoutResolver', 'fetchProviderDownloadResponse'],
        `export {createProviderOperationDeadline,createProviderOperationTimeoutResolver} from 'capture:minimax-deadlines';\nexport function fetchProviderDownloadResponse(){globalThis.__deferredCalls.push('fetchProviderDownloadResponse');throw Error('Custom MiniMax response factory is required');}`,
        { source: shared, sourceSha256: this.tracked.get(shared), originalSourceExecuted: false });
    }
    if (importer === body && specifier === '@openclaw/normalization-core') {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['consumeResponseBytes', 'decodeTextPrefix'],
        `export {consumeResponseBytes} from 'capture:source:packages/normalization-core/src/response-bytes.ts';\nexport {decodeTextPrefix} from 'capture:source:packages/normalization-core/src/text-decoding.ts';`,
        { origin: 'packages/normalization-core/src/index.ts', originSha256: this.tracked.get('packages/normalization-core/src/index.ts') });
    }
    if (['packages/media-core/src/file-name.ts', mime].includes(importer) && specifier === 'node:path') {
      return this.binding(importer, specifier, 'native-node-path-binding', ['default'], 'export default globalThis.__path;');
    }
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/media-core/mime': mime, '@openclaw/normalization-core/record-coerce': records,
      '@openclaw/normalization-core/string-coerce': strings, '@openclaw/normalization-core/number-coercion': numbers,
      '@openclaw/normalization-core/error-coercion': 'packages/normalization-core/src/error-coercion.ts',
      '@openclaw/normalization-core/utf16-slice': 'packages/normalization-core/src/utf16-slice.ts' };
    if (wholeSources.includes(importer) && packages[specifier]) return this.source(importer, specifier, packages[specifier]);
    if (wholeSources.includes(importer) && specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared MiniMax music import: ${importer} -> ${specifier}`);
  }

  sanitize(params) {
    this.current.sanitizeCalls.push(params === undefined ? null : plain(params));
    return params === undefined ? undefined : plain(params);
  }

  config(params) {
    this.current.configCalls.push(plain(params));
    assert.equal(params.provider, this.current.providerId);
    assert.equal(params.capability, 'audio');
    assert.equal(params.jsonContentType, false);
    return { baseUrl: params.baseUrl, headers: new Headers({ authorization: 'Bearer synthetic-minimax-fixture-key',
      ...(params.request?.headers ?? {}) }), allowPrivateNetwork: false,
      dispatcherPolicy: { fixture: 'synthetic-successful-policy' } };
  }

  status(response, label) {
    assert.equal(response.status, 200);
    this.current.statusCalls.push({ status: response.status, label });
  }

  async retry(params) {
    const { operation, ...call } = params;
    this.current.retryCalls.push(plain(call));
    return await operation();
  }

  binary(response, label, kind, opts) {
    this.current.binaryCalls.push({ label, kind, maxBytes: opts.maxBytes, timeoutMs: opts.timeoutMs(),
      contentType: response.headers.get('content-type') });
  }

  nativeResponse(specification, label) {
    const chunks = specification.chunksBase64.map(value => Buffer.from(value, 'base64'));
    const response = new Response(new ReadableStream({ start(controller) {
      for (const bytes of chunks) controller.enqueue(bytes);
      controller.close();
    } }), { status: 200, headers: specification.contentType === undefined ? {} : { 'content-type': specification.contentType } });
    const instrument = (value, name) => {
      const record = { label: name, chunksRead: 0, readerReleaseLockCount: 0, readerCancelCount: 0 };
      this.current.streams.push({ record, response: value });
      const originalGetReader = value.body.getReader.bind(value.body);
      value.body.getReader = (...args) => {
        const reader = originalGetReader(...args);
        const read = reader.read.bind(reader), releaseLock = reader.releaseLock.bind(reader), cancel = reader.cancel.bind(reader);
        reader.read = async (...values) => { const result = await read(...values); if (!result.done) record.chunksRead++; return result; };
        reader.releaseLock = () => { record.readerReleaseLockCount++; return releaseLock(); };
        reader.cancel = (...values) => { record.readerCancelCount++; return cancel(...values); };
        return reader;
      };
      const clone = value.clone.bind(value);
      value.clone = () => instrument(clone(), name + ':clone');
      return value;
    };
    return instrument(response, label);
  }

  async post(params) {
    const { fetchFn, headers, ...request } = params;
    assert.equal(typeof fetchFn, 'function');
    this.current.requests.push(plain({ ...request, headers: Object.fromEntries(headers), method: 'POST' }));
    return { response: this.nativeResponse(this.current.response, 'post'), release: async () => { this.current.releases.post++; } };
  }

  async guarded(url, init, timeoutMs, fetchFn, options) {
    assert.equal(typeof fetchFn, 'function');
    assert.ok(this.current.download);
    this.current.downloadCalls.push(plain({ url, init, timeoutMs, options }));
    return { response: this.nativeResponse(this.current.download, 'download'), release: async () => { this.current.releases.download++; } };
  }

  async run(vector) {
    this.current = { providerId: vector.providerId, response: vector.response, download: vector.download,
      sanitizeCalls: [], configCalls: [], requests: [], downloadCalls: [], maxBytesCalls: [], statusCalls: [], retryCalls: [], binaryCalls: [],
      streams: [], releases: { post: 0, download: 0 } };
    const cfg = { models: { providers: { [vector.providerId]: {
      ...(vector.config.baseUrl === undefined ? {} : { baseUrl: vector.config.baseUrl }),
      ...(vector.config.request === undefined ? {} : { request: vector.config.request }),
    } } }, ...(vector.config.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } }) };
    const req = { ...plain(vector.input), provider: vector.providerId, cfg, agentDir: '/synthetic/minimax-agent', authStore: { fixture: 'synthetic-key-store' } };
    const before = plain(req);
    this.context.__req = req;
    this.context.__providerId = vector.providerId;
    let timer;
    try {
      const operation = new vm.Script('__exports.buildMinimaxMusicGenerationProvider(__providerId).generateMusic(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('MiniMax music fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req), before);
      const { response: _response, download: _download, providerId: _providerId, streams, ...calls } = this.current;
      assert.equal(calls.requests.length, 1);
      assert.equal(calls.downloadCalls.length, vector.download ? 1 : 0);
      assert.equal(calls.releases.post, 1);
      assert.equal(calls.releases.download, vector.download ? 1 : 0);
      const observations = streams.map(({ record, response: value }) => ({ ...record, lockedAfter: value.body.locked }));
      assert.ok(observations.every(row => !row.lockedAfter));
      return { ...vector, inputAfter: plain(vector.input), ...calls, streams: observations,
        result: plain({ ...result, tracks: result.tracks.map(({ buffer, ...track }) => ({ ...track, bytesBase64: buffer.toString('base64') })) }) };
    } finally { clearTimeout(timer); }
  }

}

export async function captureMinimaxMusicGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new MinimaxMusicHarness(root, before.tracked);
  await harness.load(entry);
  const providers = harness.call(`['minimax','minimax-portal'].map(id=>{const p=__exports.buildMinimaxMusicGenerationProvider(id);return {id:p.id,label:p.label,defaultModel:p.defaultModel,models:p.models,capabilities:p.capabilities};})`);
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), `loaded whole source: ${source}`);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source));
    assert.equal(hash(bytes), before.tracked.get(source), source);
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: MINIMAX_MUSIC_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-minimax-music-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    platform: { dateNowMs: 1800000000000, clock: 'explicit synthetic fixed Date.now for deterministic ordinary deadline observations; native timers complete without expiration' },
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.call('__captureAudit'),
    deferredCalls: harness.call('__deferredCalls'), providers,
    limits: [
      'Complete unchanged MiniMax provider factory/generateMusic, media-provider-runtime, provider-assets, MIME/file-name, normalization, response byte consumer and actual bounded body reader modules execute. Whole-module evaluation does not mean every helper or branch executes; Base64 conversion is not invoked.',
      'Configured media cap and shared deadline helpers use two exact complete original source regions with byte offsets and original/generated/executable hashes. Fixed Date.now makes successful deadline observations reproducible; no exhausted timers or HTTP enforcement is qualified.',
      'All 58558 tracked reference blobs are verified before/after; source/executable/exporter/shared-harness/runtime/importer bindings and LICENSE provenance are recorded. SDK barrels and registration/service sources are provenance-only.',
      'Synthetic successful API config/sanitization/POST/guarded GET/status/retry/binary validation boundaries supply explicit JSON/raw native Response/ReadableStream bytes. No real credential/config discovery, network, transport policy, security/permission/auth, validation rejection or retry-on-failure behavior executes.',
      'Actual media runtime normalizes base origin, requested strings and hex audio, and its download wrapper calls the synthetic successful retry operation once. Actual provider selects JSON top/nested inline/URL precedence, raw audio or completed SSE, decodes plain/hex lyrics and returns exact metadata.',
      'Actual native bounded reader consumes declared successful bodies and releases reader locks. JSON uses the source native clone; unconsumed original tee is released only by a synthetic POST release callback. POST/download release callback counts qualify source finally ownership, not real socket/interrupt cleanup.',
      'Source accepts omitted timeout default300000ms, separately hostComparable=false; host requires an explicit finite total timeout. Direct MIME retains source case/parameters; generic download MIME is retained rather than replaced. Bytes are opaque protocol fixtures, not codec/playback/quality proof.',
      'No negative/failure/cancel/crash/timeout-exhaustion/race/mixed paths, real provider requests, media jobs/storage/delivery/completion/replay/native registration or whole reference/P10/goal acceptance. This is an inactive independent source oracle; it does not claim host replay of every vector.',

    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-minimax-music-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3);
  const result = await captureMinimaxMusicGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
