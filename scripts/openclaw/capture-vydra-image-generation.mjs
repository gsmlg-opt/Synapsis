// Whole pinned Vydra image callback and shared implementation; successful synthetic I/O only.
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

export const VYDRA_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/vydra/index.ts', vydraShared = 'extensions/vydra/shared.ts';
const defaults = 'extensions/vydra/defaults.ts', catalog = 'extensions/vydra/capability-catalog.ts';
const number = 'packages/normalization-core/src/number-coercion.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const constants = 'packages/media-core/src/constants.ts', mime = 'packages/media-core/src/mime.ts';
const caps = 'src/media/configured-max-bytes.ts', shared = 'src/media-understanding/shared.ts';
const errors = 'src/agents/provider-http-errors.ts', jsonPost = 'src/media-understanding/provider-json-post.ts';
const wholeSources = [entry, vydraShared, defaults, catalog, number, strings, records, constants, jsonPost];
const provenancePaths = ['extensions/vydra/openclaw.plugin.json', 'extensions/vydra/package.json',
  'extensions/vydra/onboard.ts', 'extensions/vydra/speech-provider.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/media-generation-runtime.ts',
  'src/plugin-sdk/number-runtime.ts', 'src/plugin-sdk/media-mime.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'src/plugin-sdk/provider-auth-runtime.ts', 'src/plugin-sdk/provider-auth.ts',
  'src/plugin-sdk/provider-auth-api-key.ts', 'src/plugin-sdk/plugin-entry.ts',
  'src/agents/provider-request-config.ts', 'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts',
  'src/provider-runtime/operation-retry.ts', 'src/infra/http-body.ts',
  'src/image-generation/runtime.ts', 'src/media-generation/runtime-shared.ts'];
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000,
    maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), VYDRA_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', VYDRA_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t'), [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source), stat = lstatSync(file), symlink = stat.isSymbolicLink();
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', source + ' mode');
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, mode, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])), receipt: {
    verified: true, commit: VYDRA_IMAGE_GENERATION_PIN, tree: git(root, ['rev-parse', `${VYDRA_IMAGE_GENERATION_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

// Complete tiny fixture payloads, not codec/visual-quality evidence.
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const jpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3E//Z';
const webp = 'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AA/vuUAAA=';
const prompt = '  draw a cat\n猫 🌕  ', base = 'https://vydra.example.test/api/v1';
const A = 'https://vydra.example.test/images/a.png', B = 'https://vydra.example.test/images/b.png', C = 'https://vydra.example.test/images/c.png';
function vectors() {
  const row = (id, input = {}, extra = {}) => ({ id, hostComparable: extra.hostComparable ?? true,
    ...(extra.adaptationReason ? { adaptationReason: extra.adaptationReason } : {}),
    input: { prompt, model: 'grok-imagine', timeoutMs: 30000, ...input },
    config: { baseUrl: base, ...extra.config },
    ...(extra.mediaMaxMb === undefined ? {} : { mediaMaxMb: extra.mediaMaxMb }),
    response: { submitted: { jobId: 'job-1', status: 'completed', imageUrl: A }, polls: [],
      asset: { bytesBase64: png, mimeType: 'image/png' }, ...extra.response },
    ...(extra.services ? { services: extra.services } : {}) });
  const rows = [row('minimal'), row('count-one-empty-inputs', { count: 1, inputImages: [] }),
    row('trimmed-model', { model: '  grok-imagine  ' }), row('fractional-timeout', { timeoutMs: 30000.9 }),
    row('base-custom-path', {}, { config: { baseUrl: ' https://vydra.example.test/custom/// ' } }),
    row('base-root-path', {}, { config: { baseUrl: 'https://vydra.example.test/' } }),
    row('url-only', {}, { response: { submitted: { imageUrl: A } } }),
    row('trimmed-metadata', {}, { response: { submitted: { id: ' id-1 ', status: ' Completed ', imageUrl: ' ' + A + ' ' } } }),
    row('job-id-priority', {}, { response: { submitted: { jobId: ' primary ', id: 'secondary', status: 'completed', imageUrl: A } } }),
    row('poll-immediate', {}, { response: { submitted: { jobId: 'job-1', status: 'queued' }, polls: [{ status: 'completed', imageUrl: A }] } }),
    row('poll-processing-completed', {}, { response: { submitted: { jobId: 'job-1', status: 'queued' },
      polls: [{ status: 'processing' }, { id: ' finished-1 ', status: ' Completed ', imageUrl: A }] } }),
    row('poll-url-completes-processing', {}, { response: { submitted: { id: ' job-1 ', status: 'queued' }, polls: [{ status: 'processing', imageUrl: A }] } }),
    row('queued-url-completes', {}, { response: { submitted: { jobId: 'job-1', status: 'queued', imageUrl: A } } })];
  for (const key of ['imageUrl', 'imageUrls', 'resultUrl', 'resultUrls', 'outputUrl', 'outputUrls', 'url', 'urls'])
    rows.push(row('url-key-' + key, {}, { response: { submitted: { [key]: key.endsWith('s') ? [A] : A } } }));
  for (const key of ['output', 'outputs', 'result', 'results', 'data', 'asset', 'assets'])
    rows.push(row('recurse-key-' + key, {}, { response: { submitted: { [key]: { imageUrl: A } } } }));
  rows.push(row('ordered-fixed-keys', {}, { response: { submitted: { url: C, resultUrl: B, imageUrl: A } } }),
    row('ordered-nested-url-arrays', {}, { response: { submitted: { imageUrls: [[A, B], [' ' + A + ' ', C]] } } }),
    row('ordered-root-before-recursion', {}, { response: { submitted: { output: { imageUrl: B }, imageUrl: A } } }),
    row('ordered-recursion-keys', {}, { response: { submitted: { data: { imageUrl: B }, output: { imageUrl: A } } } }),
    row('depth-five', {}, { response: { submitted: { output: [{ result: { data: { assets: { imageUrl: A } } } }] } } }),
    row('split-png-body', {}, { response: { asset: { bytesBase64: png, mimeType: 'image/png', chunkSizes: [7, 13] } } }),
    row('jpeg-body', {}, { response: { asset: { bytesBase64: jpeg, mimeType: 'image/jpeg' } } }),
    row('webp-body', {}, { response: { asset: { bytesBase64: webp, mimeType: 'image/webp' } } }),
    row('raw-parameterized-mime', {}, { response: { asset: { bytesBase64: png, mimeType: ' Image/PNG; charset=binary ' } } }),
    row('default-png-mime', {}, { response: { asset: { bytesBase64: png, mimeType: null } } }),
    row('small-configured-cap', {}, { mediaMaxMb: 1 }), row('larger-configured-cap', {}, { mediaMaxMb: 80.25 }),
    row('ignored-ordinary-options', { size: '1024x1024', aspectRatio: '1:1', resolution: '1K', quality: 'high',
      outputFormat: 'png', background: 'opaque', providerOptions: { vydra: { ordinary: true } } }),
    row('source-only-omitted-model', { model: undefined }, { hostComparable: false, adaptationReason: 'Original callback default; host requires explicit model.' }),
    row('source-only-omitted-timeout', { timeoutMs: undefined }, { hostComparable: false, adaptationReason: 'Original distinct submission/poll/download defaults; host requires explicit finite timeout.',
      response: { submitted: { jobId: 'job-1', status: 'queued' }, polls: [{ status: 'processing' }, { status: 'completed', imageUrl: A }] } }),
    row('source-only-omitted-base', {}, { hostComparable: false, adaptationReason: 'Original default config base; successful synthetic transport only.', config: { baseUrl: undefined },
      response: { submitted: { imageUrl: 'https://www.vydra.ai/images/a.png' } } }),
    row('source-only-canonical-base', {}, { hostComparable: false, adaptationReason: 'Original vydra.ai hostname normalization; successful synthetic transport only.',
      config: { baseUrl: ' https://vydra.ai/api/v1/// ' }, response: { submitted: { imageUrl: 'https://www.vydra.ai/images/a.png' } } }),
    row('source-only-configured-header', {}, { hostComparable: false, adaptationReason: 'Literal successful configured-request/header facade; production policy normalization unexecuted.',
      config: { request: { headers: { 'X-Ordinary-Trace': ' fixture ' } } },
      services: { sanitizedRequest: { headers: { 'X-Ordinary-Trace': 'fixture' } }, headers: { 'x-ordinary-trace': 'fixture' } } }));
  return plain(rows);
}

class VydraHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, ReadableStream, TextDecoder, URL,
      fetch: () => { throw Error('Real network outside source oracle'); },
      __platform: { now: () => this.current.now,
        unused: () => { throw Error('Uninvoked boundary outside ordinary image callback'); },
        config: params => this.config(params), sanitize: request => this.sanitize(request),
        guarded: (...args) => this.guarded(...args), status: (response, label) => this.status(response, label),
        read: (...args) => this.read(...args), wait: ms => this.wait(ms),
        retry: params => { this.current.retryCalls.push({ stage: params.stage, implementation: 'successful-first-execution-retry-facade' }); return params.operation(); } } },
      { codeGeneration: { strings: false, wasm: false } });
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
      importModuleDynamically: specifier => { this.dynamicImports.push({ importer: source, specifier }); throw Error('Undeclared Vydra dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:vydra:' + key, code);
  }
  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module', source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }
  alias(importer, specifier, source, exports) {
    return this.binding(importer, specifier, 'whole-source-export-alias', exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:' + source)};`, { source, sourceSha256: this.tracked.get(source) });
  }
  projection(importer, specifier, source, selections, prelude, exports) {
    const original = readFileSync(join(this.root, source)); assert.equal(hash(original), this.tracked.get(source));
    const regions = selections.map(([startMarker, endMarker]) => {
      const startByte = original.indexOf(startMarker), endByte = endMarker === null ? original.length : original.indexOf(endMarker, startByte);
      assert.ok(startByte >= 0 && endByte > startByte, source); assert.equal(original.indexOf(startMarker, startByte + 1), -1, source + ' unique region');
      return { startByte, endByte, sourceRegionSha256: hash(original.subarray(startByte, endByte)) };
    });
    const generated = prelude + '\n' + regions.map(row => original.subarray(row.startByte, row.endByte).toString()).join('\n');
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source + ':' + regions[0].startByte, { path: source, sha256: hash(original), executed: true, wholeModule: false,
      projection: { regions, prelude, generatedCode: generated, generatedSha256: hash(generated) }, transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-regions-projection', exports, executable, { source, sourceSha256: this.tracked.get(source) });
  }
  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:vydra:') && specifier.startsWith('capture:source:')) return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    if (specifier === 'capture:operations') return this.projection(parent, specifier, shared,
      [['export function createProviderOperationDeadline(', 'export async function fetchProviderOperationResponse('],
        ['function resolveGuardedRequestOptions(', '// Keep the shipped transcription name']],
      `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from 'capture:source:${number}';
import {readProviderJsonObjectResponse} from 'capture:readers';
const DEFAULT_GUARDED_HTTP_TIMEOUT_MS=60000;
const sleepWithAbort=globalThis.__platform.wait;
const fetchWithTimeoutGuarded=globalThis.__platform.guarded;
const assertOkOrThrowHttpError=globalThis.__platform.status;
const fetchWithTimeout=globalThis.__platform.unused;
const createProviderHttpError=globalThis.__platform.unused;
const isTransientProviderHttpStatus=globalThis.__platform.unused;
const executeProviderOperationWithRetry=globalThis.__platform.retry;`,
      ['createProviderOperationDeadline', 'createProviderOperationTimeoutError', 'resolveProviderOperationTimeoutMs',
        'createProviderOperationTimeoutResolver', 'pollProviderOperationJson', 'postJsonRequest', 'postMultipartRequest']);
    if (specifier === 'capture:readers') return this.projection(parent, specifier, errors,
      [['const PROVIDER_RESPONSE_MAX_BYTES =', 'const SHORT_BEARER_TOKEN_PATTERN ='],
        ['function readProviderResponseBytes(', 'type ProviderHttpErrorOptions ='],
        ['export async function readProviderJsonResponse<T>(', 'export async function readProviderJsonArrayFieldResponse('],
        ['// One HTTP media type,', null]],
      `import {asOptionalRecord} from 'capture:source:${records}';
import {mediaKindFromMime} from 'capture:source:${constants}';
const readResponseWithLimit=globalThis.__platform.read;`,
      ['readProviderJsonResponse', 'readProviderJsonObjectResponse', 'readProviderBinaryResponse']);
    if (importer === jsonPost && specifier === './shared.js') return this.binding(importer, specifier, 'source-post-wrapper-alias', ['postJsonRequest'], "export {postJsonRequest} from 'capture:operations';");
    if (importer === jsonPost && specifier === '../agents/provider-http-errors.js') return this.binding(importer, specifier, 'source-json-readers-successful-status-facade', ['assertOkOrThrowHttpError', 'readProviderJsonResponse', 'readProviderJsonObjectResponse'],
      "export {readProviderJsonResponse,readProviderJsonObjectResponse} from 'capture:readers'; export const assertOkOrThrowHttpError=globalThis.__platform.status;");
    if (importer === vydraShared && specifier === 'openclaw/plugin-sdk/provider-http') return this.binding(importer, specifier, 'source-post-poll-deadline-readers-and-successful-config-guard-status-facades',
      ['assertOkOrThrowHttpError', 'createProviderOperationDeadline', 'createProviderOperationTimeoutError', 'createProviderOperationTimeoutResolver', 'fetchWithTimeoutGuarded', 'pollProviderOperationJson', 'postJsonResponse', 'readProviderBinaryResponse', 'resolveProviderApiKeyHttpRequestConfig', 'resolveProviderHttpRequestConfig', 'resolveProviderOperationTimeoutMs', 'sanitizeConfiguredModelProviderRequest'],
      `export {createProviderOperationDeadline,createProviderOperationTimeoutError,createProviderOperationTimeoutResolver,pollProviderOperationJson,resolveProviderOperationTimeoutMs} from 'capture:operations';
export {postJsonResponse} from 'capture:source:${jsonPost}';
export {readProviderBinaryResponse} from 'capture:readers';
export const assertOkOrThrowHttpError=globalThis.__platform.status;
export const fetchWithTimeoutGuarded=globalThis.__platform.guarded;
export const resolveProviderApiKeyHttpRequestConfig=globalThis.__platform.config;
export const resolveProviderHttpRequestConfig=globalThis.__platform.unused;
export const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;`);
    if (importer === vydraShared && specifier === 'openclaw/plugin-sdk/media-generation-runtime') return this.projection(importer, specifier, caps,
      [['const MB = 1024 * 1024;', '/** Reads channel/account media caps']], `import {maxBytesForKind} from 'capture:source:${constants}';`,
      ['resolveGeneratedImageDownloadMaxBytes', 'resolveGeneratedMediaMaxBytes']);
    if (importer === vydraShared && specifier === 'openclaw/plugin-sdk/media-mime') return this.projection(importer, specifier, mime,
      [['const EXT_BY_MIME:', 'function buildMimeByExt('], ['const MIME_SYNONYMS:', '/** Returns the bounded buffer prefix'],
        ['export function extensionForMime(', 'export function isGifMedia(']], '', ['extensionForMime']);
    if (importer === vydraShared && specifier === 'openclaw/plugin-sdk/number-runtime') return this.alias(importer, specifier, number, ['resolvePositiveTimerTimeoutMs']);
    if ([vydraShared, defaults].includes(importer) && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return this.binding(importer, specifier, 'whole-source-export-alias', ['asOptionalRecord', 'normalizeOptionalString', 'normalizeOptionalLowercaseString'],
      `export {asOptionalRecord} from 'capture:source:${records}'; export {normalizeOptionalString,normalizeOptionalLowercaseString} from 'capture:source:${strings}';`);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/plugin-entry') return this.binding(importer, specifier, 'successful-registration-facade', ['definePluginEntry'], 'export const definePluginEntry=entry=>entry;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth') return this.binding(importer, specifier, 'uninvoked-configured-check-facade', ['isProviderApiKeyConfiguredAsync'], 'export const isProviderApiKeyConfiguredAsync=globalThis.__platform.unused;');
    if (importer === entry && specifier === 'openclaw/plugin-sdk/provider-auth-api-key') return this.binding(importer, specifier, 'uninvoked-auth-method-descriptor-facade', ['createProviderApiKeyAuthMethod'], 'export const createProviderApiKeyAuthMethod=params=>params;');
    if (importer === entry && specifier === './onboard.js') return this.binding(importer, specifier, 'uninvoked-onboarding-facade', ['applyVydraConfig'], 'export const applyVydraConfig=globalThis.__platform.unused;');
    if ([entry, catalog].includes(importer) && specifier === './speech-provider.js') return this.binding(importer, specifier, 'uninvoked-speech-callback-descriptor-facade', ['buildVydraSpeechProvider'], "export const buildVydraSpeechProvider=()=>({id:'vydra',facade:true});");
    if (specifier.startsWith('.') && wholeSources.includes(importer)) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared Vydra image import: ${importer} -> ${specifier}`);
  }
  sanitize(input) {
    const output = this.current.services.sanitizedRequest;
    this.current.sanitizeCalls.push({ input: input ?? null, output: output ?? null, implementation: 'successful-configured-request-sanitizer-facade' });
    return output;
  }
  config(params) {
    const atMs = this.current.now; this.current.now += 2;
    this.current.keyCalls.push({ provider: params.provider, atMs, implementation: 'successful-explicit-synthetic-credential-facade' });
    this.current.now += 3;
    const headers = new Headers({ authorization: 'Bearer synthetic-explicit-key', 'content-type': 'application/json', ...this.current.services.headers });
    const output = { baseUrl: params.baseUrl, headers: Object.fromEntries(headers), allowPrivateNetwork: false };
    this.current.configCalls.push({ provider: params.provider, capability: params.capability, baseUrl: params.baseUrl,
      defaultBaseUrl: params.defaultBaseUrl, request: params.request ?? null, output, atMs: atMs + 2,
      implementation: 'successful-provider-api-key-http-config-policy-facade' });
    return { ...output, headers };
  }
  async guarded(url, init, timeoutMs, fetchFn, options) {
    assert.equal(fetchFn, this.context.fetch);
    const kind = init.method === 'POST' ? 'post' : options?.auditContext === 'vydra-job-status' ? 'poll' : 'download';
    const receipt = { kind, url, method: init.method, headers: Object.fromEntries(new Headers(init.headers)),
      timeoutMs: timeoutMs ?? 60000, atMs: this.current.now, auditContext: options?.auditContext ?? null, releaseCount: 0 };
    this.current.requests.push(receipt); this.current.events.push({ kind: 'request', stage: kind, url, atMs: this.current.now });
    let bytes, headers;
    if (kind === 'post') { receipt.rawBody = init.body; receipt.body = JSON.parse(init.body); this.current.now += 7;
      bytes = Buffer.from(JSON.stringify(this.current.response.submitted)); headers = { 'content-type': 'application/json' }; }
    else if (kind === 'poll') { const payload = this.current.response.polls[this.current.pollIndex++]; assert.ok(payload);
      this.current.now += 4; bytes = Buffer.from(JSON.stringify(payload)); headers = { 'content-type': 'application/json' }; }
    else { assert.equal(this.current.requests.filter(row => row.kind === 'download').length, 1);
      this.current.now += 5; const asset = this.current.response.asset; bytes = Buffer.from(asset.bytesBase64, 'base64');
      headers = asset.mimeType === null ? {} : { 'content-type': asset.mimeType }; }
    const chunks = []; let cursor = 0;
    for (const size of (kind === 'download' ? this.current.response.asset.chunkSizes ?? [] : [])) { chunks.push(bytes.subarray(cursor, cursor + size)); cursor += size; }
    if (cursor < bytes.length) chunks.push(bytes.subarray(cursor));
    const response = new Response(new ReadableStream({ start(controller) { for (const chunk of chunks) controller.enqueue(chunk); controller.close(); } }), { status: 200, headers });
    this.current.responses.set(response, { receipt, chunks: chunks.map(row => row.length) });
    return { response, release: async () => { receipt.releaseCount++; receipt.releasedAtMs = this.current.now;
      this.current.events.push({ kind: 'release', stage: kind, url, atMs: this.current.now }); } };
  }
  status(response, label) { assert.equal(response.status, 200); this.current.statusCalls.push({ label, status: 200, atMs: this.current.now, implementation: 'successful-status-facade' }); }
  async read(response, maxBytes, options) {
    const { receipt, chunks } = this.current.responses.get(response), atMs = this.current.now;
    const timeoutMs = typeof options.timeoutMs === 'function' ? options.timeoutMs() : options.timeoutMs ?? null;
    const reader = response.body.getReader(), values = [];
    for (;;) { const { value, done } = await reader.read(); if (done) break; values.push(Buffer.from(value)); }
    reader.releaseLock(); const bytes = Buffer.concat(values); assert.ok(bytes.length <= maxBytes);
    this.current.readerCalls.push({ kind: receipt.kind, maxBytes, timeoutMs, chunkTimeoutMs: options.chunkTimeoutMs,
      hasOnIdleTimeout: typeof options.onIdleTimeout === 'function', hasOnOverflow: typeof options.onOverflow === 'function',
      atMs, chunkLengths: chunks, bytesRead: bytes.length, implementation: 'successful-lower-body-reader-facade' });
    receipt.maxBytes = maxBytes; this.current.now += receipt.kind === 'download' ? 2 : 3; return bytes;
  }
  async wait(ms) { this.current.events.push({ kind: 'wait', durationMs: ms, atMs: this.current.now, implementation: 'synthetic-wait-facade' }); this.current.now += ms; }
  async run(vector) {
    this.current = { response: plain(vector.response), services: plain(vector.services ?? {}), now: 100000,
      responses: new Map(), requests: [], events: [], pollIndex: 0, readerCalls: [], statusCalls: [], retryCalls: [], keyCalls: [], configCalls: [], sanitizeCalls: [] };
    const cfg = { models: { providers: { vydra: plain(vector.config) } }, ...(vector.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.mediaMaxMb } } }) };
    const req = { ...plain(vector.input), cfg }, cfgBefore = plain(cfg); this.context.__req = req; let timer;
    try {
      const promise = new vm.Script('__provider.generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Vydra fixture asynchronous deadline exceeded')), 5000); })]);
      const { cfg: _cfg, ...inputAfter } = req;
      assert.deepEqual(plain(cfg), cfgBefore); assert.deepEqual(plain(inputAfter), vector.input);
      assert.ok(this.current.requests.every(row => row.releaseCount === 1));
      this.context.__payload = this.current.response.polls.at(-1) ?? this.current.response.submitted;
      const extractedUrls = this.call('__shared.extractVydraResultUrls(__payload,"image")');
      return plain({ ...vector, inputAfter, configAfter: cfg.models.providers.vydra, extractedUrls,
        requests: this.current.requests, events: this.current.events, readerCalls: this.current.readerCalls,
        statusCalls: this.current.statusCalls, retryCalls: this.current.retryCalls, configCalls: this.current.configCalls,
        keyCalls: this.current.keyCalls, sanitizeCalls: this.current.sanitizeCalls,
        result: { ...result, images: result.images.map(({ buffer, ...asset }) => ({ ...asset, bytesBase64: buffer.toString('base64') })) },
        clock: { kind: 'synthetic-Date.now', startMs: 100000, endMs: this.current.now,
          serviceCostsMs: { key: 2, config: 3, post: 7, poll: 4, jsonRead: 3, download: 5, binaryRead: 2 } } });
    } finally { clearTimeout(timer); }
  }
}

export async function captureVydraImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root); assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new VydraHarness(root, before.tracked);
  await harness.load(catalog); const capabilityCatalog = harness.call('({keys:Object.keys(__exports.default),imageProvidersPresent:"imageGenerationProviders" in __exports.default})');
  await harness.load(vydraShared); harness.context.__shared = harness.context.__exports;
  await harness.load(entry);
  new vm.Script('__exports.default.register({registerProvider(){},registerSpeechProvider(){},registerVideoGenerationProvider(){},registerImageGenerationProvider(provider){globalThis.__provider=provider;}});').runInContext(harness.context, { timeout: 200 });
  const providerDescriptor = harness.call('(()=>{const {generateImage,isConfiguredAsync,...descriptor}=__provider;return descriptor;})()');
  const observations = []; for (const vector of vectors()) observations.push(await harness.run(vector));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source && row.wholeModule), source);
  for (const source of provenancePaths) { const bytes = readFileSync(join(root, source)); assert.equal(hash(bytes), before.tracked.get(source));
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true }); }
  const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
  return plain({ schemaVersion: 1, referencePin: VYDRA_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-vydra-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports,
    providerDescriptor, capabilityCatalog,
    serviceFacadeLedger: [
      { name: 'plugin registration/unrelated speech/auth/onboarding descriptors', executed: false, limit: 'Whole index/catalog run with registration and descriptor facades; speech/video/onboarding/configured checks uninvoked.' },
      { name: 'resolveProviderApiKeyHttpRequestConfig/credential/policy', executed: false, limit: 'Named successful key/config/policy facade consumes original normalized base. No production credential discovery or auth/policy verification.' },
      { name: 'sanitizeConfiguredModelProviderRequest', executed: false, limit: 'Literal ordinary successful output; real sanitizer unexecuted.' },
      { name: 'fetchWithTimeoutGuarded', executed: false, limit: 'No-network successful native streamed Response/release producer. Fallback60000 is an explicit facade; DNS/proxy/SSRF/TLS/permission unexecuted.' },
      { name: 'assertOkOrThrowHttpError', executed: false, limit: 'Successful status200 facade only.' },
      { name: 'readResponseWithLimit', executed: false, limit: 'Native reader consumes full tiny homogeneous bodies and records original cap/idle/lazy timeout arguments; production bound/timer enforcement unexecuted.' },
      { name: 'sleepWithAbort/executeProviderOperationWithRetry', executed: false, limit: 'Wait advances synthetic time by the original requested interval. Retry facade runs first successful operation only; failure/retry behavior unexecuted.' },
    ],
    limits: [
      'Whole unchanged Vydra index/shared/defaults/capability-catalog, JSON-post wrapper and pure number/string/record/constants execute. Catalog lists only speechProviders while index registers image; no image catalog is invented.',
      'Complete original deadline/poll/transport/JSON-body/cap and full MIME extension-map/normalization regions execute. Original static/lazy timeout resolution, JSON UTF8 parser and binary readers run over a successful lower reader.',
      'Image callback never passes video deadlineTimeoutMs. Explicit submission T, fresh polling T (per-call cap120000), and fresh download T are separate stages; body shares only its stage deadline. First poll immediate, max120 reads, ordinary wait2500ms.',
      'Original timer helpers floor positive durations and clamp at2147000000ms; modest fractional timeout only. Fractional POST receipt is raw30000.9 passed to the substituted guard, not actual native guard timer equivalence; download deadline normalizes to30000. No extreme/overflow execution.',
      'All58558 tracked blobs/modes/symlinks verified before/after. Original/projection/generated/transformed/import/export/exporter/shared-harness/fixed-Node24.22.1 receipts reconstruct independently.',
      'Every comparable row uses explicit grok-imagine, synthetic public base and finite positive timeout; omitted model/timeout/base and configured header facade rows are source-only. Only same-origin result URLs execute; no origin or key/policy-contract test.',
      'Ordered many-URL extraction yields one fetch. Small ordinary complete PNG/JPEG/WebP fixtures are homogeneous per invocation; raw trimmed MIME/filename/bytes are transport evidence, not decoded codec or visual-quality validation.',
      'No security/permission/auth/TLS/negative/mixed/overflow/failure/cancel/crash/real-provider execution. Raw callback only: no runtime selection/default installation/failover/tool activation/persistence/delivery or production policy/reader equivalence.',
    ], observations });
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2); assert.equal(args.length, 3); assert.equal(args[1], '--out'); assert.ok(args[2]);
  const result = await captureVydraImageGeneration(args[0]); writeFileSync(args[2], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: args[2], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
