// Ordinary successful whole-source Automations factory callbacks only.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureAutomationFactory } from './capture-automation-factory.mjs';

const source = process.env.OPENCLAW_AUTOMATION_FACTORY_SOURCE ?? '/tmp/openclaw-488631c';
const capture = await captureAutomationFactory(source);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const call = id => rows.get(id).gatewayCalls.at(-1);

test('unchanged model factory executes all nine ordinary action callbacks with standard results', () => {
  assert.equal(rows.size, 19);
  assert.deepEqual([...new Set([...rows.values()].map(row => row.arguments.action))].sort(),
    ['add', 'get', 'list', 'remove', 'run', 'runs', 'status', 'update', 'wake']);
  for (const row of rows.values()) {
    assert.equal(row.tool.name, 'automations');
    assert.equal(row.tool.label, 'Automations');
    assert.equal(row.tool.executeType, 'function');
    assert.equal(row.result.content[0].type, 'text');
    assert.equal(row.result.content[0].text, JSON.stringify(row.result.details, null, 2));
    assert.equal(row.gatewayCalls.length, row.expectedGatewayCalls);
    assert.equal(row.gatewayCalls.at(-1).method, row.expectedMethod);
    assert.deepEqual(row.deferredCalls, []);
    assert.equal(row.validInput, true);
    assert.equal(row.validOutput, true);
    assert.equal(row.policyConstructionCalls, 1);
    assert.equal(row.policyAssertionCalls, 0);
  }
  assert.deepEqual(call('get-id-alias').params, { id: 'fixture-job' });
  assert.deepEqual(call('runs-specific').params, { id: 'fixture-job', runId: 'fixture-run' });
});

test('model run defaults to due and records explicit force with bounded wait options', () => {
  assert.deepEqual(call('run-default-due').params, { id: 'fixture-job', mode: 'due', waitTimeoutMs: 60000 });
  assert.deepEqual(call('run-explicit-force').params, { id: 'fixture-job', mode: 'force', waitTimeoutMs: 2500 });
  assert.deepEqual(call('run-wait-cap').params, { id: 'fixture-job', mode: 'due', waitTimeoutMs: 600000 });
  assert.equal(call('run-default-due').options.timeoutMs, 120000);
  assert.equal(call('run-explicit-force').options.timeoutMs, 62500);
  assert.equal(call('run-wait-cap').options.timeoutMs, 660000);
  assert.equal(rows.get('run-enqueued').result.details.enqueued, true);
  assert.match(rows.get('run-enqueued').result.details.note, /Do not schedule a verification job/);
});

test('wake defaults to next heartbeat and routes through supplied caller context', () => {
  assert.deepEqual(call('wake-default').params, { mode: 'next-heartbeat', text: 'Wake 雪😀',
    sessionKey: 'agent:fixture-agent:main', agentId: 'fixture-agent' });
  assert.deepEqual(call('wake-explicit-session').params, { mode: 'now', text: 'Follow up',
    sessionKey: 'agent:fixture-agent:follow-up', agentId: 'fixture-agent' });
  for (const id of ['wake-default', 'wake-explicit-session']) assert.deepEqual(call(id).extra, { expectFinal: false });
});

test('actual create normalization preserves prompt bytes and typed schedules while patch omits defaults', () => {
  const prompt = '  Summarize 雪😀\nKeep spacing.  \n';
  const at = call('add-at-defaults').params;
  assert.deepEqual(at.schedule, { kind: 'at', at: '2026-10-28T10:00:00.000Z' });
  assert.equal(at.payload.message, prompt);
  assert.equal(at.enabled, true);
  assert.equal(at.wakeMode, 'now');
  assert.equal(at.deleteAfterRun, true);
  assert.equal(at.sessionTarget, 'current');
  assert.equal(at.sessionKey, 'agent:fixture-agent:main');
  assert.deepEqual(call('add-every').params.schedule, { kind: 'every', everyMs: 1500, anchorMs: 1793181600000 });
  assert.deepEqual(call('add-cron').params.schedule, { kind: 'cron', expr: '17 * * * *', tz: 'Asia/Shanghai' });
  const isolated = call('add-without-session-context').params;
  assert.equal(isolated.sessionTarget, 'isolated');
  assert.deepEqual(isolated.delivery, { mode: 'announce' });
  assert.equal(Object.hasOwn(isolated, 'sessionKey'), false);
  assert.deepEqual(call('update-name-only').params.patch, { name: 'Renamed automation' });
  assert.deepEqual(call('update-every').params.patch, { schedule: { kind: 'every', everyMs: 3000 } });
  assert.deepEqual(call('update-prompt').params.patch, { payload: { kind: 'agentTurn', message: prompt } });
});

test('list projection and remove revision read are factory callback behavior', () => {
  assert.deepEqual(call('list-default').params, { includeDisabled: false, compact: true });
  assert.deepEqual(call('list-page').params, { includeDisabled: true, compact: true, limit: 5, offset: 2, agentId: 'fixture-agent' });
  assert.equal(rows.get('list-default').result.details.includeDisabled, false);
  assert.equal(rows.get('list-page').result.details.includeDisabled, true);
  assert.match(rows.get('list-page').result.details.inventoryHint, /Counts and pagination describe this filtered view/);
  assert.deepEqual(rows.get('remove').gatewayCalls.map(row => row.method), ['cron.get', 'cron.remove']);
  assert.deepEqual(call('remove').params, { id: 'fixture-job', expectedConfigRevision: 'fixture-revision' });
});

test('source package runtime and explicit facade evidence are independently reproducible', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  for (const name of ['src/agents/tools/cron-tool.ts', 'src/cron/normalize.ts',
    'src/cron/normalize-payload.ts', 'src/agents/tools/cron-tool-canonicalize.ts',
    'src/agents/tools/cron-tool-creator-cap.ts', 'src/agents/tools/cron-tool-write.ts',
    'src/agents/tools/tool-results.ts', 'src/agents/tools/cron-tool-schema.ts',
    'src/agents/tools/cron-tool-output-schema.ts']) assert.ok(capture.sourceRecords.some(row => row.path === name && row.executed));
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(source, row.path));
    assert.equal(hash(bytes), row.sha256);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256);
    }
  }
  for (const row of capture.importBindings) if (row.generatedCode) assert.equal(hash(row.generatedCode), row.generatedSha256);
  for (const pkg of capture.packages) {
    assert.equal(pkg.version, pkg.name === 'zod' ? '4.6.7' : '1.3.37');
    assert.ok(pkg.files.length > 1);
    for (const row of pkg.files) assert.equal(hash(readFileSync(join(pkg.root, row.path))), row.sha256);
  }
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(hash(readFileSync(capture.runtime.executable)), capture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-automation-factory.mjs', import.meta.url))), capture.exporter.sha256);
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.boundaries.factoryInvoked, true);
  assert.equal(capture.boundaries.executeInvoked, true);
  assert.equal(capture.boundaries.policyConstructionExecuted, false);
  assert.equal(capture.boundaries.policyAssertionCalls, 0);
  for (const name of ['gatewayServiceExecuted', 'jobServiceExecuted', 'storageExecuted', 'timersExecuted',
    'lifecycleExecuted', 'executorExecuted', 'runtimeAssemblyExecuted', 'fullFactoryParity']) assert.equal(capture.boundaries[name], false);
  assert.deepEqual(capture.deferredCalls, []);
  assert.deepEqual(capture, JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/automation-factory.json', import.meta.url))));
});
