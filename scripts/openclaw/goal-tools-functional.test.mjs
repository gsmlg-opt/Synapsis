import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureGoalTools } from './capture-goal-tools.mjs';

const capture = await captureGoalTools('/tmp/openclaw-488631c');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');

test('original goal factories retain model instructions and exact public schemas', () => {
  const schemas={
    get_goal:{type:'object',properties:{}},
    create_goal:{type:'object',properties:{
      objective:{type:'string',description:'Concrete objective; explicit request only.'},
      token_budget:{anyOf:[{type:'integer',minimum:1},{type:'null'}],description:'Positive token budget. Omit or pass null unless explicitly requested.'}},required:['objective']},
    update_goal:{type:'object',properties:{status:{type:'string',enum:['complete','blocked'],description:'complete | blocked.'},
      note:{type:'string',description:'Short status note.'}},required:['status']},
    progress_card:{type:'object',properties:{markdown:{type:'string'},plan:{type:'array',items:{type:'object',properties:{
      step:{type:'string',minLength:1},status:{anyOf:[{type:'string',const:'pending'},{type:'string',const:'in_progress'},{type:'string',const:'completed'}]}},
      required:['step','status'],additionalProperties:false},maxItems:50}},additionalProperties:false},
  };
  const metadata={
    get_goal:{name:'get_goal',label:'Get Goal',displaySummary:'Get the current thread goal',
      description:'Get the current session goal, including its full objective, status, token usage, and optional budget.'},
    create_goal:{name:'create_goal',label:'Create Goal',displaySummary:'Create a thread goal',
      description:'Create a goal only when explicitly requested by the user or system instructions. Set a positive token_budget only when a budget is explicitly requested; otherwise omit it or pass null. Fails if a goal already exists; the user must clear it before starting another.'},
    update_goal:{name:'update_goal',label:'Update Goal',displaySummary:'Complete or block a thread goal',
      description:'Mark the session goal complete only when the full objective is verified and no required work remains. Mark it blocked only when the same blocker has recurred for at least three consecutive goal turns and no meaningful progress is possible without user input or an external change. After the user resumes a blocked goal, count those turns from the resume. Difficulty, incomplete work, or a nearly exhausted budget do not justify completion or blocking. Updating a goal does not reply to the user; provide the requested final response afterward.'},
  };
  for(const name of Object.keys(schemas))assert.deepEqual(capture.tools[name].parameters,schemas[name]);
  for(const [name,expected] of Object.entries(metadata))assert.deepEqual(capture.tools[name],{...expected,parameters:schemas[name]});
  assert.equal(capture.tools.progress_card.name,'progress_card');
  assert.equal(capture.tools.progress_card.label,'Progress Card');
  assert.equal('displaySummary' in capture.tools.progress_card,false);
  assert.deepEqual(Object.keys(capture.tools.progress_card).sort(),['description','label','name','parameters']);
  assert.match(capture.tools.progress_card.description,/Each call replaces the whole card/);
  assert.match(capture.tools.progress_card.description,/Max 8 KB markdown, 50 steps/);
  assert.deepEqual(Object.keys(capture.tools).sort(), ['create_goal', 'get_goal', 'progress_card', 'update_goal']);
  assert.equal(capture.tools.get_goal.label, 'Get Goal');
  assert.equal(capture.tools.create_goal.label, 'Create Goal');
  assert.equal(capture.tools.update_goal.label, 'Update Goal');
  assert.deepEqual(capture.tools.get_goal.parameters, { type: 'object', properties: {} });
  assert.deepEqual(capture.tools.create_goal.parameters.required, ['objective']);
  assert.deepEqual(capture.tools.create_goal.parameters.properties.token_budget.anyOf, [{type:'integer',minimum:1},{type:'null'}]);
  assert.deepEqual(capture.tools.update_goal.parameters.properties.status.enum, ['complete', 'blocked']);
  assert.match(capture.tools.create_goal.description, /only when explicitly requested/);
  assert.match(capture.tools.create_goal.description, /positive token_budget only when a budget is explicitly requested/);
  assert.match(capture.tools.update_goal.description, /full objective is verified and no required work remains/);
  assert.match(capture.tools.update_goal.description, /at least three consecutive goal turns/);
  assert.match(capture.tools.update_goal.description, /count those turns from the resume/);
});

test('ordinary successful callbacks preserve objectives budgets results and side effects', () => {
  for (const id of ['create-no-budget', 'create-positive-budget', 'create-null-budget']) {
    const row = rows.get(id);
    assert.equal(row.result.details.status, 'created');
    assert.equal(row.result.details.goal.objective, 'Finish supplied objective 雪😀');
    assert.equal(row.result.details.goal.status, 'active');
    assert.equal(row.result.details.goal.tokensUsed, 0);
    assert.deepEqual(row.result.content, [{type:'text',text:JSON.stringify(row.result.details,null,2)}]);
    assert.equal(row.calls.filter(call => call.callback === 'patchSessionEntryCore').length, 1);
    assert.equal(row.calls.filter(call => call.callback === 'recordSessionGoalChanged').length, 1);
    assert.deepEqual(row.argumentsAfter, row.arguments);
  }
  assert.equal(rows.get('create-positive-budget').result.details.goal.tokenBudget, 1000);
  assert.equal(new Set(['create-no-budget','create-positive-budget','create-null-budget'].map(id=>rows.get(id).result.details.goal.id)).size,3);
  assert.equal('tokenBudget' in rows.get('create-no-budget').result.details.goal, false);
  assert.equal('tokenBudget' in rows.get('create-null-budget').result.details.goal, false);
  assert.deepEqual(rows.get('get-missing').result.details, {status:'missing'});
  assert.equal(rows.get('get-active').result.details.goal.tokensUsed, 25);
  assert.equal(rows.get('get-updated').result.details.goal.status, 'complete');
  for (const status of ['complete', 'blocked']) {
    const row = rows.get('update-' + status);
    assert.equal(row.result.details.status, 'updated');
    assert.equal(row.result.details.goal.status, status);
    assert.equal(row.result.details.goal.tokensUsed, 25);
    assert.equal(row.result.details.goal.lastStatusNote, 'Supplied ordinary status note');
    assert.match(row.result.details.nextAction, /no reply was sent to the user/);
  }
  const repeated=rows.get('update-complete-repeat');
  assert.equal(repeated.result.details.goal.completedAt,1700000000000);
  assert.equal(repeated.result.details.goal.updatedAt,1800000000000);
  assert.equal(repeated.result.details.goal.id,repeated.snapshotBefore.goal.id);
  assert.deepEqual(capture.accounting.map(row => [row.id,row.goal.tokensUsed,row.goal.status]), [
    ['fresh-usage',25,'active'], ['unbudgeted-usage',25,'active']]);
});

