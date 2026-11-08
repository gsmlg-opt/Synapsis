// Whole pinned Workboard factories and ordinary record algorithms. Supplied ports are not SQLite.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto, { createHash } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import { isDeepStrictEqual } from 'node:util';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const WORKBOARD_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const prefix = 'extensions/workboard/';
const entry = prefix + 'index.ts';
const toolSource = prefix + 'src/tools.ts';
const storeSource = prefix + 'src/store.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, prefix + 'record-fields.ts',
  ...['tools', 'tools-orchestration', 'tools-card-mutations', 'card-redaction', 'workspace-access',
    'workspace-path', 'store', 'store-notifications', 'store-workflow', 'store-promote',
    'store-enrichment', 'store-core', 'store-boards', 'store-runtime', 'store-automation',
    'store-normalizers', 'store-board-normalizers', 'store-card-helpers', 'store-constants',
    'store-read', 'store-string-lists'].map(path => prefix + 'src/' + path + '.ts'),
  'packages/workboard-contract/src/index.ts', 'packages/workboard-contract/src/sessions-board.ts',
  'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tool-input-error.ts',
  'src/infra/unicode-visibility.ts', 'src/param-key.ts', 'src/security/secret-equal.ts',
  ...['number-coercion', 'string-coerce', 'record-coerce', 'string-normalization', 'utf16-slice']
    .map(path => 'packages/normalization-core/src/' + path + '.ts'),
];

// Only these imports are supplied. Their complete generated code is part of the receipt.
// Plugin registration is executed, but the external services it registers are not started.
const suppliedCode = {
  [prefix + 'api.ts']: {
    definePluginEntry: `export function definePluginEntry(value){
      __registrationCalls.push({callback:'definePluginEntry',id:value.id,name:value.name,description:value.description,
        boundary:'supplied identity entry constructor; production plugin SDK assembly not executed'});return value;
    }`,
  },
  [prefix + 'runtime-api.ts']: {
    WorkboardStore: `export const WorkboardStore={openSqlite(workerModuleUrl){
      __registrationCalls.push({callback:'WorkboardStore.openSqlite',workerModuleUrl,
        boundary:'supplied existing original domain instance; SQLite factory not executed'});return __store;
    }};`,
    registerWorkboardGatewayMethods: `export function registerWorkboardGatewayMethods(){__registrationCalls.push({callback:'registerWorkboardGatewayMethods',boundary:'supplied registration sink; gateway not executed'});}`,
  },
  [prefix + 'src/automation-nudge.ts']: {
    createWorkboardAutomationNudgeService: `export function createWorkboardAutomationNudgeService(){return __service('createWorkboardAutomationNudgeService');}`,
  },
  [prefix + 'src/change-events.ts']: {
    createWorkboardChangeEventService: `export function createWorkboardChangeEventService(){return __service('createWorkboardChangeEventService');}`,
  },
  [prefix + 'src/command.ts']: {
    registerWorkboardCommand: `export function registerWorkboardCommand(){__registrationCalls.push({callback:'registerWorkboardCommand',boundary:'supplied registration sink; command not executed'});}`,
  },
  [prefix + 'src/lifecycle-sync.ts']: {
    createWorkboardLifecycleService: `export function createWorkboardLifecycleService(){return __service('createWorkboardLifecycleService');}`,
    readWorkboardLifecycleSessions: `export function readWorkboardLifecycleSessions(){return __uninvoked('readWorkboardLifecycleSessions');}`,
    syncWorkboardAgentEnded: `export function syncWorkboardAgentEnded(){return __uninvoked('syncWorkboardAgentEnded');}`,
    syncWorkboardSubagentEnded: `export function syncWorkboardSubagentEnded(){return __uninvoked('syncWorkboardSubagentEnded');}`,
  },
  [prefix + 'src/sessions-board.ts']: {
    createWorkboardSessionsBoardService: `export function createWorkboardSessionsBoardService(){return __service('createWorkboardSessionsBoardService');}`,
  },
  [prefix + 'src/sqlite-store-paths.ts']: {
    resolveWorkboardSqliteWorkerModuleUrl: `export function resolveWorkboardSqliteWorkerModuleUrl(){
      __registrationCalls.push({callback:'resolveWorkboardSqliteWorkerModuleUrl',boundary:'supplied symbolic address; no worker'});return 'supplied:sqlite-worker-not-executed';
    }`,
  },
  [prefix + 'src/store-lifecycle.ts']: {
    registerWorkboardStoreLifecycle: `export function registerWorkboardStoreLifecycle(){__registrationCalls.push({callback:'registerWorkboardStoreLifecycle',boundary:'supplied registration sink; lifecycle not executed'});}`,
  },
  'src/plugin-sdk/runtime-env.ts': {
    createSubsystemLogger: `export function createSubsystemLogger(name){
      __registrationCalls.push({callback:'createSubsystemLogger',name,boundary:'supplied logger; no production logging'});
      return Object.fromEntries(['info','warn','error','debug'].map(method=>[method,(...args)=>__uninvoked('logger.'+method)]));
    }`,
  },
};
const deferredCode = {
  [prefix + 'src/sqlite-store.ts']: ['createWorkboardSqliteStores'],
  'src/plugin-sdk/agent-runtime.ts': ['listAgentIds', 'resolveAgentConfig', 'resolveAgentWorkspaceDir', 'resolveDefaultAgentId'],
  'src/plugin-sdk/file-access-runtime.ts': ['canonicalPathFromExistingAncestor', 'isPathInside'],
  'packages/media-core/src/mime.ts': ['detectMime'],
  'src/infra/fs-safe.ts': ['readLocalFileSafely'],
};

