// Independent prepared-input/canonical-text plans; no host implementation or expectations imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMusicRequestKey,MUSIC_REQUEST_KEY_PIN } from './capture-music-request-key.mjs';
const root='/tmp/openclaw-488631c';
const capture=await captureMusicRequestKey(root);
const rows=new Map(capture.observations.map(row=>[row.id,row]));
const hash=value=>createHash('sha256').update(value).digest('hex');
const q=JSON.stringify;
// Slots are fixed by the source music key contract, independently of capture vectors.
const sortedFields=['durationSeconds','filename','format','imageInputs','instrumental','lyrics','model','prompt','provider','tool'];
const sourceInsertion=['tool','prompt','provider','model','lyrics','instrumental','durationSeconds','format','filename','imageInputs'];
const tokens=fields=>({durationSeconds:'undefined',filename:'undefined',format:'undefined',imageInputs:'[]',instrumental:'undefined',
 lyrics:'undefined',model:'undefined',prompt:'"A melody"',provider:'undefined',tool:'"music_generate"',...fields});
const canonical=fields=>'{'+sortedFields.map(key=>'"'+key+'":'+fields[key]).join(',')+'}';
const plans=[
 ['all-optional-undefined',{}],
 ['raw-prompt-whitespace',{prompt:q(' \uFEFF夜 café 😀\n雪\u00a0 ')}],
 ['all-fields-false',{provider:'" Google "',model:'" model raw "',lyrics:'" exact lyrics\\n "',instrumental:'false',durationSeconds:'37',format:'" WAV "',filename:'" name raw.wav "',imageInputs:'["first.png"," second.png "]'}],
 ['instrumental-true',{instrumental:'true'}],
 ['optional-empty-strings',{provider:'""',model:'""',lyrics:'""',format:'""',filename:'""'}],
 ['scalar-string-escapes',{prompt:String.raw`"quote\" slash/ backslash\\ tab\t line\n return\r back\b form\f zero\u0000"`,lyrics:q('line\u2028separator\u2029end'),filename:q('雪\\".wav')}],
 ['unicode-nfc',{prompt:q('café')}],['unicode-nfd',{prompt:q('cafe\u0301')}],
 ['images-order-and-duplicates',{imageInputs:q(['b.png','a.png','b.png',' 雪 /x?y=1 '])}],
 ['images-reversed',{imageInputs:'["a.png","b.png"]'}],
 ['duration-sixty',{durationSeconds:'60'}],
 ['duration-fixed-integral',{durationSeconds:'100000000000000000000'}],
 ['duration-exponential-integral',{durationSeconds:'1e+21'}],
 ['duration-wide-exponential',{durationSeconds:'2.5e+22'}],
 ['native-integer-once-rounded-low',{durationSeconds:'9007199254740992'}],
 ['native-integer-once-rounded-high',{durationSeconds:'9007199254740996'}],
 ['native-integer-source-shortest-spelling',{durationSeconds:'1000000000000000100'}],
 ['prepared-explicit-model-ref',{provider:'"google"',model:'"resolved-model"'}],
 ['prepared-primary-model-ref',{provider:'"google"',model:'"primary-model"'}],
 ['prepared-primary-config-fallback',{model:'" raw primary "'}],
 ['prepared-provider-default-fallback',{provider:'"comfy"',model:'" workflow "'}],
 ['prepared-selected-provider-id-priority',{provider:'"chosen"',model:'"direct"'}],
 ['prepared-selected-ref-provider-fallback',{provider:'"reference-provider"',model:'"direct"'}],
 ['prepared-empty-explicit-ref-model',{provider:'"google"',model:'""'}],
 ['prepared-empty-primary-ref-model',{provider:'"google"',model:'""'}],
 ['closed-unknown-fields-unused',{}],
];

