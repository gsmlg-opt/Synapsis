import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

async function processTree(pid) {
  const children = await readFile(`/proc/${pid}/task/${pid}/children`, 'utf8');
  const descendants = await Promise.all(children.trim().split(/\s+/).filter(Boolean).map(async child => {
    try { return await processTree(Number(child)); } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }));
  return [pid, ...descendants.flat()];
}

async function fixture(t) {
  const server = createServer((_req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><title>Wait normalization</title>
      <h1>Ready text</h1><div hidden>Ready text</div>
      <div hidden>Gone text</div><div>Gone text</div>
      <div class="repeated">First match</div><div class="repeated" hidden>Second match</div>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-wait-normalization-'));
  const host = new BrowserHost({ profile: 'wait', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  let closed = false;
  const close = async () => {
    if (closed) return;
    const pids = host.diagnosticPid ? await processTree(host.diagnosticPid) : [];
    assert.equal((await host.close()).cleanup_confirmed, true);
    const deadline = performance.now() + 15000;
    for (const pid of pids) {
      while (true) {
        try { process.kill(pid, 0); } catch (error) {
          assert.equal(error.code, 'ESRCH');
          break;
        }
        assert.ok(performance.now() < deadline, `owned Chromium process ${pid} exited`);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    }
    assert.equal(host.operation, null);
    closed = true;
  };
  t.after(async () => {
    try { await close(); } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const url = `http://127.0.0.1:${server.address().port}/page`;
  const { targetId } = await call('open', { targetUrl: url });
  const page = host.tabs.get(targetId).page;
  await page.waitForLoadState('load');
  return { host, page, url, close, act: request => call('act', { targetId, request }) };
}

// These observers retain the public arguments and delegate every original call.
// Assertions run only after the real wait, normal close, and owned process exits.
function observe(host, page) {
  const calls = [];
  const leaves = [];
  const act = host.act.bind(host);
  host.act = (tab, request, operation) => {
    if (request.kind === 'wait') leaves.push(structuredClone(request));
    return act(tab, request, operation);
  };
  for (const method of ['evaluateHandle', 'getByText', 'locator', 'waitForURL', 'waitForLoadState', 'waitForFunction']) {
    const original = page[method].bind(page);
    page[method] = (...args) => {
      calls.push({ method, argument: args[0], at: performance.now() });
      return original(...args);
    };
  }
  return { calls, leaves };
}

for (const nested of [false, true]) {
  test(`ordinary forwarding ${nested ? 'nested batch leaf' : 'direct wait'} trims successful text and selector inputs`, { timeout: 60000 }, async t => {
    const { host, page, url, close, act } = await fixture(t);
    await page.evaluate(() => { window.order = ['before']; window.polls = 0; });
    const observed = observe(host, page);
    const wait = {
      kind: 'wait', timeMs: 30, text: '  Ready text  ', textGone: '  Gone text  ',
      selector: '  .repeated  ', url, loadState: 'load',
      fn: '  () => { window.polls++; if (window.polls < 3) return false; window.order.push("wait"); return true; }  ',
    };
    const request = nested ? { kind: 'batch', actions: [{ kind: 'batch', actions: [wait,
      { kind: 'evaluate', fn: '() => { window.order.push("after"); return window.order; }' },
    ] }] } : wait;
    const original = structuredClone(request);
    const result = await act(request);
    const effects = await page.evaluate(() => ({ order: window.order, polls: window.polls,
      matches: [...document.querySelectorAll('.repeated')].map(element => element.hidden) }));
    await close();

    const receipt = nested ? result.results[0].results[0] : result;
    assert.equal(receipt.ok, true);
    assert.equal(result[RESULT_DISPATCHED], true);
    assert.deepEqual(effects, { order: nested ? ['before', 'wait', 'after'] : ['before', 'wait'], polls: 3, matches: [false, true] });
    if (nested) assert.deepEqual(result.results[0].results[1].value, ['before', 'wait', 'after']);
    assert.deepEqual(request, original);
    assert.deepEqual(observed.calls.map(call => call.method), ['evaluateHandle', 'getByText', 'getByText', 'locator', 'waitForURL', 'waitForLoadState', 'waitForFunction']);
    assert.ok(observed.calls[1].at - observed.calls[0].at >= 20);
    // The old host reaches this assertion only after successful action/cleanup.
    assert.deepEqual(observed.calls.slice(1, 6).map(call => call.argument), ['Ready text', 'Gone text', '.repeated', url, 'load']);
    assert.deepEqual(observed.leaves.map(leaf => [leaf.text, leaf.textGone, leaf.selector, leaf.url, leaf.loadState, leaf.fn]),
      [['Ready text', 'Gone text', '.repeated', url, 'load', wait.fn.trim()]]);
  });
}

// Post-implementation success coverage. Exclude this name from the old-host RED run.
test('normalized URL and load state accept padded strings and omit blank optional conditions', { timeout: 60000 }, async t => {
  const { host, page, url, close, act } = await fixture(t);
  const observed = observe(host, page);
  const padded = { kind: 'wait', timeMs: 10, text: ' \tReady text\n', textGone: '\nGone text  ', selector: '  .repeated\t', url: `  ${url}\n`, loadState: '  load\t', fn: ' \n() => { window.normalized = (window.normalized || 0) + 1; return true; } \t' };
  const blanks = { kind: 'wait', timeMs: 10, text: '  ', textGone: '\t', selector: '\n', url: ' \t', loadState: '\n ', fn: '\t ' };
  const request = { kind: 'batch', actions: [padded, { kind: 'batch', actions: [blanks] }] };
  const original = structuredClone(request);
  const result = await act(request);
  const effect = await page.evaluate(() => window.normalized);
  await close();

  assert.equal(result.results[0].ok, true);
  assert.deepEqual(result.results[1], { ok: true, results: [{ ok: true }] });
  assert.equal(effect, 1);
  assert.deepEqual(request, original);
  assert.deepEqual(observed.calls.filter(call => ['getByText', 'locator', 'waitForURL', 'waitForLoadState'].includes(call.method)).map(call => call.argument),
    ['Ready text', 'Gone text', '.repeated', url, 'load']);
  const fields = ['text', 'textGone', 'selector', 'url', 'loadState', 'fn'];
  assert.deepEqual(fields.map(field => observed.leaves[0][field]), ['Ready text', 'Gone text', '.repeated', url, 'load', padded.fn.trim()]);
  assert.deepEqual(fields.map(field => observed.leaves[1][field]), fields.map(() => undefined));
});