// This is an explicit supplied persistence PORT, not copied domain algorithms or a persistence oracle.
// Filtering/aggregation implement its declared input contract; record normalization/order/context
// execute only in original source. Unused persistence operations throw if reached.
const hostCode = `
globalThis.__plain=value=>value===undefined?undefined:JSON.parse(JSON.stringify(value));
globalThis.__deferredCalls=[];
globalThis.__registrationCalls=[];
globalThis.__persistenceCalls=[];
globalThis.__registered=[];
globalThis.__uninvoked=name=>{__deferredCalls.push(name);throw Error('uninvoked supplied boundary: '+name);};
globalThis.__service=name=>{
  __registrationCalls.push({callback:name,boundary:'supplied inert service; original service implementation not executed'});
  return Object.fromEntries(['stop','nudge','onGatewayStart','onGatewayStop','readSessions','read','update','move']
    .map(method=>[method,()=>__uninvoked(name+'.'+method)]));
};
globalThis.__keyed=(name)=>{
  const values=new Map();
  const receipt=(method,args)=>__persistenceCalls.push({port:name,method,arguments:__plain(args),boundary:'explicit supplied in-memory persistence port'});
  return {values,
    async register(key,value){receipt('register',[key,value]);values.set(key,__plain(value));},
    async lookup(key){receipt('lookup',[key]);return __plain(values.get(key));},
    async delete(key){return __uninvoked(name+'.delete');},
    async entries(){receipt('entries',[]);return [...values].map(([key,value])=>({key,value:__plain(value)}));},
  };
};
globalThis.__cards=__keyed('cards');
globalThis.__boardValues=__keyed('boards');
globalThis.__cardEntries=__cards.entries;
__cards.entries=async function(scope){
  const rows=await __cardEntries();
  __persistenceCalls.push({port:'cards',method:'entriesScope',arguments:__plain([scope??null]),boundary:'supplied scope filtering; original readCards applies ordering'});
  if(!scope)return rows;
  if(scope.kind==='board')return rows.filter(({value})=>(value.card.metadata?.automation?.boardId??'default')===scope.boardId);
  if(scope.kind==='worker-context')return rows.filter(({value})=>scope.parentIds.includes(value.card.id)||
    (value.card.id!==scope.cardId&&(value.card.metadata?.automation?.boardId??'default')===scope.boardId&&
      value.card.agentId===scope.agentId&&value.card.status==='done'));
  return __uninvoked('cards.entries:'+scope.kind);
};
__cards.registerIfUpdatedAt=async function(key,value,expectedUpdatedAt){
  __persistenceCalls.push({port:'cards',method:'registerIfUpdatedAt',arguments:__plain([key,value,expectedUpdatedAt]),boundary:'supplied single-process in-memory comparison; no durable CAS qualification'});
  if(__cards.values.get(key)?.card.updatedAt!==expectedUpdatedAt)return __uninvoked('unexpected supplied update mismatch');
  __cards.values.set(key,__plain(value));return true;
};
__cards.listBoardAggregates=async function(){
  const groups=new Map();
  for(const {card} of __cards.values.values()){
    const boardId=card.metadata?.automation?.boardId??'default';const key=JSON.stringify([boardId,card.status]);
    const aggregate=groups.get(key)??{boardId,status:card.status,total:0,archived:0,updatedAt:0};
    aggregate.total++;aggregate.archived+=card.metadata?.archivedAt?1:0;aggregate.updatedAt=Math.max(aggregate.updatedAt,card.updatedAt);groups.set(key,aggregate);
  }
  const result=[...groups.values()];
  __persistenceCalls.push({port:'cards',method:'listBoardAggregates',arguments:[],result:__plain(result),boundary:'supplied aggregation port; original readBoardSummaries consumes these facts'});
  return __plain(result);
};
for(const name of ['registerIfAbsent','deleteIfUpdatedAt','claimIfOwnerAvailable','listCardStatuses','listStatsAggregates','hasCards'])
  __cards[name]=()=>__uninvoked('cards.'+name);
globalThis.__stores={boards:__boardValues,subscriptions:__keyed('subscriptions'),attachments:__keyed('attachments'),
  sessionsBoard:Object.fromEntries(['get','update','listPlacements','repairPlacements','writePlacement'].map(name=>[name,()=>__uninvoked('sessionsBoard.'+name)]))};
globalThis.__toolContext={agentId:'fixture-agent',sessionKey:'agent:fixture-agent:main',sessionId:'supplied-session',
  assertInvocationCurrent:()=>__uninvoked('assertInvocationCurrent')};
globalThis.__api={registrationMode:'supplied-ordinary-registration',runtimeSource:'supplied-source',
  runtime:{gateway:{},worktrees:{},sandbox:{resolveWorkspaceAuthority:()=>__uninvoked('resolveWorkspaceAuthority')}},
  session:{controls:{registerControlUiDescriptor:value=>__registrationCalls.push({callback:'registerControlUiDescriptor',value:__plain(value),boundary:'supplied UI registration sink'})}},
  registerCli:(_callback,metadata)=>__registrationCalls.push({callback:'registerCli',metadata:__plain(metadata),boundary:'supplied registration sink; CLI callback not invoked'}),
  registerService:()=>__registrationCalls.push({callback:'registerService',boundary:'supplied registration sink; service not started'}),
  on:event=>__registrationCalls.push({callback:'on',event,boundary:'supplied registration sink; event handler not invoked'}),
  registerTool:(factory,options)=>__registered.push({factory,options}),
};
`;

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], {encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024,
    env: {...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1'}}).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), WORKBOARD_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', WORKBOARD_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t'); const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path); const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    return {path, gitBlob, sha256: hash(bytes)};
  });
  assert.equal(files.length, 58558);
  return {tracked: new Map(files.map(row => [row.path, row.sha256])), receipt: {verified: true, commit: WORKBOARD_PIN,
    tree: git(root, ['rev-parse', `${WORKBOARD_PIN}^{tree}`]), verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files))}};
}

class WorkboardHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, {allowedSources: wholeSources});
    this.context = vm.createContext({Buffer, TextEncoder, TextDecoder, __platform: {crypto, AsyncLocalStorage, isDeepStrictEqual}},
      {codeGeneration: {strings: false, wasm: false}});
    new vm.Script(hostCode).runInContext(this.context, {timeout: 1000});
    this.sourceRecords = new Map(); this.importBindings = new Map();
  }
  record(path) {
    const sha256 = this.tracked.get(path); assert.ok(sha256, path);
    assert.equal(hash(readFileSync(join(this.root, path))), sha256, path);
    if (!this.sourceRecords.has(path)) this.sourceRecords.set(path, {path, sha256, executed: false, originalSourceExecuted: false, provenanceOnly: true});
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    if (this.typeboxRoot && file.startsWith(this.typeboxRoot + sep)) return super.module(file);
    const path = relative(this.root, file); assert.ok(wholeSources.includes(path), path); this.record(path);
    const executable = stripTypeScriptTypes(readFileSync(file, 'utf8'), {mode: 'transform', sourceMap: false});
    this.sourceRecords.set(path, {path, sha256: this.tracked.get(path), executed: false, originalSourceExecuted: false,
      wholeModule: true, transformation, executableSha256: hash(executable)});
    const mod = new vm.SourceTextModule(executable, {context: this.context, identifier: file,
      importModuleDynamically: () => {this.context.__deferredCalls.push('dynamic import'); throw Error('undeclared dynamic import');}});
    this.modules.set(file, mod); return mod;
  }
  async load(path) {
    await super.load(path);
    for (const row of this.sourceRecords.values()) if (this.modules.get(join(this.root, row.path))?.status === 'evaluated') {
      row.executed = true; row.originalSourceExecuted = true; row.provenanceOnly = false;
    }
  }
  binding(importer, specifier, kind, exports, generatedCode, sources = []) {
    for (const path of sources) this.record(path);
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, {importer, specifier, kind, exports, generatedCode,
      generatedSha256: hash(generatedCode), sources: sources.map(path => ({path, sha256: this.tracked.get(path)})),
      originalSourceExecuted: kind === 'whole-source-export-alias'});
    return this.synthetic('capture:workboard:' + key, generatedCode);
  }
  aliases(importer, specifier, selections, barrel) {
    const aliases = selections.map(([source, exports]) => ({source, exports: exports.map(value =>
      typeof value === 'string' ? {sourceName: value, exportedName: value} : value)}));
    const code = aliases.map(({source, exports}) => `export {${exports.map(({sourceName, exportedName}) =>
      sourceName === exportedName ? sourceName : `${sourceName} as ${exportedName}`).join(',')}} from ${JSON.stringify('capture:source:' + source)};`).join('\n');
    const mod = this.binding(importer, specifier, 'whole-source-export-alias', aliases.flatMap(({exports}) => exports.map(value => value.exportedName)), code,
      [...selections.map(([source]) => source), ...(barrel ? (Array.isArray(barrel) ? barrel : [barrel]) : [])]);
    this.importBindings.get(importer + ':' + specifier).exportAliases = aliases;
    return mod;
  }
  source(importer, specifier, path) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, {importer, specifier, kind: 'whole-source-module', source: path, sourceSha256: this.tracked.get(path)});
    return this.module(join(this.root, path));
  }
  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:workboard:') && specifier.startsWith('capture:source:')) return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    if (specifier === 'typebox') {
      const file = super.resolve(specifier, parent); const key = importer + ':typebox';
      if (!this.importBindings.has(key)) this.importBindings.set(key, {importer, specifier, kind: 'actual-pinned-package', version: this.typeboxVersion,
        path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(readFileSync(file)), packageSha256: this.dependencies.get('typebox/package.json').sha256});
      return this.module(file);
    }
    if (this.typeboxRoot && parent.startsWith(this.typeboxRoot + sep)) {
      const file = super.resolve(specifier, parent); const key = importer + ':' + specifier;
      if (!this.importBindings.has(key)) this.importBindings.set(key, {importer: 'typebox/' + relative(this.typeboxRoot, parent), specifier,
        kind: 'actual-package-module', path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(readFileSync(file))});
      return this.module(file);
    }
    const builtins = {
      'node:crypto': ['createHash', 'randomUUID', 'timingSafeEqual'],
      'node:util': ['isDeepStrictEqual'], 'node:async_hooks': ['AsyncLocalStorage'],
    };
    if (builtins[specifier]) {
      const code = specifier === 'node:crypto'
        ? 'export const {createHash,randomUUID,timingSafeEqual}=globalThis.__platform.crypto;'
        : `export const {${builtins[specifier].join(',')}}=globalThis.__platform;`;
      return this.binding(importer, specifier, 'actual-platform-builtin', builtins[specifier], code);
    }
    if (specifier === '@openclaw/workboard-contract') return this.source(importer, specifier, 'packages/workboard-contract/src/index.ts');
    const normalization = '@openclaw/normalization-core/';
    if (specifier.startsWith(normalization)) return this.source(importer, specifier, 'packages/normalization-core/src/' + specifier.slice(normalization.length) + '.ts');
    const sdk = 'openclaw/plugin-sdk/';
    if (specifier === sdk + 'core') return this.aliases(importer, specifier, [
      ['src/agents/tools/common.ts', [{sourceName: 'readToolStringParam', exportedName: 'readStringParam'}]],
      ['src/agents/tools/tool-results.ts', ['jsonResult']]], 'src/plugin-sdk/core.ts');
    if (specifier === sdk + 'number-runtime') return this.aliases(importer, specifier, [
      ['packages/normalization-core/src/number-coercion.ts', ['resolveIntegerOption', 'resolveOptionalIntegerOption', 'resolveNonNegativeIntegerOption',
        'isFutureDateTimestampMs', 'MAX_DATE_TIMESTAMP_MS', 'resolveExpiresAtMsFromDurationMs']]], 'src/plugin-sdk/number-runtime.ts');
    if (specifier === sdk + 'string-coerce-runtime') return this.aliases(importer, specifier, [
      ['packages/normalization-core/src/record-coerce.ts', ['isRecord', 'asRecord', 'asNonArrayRecord', 'asOptionalRecord']],
      ['packages/normalization-core/src/string-coerce.ts', ['normalizeOptionalString', 'readStringValue']]], 'src/plugin-sdk/string-coerce-runtime.ts');
    if (specifier === sdk + 'text-utility-runtime') return this.aliases(importer, specifier, [
      ['packages/normalization-core/src/utf16-slice.ts', ['truncateUtf16Safe']]], ['src/plugin-sdk/text-utility-runtime.ts', 'src/utils.ts']);
    if (specifier === sdk + 'security-runtime') return this.aliases(importer, specifier, [
      ['src/security/secret-equal.ts', ['safeEqualSecret']]], 'src/plugin-sdk/security-runtime.ts');
    let path;
    if (specifier === '@openclaw/media-core/mime') path = 'packages/media-core/src/mime.ts';
    else if (specifier.startsWith(sdk)) path = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
    else if (specifier.startsWith('.')) path = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
    if (path && suppliedCode[path]) return this.binding(importer, specifier, 'explicit-supplied-registration-boundary',
      Object.keys(suppliedCode[path]), Object.values(suppliedCode[path]).join('\n'), [path]);
    if (path && deferredCode[path]) {
      const exports = deferredCode[path];
      return this.binding(importer, specifier, 'uninvoked-throwing-boundary', exports,
        exports.map(name => `export function ${name}(){return __uninvoked(${JSON.stringify(path + ':' + name)});}`).join('\n'), [path]);
    }
    if (path && wholeSources.includes(path)) return this.source(importer, specifier, path);
    throw Error(`Undeclared Workboard import: ${importer} -> ${specifier}`);
  }
  run(code) {return new vm.Script(code).runInContext(this.context, {timeout: 1000});}
  receipt(phase) {
    return {phase, evaluatedWholeSources: [...this.sourceRecords.values()].filter(row => row.executed).map(row => row.path).sort(),
      meaning: 'whole modules evaluated; this is not per-branch coverage'};
  }
}

