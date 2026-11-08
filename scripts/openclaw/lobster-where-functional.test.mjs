// Independent source-defined ordinary literals, frozen before first capture.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureLobsterWhere } from './capture-lobster-where.mjs';

const fixturePath = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-where.json', import.meta.url);
const load = () => JSON.parse(readFileSync(fixturePath, 'utf8'));
const cases = () => new Map(load().cases.map(item => [item.id, item.runs]));

test('provenance retains complete unchanged pinned modules and explicit harness boundaries', () => {
  const f = load();
  assert.equal(f.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(f.sourcePackage.version, '2026.9.16');
  assert.equal(f.sourceRecords.length, 15);
  assert.ok(f.sourceRecords.every(r => r.wholeModule && r.executed && /^[a-f0-9]{64}$/.test(r.sha256)));
  assert.ok(f.sourceRecords.some(r => r.path === 'package/dist/src/commands/stdlib/where.js'));
  assert.equal(f.executedWorkflowRuntime, true);
  assert.equal(f.productionCatalogInstalled, false);
  assert.equal(f.checkpointPersistenceExecuted, false);
  assert.equal(f.fullToolRuntimeExecuted, false);
  assert.equal(f.nativeToolExecution, false);
  assert.equal(f.dependencies.length, 5);
  assert.ok(f.license.text.length > 100);
});

test('filtering is lazy, skips serially and returns its original item without extra demand', () => {
  const c = cases(), zero = c.get('zero-demand')[0], one = c.get('skip-and-one-pull')[0];
  assert.deepEqual(zero.trace, ['run:where', 'run:head', 'run:json']);
  assert.deepEqual(zero.counters.input, { opens: 0, yields: 0, finishes: 0 });
  assert.equal(zero.values.outputJson, '[]');
  assert.equal(zero.values.inputJson, '[{"n":0},{"n":2}]');
  assert.deepEqual(one.trace, ['run:where', 'run:head', 'run:json', 'input:open', 'input:yield:0', 'input:yield:1', 'input:finally']);
  assert.deepEqual(one.counters.input, { opens: 1, yields: 2, finishes: 1 });
  assert.equal(one.values.outputJson, '[{"n":2}]');
  assert.deepEqual(one.values.originalIndices, [1]);
  assert.equal(one.values.inputJson, '[{"n":0},{"n":2},{"n":3}]');
});

test('predicate literals, source-specific paths and JavaScript comparisons match independent outputs', () => {
  const c = cases();
  for (const [id, text, indices] of [
    ['numeric-operators', '[{"n":3}]', [2]],
    ['strict-less', '[{"n":1},{"n":2}]', [0, 1]],
    ['numeric-string-equality', '[{"n":"2"}]', [1]],
    ['numeric-radices', '[{"n":10}]', [1]],
    ['numeric-plus-fraction-exponent', '[{"n":1},{"n":2}]', [1, 2]],
    ['boolean', '[{"flag":true,"id":"T"}]', [1]],
    ['boolean-spelling-trailing-space', '[{"v":"true "}]', [1]],
    ['null', '[{"v":null,"id":1},{"v":null,"id":2}]', [0, 1]],
    ['missing-null', '[{"id":1},{"id":2}]', [0, 1]],
    ['retained-empty-path', '[{"a":{"":{"b":2},"b":1},"id":"empty"}]', [0]],
    ['leading-empty-path', '[{"":{"v":2},"v":1}]', [0]],
    ['array-own-index', '[[2,3]]', [1]],
    ['array-own-length', '[[1,2,3]]', [1]],
    ['unboxed-string', '[{"s":"alpha"},{"s":"beta"}]', [0, 1]],
    ['array-loose-number', '[{"v":[2]}]', [1]],
    ['object-loose-string', '[{"v":{"a":1}},{"v":{"a":2}}]', [0, 1]],
    ['utf16-string-comparison', '[{"v":"a"},{"v":"𐀀"}]', [0, 1]],
  ]) {
    assert.equal(c.get(id)[0].values.outputJson, text, id);
    assert.deepEqual(c.get(id)[0].values.originalIndices, indices, id);
  }
});

test('actual structured-input preview and fresh next-stage resume do not rerun the filter', () => {
  const [before, after] = cases().get('checkpoint');
  assert.equal(before.result.halted, true);
  assert.deepEqual(before.result.items[0].subject, { text: '{"n":2}' });
  assert.deepEqual(before.result.items[0].items, [{ n: 2 }]);
  assert.deepEqual(before.counters.input, { opens: 1, yields: 2, finishes: 1 });
  assert.deepEqual(after.trace, ['run:map', 'run:json']);
  assert.deepEqual(after.result.items, [{ value: 'continue', echo: 'continue' }]);
  assert.equal(after.result.halted, false);
});

test('fresh complete capture equals the frozen evidence', async () => {
  const [referenceRoot, archive, dependencies] = [process.env.OPENCLAW_REFERENCE_ROOT, process.env.LOBSTER_REFERENCE_ARCHIVE, process.env.LOBSTER_REFERENCE_DEPENDENCIES];
  assert.ok(referenceRoot && archive && dependencies, 'provide explicit source and archives');
  assert.deepEqual(await captureLobsterWhere({ referenceRoot, archive, dependencies }), load());
});
