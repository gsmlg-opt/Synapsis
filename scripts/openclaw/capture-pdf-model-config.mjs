import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,lstatSync,readlinkSync,realpathSync,readdirSync,existsSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {join,dirname,relative,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
import path from 'node:path';
// Executes unchanged pinned selector/helper modules. IO availability is a declared fixture port.
export async function capturePdfModelConfig(root) {
root = realpathSync(root);
const pin='488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash=x=>cryptoHash('sha256',x);
function cryptoHash(type,x){return createHash(type).update(x).digest('hex');}
const plain=x=>JSON.parse(JSON.stringify(x));
const git=args=>execFileSync('git',['-C',root,...args],{encoding:'utf8',maxBuffer:64*1024*1024,timeout:30000,env:{...process.env,GIT_OPTIONAL_LOCKS:'0',GIT_NO_REPLACE_OBJECTS:'1'}}).trimEnd();
function checkout(){assert.equal(git(['rev-parse','HEAD']),pin);assert.equal(git(['status','--porcelain','--untracked-files=no']),'');let rows=git(['ls-tree','-rz','--full-tree',pin]).split('\0').filter(Boolean).map(line=>{let [h,p]=line.split('\t'),[mode,type,blob]=h.split(' '),f=join(root,p),s=lstatSync(f);assert.equal(type,'blob');assert.equal(s.isSymbolicLink(),mode==='120000');if(!s.isSymbolicLink())assert.equal(!!(s.mode&0o111),mode==='100755');assert.ok(realpathSync(f).startsWith(root+'/'));let b=s.isSymbolicLink()?Buffer.from(readlinkSync(f)):readFileSync(f);assert.equal(cryptoHash('sha1',Buffer.concat([Buffer.from(`blob ${b.length}\0`),b])),blob,p);return {path:p,mode,blob,sha256:hash(b)};});return {pin,count:rows.length,sha256:hash(JSON.stringify(rows)),rows};}
const rootSource='src/agents/tools/pdf-tool.model-config.ts';
const exactWhole=new Set([rootSource,'src/media-understanding/defaults.ts','src/media-understanding/defaults.constants.ts','src/media-understanding/config-provider-models.ts','src/media-understanding/provider-registry-metadata.ts','src/agents/tools/pdf-tool.helpers.ts','src/agents/tools/image-tool.helpers.ts','src/agents/tools/model-config.helpers.ts','src/agents/tools/media-tool-text.ts','src/agents/defaults.ts','src/agents/agent-scope-config.ts','src/agents/configured-provider-model.ts','src/agents/configured-provider-fallback.ts','src/agents/minimax-vlm.ts','src/agents/utility-model-setting.ts','src/agents/provider-model-normalization.runtime.ts','src/plugins/manifest-model-id-normalization.ts']);
function whole(p){if(ports[p])return false;return exactWhole.has(p)||p.startsWith('packages/normalization-core/src/')||p.startsWith('packages/model-catalog-core/src/')||p.startsWith('packages/media-understanding-common/src/')||p.startsWith('src/agents/model-')||p.startsWith('src/config/model-')||p==='src/shared/model-key.ts'||p==='src/shared/dedupe-by-key.ts';}
const modules=new Map(),sources=new Map(),boundaries=new Map(),bindings=[],calls=[],results=[];
let current,phase='checkout-before',before;
const actualManifests=readdirSync(join(root,'extensions')).map(id=>join('extensions',id,'openclaw.plugin.json')).filter(p=>existsSync(join(root,p))).map(p=>({path:p,sha256:hash(readFileSync(join(root,p))),value:JSON.parse(readFileSync(join(root,p),'utf8'))}));
let snapshot={plugins:actualManifests.map(x=>x.value),manifestRegistry:{},owners:{modelIdNormalizationPolicies:new Map(),providers:new Map()}};
const ports={
 'src/plugins/manifest-contract-eligibility.ts':{loadManifestMetadataSnapshot:()=>snapshot},
 'src/plugins/current-plugin-metadata-snapshot.ts':{getCurrentPluginMetadataSnapshot:()=>snapshot},
 'src/plugins/plugin-metadata-snapshot.runtime.ts':{getCurrentPluginMetadataSnapshotRuntime:()=>snapshot,resolvePluginMetadataSnapshotRuntime:()=>snapshot},
 'src/plugins/runtime-state.ts':{getActivePluginRegistryWorkspaceDirFromState:()=>undefined},
 'src/plugins/runtime-workspace-state.ts':{getActivePluginRegistryWorkspaceDirFromStateCore:()=>undefined},
 'src/plugins/runtime/gateway-request-scope.ts':{getPluginRegistryForContext:()=>undefined},
 'src/plugins/runtime/generation-state.ts':{getPluginRuntimeGenerationRegistry:()=>undefined},
 'src/plugins/provider-auth-scope.ts':{resolveProviderAuthScope:()=> 'agent'},
 'src/agents/model-auth.ts':{hasRuntimeAvailableProviderAuth:args=>current.available.includes(args.provider),resolveEnvApiKey:()=>undefined},
 'src/agents/auth-profiles.ts':{listProfilesForProvider:()=>[]},
 'src/agents/model-auth-policy.ts':{isAuthModeAllowedForModel:()=>true},
 'src/agents/model-auth-provider-config.ts':{profileTypeToAuthMode:()=> 'api-key'},
};
const ctx=vm.createContext({Buffer,URL,TextEncoder,TextDecoder,process:{env:{}},console:{log:()=>{}},__port:(p,name,args)=>{calls.push({vector:current?.id??'initialization',source:p,name,args:plain(args)});if(ports[p]&&Object.hasOwn(ports[p],name))return ports[p][name](...args);throw Error('Uninvoked sealed import called: '+p+'#'+name);}}, {codeGeneration:{strings:false,wasm:false}});
function sourceTarget(spec,parent){if(spec.startsWith('.')){let p=relative(root,resolve(root,dirname(parent),spec));return p.endsWith('.js')?p.slice(0,-3)+'.ts':p;}for(let pkg of ['normalization-core','model-catalog-core','media-core']){let prefix='@openclaw/'+pkg;if(spec===prefix||spec.startsWith(prefix+'/'))return 'packages/'+pkg+'/src/'+(spec===prefix?'index':spec.slice(prefix.length+1))+'.ts';}if(spec.startsWith('node:'))return spec;throw Error('Unmapped package import '+parent+' -> '+spec);}
function imports(code){return [...code.matchAll(/\b(import|export)\s+([^;]*?)\s+from\s*(['"])([^'"]+)\3\s*;/g)].map(m=>({kind:m[1],clause:m[2],spec:m[4]}));}
function names(clause){if(clause.trim().startsWith('* as '))throw Error('Namespace imports require real module: '+clause);let ns=[];let b=clause.match(/\{([\s\S]*?)\}/);if(b)ns.push(...b[1].split(',').map(x=>x.trim().split(/\s+as\s+/)[0]).filter(Boolean));let first=clause.split(',')[0].trim();if(!first.startsWith('{')&&!first.startsWith('*')&&first)ns.push('default');return ns;}
function scan(p){if(sources.has(p))return;let b=readFileSync(join(root,p)),code=stripTypeScriptTypes(b.toString(),{mode:'transform',sourceMap:false});sources.set(p,{path:p,sha256:hash(b),executableSha256:hash(code),wholeModule:true,code});for(let imp of imports(code)){let target=sourceTarget(imp.spec,p);bindings.push({importer:p,specifier:imp.spec,target,kind:whole(target)?'whole-original-source':target.startsWith('node:')?'node-platform-module':ports[target]?'explicit-fixture-port':'sealed-uninvoked-import'});if(whole(target))scan(target);else {let r=boundaries.get(target)||{path:target,names:new Set(),sourceSha256:target.startsWith('node:')?null:hash(readFileSync(join(root,target)))};for(let n of names(imp.clause))r.names.add(n);boundaries.set(target,r);}}}
function mod(p){if(modules.has(p))return modules.get(p);let m;if(sources.has(p)){m=new vm.SourceTextModule(sources.get(p).code,{context:ctx,identifier:p,importModuleDynamically:s=>{throw Error('Uninvoked dynamic import '+p+' -> '+s);}});}else {let b=boundaries.get(p);assert.ok(b,p);let vals={};for(let n of b.names){if(p==='node:path')vals[n]=n==='default'?path:path[n];else vals[n]=(...args)=>ctx.__port(p,n,args);}m=new vm.SyntheticModule([...b.names],function(){for(let [n,v]of Object.entries(vals))this.setExport(n,v);},{context:ctx,identifier:p});}modules.set(p,m);return m;}
const provider=(models)=>({models:models.map(x=>typeof x==='string'?{id:x,input:['text','image']}:x)});
const cfg=(primary,providers={},extra={})=>({agents:{defaults:{model:primary,...extra}},models:{providers}});
const row=(id,config,available,expected,activeModel)=>({id,cfg:config,available,expected,...(activeModel?{activeModel}:{})});
const vectors=[
 row('explicit-pdf-before-image',cfg('openai/gpt-6-astra',{}, {pdfModel:{primary:' google/pdf-custom ',fallbacks:['anthropic/second','google/pdf-custom']},imageModel:'openai/ignored'}),['google','anthropic'],{primary:'google/pdf-custom',fallbacks:['anthropic/second','google/pdf-custom']}),
 row('explicit-image-before-auto',cfg('anthropic/base',{}, {imageModel:{primary:'openai/vision-one',fallbacks:['google/vision-two'],timeoutMs:32100}}),['openai','google','anthropic'],{primary:'openai/vision-one',fallbacks:['google/vision-two'],timeoutMs:32100}),
 row('explicit-bare-configured-image-ref',cfg('openai/gpt-6-astra',{custom:provider(['Vision-Exact'])},{pdfModel:'Vision-Exact'}),['custom'],{primary:'custom/Vision-Exact'}),
 row('native-primary-configured-model',cfg('anthropic/base',{anthropic:provider(['native-chosen']),google:provider(['gemini-chosen']),openai:provider(['vision-chosen'])}),['anthropic','google','openai'],{primary:'anthropic/native-chosen',fallbacks:['google/gemini-chosen','openai/vision-chosen']}),
 row('native-primary-beats-priority',cfg('google/base',{anthropic:provider(['a']),google:provider(['g'])}),['anthropic','google'],{primary:'google/g',fallbacks:['anthropic/a']}),
 row('native-before-generic-with-manifest-defaults',cfg('openai/text',{}),['anthropic','google','openai'],{primary:'anthropic/claude-opus-5-5',fallbacks:['google/gemini-3-flash-preview','openai/gpt-6-astra']}),
 row('native-default-dedup-current-active',cfg('anthropic/base',{}),['anthropic','google'],{primary:'anthropic/claude-opus-5-5',fallbacks:['google/gemini-3-flash-preview']},{provider:'custom',model:'active-never-preferred',supportsImages:true}),
 row('configured-custom-vision-order',cfg('custom/text',{custom:provider(['vision-first','vision-second']),other:provider(['other-image'])}),['custom','other'],{primary:'custom/vision-first',fallbacks:['other/other-image']}),
 row('configured-self-prefixed-vision-no-double-prefix',cfg('custom/text',{custom:provider(['custom/vision-one'])}),['custom'],{primary:'custom/vision-one',fallbacks:['custom/custom/vision-one']}),
 row('primary-text-before-generic',cfg('minimax/text-primary',{minimax:provider([{id:'text-primary',input:['text']}]),openai:provider(['vision'])}),['minimax','openai'],{primary:'minimax/text-primary',fallbacks:['openai/vision']}),
 row('native-before-primary-text',cfg('minimax/text-primary',{minimax:provider([{id:'text-primary',input:['text']}]),anthropic:provider(['native'])}),['minimax','anthropic'],{primary:'anthropic/native',fallbacks:['minimax/text-primary']}),
 row('document-text-default-without-configured-text',cfg('openai/text',{openai:provider(['vision'])}),['minimax','openai'],{primary:'openai/vision',fallbacks:['minimax/MiniMax-M2.7']}),
 row('minimax-cn-execution-alias-text',cfg('minimax-cn/text-china',{'minimax-cn':provider([{id:'text-china',input:['text']},{id:'blocked-image',input:['image']}])}),['minimax-cn'],{primary:'minimax-cn/text-china'}),
 row('active-fills-final-no-prior-primary',cfg('custom/text',{}),['custom'],{primary:'custom/active/with/slashes'},{provider:'custom',model:'active/with/slashes',supportsImages:true}),
 row('active-self-prefixed-ref-kept',cfg('custom/text',{}),['custom'],{primary:'custom/active'},{provider:'custom',model:'custom/active',supportsImages:true}),
 row('nonprimary-minimax-first-configured-text',cfg('openai/vision',{openai:provider(['vision']),minimax:provider([{id:'text-first',input:['text']},{id:'text-second',input:['text']}])}),['openai','minimax'],{primary:'openai/vision',fallbacks:['minimax/text-first']}),
 row('primary-image-default-selects-document-text-hint',cfg('minimax/MiniMax-VL-01',{minimax:provider([{id:'MiniMax-VL-01',input:['text','image']}]),openai:provider(['vision'])}),['minimax','openai'],{primary:'minimax/MiniMax-M2.7',fallbacks:['openai/vision']}),
 row('native-group-before-tied-generic-exact-saved-refs',cfg('openai/gpt-6-astra',{openai:provider(['gpt-6-astra']),google:provider(['gemini-3-flash-preview']),anthropic:provider(['claude-opus-5-5'])}),['openai','google','anthropic'],{primary:'anthropic/claude-opus-5-5',fallbacks:['google/gemini-3-flash-preview','openai/gpt-6-astra']}),
];
let receipt={status:'RUNNING',driverSha256:hash(readFileSync(new URL(import.meta.url))),pin,phase,results,corrections:[]};
try{before=checkout();receipt.sourceBefore={pin:before.pin,count:before.count,sha256:before.sha256};phase='scan';scan(rootSource);phase='link';let main=mod(rootSource);await main.link((spec,parent)=>mod(sourceTarget(spec,parent.identifier)));phase='evaluate';await main.evaluate({timeout:3000});
 // Build normalization/provider ownership through the original complete pure collector.
 const core=modules.get('packages/model-catalog-core/src/provider-model-id-normalization.ts');if(core?.status==='evaluated')snapshot.owners.modelIdNormalizationPolicies=core.namespace.collectManifestModelIdNormalizationPolicies(snapshot.plugins);
 snapshot.owners.providers=new Map(snapshot.plugins.flatMap(p=>(p.providers||[]).map(id=>[id,p])));
 phase='vectors';for(let vector of vectors){current=vector;let input={cfg:plain(vector.cfg),agentDir:'/ordinary-agent',authStore:{profiles:{}},...(vector.activeModel?{activeModel:plain(vector.activeModel)}:{})};let value=main.namespace.resolvePdfModelConfigForTool(input);let actual=plain(value);results.push({id:vector.id,input:plain(input),available:vector.available,expected:vector.expected,actual,pass:JSON.stringify(actual)===JSON.stringify(vector.expected)});assert.deepEqual(actual,vector.expected,vector.id);}
 phase='source-after';let after=checkout();receipt.sourceAfter={pin:after.pin,count:after.count,sha256:after.sha256};assert.equal(after.sha256,before.sha256);receipt.status='PASS';
}catch(e){receipt.status='FAIL';receipt.error={message:e.message,stack:e.stack};}
finally{receipt.phase=phase;receipt.wholeModules=[...sources.values()].map(({code,...x})=>({...x,evaluationStatus:modules.get(x.path)?.status??'not-instantiated'}));receipt.boundaries=[...boundaries.values()].map(x=>({...x,names:[...x.names],kind:x.path.startsWith('node:')?'node-platform-module':ports[x.path]?'explicit-fixture-port':'sealed-uninvoked-import'}));receipt.bindings=bindings;receipt.calls=calls;receipt.manifests=actualManifests.map(({value,...x})=>x);receipt.excluded=['security','permission','auth','negative','error','failure','blocked','cancel','crash','timeout-exhaustion','TTL','race','resource-threshold','mixed-suites','realproviders'];}
return receipt;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [root, output] = process.argv.slice(2);
  assert.ok(root && output, 'Usage: node --experimental-vm-modules capture-pdf-model-config.mjs SOURCE OUTPUT');
  const receipt = await capturePdfModelConfig(root);
  writeFileSync(output, JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({status: receipt.status, vectors: receipt.results.length, wholeModules: receipt.wholeModules.length}));
  if (receipt.status !== 'PASS') process.exitCode = 1;
}
