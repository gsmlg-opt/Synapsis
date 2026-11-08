// Ordinary synthetic SystemOne success only; no paid provider or error suite.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenRouterDecisions } from './capture-openrouter-decisions.mjs';
const capture=await captureOpenRouterDecisions();
const rows=new Map(capture.observations.map(row=>[row.id,row]));
const hash=value=>createHash('sha256').update(value).digest('hex');

test('sixteen complete-source ordinary requests use explicit SystemOne models and release once',()=>{
  assert.equal(rows.size,16);
  for(const row of rows.values()){
    assert.equal(row.request.method,'POST');
    assert.equal(row.request.url,row.baseUrl+'/systemone');
    assert.equal(row.request.timeoutMs,30000);
    assert.equal(row.request.body.model,row.model);
    assert.equal(row.outcome.status,'ok');
    assert.equal(row.outcome.result.model,row.model+'-served');
    assert.equal(row.releaseCount,1);
    assert.deepEqual(row.readerCalls,[{maxBytes:1048576,timeoutMs:30000}]);
  }
});

test('native values retain served provider, explicit choice, fractional score and rounded distributions',()=>{
  const row=rows.get('native-113');
  assert.deepEqual(row.request.body.state,{ticket:'Supplied ticket 😀'});
  assert.deepEqual(row.request.body.questions,{
    check:{type:'noul',instructions:'Is this urgent?'},
    route:{type:'choice',instructions:'Which team?',criteria:{a:null,b:'Billing'}},
    urgency:{type:'score',instructions:'How urgent?',criteria:['Low','High']},
  });
  assert.deepEqual(row.outcome.result.answers,{
    check:{type:'boolean',probabilityTrue:0.37},
    route:{type:'choice',choice:'a',probabilities:{a:0.49,b:0.5},confidence:0.1},
    urgency:{type:'score',score:0.71,probabilities:[0.3,0.69],confidence:0.2},
  });
  assert.deepEqual(row.outcome.result.metadata,{provider:'TypeSafe'});
  assert.deepEqual(row.outcome.result.usage,{inputTokens:476,outputTokens:70,costUsd:0.000019992});
});

test('PNG JPEG supplied image order and boxes remain exact, including explicit empty text',()=>{
  assert.deepEqual(rows.get('image-png').request.body.state,[{type:'image_url',image_url:{url:'data:image/png;base64,AA=='}}]);
  assert.deepEqual(rows.get('image-jpeg-empty-text').request.body.state,['',{type:'image_url',image_url:{url:'data:image/jpeg;base64,AQID'}}]);
  for(const id of ['box-114-png','box-latest-jpeg']){
    const row=rows.get(id);
    assert.deepEqual(row.request.body.state,['Listing photo',{type:'image_url',image_url:{url:row.arguments.state.dataUri}}]);
    assert.deepEqual(row.outcome.result.answers,{target:{type:'box',box:{top:0.25,bottom:0.75,left:0.25,right:0.76},confidence:0.91}});
  }
});

test('legacy and JSON value evidence, zero/absent cost and full raw usage retain distinct meanings',()=>{
  assert.equal(rows.get('legacy-text').request.body.state,'  Explicit text 雪\n');
  assert.deepEqual(rows.get('json-array').request.body.state,['ordered','evidence']);
  assert.equal(rows.get('json-string').request.body.state,'Explicit JSON string');
  assert.deepEqual(rows.get('cost-zero').outcome.result.usage,{inputTokens:0,outputTokens:0,costUsd:0});
  assert.deepEqual(rows.get('cost-absent').outcome.result.usage,{inputTokens:3,outputTokens:1});
  assert.equal(Object.hasOwn(rows.get('cost-absent').outcome.result,'metadata'),false);
  assert.deepEqual(rows.get('usage-extended').outcome.result.usage,{inputTokens:2,outputTokens:1,costUsd:0,
    raw:{input_tokens:2,output_tokens:1,cost:0,provider_units:3,details:{cached:1}}});
  assert.deepEqual(rows.get('structured-instructions').request.body.questions.check,
    {type:'noul',instructions:{ask:'Is this urgent?'},criteria:{true:['Urgent'],false:{label:'Routine'}}});
});

test('actual source routing merges preferences while preserving prepared custom prefix',()=>{
  const row=rows.get('provider-preferences');
  assert.deepEqual(row.request.body.provider,{order:['typesafe'],only:['typesafe'],require_parameters:true});
  assert.deepEqual(row.params,{provider:row.request.body.provider});
  assert.equal(rows.get('custom-prefix').request.url,'https://router.example.test/tenant/api/v1/systemone');
});

test('unchanged whole modules and per-import generated facades have exact executable provenance',()=>{
  const whole=capture.sourceRecords.filter(row=>row.executed);assert.equal(whole.length,15);
  for(const row of whole){
    const bytes=readFileSync(join('/tmp/openclaw-488631c',row.path));
    assert.equal(row.wholeModule,true);assert.equal(row.sha256,hash(bytes));
    assert.equal(row.executableSha256,hash(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})));
  }
  for(const binding of capture.importBindings){
    if(binding.generatedCode)assert.equal(binding.generatedSha256,hash(binding.generatedCode));
    assert.ok(binding.importer&&binding.specifier);
  }
  assert.equal(capture.exporter.sha256,hash(readFileSync(new URL('./capture-openrouter-decisions.mjs',import.meta.url))));
  assert.equal(capture.harness.sha256,hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url))));
  assert.equal(capture.runtime.version,'24.22.1');assert.equal(capture.runtime.sha256,hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles,58558);assert.deepEqual(capture.sourceTree.before,capture.sourceTree.after);
});

test('production lower bodies and host adaptation limits remain disclosed',()=>{
  for(const term of ['Complete unchanged','explicit facades','preference merge','cost','host adaptation','no unsupported/error'])assert.ok(capture.limits.some(value=>value.includes(term)),term);
  assert.deepEqual(capture.deferredCalls,[]);
});

test('fresh whole-source capture reproduces the frozen ordinary vectors exactly',async()=>{
  const fixture=JSON.parse(readFileSync(new URL('../../apps/synapsis_provider/test/fixtures/openclaw/488631c/openrouter-decisions.json',import.meta.url)));
  assert.deepEqual(capture,fixture);assert.deepEqual(await captureOpenRouterDecisions(),fixture);
});