test('26 independent literal canonical plans retain all ten fields, exact strings and source undefined',()=>{
 assert.equal(plans.length,26);assert.deepEqual([...rows.keys()],plans.map(row=>row[0]));
 for(const [id,fields] of plans){
  const expected=tokens(fields),text=canonical(expected),row=rows.get(id);
  assert.equal(row.canonical,text,id+' exact source canonical text');
  assert.equal(row.sha256Utf8Observation,hash(Buffer.from(text,'utf8')),id+' exporter UTF8 digest');
  assert.deepEqual(row.keyObjectEntries.map(entry=>entry.key),sourceInsertion,id+' original complete insertion order');
  assert.deepEqual(row.sourceUndefinedFields,sourceInsertion.filter(key=>expected[key]==='undefined'),id+' explicit own undefined fields');
  assert.equal(row.keyObjectEntries.length,10,id);
  assert.deepEqual(row.preparedAfter,{...row.prepared,...(row.numericPreparation?{durationSeconds:row.numericPreparation.number}:{})},id+' prepared object unchanged');
 }
 assert.equal(rows.get('all-optional-undefined').canonical,
  '{"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"A melody","provider":undefined,"tool":"music_generate"}');
});

test('ordinary integral binary64 values use exact ECMAScript spelling with once-rounded native integers',()=>{
 const numeric=[
  ['all-fields-false','37'],['duration-sixty','60'],['duration-fixed-integral','100000000000000000000'],
  ['duration-exponential-integral','1e+21'],['duration-wide-exponential','2.5e+22'],
  ['native-integer-once-rounded-low','9007199254740992','4340000000000000','9007199254740993'],
  ['native-integer-once-rounded-high','9007199254740996','4340000000000002','9007199254740995'],
  ['native-integer-source-shortest-spelling','1000000000000000100','43abc16d674ec801','1000000000000000128'],
 ];
 for(const [id,spelling,bits,native] of numeric){
  const row=rows.get(id);assert.equal(row.sourceDuration.sourceSpelling,spelling,id);
  assert.equal(Number.isInteger(row.sourceDuration.number)&&Number.isFinite(row.sourceDuration.number)&&row.sourceDuration.number>0,true,id);
  assert.equal(row.keyObjectEntries.find(entry=>entry.key==='durationSeconds').sourceSpelling,spelling,id);
  if(bits){assert.equal(row.sourceDuration.binary64Hex,bits,id);assert.deepEqual(row.numericPreparation,
   {nativeIntegerDecimal:native,implementation:'native-Number(BigInt(decimal))-once-before-source',...row.sourceDuration},id);}
 }
});

test('no string normalization, Unicode normalization, image sorting/dedup or unknown-key inclusion occurs',()=>{
 assert.notEqual(rows.get('unicode-nfc').canonical,rows.get('unicode-nfd').canonical);
 assert.equal(rows.get('raw-prompt-whitespace').keyObjectEntries.find(entry=>entry.key==='prompt').value,' \uFEFF夜 café 😀\n雪\u00a0 ');
 assert.deepEqual(rows.get('images-order-and-duplicates').keyObjectEntries.find(entry=>entry.key==='imageInputs'),
  {key:'imageInputs',type:'object',value:['b.png','a.png','b.png',' 雪 /x?y=1 ']});
 assert.equal(rows.get('all-fields-false').keyObjectEntries.find(entry=>entry.key==='instrumental').value,false);
 assert.equal(rows.get('optional-empty-strings').keyObjectEntries.find(entry=>entry.key==='provider').value,'');
 assert.equal(rows.get('closed-unknown-fields-unused').canonical,rows.get('all-optional-undefined').canonical);
 assert.equal(rows.get('scalar-string-escapes').canonical.includes('\\u0000'),true);
 assert.equal(rows.get('scalar-string-escapes').canonical.includes('line\u2028separator\u2029end'),true);
});

test('prepared provider/model expression branches execute without invoking actual selection or parsing',()=>{
 const expected=[['prepared-explicit-model-ref','google','resolved-model'],['prepared-primary-model-ref','google','primary-model'],
  ['prepared-primary-config-fallback',undefined,' raw primary '],['prepared-provider-default-fallback','comfy',' workflow '],
  ['prepared-selected-provider-id-priority','chosen','direct'],['prepared-selected-ref-provider-fallback','reference-provider','direct'],
  ['prepared-empty-explicit-ref-model','google',''],['prepared-empty-primary-ref-model','google','']];
 for(const [id,provider,model] of expected){
  const entries=rows.get(id).keyObjectEntries;
  assert.deepEqual(entries.find(entry=>entry.key==='provider'),provider===undefined?{key:'provider',type:'undefined'}:{key:'provider',type:'string',value:provider},id);
  assert.deepEqual(entries.find(entry=>entry.key==='model'),{key:'model',type:'string',value:model},id);
 }
 assert.ok(capture.limits.some(value=>value.includes('No tool factory/model parser/provider resolver')));
});

