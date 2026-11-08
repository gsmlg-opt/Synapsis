// Positive pure timestamp computations only; no scheduler service or Croner executes.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureScheduleComputation, SCHEDULE_COMPUTATION_PIN } from './capture-schedule-computation.mjs';

const root = '/tmp/openclaw-488631c';
const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/schedule-computation.json', import.meta.url)));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const nowMs = 1793095200000;
const rows = new Map(fixture.observations.map(row => [row.id, row]));
const sourceHashes = {
  'src/cron/schedule.ts': 'e3ba3f6e080488430cbeef5b0c9e25d3eaad8eba3afabbfbce970e972895ecd6',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'src/infra/format-time/parse-offsetless-zoned-datetime.ts': 'f58e07c1849997a131e8cac042a571ff41d8714f6074e2a5dd290cd7391f0a56',
  'src/infra/map-size.ts': '36f06592cf1ae20d291e921da7cb42e8d7814372ca2d0745bec7a54a2a8a4409',
  'src/cron/parse.ts': '4bffa54d9d545928fe5aaf7c111c1d9db0923d61bd3d2ea3a06bb72aa112180a',
  'src/cron/schedule-number.ts': '832c2837631dce4065d03696c2bd062c7b91e029cca0aac2496bed053a71e5cc',
  'src/shared/iso-time.ts': '79699b601ce5f17bb85ec4838c1bca8fdd5560895406b42ecf6cfa4fd332e871',
};

