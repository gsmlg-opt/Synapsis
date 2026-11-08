// Literal ordinary-success expectations from the pinned llm-task callback.
// This tests the independent reference capture, not a host implementation/runtime.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { captureLlmTask } from './capture-llm-task.mjs';

const root = '/tmp/openclaw-488631c';
const captured = await captureLlmTask(root);
const rows = new Map(captured.vectors.map(row => [row.id, row]));
const systemPrompt = 'You are a JSON-only function. Return ONLY a valid JSON value. Do not wrap in markdown fences. Do not include commentary. Do not call tools.';
const expected = {
  'primary-string': {prompt:' classify 雪😀 ',input:{z:2,a:['one',null]},json:{ok:true,text:'雪😀'}},
  'primary-object': {prompt:'task',json:null},
  'plugin-defaults': {prompt:'task',model:'anthropic/claude-fixture',authProfileId:'profile-default',timeoutMs:45000,maxTokens:123,json:true},
  'request-overrides': {prompt:' task ',input:[false,0,' padded '],model:'openrouter/vendor/model',authProfileId:'chosen-profile',timeoutMs:12345,maxTokens:17,temperature:0,reasoning:'medium',json:0},
  'explicit-provider-nested': {prompt:'task',model:'openrouter/vendor/nested/model',json:' padded value '},
  'configured-alias': {prompt:'task',model:'anthropic/claude-alias',json:[1,null,'雪😀']},
  'configured-provider-alias': {prompt:'task',model:'anthropic/claude-alias',json:false},
  'fenced-object': {prompt:'task',input:null,json:{nested:[1,false,null]}},
  'fenced-array': {prompt:'task',json:['a',2]},
  'valid-schema': {prompt:'task',json:{kind:'ok',count:2}},
  'local-ref-schema': {prompt:'task',json:['one','雪😀']},
  'plugin-timeout-token-only': {prompt:'task',input:false,timeoutMs:61000,maxTokens:256,json:'done'},
};
const digest = value => createHash('sha256').update(value).digest('hex');

test('whole callback forwards exact single isolated completion requests and source model precedence', () => {
  assert.deepEqual([...rows.keys()].sort(), Object.keys(expected).sort());
  for (const [id, value] of Object.entries(expected)) {
    const row = rows.get(id);
    const call = {
      messages:[{role:'user',content:`TASK:\n${value.prompt}\n\nINPUT_JSON:\n${JSON.stringify(value.input ?? null,null,2)}\n`}],
      systemPrompt,
      purpose:'llm-task',
      execution:{mode:'isolated-agent-runtime',timeoutMs:value.timeoutMs ?? 30000},
    };
    for (const key of ['model','maxTokens','temperature','reasoning']) {
      if (Object.hasOwn(value,key)) call[key] = value[key];
    }
    if (value.authProfileId) call.execution.authProfileId = value.authProfileId;
    assert.deepEqual(row.completeCalls, [call], id);
    assert.equal(row.argumentsUnchanged, true, id);
    assert.equal(row.arguments.prompt, value.prompt, id);
    if (Object.hasOwn(value,'input')) assert.deepEqual(row.arguments.input,value.input,id);
    else assert.equal(Object.hasOwn(row.arguments,'input'),false,id);
  }
  // Overrides are authored differently: aliases can change provider, explicit
  // provider routes retain nested model IDs, and zero temperature is content.
  assert.equal(rows.get('request-overrides').arguments.provider,' openrouter ');
  assert.equal(rows.get('request-overrides').arguments.model,' openrouter/vendor/model ');
  assert.equal(rows.get('configured-alias').pluginConfig.defaultModel,' short ');
  assert.equal(rows.get('request-overrides').arguments.thinking,' medium ');
});

test('actual JSON parsing, fences, schema success and textResult retain every JSON value', () => {
  for (const [id,value] of Object.entries(expected)) {
    assert.deepEqual(rows.get(id).result, {
      content:[{type:'text',text:JSON.stringify(value.json,null,2)}],
      details:{json:value.json,provider:'actual-provider',model:'actual-model'},
    },id);
  }
  assert.equal(Object.hasOwn(rows.get('valid-schema').result.details.json,'optional'),false);
  assert.equal(rows.get('valid-schema').arguments.schema.properties.optional.default,'unused');
  assert.deepEqual(rows.get('local-ref-schema').arguments.schema.items,{$ref:'#/$defs/entry'});
  assert.match(rows.get('fenced-object').completion.text,/```JSON/);
  assert.match(rows.get('fenced-array').completion.text,/```\n/);
});

test('executed full sources, actual TypeBox bytes and frozen capture remain reproducible', () => {
  assert.equal(captured.referencePin,'488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const executed = new Set();
  for (const record of captured.sourceRecords) {
    const bytes = readFileSync(join(root,record.path));
    assert.equal(digest(bytes),record.sha256,record.path);
    if (record.executed) {
      executed.add(record.path);
      assert.equal(digest(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})),record.executableSha256,record.path);
    }
  }
  for (const source of ['extensions/llm-task/src/llm-task-tool.ts','extensions/llm-task/src/llm-task-tool-definition.ts','src/agents/model-selection-shared.ts','src/plugins/schema-validator.ts','packages/normalization-core/src/string-coerce.ts','src/agents/tools/tool-results.ts']) {
    assert.ok(executed.has(source),source);
  }
  assert.equal(captured.typebox.version,'1.3.37');
  const entry = createRequire(join(root,'package.json')).resolve('typebox');
  const typeboxRoot = dirname(dirname(entry));
  assert.ok(captured.typebox.files.length > 0);
  for (const dep of captured.typebox.files) {
    const path = dep.path.replace(/^typebox\//,'');
    assert.equal(digest(readFileSync(join(typeboxRoot,path))),dep.sha256,dep.path);
  }
  assert.equal(captured.harness.sha256,digest(readFileSync(new URL('./capture-llm-task.mjs',import.meta.url))));
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/llm-task.json',import.meta.url)));
  assert.deepEqual(captured,fixture);
});