test('four whole modules plus one exact justified tool expression projection reconstruct byte for byte',()=>{
 assert.equal(MUSIC_REQUEST_KEY_PIN,'488631c18fae7cc541ba8fc8beff6cbb0438787b');assert.equal(capture.referencePin,MUSIC_REQUEST_KEY_PIN);
 assert.deepEqual(capture.sourceTree.before,capture.sourceTree.after);assert.equal(capture.sourceTree.before.verifiedTrackedFiles,58558);
 const whole=['packages/normalization-core/src/stable-stringify.ts','src/agents/media-generation-task-status-shared.ts',
  'packages/normalization-core/src/string-coerce.ts','src/agents/session-async-task-status.ts'];
 assert.deepEqual(capture.sourceRecords.filter(row=>row.wholeModule).map(row=>row.path).sort(),whole.sort());
 const projected=capture.sourceRecords.filter(row=>row.executed&&!row.wholeModule);assert.equal(projected.length,1);
 assert.equal(projected[0].path,'src/agents/tools/music-generate-tool.ts');
 for(const row of capture.sourceRecords){
  const source=readFileSync(join(root,row.path));assert.equal(row.sha256,hash(source),row.path);
  if(!row.executed){assert.equal(row.provenanceOnly,true);continue;}
  let generated=source.toString();
  if(row.projection){
   const p=row.projection;assert.ok(p.justification.length>100);assert.equal(p.regions.length,1);
   const region=p.regions[0],bytes=source.subarray(region.startByte,region.endByte);
   assert.equal(region.sourceRegionSha256,hash(bytes));
   assert.ok(bytes.toString().startsWith('            const selectedProviderId = selectedProvider?.id ?? selectedModelRef?.provider;'));
   assert.ok(bytes.toString().includes('const requestKey = buildMediaGenerationRequestKey({'));
   assert.ok(bytes.toString().includes('musicGenerationModelConfig.primary ??'));
   generated=p.prelude+bytes.toString()+p.suffix;assert.equal(p.generatedCode,generated);assert.equal(p.generatedSha256,hash(generated));
  }
  assert.equal(row.transformation,'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
  assert.equal(row.executableSha256,hash(stripTypeScriptTypes(generated,{mode:'transform',sourceMap:false})));
 }
 assert.ok(capture.sourceRecords.some(row=>row.path==='LICENSE'&&row.provenanceOnly));
 for(const binding of capture.importBindings){
  if(binding.generatedCode)assert.equal(binding.generatedSha256,hash(binding.generatedCode));
  if(binding.source)assert.equal(binding.sourceSha256,hash(readFileSync(join(root,binding.source))));
 }
 assert.deepEqual(capture.dynamicImports,[]);
});

test('observer delegates same object to original wrapper with explicit unused import and runtime receipts',()=>{
 assert.deepEqual(capture.observationSeams.map(row=>[row.name,row.implementation]),
  [['buildMediaGenerationRequestKey-argument','transparent-same-reference-observer-then-unchanged-source-wrapper']]);
 assert.ok(capture.serviceFacadeLedger.every(row=>row.productionExecuted===false&&row.limit.length>50));
 assert.equal(capture.runtime.version,'24.22.1');assert.equal(capture.runtime.sha256,hash(readFileSync(capture.runtime.executable)));
 assert.equal(capture.exporter.sha256,hash(readFileSync(new URL('./capture-music-request-key.mjs',import.meta.url))));
 assert.equal(capture.harness.sha256,hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url))));
});

test('second fresh capture is plain deterministic source observation matching saved CLI fixture',async()=>{
 assert.deepEqual(await captureMusicRequestKey(root),capture);assert.deepEqual(JSON.parse(JSON.stringify(capture)),capture);
 const fixture=JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/music-request-key.json',import.meta.url)));
 assert.deepEqual(fixture,capture);
});
