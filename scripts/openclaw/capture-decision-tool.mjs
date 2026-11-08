// Whole pinned Decisions tool factory, contract and successful callback capture.
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

export const DECISION_TOOL_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'src/agents/tools/decision-tool.ts';
const contract = 'src/agents/tools/decision-tool-contract.ts';
const setting = 'src/agents/decision-model-setting.ts';
const refs = 'packages/model-catalog-core/src/model-catalog-refs.ts';
const wholeSources = [entry, contract, setting, refs, 'src/agents/model-ref-profile.ts',
  'packages/model-catalog-core/src/provider-id.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/record-coerce.ts', 'src/decisions/validation-v2.ts',
  'src/decisions/validation.ts', 'src/decisions/validation-common.ts',
  'src/decisions/compatibility.ts', 'src/agents/tools/tool-results.ts'];
const provenancePaths = ['src/decisions/runtime.ts','src/decisions/provider-host.ts',
  'src/decisions/types-v2.ts','src/agents/agent-scope-config.ts','src/config/config.ts',
  'src/plugins/current-plugin-metadata-state.ts','src/plugins/manifest-contract-eligibility.ts',
  'src/plugins/runtime/gateway-request-scope.ts'];
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), DECISION_TOOL_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', DECISION_TOOL_PIN]).split('\0').filter(Boolean).map(item => {
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
    receipt: { verified: true, commit: DECISION_TOOL_PIN, tree: git(root, ['rev-parse', `${DECISION_TOOL_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}



const hostCode = `
globalThis.__deferredCalls=[];
globalThis.__trace=[];
globalThis.__fixture=undefined;
globalThis.__runtimeConfig=undefined;
globalThis.__metadataSnapshot={fixture:true};
globalThis.__manifestPlugins=[];
`;
const runtimeCode = `
export async function evaluateDecisionV2Operation(batch,options,registry,config){
 const f=globalThis.__fixture;
 f.trace.push('evaluate');
 f.evaluateCalls.push({batch:JSON.parse(JSON.stringify(batch)),agentId:options.agentId,purpose:options.purpose,
 rubricVersion:options.rubricVersion,timeoutMs:options.timeoutMs,signalType:options.signal.constructor.name,
 registry:JSON.parse(JSON.stringify(registry)),config:JSON.parse(JSON.stringify(config)),
 selection:globalThis.__selection.resolveDecisionModelSetting(config,options.agentId)});
 return {outcome:JSON.parse(JSON.stringify(f.outcome))};
}
export function completeDecisionEvaluation(evaluation){
 const f=globalThis.__fixture;f.trace.push('complete');f.completeCalls++;
 return evaluation.outcome;
}
`;

class DecisionToolHarness extends FactoryHarness {
  constructor(root, tracked){
    super(root,tracked,{allowedSources:wholeSources});
    this.context=vm.createContext({Buffer,AbortController,TextEncoder,__platform:{createHash,isProxy}},
      {codeGeneration:{strings:false,wasm:false}});
    new vm.Script(hostCode).runInContext(this.context,{timeout:1000});
    this.sourceRecords=new Map();this.importBindings=new Map();
  }
  module(file){
    if(this.modules.has(file))return this.modules.get(file);
    if(this.typeboxRoot && (file===this.typeboxRoot||file.startsWith(this.typeboxRoot+sep)))return super.module(file);
    const source=relative(this.root,file);assert.ok(wholeSources.includes(source),source);
    const bytes=readFileSync(file);assert.equal(hash(bytes),this.tracked.get(source),source);
    const executable=stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false});
    this.loadedFiles.set(source,{path:source,sha256:hash(bytes)});
    this.sourceRecords.set(source,{path:source,sha256:hash(bytes),executed:true,wholeModule:true,
      transformation,executableSha256:hash(executable)});
    const mod=new vm.SourceTextModule(executable,{context:this.context,identifier:file,
      importModuleDynamically:async(specifier)=>{
        assert.equal(source,entry);assert.equal(specifier,'../../decisions/runtime.js');
        this.context.__fixture.trace.push('dynamic-runtime-import');
        const runtime=this.binding(source,specifier,'synthetic-decision-runtime',
          ['evaluateDecisionV2Operation','completeDecisionEvaluation'],runtimeCode,
          {source:'src/decisions/runtime.ts',sourceSha256:this.tracked.get('src/decisions/runtime.ts'),originalSourceExecuted:false});
        if(runtime.status==='unlinked')await runtime.link(()=>{throw Error('runtime facade has no imports');});
        if(runtime.status==='linked')await runtime.evaluate({timeout:1000});
        return runtime;
      }});
    this.modules.set(file,mod);return mod;
  }
  binding(importer,specifier,kind,exports,code,extra={}){
    const key=importer+':'+specifier;
    if(!this.importBindings.has(key))this.importBindings.set(key,{importer,specifier,kind,exports,
      generatedCode:code,generatedSha256:hash(code),...extra});
    return this.synthetic('capture:decision-tool:'+key,code);
  }
  source(importer,specifier,source){
    const key=importer+':'+specifier;
    if(!this.importBindings.has(key))this.importBindings.set(key,{importer,specifier,kind:'whole-source-module',
      source,sourceSha256:this.tracked.get(source)});
    return this.module(join(this.root,source));
  }
  alias(importer,specifier,source,exports){
    return this.binding(importer,specifier,'whole-source-export-alias',exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:'+source)};`,
      {source,sourceSha256:this.tracked.get(source)});
  }
  import(specifier,parent){
    const importer=relative(this.root,parent);
    if(parent.startsWith('capture:decision-tool:')&&specifier.startsWith('capture:source:'))return this.module(join(this.root,specifier.slice('capture:source:'.length)));
    if(specifier==='typebox'){
      const file=super.resolve(specifier,parent);
      if(!this.importBindings.has('typebox'))this.importBindings.set('typebox',{importer,specifier,kind:'actual-pinned-package',
        version:this.typeboxVersion,path:'typebox/'+relative(this.typeboxRoot,file),sha256:hash(readFileSync(file)),
        packageSha256:this.dependencies.get('typebox/package.json').sha256});
      return this.module(file);
    }
    if(this.typeboxRoot&&parent.startsWith(this.typeboxRoot+sep))return super.import(specifier,parent);
    if(specifier==='node:crypto')return this.binding(importer,specifier,'actual-platform-builtin',['createHash'],
      'export const createHash=globalThis.__platform.createHash;');
    if(specifier==='node:util/types')return this.binding(importer,specifier,'actual-platform-builtin',['isProxy'],
      'export const isProxy=globalThis.__platform.isProxy;');
    if(specifier==='@openclaw/model-catalog-core/model-catalog-refs')return this.alias(importer,specifier,refs,['parseProviderModelRef']);
    if(specifier==='@openclaw/normalization-core/string-coerce')return this.alias(importer,specifier,
      'packages/normalization-core/src/string-coerce.ts',['normalizeLowercaseStringOrEmpty']);
    if(specifier==='@openclaw/normalization-core/record-coerce')return this.alias(importer,specifier,
      'packages/normalization-core/src/record-coerce.ts',['asOptionalRecord','isRecord']);
    const facades=[
      [entry,'../../config/config.js','src/config/config.ts',['getRuntimeConfig'],
        `export function getRuntimeConfig(){const f=globalThis.__fixture;f.configReads++;f.trace.push('config-read');return globalThis.__runtimeConfig;}`],
      [entry,'../../plugins/current-plugin-metadata-state.js','src/plugins/current-plugin-metadata-state.ts',['getGatewayPluginMetadataSnapshot'],
        `export function getGatewayPluginMetadataSnapshot(){globalThis.__fixture.trace.push('metadata-read');return globalThis.__metadataSnapshot;}`],
      [entry,'../../plugins/manifest-contract-eligibility.js','src/plugins/manifest-contract-eligibility.ts',['listAvailableManifestContractPlugins'],
        `export function listAvailableManifestContractPlugins(params){const f=globalThis.__fixture;f.manifestCalls++;f.trace.push('manifest-read');f.manifestParams=JSON.parse(JSON.stringify(params));return globalThis.__manifestPlugins;}`],
      [entry,'../../plugins/runtime/gateway-request-scope.js','src/plugins/runtime/gateway-request-scope.ts',['getPluginRegistryForContext'],
        `export function getPluginRegistryForContext(){globalThis.__fixture.trace.push('registry-read');return {fixtureRegistry:'decision-source-success'};}`],
      [setting,'./agent-scope-config.js','src/agents/agent-scope-config.ts',['listAgentEntries','resolveAgentConfig'],
        `export function listAgentEntries(config){return config.agents?.list??[];}
export function resolveAgentConfig(config,agentId){return listAgentEntries(config).find(row=>row.id===agentId);}`],
    ].find(([owner,name])=>owner===importer&&name===specifier);
    if(facades)return this.binding(importer,specifier,'explicit-configuration-metadata-facade',facades[3],facades[4],
      {source:facades[2],sourceSha256:this.tracked.get(facades[2]),originalSourceExecuted:false});
    if(specifier.startsWith('.')){
      const source=relative(this.root,resolve(dirname(parent),specifier)).replace(/.js$/,'.ts');
      if(wholeSources.includes(source))return this.source(importer,specifier,source);
    }
    throw Error(`Undeclared Decision tool import: ${importer} -> ${specifier}`);
  }
  run(code){return new vm.Script(code).runInContext(this.context,{timeout:1000});}
}

