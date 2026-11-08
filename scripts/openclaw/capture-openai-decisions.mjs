// Whole pinned native Decisions modules; successful synthetic HTTP only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { isProxy } from 'node:util/types';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const OPENAI_DECISIONS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openai/decision-provider.runtime.ts';
const sdk = 'src/plugin-sdk/decisions-openai-runtime.ts';
const wholeSources = [entry, sdk, 'extensions/openai/base-url.ts',
  'src/decisions/validation-v2.ts', 'src/decisions/validation.ts',
  'src/decisions/validation-common.ts', 'src/decisions/compatibility.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/string-coerce.ts'];
const provenancePaths = ['src/agents/tools/decision-tool.ts', 'src/agents/tools/decision-tool-contract.ts',
  'src/decisions/runtime.ts', 'src/decisions/provider-host.ts', 'src/decisions/types-v2.ts',
  'extensions/openai/decision-provider.ts', 'extensions/openai/openclaw.plugin.json',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/extension-shared.ts',
  'src/plugin-sdk/agent-harness-runtime.ts', 'src/plugin-sdk/fetch-runtime.ts'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENAI_DECISIONS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENAI_DECISIONS_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: OPENAI_DECISIONS_PIN, tree: git(root, ['rev-parse', `${OPENAI_DECISIONS_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}


function vectors() {
  const questions = {
    damaged: { type: 'boolean', instructions: 'Is the parcel damaged?', criteria: { true: 'Damaged parcel', false: null } },
    route: { type: 'choice', instructions: { task: 'Choose route' }, criteria: { sales: ['New order'], support: { team: 'support' } } },
    urgency: { type: 'score', criteria: ['Low', { level: 'Medium' }, null] },
  };
  const base = { contractVersion: 2, state: { type: 'text', text: '  The parcel is damaged. 😀\n' }, questions };
  const image = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA3sAAAAASUVORK5CYII=';
  const rows = [
    ['text-three', base],
    ['json-three', { ...base, state: { type: 'json', value: { count: 2, report: 'The parcel is damaged' } } }],
    ['legacy-text', { state: 'Legacy supplied evidence', questions }],
    ['legacy-null', { state: null, questions }],
    ['legacy-array', { state: [{ fact: 'one' }, null, 'two'], questions }],
    ['image-text', { ...base, state: { type: 'image', dataUri: image, text: 'Inspect supplied image only' } }],
    ['image-only', { ...base, state: { type: 'image', dataUri: image } }],
    ['missing-instructions', { ...base, questions: { check: { type: 'boolean' } } }],
    ['null-instructions', { ...base, questions: { check: { type: 'boolean', instructions: null, criteria: null } } }],
    ['explicit-choice-estimates', base],
    ['custom-api-prefix', base],
  ];
  return rows.map(([id, args]) => ({ id, arguments: args,
    baseUrl: id === 'custom-api-prefix' ? 'https://decisions.example.test/custom/v1' : 'https://api.openai.com/v1',
    response: { model: 'returned-decision-model', answers: Object.entries(args.questions).map(([name, q]) => {
      if (q.type === 'boolean') return { name, type: 'predicate', probability: 0.95 };
      if (q.type === 'choice') return { name, type: 'choice', choice: 'support', confidence: 1.7,
        probabilities: [{ value: 'support', probability: id === 'explicit-choice-estimates' ? 0.2 : 0.8 },
          { value: 'sales', probability: 0.7 }] };
      return { name, type: 'score', score: 1.25, confidence: -0.2, probabilities: [
        { label: '2', value: 2, probability: 0.3 }, { label: '0', value: 0, probability: 0.05 },
        { label: '1', value: 1, probability: 0.65 }] };
    }), usage: { input_tokens: 42, output_tokens: 0, total_tokens: 42 } } }));
}

class DecisionsHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, URL, Response, AbortController,
      performance: { now: () => 1000 },
      __platform: { isProxy, fetch: params => this.fetch(params),
        read: async (response, options) => {
          this.current.readerCalls.push({ maxBytes: options.maxBytes });
          return response.json();
        } } }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script('globalThis.__captureAudit=[];globalThis.__deferredCalls=[]').runInContext(this.context);
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
    return this.synthetic('capture:decisions:' + key, code);
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
      exports.map(name => `export function ${name}(){globalThis.__deferredCalls.push(${JSON.stringify({ importer, specifier, export: name })});throw Error('Uninvoked decisions dependency: ${name}');}`).join('\n'),
      { source, sourceSha256: this.tracked.get(source), originalSourceExecuted: false });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:decisions:') && specifier.startsWith('capture:source:')) {
      return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    }
    const alias = (source, exports) => this.alias(importer, specifier, source, exports);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/decisions-openai-runtime') {
      return alias(sdk, ['evaluateOpenAICompatibleDecision']);
    }
    if (importer === 'extensions/openai/base-url.ts' && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return alias('packages/normalization-core/src/string-coerce.ts', ['normalizeOptionalString']);
    }
    if (specifier === '@openclaw/normalization-core/record-coerce' ||
        (importer === sdk && specifier === './string-coerce-runtime.js')) {
      return alias('packages/normalization-core/src/record-coerce.ts', ['isRecord']);
    }
    if (importer === sdk && specifier === './decisions.js') return alias('src/decisions/validation-v2.ts', ['validateDecisionBatchV2']);
    if (importer === 'src/decisions/validation-common.ts' && specifier === 'node:util/types') {
      return this.binding(importer, specifier, 'actual-platform-builtin', ['isProxy'], 'export const isProxy=globalThis.__platform.isProxy;');
    }
    if (importer === sdk && specifier === './agent-harness-runtime.js') {
      return this.binding(importer, specifier, 'explicit-prepared-model-fixture', ['getModelProviderRequestTransport'], 'export function getModelProviderRequestTransport(){return undefined;}');
    }
    if (importer === sdk && specifier === './extension-shared.js') {
      return this.binding(importer, specifier, 'explicit-deadline-fixture', ['buildTimeoutAbortSignal'],
        'export function buildTimeoutAbortSignal(params){globalThis.__timeout=params.timeoutMs;return {signal:params.signal,cleanup(){globalThis.__cleanups++;}};}');
    }
    if (importer === sdk && specifier === './fetch-runtime.js') {
      return this.binding(importer, specifier, 'explicit-environment-fixture', ['shouldUseEnvHttpProxyForUrl', 'withTrustedEnvProxyGuardedFetchMode'],
        'export function shouldUseEnvHttpProxyForUrl(){return false;} export function withTrustedEnvProxyGuardedFetchMode(){throw Error("uninvoked proxy mode");}');
    }
    if (importer === sdk && specifier === './provider-http.js') {
      return this.binding(importer, specifier, 'successful-http-policy-reader-fixture',
        ['createProviderCredentialMatcher', 'fetchWithProviderHttpGuard', 'readProviderJsonObjectResponse', 'resolveProviderHttpRequestConfig'], `
export function createProviderCredentialMatcher(){return ()=>false;}
export const fetchWithProviderHttpGuard=globalThis.__platform.fetch;
export function readProviderJsonObjectResponse(response,label,options){return globalThis.__platform.read(response,options);}
export function resolveProviderHttpRequestConfig(params){return {baseUrl:params.baseUrl,headers:params.defaultHeaders,allowPrivateNetwork:false};}
`);
    }
    if (importer === sdk && specifier === './retry-runtime.js') {
      return this.unused(importer, specifier, ['parseRetryAfterHeaderSeconds'], 'src/plugin-sdk/retry-runtime.ts');
    }
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared decision import: ${importer} -> ${specifier}`);
  }

  async fetch(params) {
    params.beforeRequest();
    this.current.requests.push({ url: params.url, method: params.init.method,
      body: JSON.parse(params.init.body), timeoutMs: this.context.__timeout });
    return { response: new Response(JSON.stringify(this.current.response), { status: 200 }),
      release: async () => { this.current.releases++; } };
  }

  async run(vector) {
    this.current = { ...plain(vector), requests: [], releases: 0, readerCalls: [] };
    this.context.__vector = plain(vector);
    new vm.Script(`{globalThis.__cleanups=0;
const args=JSON.parse(JSON.stringify(__vector.arguments));
globalThis.__batch=args.contractVersion===2?{state:args.state,questions:args.questions}:__compat.decisionBatchV1ToV2(args);
globalThis.__decisionContext={signal:new AbortController().signal,deadlineMonotonicMs:31000,
 auth:{mode:'api-key',apiKey:'fixture-decision-key'},isAdmissible:()=>true,
 model:{id:'gpt-6-luna',api:'openai-responses',baseUrl:__vector.baseUrl}};}
`).runInContext(this.context, { timeout: 1000 });
    let timer;
    try {
      const evaluation = new vm.Script('__exports.evaluateOpenAIDecision(__batch,__decisionContext)').runInContext(this.context, { timeout: 1000 });
      const outcome = await Promise.race([evaluation, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('capture deadline exceeded')), 5000); })]);
      assert.equal(this.current.requests.length, 1, vector.id);
      assert.equal(this.current.releases, 1, vector.id);
      assert.equal(this.context.__cleanups, 1, vector.id);
      const batch = plain(this.context.__batch);
      assert.equal(outcome.status, 'ok', vector.id);
      return { ...plain(vector), batch, request: this.current.requests[0], outcome: plain(outcome),
        releaseCount: this.current.releases, cleanupCount: this.context.__cleanups, readerCalls: this.current.readerCalls };
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenAIDecisions(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  const harness = new DecisionsHarness(root, before.tracked);
  await harness.load('src/decisions/compatibility.ts');
  harness.context.__compat = harness.context.__exports;
  await harness.load(entry);
  const observations = [];
  for (const row of vectors()) observations.push(await harness.run(row));
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of wholeSources) assert.ok(sourceRecords.some(row => row.path === source), source);
  for (const source of provenancePaths) sourceRecords.push({ path: source, sha256: before.tracked.get(source), executed: false, provenanceOnly: true });
  const after = checkout(root);
  assert.deepEqual(before.receipt, after.receipt);
  assert.deepEqual(plain(harness.context.__deferredCalls), []);
  return { schemaVersion: 1, referencePin: OPENAI_DECISIONS_PIN,
    exporter: { path: 'scripts/openclaw/capture-openai-decisions.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    sourceTree: { before: before.receipt, after: after.receipt },
    transformation: transform, sourceRecords, importBindings: [...harness.importBindings.values()],
    deferredCalls: plain(harness.context.__deferredCalls), observations,
    limits: [
      'Whole unchanged native OpenAI wrapper, SDK translator/parser, V1/V2 validators, compatibility and normalization modules execute; no copied protocol bodies.',
      'Synthetic successful HTTP Response only; no socket, provider quality, real account, credential selection, model capability discovery or full runtime/tool factory executes.',
      'Prepared request, HTTP policy, credential matcher, timeout/cleanup and JSON response reader are explicit facades. Production policy, timeout/overflow/cancellation bodies and transport release are unexecuted.',
      'Reference object iteration and JSON.stringify execute with canonical ASCII fixture keys; Synapsis native map sorting and Jason numeric encoding are documented host adaptations, not exact incoming-order or numeric-byte parity.',
      'Only boolean/choice/score and text/json/image routes execute. No list/sort/tags/box or other provider implementation claim.',
    ] };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3]);
  const capture = await captureOpenAIDecisions(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ vectors: capture.observations.length, modules: capture.sourceRecords.filter(row => row.executed).length }) + '\n');
}
