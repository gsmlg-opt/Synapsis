// Whole pinned Goals/progress factories and algorithms with explicit supplied-success boundaries.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto, { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const GOAL_TOOLS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'src/agents/tools/goal-tools.ts';
const goals = 'src/config/sessions/goals.ts';
const progress = 'src/agents/tools/progress-card-tool.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [entry, goals, progress,
  'src/config/sessions/goals-transitions.ts', 'src/config/sessions/types.ts',
  'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tool-input-error.ts',
  'src/agents/schema/string-enum.ts', 'src/agents/tools/progress-card-tool-outcome.ts',
  'src/session-cards/progress-card-input.ts', 'src/infra/unicode-visibility.ts', 'src/param-key.ts',
  'src/utils/token-format.ts', 'packages/session-url-contract/src/session-key-normalization.ts',
  'packages/session-url-contract/src/session-key.ts',
  ...['progress-card-limits','client-info','secret-ref-contract','session-limits',
    'schema/progress-card','schema/closed-object','schema/primitives','schema/string-literal-union',
    'schema/user-profile-constants'].map(path => 'packages/gateway-protocol/src/' + path + '.ts'),
  ...['agent-id','result','number-coercion','string-coerce','record-coerce','string-normalization',
    'stable-stringify','format','expect'].map(path => 'packages/normalization-core/src/' + path + '.ts'),
];

