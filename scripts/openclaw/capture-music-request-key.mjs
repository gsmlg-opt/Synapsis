// Pinned music request-key object region, actual unchanged wrapper and stable serializer.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';
export const MUSIC_REQUEST_KEY_PIN='488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot='/tmp/openclaw-488631c';
const fixedNode='/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const stable='packages/normalization-core/src/stable-stringify.ts';
const shared='src/agents/media-generation-task-status-shared.ts';
const strings='packages/normalization-core/src/string-coerce.ts';
const details='src/agents/session-async-task-status.ts';
const tool='src/agents/tools/music-generate-tool.ts';
const wholeSources=[stable,shared,strings,details];
const unusedImports=[
 [shared,'@openclaw/normalization-core/utf16-slice',['truncateUtf16Safe'],'packages/normalization-core/src/utf16-slice.ts','Prompt-context/truncation exports are outside request-key scope and remain uninvoked.'],
 [shared,'../routing/session-key.js',['parseAgentSessionKey'],'src/routing/session-key.ts','Status owner lookup and session-key parsing are outside request-key scope and remain uninvoked.'],
 [shared,'./media-generation-activity.js',['listMediaGenerationOperations'],'src/agents/media-generation-activity.ts','Activity lookup/Store snapshots are outside request-key scope and remain uninvoked.'],
 [shared,'./sanitize-for-prompt.js',['sanitizeForPromptLiteral'],'src/agents/sanitize-for-prompt.ts','Prompt-context sanitizer is outside request-key scope and remains uninvoked.'],
];
const provenance=['LICENSE','packages/normalization-core/src/index.ts','src/music-generation/types.ts',
 'src/media-generation/model-ref.ts','src/agents/tools/media-tool-shared.ts',...unusedImports.map(row=>row[3])];
