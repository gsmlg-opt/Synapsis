// Whole pinned standing-intent source with real SQLite; the worker transport is supplied.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { tmpdir } from 'node:os';
import { isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const STANDING_INTENTS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const artifactPath = '/tmp/synapsis-intent297-evidence/kysely-artifact.json';
const prefix = 'extensions/memory-core/';
const entry = prefix + 'index.ts';
const workerSource = prefix + 'src/standing-intents.worker.ts';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  }).trimEnd();
}

function verifyTree(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), STANDING_INTENTS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const tracked = new Map();
  for (const item of git(root, ['ls-tree', '-rz', '--full-tree', STANDING_INTENTS_PIN]).split('\0').filter(Boolean)) {
    const [header, path] = item.split('\t');
    const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    assert.equal(lstatSync(file).isSymbolicLink(), mode === '120000');
    assert.ok(inside(root, realpathSync(file)), path);
    const bytes = mode === '120000' ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    tracked.set(path, { path, gitBlob, sha256: hash(bytes) });
  }
  return { tracked, receipt: { pin: STANDING_INTENTS_PIN,
    tree: git(root, ['rev-parse', `${STANDING_INTENTS_PIN}^{tree}`]),
    clean: true, verifiedTrackedFiles: tracked.size } };
}

// These declarations only re-export unchanged complete source modules through narrow SDK names.
const sdkSources = {
  'agent-scope-runtime': {
    'src/agents/agent-scope.ts': ['listAgentIds', 'resolveSessionAgentIdStrict'],
  },
  'lazy-runtime': { 'src/shared/lazy-runtime.ts': ['createLazyRuntimeModule'] },
  'memory-core-host-runtime-core': {
    'src/agents/tools/common.ts': ['asToolParamsRecord'],
    'src/agents/tools/tool-results.ts': ['jsonResult'],
  },
  'param-readers': {
    'src/agents/tools/common.ts': ['readNonNegativeIntegerParam', 'readPositiveIntegerParam'],
  },
  'plugin-config-runtime': {
    'src/plugins/config-state.ts': ['createNormalizedPluginsConfig as normalizePluginsConfig'],
  },
  'database-engine-worker-runtime': {
    'src/infra/database-engine/search-admission.ts': ['admitStoreSearch'],
  },
  'memory-core-host-engine-storage': {
    'src/infra/sql-connection.ts': ['isPostgresSqlConnection'],
    'src/infra/database-engine/capability-unavailable.ts': ['DatabaseSearchCapabilityUnavailableError'],
  },
  'memory-core-host-engine-schema': {
    'packages/memory-host-sdk/src/host/memory-search-schema.ts': ['memoryStandingIntentSearchSchema'],
  },
  'sqlite-worker-runtime': {
    'src/infra/kysely-sync.ts': ['executeSqliteQuerySync', 'executeSqliteQueryTakeFirstSync', 'getNodeSqliteKysely', 'sqliteStringSet'],
    'src/infra/sqlite-transaction.ts': ['runSqliteImmediateTransactionSync'],
    'src/infra/sqlite-worker-binding.ts': ['bindSqliteWorkerDatabase'],
    'src/infra/sqlite-post-commit.ts': ['withSqlitePostCommitPublications'],
    'src/state/openclaw-agent-standing-intents-schema.ts': ['ensureOpenClawAgentStandingIntentsSchema'],
  },
  'state-paths': { 'src/config/state-dir.ts': ['resolveStateDir'] },
};

// Each deferred import is outside the selected ordinary source path. Reaching it is an error.
// No operation on the selected SQLite/FTS/transaction/queue/standing-intent path is deferred.
const deferredSources = new Set([
  'src/config/model-input.ts', 'src/config/sessions/auth-profile-override-provenance.ts',
  'src/config/sessions/model-override-provenance.ts', 'src/config/sessions/session-store-config.ts',
  'src/agents/workspace-state-identity.ts', 'src/skills/discovery/agent-filter.ts',
  'src/cli/command-format.ts', 'src/config/model-policy-allowlist-migration.ts',
  'src/config/runtime-config-publication.ts', 'src/infra/main-thread-stall.ts',
  'src/utils.ts', 'src/agents/agent-dir-registry.ts', 'src/agents/workspace-default.ts',
  'src/cli/profile-utils.ts', 'src/infra/home-dir.ts',
  'src/channels/bundled-channel-catalog-read.ts',
  'src/infra/fs-safe.ts', 'packages/media-core/src/mime.ts',
  'src/infra/database-engine/postgres-search.ts',
  'src/infra/database-engine/search-extension.ts',
  'src/infra/database-engine/physical-facts.ts',
  'src/infra/database-engine/sqlite-vector-subprocess.ts',
  'src/infra/database-engine/sqlite-memory-vector-schema.ts',
  'src/state/openclaw-database-seal-schema.ts',
]);

