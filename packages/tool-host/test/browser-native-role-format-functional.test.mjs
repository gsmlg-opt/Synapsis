import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { renderNativeRoleTree } from '../src/browser/native-role-snapshot.mjs';

const fixture = JSON.parse(await readFile(new URL('./fixtures/browser-native-role-format.json', import.meta.url)));
const options = extra => ({ depth: 100, limit: 1000, maxChars: 100000, interactive: false, compact: false, ...extra });
function render(vector, extra = {}) {
  let next = 50;
  return renderNativeRoleTree(vector.nodes, vector.rootBackendNodeId, options({ depth: vector.options.maxDepth ?? 100, ...vector.options, ...extra }), () => `e${next++}`);
}
function normalized(snapshot, refs) {
  const identities = new Map(refs.map(ref => [ref.ref, ref.backendNodeId]));
  return snapshot.replace(/\[ref=(e\d+)\]/g, (_, ref) => {
    assert.ok(identities.has(ref), `Rendered ref ${ref} has a retained backend identity`);
    return `[backend=${identities.get(ref)}]`;
  });
}

test('fixture records the exact pin and complete ordinal pipeline with explicit platform facades', async () => {
  assert.equal(fixture.referenceCommit, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  for (const name of ['cdp-role-snapshot.ts', 'cdp-role-snapshot-tree.ts', 'pw-role-snapshot.ts', 'cdp-ax.ts', 'snapshot-roles.ts']) {
    assert.ok(fixture.sourceRecords.some(record => record.path.endsWith(`/${name}`) && record.executed && /^[a-f0-9]{64}$/.test(record.executableSha256)));
  }
  assert.equal(fixture.facades.length, 3);
  assert.equal(fixture.sourceRecords.filter(record => record.provenanceOnly && !record.executed).length, 3);
  const script = await readFile(new URL('../../../scripts/openclaw/capture-browser-role.mjs', import.meta.url));
  assert.equal(createHash('sha256').update(script).digest('hex'), fixture.scriptSha256);
});

for (const vector of fixture.vectors) {
  test(`native role text matches pinned full scoped pipeline: ${vector.name}`, () => {
    const actual = render(vector);
    const expected = vector.expected.result;
    const sourceRefs = Object.entries(expected.refs).map(([ref, info]) => ({ ref, role: info.role, name: info.name ?? '', backendNodeId: info.backendDOMNodeId, nth: info.nth ?? 0 }));
    assert.equal(normalized(actual.snapshot, actual.refs), normalized(expected.snapshot, sourceRefs));
    assert.equal(actual.truncated, false);
    assert.deepEqual(actual.refs.map(({ ref: _alias, ...info }) => info).sort((a, b) => a.backendNodeId - b.backendNodeId), sourceRefs.map(({ ref: _alias, nth: _nth, ...info }) => info).sort((a, b) => a.backendNodeId - b.backendNodeId));
    assert.deepEqual(actual.deltaKeys, new Set(sourceRefs.map(info => JSON.stringify([info.role, info.name, info.nth]))));
  });
}

test('depth-shaped duplicate delta retains the source ordinal through later wider capture', () => {
  const vector = fixture.vectors.find(item => item.name === 'depth-filter-retains-original-ordinal');
  const shallow = render(vector);
  const wide = render(vector, { depth: 100, previousKeys: shallow.deltaKeys });
  assert.equal(wide.newElements, 1);
  const deep = wide.snapshot.split('\n').find(line => line.includes('[nth=1]'));
  assert.match(deep, /\[new\]$/);
  const shallowLine = wide.snapshot.split('\n').find(line => line.includes('Repeat') && !line.includes('[nth='));
  assert.ok(!shallowLine.includes('[new]'));
});

test('compact shaping retains suppressed-group depth, including local leading indentation', () => {
  const vector = fixture.vectors.find(item => item.name === 'compact-retains-depth-and-ordinal');
  const visibleRoot = render(vector);
  assert.match(visibleRoot.snapshot, /^    - button "Repeat".*\[nth=1\]$/m);
  const transparentRoot = { ...vector, nodes: vector.nodes.map((node, index) => index ? node : { ...node, role: { value: 'generic' }, name: { value: '' } }) };
  // Local depth indentation is retained; the pin's final trim() removes it only
  // on the first emitted line. This is explicitly outside complete text parity.
  assert.match(render(transparentRoot).snapshot, /^  - button "Repeat".*\[nth=1\]/);
});

test('true empty fallback uses shared budgets, emits no refs or delta identities and reports zero new elements', () => {
  for (const name of ['empty-transparent-root', 'interactive-empty', 'compact-empty']) {
    const vector = fixture.vectors.find(item => item.name === name);
    const text = vector.expected.result.snapshot;
    const exact = render(vector, { limit: 1, maxChars: text.length, previousKeys: new Set(['prior']) });
    assert.equal(exact.snapshot, text);
    assert.equal(exact.truncated, false);
    assert.deepEqual(exact.refs, []);
    assert.deepEqual(exact.deltaKeys, new Set());
    assert.equal(exact.newElements, 0);
    for (const budget of [{ limit: 0 }, { maxChars: 0 }, { maxChars: text.length - 1 }]) {
      const bounded = render(vector, { ...budget, previousKeys: new Set() });
      assert.equal(bounded.snapshot, '');
      assert.equal(bounded.truncated, true);
      assert.deepEqual(bounded.refs, []);
      assert.deepEqual(bounded.deltaKeys, new Set());
      assert.equal(bounded.newElements, 0);
    }
  }
});

test('nonempty output cut to zero remains blank and retained refs match whole output lines', () => {
  const vector = fixture.vectors.find(item => item.name === 'duplicates-unique-mixed-roles-and-names');
  for (const budget of [{ limit: 0 }, { maxChars: 0 }, { maxChars: 1 }]) {
    const result = render(vector, { ...budget, previousKeys: new Set() });
    assert.equal(result.snapshot, '');
    assert.equal(result.truncated, true);
    assert.deepEqual(result.refs, []);
    assert.deepEqual(result.deltaKeys, new Set());
    assert.equal(result.newElements, 0);
  }
  const limited = render(vector, { limit: 2 });
  const exact = render(vector, { maxChars: limited.snapshot.length });
  assert.equal(exact.snapshot, limited.snapshot);
  assert.deepEqual(exact.refs, limited.refs);
  assert.equal(exact.deltaKeys.size, 2);
  assert.equal(exact.truncated, true);
  assert.match(exact.snapshot, /\[nth=1\]$/);
});
