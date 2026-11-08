import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

async function fixture(t) {
  const markers = [];
  const loads = { old: 0, next: 0, decoy: 0 };
  const server = createServer((req, res) => {
    if (req.url.startsWith('/marker/')) { markers.push(req.url.slice('/marker/'.length)); res.end('recorded'); return; }
    if (req.url === '/favicon.ico') { res.writeHead(204).end(); return; }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/old') {
      loads.old++;
      res.end('<!doctype html><title>Original batch page</title><a id="next" href="/next">Next destination</a><button id="reload" onclick="location.reload()">Reload original</button>');
      return;
    }
    if (req.url === '/decoy') { loads.decoy++; res.end('<!doctype html><title>Other tab</title><button>Decoy control</button>'); return; }
    loads.next++;
    res.end(`<!doctype html><meta charset="utf-8"><title>Batch destination 雪😀</title>
      <main><h1>Noninteractive destination heading</h1><p>Ordinary destination prose</p>
      <button id="continue" onclick="window.batchClicks=(window.batchClicks||0)+1">Continue 雪😀</button>
      <button>Other action</button></main>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-batch-navigation-state-'));
  const host = new BrowserHost({ profile: 'batch-navigation-state', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  const url = `http://127.0.0.1:${server.address().port}`;
  const opened = await call('open', { targetUrl: `${url}/old`, label: ' docs ' });
  const decoy = await call('open', { targetUrl: `${url}/decoy`, label: 'other' });
  const tab = host.tabs.get(opened.targetId);
  const captures = [];
  const snapshot = host.snapshot.bind(host);
  host.snapshot = async (selected, args, operation) => {
    captures.push({ targetId: selected.targetId, args: structuredClone(args) });
    return snapshot(selected, args, operation);
  };
  return { host, call, url, tab, targetId: opened.targetId, decoy: host.tabs.get(decoy.targetId), decoySnapshot: host.tabs.get(decoy.targetId).snapshot, loads, markers, captures,
    act: (request, targetId = opened.targetId) => call('act', { targetId, request }) };
}

const mark = name => ({ kind: 'evaluate', fn: `async () => { await fetch('/marker/${name}'); return ${JSON.stringify(name)}; }` });

function assertState(f, result, url, names = ['Continue 雪😀', 'Other action']) {
  assert.equal(result.targetId, f.targetId);
  assert.equal(result.url, url);
  const state = result.pageState;
  assert.ok(state, 'successful nested batch navigation returns compact pageState');
  assert.equal(state.targetId, f.targetId);
  assert.equal(state.url, url);
  assert.equal(state.generation, f.host.generation);
  assert.equal(state.documentGeneration, f.tab.document);
  assert.equal(state.snapshotGeneration, f.tab.snapshot);
  assert.equal(state.format, 'ai');
  assert.equal(state.refsType, 'role');
  assert.equal(state.truncated, false);
  assert.ok(state.snapshot.length > 0 && state.snapshot.length <= 8000);
  assert.ok(state.snapshot.split('\n').length <= 100);
  assert.equal(state.snapshot.isWellFormed(), true);
  assert.equal(state.snapshot.includes('Noninteractive destination heading'), false);
  assert.equal(state.snapshot.includes('Ordinary destination prose'), false);
  assert.equal(state.snapshot.includes('Decoy control'), false);
  assert.deepEqual(state.refs.map(item => item.name), names);
  assert.equal(state.refCount, names.length);
  assert.deepEqual([...f.tab.refs.keys()], state.refs.map(item => item.ref));
  assert.equal(f.decoy.snapshot, f.decoySnapshot);
  assert.equal(Object.hasOwn(result, 'content'), false);
  assert.equal(Object.hasOwn(state, 'content'), false);
  for (const item of state.refs) {
    assert.match(item.ref, /^e\d+$/);
    assert.ok(state.snapshot.includes(`[ref=${item.ref}]`));
    assert.deepEqual(f.tab.refMetadata.get(item.ref), { role: item.role, name: item.name });
  }
  assert.deepEqual(f.captures, [{ targetId: f.targetId, args: { mode: 'efficient' } }]);
  return state.refs[0].ref;
}

for (const selection of ['canonical', 'label']) {
  test(`nested batch ${selection} navigation keeps rich stop receipts and captures once for the exact selected tab`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const request = { kind: 'batch', actions: [mark('before'), { kind: 'batch', actions: [mark('inside'), { kind: 'click', selector: '#next' }, mark('inner-after')] }, mark('outer-after')] };
    const original = structuredClone(request);
    const result = await f.act(request, selection === 'canonical' ? f.targetId : ' docs ');
    assert.deepEqual(request, original);
    const url = `${f.url}/next`;
    const aborted = { reason: 'navigation', afterAction: 2, url, skipped: 1 };
    assert.deepEqual(result.aborted, aborted);
    assert.deepEqual(result.results, [
      { ok: true, value: 'before' },
      { ok: true, navigated: true, url, aborted, results: [{ ok: true, value: 'inside' }, { ok: true, navigated: true, url }] },
    ]);
    assert.deepEqual(f.markers, ['before', 'inside']);
    const ref = assertState(f, result, url);
    assert.ok(f.tab.snapshot > 0);
    assert.equal(Object.hasOwn(result.results[1], 'pageState'), false);
    assert.equal(Object.hasOwn(result.results[1].results[1], 'pageState'), false);
    assert.equal((await f.act({ kind: 'click', ref }, 'docs')).ok, true);
    assert.equal((await f.act({ kind: 'evaluate', fn: '() => window.batchClicks' })).value, 1);
    assert.deepEqual(f.markers, ['before', 'inside']);
    assert.deepEqual(f.loads, { old: 1, next: 1, decoy: 1 });
  });
}

test('final-position nested navigation publishes state from navigated results without fabricated aborted metadata', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.act({ kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'click', selector: '#next' }] }] });
  const url = `${f.url}/next`;
  assert.equal(Object.hasOwn(result, 'aborted'), false);
  assert.deepEqual(result.results, [{ ok: true, navigated: true, url, results: [{ ok: true, navigated: true, url }] }]);
  const ref = assertState(f, result, url);
  await f.act({ kind: 'click', ref });
  assert.equal((await f.act({ kind: 'evaluate', fn: '() => window.batchClicks' })).value, 1);
  assert.deepEqual(f.loads, { old: 1, next: 1, decoy: 1 });
});