const allCapabilities={input:['text','json','image','list'],confidence:'provider-specific',questions:{
  boolean:{probabilities:'boolean',abstention:true,requiresCriteria:true},
  choice:{probabilities:'categorical',abstention:true,minOptions:2,maxOptions:255},
  score:{probabilities:'categorical',abstention:false,minOptions:2,maxOptions:10},
  sort:{probabilities:'none',abstention:false},tags:{probabilities:'independent',abstention:true},
  box:{probabilities:'none',abstention:false}},limits:{maxQuestions:400,image:{maxBytes:4194304,mimeTypes:['image/png','image/jpeg']},
  maxRequestTokens:10000,maxStateAndQuestionTokens:8000,maxInputTokens:5000,inputTokenScope:'encoded-question'}};
const usage={inputTokens:3,outputTokens:0,costUsd:0,units:{unit:'requests',amount:1},raw:{fixture:[1,2]}};
function vectors(){
  const boolean={type:'boolean',instructions:'Is the supplied evidence relevant?',criteria:{true:'Relevant',false:'Other'}};
  const three={check:boolean,route:{type:'choice',instructions:{task:'Choose supplied route'},criteria:{a:null,b:'B'}},
    score:{type:'score',criteria:['Low','High']}};
  const booleanAnswer={type:'boolean',answer:true,probabilityTrue:0.4};
  const base={contractVersion:2,state:{type:'text',text:'Supplied evidence 雪😀'},questions:{q:boolean}};
  const threeAnswers={check:booleanAnswer,route:{type:'choice',choice:'a',probabilities:{a:0.2,b:0.7},confidence:-0.2,metadata:{route:'fixture'}},
    score:{type:'score',score:0.71,probabilities:[0.3,0.69],confidence:null}};
  const make=(id,args,answers,extra={})=>({id,arguments:args,answers,...extra});
  return [
    make('legacy-text',{state:'  Supplied text 雪😀\n',questions:{q:boolean}},{q:booleanAnswer}),
    make('legacy-json-null',{state:null,questions:{q:boolean}},{q:booleanAnswer}),
    make('legacy-json-array',{state:['one',null,{two:2}],questions:{q:boolean}},{q:booleanAnswer}),
    make('v2-text-three',{...base,questions:three},threeAnswers),
    make('v2-tags',{...base,questions:{q:{type:'tags',instructions:['Assign supplied labels'],criteria:{blue:'Blue',red:'Red'}}}},
      {q:{type:'tags',tags:[{id:'red',applies:false,probability:0.2},{id:'blue',applies:null,probability:0.5}]}}),
    make('v2-image-box',{contractVersion:2,state:{type:'image',dataUri:'data:image/png;base64,AA==',text:''},questions:{q:{type:'box',instructions:{object:'Supplied object'}}}},
      {q:{type:'box',box:{top:0.1,bottom:0.8,left:0.2,right:0.7},confidence:0.91}}),
    make('v2-list-sort',{contractVersion:2,state:{type:'list',items:[{id:'b',content:['B']},{id:'a',content:null}]},questions:{q:{type:'sort',instructions:'Order IDs'}}},
      {q:{type:'sort',order:['a','b'],confidence:-0.4}}),
    make('v2-categorical-boolean-zero',base,{q:{type:'boolean',probabilityTrue:0}},
      {capabilities:{input:['text'],questions:{boolean:{probabilities:'categorical',abstention:false}}}}),
    make('v2-json-structured',{...base,state:{type:'json',value:{z:2,a:['first',{nested:'雪😀'}]}}},{q:booleanAnswer}),
    make('snapshot-catalog',base,{q:booleanAnswer},{catalogMode:'manifest'}),
    make('runtime-config-reread',base,{q:booleanAnswer},{nextModel:'second-model'}),
    make('runtime-config-default',base,{q:booleanAnswer},{defaultFactoryConfig:true,defaultSelection:true}),
  ];
}

