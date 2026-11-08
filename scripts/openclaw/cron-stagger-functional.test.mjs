// Ordinary pure scheduling reference evidence; lifecycle and Synapsis execution are separate.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureCronStagger, CRON_STAGGER_PIN } from './capture-cron-stagger.mjs';

const root = '/tmp/openclaw-488631c';
const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/cron-stagger.json', import.meta.url)));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const nowMs = 1793095200000;
const rows = new Map(fixture.observations.map(row => [row.id, row]));
const sourceHashes = {
  'src/cron/service/jobs-scheduling.ts': 'd09f2e83cff17017ce19710522733cba0da17299523660bd6123f067fa37af8d',
  'packages/normalization-core/src/expect.ts': 'ea995c248b00f6c9e17bbc9c3085971feeb0ee614d2bd9c8c902e8bc26cacb7a',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
  'src/infra/map-size.ts': '36f06592cf1ae20d291e921da7cb42e8d7814372ca2d0745bec7a54a2a8a4409',
  'src/cron/schedule-number.ts': '832c2837631dce4065d03696c2bd062c7b91e029cca0aac2496bed053a71e5cc',
  'src/cron/schedule.ts': 'e3ba3f6e080488430cbeef5b0c9e25d3eaad8eba3afabbfbce970e972895ecd6',
  'src/cron/stagger.ts': 'a4f9236ea2571076932df830fe9d64be1675dfb0241f2a33d9cc97c2ac5e782d',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'src/infra/format-time/parse-offsetless-zoned-datetime.ts': 'f58e07c1849997a131e8cac042a571ff41d8714f6074e2a5dd290cd7391f0a56',
  'src/cron/parse.ts': '4bffa54d9d545928fe5aaf7c111c1d9db0923d61bd3d2ea3a06bb72aa112180a',
  'src/shared/iso-time.ts': '79699b601ce5f17bb85ec4838c1bca8fdd5560895406b42ecf6cfa4fd332e871',
};

