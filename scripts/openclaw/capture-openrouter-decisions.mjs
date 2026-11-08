// Whole pinned OpenRouter/SystemOne source with ordinary successful synthetic HTTP.
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

export const OPENROUTER_DECISIONS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/openrouter/decision-provider.ts';
const catalog = 'extensions/openrouter/provider-catalog.ts';
const routing = 'extensions/openrouter/provider-routing.ts';
const requestConfig = 'src/agents/provider-request-config.ts';
const wholeSources = [entry, catalog, routing, 'extensions/openrouter/models.ts', 'extensions/openrouter/provider-defaults.ts',
  'src/decisions/validation-v2.ts', 'src/decisions/validation.ts', 'src/decisions/validation-common.ts', 'src/decisions/compatibility.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-normalization.ts', requestConfig, 'src/secrets/provider-request-secret-fields.ts'];
const provenancePaths = ['src/agents/tools/decision-tool.ts', 'src/agents/tools/decision-tool-contract.ts',
  'src/decisions/runtime.ts', 'src/decisions/provider-host.ts', 'src/decisions/types-v2.ts',
  'extensions/openrouter/openclaw.plugin.json', 'src/plugin-sdk/decisions.ts',
  'src/plugin-sdk/provider-http.ts', 'src/plugin-sdk/agent-scope-runtime.ts',
  'src/plugin-sdk/model-ref-parse.ts', 'src/config/types.secrets.ts', 'src/plugins/provider-auth-authority.ts',
  'src/agents/provider-attribution.ts'];
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENROUTER_DECISIONS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENROUTER_DECISIONS_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: OPENROUTER_DECISIONS_PIN, tree: git(root, ['rev-parse', `${OPENROUTER_DECISIONS_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}


function vectors() {
  const questions = {
    check: { type: 'boolean', instructions: 'Is this urgent?' },
    route: { type: 'choice', instructions: 'Which team?', criteria: { a: null, b: 'Billing' } },
    urgency: { type: 'score', instructions: 'How urgent?', criteria: ['Low', 'High'] },
  };
  const common = { contractVersion: 2, state: { type: 'json', value: { ticket: 'Supplied ticket 😀' } }, questions };
  const models = ['typesafe/jev-1.13', 'typesafe/jev-1.14', '~typesafe/jev-latest'];
  const png = 'data:image/png;base64,AA==';
  const jpeg = 'data:image/jpeg;base64,AQID';
  const rows = [
    { id: 'native-113', arguments: common, model: models[0] },
    { id: 'native-114', arguments: common, model: models[1] },
    { id: 'native-latest', arguments: common, model: models[2] },
    { id: 'legacy-text', arguments: { state: '  Explicit text 雪\n', questions }, model: models[0] },
    { id: 'json-array', arguments: { ...common, state: { type: 'json', value: ['ordered', 'evidence'] } }, model: models[0] },
    { id: 'json-string', arguments: { ...common, state: { type: 'json', value: 'Explicit JSON string' } }, model: models[0] },
    { id: 'image-png', arguments: { ...common, state: { type: 'image', dataUri: png } }, model: models[0] },
    { id: 'image-jpeg-empty-text', arguments: { ...common, state: { type: 'image', dataUri: jpeg, text: '' } }, model: models[0] },
    ...models.slice(1).map((model, index) => ({ id: index ? 'box-latest-jpeg' : 'box-114-png', model,
      arguments: { contractVersion: 2, state: { type: 'image', dataUri: index ? jpeg : png, text: 'Listing photo' },
        questions: { target: { type: 'box', instructions: 'the red product' } } } })),
    { id: 'cost-zero', arguments: common, model: models[0] },
    { id: 'cost-absent', arguments: common, model: models[0] },
    { id: 'usage-extended', arguments: common, model: models[0] },
    { id: 'custom-prefix', arguments: common, model: models[1], baseUrl: 'https://router.example.test/tenant/api/v1' },
    { id: 'provider-preferences', arguments: common, model: models[1],
      providerParams: { provider: { order: ['typesafe'], only: ['default'] } },
      modelParams: { provider: { only: ['model-choice'], require_parameters: true } },
      extraParams: { provider: { only: ['typesafe'] } },
      params: { provider: { order: ['typesafe'], only: ['typesafe'], require_parameters: true } } },
    { id: 'structured-instructions', arguments: { ...common, questions: {
      check: { type: 'boolean', instructions: { ask: 'Is this urgent?' }, criteria: { true: ['Urgent'], false: { label: 'Routine' } } },
      route: { type: 'choice', instructions: ['Choose'], criteria: { a: ['Accounts'], b: { name: 'Billing' } } },
      urgency: { type: 'score', instructions: { ask: 'Rate' }, criteria: [{ label: 'Low' }, ['High']] },
    } }, model: models[0] },
  ];
  return rows.map(row => {
    const box = row.id.startsWith('box-');
    const response = {
      model: row.model + '-served', provider: 'TypeSafe',
      answers: box ? { target: { type: 'box', box: { top: 0.25, bottom: 0.75, left: 0.25, right: 0.76 }, confidence: 0.91 } } : {
        check: { type: 'noul', noul: 0.37 },
        route: { type: 'choice', choice: 'a', probabilities: { a: 0.49, b: 0.5 }, confidence: 0.1 },
        urgency: { type: 'score', score: 0.71, probabilities: { '0': 0.3, '1': 0.69 }, confidence: 0.2 },
      }, usage: { input_tokens: 476, output_tokens: 70, cost: 0.000019992 },
    };
    if (row.id === 'cost-zero') response.usage = { input_tokens: 0, output_tokens: 0, cost: 0 };
    if (row.id === 'cost-absent') { response.usage = { input_tokens: 3, output_tokens: 1 }; delete response.provider; }
    if (row.id === 'usage-extended') response.usage = { input_tokens: 2, output_tokens: 1, cost: 0, provider_units: 3, details: { cached: 1 } };
    return { baseUrl: 'https://openrouter.ai/api/v1', params: {}, ...row, response };
  });
}

class OpenRouterHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, URL, Response, Headers, AbortController,
      performance: { now: () => 1000 },
      __platform: { isProxy, fetch: params => this.fetch(params), read: async (response, options) => {
        this.current.readerCalls.push({ maxBytes: options.maxBytes, timeoutMs: options.timeoutMs });
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
    return this.synthetic('capture:openrouter-decisions:' + key, code);
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
    if (parent.startsWith('capture:openrouter-decisions:') && specifier.startsWith('capture:source:')) return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    const alias = (source, names) => this.alias(importer, specifier, source, names);
    if (importer === entry && specifier === 'openclaw/plugin-sdk/decisions') return alias('src/decisions/validation-v2.ts', ['validateDecisionBatchV2', 'validateDecisionResultV2']);
    if (specifier === '@openclaw/normalization-core/record-coerce') return alias('packages/normalization-core/src/record-coerce.ts', ['isRecord']);
    if (specifier === '@openclaw/normalization-core/string-coerce') return alias('packages/normalization-core/src/string-coerce.ts', ['normalizeLowercaseStringOrEmpty']);
    if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime') {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['asOptionalRecord', 'asPositiveSafeInteger', 'filterStringEntries', 'normalizeOptionalString', 'normalizeLowercaseStringOrEmpty'], `
export {asOptionalRecord} from 'capture:source:packages/normalization-core/src/record-coerce.ts';
export {asPositiveSafeInteger} from 'capture:source:packages/normalization-core/src/number-coercion.ts';
export {filterStringEntries} from 'capture:source:packages/normalization-core/src/string-normalization.ts';
export {normalizeOptionalString,normalizeLowercaseStringOrEmpty} from 'capture:source:packages/normalization-core/src/string-coerce.ts';`);
    }
    if (importer === 'src/decisions/validation-common.ts' && specifier === 'node:util/types') return this.binding(importer, specifier, 'actual-platform-builtin', ['isProxy'], 'export const isProxy=globalThis.__platform.isProxy;');
    if ([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/provider-http') return this.binding(importer, specifier, 'successful-http-policy-reader-fixture', ['normalizeBaseUrl','readProviderJsonResponse','resolveProviderHttpRequestConfig','sanitizeConfiguredModelProviderRequest'], `
export {normalizeBaseUrl} from 'capture:source:src/agents/provider-request-config.ts';
export async function readProviderJsonResponse(response,label,options){return JSON.parse(JSON.stringify(await globalThis.__platform.read(response,options)));}
export function resolveProviderHttpRequestConfig(params){return {baseUrl:params.baseUrl,headers:params.defaultHeaders,allowPrivateNetwork:false};}
export function sanitizeConfiguredModelProviderRequest(value){return value;}`);
    if ([entry, catalog].includes(importer) && specifier === 'openclaw/plugin-sdk/ssrf-runtime') return this.binding(importer, specifier, 'successful-transport-fixture', ['fetchWithSsrFGuard','ssrfPolicyFromHttpBaseUrlAllowedOrigin'], `
export const fetchWithSsrFGuard=globalThis.__platform.fetch;
export function ssrfPolicyFromHttpBaseUrlAllowedOrigin(){return {};}`);
    if (importer === routing && specifier === 'openclaw/plugin-sdk/agent-scope-runtime') return this.binding(importer, specifier, 'explicit-agent-config-fixture', ['resolveAgentConfig'], 'export function resolveAgentConfig(config,agentId){return config.agents?.entries?.[agentId];}');
    const unused = [
      [catalog,'openclaw/plugin-sdk/model-catalog-pricing',['normalizeOpenRouterModelPricing'],'src/plugin-sdk/model-catalog-pricing.ts'],
      [catalog,'openclaw/plugin-sdk/provider-catalog-live-runtime',['buildLiveModelProviderConfig'],'src/plugin-sdk/provider-catalog-live-runtime.ts'],
      [catalog,'openclaw/plugin-sdk/provider-catalog-shared',['normalizeOpenRouterModelReasoning'],'src/plugin-sdk/provider-catalog-shared.ts'],
      ['extensions/openrouter/models.ts','openclaw/plugin-sdk/model-ref-parse',['normalizeOpenRouterModelFamilyId'],'src/plugin-sdk/model-ref-parse.ts'],
      [requestConfig,'../config/types.secrets.js',['assertSecretInputResolved'],'src/config/types.secrets.ts'],
      [requestConfig,'../plugins/provider-auth-authority.js',['attachProviderAuthAuthority','getProviderAuthAuthority'],'src/plugins/provider-auth-authority.ts'],
      [requestConfig,'./provider-attribution.js',['resolveProviderRequestCapabilities'],'src/agents/provider-attribution.ts'],
    ].find(([owner,name]) => importer === owner && specifier === name);
    if (unused) return this.unused(importer,specifier,unused[2],unused[3]);
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared OpenRouter import: ${importer} -> ${specifier}`);
  }

  async fetch(params) {
    params.beforeRequest();
    this.current.requests.push({ url: params.url, method: params.init.method, body: JSON.parse(params.init.body), timeoutMs: params.timeoutMs });
    return { response: new Response(JSON.stringify(this.current.response), { status: 200 }), release: async () => { this.current.releases++; } };
  }

  async run(vector) {
    this.current = { ...plain(vector), requests: [], releases: 0, readerCalls: [] };
    this.context.__vector = plain(vector);
    new vm.Script(`{
const args=JSON.parse(JSON.stringify(__vector.arguments));
globalThis.__batch=args.contractVersion===2?{state:args.state,questions:args.questions}:__compat.decisionBatchV1ToV2(args);
globalThis.__decisionContext={agentId:'worker',signal:new AbortController().signal,deadlineMonotonicMs:31000,isAdmissible:()=>true,
 auth:{mode:'api-key',apiKey:'fixture-openrouter-key'},
 model:{id:__vector.model,baseUrl:__vector.baseUrl,params:__vector.modelParams,
 inference:{decision:{confidence:'provider-specific',questions:{
 boolean:{probabilities:'boolean',abstention:false},choice:{probabilities:'categorical',abstention:false},
 score:{probabilities:'categorical',abstention:false},box:{probabilities:'none',abstention:false}}}}},
 config:{models:{providers:{openrouter:{params:__vector.providerParams}}},agents:{entries:{worker:{params:__vector.extraParams}}}}};
}`).runInContext(this.context, { timeout: 1000 });
    let timer;
    try {
      const evaluation = new vm.Script('__exports.buildOpenRouterDecisionProvider().evaluate(__batch,__decisionContext)').runInContext(this.context,{timeout:1000});
      const outcome = await Promise.race([evaluation,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('capture deadline exceeded')),5000);})]);
      assert.equal(outcome.status,'ok',JSON.stringify({id:vector.id,outcome}));
      assert.equal(this.current.requests.length,1,vector.id);
      assert.equal(this.current.releases,1,vector.id);
      return {...plain(vector),batch:plain(this.context.__batch),request:this.current.requests[0],outcome:plain(outcome),releaseCount:1,readerCalls:this.current.readerCalls};
    } finally { clearTimeout(timer); }
  }
}

