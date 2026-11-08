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
  let loads = 0;
  const server = createServer((req, res) => {
    if (req.url.startsWith('/marker/')) {
      markers.push(decodeURIComponent(req.url.slice('/marker/'.length)));
      res.end('recorded');
      return;
    }
    if (req.url === '/favicon.ico') { res.writeHead(204).end(); return; }
    loads++;
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><title>Batch fixture</title><h1>${req.url === '/next' ? 'Next page' : 'Batch fixture'}</h1>
      <a id="next" href="/next">Next</a><button id="reload" onclick="location.reload()">Reload</button>
      <button id="confirm" onclick="window.confirmed=confirm('Continue batch?')">Confirm</button>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-batch-functional-'));
  const host = new BrowserHost({ profile: 'functional', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  t.after(async () => {
    const pid = host.diagnosticPid;
    assert.equal((await host.close()).cleanup_confirmed, true);
    if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const url = `http://127.0.0.1:${server.address().port}`;
  const { targetId } = await call('open', { targetUrl: url });
  return { host, call, targetId, url, markers, loads: () => loads,
    act: request => call('act', { targetId, request }) };
}

const mark = name => ({ kind: 'evaluate', fn: `async () => { await fetch('/marker/${name}'); return ${JSON.stringify(name)}; }` });

test('nested batches execute depth first and retain rich child results', { timeout: 60000 }, async t => {
  const { act, targetId, markers } = await fixture(t);
  const result = await act({ kind: 'batch', actions: [mark('first'), { kind: 'batch', targetId, actions: [mark('second'), { kind: 'batch', actions: [mark('third')] }, mark('fourth')] }, mark('last')] });
  assert.deepEqual(markers, ['first', 'second', 'third', 'fourth', 'last']);
  assert.equal(result.results[0].value, 'first');
  assert.equal(result.results[1].ok, true);
  assert.equal(result.results[1].results[0].value, 'second');
  assert.equal(result.results[1].results[1].results[0].value, 'third');
  assert.equal(result.results[1].results[2].value, 'fourth');
  assert.equal(result.results[2].value, 'last');
  assert.equal(result.aborted, undefined);
});

test('a valid hundred-descendant batch supports six batch wrappers', { timeout: 60000 }, async t => {
  const { act } = await fixture(t);
  let request = { kind: 'batch', actions: Array.from({ length: 95 }, (_, index) => ({ kind: 'evaluate', fn: `() => (window.steps ??= []).push(${index})` })) };
  for (let depth = 0; depth < 5; depth++) request = { kind: 'batch', actions: [request] };
  let result = await act(request);
  for (let depth = 0; depth < 5; depth++) {
    assert.equal(result.results.length, 1);
    assert.equal(result.results[0].ok, true);
    result = result.results[0];
  }
  assert.equal(result.results.length, 95);
  assert.deepEqual(result.results.map(item => item.value), Array.from({ length: 95 }, (_, index) => index + 1));
  assert.deepEqual((await act({ kind: 'evaluate', fn: '() => window.steps' })).value, Array.from({ length: 95 }, (_, index) => index));
});

test('nested navigation stops remaining children and enclosing actions', { timeout: 60000 }, async t => {
  const { act, call, targetId, url, markers } = await fixture(t);
  const result = await act({ kind: 'batch', stopOnError: false, actions: [mark('before'), { kind: 'batch', stopOnError: false, actions: [mark('inside'), { kind: 'click', selector: '#next' }, mark('inner-after')] }, mark('outer-after')] });
  assert.deepEqual(markers, ['before', 'inside']);
  assert.deepEqual(result.aborted, { reason: 'navigation', afterAction: 2, url: `${url}/next`, skipped: 1 });
  const nested = result.results[1];
  assert.equal(nested.ok, true);
  assert.equal(nested.navigated, true);
  assert.equal(nested.url, `${url}/next`);
  assert.deepEqual(nested.aborted, { reason: 'navigation', afterAction: 2, url: `${url}/next`, skipped: 1 });
  assert.equal(nested.results[1].navigated, true);
  assert.equal(nested.results[1].url, `${url}/next`);
  assert.match((await call('snapshot', { targetId })).snapshot, /Next page/);
});

test('same-URL nested reload stops later actions and final navigation has no empty abort', { timeout: 60000 }, async t => {
  const { act, call, targetId, url, markers, loads } = await fixture(t);
  const result = await act({ kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'click', selector: '#reload' }, mark('inner-after-reload')] }, mark('outer-after-reload')] });
  assert.deepEqual(markers, []);
  assert.equal(loads(), 2);
  assert.deepEqual(result.aborted, { reason: 'navigation', afterAction: 1, url: `${url}/`, skipped: 1 });
  assert.equal(result.results[0].navigated, true);
  assert.deepEqual(result.results[0].aborted, { reason: 'navigation', afterAction: 1, url: `${url}/`, skipped: 1 });
  const finished = await act({ kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'click', selector: '#next' }] }] });
  assert.equal(finished.aborted, undefined);
  assert.equal(finished.results[0].aborted, undefined);
  assert.equal(finished.results[0].navigated, true);
  assert.equal(finished.results[0].results[0].navigated, true);
  assert.match((await call('snapshot', { targetId })).snapshot, /Next page/);
});

test('nested tab close stops remaining enclosing actions', { timeout: 60000 }, async t => {
  const { act, call, targetId, url, markers } = await fixture(t);
  const result = await act({ kind: 'batch', stopOnError: false, actions: [mark('before-close'), { kind: 'batch', stopOnError: false, actions: [{ kind: 'close' }, mark('inner-after-close')] }, mark('outer-after-close')] });
  assert.deepEqual(markers, ['before-close']);
  assert.deepEqual(result.aborted, { reason: 'closed', afterAction: 2, url: `${url}/`, skipped: 1 });
  assert.deepEqual(result.results[1].aborted, { reason: 'closed', afterAction: 1, url: `${url}/`, skipped: 1 });
  assert.equal(result.results[1].results[0].closed, true);
  assert.equal((await call('tabs')).tabs.some(tab => tab.targetId === targetId), false);
});

test('dialog interruption ends every nested batch without dispatching later markers', { timeout: 60000 }, async t => {
  const { act, call, targetId, markers } = await fixture(t);
  const result = await act({ kind: 'batch', stopOnError: false, actions: [mark('before-dialog'), { kind: 'batch', stopOnError: false, actions: [{ kind: 'click', selector: '#confirm' }, mark('inner-after-dialog')] }, mark('outer-after-dialog')] });
  assert.equal(result.dialogPending, true);
  assert.deepEqual(markers, ['before-dialog']);
  const pending = result.browserState.dialogs.pending[0];
  assert.equal(pending.message, 'Continue batch?');
  await call('dialog', { targetId, dialogId: pending.id, accept: true });
  await act({ kind: 'wait', timeMs: 50 });
  assert.equal((await act({ kind: 'evaluate', fn: '() => window.confirmed' })).value, true);
  assert.deepEqual(markers, ['before-dialog']);
  const tabs = await call('tabs');
  assert.equal(tabs.tabs.find(tab => tab.targetId === targetId).browserState.pendingActions.length, 0);
});