test('eleven complete pinned modules and fixed runtime retain exact source provenance', () => {
  assert.equal(fixture.referencePin, CRON_STAGGER_PIN);
  assert.equal(fixture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(fixture.sourceTree.before.verified, true);
  assert.equal(fixture.sourceTree.before.commit, CRON_STAGGER_PIN);
  assert.equal(fixture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.sourceTree.before, fixture.sourceTree.after);
  assert.deepEqual(Object.fromEntries(fixture.sourceRecords.map(row => [row.path, row.sha256])), sourceHashes);
  assert.equal(fixture.transformation, 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
  for (const row of fixture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    assert.equal(row.executed, true);
    assert.equal(row.wholeModule, true);
    assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  assert.equal(fixture.exporter.sha256, hash(readFileSync(new URL('./capture-cron-stagger.mjs', import.meta.url))));
  assert.equal(fixture.runtime.version, '24.22.1');
  assert.equal(process.versions.node, fixture.runtime.version);
  assert.equal(fixture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(fixture.runtime.sha256, hash(readFileSync(fixture.runtime.executable)));
});

test('actual Croner whole module comes from exact lock-pinned10.0.1 archive', () => {
  assert.equal(fixture.package.name, 'croner');
  assert.equal(fixture.package.version, '10.0.1');
  assert.equal(fixture.package.integrity, 'sha512-ixNtAJndqh173VQ4KodSdJEI6nuioBWI0V1ITNKhZZsO0pEMoDxz539T4FTTbSZ/xIOSuDnzxLVRqBVSvPNE2g==');
  assert.equal(fixture.package.archiveSha256, 'd6d93c286125fed567b986a576ff1daa74e72d56bb63fe28248ca17cfcb00cee');
  assert.equal(fixture.package.moduleSha256, 'a2eb1f669c605d4775116947209c91dfec4afdcc76fe8407134938bf5a09a600');
  assert.equal(hash(readFileSync(fixture.package.archive)), fixture.package.archiveSha256);
  assert.equal(hash(readFileSync(fixture.package.module)), fixture.package.moduleSha256);
  assert.equal(fixture.package.upstreamLockSha256, hash(readFileSync(join(root, 'pnpm-lock.yaml'))));
  assert.equal(fixture.package.wholeModule, true);
  assert.equal(fixture.package.sourceImplementationExecuted, true);
});

test('ordinary explicit normalization keeps zero and source default detector matches hour grammar', () => {
  assert.deepEqual(fixture.normalization, [
    { input: 0, normalized: 0 }, { input: 1, normalized: 1 },
    { input: 300000, normalized: 300000 }, { input: 1234.9, normalized: 1234 },
    { input: '0', normalized: 0 }, { input: '300000', normalized: 300000 },
    { input: ' +300000 ', normalized: 300000 },
  ]);
  assert.deepEqual(fixture.defaults, [
    { expr: '0 * * * *', staggerMs: 300000 },
    { expr: '0 */2 * * *', staggerMs: 300000 },
    { expr: '0 9,* * * *', staggerMs: 300000 },
    { expr: '0 9 * * *', staggerMs: null },
    { expr: '30 * * * *', staggerMs: null },
    { expr: '0 0 * * * *', staggerMs: 300000 },
    { expr: '0 0 */3 * * *', staggerMs: 300000 },
  ]);
});

test('UUID hashing produces stable slots and only advances after the effective current slot', () => {
  const expected = [
    ['hourly-window', nowMs, 1793095352325, 1793091752325, 152325],
    ['hourly-before-window', nowMs - 60000, 1793095352325, 1793091752325, 152325],
    ['hourly-at-effective-slot', 1793095352325, 1793098952325, 1793095352325, 152325],
    ['hourly-after-effective-slot', 1793095352326, 1793098952325, 1793095352325, 152325],
    ['different-uuid-window', nowMs, 1793095467436, 1793091867436, 267436],
    ['custom-minute-window', nowMs, 1793095232325, 1793094932325, 32325],
  ];
  for (const [id, instant, next, previous, offset] of expected) {
    const row = rows.get(id);
    assert.equal(row.nowMs, instant, id);
    assert.equal(row.nextRunAtMs, next, id);
    assert.equal(row.previousRunAtMs, previous, id);
    assert.equal(row.hashDerivedOffsetMs, offset, id);
    assert.equal(createHash('sha256').update(row.job.id).digest().readUInt32BE(0) % row.job.schedule.staggerMs, offset, id);
    assert.equal(row.job.schedule.tz, 'Etc/UTC');
  }
  assert.equal(rows.get('hourly-window').job.id, '11111111-1111-4111-8111-111111111111');
  assert.equal(rows.get('different-uuid-window').job.id, '22222222-2222-4222-8222-222222222222');
});

test('explicit zero and one-millisecond windows execute exact unstaggered future hours', () => {
  for (const [id, staggerMs] of [['explicit-zero', 0], ['one-ms-window-offset-zero', 1]]) {
    const row = rows.get(id);
    assert.equal(row.job.schedule.staggerMs, staggerMs);
    assert.equal(row.hashDerivedOffsetMs, 0);
    assert.equal(row.nowMs, nowMs);
    assert.equal(row.nextRunAtMs, nowMs + 3600000);
    assert.equal(row.previousRunAtMs, nowMs);
  }
});

test('Kathmandu quarter-hour UTC phase retains source timezone and strict slot boundaries', () => {
  const expected = [
    ['kathmandu-before-hour', nowMs, 1793096252325, 1793092652325],
    ['kathmandu-hour-window', 1793096100000, 1793096252325, 1793092652325],
    ['kathmandu-at-slot', 1793096252325, 1793099852325, 1793096252325],
  ];
  assert.equal(Date.parse('2026-10-27T16:00:00+05:45'), nowMs + 900000);
  for (const [id, instant, next, previous] of expected) {
    const row = rows.get(id);
    assert.equal(row.job.schedule.tz, 'Asia/Kathmandu');
    assert.equal(row.hashDerivedOffsetMs, 152325);
    assert.equal(row.nowMs, instant);
    assert.equal(row.nextRunAtMs, next);
    assert.equal(row.previousRunAtMs, previous);
  }
});

test('all observed calls are pure scheduling with no deferred lifecycle invocation', () => {
  assert.equal(fixture.observations.length, 11);
  assert.equal(rows.size, 11);
  assert.deepEqual(fixture.entry, { path: 'src/cron/service/jobs-scheduling.ts',
    exports: ['computeJobNextRunAtMs', 'computeJobPreviousRunAtOrBeforeMs'], calls: 22 });
  assert.deepEqual(fixture.deferredCalls, []);
  assert.equal(fixture.deferredBindings.length, 9);
  for (const binding of fixture.deferredBindings) {
    assert.equal(binding.kind, 'uninvoked-throwing-binding');
    assert.equal(binding.sourceImplementationExecuted, false);
    assert.equal(binding.invocationCount, 0);
    assert.equal(hash(binding.generatedCode), binding.generatedSha256);
    assert.equal(hash(readFileSync(join(root, binding.path))), binding.sourceSha256);
  }
  assert.deepEqual(fixture.scope, { pureCronNextExecuted: true, pureCronPreviousExecuted: true,
    staggerNormalizationExecuted: true, cronerExecuted: true, jobLifecycleExecuted: false,
    toolFactoryExecuted: false, synapsisExecutionProved: false });
  for (const row of fixture.observations) {
    assert.ok(row.nextRunAtMs > row.nowMs, row.id);
    assert.ok(row.previousRunAtMs <= row.nowMs, row.id);
    assert.equal(row.job.enabled, true);
    assert.deepEqual(row.job.state, {});
  }
});

test('fresh whole-source execution exactly reproduces the frozen capture', async () => {
  assert.deepEqual(await captureCronStagger(root), fixture);
});
