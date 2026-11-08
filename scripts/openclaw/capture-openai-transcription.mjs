// Whole pinned OpenAI transcription source with native multipart and synthetic successful HTTP.
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

export const OPENAI_TRANSCRIPTION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openai/audio-transcription.ts';
const generic = 'src/media-understanding/openai-compatible-audio.ts';
const shared = 'src/media-understanding/shared.ts';
const policy = 'src/agents/provider-request-config.ts';
const parser = 'src/agents/provider-http-errors.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const audioBase64 = 'UklGRigAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQQAAAAAANB/';
const wholeSources = [
  "extensions/openai/audio-transcription.ts",
  "src/media-understanding/openai-compatible-audio.ts",
  "src/media-understanding/shared.ts",
  "extensions/openai/base-url.ts",
  "extensions/openai/default-models.ts",
  "src/media-understanding/openai-audio-api.ts",
  "packages/media-understanding-common/src/openai-compatible-video.ts",
  "src/plugin-sdk/blob-runtime.ts",
  "packages/media-core/src/base64.ts",
  "packages/normalization-core/src/number-coercion.ts",
  "packages/normalization-core/src/string-coerce.ts",
  "packages/normalization-core/src/record-coerce.ts",
  "packages/normalization-core/src/utf16-slice.ts",
  "src/shared/text-truncate.ts",
  "src/agents/provider-http-errors.ts",
  "packages/media-core/src/constants.ts",
  "src/utils/boolean.ts",
  "src/agents/provider-request-config.ts",
  "src/secrets/provider-request-secret-fields.ts"
];
const provenancePaths = [
  "extensions/openai/media-understanding-provider.ts",
  "extensions/openai/index.ts",
  "extensions/openai/openclaw.plugin.json",
  "src/media-understanding/types.ts",
  "src/media-understanding/runner.entries.ts",
  "src/plugin-sdk/media-understanding.ts",
  "src/plugin-sdk/provider-auth.ts",
  "src/plugin-sdk/provider-auth-runtime.ts",
  "src/plugin-sdk/provider-http.ts",
  "src/plugin-sdk/provider-onboard.ts",
  "src/infra/net/fetch-guard.ts",
  "src/infra/net/proxy-env.ts",
  "src/infra/http-body.ts",
  "src/provider-runtime/operation-retry.ts",
  "src/utils/fetch-timeout.ts",
  "src/agents/provider-attribution.ts",
  "src/plugins/provider-auth-authority.ts",
  "src/config/types.secrets.ts",
  "src/agents/provider-request-header-redaction.ts",
  "src/logging/redact.ts",
  "src/infra/backoff.ts",
  "src/infra/retry-after.ts"
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENAI_TRANSCRIPTION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENAI_TRANSCRIPTION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: hash(bytes) };
  });
  return {
    tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: OPENAI_TRANSCRIPTION_PIN, tree: git(root, ['rev-parse', `${OPENAI_TRANSCRIPTION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}

function vectors() {
  const standard = { audioBase64, fileName: 'voice.wav', mime: 'audio/wav', timeoutMs: 12345 };
  const raw = [
    ['default-wav', {}],
    ['explicit-model', { model: ' gpt-4o-mini-transcribe ' }],
    ['language-prompt-unicode', { language: ' EN-us ', prompt: ' 名称 Ada 😀 ' }],
    ['blank-optional-fields', { language: ' \t ', prompt: ' \n ' }],
    ['filename-basename', { fileName: '  recordings/day/voice note.wav  ' }],
    ['aac-extension', { fileName: 'VOICE.AAC', mime: 'audio/aac' }],
    ['aac-extensionless', { fileName: 'voice', mime: 'Audio/AAC' }],
    ['mime-default', { mime: undefined }],
    ['custom-base', { baseUrl: ' https://transcription.example.test/v1/// ', model: ' Vendor/Model-X ' }],
    ['response-unicode', {}],
    ['silence', {}],
    ['ignored-query', { query: { response_format: 'text', temperature: 0, timestamp_granularities: ['word'] } }],
    ['buffer-subrange', { bufferView: { byteOffset: 7, byteLength: 48,
      backingBytesBase64: Buffer.concat([Buffer.alloc(7, 0x11), Buffer.from(audioBase64, 'base64'), Buffer.alloc(5, 0x22)]).toString('base64') } }],
    ['native-mime-case', { mime: 'Audio/WAV; Codecs=PCM' }],
    ['raw-json-bom', {}],
  ];
  return raw.map(([id, overrides]) => {
    const input = plain({ ...standard, ...overrides });
    const text = id === 'response-unicode' ? '\uFEFF\u00A0 A  e\u0301 😀\r\nZ \u00A0\uFEFF'
      : id === 'silence' ? ' \r\n\t\u00A0\uFEFF ' : id === 'raw-json-bom' ? ' JSON BOM transcript. ' : ' Plain transcript. ';
    const json = { text, model: 'server-selected' };
    const bodyText = (id === 'raw-json-bom' ? '\uFEFF' : '') + JSON.stringify(json);
    return { id, input, response: { bodyText, bodyBytesBase64: Buffer.from(bodyText).toString('base64'), json } };
  });
}

// Each rule is specific to its original importer and source export set.
const deferred = [
  [entry, 'openclaw/plugin-sdk/provider-auth', ['findNormalizedProviderValue', 'hasConfiguredSecretInput'], 'src/plugin-sdk/provider-auth.ts'],
  [entry, 'openclaw/plugin-sdk/provider-auth-runtime', ['collectProviderApiKeysForExecution', 'executeWithApiKeyRotation', 'isProviderAuthError', 'requireApiKey', 'resolveApiKeyForProvider'], 'src/plugin-sdk/provider-auth-runtime.ts'],
  [entry, 'openclaw/plugin-sdk/provider-http', ['providerOperationRetryConfig'], 'src/plugin-sdk/provider-http.ts'],
  ['extensions/openai/default-models.ts', 'openclaw/plugin-sdk/provider-onboard', ['applyAgentDefaultModelPrimary', 'ensureModelAllowlistEntry', 'resolveAgentModelPrimaryValue'], 'src/plugin-sdk/provider-onboard.ts'],
  [shared, '../infra/backoff.js', ['sleepWithAbort'], 'src/infra/backoff.ts'],
  [shared, '../provider-runtime/operation-retry.js', ['executeProviderOperationWithRetry', 'isTransientProviderHttpStatus'], 'src/provider-runtime/operation-retry.ts'],
  [shared, '../utils/fetch-timeout.js', ['fetchWithTimeout'], 'src/utils/fetch-timeout.ts'],
  [parser, '../infra/retry-after.js', ['parseRetryAfterHeaderSeconds'], 'src/infra/retry-after.ts'],
  [parser, '../logging/redact.js', ['redactSensitiveText', 'redactToolPayloadText'], 'src/logging/redact.ts'],
  [parser, './provider-request-header-redaction.js', ['collectRequestHeaderSecretValues', 'createExactSecretValueMatcher', 'redactExactSecretValues', 'redactProviderResponseErrorText'], 'src/agents/provider-request-header-redaction.ts'],
  [policy, '../config/types.secrets.js', ['assertSecretInputResolved'], 'src/config/types.secrets.ts'],
  [policy, '../plugins/provider-auth-authority.js', ['attachProviderAuthAuthority', 'getProviderAuthAuthority'], 'src/plugins/provider-auth-authority.ts'],
  [policy, './provider-attribution.js', ['resolveProviderRequestCapabilities'], 'src/agents/provider-attribution.ts'],
];

class TranscriptionHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, FormData, Blob, File, Headers, Response, TextDecoder, URL,
      __platform: { path, fetchWithSsrFGuard: params => this.fetch(params),
        readResponseWithLimit: async (response, maxBytes, options) => {
          this.current.readerCalls.push({ maxBytes, chunkTimeoutMs: options.chunkTimeoutMs });
          return Buffer.from(await response.arrayBuffer());
        } } }, { codeGeneration: { strings: false, wasm: false } });
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
    return this.synthetic('capture:transcription:' + key, code);
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

  unused(importer, specifier, exports, source) {
    return this.binding(importer, specifier, 'uninvoked-dependency-facade', exports,
      exports.map(name => `export function ${name}(){globalThis.__deferredCalls.push(${JSON.stringify({ importer, specifier, export: name })});throw Error('Uninvoked transcription dependency: ${name}');}`).join('\n'),
      { source, sourceSha256: this.tracked.get(source), originalSourceExecuted: false });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:transcription:') && specifier.startsWith('capture:source:')) {
      return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    }
    if (importer === entry && specifier === 'openclaw/plugin-sdk/media-understanding') {
      return this.alias(importer, specifier, generic, ['transcribeOpenAiCompatibleAudio'], 'src/plugin-sdk/media-understanding.ts');
    }
    if (importer === 'extensions/openai/base-url.ts' && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return this.alias(importer, specifier, 'packages/normalization-core/src/string-coerce.ts', ['normalizeOptionalString']);
    }
    const rule = deferred.find(([owner, name]) => owner === importer && name === specifier);
    if (rule) return this.unused(importer, specifier, rule[2], rule[3]);
    if (importer === shared && specifier === 'node:path') {
      return this.binding(importer, specifier, 'actual-platform-builtin', ['default'],
        'export default globalThis.__platform.path;', { platform: 'node:path (Linux POSIX)' });
    }
    if (importer === shared && specifier === '../agents/provider-request-config.js') {
      return this.binding(importer, specifier, 'successful-policy-fixture',
        ['normalizeBaseUrl', 'resolveProviderRequestPolicyConfig', 'buildProviderRequestDispatcherPolicy', 'sanitizeConfiguredModelProviderRequest'], `
import {normalizeBaseUrl} from ${JSON.stringify('capture:source:' + policy)};
export {normalizeBaseUrl};
export function resolveProviderRequestPolicyConfig(params){return {baseUrl:normalizeBaseUrl(params.baseUrl,params.defaultBaseUrl),headers:{},allowPrivateNetwork:false,trustConfiguredBaseUrlOrigin:false};}
export function buildProviderRequestDispatcherPolicy(){return undefined;}
export function sanitizeConfiguredModelProviderRequest(){globalThis.__deferredCalls.push({kind:'uninvoked-config-sanitization'});throw Error('Uninvoked configuration sanitization');}
`, { source: policy, sourceSha256: this.tracked.get(policy),
          boundary: 'Only actual whole-source normalizeBaseUrl executes; headers/transport policy are explicit fixture values.' });
    }
    if (importer === shared && specifier === '../infra/net/fetch-guard.js') {
      const source = 'src/infra/net/fetch-guard.ts';
      const original = readFileSync(join(this.root, source), 'utf8');
      const selected = /^export const GUARDED_FETCH_MODE = \{\n([\s\S]*?)\n\} as const;/m.exec(original);
      assert.ok(selected, 'source-owned fetch mode constants');
      const constant = stripTypeScriptTypes(selected[0], { mode: 'transform', sourceMap: false });
      return this.binding(importer, specifier, 'successful-native-response-fixture', ['fetchWithSsrFGuard', 'GUARDED_FETCH_MODE'],
        constant + '\nexport const fetchWithSsrFGuard=globalThis.__platform.fetchWithSsrFGuard;',
        { source, sourceSha256: this.tracked.get(source), selectedConstantSha256: hash(selected[0]), originalSourceExecuted: false });
    }
    if (importer === shared && specifier === '../infra/net/proxy-env.js') {
      return this.binding(importer, specifier, 'explicit-environment-fixture', ['shouldUseEnvHttpProxyForUrl'],
        'export function shouldUseEnvHttpProxyForUrl(){return false;}',
        { source: 'src/infra/net/proxy-env.ts', sourceSha256: this.tracked.get('src/infra/net/proxy-env.ts'), originalSourceExecuted: false });
    }
    if (importer === parser && specifier === '../infra/http-body.js') {
      return this.binding(importer, specifier, 'successful-body-reader-fixture', ['readResponseWithLimit', 'readResponseTextPrefix'], `
export const readResponseWithLimit=globalThis.__platform.readResponseWithLimit;
export function readResponseTextPrefix(){globalThis.__deferredCalls.push({kind:'uninvoked-text-prefix-reader'});throw Error('Uninvoked text prefix reader');}
`, { source: 'src/infra/http-body.ts', sourceSha256: this.tracked.get('src/infra/http-body.ts'), originalSourceExecuted: false });
    }
    const packages = {
      '@openclaw/normalization-core/number-coercion': 'packages/normalization-core/src/number-coercion.ts',
      '@openclaw/normalization-core/string-coerce': 'packages/normalization-core/src/string-coerce.ts',
      '@openclaw/normalization-core/record-coerce': 'packages/normalization-core/src/record-coerce.ts',
      '@openclaw/normalization-core/utf16-slice': 'packages/normalization-core/src/utf16-slice.ts',
      '@openclaw/media-core/base64': 'packages/media-core/src/base64.ts',
      '@openclaw/media-core/constants': 'packages/media-core/src/constants.ts',
    };
    if (packages[specifier]) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared transcription import: ${importer} -> ${specifier}`);
  }

  async fetch(params) {
    const form = params.init.body;
    assert.ok(form instanceof FormData, 'actual native FormData');
    const fields = {};
    let file;
    const fieldOrder = [];
    for (const [name, value] of form.entries()) {
      fieldOrder.push(name);
      if (typeof value === 'string') fields[name] = value;
      else {
        assert.ok(value instanceof File, 'actual native multipart File');
        const serialized = Buffer.from(await new Response(form).arrayBuffer()).toString('latin1');
        const headers = serialized.split('\r\n\r\n').find(part => part.includes('name="file"'));
        const mime = /Content-Type: ([^\r\n]+)/i.exec(headers)?.[1];
        assert.equal(typeof mime, 'string', 'native multipart part MIME');
        file = { name: value.name, blobType: value.type, effectivePartMime: mime,
          size: value.size, bytesBase64: Buffer.from(await value.arrayBuffer()).toString('base64') };
      }
    }
    this.current.requests.push({ url: params.url, method: params.init.method, timeoutMs: params.timeoutMs,
      fieldOrder, fields, file });
    const response = await params.fetchImpl(params.url, params.init);
    return { response, release: async () => { this.current.releaseCount += 1; } };
  }

  async run(vector) {
    const current = { ...plain(vector), requests: [], releaseCount: 0, readerCalls: [] };
    this.current = current;
    const input = plain(vector.input);
    const bytes = Buffer.from(input.audioBase64, 'base64');
    const backing = input.bufferView ? Buffer.alloc(Buffer.from(input.bufferView.backingBytesBase64, 'base64').length) : Buffer.alloc(bytes.length);
    backing.set(input.bufferView ? Buffer.from(input.bufferView.backingBytesBase64, 'base64') : bytes);
    const buffer = input.bufferView ? backing.subarray(input.bufferView.byteOffset, input.bufferView.byteOffset + input.bufferView.byteLength) : backing;
    const before = Buffer.from(backing);
    const { audioBase64: _audio, bufferView: _view, ...params } = input;
    this.context.__input = { ...params, buffer, apiKey: 'fixture-openai-transcription',
      fetchFn: async () => new Response(Buffer.from(vector.response.bodyBytesBase64, 'base64'),
        { status: 200, headers: { 'content-type': 'application/json' } }) };
    let timer;
    try {
      const promise = new vm.Script('__exports.transcribeOpenAiAudio(__input)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Transcription fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.equal(current.requests.length, 1, vector.id);
      assert.equal(current.releaseCount, 1, vector.id);
      assert.deepEqual(backing, before, 'source leaves selected bytes and backing range unchanged');
      const { buffer: afterBuffer, apiKey: _key, fetchFn: _fetch, ...afterParams } = this.context.__input;
      assert.deepEqual(afterBuffer, buffer);
      const inputAfter = { audioBase64: afterBuffer.toString('base64'), ...plain(afterParams),
        ...(input.bufferView ? { bufferView: { ...input.bufferView, backingBytesBase64: backing.toString('base64') } } : {}) };
      return { id: vector.id, input: vector.input, inputAfter, request: current.requests[0],
        response: vector.response, result: plain(result), releaseCount: current.releaseCount, readerCalls: current.readerCalls };
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenAITranscription(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1', 'supported fixed Node runtime');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  const harness = new TranscriptionHarness(root, before.tracked);
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
  const deferredCalls = plain(harness.context.__deferredCalls);
  assert.deepEqual(deferredCalls, []);
  assert.deepEqual(plain(harness.context.__captureAudit), []);
  return {
    schemaVersion: 1, referencePin: OPENAI_TRANSCRIPTION_PIN,
    exporter: { path: 'scripts/openclaw/capture-openai-transcription.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt },
    transformation: transform, sourceRecords, importBindings: [...harness.importBindings.values()], deferredCalls,
    limits: [
      'Complete unchanged wrapper, generic, shared, native FormData/Blob/File, buffer-range helper, actual base normalizer and actual JSON decoder/object wrapper execute. No copied function bodies.',
      'All 58,558 tracked reference blobs are verified before/after. Exact source, transformed executable, exporter, shared harness, runtime and per-importer generated facade hashes are recorded.',
      'Only synthetic successful HTTP Response fixtures execute; no real provider, socket, transcription quality, account/context/auth selection, proxy discovery or production policy implementation claim.',
      'Transport and headers are explicit successful policy fixture values. The actual pure normalizeBaseUrl executes from its unchanged complete module; other functions in that module remain uninvoked.',
      'The production bounded stream reader is unexecuted: a native Response.arrayBuffer fixture records the actual parser default 16 MiB response cap and 30,000 ms chunk timeout; no chunk, overflow or timeout behavior is tested.',
      'The generic adapter has no input audio byte cap; response 16 MiB is not an upload cap. Ingress/preflight/runner/channel attachment processing is unexecuted.',
      'The typed query map is ignored by actual generic source; no response_format/text mode, temperature, timestamps or query serialization is claimed.',
      'Actual native multipart serialization supplies effective file MIME; random boundaries and File.lastModified are excluded from deterministic evidence. Linux node:path filename semantics only; no codec conversion.',
      'Provider/plugin registration, full runtime assembly, selected model consumption, Synapsis integration and whole P10 completion are separate claims.',
    ], observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-openai-transcription.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureOpenAITranscription(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed).length,
    provenanceOnly: result.sourceRecords.filter(row => !row.executed).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
