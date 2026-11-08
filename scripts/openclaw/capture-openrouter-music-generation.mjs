// Complete pinned OpenRouter music provider and SSE parser under ordinary successful synthetic I/O.
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

export const OPENROUTER_MUSIC_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openrouter/music-generation-provider.ts';
const contextSource = 'extensions/openrouter/generation-request-context.ts';
const defaults = 'extensions/openrouter/provider-defaults.ts';
const caps = 'src/media/configured-max-bytes.ts';
const imageAssets = 'src/image-generation/image-assets.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const base64 = 'packages/media-core/src/base64.ts';
const constants = 'packages/media-core/src/constants.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, contextSource, defaults, imageAssets, number, strings, records, base64, constants];
const provenancePaths = ['src/plugin-sdk/image-generation.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/media-runtime.ts', 'src/plugin-sdk/music-generation.ts', 'src/plugin-sdk/number-runtime.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/agents/provider-http-errors.ts', 'src/agents/provider-request-config.ts', 'src/infra/net/fetch-guard.ts',
  'extensions/openrouter/provider-catalog.ts', 'extensions/openrouter/index.ts',
  'extensions/openrouter/openclaw.plugin.json', 'src/music-generation/types.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENROUTER_MUSIC_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENROUTER_MUSIC_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: OPENROUTER_MUSIC_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${OPENROUTER_MUSIC_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// Tiny protocol bytes; no video decoding, visual quality or production reader claim.
const mp4 = Buffer.from([0, 0, 0, 20, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0, 109, 112, 52, 50]).toString('base64');
const webm = Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x84, 0x42, 0x82, 0x84, 0x77, 0x65, 0x62, 0x6d]).toString('base64');
const avi = Buffer.from([0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x41, 0x56, 0x49, 0x20]).toString('base64');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';

function chunks(bytes, sizes) {
  const result = [];
  for (let offset = 0, index = 0; offset < bytes.length; index++) {
    const size = sizes[index % sizes.length];
    result.push(bytes.subarray(offset, offset + size).toString('base64'));
    offset += size;
  }
  return result;
}