test('root progress callbacks preserve normalized input exact gateway calls and private outcome', () => {
  const markdown = rows.get('progress-markdown');
  assert.equal(markdown.gatewayCalls[0].method, 'progressCard.put');
  assert.deepEqual(markdown.gatewayCalls[0].params, {sessionKey:'agent:fixture:main',agentId:'fixture',markdown:'Reviewed 2 of 4 supplied files.'});
  assert.deepEqual(markdown.result.details, {revision:1,steps:null});
  assert.equal(markdown.result.content[0].text, 'Progress card updated (rev 1)');
  assert.deepEqual(rows.get('progress-plan').result.details, {revision:2,steps:{completed:1,total:2}});
  assert.deepEqual(rows.get('progress-plan').planSaved, [true]);
  assert.deepEqual(rows.get('progress-update').planSaved, [false]);
  assert.deepEqual(rows.get('progress-clear').result.details, {revision:null,steps:null});
  assert.equal(rows.get('progress-clear').result.content[0].text, 'Progress card cleared');
  assert.equal(rows.get('progress-clear').outcome, '{"markdown":null,"steps":null}');
  for (const id of ['progress-markdown','progress-plan','progress-update','progress-clear']) {
    const row=rows.get(id);
    assert.equal(row.gatewayCalls.length,1);
    assert.deepEqual(JSON.parse(row.result.content[1].text),row.result.details);
    assert.equal(typeof row.outcome,'string');
    assert.deepEqual(row.argumentsAfter,row.arguments);
  }
});

test('independent source runtime and generated facade provenance is reproducible', () => {
  assert.equal(capture.referencePin,'488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles,58558);
  assert.deepEqual(capture.sourceTree.before,capture.sourceTree.after);
  for (const path of ['src/agents/tools/goal-tools.ts','src/config/sessions/goals.ts','src/config/sessions/goals-transitions.ts','src/config/sessions/types.ts','src/agents/tools/progress-card-tool.ts','src/agents/tools/progress-card-tool-outcome.ts','src/session-cards/progress-card-input.ts','packages/gateway-protocol/src/schema/progress-card.ts']) {
    const row=capture.sourceRecords.find(row=>row.path===path);
    assert.equal(row.executed,true,path);
  }
  for (const row of capture.sourceRecords) {
    const bytes=readFileSync(join('/tmp/openclaw-488631c',row.path));
    assert.equal(hash(bytes),row.sha256);
    if(row.executed){assert.equal(row.wholeModule,true);assert.equal(hash(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})),row.executableSha256);}
  }
  for(const row of capture.importBindings)if(row.generatedCode)assert.equal(hash(row.generatedCode),row.generatedSha256);
  assert.equal(capture.typebox.version,'1.3.37');
  for(const row of capture.typebox.files)assert.equal(hash(readFileSync(join(capture.typebox.root,row.path.slice('typebox/'.length)))),row.sha256);
  assert.equal(capture.runtime.version,'24.22.1');
  assert.equal(hash(readFileSync(capture.runtime.executable)),capture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-goal-tools.mjs',import.meta.url))),capture.exporter.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url))),capture.harness.sha256);
  assert.equal(hash(capture.host.generatedCode),capture.host.sha256);
});

test('supplied boundaries leave persistence ownership transport and semantic obligations unexecuted', () => {
  assert.equal(capture.boundaries.factoryInvoked,true);
  assert.equal(capture.boundaries.callbackInvoked,true);
  for(const key of ['productionPersistenceExecuted','sqliteWorkerExecuted','sessionOwnerExecuted','gatewayTransportExecuted','fullAssemblyExecuted','rootEligibilityExecuted','blockedRuleEnforcementProven','networkExecuted'])assert.equal(capture.boundaries[key],false,key);
  assert.deepEqual(capture.deferredCalls,[]);
  assert.equal(capture.canonicalization.strategy,'post-execution generated UUID and timestamp substitution');
  assert.ok(capture.limits.some(line=>line.includes('SQLite')));
  assert.ok(capture.limits.some(line=>line.includes('three consecutive')));
});

test('fresh VM repeat equals complete standalone frozen fixture', async () => {
  const fixture=JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/goal-tools.json',import.meta.url)));
  assert.deepEqual(capture,fixture);
  assert.deepEqual(await captureGoalTools('/tmp/openclaw-488631c'),fixture);
});
