// Unchanged pinned Comfy music registration/workflow; successful synthetic I/O only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import path from 'node:path';
import { FactoryHarness } from './capture-recipes.mjs';


export const COMFY_MUSIC_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/comfy/index.ts';
const runtime = 'extensions/comfy/workflow-runtime.ts';
const http = 'extensions/comfy/workflow-http.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const lists = 'packages/normalization-core/src/string-normalization.ts';
const boolean = 'src/utils/boolean.ts';
const constants = 'packages/media-core/src/constants.ts';
const mime = 'packages/media-core/src/mime.ts';
const filenames = 'packages/media-core/src/file-name.ts';
const blob = 'src/plugin-sdk/blob-runtime.ts';
const base64 = 'packages/media-core/src/base64.ts';
const caps = 'src/media/configured-max-bytes.ts';
const errors = 'src/agents/provider-http-errors.ts';
const requestConfigSource = 'src/agents/provider-request-config.ts';
const wholeSources = [entry, runtime, http, number, strings, records, lists, boolean,
  constants, mime, filenames, blob, base64];
const provenancePaths = ['extensions/comfy/openclaw.plugin.json', 'extensions/comfy/package.json',
  'src/plugin-sdk/plugin-entry.ts', 'src/plugin-sdk/provider-auth-api-key.ts',
  'src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugin-sdk/secret-ref-readonly.ts',
  'src/plugin-sdk/media-generation-runtime.ts', 'src/plugin-sdk/media-mime.ts',
  'src/plugin-sdk/number-runtime.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/secret-input-runtime.ts',
  'src/plugin-sdk/ssrf-runtime.ts', 'src/plugin-sdk/text-utility-runtime.ts',
  'src/music-generation/types.ts', 'LICENSE', 'src/infra/http-body.ts',
  'src/infra/http-response-body.ts', 'src/infra/http-response-body-timeout.ts'];
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
// Do not sort keys: the original workflow traverses Object.keys(history.outputs).
const plain = value => JSON.parse(JSON.stringify(value));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), COMFY_MUSIC_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', COMFY_MUSIC_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
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
    verified: true, commit: COMFY_MUSIC_GENERATION_PIN,
    tree: git(root, ['rev-parse', `${COMFY_MUSIC_GENERATION_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const audio = 'AAECA//+gH8=';
const prompt = ' Compose a small blue melody. ';
const graph = () => ({
  '6': { class_type: 'CLIPTextEncode', inputs: { text: 'original prompt', clip: ['4', 1] } },
  '3': { class_type: 'KSampler', inputs: { seed: 731, steps: 20, model: ['4', 0] } },
  '8': { class_type: 'LoadImage', inputs: { image: 'original.png' } },
  '9': { class_type: 'SaveAudio', inputs: { filename_prefix: 'ComfyUI', audio: ['3', 0] } },
});
const asset = (filename = 'output.mp3', extra = {}) => ({ filename, ...extra });
const history = (outputs = { '9': { audio: [asset()] } }) => ({ outputs, status: { completed: true } });
function vectors() {
  const row = (id, options = {}) => ({ id, hostComparable: options.hostComparable ?? true,
    ...(options.adaptationReason ? { adaptationReason: options.adaptationReason } : {}),
    input: { prompt, model: 'workflow', timeoutMs: 30000, ...options.input },
    config: { mode: 'local', baseUrl: 'https://comfy.example.test', workflow: graph(),
      promptNodeId: '6', pollIntervalMs: 100, ...options.config },
    ...(options.mediaMaxMb === undefined ? {} : { mediaMaxMb: options.mediaMaxMb }),
    responsePlan: { prompt: { prompt_id: ' job-17 ' }, upload: { filename: 'uploaded.png' },
      statuses: [{ status: 'completed' }], histories: [history()],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/mpeg' }], ...options.responsePlan },
  });
  return plain([
    row('local-generate'),
    row('cloud-generate', { config: { mode: 'cloud', apiKey: 'synthetic-comfy-key' } }),
    row('prompt-unicode-whitespace', { input: { prompt: '  音乐 🌕 e\u0301\n' } }),
    row('custom-model-label', { input: { model: '  custom display label  ' } }),
    row('blank-model-default', { input: { model: ' \uFEFF\u00a0 ' } }),
    row('null-model-default', { input: { model: null } }),
    row('omitted-model-default', { input: { model: undefined } }),
    row('fractional-timeout', { input: { timeoutMs: 30000.9 } }),
    row('empty-references', { input: { inputImages: [] } }),
    row('ignored-raw-music-options', { input: { lyrics: 'ignored lyric text', instrumental: true,
      format: 'wav', duration: 19, durationSeconds: 23,
      providerOptions: { comfy: { seed: 999, steps: 99 } } } }),
    row('local-history-pending', { responsePlan: { histories: [{}, history()] } }),
    row('cloud-status-pending', { config: { mode: 'cloud', apiKey: 'synthetic-comfy-key' },
      responsePlan: { statuses: [{ status: 'pending' }, { status: 'running' }, { status: 'completed' }] } }),
    row('nested-history', { responsePlan: { histories: [{ 'job-17': history() }] } }),
    row('history-outputs-terminal', { responsePlan: { histories: [{ outputs: { '9': { audio: [asset()] } } }] } }),
    row('output-name-fallback', { responsePlan: { histories: [history({ '9': { audio: [{ name: ' fallback.music ' }] } })] } }),
    row('output-filename-priority', { responsePlan: { histories: [history({ '9': { audio: [asset(' chosen.raw ', { name: 'ignored.wav' })] } })] } }),
    row('encoded-output-query', { responsePlan: { histories: [history({ '9': { audio: [asset(' 曲 +#?.mp3 ',
      { subfolder: ' folder /一 ', type: ' temp ' })] } })] } }),
    row('output-node-selector', { config: { outputNodeId: ' z ' }, responsePlan: {
      histories: [history({ '9': { audio: [asset('unselected.mp3')] }, z: { audio: [asset('selected.mp3')] } })] } }),
    row('output-order-integer-keys', { responsePlan: {
      histories: [history({ '10': { audio: [asset('ten.mp3')] }, '2': { audio: [asset('two.mp3')] } })],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/mpeg' }, { bytesBase64: 'QUJD', mimeType: 'audio/mpeg' }] } }),
    row('output-order-string-keys', { responsePlan: {
      histories: [history({ z: { audio: [asset('z.mp3')] }, a: { audio: [asset('a.mp3')] } })],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/mpeg' }, { bytesBase64: 'QUJD', mimeType: 'audio/mpeg' }] } }),
    row('output-order-integer-and-string-keys', { responsePlan: {
      histories: [history({ '10': { audio: [asset('ten.mp3')] }, z: { audio: [asset('z.mp3')] },
        '2': { audio: [asset('two.mp3')] }, a: { audio: [asset('a.mp3')] } })],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/mpeg' }, { bytesBase64: 'QUJD', mimeType: 'audio/mpeg' },
        { bytesBase64: 'REVG', mimeType: 'audio/mpeg' }, { bytesBase64: 'R0hJ', mimeType: 'audio/mpeg' }] } }),
    row('output-order-within-node', { responsePlan: {
      histories: [history({ '9': { audio: [asset('first.mp3'), asset('second.mp3')] } })],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/mpeg' }, { bytesBase64: 'QUJD', mimeType: 'audio/mpeg' }] } }),
    row('audio-bucket-selection', { responsePlan: { histories: [history({ '9': {
      images: [asset('ignore.png')], gifs: [asset('ignore.gif')], videos: [asset('ignore.mp4')], audio: [asset()]
    } })] } }),
    row('base-prefix-normalization', { config: { baseUrl: ' \uFEFFhttps://comfy.example.test/resource/v1///\u00a0' } }),
    row('output-missing-mime', { responsePlan: { downloads: [{ bytesBase64: audio }] } }),
    row('output-mime-parameters', { responsePlan: { downloads: [{ bytesBase64: audio, mimeType: ' Audio/MPEG; profile="ordinary" ' }] } }),
    row('output-wav-raw-filename', { responsePlan: { histories: [history({ '9': { audio: [asset('opaque.original')] } })],
      downloads: [{ bytesBase64: audio, mimeType: 'audio/wav' }] } }),
    row('alternate-prompt-binding', { config: { promptNodeId: ' 6 ', promptInputName: ' positive ' } }),
    row('repeat-workflow-first', { input: { prompt: 'first independent prompt' } }),
    row('repeat-workflow-second', { input: { prompt: 'second independent prompt' } }),
    row('local-upload-default-mime', { input: { inputImages: [{ bytesBase64: png }] }, config: { inputImageNodeId: '8' } }),
    row('local-upload-null-mime', { input: { inputImages: [{ bytesBase64: png, mimeType: null }] }, config: { inputImageNodeId: '8' } }),
    row('cloud-upload-named', { input: { inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: ' reference +.png ' }] },
      config: { mode: 'cloud', apiKey: 'synthetic-comfy-key', inputImageNodeId: '8', inputImageInputName: ' reference ' },
      responsePlan: { upload: { name: ' uploaded fallback.png ' }, statuses: [{ status: 'pending' }, { status: 'completed' }] } }),
    row('upload-filename-priority', { input: { inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: 'source.png' }] },
      config: { inputImageNodeId: '8' }, responsePlan: { upload: { filename: ' chosen.png ', name: 'ignored.png' } } }),
    row('source-only-seed-binding', { hostComparable: false,
      adaptationReason: 'Deterministic randomInt facade returns42 and records exclusive bound; independent host random values are not compared.', config: { seedNodeId: '3' } }),
    row('source-only-alternate-seed-binding', { hostComparable: false,
      adaptationReason: 'Deterministic randomInt facade returns42 for alternate binding; host random values are not compared.', config: { seedNodeId: '3', seedInputName: ' noise_seed ' } }),
    row('source-only-default-timeout', { input: { timeoutMs: undefined }, hostComparable: false,
      adaptationReason: 'Raw callback default300000ms; inactive host requires explicit finite positive request timeout.' }),
    row('source-only-configured-timeout', { input: { timeoutMs: undefined }, config: { timeoutMs: 45000 }, hostComparable: false,
      adaptationReason: 'Raw source configuration timeout fallback; inactive host requires explicit request timeout.' }),
    row('source-only-configured-header', { config: { headers: { 'X-Ordinary': ' literal value ' } }, hostComparable: false,
      adaptationReason: 'Literal successful header/config facade; production secret/header/request policy unexecuted.' }),
    row('source-only-music-overlay', { config: { music: { promptNodeId: '6', promptInputName: 'caption', pollIntervalMs: 250 } }, hostComparable: false,
      adaptationReason: 'Original source music config overlay executes; inactive host receives already-selected configuration.' }),
    row('source-only-media-config-small', { mediaMaxMb: 1.25, hostComparable: false,
      adaptationReason: 'Source mediaMaxMb config observes ordinary audio cap without image64MiB floor; host takes explicit max_audio_bytes instead.' }),
    row('source-only-media-config-large', { mediaMaxMb: 80.25, hostComparable: false,
      adaptationReason: 'Source mediaMaxMb conversion uses floor(MB*value); host takes explicit max_audio_bytes. Tiny audio remains far below cap.' }),
  ]);
}

class ComfyHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, Blob, FormData,
      TextDecoder, URL, URLSearchParams,
      structuredClone: value => { const cloned = structuredClone(value);
        this.current.clonedWorkflow = cloned; return cloned; },
      performance: { now: () => this.current.now },
      process: { env: {} },
      __platform: { path,
        unused: () => { throw Error('Uninvoked boundary outside ordinary Comfy music callback'); },
        definePluginEntry: definition => { this.registrationCalls.push({ kind: 'definePluginEntry', id: definition.id }); return definition; },
        authMethod: () => ({ captureOnly: true }),
        randomInt: exclusiveMax => { this.current.randomCalls.push({ exclusiveMax, value: 42, implementation: 'deterministic-randomInt-facade' }); return 42; },
        secret: params => { this.current.secretCalls.push({ path: params.path, implementation: 'literal-secret-input-facade' });
          return typeof params.value === 'string' && params.value.trim() ? { status: 'available', value: params.value.trim() } : { status: 'missing' }; },
        configuredSecret: params => { this.current.headerCalls.push({ path: params.path, implementation: 'literal-configured-header-facade' }); return { value: params.value }; },
        config: (params, normalizedBase) => this.config(params, normalizedBase), fetch: params => this.fetch(params),
        status: (response, label, options) => { assert.equal(response.status, 200);
          this.current.statusCalls.push({ label, atMs: this.current.now, remainingMs: options.bodyTimeoutMs(), implementation: 'successful-status-facade' }); },
        read: (response, maxBytes, options) => this.read(response, maxBytes, options),
        sleep: async ms => { this.current.sleepCalls.push({ ms, atMs: this.current.now }); this.current.now += ms; },
        privateHost: () => false, origin: () => undefined, merge: () => undefined,
      }, fetch: () => { throw Error('Real network outside source oracle'); },
    }, { codeGeneration: { strings: false, wasm: false } });
    this.sourceRecords = new Map(); this.importBindings = new Map(); this.dynamicImports = [];
    this.registrationCalls = [];
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
        throw Error('Undeclared Comfy dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:comfy:' + key, code);
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
      const startByte = original.indexOf(startMarker); const endByte = endMarker === null ? original.length : original.indexOf(endMarker, startByte);
      assert.ok(startByte >= 0 && endByte > startByte, source);
      assert.equal(original.indexOf(startMarker, startByte + 1), -1, source + ' unique region');
      return { startByte, endByte, sourceRegionSha256: hash(original.subarray(startByte, endByte)) };
    });
    const generated = prelude + '\n' + regions.map(row => original.subarray(row.startByte, row.endByte).toString()).join('\n');
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source + ':' + regions[0].startByte, { path: source, sha256: hash(original), executed: true,
      wholeModule: false, projection: { justification: source === caps ? 'Heavy channel/routing/store imports are unrelated to generated audio cap; complete unchanged generated-media cap region selected.' : source === errors ? 'Heavy error/redaction imports are unrelated to successful reads; complete unchanged successful reader regions selected, lower body reader explicitly synthetic.' : 'Provider request-config module has unrelated auth/header dependencies; complete unchanged normalizeBaseUrl function selected.', regions, prelude, generatedCode: generated, generatedSha256: hash(generated) },
      transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-regions-projection', exports, executable,
      { source, sourceSha256: this.tracked.get(source) });
  }
  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:comfy:') && specifier.startsWith('capture:source:'))
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (parent.startsWith('capture:comfy:') && specifier === 'capture:base-url')
      return this.projection(parent, specifier, requestConfigSource,
        [['export function normalizeBaseUrl(baseUrl:', '// Header keys are compared case-insensitively']],
        '', ['normalizeBaseUrl']);
    if (parent.startsWith('capture:comfy:') && specifier === 'capture:readers')
      return this.projection(parent, specifier, errors, [
        ['const PROVIDER_RESPONSE_MAX_BYTES =', 'const SHORT_BEARER_TOKEN_PATTERN ='],
        ['function readProviderResponseBytes(', 'type ProviderHttpErrorOptions ='],
        ['export async function readProviderJsonResponse<T>(', 'export async function readProviderJsonObjectResponse('],
        ['// One HTTP media type,', null],
      ], `import {mediaKindFromMime} from 'capture:source:${constants}';\nconst readResponseWithLimit=globalThis.__platform.read;`,
      ['readProviderJsonResponse', 'readProviderBinaryResponse']);
    if (importer === entry && specifier === './workflow-runtime.js') return this.source(importer, specifier, runtime);
    if (importer === runtime && specifier === './workflow-http.js') return this.source(importer, specifier, http);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/plugin-entry')
      return this.binding(importer, specifier, 'registration-only-definePluginEntry-facade', ['definePluginEntry'],
        'export const definePluginEntry=globalThis.__platform.definePluginEntry;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth-api-key')
      return this.binding(importer, specifier, 'uninvoked-onboarding-descriptor-facade', ['createProviderApiKeyAuthMethod'],
        'export const createProviderApiKeyAuthMethod=globalThis.__platform.authMethod;');
    if ([runtime, http].includes(importer) && specifier === 'openclaw/plugin-sdk/number-runtime')
      return this.alias(importer, specifier, number, ['resolvePositiveTimerTimeoutMs']);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/blob-runtime')
      return this.alias(importer, specifier, blob, ['bufferToBlobPart']);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/media-mime')
      return this.alias(importer, specifier, mime, ['extensionForMime']);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/string-coerce-runtime')
      return this.binding(importer, specifier, 'whole-source-export-alias',
        ['asBoolean', 'isRecord', 'normalizeOptionalLowercaseString', 'normalizeOptionalString', 'uniqueStrings'],
        `export {asBoolean} from 'capture:source:${boolean}';export {isRecord} from 'capture:source:${records}';
export {normalizeOptionalLowercaseString,normalizeOptionalString} from 'capture:source:${strings}';
export {uniqueStrings} from 'capture:source:${lists}';`);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/media-generation-runtime')
      return this.projection(importer, specifier, caps, [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']],
        `import {maxBytesForKind} from 'capture:source:${constants}';`,
        ['resolveGeneratedMediaMaxBytes', 'resolveGeneratedImageDownloadMaxBytes']);
    if ([runtime, http].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http')
      return this.binding(importer, specifier, 'source-json-binary-readers-and-successful-status-config-facades',
        ['assertOkOrThrowHttpError', 'readProviderJsonResponse', 'readProviderBinaryResponse',
          'redactProviderResponseErrorText', 'resolveProviderHttpRequestConfig'],
        `import {normalizeBaseUrl} from 'capture:base-url';
export {readProviderJsonResponse,readProviderBinaryResponse} from 'capture:readers';
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const resolveProviderHttpRequestConfig=params=>globalThis.__platform.config(params,normalizeBaseUrl(params.baseUrl,params.defaultBaseUrl));
export const redactProviderResponseErrorText=globalThis.__platform.unused;`);
    if ([runtime, http].includes(importer) && specifier === 'openclaw/plugin-sdk/ssrf-runtime')
      return this.binding(importer, specifier, 'successful-unenforced-network-policy-and-no-network-fetch-facade',
        ['fetchWithSsrFGuard', 'isPrivateOrLoopbackHost', 'mergeSsrFPolicies', 'ssrfPolicyFromHttpBaseUrlAllowedOrigin'],
        `export const fetchWithSsrFGuard=globalThis.__platform.fetch;
export const isPrivateOrLoopbackHost=globalThis.__platform.privateHost;
export const mergeSsrFPolicies=globalThis.__platform.merge;
export const ssrfPolicyFromHttpBaseUrlAllowedOrigin=globalThis.__platform.origin;`);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/provider-auth')
      return this.binding(importer, specifier, 'uninvoked-availability-facade', ['isProviderApiKeyConfigured', 'isProviderApiKeyConfiguredAsync'],
        'export const isProviderApiKeyConfigured=globalThis.__platform.unused;export const isProviderApiKeyConfiguredAsync=globalThis.__platform.unused;');
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/provider-auth-runtime')
      return this.binding(importer, specifier, 'uninvoked-credential-discovery-facade', ['resolveApiKeyForProvider'],
        'export const resolveApiKeyForProvider=globalThis.__platform.unused;');
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/secret-input-runtime')
      return this.binding(importer, specifier, 'literal-explicit-credential-and-configured-header-facades',
        ['normalizeSecretInputString', 'resolveConfiguredSecretInputString', 'resolveSecretInputString'],
        `export {normalizeOptionalString as normalizeSecretInputString} from 'capture:source:${strings}';
export const resolveSecretInputString=globalThis.__platform.secret;
export const resolveConfiguredSecretInputString=globalThis.__platform.configuredSecret;`);
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/secret-ref-readonly')
      return this.binding(importer, specifier, 'uninvoked-secret-ref-facade', ['canResolveEnvSecretRefInReadOnlyPath'],
        'export const canResolveEnvSecretRefInReadOnlyPath=globalThis.__platform.unused;');
    if (importer === runtime && specifier === 'openclaw/plugin-sdk/text-utility-runtime')
      return this.binding(importer, specifier, 'synthetic-monotonic-sleep-and-uninvoked-path-facade', ['resolveUserPath', 'sleep'],
        'export const resolveUserPath=globalThis.__platform.unused;export const sleep=globalThis.__platform.sleep;');
    if (importer === runtime && specifier === 'node:crypto')
      return this.binding(importer, specifier, 'deterministic-source-only-randomInt-facade', ['randomInt'],
        'export const randomInt=globalThis.__platform.randomInt;');
    if (importer === runtime && specifier === 'node:fs/promises')
      return this.binding(importer, specifier, 'uninvoked-filesystem-facade', ['default'],
        'export default {readFile:globalThis.__platform.unused};');
    if ([mime, filenames].includes(importer) && specifier === 'node:path')
      return this.binding(importer, specifier, 'native-pure-node-path', ['default'],
        'export default globalThis.__platform.path;');
    const packages = { '@openclaw/media-core/base64': base64,
      '@openclaw/normalization-core/string-coerce': strings };
    if (packages[specifier] && wholeSources.includes(importer)) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared Comfy music import: ${importer} -> ${specifier}`);
  }
  register() {
    this.context.__api = {
      registerProvider: descriptor => this.registrationCalls.push({ kind: 'provider-descriptor-only', id: descriptor.id }),
      registerImageGenerationProvider: descriptor => this.registrationCalls.push({ kind: 'uninvoked-image-descriptor', id: descriptor.id }),
      registerMusicGenerationProvider: descriptor => { this.provider = descriptor;
        this.registrationCalls.push({ kind: 'music-callback-captured', id: descriptor.id }); },
      registerVideoGenerationProvider: descriptor => this.registrationCalls.push({ kind: 'uninvoked-video-descriptor', id: descriptor.id }),
    };
    new vm.Script('__exports.default.register(__api)').runInContext(this.context, { timeout: 1000 });
    this.context.__provider = this.provider;
    return this.call('(()=>{const {generateMusic,isConfigured,isConfiguredAsync,...descriptor}=__provider;return descriptor;})()');
  }
  config(params, normalizedBase) {
    const headers = new Headers(params.defaultHeaders);
    for (const [key, value] of params.headers) headers.set(key, value);
    const baseUrl = normalizedBase;
    const output = { baseUrl, allowPrivateNetwork: params.allowPrivateNetwork,
      headers: Object.fromEntries(headers), dispatcherPolicy: null };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability,
      transport: params.transport, baseUrl: params.baseUrl ?? null, defaultBaseUrl: params.defaultBaseUrl,
      defaultHeaders: plain(params.defaultHeaders), configuredHeaders: Object.fromEntries(params.headers),
      output, implementation: 'literal-successful-provider-http-config-facade' });
    this.current.now += 3;
    return { ...output, headers, dispatcherPolicy: undefined };
  }
  async fetch(params) {
    const state = this.current;
    state.preparedBeforeNetwork ??= plain(state.clonedWorkflow);
    assert.ok(state.requests.every(row => row.releaseCount === 1), 'release before next request');
    const url = new URL(params.url);
    const kind = url.pathname.endsWith('/upload/image') ? 'upload'
      : url.pathname.endsWith('/prompt') ? 'prompt' : url.pathname.endsWith('/status') ? 'status'
      : url.pathname.includes('/history') ? 'history' : 'download';
    const receipt = { kind, url: params.url, method: params.init?.method ?? 'GET',
      headers: Object.fromEntries(new Headers(params.init?.headers)), timeoutMs: params.timeoutMs,
      atMs: state.now, auditContext: params.auditContext, releaseCount: 0, bodyReadCount: 0 };
    if (kind === 'upload') {
      assert.ok(params.init.body instanceof FormData);
      receipt.fields = [];
      for (const [name, value] of params.init.body) receipt.fields.push(typeof value === 'string'
        ? { name, value } : { name, fileName: value.name, mimeType: value.type,
          bytesBase64: Buffer.from(await value.arrayBuffer()).toString('base64') });
    } else if (kind === 'prompt') {
      receipt.rawBody = params.init.body;
      receipt.jsonBody = JSON.parse(params.init.body);
    }
    let payload, response;
    if (kind === 'download') {
      payload = state.responsePlan.downloads[state.indices.download++]; assert.ok(payload);
      state.now += 5;
      response = new Response(Buffer.from(payload.bytesBase64, 'base64'), { status: 200,
        headers: payload.mimeType === undefined ? {} : { 'content-type': payload.mimeType } });
    } else {
      payload = kind === 'history' ? state.historyJson[state.indices.history++]
        : JSON.stringify(kind === 'status' ? state.responsePlan.statuses[state.indices.status++] : state.responsePlan[kind]);
      assert.equal(typeof payload, 'string'); receipt.responseJson = payload;
      state.now += 7;
      response = new Response(payload, { status: 200, headers: { 'content-type': 'application/json' } });
    }
    state.requests.push(receipt); state.responses.set(response, receipt);
    return { response, release: async () => { assert.equal(response.bodyUsed, true); assert.equal(receipt.bodyReadCount, 1); receipt.releaseCount += 1; receipt.releasedAtMs = state.now;
      state.releaseCalls.push({ kind, url: params.url, atMs: state.now, releaseCount: receipt.releaseCount }); } };
  }
  async read(response, maxBytes, options) {
    const state = this.current; const receipt = state.responses.get(response); assert.ok(receipt);
    const kind = receipt.kind === 'download' ? 'binary' : 'json';
    const remainingBeforeMs = options.timeoutMs();
    assert.equal(response.bodyUsed, false); receipt.bodyUsedBeforeRead = response.bodyUsed;
    const bytes = Buffer.from(await response.arrayBuffer()); receipt.bodyReadCount += 1;
    receipt.bodyUsedAfterRead = response.bodyUsed; assert.equal(response.bodyUsed, true);
    assert.ok(bytes.length <= maxBytes);
    state.now += kind === 'json' ? 3 : 2;
    state.readerCalls.push({ kind, requestKind: receipt.kind, atMs: receipt.atMs + (kind === 'json' ? 7 : 5),
      maxBytes, chunkTimeoutMs: options.chunkTimeoutMs, remainingBeforeMs, remainingAfterMs: options.timeoutMs(),
      hasOnOverflow: typeof options.onOverflow === 'function', hasOnIdleTimeout: typeof options.onIdleTimeout === 'function',
      bytesBase64: bytes.toString('base64'), implementation: 'successful-lower-body-reader-facade' });
    return bytes;
  }
  async run(vector) {
    this.current = { now: 100000, responsePlan: plain(vector.responsePlan),
      historyJson: vector.responsePlan.histories.map(value => JSON.stringify(value)),
      indices: { history: 0, status: 0, download: 0 }, responses: new Map(),
      requests: [], configCalls: [], secretCalls: [], headerCalls: [], statusCalls: [],
      readerCalls: [], releaseCalls: [], sleepCalls: [], randomCalls: [] };
    const input = plain(vector.input);
    if (input.inputImages) input.inputImages = input.inputImages.map(({ bytesBase64, ...image }) => {
      // A slice with unrelated prefix/suffix proves the original blob helper uses the exact byte range.
      const bytes = Buffer.from(bytesBase64, 'base64');
      const padded = Buffer.concat([Buffer.from('prefix'), bytes, Buffer.from('suffix')]);
      return { ...image, buffer: padded.subarray(6, 6 + bytes.length) };
    });
    const config = plain(vector.config);
    if (vector.id.startsWith('repeat-workflow-')) {
      this.repeatedWorkflow ??= config.workflow;
      config.workflow = this.repeatedWorkflow;
    }
    const cfg = { plugins: { entries: { comfy: { config } } },
      ...(vector.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.mediaMaxMb } } }) };
    const cfgBefore = plain(cfg);
    const req = { ...input, provider: 'comfy', cfg };
    this.context.__req = req;
    let timer;
    try {
      const pending = new vm.Script('__provider.generateMusic(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([pending, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Comfy fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.deepEqual(plain(cfg), cfgBefore);
      const { cfg: _cfg, provider: _provider, ...after } = req;
      if (after.inputImages) after.inputImages = after.inputImages.map(({ buffer, ...image }) => ({ ...image, bytesBase64: buffer.toString('base64') }));
      assert.deepEqual(plain(after), vector.input);
      assert.ok(this.current.requests.every(row => row.releaseCount === 1));
      const state = this.current;
      return plain({ ...vector, projectedConfig: cfgBefore, configAfter: cfg,
        inputAfter: after, preparedBeforeNetwork: state.preparedBeforeNetwork, preparedWorkflow: state.requests.find(row => row.kind === 'prompt').jsonBody.prompt,
        historyJson: state.historyJson, requests: state.requests,
        result: { ...result, tracks: result.tracks.map(({ buffer, ...track }) => ({ ...track, bytesBase64: buffer.toString('base64') })) },
        configCalls: state.configCalls, secretCalls: state.secretCalls, headerCalls: state.headerCalls,
        statusCalls: state.statusCalls, readerCalls: state.readerCalls, releaseCalls: state.releaseCalls,
        sleepCalls: state.sleepCalls, randomCalls: state.randomCalls,
        clock: { kind: 'synthetic-monotonic-performance.now', startMs: 100000, deadlineStartMs: 100003,
          endMs: state.now, serviceCostsMs: { config: 3, jsonFetch: 7, jsonRead: 3, download: 5, binaryRead: 2 } } });
    } finally { clearTimeout(timer); }
  }
}

