import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

async function fixture(t) {
  const loads = { old: 0, next: 0 };
  const server = createServer((req, res) => {
    if (req.url === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/old') {
      loads.old++;
      res.end('<!doctype html><title>Original page</title><button>Old control</button>');
      return;
    }
    loads.next++;
    res.end(`<!doctype html><meta charset="utf-8"><title>Navigated page 雪😀</title>
      <style>button,input,a{display:block;min-height:32px}</style><main>
      <h1>Noninteractive heading</h1><p>Ordinary visible prose 雪😀</p>
      <button id="chosen" onclick="window.navigationClicks=(window.navigationClicks||0)+1">Continue 雪😀</button>
      <label>Search 雪😀<input id="search"></label><a href="#section">Jump 雪😀</a>
      <section id="section">Noninteractive section</section></main>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-navigation-state-'));
  const host = new BrowserHost({ profile: 'navigation-state', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  const targetId = opened.targetId;
  assert.equal(Object.hasOwn(opened, 'pageState'), false);
  return { host, call, targetId, loads, nextUrl: `${url}/next`, tab: host.tabs.get(targetId) };
}

async function assertPageState(f, result, url) {
  assert.equal(result.targetId, f.targetId);
  assert.equal(result.url, url);
  assert.equal(result.generation, f.host.generation);
  assert.equal(result.documentGeneration, f.tab.document);
  const state = result.pageState;
  assert.ok(state, 'successful navigate returns efficient pageState without another snapshot call');
  assert.equal(state.generation, result.generation);
  assert.equal(state.targetId, result.targetId);
  assert.equal(state.url, result.url);
  assert.equal(state.documentGeneration, result.documentGeneration);
  assert.equal(state.snapshotGeneration, f.tab.snapshot);
  assert.equal(state.format, 'ai');
  assert.equal(state.refsType, 'role');
  assert.equal(state.truncated, false);
  assert.match(state.semantics, /Native Chromium AX roles/);
  assert.ok(state.snapshot.length > 0 && state.snapshot.length <= 8000);
  assert.ok(state.snapshot.split('\n').length <= 100);
  assert.equal(state.snapshot.isWellFormed(), true);
  assert.equal(state.snapshot.includes('Ordinary visible prose'), false);
  assert.equal(state.snapshot.includes('Noninteractive heading'), false);
  assert.equal(state.snapshot.includes('Noninteractive section'), false);
  assert.equal(state.snapshot.includes('Old control'), false);
  assert.equal(state.refCount, state.refs.length);
  assert.deepEqual(state.refs.map(({ role, name }) => ({ role, name })), [
    { role: 'button', name: 'Continue 雪😀' },
    { role: 'textbox', name: 'Search 雪😀' },
    { role: 'link', name: 'Jump 雪😀' },
  ]);
  assert.deepEqual([...f.tab.refs.keys()], state.refs.map(item => item.ref));
  for (const item of state.refs) {
    assert.match(item.ref, /^e\d+$/);
    assert.ok(state.snapshot.includes(`[ref=${item.ref}]`));
    assert.deepEqual(f.tab.refMetadata.get(item.ref), { role: item.role, name: item.name });
    assert.equal(await f.tab.refs.get(item.ref).evaluate(element => element.isConnected), true);
  }
  const chosen = state.refs.find(item => item.name === 'Continue 雪😀');
  assert.equal(await f.tab.refs.get(chosen.ref).evaluate(element => element.id), 'chosen');
  assert.equal(Object.hasOwn(result, 'content'), false);
  assert.equal(Object.hasOwn(state, 'content'), false);
  return chosen.ref;
}

for (const selection of ['canonical', 'label']) {
  test(`navigate by ${selection} target publishes canonical efficient state for the immediate ref action`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const document = f.tab.document;
    const result = await f.call('navigate', { targetId: selection === 'canonical' ? f.targetId : ' docs ', targetUrl: f.nextUrl });
    const ref = await assertPageState(f, result, f.nextUrl);
    assert.ok(result.documentGeneration > document);
    assert.equal(Object.hasOwn(result.pageState, 'newElements'), false);
    const clicked = await f.call('act', { targetId: f.targetId, request: { kind: 'click', ref } });
    assert.equal(clicked.ok, true);
    const proof = await f.call('act', { targetId: f.targetId, request: { kind: 'evaluate', fn: '() => ({clicks:window.navigationClicks, title:document.title, chosen:document.querySelector("#chosen").textContent})' } });
    assert.deepEqual(proof.value, { clicks: 1, title: 'Navigated page 雪😀', chosen: 'Continue 雪😀' });
    assert.deepEqual(f.loads, { old: 1, next: 1 });
  });
}

test('same-URL and hash navigations each publish fresh retained refs in their current document scope', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  let previous;
  for (const [index, targetUrl] of [f.nextUrl, f.nextUrl, `${f.nextUrl}#section`].entries()) {
    const result = await f.call('navigate', { targetId: index === 1 ? 'docs' : f.targetId, targetUrl });
    const ref = await assertPageState(f, result, targetUrl);
    if (previous) {
      assert.ok(result.documentGeneration > previous.documentGeneration);
      assert.ok(result.pageState.snapshotGeneration > previous.pageState.snapshotGeneration);
      assert.ok(result.pageState.refs.every(item => !previous.pageState.refs.some(old => old.ref === item.ref)));
      assert.ok(previous.pageState.refs.every(item => !f.tab.refs.has(item.ref)));
    }
    if (index < 2) assert.equal(Object.hasOwn(result.pageState, 'newElements'), false);
    else assert.equal(result.pageState.newElements, 0);
    previous = result;
    if (index === 2) {
      await f.call('act', { targetId: 'docs', request: { kind: 'click', ref } });
      assert.equal((await f.call('act', { targetId: f.targetId, request: { kind: 'evaluate', fn: '() => window.navigationClicks' } })).value, 1);
    }
  }
  assert.deepEqual(f.loads, { old: 1, next: 2 });
});
