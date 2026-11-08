import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { renderAriaYaml } from '../src/browser/aria-yaml.mjs';
import { BrowserHost } from '../src/browser/host.mjs';

const fixture = JSON.parse(await readFile(new URL('./fixtures/browser-aria-yaml.json', import.meta.url)));
const options = { depth: 100, limit: 500, maxChars: 40000, interactive: false, compact: false };
const allocator = (start = 100) => { let sequence = start; return () => `e${++sequence}`; };
function normalizeAliases(snapshot, refs) {
  // The fixture has ordinary names/scalars, so each substitution targets one
  // known formatter token; never normalize arbitrary occurrences of eNN text.
  for (const info of refs) snapshot = snapshot.replace(`[ref=${info.ref}]`, `[ref=${info.sourceRef}]`);
  return snapshot;
}

test('frozen pinned YAML body vectors preserve ordinary text and explicit shaping', () => {
  assert.equal(fixture.referenceCommit, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(fixture.sourceRecords.length, 4);
  for (const vector of fixture.vectors) {
    const result = renderAriaYaml(vector.yaml, { ...options, ...vector.options, depth: vector.options.maxDepth ?? 100 }, allocator());
    assert.equal(normalizeAliases(result.snapshot, result.refs), vector.expected.snapshot, vector.name);
    assert.deepEqual(Object.fromEntries(result.refs.map(({ sourceRef, role, name }) => [sourceRef, { role, ...(name ? { name } : {}) }])), vector.expected.refs, vector.name);
    assert.deepEqual([...result.deltaKeys], result.refs.map(info => info.sourceRef), vector.name);
    assert.equal(result.truncated, false, vector.name);
  }
});

test('YAML local budgets retain whole lines, exported identities, and bounded deltas', () => {
  const yaml = '- button "First" [ref=e1]\n- button "Second" [ref=f2e2]\n- paragraph: body';
  const baseline = renderAriaYaml(yaml, options, allocator());
  const first = baseline.snapshot.split('\n')[0];
  for (const bound of [{ limit: 1 }, { maxChars: first.length }]) {
    const result = renderAriaYaml(yaml, { ...options, ...bound }, allocator());
    assert.equal(result.snapshot, first);
    assert.deepEqual(result.refs, baseline.refs.slice(0, 1));
    assert.deepEqual([...result.deltaKeys], ['e1']);
    assert.equal(result.truncated, true);
  }
  for (const bound of [{ limit: 0 }, { maxChars: 0 }]) {
    const result = renderAriaYaml('', { ...options, ...bound }, allocator());
    assert.equal(result.snapshot, ''); assert.deepEqual(result.refs, []); assert.equal(result.truncated, true);
  }
  const delta = renderAriaYaml(yaml, { ...options, previousKeys: new Set(['e1']), limit: 2 }, allocator());
  assert.equal(delta.snapshot, `${first}\n- button "Second" [ref=e102] [new]`);
  assert.equal(delta.newElements, 1); assert.deepEqual([...delta.deltaKeys], ['e1', 'f2e2']);
  const unicode = '- paragraph: ' + '界'.repeat(90000);
  const bytes = renderAriaYaml(unicode, { ...options, maxChars: 300000 }, allocator());
  assert.equal(bytes.snapshot, ''); assert.deepEqual(bytes.refs, []); assert.equal(bytes.truncated, true);
});

test('public YAML host capture matches raw formatter text and exact actionable source refs', { timeout: 60000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-aria-yaml-'));
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/frame') return res.end('<button>Frame action</button><label>Frame field<input placeholder="Frame hint"></label>');
    res.end(`<!doctype html><title>YAML fixture</title><h2>Current work</h2>
      <p>First paragraph<br>Second line: today's work</p><a href="/details">Details: today's work</a>
      <label>Notes<input placeholder="Write: here" value="First value"></label>
      <button aria-pressed="mixed" onclick="window.clicked=true">Save: today's work</button>
      <input type="checkbox" aria-label="Selected" checked><iframe src="/frame"></iframe>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const host = new BrowserHost({ profile: 'aria-yaml', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => {
    try { assert.equal((await host.close()).cleanup_confirmed, true); }
    finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}/` });
  await call('act', { targetId, request: { kind: 'wait', loadState: 'load' } });
  const page = host.tabs.get(targetId).page;
  const capture = page.ariaSnapshot.bind(page); const getByRef = page.getByRef.bind(page);
  const captures = []; const boundSources = [];
  page.ariaSnapshot = async settings => { const yaml = await capture(settings); captures.push({ settings, yaml }); return yaml; };
  page.getByRef = source => { boundSources.push(source); return getByRef(source); };
  const result = await call('snapshot', { targetId, refs: 'aria', limit: 500, depth: 100, maxChars: 40000 });
  assert.equal(captures.length, 1);
  assert.equal(captures[0].settings.mode, 'ai');
  assert.ok(captures[0].settings.signal instanceof AbortSignal);
  assert.ok(Number.isFinite(captures[0].settings.timeout) && captures[0].settings.timeout > 0);
  assert.equal(result.refs.length, boundSources.length);
  const expected = renderAriaYaml(captures[0].yaml, options, allocator());
  const actualRefs = result.refs.map((info, index) => ({ ...info, sourceRef: boundSources[index] }));
  assert.equal(normalizeAliases(result.snapshot, actualRefs), captures[0].yaml);
  assert.equal(normalizeAliases(result.snapshot, actualRefs), normalizeAliases(expected.snapshot, expected.refs));
  assert.deepEqual(actualRefs.map(({ ref: _ref, ...info }) => info), expected.refs.map(({ ref: _ref, ...info }) => info));
  assert.ok(boundSources.some(source => /^f\d+e\d+$/.test(source)));
  assert.match(result.snapshot, /\n\s+- \/url: \/details/);
  assert.match(result.snapshot, /\n\s+- \/placeholder: ['"]?Write: here/);
  assert.match(result.snapshot, /\[pressed=mixed\]/);
  const button = result.refs.find(info => info.name === "Save: today's work");
  await call('act', { targetId, request: { kind: 'click', ref: button.ref } });
  assert.equal((await call('act', { targetId, request: { kind: 'evaluate', fn: '() => window.clicked' } })).value, true);
});
