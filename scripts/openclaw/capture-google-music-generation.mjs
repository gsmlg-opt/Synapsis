// Unchanged pinned GOOGLE music callback with explicit ordinary successful synthetic I/O.
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

export const GOOGLE_MUSIC_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/google/music-generation-provider.ts';
const metadata = 'extensions/google/generation-provider-metadata.ts';
const googleBase64 = 'extensions/google/base64.ts';
const googleRuntime = 'extensions/google/google-genai-runtime.ts';
const googleAuth = 'extensions/google/generation-auth.ts';
const googleHeaders = 'extensions/google/google-api-client-header.ts';
const googlePolicy = 'extensions/google/provider-policy.ts';
const googleUrls = 'extensions/google/src/google-api-base-url.ts';
const sdkRoot = '/tmp/synapsis-googlemusic365-sdk';
const sdkEntry = sdkRoot + '/node_modules/@google/genai/dist/node/index.mjs';
const assets = 'src/music-generation/provider-assets.ts';
const shared = 'src/media-understanding/shared.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const base64 = 'packages/media-core/src/base64.ts';
const constants = 'packages/media-core/src/constants.ts';
const mime = 'packages/media-core/src/mime.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, metadata, googleBase64, googleRuntime, googleAuth, googleHeaders, googlePolicy, googleUrls,
  'extensions/google/model-id.ts', 'packages/model-catalog-core/src/provider-model-id-normalize.ts',
  assets, strings, records, numbers, base64, constants, mime, 'packages/media-core/src/file-name.ts'];
