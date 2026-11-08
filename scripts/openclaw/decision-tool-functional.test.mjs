// Ordinary full-source Decision factory and callback success only.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureDecisionTool } from './capture-decision-tool.mjs';
const capture = await captureDecisionTool();
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole decision factory produces complete schemas descriptions and successful callbacks', () => {
  assert.equal(rows.size, 12);
  for (const row of rows.values()) {
    assert.equal(row.tool.name, 'decision_evaluate');
    assert.equal(row.tool.label, 'Decision evaluation');
    assert.equal(row.tool.resultContentSource, 'network');
    assert.deepEqual(row.tool.parameters, capture.schemas.input);
    assert.deepEqual(row.tool.outputSchema, capture.schemas.output);
    assert.match(row.tool.description, /Evaluate only supplied state/);
    assert.match(row.tool.description, /The selected provider supports/);
    assert.equal(row.result.details.status, 'ok');
    assert.equal(row.result.content[0].text, JSON.stringify(row.result.details));
    assert.deepEqual(row.result.details, row.outcome);
    assert.equal(row.validInput, true);
    assert.equal(row.validResult, true);
    assert.equal(row.evaluateCalls.length, 1);
    assert.equal(row.completeCalls, 1);
    assert.deepEqual(row.trace.filter(value => value === 'evaluate' || value === 'complete'), ['evaluate', 'complete']);
    assert.deepEqual(row.argumentsAfter, row.arguments);
    assert.equal(row.evaluateCalls[0].timeoutMs, 30000);
    assert.equal(row.evaluateCalls[0].purpose, 'decision_evaluate');
    assert.equal(row.evaluateCalls[0].agentId, 'fixture-agent');
    assert.match(row.evaluateCalls[0].rubricVersion, /^decision-v1-[0-9a-f]{24}$/);
  }
});

test('six native kinds preserve explicit values metadata estimates usage and evidence shape', () => {
  const types = new Set();
  for (const row of rows.values()) for (const answer of Object.values(row.outcome.result.answers)) types.add(answer.type);
  assert.deepEqual([...types].sort(), ['boolean', 'box', 'choice', 'score', 'sort', 'tags']);
  assert.equal(rows.get('v2-categorical-boolean-zero').outcome.result.answers.q.probabilityTrue, 0);
  assert.equal(rows.get('v2-text-three').outcome.result.answers.route.choice, 'a');
  assert.deepEqual(rows.get('v2-text-three').outcome.result.answers.route.probabilities, {a:0.2,b:0.7});
  assert.equal(rows.get('v2-text-three').outcome.result.answers.score.score, 0.71);
  assert.deepEqual(rows.get('v2-image-box').batch.state, rows.get('v2-image-box').arguments.state);
  assert.deepEqual(rows.get('v2-list-sort').outcome.result.answers.q.order, ['a', 'b']);
  assert.deepEqual(rows.get('v2-tags').outcome.result.answers.q.tags, [
    {id:'red',applies:false,probability:0.2},{id:'blue',applies:null,probability:0.5}]);
  const usage = rows.get('v2-text-three').outcome.result.usage;
  assert.deepEqual(usage, {inputTokens:3,outputTokens:0,costUsd:0,units:{unit:'requests',amount:1},raw:{fixture:[1,2]}});
});

test('legacy conversion actual selection resolver and capability guidance retain positive semantics', () => {
  assert.deepEqual(rows.get('legacy-text').batch.state, {type:'text',text:'  Supplied text 雪😀\n'});
  assert.deepEqual(rows.get('legacy-json-null').batch.state, {type:'json',value:null});
  assert.deepEqual(rows.get('legacy-json-array').batch.state, {type:'json',value:['one',null,{two:2}]});
  assert.deepEqual(rows.get('v2-json-structured').batch.state, {type:'json',value:{z:2,a:['first',{nested:'雪😀'}]}});
  assert.match(rows.get('v2-json-structured').tool.description, /at most 400 questions/);
  assert.match(rows.get('v2-json-structured').tool.description, /Optional confidence is a provider-specific distribution metric/);
  assert.equal(rows.get('snapshot-catalog').manifestCalls, 1);
  assert.equal(rows.get('runtime-config-reread').evaluateCalls[0].selection.model, 'second-model');
  assert.equal(rows.get('runtime-config-reread').initialSelection.model, 'model');
  assert.equal(rows.get('runtime-config-default').configReads, 2);
  assert.equal(rows.get('runtime-config-default').selection.provider, 'fixture-provider');
  assert.equal(rows.get('legacy-text').evaluateCalls[0].rubricVersion, rows.get('v2-json-structured').evaluateCalls[0].rubricVersion);
  assert.equal(rows.get('legacy-json-null').evaluateCalls[0].rubricVersion, rows.get('legacy-json-array').evaluateCalls[0].rubricVersion);
});

test('all executed whole modules and actual TypeBox files have independently reproducible hashes', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const whole = capture.sourceRecords.filter(row => row.executed);
  for (const row of capture.sourceRecords) assert.equal(hash(readFileSync(join('/tmp/openclaw-488631c', row.path))), row.sha256);
  assert.ok(whole.some(row => row.path === 'src/agents/tools/decision-tool.ts'));
  assert.ok(whole.some(row => row.path === 'src/agents/tools/decision-tool-contract.ts'));
  for (const row of whole) {
    const bytes = readFileSync(join('/tmp/openclaw-488631c', row.path));
    assert.equal(hash(bytes), row.sha256);
    assert.equal(hash(stripTypeScriptTypes(bytes.toString(), {mode:'transform',sourceMap:false})), row.executableSha256);
    assert.equal(row.wholeModule, true);
  }
  for (const binding of capture.importBindings) if (binding.generatedCode) assert.equal(hash(binding.generatedCode), binding.generatedSha256);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.ok(capture.typebox.files.length > 1);
  for (const row of capture.typebox.files) assert.equal(hash(readFileSync(join(capture.typebox.root, row.path.slice('typebox/'.length)))), row.sha256);
  assert.equal(hash(capture.host.generatedCode), capture.host.sha256);
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(hash(readFileSync(capture.runtime.executable)), capture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-decision-tool.mjs', import.meta.url))), capture.exporter.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))), capture.harness.sha256);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
});

test('synthetic runtime and config boundaries are explicit and do not claim provider host execution', () => {
  assert.equal(capture.boundaries.factoryInvoked, true);
  assert.equal(capture.boundaries.callbackInvoked, true);
  assert.equal(capture.boundaries.realDecisionRuntimeExecuted, false);
  assert.equal(capture.boundaries.realProviderHostExecuted, false);
  assert.equal(capture.boundaries.networkExecuted, false);
  assert.equal(capture.boundaries.registrationExecuted, false);
  assert.deepEqual(capture.deferredCalls, []);
  for (const word of ['synthetic decision runtime','configuration','provider-host','positive']) assert.ok(capture.limits.some(line => line.includes(word)), word);
});

test('fresh capture matches the complete frozen standalone fixture', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/decision-tool.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureDecisionTool(), fixture);
});