const unrelated = {
  [prefix + 'cli-metadata.ts']: `export function registerMemoryCoreCli(){__observe('registerMemoryCoreCli');}`,
  [prefix + 'src/dreaming-state.ts']: `export function configureMemoryCoreDreamingState(){__observe('configureMemoryCoreDreamingState');}`,
  [prefix + 'src/dreaming.ts']: `export function registerShortTermPromotionDreaming(){__observe('registerShortTermPromotionDreaming');}`,
  [prefix + 'src/flush-plan.ts']: `export function buildMemoryFlushPlan(){return __uninvoked('buildMemoryFlushPlan');}`,
  [prefix + 'src/memory/lifecycle.ts']: `export function prepareMemoryManagerReload(){return __uninvoked('prepareMemoryManagerReload');}
export function retainMemoryIndexingAgents(){return __uninvoked('retainMemoryIndexingAgents');}`,
  [prefix + 'src/session-backfill-gateway.ts']: `export function registerSessionBackfillGatewayMethods(){__observe('registerSessionBackfillGatewayMethods');}`,
  [prefix + 'src/memory-tool-contract.ts']: `
export const MEMORY_SEARCH_TOOL_CONTRACT={name:'memory_search'};
export const MEMORY_GET_TOOL_CONTRACT={name:'memory_get'};
export function buildMemoryPromptSection(){return __uninvoked('buildMemoryPromptSection');}
export function buildProjectMemoryWriteInstruction(){return __uninvoked('buildProjectMemoryWriteInstruction');}
export function resolveMemoryToolContext(){return __uninvoked('resolveMemoryToolContext');}`,
};

// Exact supplied input, registration and scheduling code evaluated in the source VM.
const inputCode = `
export function installInputs(stateDir){
 globalThis.__clock=1800000000000;
 const NativeDate=Date;
 globalThis.Date=class extends NativeDate{
  constructor(...args){super(...(args.length?args:[__clock]));}
  static now(){return __clock;}
 };
 globalThis.__input={agentId:'agent297',sessionKey:'agent:agent297:source',sessionId:'source-session297',
  nativeChannelId:'conversation297',messageChannel:' WebChat ',requesterSenderId:' synapsis:operator '};
 globalThis.__config={agents:{entries:{agent297:{}}},plugins:{slots:{memory:'capture-unselected-memory'}}};
 globalThis.__processEnv={OPENCLAW_STATE_DIR:stateDir};
 globalThis.__calls=[];
 globalThis.__deferredCalls=[];
 globalThis.__observe=(name,input)=>__calls.push({name,...(input===undefined?{}:{input})});
 globalThis.__uninvoked=name=>{__deferredCalls.push(name);throw Error('uninvoked supplied boundary: '+name);};
 globalThis.__registeredTools=[];
 globalThis.__registeredHooks=[];
 globalThis.__registeredServices=[];
 globalThis.__api={id:'memory-core',config:__config,
  runtime:{config:{current:()=>__config},llm:{acquireLocalService(){return __uninvoked('llm.acquireLocalService');}},
   state:{openKeyedStore(){return __uninvoked('state.openKeyedStore');}}},
  lifecycle:{runInBackgroundContext(run){return __uninvoked('lifecycle.runInBackgroundContext');},
   onDispose(callback){__observe('onDispose',{callbackPresent:typeof callback==='function'});}},
  logger:Object.fromEntries(['warn','info','debug','error'].map(name=>[name,(...args)=>__observe('logger.'+name,args)])),
  registerTool(factory,options){__registeredTools.push({factory,options});__observe('registerTool',options);},
  registerService(service){__registeredServices.push(service);__observe('registerService',{id:service.id});},
  on(name,callback){__registeredHooks.push({name,callback});__observe('on',{name});},
  registerMemoryCapability(){__observe('registerMemoryCapability');},
  registerCommand(){__observe('registerCommand');}};
 globalThis.__maintenance={started:false,stopped:false,scheduled:[],executed:[],pendingAfterStop:null};
 globalThis.__jobs=new Map();
 globalThis.__schedulerController=new AbortController();
 globalThis.__scheduler={signal:__schedulerController.signal,now:()=>__clock,
  schedule(job){const token={job};__jobs.set(job.id,token);
   __maintenance.scheduled.push({id:job.id,atMs:job.atMs});
   return {cancel(){if(__jobs.get(job.id)===token)__jobs.delete(job.id);}};}};
 globalThis.__drainDue=async()=>{
  for(let turns=0;turns<32;turns++){
   const due=[...__jobs.values()].filter(({job})=>job.atMs<=__clock).sort((a,b)=>a.job.atMs-b.job.atMs);
   if(!due.length)return;
   for(const token of due){const {job}=token;if(__jobs.get(job.id)!==token)continue;
    __jobs.delete(job.id);__maintenance.executed.push({id:job.id,atMs:job.atMs,nowMs:__clock});await job.run();}
  }
  throw Error('manual scheduler did not settle');
 };
}
`;