// These modules are supplied boundaries, never a persistence backend or production owner.
const facadeCode = {
  'src/config/sessions/paths.ts': {
    resolveSessionStorePathCore: `export function resolveSessionStorePathCore(template,options){
      __calls.push({callback:'resolveSessionStorePathCore',template,options:__plain(options)});
      return __input.storePath;
    }`,
  },
  'src/config/sessions/session-accessor.ts': {
    patchSessionEntryCore: `export async function patchSessionEntryCore(scope,patch,options){
      const before=__plain(__snapshot);const delta=await patch(__plain(__snapshot));
      const result=delta?{...__snapshot,...delta}:__snapshot;
      __calls.push({callback:'patchSessionEntryCore',scope:__plain(scope),options:options?__plain(options):null,
        before,patch:__plain(delta),returnedSnapshot:__plain(result),boundary:'supplied successful patch callback, no persistence'});
      __snapshot=__plain(result);return __plain(result);
    }`,
  },
  'src/config/sessions/session-entry-read-runtime.ts': {
    withSessionEntryReadOnlyInWorker: `export async function withSessionEntryReadOnlyInWorker(scope,prepare,consume){
      __calls.push({callback:'withSessionEntryReadOnlyInWorker',scope:__plain(scope),snapshot:__plain(__snapshot),
        boundary:'supplied successful read, no worker'});
      prepare();return consume({ok:true,value:__plain(__snapshot)});
    }`,
  },
  'src/sessions/session-state-events.ts': {
    recordSessionGoalChanged: `export async function recordSessionGoalChanged(options){
      __calls.push({callback:'recordSessionGoalChanged',options:__plain(options),boundary:'recorded call only, no event persistence or publication'});
    }`,
  },
  'src/agents/tools/in-process-gateway.ts': {
    callInProcessGatewayTool: `export async function callInProcessGatewayTool(method,params){
      __gatewayCalls.push({method,params:__plain(params)});return __plain(__input.gatewayResult);
    }`,
  },
};
const deferredCode = {
  'packages/media-core/src/mime.ts': ['detectMime'],
  'src/infra/fs-safe.ts': ['readLocalFileSafely'],
};
const hostCode = `
globalThis.__plain=value=>JSON.parse(JSON.stringify(value));
globalThis.__deferredCalls=[];
globalThis.__calls=[];
globalThis.__gatewayCalls=[];
globalThis.__snapshot=undefined;
globalThis.__input=undefined;
`;
function git(root,args){
  return execFileSync('git',['-C',root,...args],{encoding:'utf8',timeout:30000,maxBuffer:64*1024*1024,
    env:{...process.env,GIT_OPTIONAL_LOCKS:'0',GIT_NO_REPLACE_OBJECTS:'1'}}).trimEnd();
}
function checkout(root){
  assert.equal(realpathSync(git(root,['rev-parse','--show-toplevel'])),root);
  assert.equal(git(root,['rev-parse','HEAD']),GOAL_TOOLS_PIN);
  assert.equal(git(root,['status','--porcelain','--untracked-files=no']),'');
  const files=git(root,['ls-tree','-rz','--full-tree',GOAL_TOOLS_PIN]).split('\0').filter(Boolean).map(item=>{
    const [header,path]=item.split('\t');const [mode,type,gitBlob]=header.split(' ');
    assert.equal(type,'blob');assert.ok(['100644','100755','120000'].includes(mode));
    assert.ok(!isAbsolute(path)&&!path.split('/').includes('..'));
    const file=join(root,path);const symlink=lstatSync(file).isSymbolicLink();
    assert.equal(symlink,mode==='120000');assert.ok(realpathSync(file).startsWith(root+sep));
    const bytes=symlink?Buffer.from(readlinkSync(file)):readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),gitBlob,path);
    return {path,gitBlob,sha256:hash(bytes)};
  });
  assert.equal(files.length,58558);
  return {tracked:new Map(files.map(row=>[row.path,row.sha256])),receipt:{verified:true,commit:GOAL_TOOLS_PIN,
    tree:git(root,['rev-parse',`${GOAL_TOOLS_PIN}^{tree}`]),verifiedTrackedFiles:files.length,filesSha256:hash(JSON.stringify(files))}};
}
class GoalToolsHarness extends FactoryHarness {
  constructor(root,tracked){
    super(root,tracked,{allowedSources:wholeSources});
    this.context=vm.createContext({Buffer,TextEncoder,TextDecoder,__platform:{crypto}},
      {codeGeneration:{strings:false,wasm:false}});
    new vm.Script(hostCode).runInContext(this.context,{timeout:1000});
    this.sourceRecords=new Map();this.importBindings=new Map();
  }
  record(path){
    const sha256=this.tracked.get(path);assert.ok(sha256,path);
    assert.equal(hash(readFileSync(join(this.root,path))),sha256,path);
    if(!this.sourceRecords.has(path))this.sourceRecords.set(path,{path,sha256,executed:false,originalSourceExecuted:false,provenanceOnly:true});
  }
  module(file){
    if(this.modules.has(file))return this.modules.get(file);
    if(this.typeboxRoot&&file.startsWith(this.typeboxRoot+sep))return super.module(file);
    const path=relative(this.root,file);assert.ok(wholeSources.includes(path),path);this.record(path);
    const executable=stripTypeScriptTypes(readFileSync(file,'utf8'),{mode:'transform',sourceMap:false});
    this.sourceRecords.set(path,{path,sha256:this.tracked.get(path),executed:true,originalSourceExecuted:true,
      wholeModule:true,transformation,executableSha256:hash(executable)});
    const mod=new vm.SourceTextModule(executable,{context:this.context,identifier:file,
      importModuleDynamically:()=>{this.context.__deferredCalls.push('dynamic import');throw Error('undeclared dynamic import');}});
    this.modules.set(file,mod);return mod;
  }
  binding(importer,specifier,kind,exports,generatedCode,sources=[]){
    for(const path of sources)this.record(path);
    const key=importer+':'+specifier;
    if(!this.importBindings.has(key))this.importBindings.set(key,{importer,specifier,kind,exports,generatedCode,
      generatedSha256:hash(generatedCode),sources:sources.map(path=>({path,sha256:this.tracked.get(path)})),
      originalSourceExecuted:kind==='whole-source-export-alias'});
    return this.synthetic('capture:goal-tools:'+key,generatedCode);
  }
  alias(importer,specifier,source,exports,barrel){
    const code=`export {${exports.join(',')}} from ${JSON.stringify('capture:source:'+source)};`;
    return this.binding(importer,specifier,'whole-source-export-alias',exports,code,[source,...(barrel?[barrel]:[])]);
  }
  import(specifier,parent){
    const importer=relative(this.root,parent);
    if(parent.startsWith('capture:goal-tools:')&&specifier.startsWith('capture:source:'))return this.module(join(this.root,specifier.slice('capture:source:'.length)));
    if(specifier==='typebox'){
      const file=super.resolve(specifier,parent);const key=importer+':typebox';
      if(!this.importBindings.has(key))this.importBindings.set(key,{importer,specifier,kind:'actual-pinned-package',version:this.typeboxVersion,
        path:'typebox/'+relative(this.typeboxRoot,file),sha256:hash(readFileSync(file)),packageSha256:this.dependencies.get('typebox/package.json').sha256});
      return this.module(file);
    }
    if(this.typeboxRoot&&parent.startsWith(this.typeboxRoot+sep)){
      const file=super.resolve(specifier,parent);const key=importer+':'+specifier;
      if(!this.importBindings.has(key))this.importBindings.set(key,{importer:'typebox/'+relative(this.typeboxRoot,parent),specifier,
        kind:'actual-package-module',path:'typebox/'+relative(this.typeboxRoot,file),sha256:hash(readFileSync(file))});
      return this.module(file);
    }
    if(specifier==='node:crypto')return this.binding(importer,specifier,'actual-platform-builtin',['default'],
      'export default globalThis.__platform.crypto;');
    const normalization='@openclaw/normalization-core/';
    if(specifier.startsWith(normalization)){
      const path='packages/normalization-core/src/'+specifier.slice(normalization.length)+'.ts';
      assert.ok(wholeSources.includes(path),path);return this.source(importer,specifier,path);
    }
    if(specifier==='@openclaw/normalization-core'){
      const path=importer==='src/utils/token-format.ts'?'format':'stable-stringify';
      return this.alias(importer,specifier,'packages/normalization-core/src/'+path+'.ts',
        [path==='format'?'formatCompactTokenCount':'stableStringify'],'packages/normalization-core/src/index.ts');
    }
    if(importer===entry&&specifier==='../../routing/session-key.js'){
      const a='packages/normalization-core/src/agent-id.ts';const b='packages/session-url-contract/src/session-key-normalization.ts';
      return this.binding(importer,specifier,'whole-source-export-alias',['normalizeAgentId','parseAgentSessionKey'],
        `export {normalizeAgentId} from ${JSON.stringify('capture:source:'+a)};\nexport {parseAgentSessionKey} from ${JSON.stringify('capture:source:'+b)};`,
        [a,b,'src/routing/session-key.ts']);
    }
    if(importer===entry&&specifier==='../schema/typebox.js')return this.alias(importer,specifier,
      'src/agents/schema/string-enum.ts',['stringEnum'],'src/agents/schema/typebox.ts');
    if(importer===progress&&specifier==='../../../packages/gateway-protocol/src/index.js')return this.alias(importer,specifier,
      'packages/gateway-protocol/src/schema/progress-card.ts',['PROGRESS_CARD_MAX_STEPS','ProgressCardStepSchema'],
      'packages/gateway-protocol/src/index.ts');
    let path;
    if(specifier==='@openclaw/media-core/mime')path='packages/media-core/src/mime.ts';
    else if(specifier.startsWith('.'))path=relative(this.root,resolve(dirname(parent),specifier)).replace(/\.js$/,'.ts');
    if(path&&facadeCode[path]){
      const exports=Object.keys(facadeCode[path]);
      return this.binding(importer,specifier,'explicit-supplied-success-boundary',exports,Object.values(facadeCode[path]).join('\n'),[path]);
    }
    if(path&&deferredCode[path]){
      const exports=deferredCode[path];const code=exports.map(name=>`export function ${name}(){__deferredCalls.push(${JSON.stringify(path+':'+name)});throw Error('uninvoked boundary');}`).join('\n');
      return this.binding(importer,specifier,'uninvoked-throwing-boundary',exports,code,[path]);
    }
    if(path&&wholeSources.includes(path))return this.source(importer,specifier,path);
    throw Error(`Undeclared Goal tools import: ${importer} -> ${specifier}`);
  }
  source(importer,specifier,path){
    const key=importer+':'+specifier;
    if(!this.importBindings.has(key))this.importBindings.set(key,{importer,specifier,kind:'whole-source-module',source:path,sourceSha256:this.tracked.get(path)});
    return this.module(join(this.root,path));
  }
  run(code){return new vm.Script(code).runInContext(this.context,{timeout:1000});}
}