export async function captureOpenRouterDecisions(source = fixedRoot) {
  assert.equal(process.versions.node,'24.22.1');
  assert.equal(realpathSync(process.execPath),realpathSync(fixedNode));
  const root=realpathSync(source);assert.equal(root,fixedRoot);
  const before=checkout(root),harness=new OpenRouterHarness(root,before.tracked);
  await harness.load('src/decisions/compatibility.ts');harness.context.__compat=harness.context.__exports;
  await harness.load(entry);
  const observations=[];for(const row of vectors())observations.push(await harness.run(row));
  const sourceRecords=[...harness.sourceRecords.values()];for(const source of wholeSources)assert.ok(sourceRecords.some(row=>row.path===source),source);
  for(const source of provenancePaths){assert.ok(before.tracked.has(source),source);sourceRecords.push({path:source,sha256:before.tracked.get(source),executed:false,provenanceOnly:true});}
  const after=checkout(root);assert.deepEqual(before.receipt,after.receipt);assert.deepEqual(plain(harness.context.__deferredCalls),[]);
  return {schemaVersion:1,referencePin:OPENROUTER_DECISIONS_PIN,
    exporter:{path:'scripts/openclaw/capture-openrouter-decisions.mjs',sha256:hash(readFileSync(fileURLToPath(import.meta.url)))},
    harness:{path:'scripts/openclaw/capture-recipes.mjs',sha256:hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url)))},
    runtime:{executable:fixedNode,version:process.versions.node,sha256:hash(readFileSync(fixedNode))},
    sourceTree:{before:before.receipt,after:after.receipt},transformation:transform,sourceRecords,importBindings:[...harness.importBindings.values()],
    deferredCalls:plain(harness.context.__deferredCalls),observations,limits:[
      'Complete unchanged OpenRouter decision provider, catalog URL normalizer, routing/model helpers, V1/V2 validation/compatibility and normalization modules execute; no copied protocol bodies.',
      'Synthetic successful HTTP Response only. HTTP policy/headers/request sanitization/SSRF/body reader and Agent-config lookup are explicit facades; production transport, timeout/overflow/cancellation and account authority bodies are unexecuted.',
      'Actual provider preference merge executes against explicit provider/model/Agent fixture inputs. This is source algorithm evidence, not Synapsis reference-config inheritance or dynamic capability discovery parity.',
      'Exact request/result values, box, rounded distributions, served model/provider, optional zero/absent cost and full extra raw usage execute; no real model quality or endpoint support claim.',
      'Native map UTF16/Jason representation remains a host adaptation; supplied JSON state is a JSON value on SystemOne, not an OpenAI-style JSON text string. No exact incoming-order/JavaScript-byte claim.',
      'Only successful boolean/choice/score and supported box/image routes execute; no unsupported/error/auth/security/permission/cancellation behavior is tested.',
    ]};
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  assert.ok(process.argv[3]);const capture=await captureOpenRouterDecisions(process.argv[2]);writeFileSync(process.argv[3],JSON.stringify(capture,null,2)+'\n');
  process.stdout.write(JSON.stringify({vectors:capture.observations.length,modules:capture.sourceRecords.filter(row=>row.executed).length})+'\n');
}