// This port has no domain operations. Its execute delegates to the unchanged worker backend.
// Logical facade handles borrow one physical connection; only explicit teardown closes it.
const transportCode = `
import {DatabaseSync} from 'node:sqlite';
import {mkdirSync} from 'node:fs';
import {dirname} from 'node:path';
export function installTransport(){
 globalThis.__physical=undefined;
 globalThis.__sql=[];
 globalThis.__transportCalls=[];
 globalThis.__opened=0;globalThis.__closed=0;
 globalThis.__openPhysical=(options)=>{
  mkdirSync(dirname(options.path),{recursive:true});
  const db=new DatabaseSync(options.path);__opened++;
  const nativePrepare=db.prepare.bind(db),nativeExec=db.exec.bind(db);
  db.exec=function(sql){__sql.push({sql,parameters:[]});return nativeExec(sql);};
  db.prepare=function(sql){
   const statement=nativePrepare(sql);
   return new Proxy(statement,{get(target,key){const value=Reflect.get(target,key,target);
    if(typeof value!=='function')return value;
    if(['all','get','run','iterate'].includes(key))return (...parameters)=>{
     __sql.push({sql,parameters:[...parameters]});return Reflect.apply(value,target,parameters);};
    return value.bind(target);
   }});
  };
  const backend=__bindBackend(undefined,{database:db,admit(stage){__transportCalls.push({operation:'admit',stage});}});
  __physical={db,backend,path:options.path};return __physical;
 };
 globalThis.__closePhysical=()=>{
  if(!__physical)return;
  __physical.backend.assertSettled();__physical.backend.close();__physical.db.close();__closed++;__physical=undefined;
 };
 globalThis.__inspectRows=()=>__physical.db.prepare('SELECT * FROM standing_intents ORDER BY intent_key').all();
 globalThis.__inspectSchema=()=>__physical.db.prepare("SELECT name,type,sql FROM sqlite_schema WHERE name LIKE '%standing_intents%' ORDER BY name").all();
}
export async function openOpenClawAgentSqliteWorkerStoreV2(options,authority,descriptor){
 __transportCalls.push({operation:'open',path:options.path,version:authority.version,moduleUrl:String(descriptor.moduleUrl)});
 authority.assertCurrent();
 let closed=false;
 return {
  async prepare(){authority.assertCurrent();if(!__physical)__openPhysical(options);
   if(__physical.path!==options.path)throw Error('capture transport path changed');},
  async execute(command,assertCurrent){
   if(closed)throw Error('capture logical handle closed');authority.assertCurrent();assertCurrent();
   __transportCalls.push({operation:'execute',type:command.type});
   return __physical.backend.execute(command);
  },
  async close(){closed=true;__transportCalls.push({operation:'close'});},
 };
}
export function resolveRuntimeWorkerUrl(descriptor){
 __transportCalls.push({operation:'worker-address',descriptor});return new URL(__sourceWorkerUrl);
}
`;

// Observation-only constructor: the original plugin register body and its callbacks execute.
const entryCode = `export function definePluginEntry(value){__observe('definePluginEntry',{id:value.id});return value;}`;
const loggerCode = `export function createSubsystemLogger(name){
 return Object.fromEntries(['warn','info','debug','error','trace'].map(method=>[method,(...args)=>__observe('subsystem.'+method,{name,args})]));
}`;

class StandingIntentHarness {
  constructor(root, tracked, artifact, stateDir) {
    this.root = root;
    this.tracked = tracked;
    this.artifact = artifact;
    this.records = new Map();
    this.ports = new Map();
    this.modules = new Map();
    this.executableSources = new Map();
    this.packageFiles = new Map();
    const captureProcess = Object.create(process);
    captureProcess.env = { OPENCLAW_STATE_DIR: stateDir };
    this.context = vm.createContext({ process: captureProcess, Buffer, TextEncoder, TextDecoder,
      URL, URLSearchParams, AbortController, AbortSignal, structuredClone, performance,
      setTimeout, clearTimeout, setImmediate, clearImmediate, console },
    { codeGeneration: { strings: false, wasm: false } });
    this.context.__sourceWorkerUrl = pathToFileURL(join(root, workerSource)).href;
    this.context.__stateDir = stateDir;
  }

  sourceRecord(path, execute = false) {
    const bytes = readFileSync(join(this.root, path));
    const pinned = this.tracked.get(path);
    assert.ok(pinned, `untracked source: ${path}`);
    assert.equal(hash(bytes), pinned.sha256, path);
    if (!this.records.has(path)) this.records.set(path, { ...pinned, wholeModule: true, executed: false });
    if (!execute) return bytes.toString();
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.records.set(path, { ...pinned, wholeModule: true, executed: true, transformation,
      executableSha256: hash(executable) });
    this.executableSources.set(path, executable);
    return executable;
  }

