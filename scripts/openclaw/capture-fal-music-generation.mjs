// Unchanged pinned FAL music callback with explicit ordinary successful synthetic I/O.
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

export const FAL_MUSIC_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/fal/music-generation-provider.ts';
const httpConfig = 'extensions/fal/http-config.ts';
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
  'src/music-generation/types.ts', 'extensions/fal/index.ts', 'extensions/fal/openclaw.plugin.json'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), FAL_MUSIC_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', FAL_MUSIC_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: FAL_MUSIC_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${FAL_MUSIC_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

function vectors() {
  const url = 'https://audio.example.test/music';
  const standardBytes = Buffer.from('FAL ordinary synthetic music 歌 😀');
  const vector = (id, input = {}, options = {}) => ({ id,
    input: { prompt: '  Morning melody 歌 😀  ', timeoutMs: 12345, ...input },
    config: options.config ?? {},
    response: { payload: options.payload ?? { audio: url },
      ...(options.contentType === null ? {} : { contentType: options.contentType ?? 'audio/mpeg' }),
      chunksBase64: (options.byteChunks ?? [standardBytes]).map(value => value.toString('base64')) },
    ...(options.sourceOnly ? { hostComparable: false,
      adaptationReason: 'Source omitted timeout defaults to 180000ms; host protocol requires an explicit finite total timeout.' } : {}) });
  const mini = 'fal-ai/minimax-music/v2.6';
  const ace = 'fal-ai/ace-step/prompt-to-audio';
  const stable = 'fal-ai/stable-audio-25/text-to-audio';
  return [
    vector('default-minimax'),
    vector('default-timeout', { timeoutMs: undefined }, { sourceOnly: true }),
    vector('minimax-lyrics-duration-mp3', { model: ` ${mini} `, lyrics: ' \n Verse 歌 😀\nChorus \t', durationSeconds: 52.5, format: 'mp3' },
      { payload: { audio: url, lyrics: ' \n Returned 歌 😀\nSecond line \t', seed: 42, tags: ['calm', 'piano'] } }),
    vector('minimax-instrumental-duration-mp3', { instrumental: true, durationSeconds: 240, format: 'mp3' },
      { payload: { audio: url, seed: 0, tags: [] } }),
    vector('minimax-false-blank-model-lyrics', { model: ' \t ', instrumental: false, lyrics: ' \t\n ', durationSeconds: 30 }),
    vector('ace-default', { model: ace }, { contentType: 'audio/wav' }),
    vector('ace-instrumental-duration-wav', { model: ` ${ace} `, instrumental: true, durationSeconds: 31.5, format: 'wav' },
      { contentType: 'audio/wav', payload: { audio: url, seed: 7, tags: 'instrumental', lyrics: ' ACE returned lyric ' } }),
    vector('ace-false-duration-wav', { model: ace, instrumental: false, durationSeconds: 60, format: 'wav' }, { contentType: 'audio/wav' }),
    vector('stable-default', { model: stable }, { contentType: 'audio/wav' }),
    vector('stable-duration-wav', { model: ` ${stable} `, instrumental: false, durationSeconds: 90, format: 'wav' }, { contentType: 'audio/wav' }),
    vector('audio-priority-and-candidate-filename', {}, { payload: {
      audio_file: { url: 'https://audio.example.test/second', content_type: 'audio/flac', file_name: 'second.flac' },
      audio: { url: '  https://audio.example.test/first  ', content_type: ' AUDIO/WAV ; charset=utf-8 ', file_name: '  chosen-name.wav  ' },
      seed: 11, tags: { style: 'ambient' }, lyrics: '  Priority lyric  ' }, contentType: ' Audio/MPEG ; charset=binary ' }),
    vector('audio-file-string-url', {}, { payload: { audio_file: '  https://audio.example.test/file-only  ', seed: null, tags: null, lyrics: ' \t ' }, contentType: 'AUDIO/WAVE; codecs=pcm' }),
    vector('candidate-mime-after-generic-header', {}, { payload: { audio: { url, content_type: ' AUDIO/WAVE ; codecs=pcm ' } }, contentType: 'application/octet-stream' }),
    vector('candidate-mime-after-binary-header', {}, { payload: { audio_file: { url, content_type: ' Audio/FLAC ; codecs=flac ', file_name: '  archive.flac  ' } }, contentType: 'binary/octet-stream' }),
    vector('default-mime-with-generic-candidate', {}, { payload: { audio: { url, content_type: ' application/octet-stream ' } }, contentType: null }),
    vector('header-mime-default-filename', {}, { contentType: ' Audio/OGG ; codecs=opus ' }),
    vector('custom-base-configured-cap-chunks', { format: 'mp3', durationSeconds: 18 }, {
      config: { baseUrl: ' https://relay.example.test/fal/// ', request: { headers: { 'x-test': 'ordinary' } }, mediaMaxMb: 0.03125 },
      payload: { audio: url, seed: 0, tags: false },
      byteChunks: [standardBytes.subarray(0, 1), standardBytes.subarray(1, 7), standardBytes.subarray(7, 31), standardBytes.subarray(31)] }),
  ].map(plain);
}

class FalMusicHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    const fixtureNow = 1_800_000_000_000;
    class FixtureDate extends Date { static now() { return fixtureNow; } }
    this.context = vm.createContext({ Buffer, Uint8Array, TextDecoder, Headers, Response,
      AbortController, AbortSignal, setTimeout, clearTimeout, Date: FixtureDate,
      fetch: () => { throw Error('Undeclared real FAL fetch'); },
      __path: path,
      __platform: { key: params => this.key(params), sanitize: params => this.sanitize(params),
        config: params => this.config(params), post: params => this.post(params), download: params => this.download(params),
        cap: (kind, value) => this.current.maxBytesCalls.push({ kind, maxBytes: value }) } },
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
    return this.synthetic('capture:fal-music:' + key, code);
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
    if (parent.startsWith('capture:fal-music:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:fal-music:') && specifier === 'capture:fal-caps') {
      return this.projection(specifier, caps, 'const MB = 1024 * 1024;', '/**\n * Bounds a provider\'s download',
        `import {maxBytesForKind} from 'capture:source:${constants}';\n`, ['resolveGeneratedMediaMaxBytes']);
    }
    if (parent.startsWith('capture:fal-music:') && specifier === 'capture:fal-deadlines') {
      return this.projection(specifier, shared, 'export function createProviderOperationDeadline(',
        '/** Waits for the next poll interval',
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${numbers}';\nconst DEFAULT_GUARDED_HTTP_TIMEOUT_MS=60000;\n`,
        ['createProviderOperationDeadline', 'createProviderOperationTimeoutResolver']);
    }
    if ([entry, httpConfig].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['isRecord', 'normalizeOptionalString'],
        `export {isRecord} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`,
        { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/music-generation') {
      return this.alias(importer, specifier, assets, ['downloadGeneratedMusicAsset', 'extractGeneratedMusicFileCandidates'], 'src/plugin-sdk/music-generation.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      return this.binding(importer, specifier, 'source-region-observing-export-alias', ['resolveGeneratedMediaMaxBytes'],
        `import {resolveGeneratedMediaMaxBytes as resolve} from 'capture:fal-caps';\nexport function resolveGeneratedMediaMaxBytes(cfg,kind){const value=resolve(cfg,kind);globalThis.__platform.cap(kind,value);return value;}`,
        { source: caps, sourceSha256: this.tracked.get(caps), origin: 'src/plugin-sdk/media-generation-runtime.ts',
          originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') {
      return this.binding(importer, specifier, 'uninvoked-dependency-facade', ['isProviderApiKeyConfiguredAsync'],
        `export function isProviderApiKeyConfiguredAsync(){globalThis.__deferredCalls.push('isProviderApiKeyConfiguredAsync');throw Error('Uninvoked account configuration lookup');}`,
        { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    }
    if (importer === httpConfig && specifier === 'openclaw/plugin-sdk/provider-auth-runtime') {
      return this.binding(importer, specifier, 'successful-synthetic-key-fixture', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.key;',
        { source: 'src/plugin-sdk/provider-auth-runtime.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth-runtime.ts'), originalSourceExecuted: false });
    }
    if ([entry, httpConfig].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http') {
      return this.binding(importer, specifier, 'successful-config-submission-fixture', importer === entry ? ['postJsonResponse'] :
        ['resolveProviderHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest'],
        importer === entry ? 'export const postJsonResponse=globalThis.__platform.post;' :
          'export const resolveProviderHttpRequestConfig=globalThis.__platform.config;\nexport const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;',
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false });
    }
    if (importer === assets && specifier === '../agents/provider-http-errors.js') {
      return this.binding(importer, specifier, 'uninvoked-dependency-facade', ['readProviderBinaryResponse'],
        `export function readProviderBinaryResponse(){globalThis.__deferredCalls.push('readProviderBinaryResponse');throw Error('Uninvoked validated binary reader');}`,
        { source: 'src/agents/provider-http-errors.ts', sourceSha256: this.tracked.get('src/agents/provider-http-errors.ts'), originalSourceExecuted: false });
    }
    if (importer === assets && specifier === '../infra/http-body.js') {
      return this.alias(importer, specifier, body, ['readResponseWithLimit'], 'src/infra/http-body.ts');
    }
    if (importer === assets && specifier === '../media-understanding/shared.js') {
      return this.binding(importer, specifier, 'source-deadlines-synthetic-download-fixture',
        ['createProviderOperationDeadline', 'createProviderOperationTimeoutResolver', 'fetchProviderDownloadResponse'],
        `export {createProviderOperationDeadline,createProviderOperationTimeoutResolver} from 'capture:fal-deadlines';\nexport const fetchProviderDownloadResponse=globalThis.__platform.download;`,
        { source: shared, sourceSha256: this.tracked.get(shared), originalSourceExecuted: false,
          boundary: 'Deadline functions execute an exact original region; successful download returns native Response from declared bytes without real HTTP/policy/retry.' });
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
    throw Error(`Undeclared FAL music import: ${importer} -> ${specifier}`);
  }

  key(params) {
    this.current.keyCalls.push(plain(params));
    assert.equal(params.provider, 'fal');
    return { apiKey: 'synthetic-fal-fixture-key' };
  }

  sanitize(params) {
    this.current.sanitizeCalls.push(params === undefined ? null : plain(params));
    // Declared fixture has no live configuration/policy semantics.
    return params === undefined ? undefined : plain(params);
  }

  config(params) {
    this.current.configCalls.push(plain(params));
    assert.equal(params.provider, 'fal');
    assert.equal(params.capability, 'audio');
    assert.equal(params.allowPrivateNetwork, false);
    assert.equal(params.transport, 'http');
    return { baseUrl: (params.baseUrl ?? params.defaultBaseUrl).replace(/\/+$/, ''),
      headers: new Headers(params.defaultHeaders), allowPrivateNetwork: false,
      dispatcherPolicy: { fixture: 'synthetic-successful-policy' } };
  }

  async post(params) {
    const { fetchFn, headers, ...request } = params;
    assert.equal(typeof fetchFn, 'function');
    this.current.requests.push(plain({ ...request, headers: Object.fromEntries(headers), method: 'POST' }));
    return plain(this.current.response.payload);
  }

  async download(params) {
    const { fetchFn, ...call } = params;
    assert.equal(typeof fetchFn, 'function');
    this.current.downloadCalls.push(plain(call));
    const buffers = this.current.response.chunksBase64.map(value => Buffer.from(value, 'base64'));
    const response = new Response(new ReadableStream({ start(controller) {
      for (const bytes of buffers) controller.enqueue(bytes);
      controller.close();
    } }), { status: 200, headers: this.current.response.contentType === undefined ? {} : { 'content-type': this.current.response.contentType } });
    this.current.body = response.body;
    const originalGetReader = response.body.getReader.bind(response.body);
    response.body.getReader = (...args) => {
      const reader = originalGetReader(...args);
      const read = reader.read.bind(reader);
      const releaseLock = reader.releaseLock.bind(reader);
      const cancel = reader.cancel.bind(reader);
      reader.read = async (...values) => { const result = await read(...values); if (!result.done) this.current.stream.chunksRead++; return result; };
      reader.releaseLock = () => { this.current.stream.readerReleaseLockCount++; return releaseLock(); };
      reader.cancel = (...values) => { this.current.stream.readerCancelCount++; return cancel(...values); };
      return reader;
    };
    return response;
  }

  async run(vector) {
    this.current = { response: vector.response, keyCalls: [], sanitizeCalls: [], configCalls: [], requests: [], downloadCalls: [], maxBytesCalls: [],
      stream: { chunksRead: 0, readerReleaseLockCount: 0, readerCancelCount: 0 } };
    const cfg = { models: { providers: { fal: {
      ...(vector.config.baseUrl === undefined ? {} : { baseUrl: vector.config.baseUrl }),
      ...(vector.config.request === undefined ? {} : { request: vector.config.request }),
    } } }, ...(vector.config.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } }) };
    const req = { ...plain(vector.input), provider: 'fal', cfg, agentDir: '/synthetic/fal-agent', authStore: { fixture: 'synthetic-key-store' } };
    const before = plain(req);
    this.context.__req = req;
    let timer;
    try {
      const operation = new vm.Script('__exports.buildFalMusicGenerationProvider().generateMusic(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('FAL music fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req), before);
      const { response: _response, body: nativeBody, ...calls } = this.current;
      assert.equal(calls.requests.length, 1);
      assert.equal(calls.downloadCalls.length, 1);
      assert.equal(nativeBody.locked, false);
      return { ...vector, inputAfter: plain(vector.input), ...calls,
        stream: { ...calls.stream, lockedAfter: nativeBody.locked },
        result: plain({ ...result, tracks: result.tracks.map(({ buffer, ...track }) => ({ ...track, bytesBase64: buffer.toString('base64') })) }) };
    } finally { clearTimeout(timer); }
  }
}