const session={sessionId:'supplied-session',updatedAt:1700000000000,totalTokens:125,totalTokensFresh:true,totalTokensVersion:1};
const suppliedGoal={schemaVersion:1,id:'supplied-goal',objective:'Finish supplied objective 雪😀',status:'active',createdAt:1700000000000,
  updatedAt:1700000000000,tokenStart:100,tokenStartFresh:true,tokensUsed:0,tokenBudget:1000,continuationTurns:0};
const factoryOptions={agentSessionKey:'agent:fixture:main',sessionAgentId:'fixture',config:{session:{store:'/supplied/{agentId}/sessions.json'}}};
function vectors(){
  const objective='  Finish supplied objective 雪😀  ';
  const plan=[{step:'Inspect supplied evidence',status:'completed'},{step:'Review supplied result',status:'in_progress'}];
  const done=plan.map(step=>({...step,status:'completed'}));
  const card=(revision,markdown,steps)=>({card:{sessionKey:'agent:fixture:main',revision,updatedAt:1700000000000,
    ...(markdown?{markdown}:{}),...(steps?{steps}: {})}});
  return [
    {id:'create-no-budget',tool:'create_goal',arguments:{objective},snapshot:session},
    {id:'create-positive-budget',tool:'create_goal',arguments:{objective,token_budget:1000},snapshot:session},
    {id:'create-null-budget',tool:'create_goal',arguments:{objective,token_budget:null},snapshot:session},
    {id:'get-missing',tool:'get_goal',arguments:{},snapshot:session},
    {id:'get-active',tool:'get_goal',arguments:{},snapshot:{...session,goal:suppliedGoal}},
    {id:'get-updated',tool:'get_goal',arguments:{},snapshot:{...session,goal:{...suppliedGoal,status:'complete',completedAt:1700000000000}}},
    ...['complete','blocked'].map(status=>({id:'update-'+status,tool:'update_goal',arguments:{status,note:'Supplied ordinary status note'},snapshot:{...session,goal:suppliedGoal}})),
    {id:'update-complete-repeat',tool:'update_goal',arguments:{status:'complete',note:'Supplied ordinary status note'},
      snapshot:{...session,goal:{...suppliedGoal,status:'complete',completedAt:1700000000000}}},
    {id:'progress-markdown',tool:'progress_card',arguments:{markdown:'Reviewed 2 of 4 supplied files.'},gatewayResult:card(1,'Reviewed 2 of 4 supplied files.')},
    {id:'progress-plan',tool:'progress_card',arguments:{plan},gatewayResult:card(2,undefined,plan)},
    {id:'progress-update',tool:'progress_card',arguments:{markdown:'Reviewed all 4 supplied files.',plan:done},gatewayResult:card(3,'Reviewed all 4 supplied files.',done)},
    {id:'progress-clear',tool:'progress_card',arguments:{markdown:'',plan:[]},gatewayResult:{card:null}},
  ];
}
// Canonicalize observed generated values only after original algorithms finish. Every occurrence,
// including JSON result text, receives the same per-vector substitution. No source/global clock edits.
function canonicalize(observed){
  const substitutions=[];
  if(observed.id.startsWith('create-')){
    const goal=observed.result.details.goal;
    assert.match(goal.id,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
    assert.equal(goal.createdAt,goal.updatedAt);assert.ok(Number.isSafeInteger(goal.createdAt));
    assert.equal(observed.snapshotAfter.goal.id,goal.id);
    substitutions.push([goal.id,observed.id+':generated-goal-uuid'],[goal.createdAt,1800000000000]);
  }else if(observed.id.startsWith('update-')){
    const goal=observed.result.details.goal;assert.ok(Number.isSafeInteger(goal.updatedAt));
    if(observed.snapshotBefore.goal.completedAt!==undefined&&goal.status==='complete'){
      assert.equal(goal.completedAt,observed.snapshotBefore.goal.completedAt);
    }else assert.equal(goal[goal.status==='complete'?'completedAt':'blockedAt'],goal.updatedAt);
    substitutions.push([goal.updatedAt,1800000000000]);
  }
  const visit=value=>{
    for(const [from,to] of substitutions)if(value===from)return to;
    if(typeof value==='string')return substitutions.reduce((text,[from,to])=>text.split(String(from)).join(String(to)),value);
    if(Array.isArray(value))return value.map(visit);
    if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,visit(item)]));
    return value;
  };
  return visit(observed);
}
async function deadline(promise){
  let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Goal callback deadline')),5000);})]);}
  finally{clearTimeout(timer);}
}
export async function captureGoalTools(source=fixedRoot){
  assert.equal(process.versions.node,'24.22.1');assert.equal(realpathSync(process.execPath),realpathSync(fixedNode));
  const root=realpathSync(source);assert.equal(root,fixedRoot);const before=checkout(root);
  const harness=new GoalToolsHarness(root,before.tracked);
  await harness.load(entry);harness.context.__goalFactories=harness.context.__exports;
  await harness.load(progress);harness.context.__progressFactory=harness.context.__exports;
  await harness.load('src/agents/tools/progress-card-tool-outcome.ts');harness.context.__outcomes=harness.context.__exports;
  await harness.load('src/config/sessions/goals-transitions.ts');harness.context.__transitions=harness.context.__exports;
  await harness.load('packages/gateway-protocol/src/schema/progress-card.ts');harness.context.__schemas=harness.context.__exports;
  harness.context.__factoryOptions=plain(factoryOptions);
  harness.run(`globalThis.__tools={get_goal:__goalFactories.createGetGoalTool(__factoryOptions),
    create_goal:__goalFactories.createCreateGoalTool(__factoryOptions),update_goal:__goalFactories.createUpdateGoalTool(__factoryOptions),
    progress_card:__progressFactory.createProgressCardTool({agentSessionKey:'agent:fixture:main',agentId:'fixture',onPlanSaved:value=>__planSaved.push(value)})};`);
  const tools=harness.call(`Object.fromEntries(Object.entries(__tools).map(([name,tool])=>[name,
    Object.fromEntries(Object.entries(tool).filter(([,value])=>typeof value!=='function'))]))`);
  const observations=[];
  const generatedUUIDs=new Set();
  for(const input of vectors()){
    harness.context.__serializedInput=JSON.stringify({...input,storePath:'/supplied/fixture/sessions.json'});
    harness.run(`globalThis.__input=JSON.parse(__serializedInput);globalThis.__snapshot=__input.snapshot;
      globalThis.__calls=[];globalThis.__gatewayCalls=[];globalThis.__planSaved=[];globalThis.__params=__plain(__input.arguments);`);
    const result=await deadline(harness.run(`__tools[__input.tool].execute('supplied-call',__params)`));
    harness.context.__result=result;
    const observed=harness.call(`({id:__input.id,tool:__input.tool,arguments:__input.arguments,argumentsAfter:__params,
      factoryOptions:__input.tool==='progress_card'?{agentSessionKey:'agent:fixture:main',agentId:'fixture'}:__factoryOptions,
      context:'explicit supplied primary root factory context; no assembly or eligibility execution',
      snapshotBefore:__input.snapshot,snapshotAfter:__snapshot,result:__result,calls:__calls,gatewayCalls:__gatewayCalls,
      gatewayResult:__input.gatewayResult,planSaved:__planSaved,outcome:__outcomes.getProgressCardToolOutcome(__result)})`);
    if(input.id.startsWith('create-')){
      const generatedUUID=observed.result.details.goal.id;
      assert.equal(generatedUUIDs.has(generatedUUID),false,'distinct original UUIDs across independent creates');
      generatedUUIDs.add(generatedUUID);
    }
    observations.push(canonicalize(observed));
  }
  harness.context.__accountingEntry=plain({...session,goal:suppliedGoal});
  const accounting=harness.call(`[
    {id:'fresh-usage',entry:__accountingEntry,goal:__transitions.accountSessionGoalUsage(__accountingEntry,1700000000100)},
    {id:'unbudgeted-usage',entry:{...__accountingEntry,goal:{...__accountingEntry.goal,tokenBudget:undefined}},
      goal:__transitions.accountSessionGoalUsage({...__accountingEntry,goal:{...__accountingEntry.goal,tokenBudget:undefined}},1700000000100)}]`);
  const sourceRecords=[...harness.sourceRecords.values()].sort((a,b)=>a.path.localeCompare(b.path));
  const after=checkout(root);assert.deepEqual(before.receipt,after.receipt);
  return {schemaVersion:1,referencePin:GOAL_TOOLS_PIN,
    exporter:{path:'scripts/openclaw/capture-goal-tools.mjs',sha256:hash(readFileSync(fileURLToPath(import.meta.url)))},
    harness:{path:'scripts/openclaw/capture-recipes.mjs',sha256:hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url)))},
    runtime:{executable:fixedNode,version:process.versions.node,sha256:hash(readFileSync(fixedNode))},
    sourceTree:{before:before.receipt,after:after.receipt},transformation,sourceRecords,importBindings:[...harness.importBindings.values()],
    typebox:{version:harness.typeboxVersion,root:harness.typeboxRoot,files:[...harness.dependencies.values()].sort((a,b)=>a.path.localeCompare(b.path))},
    host:{generatedCode:hostCode,sha256:hash(hostCode)},tools,
    schemas:harness.call(`({progressStep:__schemas.ProgressCardStepSchema,progressPut:__schemas.ProgressCardPutParamsSchema,progressResult:__schemas.ProgressCardPutResultSchema})`),
    observations,accounting,deferredCalls:harness.call('__deferredCalls'),
    canonicalization:{strategy:'post-execution generated UUID and timestamp substitution',generatedUUID:'<vector id>:generated-goal-uuid',generatedTimestamp:1800000000000,
      scope:'Only create UUID/create time and update time plus identical occurrences in calls, snapshots and JSON text; original crypto and Date execute unchanged.',
      checks:'UUID v4 format and cross-create uniqueness, safe integer time, created/updated equality, patch/result identity, status timestamp equality and repeated-complete timestamp preservation checked before substitution.',
      limits:'Vectors use independent supplied snapshots. UUID replacements retain per-vector equality and distinctness across create vectors. Timestamp substitution preserves observed intra-vector equality; no cross-vector timing, ordering, duration or real-clock claim.'},
    boundaries:{factoryInvoked:true,callbackInvoked:true,productionPersistenceExecuted:false,sqliteWorkerExecuted:false,
      sessionOwnerExecuted:false,gatewayTransportExecuted:false,fullAssemblyExecuted:false,rootEligibilityExecuted:false,
      blockedRuleEnforcementProven:false,networkExecuted:false},limits:[
      'Complete unchanged Goal factories, goals.ts, goals-transitions.ts, types.ts accounting and common/result helpers execute with actual TypeBox1.3.37.',
      'Session snapshots and successful patch/read callbacks are explicit supplied data boundaries. SQLite/worker actor storage, atomicity, ownership, admissions, event/outbox/watch persistence and publication do not execute; sessions.json is a compatibility address, not a JSON backend.',
      'Progress factory/input/outcome and whole actual gateway protocol schema execute. Gateway facade returns an explicitly supplied successful card; call arguments, receipt, onPlanSaved and private outcome are observed, not real gateway ownership, revision storage, broadcasts or UI rendering.',
      'Full-objective completion, explicit requests and the same blocker for three consecutive goal turns remain description obligations, not semantic runtime proof or blocked-rule enforcement.',
      'Only ordinary positive create/get/update, nonexhausted accounting and root progress markdown/plan/update/clear are invoked. No assembly/root eligibility, child/scheduled admission, continuation, provider accounting, real provider/network or excluded negative/error/cancellation/permission behavior executes.',
      'Routing and schema barrels use declared export aliases to whole pure source modules; unrelated common MIME/filesystem imports are uninvoked throwing boundaries. Every supplied/generated binding and original source is recorded.',
      'This independent reference evidence does not activate Synapsis Goal code or unblock production Concord#107 durable CAS integration.',
    ]};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  assert.equal(process.argv.length,4,'usage: capture-goal-tools.mjs source-root output');
  const capture=await captureGoalTools(process.argv[2]);writeFileSync(process.argv[3],JSON.stringify(capture,null,2)+'\n');
  process.stdout.write(JSON.stringify({vectors:capture.observations.length,wholeModules:capture.sourceRecords.filter(row=>row.executed).length})+'\n');
}