export async function captureDecisionTool(source=fixedRoot){
  assert.equal(process.versions.node,'24.22.1');assert.equal(realpathSync(process.execPath),realpathSync(fixedNode));
  const root=realpathSync(source);assert.equal(root,fixedRoot);const before=checkout(root);
  const harness=new DecisionToolHarness(root,before.tracked);
  await harness.load(setting);harness.context.__selection=harness.context.__exports;
  await harness.load('src/decisions/validation-v2.ts');harness.context.__validation=harness.context.__exports;
  await harness.load(contract);harness.context.__contract=harness.context.__exports;
  await harness.load(entry);
  const schemas=harness.call('({input:__contract.DecisionEvaluateInput,output:__contract.DecisionEvaluateOutput})');
  const observations=[];
  for(const row of vectors()){
    const capabilities=row.capabilities??allCapabilities;
    const model=row.model??'model';
    const config={plugins:{enabled:true},agents:row.defaultSelection?{defaults:{decisionModel:'fixture-provider/'+model},list:[{id:'fixture-agent'}]}:
      {list:[{id:'fixture-agent',decisionModel:'fixture-provider/'+model}]}};
    const models=[{provider:'fixture-provider',id:'model',inference:{decision:capabilities}},
      {provider:'fixture-provider',id:'second-model',inference:{decision:capabilities}}];
    const outcome={status:'ok',result:{model:'fixture-returned-model',answers:row.answers,usage,metadata:{provider:'fixture-provider'}},
      provenance:{providerId:'fixture-provider',rubricVersion:'fixture-runtime-rubric',runtimeGeneration:'fixture-generation'}};
    harness.context.__vector=plain({...row,capabilities,config,models,outcome});
    harness.run(`{
 const v=JSON.parse(JSON.stringify(__vector));globalThis.__fixture={...v,trace:[],configReads:0,manifestCalls:0,evaluateCalls:[],completeCalls:0};
 globalThis.__runtimeConfig=v.config;
 globalThis.__manifestPlugins=[{id:'fixture-plugin',modelCatalog:{providers:{'fixture-provider':{models:v.models.map(({provider,...model})=>model)}}}}];
 globalThis.__params=v.arguments;
 globalThis.__initialSelection=__selection.resolveDecisionModelSetting(v.config,'fixture-agent');
 globalThis.__tool=__exports.createDecisionTool('fixture-agent',v.defaultFactoryConfig?undefined:
  {config:v.config,...(v.catalogMode==='manifest'?{}:{preparedModelRuntime:{metadataSnapshot:__metadataSnapshot,modelCatalog:{entries:v.models}}})});
 globalThis.__batch=__contract.parseDecisionEvaluateInput(__params);
 if(v.nextModel)__runtimeConfig={...v.config,agents:{list:[{id:'fixture-agent',decisionModel:'fixture-provider/'+v.nextModel}]}};
 }`);
    const execution=harness.run('__tool.execute("ordinary-"+__fixture.id,__params,new AbortController().signal)');
    let timer,result;
    try{result=await Promise.race([execution,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('decision factory callback deadline')),5000);})]);}
    finally{clearTimeout(timer);}
    harness.context.__result=result;
    const observed=harness.call(`({id:__fixture.id,arguments:__fixture.arguments,argumentsAfter:__params,batch:__batch,
 tool:{name:__tool.name,label:__tool.label,description:__tool.description,parameters:__tool.parameters,outputSchema:__tool.outputSchema,resultContentSource:__tool.resultContentSource},
 result:__result,outcome:__fixture.outcome,capabilities:__fixture.capabilities,initialSelection:__initialSelection,
 selection:__selection.resolveDecisionModelSetting(__runtimeConfig,'fixture-agent'),
 validInput:__validation.validateDecisionBatchV2(__batch),validResult:__validation.validateDecisionResultV2(__batch,__result.details.result,__fixture.capabilities),
 configReads:__fixture.configReads,manifestCalls:__fixture.manifestCalls,trace:__fixture.trace,
 evaluateCalls:__fixture.evaluateCalls,completeCalls:__fixture.completeCalls})`);
    assert.equal(observed.validInput,true,row.id);assert.equal(observed.validResult,true,row.id);assert.equal(observed.completeCalls,1,row.id);
    observations.push(observed);
  }
  const sourceRecords=[...harness.sourceRecords.values()];
  for(const source of wholeSources)assert.ok(sourceRecords.some(row=>row.path===source),source);
  for(const source of provenancePaths)sourceRecords.push({path:source,sha256:before.tracked.get(source),executed:false,provenanceOnly:true});
  const after=checkout(root);assert.deepEqual(before.receipt,after.receipt);
  return {schemaVersion:1,referencePin:DECISION_TOOL_PIN,
    exporter:{path:'scripts/openclaw/capture-decision-tool.mjs',sha256:hash(readFileSync(fileURLToPath(import.meta.url)))},
    harness:{path:'scripts/openclaw/capture-recipes.mjs',sha256:hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url)))},
    runtime:{executable:fixedNode,version:process.versions.node,sha256:hash(readFileSync(fixedNode))},
    sourceTree:{before:before.receipt,after:after.receipt},transformation,sourceRecords,
    importBindings:[...harness.importBindings.values()],
    typebox:{version:harness.typeboxVersion,root:harness.typeboxRoot,
      files:[...harness.dependencies.values()].sort((a,b)=>a.path.localeCompare(b.path))},
    host:{generatedCode:hostCode,sha256:hash(hostCode)},schemas,observations,
    deferredCalls:harness.call('__deferredCalls'),
    boundaries:{factoryInvoked:true,callbackInvoked:true,realDecisionRuntimeExecuted:false,realProviderHostExecuted:false,
      networkExecuted:false,registrationExecuted:false,fullAssemblyExecuted:false},limits:[
      'Complete unchanged decision tool factory, contract, V1/V2 validators/compatibility, text-result and model-setting/ref helpers execute with actual TypeBox1.3.37.',
      'The synthetic decision runtime evaluate/complete facade records invocation data, callback order and supplied successful outcome; original provider-host/runtime/billing/authority bodies are not executed.',
      'Runtime configuration, Agent lookup, metadata snapshot, available manifests and current plugin registry are explicit input facades. Actual settings resolver runs against those inputs, not full configuration inheritance or plugin eligibility services.',
      'Only positive selected/configured factory and successful callback cases execute. All six generic result kinds, supplied evidence, estimates/abstentions/metadata/usage and complete JSON content/details are retained.',
      'No real provider/network/account, registration/assembly, disabled/invalid/error/cancellation/security/permission behavior is exercised. Synthetic model capability declarations do not establish actual provider support.',
      'Reference rubric uses decision-v1 while Synapsis deliberately uses synapsis-decision-v1 semantic-map canonicalization; this capture does not change the accepted host adaptation or whole-reference gates.',
    ]};
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 assert.ok(process.argv[3]);const capture=await captureDecisionTool(process.argv[2]);
 writeFileSync(process.argv[3],JSON.stringify(capture,null,2)+'\n');
 process.stdout.write(JSON.stringify({vectors:capture.observations.length,wholeModules:capture.sourceRecords.filter(row=>row.executed).length})+'\n');
}
