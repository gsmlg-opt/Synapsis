// Independent ordinary source literals; written before the first map capture.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureLobsterMap } from './capture-lobster-map.mjs';

const fixturePath = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-map.json', import.meta.url);
const load = () => JSON.parse(readFileSync(fixturePath, 'utf8'));
const cases = () => new Map(load().cases.map(item => [item.id, item.runs]));

test('whole pinned modules execute without installing a production catalog or persisting a checkpoint', () => {
  const fixture = load();
  assert.equal(fixture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(fixture.sourcePackage.version, '2026.9.16');
  assert.equal(fixture.executedWorkflowRuntime, true);
  assert.equal(fixture.productionCatalogInstalled, false);
  assert.equal(fixture.checkpointPersistenceExecuted, false);
  assert.equal(fixture.nativeToolExecution, false);
  assert.equal(fixture.fullToolRuntimeExecuted, false);
  assert.equal(fixture.sourceRecords.length, 14);
  assert.ok(fixture.sourceRecords.every(item => item.wholeModule && item.executed && /^[a-f0-9]{64}$/.test(item.sha256)));
  assert.ok(fixture.sourceRecords.some(item => item.path === 'package/dist/src/commands/stdlib/map.js'));
  assert.equal(fixture.dependencies.length, 5);
  assert.ok(fixture.license.text.length > 100);
});

test('map remains lazy and closes a started iterator after exactly one demanded item', () => {
  const c = cases(), zero = c.get('unopened')[0], one = c.get('one-pull')[0];
  assert.deepEqual(zero.trace, ['run:map', 'run:head', 'run:json']);
  assert.deepEqual(zero.counters.input, { opens: 0, yields: 0, finishes: 0 });
  assert.equal(zero.map.inputJson, '[{"id":1},{"id":2}]');
  assert.equal(zero.map.outputJson, '[]');
  assert.deepEqual(one.trace, ['run:map', 'run:head', 'run:json', 'input:open', 'input:yield:0', 'input:finally']);
  assert.deepEqual(one.counters.input, { opens: 1, yields: 1, finishes: 1 });
  assert.equal(one.map.inputJson, '[{"id":1,"marker":"seen"},{"id":2}]');
  assert.equal(one.map.outputJson, '[{"id":1,"marker":"seen"}]');
  assert.deepEqual(one.map.aliases, [{ original: 0, packet: -1, value: -1 }]);
});

test('ordered assignments mutate original objects while wrappers retain their original reference', () => {
  const c = cases();
  for (const [id, expected] of [
    ['sequential-alias', '[{"id":"changed","first":"original","second":"original!","third":"changed"}]'],
    ['wrap-original', '[{"packet":{"id":"A","nested":{"v":2}},"summary":"A","whole":"{\\"id\\":\\"A\\",\\"nested\\":{\\"v\\":2}}"}]'],
    ['unwrap-literal', '[{"id":1},{"id":2}]'],
    ['array-wrapper', '[{"value":[1,2],"size":"2","first":"1"},{"value":[3,4],"size":"2","first":"3"}]'],
    ['primitive-wrapper', '[{"value":"alpha","copy":"alpha"},{"value":"beta","copy":"beta"}]'],
    ['null-wrapper', '[{"value":null,"copy":""},{"value":null,"copy":""}]'],
    ['assignment-parsing', '[{"nested":{"v":true},"k":"x","key":"last","out":"true","literal":"x"}]'],
    ['ordered-json', '[{"data":{"b":2,"a":1},"text":"{\\"b\\":2,\\"a\\":1}"},{"data":{"a":1,"b":2},"text":"{\\"a\\":1,\\"b\\":2}"}]'],
    ['array-unwrap', '[2,3]'],
  ]) assert.equal(c.get(id)[0].map.outputJson, expected, id);
  assert.equal(c.get('sequential-alias')[0].map.inputJson, c.get('sequential-alias')[0].map.outputJson);
  assert.deepEqual(c.get('sequential-alias')[0].map.aliases, [{ original: 0, packet: -1, value: -1 }]);
  assert.deepEqual(c.get('wrap-original')[0].map.aliases, [{ original: -1, packet: 0, value: -1 }]);
  assert.equal(c.get('wrap-original')[0].map.inputJson, '[{"id":"A","nested":{"v":2}}]');
  assert.deepEqual(c.get('array-wrapper')[0].map.aliases, [{ original: -1, packet: -1, value: 0 }, { original: -1, packet: -1, value: 1 }]);
});

test('map preview and fresh next-stage response use actual request validation and original modules', () => {
  const [before, after] = cases().get('checkpoint');
  assert.equal(before.result.halted, true);
  assert.deepEqual(before.result.items[0].subject, { text: '{"id":"A","preview":"A"}' });
  assert.equal(before.map.inputJson, '[{"id":"A","preview":"A"}]');
  assert.deepEqual(after.result.items, [{ value: 'continue', echo: 'continue' }]);
  assert.deepEqual(after.trace, ['run:map', 'run:json']);
  assert.equal(after.result.halted, false);
});

test('a fresh capture reproduces the complete frozen reference evidence', async () => {
  const [referenceRoot, archive, dependencies] = [process.env.OPENCLAW_REFERENCE_ROOT, process.env.LOBSTER_REFERENCE_ARCHIVE, process.env.LOBSTER_REFERENCE_DEPENDENCIES];
  assert.ok(referenceRoot && archive && dependencies, 'provide explicit source/archive/dependency evidence');
  assert.deepEqual(await captureLobsterMap({ referenceRoot, archive, dependencies }), load());
});
