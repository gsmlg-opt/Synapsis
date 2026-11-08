import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { projectSnapshotQuery } from '../src/browser/snapshot-query.mjs';

async function fixture(t) {
  const server = createServer((_req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end('<!doctype html><title>Snapshot query</title><style>button{display:block;width:180px;height:42px}</style><main><h1>Query examples</h1><button id="chosen" onclick="window.chosenClicks=(window.chosenClicks||0)+1">Sign IN 雪😀</button><button id="other">Sign out</button><p>Ordinary visible prose</p></main>');
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-query-'));
  const host = new BrowserHost({ profile: 'query', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  t.after(async () => {
    try {
      const pid = host.diagnosticPid;
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally {
      server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}/` });
  return { host, call, targetId, snapshot: args => call('snapshot', { targetId, ...args }), act: request => call('act', { targetId, request }) };
}

test('role query token matching publishes only matching metadata and its exact actionable ref', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.snapshot({ interactive: true, query: ' \uFEFFIN\tSIGN\u00a0雪😀 ' });
  assert.equal(result.matchCount, 1);
  assert.equal(result.summary, '1 matching line(s) in the returned snapshot.');
  assert.match(result.snapshot, /Sign IN 雪😀/);
  assert.equal(result.snapshot.includes('Sign out'), false);
  assert.deepEqual(result.refs.map(ref => ref.name), ['Sign IN 雪😀']);
  assert.equal(result.refCount, 1);
  assert.deepEqual(result.stats, { lines: 1, chars: result.snapshot.length, refs: 1, interactive: 1 });
  await f.act({ kind: 'click', ref: result.refs[0].ref });
  assert.equal((await f.act({ kind: 'evaluate', fn: '() => window.chosenClicks' })).value, 1);
  assert.equal(f.host.tabs.get(f.targetId).refs.size, 2);
});

test('raw query keeps only selected AX nodes and counts informational refs separately', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.snapshot({ snapshotFormat: 'aria', query: 'Sign IN 雪😀' });
  assert.ok(result.matchCount >= 1);
  assert.equal(result.format, 'aria');
  assert.equal(result.nodeCount, result.nodes.length);
  assert.ok(result.nodes.every(node => node.name.toLowerCase().includes('sign in')));
  assert.equal(result.stats.refs, result.nodes.length);
  assert.equal(result.refCount, result.refs.length);
  assert.ok(result.stats.refs > result.refCount);
  assert.equal(result.refs.length, 1);
  assert.equal(result.refs[0].role, 'button');
  await f.act({ kind: 'click', ref: result.refs[0].ref });
  assert.equal((await f.act({ kind: 'evaluate', fn: '() => window.chosenClicks' })).value, 1);
  assert.ok(f.host.tabs.get(f.targetId).refs.size >= result.refs.length);
});

test('AI ARIA query preserves full-source delta and labeled image while serializing filtered text', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const first = await f.snapshot({ refs: 'aria', interactive: true, query: 'sign in', labels: true });
  assert.equal(first.matchCount, 1);
  assert.equal(first.refCount, 1);
  assert.equal(Object.hasOwn(first, 'newElements'), false);
  assert.ok(first.labelsCount >= 2);
  assert.equal(first.content[1].type, 'image');
  const paired = JSON.parse(first.content[0].text);
  assert.equal(paired.snapshot, first.snapshot);
  assert.equal(paired.matchCount, 1);
  assert.equal(paired.refs.length, 1);
  const repeated = await f.snapshot({ refs: 'aria', interactive: true, query: 'sign out' });
  assert.equal(repeated.newElements, 0);
  assert.deepEqual(repeated.refs.map(ref => ref.name), ['Sign out']);
  await f.act({ kind: 'evaluate', fn: '() => { const button=document.createElement("button");button.textContent="New selected";document.querySelector("main").append(button); }' });
  const added = await f.snapshot({ refs: 'aria', interactive: true, query: 'new selected' });
  assert.equal(added.newElements, 1);
  assert.equal(added.matchCount, 1);
  assert.match(added.snapshot, / \[new\]$/);
  const empty = await f.snapshot({ refs: 'aria', interactive: true, query: 'no ordinary matches' });
  assert.equal(empty.matchCount, 0);
  assert.equal(empty.snapshot, '');
  assert.equal(empty.summary, 'No matching lines in the returned snapshot. Refine the query or take a broader snapshot.');
  assert.deepEqual(empty.stats, { lines: 0, chars: 0, refs: 0, interactive: 0 });
  assert.equal(empty.newElements, 0);
  const blank = await f.snapshot({ refs: 'aria', interactive: true, query: ' \t\uFEFF ' });
  assert.equal(Object.hasOwn(blank, 'matchCount'), false);
  assert.equal(blank.refCount, 3);
  assert.equal(blank.newElements, 0);
});

test('query-stage caps retain native JSON representation and independent Unicode/byte limits', () => {
  const node = { ref: 'ax1', role: 'button', name: 'Long selected ' + '雪😀'.repeat(20000), actionable: true };
  const source = { format: 'aria', nodes: [node], nodeCount: 1, refs: [{ ref: node.ref, role: node.role, name: node.name }], refCount: 1, truncated: false, semantics: 'Raw capture ignores maxChars' };
  const capped = projectSnapshotQuery(source, { query: 'long selected', maxChars: 5 });
  assert.equal(capped.matchCount, 1);
  assert.equal(capped.snapshot, '- but');
  assert.equal(capped.nodeCount, 0);
  assert.equal(capped.refCount, 0);
  assert.equal(capped.truncated, true);
  assert.ok(capped.semantics.includes('query maxChars applies independently'));
  const zero = projectSnapshotQuery(source, { query: 'long selected', maxChars: 0 });
  // The final available UTF-16 unit would split an emoji; the safe prefix leaves it unused.
  assert.equal(zero.snapshot.length, 39999);
  assert.equal(zero.stats.chars, 39999);
  assert.ok(Buffer.byteLength(zero.snapshot) <= 262144);
  assert.equal(zero.snapshot.isWellFormed(), true);
  assert.equal(zero.truncated, true);
  assert.equal(source.nodes.length, 1);
  assert.equal(source.refs.length, 1);
  assert.strictEqual(projectSnapshotQuery(source, { query: ' \t ' }), source);
});