  port(name, generatedCode, exports = [], modulePaths = []) {
    const key = 'capture:port:' + name;
    if (!this.modules.has(key)) {
      this.ports.set(key, { name, exports, modulePaths, generatedCode, sha256: hash(generatedCode) });
      this.modules.set(key, new vm.SourceTextModule(generatedCode,
        { context: this.context, identifier: key }));
    } else assert.equal(this.ports.get(key).generatedCode, generatedCode, name);
    return this.modules.get(key);
  }

  source(path) {
    if (this.modules.has(path)) return this.modules.get(path);
    assert.ok(!deferredSources.has(path), `deferred source reached: ${path}`);
    const executable = this.sourceRecord(path, true);
    const module = new vm.SourceTextModule(executable, { context: this.context, identifier: path,
      initializeImportMeta: meta => { meta.url = pathToFileURL(join(this.root, path)).href; },
      importModuleDynamically: async specifier => {
        assert.ok(path === entry && ['./src/standing-intents.js', './src/standing-intents-tool.js'].includes(specifier),
          `undeclared dynamic source import: ${path}:${specifier}`);
        this.context.__observe('dynamic-import', { importer: path, specifier });
        return this.load(this.relative(specifier, path));
      } });
    this.modules.set(path, module);
    if (path === 'src/state/openclaw-agent-schema.ts') this.sourceRecord('src/state/openclaw-agent-schema.sql');
    return module;
  }

  relative(specifier, importer) {
    const requested = posix.normalize(posix.join(posix.dirname(importer), specifier));
    assert.ok(!requested.startsWith('../') && !isAbsolute(requested), `source traversal: ${requested}`);
    for (const candidate of [requested.replace(/\.js$/, '.ts'), requested, requested + '/index.ts']) {
      if (this.tracked.has(candidate)) return candidate;
    }
    throw Error(`unresolved source: ${importer}:${specifier}`);
  }