export async function captureComfyMusicGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new ComfyHarness(root, before.tracked);
  await harness.load(entry); const providerDescriptor = harness.register();
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), source);
  for (const source of provenancePaths) {
    const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return plain({ schemaVersion: 1, referencePin: COMFY_MUSIC_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-comfy-music-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    registrationCalls: harness.registrationCalls, providerDescriptor,
    descriptorMethods: Object.keys(harness.provider).filter(key => typeof harness.provider[key] === 'function'),
    observationSeams: [{ name: 'structuredClone', implementation: 'native-primitive-with-reference-observation',
      limit: 'Calls native structuredClone and returns the same clone unchanged. Retains its reference only to snapshot original prompt/seed mutations at first fetch before upload response mutation; no callback or mutation logic rewritten.' }],
    serviceFacadeLedger: [
      { name: 'definePluginEntry/API shim', productionExecuted: false, limit: 'Named registration captures original music callback and descriptor; no native registry, activation, readiness, onboarding or other media callback executes.' },
      { name: 'resolveSecretInputString/resolveConfiguredSecretInputString', productionExecuted: false, limit: 'Only literal explicit synthetic key/header context. Credential discovery, secret refs and production auth policy unexecuted.' },
      { name: 'resolveProviderHttpRequestConfig', productionExecuted: false, limit: 'Original normalizeBaseUrl executes and feeds the successful literal config facade with native Headers. Production header/auth/dispatcher policy unexecuted.' },
      { name: 'fetchWithSsrFGuard/network-policy helpers', productionExecuted: false, limit: 'No-network call-recording facade, successful native Responses, release callbacks; no security, permission, DNS, TLS, proxy, redirect or private-policy proof.' },
      { name: 'assertOkOrThrowHttpError', productionExecuted: false, limit: 'Successful status facade; error/body-timeout diagnostics unexecuted.' },
      { name: 'readResponseWithLimit', productionExecuted: false, limit: 'Native Response.arrayBuffer successful tiny-body facade records original caps and remaining timeout options; production bounded stream, idle timer and enforcement unexecuted. No reader-equivalence claim.' },
      { name: 'sleep/performance.now', productionExecuted: false, limit: 'Deterministic monotonic clock advances by declared service/sleep costs inside finite budgets; no real timers or timeout/cancellation behavior tested.' },
      { name: 'randomInt', productionExecuted: false, limit: 'Returns 42 and records exclusive bound only on source-only seed rows; host ordinary RNG cannot match independent platform values.' },
    ],
    limits: [
      'Whole original 218-line registration, 752-line workflow-runtime and 55-line workflow-http execute unchanged after TypeScript erasure. Necessary normalization, MIME/extension/constants/blob/base64 modules execute whole; uncalled functions establish no behavior evidence.',
      'Original base-URL normalization, generated-media cap and JSON/binary reader regions execute, including 16MiB JSON cap, 16MiB default audio download cap without image64MiB floor, fatal UTF-8 JSON parsing and successful binary validation; lower reader is explicitly a facade.',
      'All 58,558 tracked blobs/modes/symlinks checked before and after. Source/projection/generated/executable/import/exporter/shared-harness/fixed-Node receipts are reconstructable.',
      'Comparable rows explicitly provide local/cloud mode, base, inline workflow/prompt binding, exact prompt and finite positive timeout; model omissions/blanks exercise original workflow default; cloud uses synthetic explicit key. Config/header/default/seed examples are source-only.',
      'Native Blob/FormData captures exact reference slice bytes, default PNG MIME, file/type/name and field order without unstable multipart boundary. All routes and successful release lifetimes are recorded; each synthetic native Response is consumed exactly once before release. This does not qualify production bounded reader enforcement or socket cleanup. Original history JSON is preserved without globally sorting keys.',
      'All-output examples have multiple homogeneous tiny audio assets: natural workflow results with integer-key, insertion-key and within-array ordering, unique output node metadata; no overflow or response-count policy claim.',
      'One monotonic budget covers network/body/sleep stages. Every acquired response releases exactly once before the next stage. Native structuredClone observation retains and returns the exact native clone, snapshots its original prompt/seed preparation at first fetch before upload mutation, and records submitted graph afterward. Repeated calls preserve original graph/input.',
      'One ordinary workflow selection fixture coexists audio with other media buckets and only audio is downloaded; no mixed-domain suites or nonaudio callback executes. No signal/cancellation/auth discovery/policy branch families, security/permission/TLS, negative/mixed/overflow, real-provider, failure/cancel/crash tests; no native activation, persistence/jobs/delivery or complete reference-goal claim.',
    ], observations });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2); assert.equal(args.indexOf('--out'), 1);
  assert.equal(args.length, 3); assert.ok(args[2], 'explicit --out path required');
  const result = await captureComfyMusicGeneration(args[0]);
  writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