function vectors() {
  const audio = Buffer.from('RIFF synthetic music bytes 😀', 'utf8');
  const event = (data, transcript, extra = {}) => ({ choices: [{ delta: { audio: {
    ...(data === undefined ? {} : { data }), ...(transcript === undefined ? {} : { transcript }),
  } } }], ...extra });
  const wire = (events, ending = '\n', prefix = '') => prefix + events.map(value => 'data: ' + JSON.stringify(value) + '\n\n').join('') + 'data: [DONE]' + ending;
  const vector = (id, input = {}, options = {}) => {
    const payload = options.audio ?? audio;
    const encoded = options.unpadded ? payload.toString('base64').replace(/=+$/, '') : payload.toString('base64');
    const events = options.events ?? [event(encoded, options.transcript)];
    const raw = options.raw ?? wire(events, options.ending, options.prefix);
    return { id, input: { prompt: '  A gentle morning melody 😀  ', timeoutMs: 12345, ...input },
      config: options.config ?? {}, response: { chunksBase64: chunks(Buffer.from(raw), options.sizes ?? [1048576]) },
      ...(options.sourceOnly ? { hostComparable: false,
        adaptationReason: 'Source omitted timeout defaults to 180000ms; host protocol requires an explicit finite total timeout.' } : {}) };
  };
  const unicodeTranscript = ' \t歌 e\u0301 😀\r\n line\u00a0\ufeff ';
  const split = audio.toString('base64');
  const image = 'iVBORw0KGgo=';
  const rows = [
    vector('default-wav'),
    vector('default-timeout', { timeoutMs: undefined }, { sourceOnly: true }),
    vector('explicit-model-mp3', { model: ' google/lyria-3-clip-preview ', format: 'mp3', timeoutMs: 23456 }),
    vector('blank-model-lyrics', { model: ' \t ', lyrics: ' \n ' }),
    vector('lyrics-instrumental-duration', { lyrics: '  First line\nSecond line 😀  ', instrumental: true, durationSeconds: 29.5 }),
    vector('instrumental-false-duration-down', { instrumental: false, durationSeconds: 29.49 }),
    vector('duration-half-up', { durationSeconds: 1.5 }),
    vector('custom-base', { model: ' vendor/track-v2 ', format: 'wav' },
      { config: { baseUrl: ' https://music.example.test/v1/// ' } }),
    vector('image-url', { inputImages: [{ url: ' https://images.example.test/cover.png ' }] }),
    vector('image-bytes-default-mime', { inputImages: [{ bytesBase64: image }] }),
    vector('image-bytes-explicit-mime', { inputImages: [{ bytesBase64: '/9j/', mimeType: ' image/jpeg ' }] }),
    vector('image-url-precedes-bytes', { inputImages: [{ url: ' https://images.example.test/cover.png ', bytesBase64: image }] }),
    vector('transcript-whitespace-utf8-byte-chunks', {}, { transcript: unicodeTranscript, sizes: [1] }),
    vector('transcript-only-space', {}, { transcript: ' \t\r\n ' }),
    vector('one-base64-stream-across-deltas', {}, { events: [event(split.slice(0, 1), '  Intro'),
      event(split.slice(1, 6)), event(undefined, '\n'), event(split.slice(6, 9), '歌 😀'),
      event(split.slice(9), '  ')], sizes: [3, 1, 7, 2, 11] }),
    vector('unterminated-done', {}, { ending: '', sizes: [2, 5, 1, 13] }),
    vector('padded-two-tail', {}, { audio: Buffer.from('ABCD') }),
    vector('padded-one-tail', {}, { audio: Buffer.from('ABCDE') }),
    vector('unpadded-two-tail', {}, { audio: Buffer.from('ABCD'), unpadded: true, sizes: [5, 2, 17] }),
    vector('unpadded-one-tail', {}, { audio: Buffer.from('ABCDE'), unpadded: true, sizes: [5, 2, 17] }),
    vector('ignored-stream-fields', {}, { events: [{ id: 'synthetic', model: 'ignored-server-model', choices: [{ delta: { role: 'assistant', content: 'ignored text' } }] },
      { choices: [{ delta: { audio: { data: split, transcript: 'Kept lyrics' } }, message: { audio: { data: 'aWdub3JlZA==' } } },
        { delta: { audio: { data: 'aWdub3JlZA==', transcript: 'ignored second choice' } } }], audio: { data: 'aWdub3JlZA==' }, usage: { total_tokens: 42 } },
      { choices: [], usage: { total_tokens: 45 } }], sizes: [13, 4, 77] }),
    vector('ordinary-sse-comments-crlf', {}, { raw: ': keepalive\r\nevent: message\r\ndata: \r\n\r\n  data: ' +
      JSON.stringify(event(split, ' CRLF lyric ')) + '\r\n\r\ndata: [DONE]\r\n', sizes: [1, 2, 19, 4] }),
    vector('audio-delta-edge-whitespace', {}, { events: [event(' \t' + split.slice(0, 5) + '  '),
      event('\n' + split.slice(5) + '\t')], sizes: [3, 17, 2] }),
  ];
  const large = Buffer.alloc(196609);
  for (let index = 0; index < large.length; index++) large[index] = index % 251;
  const largeEncoded = large.toString('base64');
  rows.push(vector('large-multiple-events-chunks', {}, { events: [event(largeEncoded.slice(0, 65537), 'Start '),
    event(largeEncoded.slice(65537, 180003), '歌 😀 '), event(largeEncoded.slice(180003), 'end')], sizes: [4093, 8191, 37] }));
  rows.push(vector('large-single-event-chunks', { format: 'mp3' }, { audio: large.subarray(0, 65537), sizes: [4093, 8191, 37] }));
  rows.push(vector('near-configured-audio-transcript-caps', {}, { audio: large.subarray(0, 32767),
    transcript: '歌'.repeat(10922), config: { mediaMaxMb: 0.03125 }, sizes: [4093, 127, 8191] }));
  return rows.map(plain);
}

class MusicGenerationHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, Uint8Array, TextDecoder, Headers, Response,
      fetch: () => { throw Error('Undeclared real music fetch'); },
      __platform: { config: params => this.config(params), post: params => this.post(params),
        status: async (_response, label) => { this.current.statusCalls.push({ label }); },
        cap: (kind, maxBytes) => { this.current.maxBytesCalls.push({ kind, maxBytes }); } } },
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
    return this.synthetic('capture:music-generation:' + key, code);
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

  projectedCaps() {
    const original = readFileSync(join(this.root, caps));
    assert.equal(hash(original), this.tracked.get(caps));
    const start = original.indexOf('const MB = 1024 * 1024;');
    const end = original.indexOf('/**\n * Bounds a provider\'s download', start);
    assert.ok(start >= 0 && end > start);
    const selected = original.subarray(start, end);
    const prelude = `import {maxBytesForKind} from 'capture:source:${constants}';\n`;
    const generated = prelude + selected.toString();
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(caps, { path: caps, sha256: hash(original), executed: true, wholeModule: false,
      projection: { startByte: start, endByte: end, sourceRegionSha256: hash(selected), prelude,
        generatedCode: generated, generatedSha256: hash(generated) }, transformation: transform,
      executableSha256: hash(executable) });
    return this.binding('capture:shared', 'capture:music-caps', 'complete-source-region-projection',
      ['resolveGeneratedMediaMaxBytes'], executable, { source: caps, sourceSha256: this.tracked.get(caps) });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:music-generation:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:music-generation:') && specifier === 'capture:music-caps') {
      return this.projectedCaps();
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/image-generation') return this.alias(importer, specifier,
      imageAssets, ['toImageDataUrl'], 'src/plugin-sdk/image-generation.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-runtime') return this.alias(importer, specifier,
      base64, ['canonicalizeBase64', 'estimateBase64DecodedBytes'], 'src/plugin-sdk/media-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/number-runtime') return this.alias(importer, specifier,
      number, ['resolvePositiveTimerTimeoutMs'], 'src/plugin-sdk/number-runtime.ts');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.binding(importer, specifier,
      'whole-source-export-alias', ['asOptionalRecord', 'isRecord', 'normalizeOptionalString'],
      `export {asOptionalRecord,isRecord} from 'capture:source:${records}';\nexport {normalizeOptionalString} from 'capture:source:${strings}';`,
      { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-generation-runtime') return this.binding(importer, specifier,
      'source-region-observing-export-alias', ['resolveGeneratedMediaMaxBytes'],
      `import {resolveGeneratedMediaMaxBytes as resolve} from 'capture:music-caps';\nexport function resolveGeneratedMediaMaxBytes(cfg,kind){const value=resolve(cfg,kind);globalThis.__platform.cap(kind,value);return value;}`,
      { source: caps, sourceSha256: this.tracked.get(caps), origin: 'src/plugin-sdk/media-generation-runtime.ts',
        originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') return this.binding(importer, specifier,
      'uninvoked-dependency-facade', ['isProviderApiKeyConfiguredAsync'],
      `export function isProviderApiKeyConfiguredAsync(){globalThis.__deferredCalls.push('isProviderApiKeyConfiguredAsync');throw Error('Uninvoked account configuration lookup');}`,
      { source: 'src/plugin-sdk/provider-auth.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth.ts'), originalSourceExecuted: false });
    if ([entry, contextSource].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http') return this.binding(importer, specifier,
      'successful-config-status-transport-fixture', importer === entry ? ['assertOkOrThrowHttpError', 'postJsonRequest'] :
        ['resolveProviderApiKeyHttpRequestConfig', 'sanitizeConfiguredModelProviderRequest'],
      importer === entry ? 'export const assertOkOrThrowHttpError=globalThis.__platform.status;\nexport const postJsonRequest=globalThis.__platform.post;' :
        'export const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;\nexport function sanitizeConfiguredModelProviderRequest(){return undefined;}',
      { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
        boundary: 'Successful context/config/account/header/status/submission facade; raw native Response body is parsed by unchanged complete provider source.' });
    if (importer === contextSource && specifier === './provider-catalog.js') return this.alias(importer, specifier,
      defaults, ['OPENROUTER_BASE_URL'], 'extensions/openrouter/provider-catalog.ts');
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/normalization-core/record-coerce': records, '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared music-generation import: ${importer} -> ${specifier}`);
  }

  config(params) {
    assert.equal(params.provider, 'openrouter');
    assert.equal(params.capability, 'audio');
    assert.equal(params.jsonContentType, true);
    this.current.configCalls.push(plain({ provider: params.provider, capability: params.capability,
      jsonContentType: params.jsonContentType, baseUrl: params.baseUrl, defaultBaseUrl: params.defaultBaseUrl }));
    return { baseUrl: (params.baseUrl ?? params.defaultBaseUrl).trim().replace(/\/+$/, ''),
      headers: new Headers({ 'content-type': 'application/json', 'x-fixture-header': 'synthetic-config' }),
      allowPrivateNetwork: false, dispatcherPolicy: undefined };
  }

  async post(params) {
    this.current.request = { url: params.url, method: 'POST', timeoutMs: params.timeoutMs,
      headers: Object.fromEntries(params.headers), jsonBody: plain(params.body), bodyKeyOrder: Object.keys(params.body) };
    const buffers = this.current.response.chunksBase64.map(value => Buffer.from(value, 'base64'));
    const response = new Response(new ReadableStream({ start(controller) {
      for (const bytes of buffers) controller.enqueue(bytes);
      controller.close();
    } }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
    const body = response.body;
    const actualGetReader = body.getReader.bind(body);
    body.getReader = (...args) => {
      const reader = actualGetReader(...args);
      const read = reader.read.bind(reader);
      const cancel = reader.cancel.bind(reader);
      const releaseLock = reader.releaseLock.bind(reader);
      reader.read = async (...values) => {
        const result = await read(...values);
        if (!result.done) this.current.stream.chunksRead++;
        return result;
      };
      reader.cancel = (...values) => { this.current.stream.readerCancelCount++; return cancel(...values); };
      reader.releaseLock = () => { this.current.stream.readerReleaseLockCount++; return releaseLock(); };
      return reader;
    };
    this.current.body = body;
    return { response, release: async () => { this.current.releaseCount++; } };
  }

  async run(vector) {
    this.current = { response: vector.response, configCalls: [], statusCalls: [], maxBytesCalls: [], releaseCount: 0,
      stream: { chunksRead: 0, readerCancelCount: 0, readerReleaseLockCount: 0 } };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) =>
      ({ ...image, ...(bytesBase64 ? { buffer: Buffer.from(bytesBase64, 'base64') } : {}) }));
    const req = { ...input, provider: 'openrouter', cfg: { models: { providers: { openrouter: {
      ...(vector.config.baseUrl === undefined ? {} : { baseUrl: vector.config.baseUrl }),
    } } }, ...(vector.config.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } }) } };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.buildOpenRouterMusicGenerationProvider().generateMusic(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Music fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) =>
        ({ ...image, ...(buffer ? { bytesBase64: buffer.toString('base64') } : {}) }));
      const inputAfter = plain(after);
      assert.deepEqual(inputAfter, vector.input);
      const { request, releaseCount, stream, configCalls, statusCalls, maxBytesCalls } = this.current;
      assert.equal(releaseCount, 1);
      assert.equal(stream.readerCancelCount, 1);
      assert.equal(stream.readerReleaseLockCount, 1);
      assert.equal(this.current.body.locked, false);
      return { ...vector, inputAfter, request,
        result: plain({ ...result, tracks: result.tracks.map(({ buffer, ...track }) => ({ ...track, bytesBase64: buffer.toString('base64') })) }),
        releaseCount, stream: { ...stream, lockedAfter: this.current.body.locked }, configCalls, statusCalls, maxBytesCalls };
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenRouterMusicGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new MusicGenerationHarness(root, before.tracked);
  await harness.load(entry);
  const provider = harness.call(`(() => {const p=__exports.buildOpenRouterMusicGenerationProvider();return {id:p.id,label:p.label,defaultModel:p.defaultModel,models:p.models,capabilities:p.capabilities};})()`);
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
  return { schemaVersion: 1, referencePin: OPENROUTER_MUSIC_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-openrouter-music-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.call('__captureAudit'),
    deferredCalls: harness.call('__deferredCalls'), provider,
    limits: [
      'Complete unchanged buildOpenRouterMusicGenerationProvider/generateMusic and actual SSE parser execute with whole original base64, image, number, string/record normalization, request context and base URL modules. Only configured media cap is a complete original source-region projection with byte offsets and original/generated/executable hashes.',
      'All 58,558 tracked reference blobs are verified before/after; source, executable, exporter, shared harness, runtime and importer-specific binding hashes are recorded. SDK/service/registration provenance-only files are not executed.',
      'Context/config/account/header/status/HTTP submission use successful synthetic facades. Native Response/ReadableStream and actual TextDecoder process declared raw UTF8 byte chunks; this proves parser functionality, not real sockets, HTTP transport, auth, policy, TLS, retries, timer enforcement or real provider service.',
      'Actual parser normal-completion cleanup invokes native reader.cancel and releaseLock once, and actual provider release executes once. No interrupted/cancel/crash/negative/failure/security/permission paths execute; normal reader cleanup does not prove interruption semantics.',
      'Actual cap resolver defaults audio to 16MiB or floors mediaMaxMb*1048576. Near-cap successful audio/transcript vectors use an ordinary configured 32KiB cap; production default-sized media and overflow are not exercised. Event limit formula is source provenance and successful large-event evidence only.',
      'Omitted source timeout defaults to 180000ms and is hostComparable=false; host protocol requires an explicit finite total timeout. Other observations supply finite timeouts. No timeout elapses or transport deadline enforcement runs.',
      'Audio/image payloads are synthetic protocol bytes; no codec, playback, audio quality or image model executes. Results preserve complete tracks/model/optional lyrics/metadata shape, serializing buffers solely as bytesBase64. Transcript whitespace is preserved by source.',
      'Inactive independent source oracle only: no music tool/catalog/config enablement, durable media/jobs/reference integration, registration execution, real provider request, whole reference/P10 or tool-goal completion.',
    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-openrouter-music-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3);
  const result = await captureOpenRouterMusicGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