const hash=value=>createHash('sha256').update(value).digest('hex');
const plain=value=>JSON.parse(JSON.stringify(value));
const transform='node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
function numberFacts(value){const bytes=Buffer.alloc(8);bytes.writeDoubleBE(value);return {number:value,binary64Hex:bytes.toString('hex'),sourceSpelling:JSON.stringify(value)};}
function recordValue(value){return value===undefined?{type:'undefined'}:typeof value==='number'?{type:'number',...numberFacts(value)}:{type:typeof value,value:plain(value)};}
function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MUSIC_REQUEST_KEY_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MUSIC_REQUEST_KEY_PIN]).split('\0').filter(Boolean).map(item => {
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
    verified: true, commit: MUSIC_REQUEST_KEY_PIN,
    tree: git(root, ['rev-parse', `${MUSIC_REQUEST_KEY_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

function vectors(){
 const row=(id,prepared={},extra={})=>({id,prepared:{prompt:'A melody',imageInputs:[],musicGenerationModelConfig:{},...prepared},...extra});
 return plain([
  row('all-optional-undefined'),
  row('raw-prompt-whitespace',{prompt:' \uFEFF夜 café 😀\n雪\u00a0 '}),
  row('all-fields-false',{selectedProvider:{id:' Google '},model:' model raw ',lyrics:' exact lyrics\n ',instrumental:false,durationSeconds:37,format:' WAV ',filename:' name raw.wav ',imageInputs:['first.png',' second.png ']}),
  row('instrumental-true',{instrumental:true}),
  row('optional-empty-strings',{selectedProvider:{id:''},model:'',lyrics:'',format:'',filename:''}),
  row('scalar-string-escapes',{prompt:'quote" slash/ backslash\\ tab\t line\n return\r back\b form\f zero\u0000',lyrics:'line\u2028separator\u2029end',filename:'雪\\".wav'}),
  row('unicode-nfc',{prompt:'café'}),row('unicode-nfd',{prompt:'cafe\u0301'}),
  row('images-order-and-duplicates',{imageInputs:['b.png','a.png','b.png',' 雪 /x?y=1 ']}),
  row('images-reversed',{imageInputs:['a.png','b.png']}),
  row('duration-sixty',{durationSeconds:60}),
  row('duration-fixed-integral',{durationSeconds:100000000000000000000}),
  row('duration-exponential-integral',{durationSeconds:1e21}),
  row('duration-wide-exponential',{durationSeconds:2.5e22}),
  row('native-integer-once-rounded-low',{}, {nativeDurationDecimal:'9007199254740993'}),
  row('native-integer-once-rounded-high',{}, {nativeDurationDecimal:'9007199254740995'}),
  row('native-integer-source-shortest-spelling',{}, {nativeDurationDecimal:'1000000000000000128'}),
  row('prepared-explicit-model-ref',{model:'google/original-label',explicitModelRef:{provider:'google',model:'resolved-model'},selectedModelRef:{provider:'google',model:'resolved-model'}}),
  row('prepared-primary-model-ref',{primaryModelRef:{provider:'google',model:'primary-model'},selectedModelRef:{provider:'google',model:'primary-model'},musicGenerationModelConfig:{primary:'google/config-primary'}}),
  row('prepared-primary-config-fallback',{musicGenerationModelConfig:{primary:' raw primary '}}),
  row('prepared-provider-default-fallback',{selectedProvider:{id:'comfy',defaultModel:' workflow '}}),
  row('prepared-selected-provider-id-priority',{selectedProvider:{id:'chosen',defaultModel:'default'},selectedModelRef:{provider:'other'},model:'direct'}),
  row('prepared-selected-ref-provider-fallback',{selectedProvider:{defaultModel:'default'},selectedModelRef:{provider:'reference-provider'},model:'direct'}),
  row('prepared-empty-explicit-ref-model',{model:'direct',explicitModelRef:{model:''},selectedModelRef:{provider:'google'}}),
  row('prepared-empty-primary-ref-model',{primaryModelRef:{model:''},selectedModelRef:{provider:'google'},musicGenerationModelConfig:{primary:'fallback'},selectedProvider:{defaultModel:'default'}}),
  row('closed-unknown-fields-unused',{prompt:'A melody',timeoutMs:9999,requestKey:'caller-value',tool:'other',extra:{ignored:true}}),
 ]);
}

class MusicKeyHarness extends FactoryHarness{
 constructor(root,tracked){
  super(root,tracked,{allowedSources:wholeSources});
  this.context=vm.createContext({__platform:{unused:name=>{throw Error('Uninvoked import called: '+name);},
   observe:value=>{assert.equal(this.current.arguments.length,0);this.current.arguments.push(value);
    this.current.keyObjectEntries=Object.entries(value).map(([key,value])=>({key,...recordValue(value)}));},
  }},{codeGeneration:{strings:false,wasm:false}});
  this.sourceRecords=new Map();this.importBindings=new Map();this.dynamicImports=[];
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
        throw Error('Undeclared music key dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:music-key:' + key, code);
  }
  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module',
      source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }

 import(specifier,parent){
  const importer=relative(this.root,parent);
  if(parent==='capture:music-key:tool-region'&&specifier==='capture:shared')return this.source(parent,specifier,shared);
  if(importer===shared&&specifier==='@openclaw/normalization-core')
   return this.binding(importer,specifier,'whole-source-export-alias',['stableStringify'],
    "export {stableStringify} from 'capture:stable';",{source:stable,sourceSha256:this.tracked.get(stable)});
  if(parent.startsWith('capture:music-key:')&&specifier==='capture:stable')return this.source(parent,specifier,stable);
  if(importer===shared&&specifier==='@openclaw/normalization-core/string-coerce')return this.source(importer,specifier,strings);
  if(importer===shared&&specifier==='./session-async-task-status.js')return this.source(importer,specifier,details);
  const rule=unusedImports.find(row=>row[0]===importer&&row[1]===specifier);
  if(rule){const [,,exports,source,limit]=rule;
   return this.binding(importer,specifier,'uninvoked-import-facade',exports,
    exports.map(name=>'export const '+name+'=(...args)=>globalThis.__platform.unused('+JSON.stringify(source+'#'+name)+');').join('\n'),
    {source,sourceSha256:this.tracked.get(source),limit});}
  throw Error('Undeclared music key import: '+importer+' -> '+specifier);
 }
 async prepare(){
  const original=readFileSync(join(this.root,tool));assert.equal(hash(original),this.tracked.get(tool));
  const startMarker='            const selectedProviderId = selectedProvider?.id ?? selectedModelRef?.provider;';
  const endMarker='            const duplicateGuardResult = await createMusicGenerateDuplicateGuardResult(';
  const startByte=original.indexOf(startMarker),endByte=original.indexOf(endMarker,startByte);
  assert.ok(startByte>=0&&endByte>startByte);assert.equal(original.indexOf(startMarker,startByte+1),-1);
  const prelude="import {buildMediaGenerationRequestKey as sourceBuild} from 'capture:shared';\n"+
   'const buildMediaGenerationRequestKey=value=>{globalThis.__platform.observe(value);return sourceBuild(value);};\n'+
   'export function buildPreparedMusicKey({selectedProvider,selectedModelRef,model,explicitModelRef,primaryModelRef,musicGenerationModelConfig,prompt,lyrics,instrumental,durationSeconds,format,filename,imageInputs}){\n';
  const suffix='\nreturn requestKey;\n}';
  const region=original.subarray(startByte,endByte);const generated=prelude+region.toString()+suffix;
  const executable=stripTypeScriptTypes(generated,{mode:'transform',sourceMap:false});
  this.sourceRecords.set(tool,{path:tool,sha256:hash(original),executed:true,wholeModule:false,
   projection:{justification:'Full public tool factory depends on schema, provider/config selection, reference loading, background ownership and persistence outside this pure prepared-key scope. Exact complete selectedProviderId plus requestKey object/call expression is retained, with prepared variables and transparent same-argument wrapper observation; no resolver/parser/factory executes.',
    regions:[{startByte,endByte,sourceRegionSha256:hash(region)}],prelude,suffix,generatedCode:generated,generatedSha256:hash(generated)},
   transformation:transform,executableSha256:hash(executable)});
  const mod=new vm.SourceTextModule(executable,{context:this.context,identifier:'capture:music-key:tool-region',
   importModuleDynamically:specifier=>{this.dynamicImports.push({importer:tool,specifier});throw Error('Undeclared key projection dynamic import');}});
  await mod.link((specifier,importer)=>this.import(specifier,importer.identifier));await mod.evaluate({timeout:1000});this.context.__projection=mod.namespace;
 }
 run(vector){
  const prepared=plain(vector.prepared);
  let conversion;
  if(vector.nativeDurationDecimal!==undefined){
   const value=Number(BigInt(vector.nativeDurationDecimal));prepared.durationSeconds=value;
   conversion={nativeIntegerDecimal:vector.nativeDurationDecimal,implementation:'native-Number(BigInt(decimal))-once-before-source',...numberFacts(value)};
  }
  const before=plain(prepared);this.current={arguments:[]};this.context.__prepared=prepared;
  const canonical=new vm.Script('__projection.buildPreparedMusicKey(__prepared)').runInContext(this.context,{timeout:1000});
  assert.equal(typeof canonical,'string');assert.deepEqual(plain(prepared),before);assert.equal(this.current.arguments.length,1);
  const argument=this.current.arguments[0];assert.equal(argument.imageInputs,prepared.imageInputs);
  const entriesAfter=Object.entries(argument).map(([key,value])=>({key,...recordValue(value)}));
  assert.deepEqual(entriesAfter,this.current.keyObjectEntries);
  return plain({...vector,preparedAfter:prepared,keyObjectEntries:entriesAfter,
   sourceUndefinedFields:entriesAfter.filter(entry=>entry.type==='undefined').map(entry=>entry.key),
   canonical,sha256Utf8Observation:hash(Buffer.from(canonical,'utf8')),
   ...(conversion?{numericPreparation:conversion}:{}),
   ...(prepared.durationSeconds===undefined?{}:{sourceDuration:numberFacts(prepared.durationSeconds)})});
 }
}
export async function captureMusicRequestKey(source=fixedRoot){
 assert.equal(process.versions.node,'24.22.1');assert.equal(realpathSync(process.execPath),realpathSync(fixedNode));
 const root=realpathSync(source);assert.equal(root,fixedRoot);const before=checkout(root);assert.equal(before.receipt.verifiedTrackedFiles,58558);
 const harness=new MusicKeyHarness(root,before.tracked);await harness.prepare();const observations=vectors().map(row=>harness.run(row));
 const sourceRecords=[...harness.sourceRecords.values()];for(const source of wholeSources)assert.ok(sourceRecords.some(row=>row.path===source&&row.wholeModule));
 for(const source of [...new Set(provenance)]){const bytes=readFileSync(join(root,source));assert.equal(hash(bytes),before.tracked.get(source));sourceRecords.push({path:source,sha256:hash(bytes),executed:false,provenanceOnly:true});}
 const after=checkout(root);assert.deepEqual(after.receipt,before.receipt);
 return plain({schemaVersion:1,referencePin:MUSIC_REQUEST_KEY_PIN,
  exporter:{path:'scripts/openclaw/capture-music-request-key.mjs',sha256:hash(readFileSync(fileURLToPath(import.meta.url)))},
  harness:{path:'scripts/openclaw/capture-recipes.mjs',sha256:hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url)))},
  runtime:{executable:fixedNode,version:process.versions.node,sha256:hash(readFileSync(fixedNode)),platform:process.platform},
  sourceTree:{before:before.receipt,after:after.receipt},transformation:transform,sourceRecords,
  importBindings:[...harness.importBindings.values()],dynamicImports:harness.dynamicImports,
  observationSeams:[{name:'buildMediaGenerationRequestKey-argument',implementation:'transparent-same-reference-observer-then-unchanged-source-wrapper',limit:'Records own key entries/types including undefined, then delegates identical object reference to actual unchanged shared wrapper and actual unchanged stableStringify. No payload, string or numeric conversion is changed.'}],
  serviceFacadeLedger:unusedImports.map(([importer,specifier,exports,source,limit])=>({name:specifier,importer,exports,source,productionExecuted:false,limit})),
  limits:[
   'Actual unchanged stable-stringify.ts, shared task-status module wrapper, string-coerce and session async details modules evaluate whole after TS erasure. Only buildMediaGenerationRequestKey/stableStringify selected prepared UTF8 string/bool/integral binary64/array/object paths execute; other exports/branches remain uninvoked.',
   'Exact tool source region preserves selectedProviderId fallback and all ten request-key fields including complete original model fallback expression. All model/provider/ref/config variables are prepared explicit fixtures. No tool factory/model parser/provider resolver/default selection or normalized argument-reader acceptance is claimed.',
   'Source undefined fields remain present and serialize as unquoted undefined; no optional string trimming, Unicode normalization or image-order/dedup rewrite occurs. Optional nil in host API represents unset, not generic source null; source arbitrary-value null/cycles/BigInt/Error/Uint8Array/lone-surrogate parity is outside scope.',
   'Native integer decimal fixtures convert once through native Number(BigInt(decimal)) before source execution. Source sees positive integral binary64 only, with bits/spelling recorded; generic BigInt serialization is uninvoked. SHA256 UTF8 observations are exporter calculations, not original source digest behavior.',
   'Activity Store/status owner lookup, prompt-context sanitizer/truncation, registry/auth/provider, schema/public tool dispatch/background ownership/reference loading/persistence are uninvoked or explicit throw-only seams.',
   'All58558 pinned tracked blobs/modes/symlinks verified before/after; root LICENSE/source region/source/import/generated/executable/shared-harness/runtime/exporter receipts reconstruct.',
   'No host implementation/expected values inspected or imported, no all-vector host replay. No security/auth/permission/negative/error/failure/threshold/race/mixed-domain suite, real API, config/store mutation, native activation or whole-reference/P10/goal acceptance.',
  ],observations});
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const args=process.argv.slice(2);assert.equal(args.indexOf('--out'),1);assert.equal(args.length,3);
 const result=await captureMusicRequestKey(args[0]);writeFileSync(args[2],JSON.stringify(result,null,2)+'\n');
 process.stdout.write(JSON.stringify({output:args[2],vectors:result.observations.length,wholeModules:result.sourceRecords.filter(row=>row.executed&&row.wholeModule).length,
  sourceProjections:result.sourceRecords.filter(row=>row.executed&&!row.wholeModule).length,trackedBlobs:result.sourceTree.before.verifiedTrackedFiles})+'\n');
}