  // Read only transformed import/export declarations to name throwing boundary exports.
  // No source body is selected, edited, or replaced by this operation.
  requestedNames(importer, specifier) {
    const executable = this.executableSources.get(importer);
    assert.ok(executable, importer);
    const names = new Set();
    for (const match of executable.matchAll(/(?:import|export)\s+([^;]*?)\s+from\s+["']([^"']+)["']\s*;/g)) {
      if (match[2] !== specifier) continue;
      const declaration = match[1].trim();
      const braces = declaration.match(/\{([^}]+)\}/);
      if (braces) for (const name of braces[1].split(',')) {
        const original = name.trim().split(/\s+as\s+/)[0];
        if (original) names.add(original);
      }
      if (!declaration.startsWith('{') && !declaration.startsWith('*')) names.add('default');
      assert.ok(!declaration.startsWith('*'), `namespace deferred import: ${importer}:${specifier}`);
    }
    assert.ok(names.size, `no declared deferred exports: ${importer}:${specifier}`);
    return [...names].sort();
  }

  deferred(importer, specifier, target) {
    if (this.tracked.has(target)) this.sourceRecord(target);
    const names = this.requestedNames(importer, specifier);
    const code = names.map(name => name === 'default'
      ? `export default function(){return __uninvoked(${JSON.stringify(target + ':default')});}`
      : `export function ${name}(){return __uninvoked(${JSON.stringify(target + ':' + name)});}`).join('\n');
    return this.port('uninvoked:' + importer + ':' + specifier, code, names, [target]);
  }

  reexports(name, sources) {
    const code = Object.entries(sources).map(([path, names]) =>
      `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`).join('\n');
    return this.port('original-exports:' + name, code,
      Object.values(sources).flat().map(name => name.split(/\s+as\s+/).at(-1)), Object.keys(sources));
  }

  packageSource(path) {
    const actual = realpathSync(join(this.artifact.packageRoot, path));
    assert.ok(inside(this.artifact.packageRoot, actual));
    const bytes = readFileSync(actual);
    assert.equal(hash(bytes), this.artifact.files[path], 'kysely/' + path);
    this.packageFiles.set(path, { path, sha256: hash(bytes) });
    const key = 'package:kysely/' + path;
    if (!this.modules.has(key)) this.modules.set(key,
      new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: key }));
    return this.modules.get(key);
  }

  async import(specifier, owner) {
    const importer = owner.identifier;
    if (specifier.startsWith('capture:source:')) return this.source(specifier.slice('capture:source:'.length));
    if (importer.startsWith('package:kysely/')) {
      assert.ok(specifier.startsWith('.'), specifier);
      return this.packageSource(posix.normalize(posix.join(posix.dirname(importer.slice('package:kysely/'.length)), specifier)));
    }
    if (specifier.startsWith('node:')) {
      const allowed = new Set(['node:crypto', 'node:util', 'node:util/types', 'node:async_hooks',
        'node:buffer', 'node:path', 'node:fs', 'node:fs/promises', 'node:url', 'node:os',
        'node:worker_threads', 'node:timers/promises', 'node:perf_hooks', 'node:sqlite']);
      assert.ok(allowed.has(specifier), `undeclared platform import: ${specifier}`);
      const namespace = await import(specifier);
      const key = 'capture:platform:' + specifier;
      if (!this.modules.has(key)) {
        this.context.__platform ??= {};
        this.context.__platform[specifier] = namespace;
        const names = Object.keys(namespace);
        const code = names.map(name => name === 'default'
          ? `export default globalThis.__platform[${JSON.stringify(specifier)}].default;`
          : `export const ${name}=globalThis.__platform[${JSON.stringify(specifier)}][${JSON.stringify(name)}];`).join('\n');
        return this.port('platform:' + specifier, code, names);
      }
      return this.modules.get(key);
    }
    if (specifier === 'kysely') return this.packageSource('dist/index.js');
    if (specifier === '@openclaw/media-core/mime') {
      return this.deferred(importer, specifier, 'packages/media-core/src/mime.ts');
    }
    for (const packageName of ['normalization-core', 'session-url-contract']) {
      const packagePrefix = '@openclaw/' + packageName;
      if (specifier === packagePrefix || specifier.startsWith(packagePrefix + '/')) {
        return this.source('packages/' + packageName + '/src/' + (specifier.slice(packagePrefix.length + 1) || 'index') + '.ts');
      }
    }
    if (specifier.startsWith('@openclaw/fs-safe/')) return this.deferred(importer, specifier, specifier);
    if (specifier.startsWith('openclaw/plugin-sdk/')) {
      const name = specifier.slice('openclaw/plugin-sdk/'.length);
      if (sdkSources[name]) return this.reexports('sdk:' + name, sdkSources[name]);
      if (name === 'plugin-entry') return this.port('plugin-entry-constructor', entryCode, ['definePluginEntry']);
      if (name === 'memory-core-host-runtime-files') return this.port('unrelated-memory-backend',
        `export function resolveMemoryBackendConfig(){return __uninvoked('resolveMemoryBackendConfig');}`, ['resolveMemoryBackendConfig']);
      if (name === 'process-runtime') return this.transport();
      if (name === 'sqlite-runtime') return this.reexports('sdk:sqlite-runtime', {
        'src/shared/store-writer-queue.ts': ['runQueuedStoreWrite'],
        'src/state/openclaw-agent-db.paths.ts': ['resolveOpenClawAgentSqlitePath'],
      });
      throw Error('undeclared SDK import: ' + specifier);
    }
    if (specifier.startsWith('.')) {
      const target = this.relative(specifier, importer);
      if (Object.hasOwn(unrelated, target)) {
        this.sourceRecord(target);
        return this.port('unrelated-registration:' + target, unrelated[target], this.requestedNames(importer, specifier), [target]);
      }
      if (target === 'src/logging/subsystem.ts') {
        this.sourceRecord(target);
        return this.port('subsystem-observation', loggerCode, ['createSubsystemLogger'], [target]);
      }
      if (target === 'src/config/paths.ts') return this.reexports('absolute-state-dir', {
        'src/config/state-dir.ts': ['resolveStateDir'],
      });
      if (deferredSources.has(target)) return this.deferred(importer, specifier, target);
      return this.source(target);
    }
    throw Error(`undeclared import: ${importer}:${specifier}`);
  }

  transport() {
    return this.port('real-sqlite-worker-transport', transportCode,
      ['installTransport', 'openOpenClawAgentSqliteWorkerStoreV2', 'resolveRuntimeWorkerUrl'], [workerSource]);
  }

  async evaluateModule(module) {
    if (module.status === 'unlinked') await module.link((specifier, owner) => {
      // The supplied sqlite-runtime barrel adds only its transport export to original leaves.
      return this.import(specifier, owner);
    });
    if (module.status === 'linked') await module.evaluate({ timeout: 10_000 });
    assert.equal(module.status, 'evaluated', module.identifier);
    return module;
  }

  async load(path) { return this.evaluateModule(this.source(path)); }

  async run(name, code) {
    const module = this.port('driver:' + name, code);
    await this.evaluateModule(module);
    return module.namespace;
  }
}