test('same-URL main-frame reload produces one fresh batch state and stops remaining markers', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const document = f.tab.document;
  const result = await f.act({ kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'click', selector: '#reload' }, mark('inner-after')] }, mark('outer-after')] }, 'docs');
  const url = `${f.url}/old`;
  const aborted = { reason: 'navigation', afterAction: 1, url, skipped: 1 };
  assert.deepEqual(result.aborted, aborted);
  assert.deepEqual(result.results, [{ ok: true, navigated: true, url, aborted, results: [{ ok: true, navigated: true, url }] }]);
  const ref = assertState(f, result, url, ['Next destination', 'Reload original']);
  assert.ok(result.pageState.documentGeneration > document);
  assert.equal((await f.act({ kind: 'evaluate', ref, fn: 'element => element.id' })).value, 'next');
  assert.deepEqual(f.markers, []);
  assert.deepEqual(f.loads, { old: 2, next: 0, decoy: 1 });
});

test('standalone successful navigation click keeps explicit snapshot before a new-page ref action', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.act({ kind: 'click', selector: '#next' }, 'docs');
  assert.equal(result.ok, true);
  assert.equal(result.url, `${f.url}/next`);
  assert.equal(Object.hasOwn(result, 'pageState'), false);
  assert.equal(Object.hasOwn(result, 'pageStateUnavailable'), false);
  assert.deepEqual(f.captures, []);
  const state = await f.call('snapshot', { targetId: 'docs', mode: 'efficient' });
  const ref = state.refs.find(item => item.name === 'Continue 雪😀').ref;
  assert.equal((await f.act({ kind: 'click', ref })).ok, true);
  assert.equal((await f.act({ kind: 'evaluate', fn: '() => window.batchClicks' })).value, 1);
  assert.deepEqual(f.loads, { old: 1, next: 1, decoy: 1 });
});