test('eight complete modules, pinned checkout receipts, exporter and fixed runtime match exact bytes', () => {
  assert.equal(fixture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(fixture.referencePin, SCHEDULE_COMPUTATION_PIN);
  assert.equal(fixture.transformation, 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
  assert.deepEqual(fixture.entry, { path: 'src/cron/schedule.ts', export: 'computeNextRunAtMs', calls: 24 });
  assert.equal(fixture.sourceTree.before.verified, true);
  assert.equal(fixture.sourceTree.before.commit, fixture.referencePin);
  assert.equal(fixture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.sourceTree.before, fixture.sourceTree.after);
  assert.deepEqual(Object.fromEntries(fixture.sourceRecords.map(row => [row.path, row.sha256])), sourceHashes);
  for (const row of fixture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    assert.equal(row.executed, true);
    assert.equal(row.wholeModule, true);
    assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  assert.equal(fixture.exporter.sha256, hash(readFileSync(new URL('./capture-schedule-computation.mjs', import.meta.url))));
  assert.equal(fixture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(fixture.runtime.version, '24.22.1');
  assert.equal(process.versions.node, fixture.runtime.version);
  assert.equal(fixture.runtime.sha256, hash(readFileSync(fixture.runtime.executable)));
});

test('UTC, explicit fractional-hour offset, offsetless UTC and epoch strings select the same future absolute time', () => {
  assert.equal(Date.parse('2026-10-27T10:00:00Z'), nowMs);
  assert.equal(Date.parse('2026-10-27T10:01:00Z'), 1793095260000);
  assert.equal(Date.parse('2026-10-27T15:46:00+05:45'), 1793095260000);
  const expectedInputs = {
    'absolute-z': '2026-10-27T10:01:00Z',
    'absolute-offset': '2026-10-27T15:46:00+05:45',
    'offsetless-default-utc': '2026-10-27T10:01:00',
    'epoch-milliseconds-string': '1793095260000',
  };
  for (const [id, at] of Object.entries(expectedInputs)) {
    const row = rows.get(id);
    assert.deepEqual(row.schedule, { kind: 'at', at });
    assert.equal(row.nowMs, nowMs);
    assert.equal(row.nextRunAtMs, nowMs + 60000);
    assert.deepEqual(row.subsequent, { nowMs: nowMs + 30000, nextRunAtMs: nowMs + 60000 });
  }
});

test('date-only and 24:00 normalize to UTC midnight while long ISO fractions truncate to milliseconds', () => {
  const expected = [
    ['date-only-default-utc', '2026-10-28', 1793145600000],
    ['fractional-iso-millisecond-truncation', '2026-10-27T10:01:00.123456Z', 1793095260123],
    ['offsetless-end-of-day-utc', '2026-10-27T24:00:00', 1793145600000],
  ];
  assert.equal(Date.parse('2026-10-28T00:00:00.000Z'), 1793145600000);
  assert.equal(Date.parse('2026-10-27T10:01:00.123456Z'), 1793095260123);
  for (const [id, at, nextRunAtMs] of expected) {
    const row = rows.get(id);
    assert.deepEqual(row.schedule, { kind: 'at', at });
    assert.equal(row.nowMs, nowMs);
    assert.equal(row.nextRunAtMs, nextRunAtMs);
    assert.deepEqual(row.subsequent, { nowMs: nowMs + 30000, nextRunAtMs });
  }
});

test('positive interval anchor boundaries and subsequent advancement preserve strictly future phase arithmetic', () => {
  const expected = [
    ['interval-before-anchor', nowMs + 5000, 5000],
    ['interval-exact-anchor', nowMs, 1500],
    ['interval-fractional-step-elapsed', nowMs - 500, 1000],
    ['interval-exact-later-boundary', nowMs - 3000, 1500],
    ['interval-omitted-anchor-helper', undefined, 1500],
  ];
  for (const [id, anchorMs, offset] of expected) {
    const row = rows.get(id);
    assert.deepEqual(row.schedule, { kind: 'every', everyMs: 1500, ...(anchorMs === undefined ? {} : { anchorMs }) });
    assert.equal(row.nowMs, nowMs);
    assert.equal(row.nextRunAtMs, nowMs + offset);
    assert.deepEqual(row.subsequent, { nowMs: nowMs + offset, nextRunAtMs: nowMs + offset + 1500 });
    assert.ok(row.nextRunAtMs > row.nowMs);
    assert.ok(row.subsequent.nextRunAtMs > row.subsequent.nowMs);
    if (anchorMs !== undefined) {
      assert.equal((row.nextRunAtMs - anchorMs) % 1500, 0);
      assert.equal((row.subsequent.nextRunAtMs - anchorMs) % 1500, 0);
    }
  }
  assert.equal(fixture.observations.length, 12);
  assert.equal(rows.size, 12);
  for (const row of fixture.observations) assert.deepEqual(row.scheduleAfter, row.schedule, row.id);
});

test('Croner binding audit stays zero and fixture scopes execution to the actual pure helper', () => {
  assert.deepEqual(fixture.bindingCalls, []);
  assert.equal(fixture.importBindings.length, 1);
  const binding = fixture.importBindings[0];
  assert.equal(binding.importer, fixture.entry.path);
  assert.equal(binding.specifier, 'croner');
  assert.deepEqual(binding.exports, ['Cron', 'CronDate']);
  assert.equal(binding.kind, 'uninvoked-throwing-binding');
  assert.equal(binding.sourceImplementationExecuted, false);
  assert.equal(binding.invocationCount, 0);
  assert.equal(hash(binding.generatedCode), binding.generatedSha256);
  assert.deepEqual(fixture.scope, { pureTimestampComputationExecuted: true, cronerExecuted: false,
    cronBranchExecuted: false, jobServiceExecuted: false, oneShotLifecycleExecuted: false,
    toolFactoryExecuted: false, eligibilityExecuted: false, runtimeAssemblyExecuted: false });
  for (const term of ['complete unchanged', 'Croner', 'omitted-anchor', 'one-shot lifecycle', 'eligibility', 'runtime assembly']) {
    assert.ok(fixture.limits.some(value => value.includes(term)), term);
  }
});

test('fresh whole-source execution reproduces all twelve frozen positive vectors and provenance exactly', { timeout: 60000 }, async () => {
  assert.deepEqual(await captureScheduleComputation(root), fixture);
});