function verifyKysely(root) {
  const artifact = JSON.parse(readFileSync(artifactPath));
  assert.equal(artifact.name, 'kysely');
  assert.equal(artifact.version, '0.29.6');
  assert.equal(artifact.integrity, 'sha512-hHaB8C/rfzDDtr/t8YZwxAuPJTT0zHyaPoVzcXwDYhYNAgH/4sIfVhi/XLLIY+bL/FqaIJnjATDbi8ObSELmxg==');
  assert.equal(artifact.archiveSha256, '02c79d44103b2ea05effce404448ca3b749f2daabff2343397b44ea2cdf328a3');
  artifact.packageRoot = realpathSync(artifact.packageRoot);
  const referencePackage = JSON.parse(readFileSync(join(root, 'package.json')));
  assert.equal(referencePackage.dependencies.kysely, artifact.version);
  const lock = readFileSync(join(root, 'pnpm-lock.yaml'), 'utf8');
  assert.ok(lock.includes(`  kysely@${artifact.version}:\n    resolution: {integrity: ${artifact.integrity}}`));
  const manifest = JSON.parse(readFileSync(join(artifact.packageRoot, 'package.json')));
  assert.equal(manifest.name, artifact.name);
  assert.equal(manifest.version, artifact.version);
  assert.equal(manifest.exports['.'].default, './dist/index.js');
  assert.ok(artifact.files.LICENSE);
  for (const [path, sha256] of Object.entries(artifact.files)) {
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const actual = realpathSync(join(artifact.packageRoot, path));
    assert.ok(inside(artifact.packageRoot, actual));
    assert.equal(hash(readFileSync(actual)), sha256, 'kysely/' + path);
  }
  return artifact;
}