const provenancePaths = ['LICENSE', 'extensions/google/package.json', 'pnpm-lock.yaml',
  'extensions/google/index.ts', 'extensions/google/openclaw.plugin.json',
  'src/plugin-sdk/music-generation.ts', 'src/plugin-sdk/media-mime.ts', 'src/plugin-sdk/provider-http.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts',
  'src/plugin-sdk/provider-thinking-runtime.ts', 'src/plugin-sdk/model-ref-parse.ts',
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugin-sdk/realtime-voice-provider.ts',
  'src/agents/provider-http-errors.ts', 'src/agents/provider-attribution.ts', 'src/infra/http-body.ts', 'src/music-generation/types.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), GOOGLE_MUSIC_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', GOOGLE_MUSIC_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: GOOGLE_MUSIC_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${GOOGLE_MUSIC_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

function vectors() {
  const inline = (data = 'AP+A', mimeType = 'audio/mpeg') => ({ inlineData: { data, ...(mimeType === null ? {} : { mimeType }) } });
  const response = (...parts) => ({ candidates: [{ content: { parts } }] });
  const base = (id, input = {}, options = {}) => ({ id,
    input: { prompt: ' \uFEFF Morning melody 歌 😀 \n', timeoutMs: 12345, ...input },
    config: options.config ?? {}, response: options.response ?? response(inline()),
    ...(options.sourceOnly ? { hostComparable: false,
      adaptationReason: 'Source omitted timeout defaults180000ms; host requires explicit positive finite total timeout.' } : {}) });
  return [
    base('clip-default'),
    base('source-default-timeout', { timeoutMs: undefined }, { sourceOnly: true }),
    base('blank-model-and-lyrics', { model: ' \uFEFF\u00A0 ', lyrics: ' \uFEFF\u00A0 ' }),
    base('pro-wav', { model: ' \uFEFF lyria-3-pro-preview \u00A0', format: 'wav' }, { response: response(inline('AP+A', 'Audio/WAVE; codecs=pcm')) }),
    base('pro-mp3', { model: 'lyria-3-pro-preview', format: 'mp3' }),
    base('models-resource-name', { model: ' models/lyria-3-pro-preview ', format: 'mp3' }, { response: response(inline('AP+A', 'audio/vendor-unknown')) }),
    base('tunedModels-resource-name', { model: ' tunedModels/custom-music ' }),
    base('provider-prefix-preserved', { model: ' google/lyria-3-pro-preview ' }, { response: response(inline('AP+A', 'audio/vendor-unknown')) }),
    base('unknown-pro-mime-wav', { model: 'lyria-3-pro-preview' }, { response: response(inline('AP+A', 'audio/vendor-unknown')) }),
    base('instrumental-with-lyrics', { prompt: ' \uFEFF Compose 雪 😀 \u00A0', instrumental: true,
      lyrics: ' \uFEFF Verse one\n第二行 😀 \u00A0', format: 'mp3', durationSeconds: 33.5 }),
    base('image-default-mime', { inputImages: [{ bytesBase64: 'AP+A' }] }),
    base('ordered-image-inputs', { inputImages: [
      { bytesBase64: 'AAEC/w==', mimeType: ' \uFEFF Image/JPEG; source=fixture \u00A0', fileName: 'ignored-one.jpg' },
      { bytesBase64: 'ECA=', mimeType: ' \uFEFF\u00A0 ', fileName: 'ignored-two.png' },
    ] }),
    base('ten-image-inputs', { inputImages: Array.from({ length: 10 }, (_, i) => ({ bytesBase64: Buffer.from([i, 255 - i]).toString('base64'), mimeType: 'image/png' })) }),
    base('all-candidate-text-media-order', {}, { response: { modelVersion: 'ignored', usageMetadata: { totalTokenCount: 42 },
      candidates: [
        { content: { parts: [
          { text: ' \uFEFF First lyric 雪 😀 \u00A0', inlineData: { data: 'AQ==', mimeType: 'audio/flac' } },
          { text: ' \t ', inlineData: { data: 'Ag==', mimeType: ' Audio/FLAC; mode=fixture ', mime_type: 'audio/wav' } },
          { inlineData: null, inline_data: { data: 'Aw==', mime_type: ' AUDIO/WAV ' } },
        ] } },
        { content: { parts: [
          { text: ' Second lyric\n歌 ' },
          { inline_data: { data: 'BA==', mime_type: 'audio/ogg' } },
          { inlineData: { data: 'BQ==', mimeType: ' \uFEFF ', mime_type: ' audio/x-m4a ' } },
        ] } },
      ] } }),
    base('camel-empty-inline-suppresses-snake', {}, { response: response(
      { inlineData: {}, inline_data: { data: 'AQ==', mime_type: 'audio/flac' } },
      {}, { text: '  普通 text  ' }, inline()) }),
    base('base64-standard-url-safe-variants', {}, { response: response(
      inline('AQ=='), inline('Ag'), inline('-_8='), inline('-_8'), inline(' \u0000A\tP+\nA\u001f ')) }),
    base('default-mime-and-raw-alias', {}, { response: response(inline('AQ==', null), inline('Ag==', ' AUDIO/X-WAV; source=fixture ')) }),
    base('official-openai-base-normalization', {}, { config: { baseUrl: ' https://GENERATIVELANGUAGE.GOOGLEAPIS.COM/v1beta/openai///?unused=yes#fragment ' } }),
    base('custom-versioned-base', {}, { config: { baseUrl: ' https://relay.example.test/prefix/v1beta/?unused=yes#fragment ' } }),
    base('duration-unused', { durationSeconds: 90, instrumental: false }),
  ].map(plain);
}

class GoogleMusicHarness extends FactoryHarness {
  constructor(root, tracked, sdk) {
    super(root, tracked, { allowedSources: wholeSources });
    const fixtureNow = 1_800_000_000_000;
    class FixtureDate extends Date { static now() { return fixtureNow; } }
    this.context = vm.createContext({ Buffer, Uint8Array, TextDecoder, Headers, Response, URL,
      AbortController, AbortSignal, setTimeout, clearTimeout, Date: FixtureDate,
      fetch: () => { throw Error('Undeclared real Google fetch'); },
      __path: path, __sdk: sdk,
      __platform: { key: params => this.key(params), attribution: params => this.attribution(params),
        options: params => this.options(params), fetch: (...args) => this.fetch(...args) } },
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
    return this.synthetic('capture:google-music:' + key, code);
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

  unused(importer, specifier, exports, source) {
    return this.binding(importer, specifier, 'uninvoked-dependency-facade', exports,
      exports.map(name => `export function ${name}(){globalThis.__deferredCalls.push(${JSON.stringify(name)});throw Error('Uninvoked Google music dependency');}`).join('\n'),
      { source, sourceSha256: this.tracked.get(source), originalSourceExecuted: false });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:google-music:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (parent.startsWith('capture:google-music:') && specifier === 'capture:google-deadlines') {
      return this.projection(specifier, shared, 'export function createProviderOperationDeadline(',
        '/** Waits for the next poll interval',
        `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${numbers}';\nconst DEFAULT_GUARDED_HTTP_TIMEOUT_MS=60000;\n`,
        ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs']);
    }
    if (importer.startsWith('extensions/google/') && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return this.alias(importer, specifier, strings, ['normalizeOptionalString'], 'src/plugin-sdk/string-coerce-runtime.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/music-generation') {
      return this.alias(importer, specifier, assets, ['generatedMusicAssetFromBase64'], 'src/plugin-sdk/music-generation.ts');
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-mime') {
      return this.alias(importer, specifier, mime, ['extensionForMime'], 'src/plugin-sdk/media-mime.ts');
    }
    if (importer === googleBase64 && specifier === 'openclaw/plugin-sdk/realtime-voice-provider') {
      return this.alias(importer, specifier, base64, ['canonicalizeBase64'], 'src/plugin-sdk/realtime-voice-provider.ts');
    }
    if (importer === metadata && specifier === 'openclaw/plugin-sdk/provider-auth') {
      return this.unused(importer, specifier, ['isProviderApiKeyConfiguredAsync'], 'src/plugin-sdk/provider-auth.ts');
    }
    if (importer === googleAuth && specifier === 'openclaw/plugin-sdk/provider-auth-runtime') {
      return this.binding(importer, specifier, 'successful-explicit-key-fixture', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.key;',
        { source: 'src/plugin-sdk/provider-auth-runtime.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-auth-runtime.ts'), originalSourceExecuted: false });
    }
    if (importer === googleRuntime && specifier === '@google/genai') {
      return this.binding(importer, specifier, 'actual-pinned-sdk-constructor-with-only-fetch-injection', ['GoogleGenAI'],
        `export class GoogleGenAI extends globalThis.__sdk.GoogleGenAI {constructor(options){globalThis.__platform.options(options);super({...options,httpOptions:{...options.httpOptions,fetch:globalThis.__platform.fetch}});}}`,
        { sdkEntry, sdkEntrySha256: hash(readFileSync(sdkEntry)), sdkVersion: '2.28.0',
          boundary: 'Actual unchanged installed SDK constructor and generateContent request/response conversion execute. The only SDK option added by this constructor facade is httpOptions.fetch returning explicit successful native Response fixtures.' });
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-http') {
      return this.binding(importer, specifier, 'exact-source-deadlines-export-alias', ['createProviderOperationDeadline', 'resolveProviderOperationTimeoutMs'],
        `export {createProviderOperationDeadline,resolveProviderOperationTimeoutMs} from 'capture:google-deadlines';`,
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false });
    }
    if (importer === googleHeaders && specifier === 'openclaw/plugin-sdk/provider-http') {
      return this.binding(importer, specifier, 'successful-empty-attribution-fixture', ['resolveProviderRequestHeaders'],
        'export const resolveProviderRequestHeaders=globalThis.__platform.attribution;',
        { source: 'src/plugin-sdk/provider-http.ts', sourceSha256: this.tracked.get('src/plugin-sdk/provider-http.ts'), originalSourceExecuted: false,
          boundary: 'Attribution returns an explicit empty successful fixture; source wrapper executes, shared attribution policy does not. No OpenClaw client identity is injected.' });
    }
    if (importer === googlePolicy && specifier === 'openclaw/plugin-sdk/provider-thinking-runtime') {
      return this.unused(importer, specifier, ['isGoogleGemini3ProModel', 'isGoogleGemini3ThinkingLevelModel'], 'src/plugin-sdk/provider-thinking-runtime.ts');
    }
    if (importer === 'extensions/google/model-id.ts' && specifier === 'openclaw/plugin-sdk/model-ref-parse') {
      return this.alias(importer, specifier, 'packages/model-catalog-core/src/provider-model-id-normalize.ts',
        ['normalizeAntigravityPreviewModelId', 'normalizeGooglePreviewModelId'], 'src/plugin-sdk/model-ref-parse.ts');
    }
    if (importer === assets && specifier === '../agents/provider-http-errors.js') {
      return this.unused(importer, specifier, ['readProviderBinaryResponse'], 'src/agents/provider-http-errors.ts');
    }
    if (importer === assets && specifier === '../infra/http-body.js') {
      return this.unused(importer, specifier, ['readResponseWithLimit'], 'src/infra/http-body.ts');
    }
    if (importer === assets && specifier === '../media-understanding/shared.js') {
      return this.unused(importer, specifier, ['createProviderOperationDeadline', 'createProviderOperationTimeoutResolver', 'fetchProviderDownloadResponse'], shared);
    }
    if (['packages/media-core/src/file-name.ts', mime].includes(importer) && specifier === 'node:path') {
      return this.binding(importer, specifier, 'native-node-path-binding', ['default'], 'export default globalThis.__path;');
    }
    const packages = { '@openclaw/media-core/base64': base64, '@openclaw/media-core/constants': constants,
      '@openclaw/media-core/mime': mime, '@openclaw/normalization-core/record-coerce': records,
      '@openclaw/normalization-core/string-coerce': strings, '@openclaw/normalization-core/number-coercion': numbers };
    if (wholeSources.includes(importer) && packages[specifier]) return this.source(importer, specifier, packages[specifier]);
    if (wholeSources.includes(importer) && specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared Google music import: ${importer} -> ${specifier}`);
  }

  key(params) {
    this.current.keyCalls.push(plain(params));
    assert.equal(params.provider, 'google');
    return { apiKey: 'synthetic-google-fixture-key' };
  }

  attribution(params) {
    this.current.attributionCalls.push(plain(params));
    return {};
  }

  options(params) {
    this.current.sdkOptions.push(plain(params));
  }

  async fetch(url, init) {
    assert.equal(init.method, 'POST');
    assert.equal(typeof init.body, 'string');
    this.current.requests.push({ url: String(url), method: init.method,
      headers: Object.fromEntries(new Headers(init.headers)), rawBody: init.body, body: JSON.parse(init.body),
      signalProvided: init.signal instanceof AbortSignal });
    const raw = JSON.stringify(this.current.response);
    const response = new Response(raw, { status: 200, headers: { 'content-type': 'application/json' } });
    const json = response.json.bind(response), text = response.text.bind(response);
    response.json = async () => { this.current.responseReads.json++; const value = await json(); this.current.sdkJsonInput = plain(value); return value; };
    response.text = async () => { this.current.responseReads.text++; const value = await text(); this.current.sdkTextInput = value; return value; };
    return response;
  }

  async run(vector) {
    this.current = { response: vector.response, keyCalls: [], attributionCalls: [], sdkOptions: [], requests: [], responseReads: { json: 0, text: 0 } };
    const cfg = { models: { providers: { google: {
      ...(vector.config.baseUrl === undefined ? {} : { baseUrl: vector.config.baseUrl }),
    } } } };
    const { inputImages, ...input } = vector.input;
    const req = { ...plain(input), ...(inputImages === undefined ? {} : {
      inputImages: inputImages.map(({ bytesBase64, ...image }) => ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') })) }),
      provider: 'google', cfg, agentDir: '/synthetic/google-agent', authStore: { fixture: 'synthetic-key-store' } };
    const before = plain(req);
    this.context.__req = req;
    let timer;
    try {
      const operation = new vm.Script('__exports.googleMusicGenerationProvider.generateMusic(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Google music fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(req), before);
      const { response: _response, ...calls } = this.current;
      assert.equal(calls.requests.length, 1);
      assert.equal(calls.sdkOptions.length, 1);
      return { ...vector, inputAfter: plain(vector.input), ...calls,
        result: plain({ ...result, tracks: result.tracks.map(({ buffer, ...track }) => ({ ...track, bytesBase64: buffer.toString('base64') })) }) };
    } finally { clearTimeout(timer); }
  }

}

function sdkProvenance(root) {
  const sourceManifest = JSON.parse(readFileSync(join(root, 'extensions/google/package.json')));
  assert.equal(sourceManifest.dependencies['@google/genai'], '2.28.0');
  const pnpm = readFileSync(join(root, 'pnpm-lock.yaml'), 'utf8');
  const match = pnpm.match(/'@google\/genai@2\.28\.0':\n\s+resolution: \{integrity: ([^}]+)\}/);
  assert.ok(match);
  const lock = JSON.parse(readFileSync(join(sdkRoot, 'package-lock.json')));
  const resolved = lock.packages['node_modules/@google/genai'];
  assert.equal(resolved.version, '2.28.0');
  assert.equal(resolved.integrity, match[1]);
  const installed = JSON.parse(readFileSync(join(sdkRoot, 'node_modules/@google/genai/package.json')));
  assert.equal(installed.version, '2.28.0');
  assert.equal(installed.exports['.'].node.import, './dist/node/index.mjs');
  const files = ['package.json', 'package-lock.json', 'node_modules/@google/genai/package.json',
    'node_modules/@google/genai/dist/node/index.mjs', 'node_modules/@google/genai/LICENSE'];
  return { name: '@google/genai', version: installed.version, root: sdkRoot, entry: sdkEntry,
    npmIntegrity: resolved.integrity, pinnedSourceIntegrity: match[1],
    sourceManifest: 'extensions/google/package.json', sourceLock: 'pnpm-lock.yaml',
    files: files.map(path => ({ path: join(sdkRoot, path), sha256: hash(readFileSync(join(sdkRoot, path))) })),
    boundary: 'Actual Node SDK entry and its installed native import graph execute; listed provenance does not establish transitive source coverage. Custom successful fetch replaces socket transport only; constructor facade adds only httpOptions.fetch. No SDK monkeypatch or generateContent replacement.' };
}

export async function captureGoogleMusicGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const sdkBefore = sdkProvenance(root);
  const sdk = await import(sdkEntry);
  const harness = new GoogleMusicHarness(root, before.tracked, sdk);
  await harness.load(entry);
  const provider = harness.call(`(() => {const p=__exports.googleMusicGenerationProvider;return {id:p.id,label:p.label,defaultModel:p.defaultModel,models:p.models,capabilities:p.capabilities};})()`);
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
  const sdkAfter = sdkProvenance(root);
  assert.deepEqual(sdkAfter, sdkBefore);
  return { schemaVersion: 1, referencePin: GOOGLE_MUSIC_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-google-music-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, sdk: { before: sdkBefore, after: sdkAfter }, transformation: transform,
    platform: { dateNowMs: 1800000000000, clock: 'explicit synthetic fixed Date.now for deterministic ordinary deadline observations; native timers complete without expiration' },
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.call('__captureAudit'),
    deferredCalls: harness.call('__deferredCalls'), provider,
    limits: [
      'Complete unchanged Google music callback, metadata, SDK factory, key and attribution wrappers, base64/assets/MIME/normalizers, policy/base-URL/model-ID modules execute. Whole-module evaluation does not establish every exported branch executed; unrelated image/video/thinking/model-alias helpers remain uninvoked.',
      'Shared deadline helpers execute one exact complete original source region with source byte offsets and original/generated/executable hashes. Fixed Date.now makes successful deadlines reproducible; real timer expiration is not tested.',
      'Actual installed @google/genai2.28.0 constructor and generateContent request/response conversion execute. The only constructor-facade option added is httpOptions.fetch. SDK native imports execute normally; tracked entry/package/lock hashes and npm integrity equality do not claim all transitive source execution or coverage.',
      'Synthetic successful API key and empty attribution fixtures keep saved/environment discovery, identity policy and readiness unexecuted. Actual source wrappers record their inputs; no OpenClaw client identity is injected.',
      'Synthetic fetch supplies one native successful JSON Response per callback. Actual SDK request serialization and response parsing execute, with exact raw requests/results retained; this does not prove real sockets, provider acceptance, TLS/auth/security/permission or cancellation ownership.',
      'Only first-response audio success executes. Source text-only retry and explicit terminal-stop paths are not invoked. All candidate/part order, nonblank text precedence, nullish inline keys, raw MIME/extension rules and Base64 conversions are qualified by ordinary successful fixtures.',
      'Source omitted timeout defaults180000ms and is separately hostComparable=false. Google callback has no host audio/raw body caps; host additions do not become source parity. Opaque bytes do not establish codec/playback/quality evidence.',
      'All58558 pinned tracked blobs are verified before/after; LICENSE/source/executable/exporter/shared-harness/runtime/import facades and SDK files are recorded. No negative/failure/cancel/crash/timeout-exhaustion/race/mixed tests, real provider request or public tool/config/job/storage/delivery/completion/replay/native registration/whole reference/P10/goal acceptance. Source observations do not claim host all-vector replay.',

    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  assert.equal(args.indexOf('--out'), 1, 'usage: capture-google-music-generation.mjs PINNED_SOURCE --out OUTPUT_JSON');
  assert.equal(args.length, 3);
  const result = await captureGoogleMusicGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
