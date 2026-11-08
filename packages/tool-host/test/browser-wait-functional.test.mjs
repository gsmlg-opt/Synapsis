import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

async function fixture(t) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end('<!doctype html><title>Wait fixture</title><h1>Ready text</h1><button>Wait action</button><div class="repeated">First match</div><div class="repeated" hidden>Second match</div>');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-wait-functional-'));
  const host = new BrowserHost({ profile: 'wait', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  t.after(async () => {
    try {
      const pid = host.diagnosticPid;
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
      assert.equal(host.operation, null);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const { targetId } = await call('open', { targetUrl: `${origin}/` });
  const tab = host.tabs.get(targetId);
  await tab.page.waitForLoadState('load');
  return { host, tab, call, origin, targetId, act: request => call('act', { targetId, request }) };
}

// Observe public Playwright ownership while still executing every real call.
function observeHandles(page) {
  const records = [];
  for (const method of ['evaluateHandle', 'waitForFunction']) {
    const original = page[method].bind(page);
    page[method] = async (...args) => {
      const handle = await original(...args);
      const record = { method, disposed: false }; records.push(record);
      const dispose = handle.dispose.bind(handle);
      handle.dispose = async () => { await dispose(); record.disposed = true; };
      return handle;
    };
  }
  return records;
}

test('function wait polls delayed truthiness and disposes its live document and result', { timeout: 60000 }, async t => {
  const { act, tab, host } = await fixture(t);
  const handles = observeHandles(tab.page);
  const result = await act({ kind: 'wait', fn: 'function ready() { window.predicateThis = this === window; window.polls = (window.polls || 0) + 1; return window.polls >= 4 && { ready: true }; }' });
  assert.equal(result.ok, true);
  assert.equal(result[RESULT_DISPATCHED], true);
  assert.ok(await tab.page.evaluate(() => window.polls) >= 4);
  assert.equal(await tab.page.evaluate(() => window.predicateThis), true);
  assert.deepEqual(handles, [{ method: 'evaluateHandle', disposed: true }, { method: 'waitForFunction', disposed: true }]);
  assert.equal(host.operation, null);
  assert.equal(host.status().running, true);
});

test('async predicates complete false polls serially before becoming truthy', { timeout: 60000 }, async t => {
  const { act, tab } = await fixture(t);
  await act({ kind: 'wait', fn: `async () => {
    window.active = (window.active || 0) + 1;
    window.maxActive = Math.max(window.maxActive || 0, window.active);
    await new Promise(resolve => setTimeout(resolve, 40));
    window.active--;
    window.completed = (window.completed || 0) + 1;
    return window.completed >= 3 ? 'complete' : false;
  }` });
  assert.deepEqual(await tab.page.evaluate(() => ({ active: window.active, maxActive: window.maxActive, completed: window.completed })), { active: 0, maxActive: 1, completed: 3 });
});

test('wait normalizes expression, parenthesized function, and async body sources', { timeout: 60000 }, async t => {
  const { act, tab } = await fixture(t);
  const handles = observeHandles(tab.page);
  await act({ kind: 'wait', fn: ' (window.expressionPolls = (window.expressionPolls || 0) + 1) >= 3 ' });
  await act({ kind: 'wait', fn: '(() => { window.functionCalls = (window.functionCalls || 0) + 1; return true; })' });
  await act({ kind: 'wait', fn: 'await new Promise(resolve => setTimeout(resolve, 30)); window.bodyCalls = (window.bodyCalls || 0) + 1; return true;' });
  assert.deepEqual(await tab.page.evaluate(() => [window.expressionPolls, window.functionCalls, window.bodyCalls]), [3, 1, 1]);
  assert.equal(handles.length, 6);
  assert.ok(handles.every(handle => handle.disposed));
});

test('combined waits follow time, text, textGone, first selector, URL, load, predicate order', { timeout: 60000 }, async t => {
  const { act, tab, origin } = await fixture(t);
  const page = tab.page;
  const order = [];
  let capturedAt;
  const capture = page.evaluateHandle.bind(page);
  page.evaluateHandle = (...args) => { order.push('document'); capturedAt = performance.now(); return capture(...args); };
  const getByText = page.getByText.bind(page);
  page.getByText = (text, ...args) => {
    if (text === 'Ready text') assert.ok(performance.now() - capturedAt >= 35);
    order.push(text === 'Ready text' ? 'text' : 'textGone');
    return getByText(text, ...args);
  };
  const locator = page.locator.bind(page);
  page.locator = (...args) => { order.push('selector'); return locator(...args); };
  for (const [method, label] of [['waitForURL', 'url'], ['waitForLoadState', 'loadState'], ['waitForFunction', 'fn']]) {
    const original = page[method].bind(page);
    page[method] = (...args) => { order.push(label); return original(...args); };
  }
  const result = await act({ kind: 'wait', timeMs: 50, text: 'Ready text', textGone: 'Gone text', selector: '.repeated', url: `${origin}/`, loadState: 'load', fn: '() => { window.combined = true; return true; }' });
  assert.equal(result.ok, true);
  assert.deepEqual(order, ['document', 'text', 'textGone', 'selector', 'url', 'loadState', 'fn']);
  assert.equal(await page.evaluate(() => window.combined), true);
});

test('ordinary selector waits select the first match and retained refs remain supported', { timeout: 60000 }, async t => {
  const { act, call, targetId } = await fixture(t);
  assert.equal((await act({ kind: 'wait', selector: '.repeated' })).ok, true);
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const ref = snapshot.refs.find(item => item.name === 'Wait action').ref;
  assert.equal((await act({ kind: 'wait', ref, fn: '() => true' })).ok, true);
});

test('nested batches await predicate polling before later actions and retain wait receipts', { timeout: 60000 }, async t => {
  const { act, tab } = await fixture(t);
  const result = await act({ kind: 'batch', actions: [
    { kind: 'evaluate', fn: '() => { window.order = ["before"]; return "prepared"; }' },
    { kind: 'batch', actions: [
      { kind: 'wait', fn: '() => { window.batchPolls = (window.batchPolls || 0) + 1; if (window.batchPolls < 3) return false; window.order.push("waited"); return true; }' },
      { kind: 'evaluate', fn: '() => { window.order.push("inside"); return window.batchPolls; }' },
    ] },
    { kind: 'evaluate', fn: '() => { window.order.push("after"); return window.order; }' },
  ] });
  assert.equal(result.results[1].ok, true);
  assert.equal(result.results[1].results[0].ok, true);
  assert.equal(result.results[1].results[1].value, 3);
  assert.deepEqual(result.results[2].value, ['before', 'waited', 'inside', 'after']);
  assert.deepEqual(await tab.page.evaluate(() => window.order), ['before', 'waited', 'inside', 'after']);
});