async function deadline(promise) {
  let timer;
  try {return await Promise.race([promise, new Promise((_, reject) => {timer = setTimeout(() => reject(Error('Workboard callback deadline')), 5000);})]);}
  finally {clearTimeout(timer);}
}

// Normalize ONLY after original Date/crypto complete. UUIDs are assigned by first occurrence
// in the deterministic vector traversal; original distinctness/equality is checked beforehand.
// All generated times use one display token: real elapsed/order claims stay in pre-substitution receipts.
function canonicalize(value) {
  const ids = new Map();
  const uuid = /\b[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/gi;
  const visit = item => {
    if (typeof item === 'number' && item >= 1700000000000) return 1800000000000;
    if (typeof item === 'string') return item.replace(uuid, original => {
      if (!ids.has(original)) ids.set(original, 'generated-workboard-uuid-' + (ids.size + 1));
      return ids.get(original);
    }).replace(/\b1[7-9][0-9]{11}\b/g, '1800000000000');
    if (Array.isArray(item)) return item.map(visit);
    if (item && typeof item === 'object') return Object.fromEntries(Object.entries(item).map(([key, child]) => [key, visit(child)]));
    return item;
  };
  return visit(value);
}

export async function captureWorkboard(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot); const before = checkout(root);
  const harness = new WorkboardHarness(root, before.tracked);
  await harness.load(storeSource); harness.context.__domain = harness.context.__exports;
  harness.run('globalThis.__store=new __domain.WorkboardStore(__cards,__stores);');
  await harness.load(toolSource); harness.context.__factories = harness.context.__exports;
  await harness.load(prefix + 'src/tools-orchestration.ts'); harness.context.__orchestration = harness.context.__exports;
  await harness.load(entry); harness.context.__entry = harness.context.__exports.default;
  harness.run(`__entry.register(__api);
    globalThis.__cardTools=__factories.createWorkboardTools({context:__toolContext,store:__store});
    globalThis.__orchestrationTools=__orchestration.createWorkboardOrchestrationTools({store:__store,ownerId:__toolContext.agentId});
    globalThis.__sessionTools=__registered[1].factory.create(__toolContext);
    globalThis.__tools=Object.fromEntries([...__cardTools,...__sessionTools].map(tool=>[tool.name,tool]));`);
  const executionReceipts = [harness.receipt('original-domain-constructor-and-factories-and-plugin-registration')];
  const tools = harness.call(`Object.fromEntries(Object.entries(__tools).map(([name,tool])=>[name,
    Object.fromEntries(Object.entries(tool).filter(([,value])=>typeof value!=='function'))]))`);
  const registrations = harness.call(`__registered.map(({factory,options})=>({options,
    factoryKind:typeof factory==='function'?'function':'context-factory',...(factory.contextVersion?{contextVersion:factory.contextVersion}:{})}))`);
  const factoryGroups = harness.call(`({
    base:__cardTools.filter(tool=>!__orchestrationTools.some(other=>other.name===tool.name)).map(tool=>tool.name),
    orchestration:__orchestrationTools.map(tool=>tool.name),sessions:__sessionTools.map(tool=>tool.name)})`);
  assert.equal(Object.keys(tools).length, 38);
  assert.deepEqual([...registrations[0].options.names, ...registrations[1].options.names].sort(), Object.keys(tools).sort());
  const observations = [];
  const invoke = async (id, tool, args) => {
    harness.context.__serializedArguments = JSON.stringify(args);
    harness.run('globalThis.__params=JSON.parse(__serializedArguments);');
    const start = harness.context.__persistenceCalls.length;
    const result = plain(await deadline(harness.run(`__tools[${JSON.stringify(tool)}].execute('supplied-ordinary-call',__params)`)));
    const row = {id, tool, arguments: plain(args), argumentsAfter: harness.call('__params'), result,
      persistenceCalls: plain(harness.context.__persistenceCalls.slice(start)),
      execution: 'actual unchanged factory callback and original source domain/store algorithms'};
    observations.push(row); executionReceipts.push({...harness.receipt(id), tool, callbackCompleted: true}); return result.details;
  };
  await invoke('board-create', 'workboard_board_create', {id: ' research ', name: ' Research 雪😀 ', description: ' Ordinary board '});
  await invoke('board-update', 'workboard_board_create', {id: 'research', name: ' Research reviewed '});
  const minimal = (await invoke('create-minimal', 'workboard_create', {title: ' Minimal 雪😀 ', boardId: 'research'})).card;
  const richArgs = {title: ' Rich supplied item ', notes: ' Acceptance 雪😀 ', priority: 'high', labels: [' review ', 'review', '雪😀'],
    agentId: ' fixture-agent ', tenant: ' fixture-tenant ', boardId: 'research', idempotencyKey: ' ordinary-repeat ',
    skills: [' inspect ', 'review', 'inspect'], workspace: {kind: 'dir', path: '/supplied/workspace'}, maxRuntimeSeconds: 120, maxRetries: 2};
  const rich = (await invoke('create-rich', 'workboard_create', richArgs)).card;
  const repeated = (await invoke('create-repeat', 'workboard_create', richArgs)).card;
  const other = (await invoke('create-other', 'workboard_create', {title: 'Other ordinary item', boardId: 'other'})).card;
  const done = (await invoke('create-done', 'workboard_create', {title: 'Done ordinary item', boardId: 'research', status: 'done', agentId: 'fixture-agent'})).card;
  await invoke('list-research', 'workboard_list', {boardId: 'research'});
  await invoke('list-filtered', 'workboard_list', {boardId: 'research', status: 'todo', agentId: 'fixture-agent', tenant: 'fixture-tenant'});
  await invoke('list-limited', 'workboard_list', {boardId: 'research', limit: 1});
  await invoke('read-before', 'workboard_read', {id: ' ' + rich.id + ' '});
  const commented = (await invoke('comment', 'workboard_comment', {id: rich.id, body: ' Reviewed ordinary evidence 雪😀 '})).card;
  await invoke('read-after', 'workboard_read', {id: rich.id});
  await invoke('boards-after', 'workboard_boards', {});
  const createdCards = [minimal, rich, other, done];
  const createdIds = createdCards.flatMap(card => [card.id, card.events[0].id]);
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  for (const id of [...createdIds, commented.metadata.comments[0].id, commented.events.at(-1).id]) assert.match(id, uuidPattern);
  assert.equal(new Set(createdIds).size, createdIds.length);
  assert.deepEqual(repeated, rich);
  for (const card of createdCards) {
    assert.ok(Number.isSafeInteger(card.createdAt)); assert.equal(card.createdAt, card.updatedAt);
    assert.equal(card.events[0].at, card.createdAt);
  }
  assert.ok(commented.updatedAt > rich.updatedAt);
  assert.ok(commented.updatedAt >= commented.metadata.comments[0].createdAt);
  assert.equal(commented.events.at(-1).at, commented.updatedAt);
  const boardFirst = observations.find(row => row.id === 'board-create').result.details.board;
  const boardUpdated = observations.find(row => row.id === 'board-update').result.details.board;
  assert.equal(boardUpdated.createdAt, boardFirst.createdAt); assert.ok(boardUpdated.updatedAt >= boardFirst.updatedAt);
  const recordReceipts = {distinctCreatedCards: new Set(createdCards.map(card => card.id)).size, sameKeySameCard: true,
    originalUUIDv4ShapeAndDistinctCreationIdsChecked: true, originalCreationTimestampEqualityChecked: true,
    originalCommentUpdateStrictlyAfterCardUpdateChecked: true, originalCommentTimeAtOrBeforeUpdateChecked: true,
    originalEventUpdateTimestampEqualityChecked: true, originalBoardCreationTimePreservedChecked: true,
    originalBoardUpdateNondecreasingChecked: true};
  const observed = canonicalize({observations, persistenceSnapshot: harness.call(`({
    cards:[...__cards.values].map(([key,value])=>({key,value})),boards:[...__boardValues.values].map(([key,value])=>({key,value}))})`)});
  const sourceRecords = [...harness.sourceRecords.values()].sort((a, b) => a.path.localeCompare(b.path));
  const after = checkout(root); assert.deepEqual(before.receipt, after.receipt);
  return {schemaVersion: 1, referencePin: WORKBOARD_PIN,
    exporter: {path: 'scripts/openclaw/capture-workboard.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url)))},
    harness: {path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url)))},
    runtime: {executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode))},
    sourceTree: {before: before.receipt, after: after.receipt}, transformation, sourceRecords,
    importBindings: [...harness.importBindings.values()],
    typebox: {version: harness.typeboxVersion, root: harness.typeboxRoot, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path))},
    host: {generatedCode: hostCode, sha256: hash(hostCode)}, tools, registrations, factoryGroups,
    registrationCalls: harness.call('__registrationCalls'), executionReceipts, ...observed, recordReceipts,
    deferredCalls: harness.call('__deferredCalls'),
    persistenceBoundary: 'explicit supplied in-memory keyed/card persistence interface, including scope filtering and board aggregates; no original SQLite/persistence qualification',
    canonicalization: {strategy: 'post-execution generated UUID substitution and common display timestamp',
      generatedUUID: 'generated-workboard-uuid-N in first observed occurrence order', generatedTimestamp: 1800000000000,
      scope: 'Actual crypto and Date run unchanged. Original ID identity/distinctness and timestamp relations are checked before display substitution; identical occurrences in JSON text, worker context and records share substitutions.',
      limits: 'Common displayed times do not preserve elapsed time or cross-operation timestamp equality distinctions. Pre-substitution receipt booleans prove only the named ordinary relations, not timing or concurrency.'},
    boundaries: {all38FactoriesInvoked: true, originalPluginRegistrationExecuted: true, originalRecordAlgorithmsExecuted: true,
      sqliteExecuted: false, productionPersistenceExecuted: false, workspaceGuardExecuted: false,
      sessionsBoardServiceExecuted: false, pluginServiceLifecycleExecuted: false, permissionQualification: false, networkExecuted: false, hostImplementation: false},
    limits: [
      'All 16 base and 19 orchestration factories execute as unchanged whole source; the original index register callback and contextVersion 2 Sessions factory create all 3 Sessions-board descriptors with exact TypeBox 1.3.37.',
      'Raw card factories execute directly. The registered card workspace guard callback is retained but not invoked; wrapper fidelity, workspace authority, security/permission/auth and production tool assembly remain unqualified.',
      'The original WorkboardStore constructor, inherited Board/Core runtime, normalizers, ordering, create, readWithWorkerContext, comment and public JSON projections execute over supplied ports. Other loaded store layer methods are not behavior coverage.',
      'Supplied keyed/card persistence implements in-memory lookup/register/scoped entries/ordinary compare-and-register and board aggregates only. SQLite workers, durability, atomicity, concurrent CAS, owner lifecycle and persistence recovery are not executed or qualified.',
      'Plugin API, definePluginEntry, runtime-api openSqlite, logger, service constructors and registration sinks are explicitly supplied boundaries. The runtime-api openSqlite name returns the existing source domain instance and does not execute original SQLite; original store.ts static openSqlite is uninvoked.',
      'Sessions-board factories are schema/registration evidence only; read/update/move service callbacks, gateway projection, placement persistence, plugin UI and service lifecycle do not execute.',
      'Only ordinary successful board upsert/list and item create/list/read/comment callbacks execute. Claim/dispatch/proof/attachments/notifications and other descriptor-only tools are not qualified by the 38-tool count.',
      'ClickClack discussion is a separate pending capture; comments are not a discussion substitute. Synapsis host scope and default/implicit board policy remain pending product decisions; reference source defaults are observations only.',
      'No host Workboard implementation, full equivalence, safety/security/permission/auth/negative/failure/cancel/crash/TLS/mixed-result/budget/eviction/real-provider qualification is claimed.',
    ]};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 4, 'usage: capture-workboard.mjs source-root output');
  const capture = await captureWorkboard(process.argv[2]); writeFileSync(process.argv[3], JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({tools: Object.keys(capture.tools).length, vectors: capture.observations.length,
    wholeModules: capture.sourceRecords.filter(row => row.executed).length}) + '\n');
}