export async function captureFalMusicGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new FalMusicHarness(root, before.tracked);
  await harness.load(entry);
  const provider = harness.call(`(() => {const p=__exports.buildFalMusicGenerationProvider();return {id:p.id,label:p.label,defaultModel:p.defaultModel,models:p.models,capabilities:p.capabilities};})()`);
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
  return { schemaVersion: 1, referencePin: FAL_MUSIC_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-fal-music-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    platform: { dateNowMs: 1800000000000, clock: 'explicit synthetic fixed Date.now for deterministic ordinary deadline observations; native timers complete without expiration' },
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.call('__captureAudit'),
    deferredCalls: harness.call('__deferredCalls'), provider,
    limits: [
      'Complete unchanged FAL provider factory/generateMusic, http-config, provider-assets, MIME/file-name, normalization, response byte consumer and actual bounded body reader modules execute. Whole-module evaluation does not mean every exported helper/branch executes; base64 conversion is not invoked by the FAL callback.',
      'Configured media cap and shared deadline helpers use two complete original source-region projections with byte offsets and original/generated/executable hashes. Date.now is fixed synthetically for reproducible successful deadlines; real timer exhaustion is not tested.',
      'All 58,558 tracked reference blobs are verified before/after; source, executable, exporter, shared harness, runtime and importer-specific binding hashes are recorded. SDK barrels, registration and service files listed provenance-only are not executed.',
      'Synthetic successful key/config/sanitization/postJsonResponse/download boundaries provide declared JSON and native Response/ReadableStream bodies. No real provider/auth/security/permission/network/SSRF/retry/configuration behavior is qualified; headers contain only a literal synthetic fixture key.',
      'All three models cover ordinary successful default/lyrics/instrumental/duration/format combinations allowed by their descriptors. Source audio precedes audio_file regardless of JSON key order; only the first candidate and one track are consumed. Source metadata seed/tags/normalized lyrics is preserved.',
      'Actual normal-completion body reader consumes all declared bytes and releases its lock. No failure/negative/cancel/crash/timeout-exhaustion/race paths execute. No download handle release is supplied by this source path and no interruption claim is made.',
      'Omitted source timeout defaults to 180000ms and is hostComparable=false; host protocol requires an explicit finite total timeout. Explicit finite total values are observed only; no HTTP timeout enforcement or polling is exercised.',
      'Tiny synthetic protocol bytes are not audio codec/playback/quality evidence. Actual default 16MiB and ordinary configured 32KiB caps are passed through, without production-size assets or overflow. Buffers are serialized solely as complete bytesBase64.',
      'Inactive independent source oracle only: no music tool/catalog/config enablement, durable media/jobs/reference integration, registration execution, real provider request, whole reference/P10 or tool-goal completion.',
    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-fal-music-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3);
  const result = await captureFalMusicGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