export async function captureStandingIntents(sourceRoot = fixedRoot) {
  const root = realpathSync(sourceRoot);
  assert.equal(root, fixedRoot);
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const before = verifyTree(root);
  const artifact = verifyKysely(root);
  const stateDir = await mkdtemp(join(tmpdir(), 'synapsis-intent297-reference-'));
  const harness = new StandingIntentHarness(root, before.tracked, artifact, stateDir);
  let receipt;
  try {
    const inputs = harness.port('fixed-clock-registration-manual-scheduler', inputCode, ['installInputs']);
    await harness.evaluateModule(inputs);
    inputs.namespace.installInputs(stateDir);
    const transport = harness.transport();
    await harness.evaluateModule(transport);
    transport.namespace.installTransport();
    const worker = await harness.load(workerSource);
    harness.context.__bindBackend = worker.namespace.bindSqliteWorkerBackend;

    // The supplied SDK barrel keeps queue/path exports original and only supplies transport.
    const originalImport = harness.import.bind(harness);
    harness.import = async (specifier, owner) => {
      if (specifier === 'openclaw/plugin-sdk/sqlite-runtime') {
        return harness.port('original-queue-path-plus-supplied-transport', `
export {runQueuedStoreWrite} from 'capture:source:src/shared/store-writer-queue.ts';
export {resolveOpenClawAgentSqlitePath} from 'capture:source:src/state/openclaw-agent-db.paths.ts';
export {openOpenClawAgentSqliteWorkerStoreV2} from 'capture:transport';`,
        ['runQueuedStoreWrite', 'resolveOpenClawAgentSqlitePath', 'openOpenClawAgentSqliteWorkerStoreV2'],
        ['src/shared/store-writer-queue.ts', 'src/state/openclaw-agent-db.paths.ts']);
      }
      if (specifier === 'capture:transport') return transport;
      return originalImport(specifier, owner);
    };
    const plugin = await harness.load(entry);
    harness.context.__plugin = plugin.namespace.default;
    await harness.run('register-and-start', `
__plugin.register(__api);
const registration=__registeredTools.find(row=>row.options.names.includes('intent'));
if(!registration||registration.factory.contextVersion!==2)throw Error('original intent registration missing');
globalThis.__intentFactory=registration.factory;
globalThis.__tool=registration.factory.create({...__input,config:__config,assertInvocationCurrent(){__observe('assertInvocationCurrent');}});
globalThis.__hook=__registeredHooks.find(row=>row.name==='before_prompt_build').callback;
globalThis.__service=__registeredServices.find(row=>row.id==='memory-core-standing-intents');
await __service.start({config:__config,scheduler:__scheduler,logger:__api.logger});
__maintenance.started=true;
await __drainDue();
export const registrationResult={contextVersion:registration.factory.contextVersion,names:registration.options.names,
 workspaceAccess:registration.options.workspaceAccess,hook:'before_prompt_build'};
export const definition={label:__tool.label,name:__tool.name,description:__tool.description,parameters:__tool.parameters,
 prepareArgumentsPresent:typeof __tool.prepareArguments==='function',executePresent:typeof __tool.execute==='function'};
`);
    const registration = plain(harness.modules.get('capture:port:driver:register-and-start').namespace.registrationResult);
    const definition = plain(harness.modules.get('capture:port:driver:register-and-start').namespace.definition);
    const observations = [], hooks = [], states = [], rawCreates = [];
    const invoke = async (id, args) => {
      harness.context.__arguments = plain(args);
      harness.context.__callId = id;
      const module = await harness.run(id, `
const argumentsBefore=structuredClone(__arguments);
const prepared=__tool.prepareArguments(__arguments);
const result=await __tool.execute(__callId,prepared);
await __drainDue();
export const observation={id:__callId,argumentsBefore,argumentsAfter:__arguments,prepared,result};
`);
      const observation = plain(module.observation);
      observations.push(observation);
      return observation;
    };
    const first = await invoke('create-default', {
      action: 'create', description: ' Review the deployment checklist. ',
      triggerKeywords: [' Deploy ', 'deploy', 'release check'],
    });
    rawCreates.push({ id: first.id, result: first.result,
      storedRow: plain(harness.context.__inspectRows()).find(row => row.id === first.result.details.intent.id) });
    harness.context.__clock = 1800000001000;
    const second = await invoke('create-conversation', {
      action: 'create', description: 'Review the release notes.', triggerKeywords: ['RELEASE check'],
      scope: 'conversation', maxFires: 2, cooldownSeconds: 60, expiresAt: '2027-01-18T08:00:00.000Z',
    });
    rawCreates.push({ id: second.id, result: second.result,
      storedRow: plain(harness.context.__inspectRows()).find(row => row.id === second.result.details.intent.id) });
    const armed = await invoke('list-armed', { action: 'list' });
    states.push({ id: 'armed', intents: armed.result.details.intents });
    const hookContext = { trigger: 'user', sessionKey: 'agent:agent297:source', sessionId: 'source-session297',
      channel: 'webchat', messageProvider: 'webchat', channelId: 'conversation297', senderId: 'synapsis:operator' };
    const match = async (id, prompt) => {
      harness.context.__hookInput = { id, prompt, context: hookContext };
      const result = await harness.run('hook-' + id, `
const {id,prompt,context}=__hookInput;
const result=await __hook({prompt},{...context,hookInvocation:{assertActive(){__observe('hook.assertActive');}}});
await __drainDue();
export const observation={id,prompt,context,result};
`);
      hooks.push(plain(result.observation));
    };
    harness.context.__clock = 1800000002000;
    await match('first', 'Let us deploy, then do the release check.');
    const fired = await invoke('list-fired', { action: 'list' });
    states.push({ id: 'fired', intents: fired.result.details.intents });
    harness.context.__clock = 1800086402000;
    await harness.run('advance-due', 'await __drainDue();');
    await match('rearmed', 'The check for the release follows deploy today.');
    const final = await invoke('list-final', { action: 'list' });
    states.push({ id: 'final', intents: final.result.details.intents });
    const rowsBeforeClose = plain(harness.context.__inspectRows());
    const schema = plain(harness.context.__inspectSchema());
    const databasePath = harness.context.__physical.path;
    await harness.run('stop-and-close', `
__service.stop();__maintenance.stopped=true;__maintenance.pendingAfterStop=__jobs.size;
__closePhysical();
`);
    assert.equal(harness.context.__physical, undefined);

    // A distinct VM recreates the original facade, backend and all connection-local caches.
    const reopened = new StandingIntentHarness(root, before.tracked, artifact, stateDir);
    try {
      const freshInputs = reopened.port('fixed-clock-registration-manual-scheduler', inputCode, ['installInputs']);
      await reopened.evaluateModule(freshInputs);
      freshInputs.namespace.installInputs(stateDir);
      reopened.context.__clock = 1800086402000;
      const freshTransport = reopened.transport();
      await reopened.evaluateModule(freshTransport);
      freshTransport.namespace.installTransport();
      reopened.context.__bindBackend = (await reopened.load(workerSource)).namespace.bindSqliteWorkerBackend;
      const freshImport = reopened.import.bind(reopened);
      reopened.import = async (specifier, owner) => {
        if (specifier === 'openclaw/plugin-sdk/sqlite-runtime') return reopened.port('original-queue-path-plus-supplied-transport', `
export {runQueuedStoreWrite} from 'capture:source:src/shared/store-writer-queue.ts';
export {resolveOpenClawAgentSqlitePath} from 'capture:source:src/state/openclaw-agent-db.paths.ts';
export {openOpenClawAgentSqliteWorkerStoreV2} from 'capture:transport';`,
        ['runQueuedStoreWrite', 'resolveOpenClawAgentSqlitePath', 'openOpenClawAgentSqliteWorkerStoreV2'],
        ['src/shared/store-writer-queue.ts', 'src/state/openclaw-agent-db.paths.ts']);
        if (specifier === 'capture:transport') return freshTransport;
        return freshImport(specifier, owner);
      };
      reopened.context.__plugin = (await reopened.load(entry)).namespace.default;
      const result = await reopened.run('reopen-list', `
__plugin.register(__api);
const registration=__registeredTools.find(row=>row.options.names.includes('intent'));
const tool=registration.factory.create({...__input,config:__config,assertInvocationCurrent(){__observe('assertInvocationCurrent');}});
const args={action:'list'},argumentsBefore=structuredClone(args),prepared=tool.prepareArguments(args);
const result=await tool.execute('reopen-list',prepared);
export const observation={id:'reopen-list',argumentsBefore,argumentsAfter:args,prepared,result};
`);
      const observation = plain(result.observation);
      observations.push(observation);
      states.push({ id: 'reopened', intents: observation.result.details.intents });
      const rawReopenedRows = plain(reopened.context.__inspectRows());
      assert.equal(reopened.context.__physical.path, databasePath);
      assert.deepEqual(rawReopenedRows, rowsBeforeClose);
      await reopened.run('reopen-close', '__closePhysical();');
      assert.equal(reopened.context.__physical, undefined);
      assert.deepEqual(plain(harness.context.__deferredCalls), []);
      assert.deepEqual(plain(reopened.context.__deferredCalls), []);

      const ids = rawCreates.map((row, index) => {
        const actual = row.result.details.intent.id;
        assert.match(actual, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
        assert.equal(actual, row.storedRow.id);
        assert.deepEqual(JSON.parse(row.result.content[0].text), row.result.details);
        assert.equal(rawReopenedRows[index].id, actual);
        return { actual, normalized: 'intent-' + String(index + 1).padStart(2, '0') };
      });
      assert.notEqual(ids[0].actual, ids[1].actual);
      const normalize = value => {
        let serialized = JSON.stringify(value);
        for (const { actual, normalized } of ids) serialized = serialized.replaceAll(actual, normalized);
        return JSON.parse(serialized);
      };
      for (const [path, record] of reopened.records) {
        const existing = harness.records.get(path);
        if (!existing || record.executed) harness.records.set(path, record);
      }
      for (const [key, port] of reopened.ports) {
        if (harness.ports.has(key)) assert.equal(harness.ports.get(key).sha256, port.sha256);
        else harness.ports.set(key, port);
      }
      receipt = {
        schemaVersion: 1, referencePin: STANDING_INTENTS_PIN,
        exporter: { path: 'scripts/openclaw/capture-standing-intents.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
        runtime: { version: process.versions.node, executable: realpathSync(process.execPath), sha256: hash(readFileSync(process.execPath)) },
        sourceTree: { before: before.receipt, after: null },
        sourceRecords: [...harness.records.values()].sort((a, b) => a.path.localeCompare(b.path)),
        dependencies: { kysely: { name: artifact.name, version: artifact.version, integrity: artifact.integrity,
          archiveSha256: artifact.archiveSha256, root: artifact.packageRoot,
          files: Object.entries(artifact.files).map(([path, sha256]) => ({ path, sha256 })) },
        externalPorts: [...harness.ports.values()] },
        registration, definition, observations: normalize(observations), hooks: normalize(hooks), states: normalize(states),
        maintenance: plain(harness.context.__maintenance),
        persistence: { fileBacked: true, databasePath, closedBeforeReopen: true, reopenedWithFreshBackend: true,
          connectionsOpened: harness.context.__opened + reopened.context.__opened,
          connectionsClosed: harness.context.__closed + reopened.context.__closed,
          schema, sql: plain([...harness.context.__sql, ...reopened.context.__sql]),
          rowsBeforeClose: normalize(rowsBeforeClose), rowsAfterReopen: normalize(rawReopenedRows), removedAfterCapture: false },
        normalization: { ids, rawCreates, rawReopenedRows },
        boundaries: { sourceDatabaseExecuted: true, sourceKernelExecuted: true, sourceFactoryExecuted: true,
          sourcePromptHookExecuted: true, suppliedWorkerTransport: true, sourceCanonicalWorkerExecuted: false, hostProductExecuted: false },
        exclusions: ['Cancellation action source/schema retained; cancellation execution unrun',
          'Security, permissions, auth/TLS unrun', 'Negative, error, failure, crash and mixed suites unrun',
          'Budget, truncation, eviction, size/count threshold and race qualification unrun',
          'Real provider and production product qualification unrun',
          'Canonical OpenClaw executor, worker process lifecycle and Synapsis native host execution unrun'],
      };
    } finally {
      if (reopened.context.__physical) reopened.context.__closePhysical();
    }
  } finally {
    if (harness.context.__physical) harness.context.__closePhysical();
    await rm(stateDir, { recursive: true, force: true });
  }
  assert.ok(receipt);
  receipt.persistence.removedAfterCapture = true;
  assert.equal(receipt.persistence.connectionsOpened, receipt.persistence.connectionsClosed);
  const after = verifyTree(root);
  assert.deepEqual(after.receipt, before.receipt);
  receipt.sourceTree.after = after.receipt;
  verifyKysely(root);
  return receipt;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.stdout.write(JSON.stringify(await captureStandingIntents(process.argv[2] ?? fixedRoot), null, 2) + '\n');
}
