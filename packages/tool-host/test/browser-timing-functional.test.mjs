import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

const timing = await import('../src/browser/timing.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND' && error.url === new URL('../src/browser/timing.mjs', import.meta.url).href) return {};
  throw error;
});

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-timing-'));
  const server = createServer((_request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><title>Timing phases</title>
      <style>button,input,select{display:block;height:40px;width:200px;margin:12px}</style>
      <button id="from">From</button><button id="to">To</button>
      <form id="form"><label>Text<input id="text" value="seed"></label>
      <label>Check<input id="check" type="checkbox"></label>
      <select id="select"><option value="a">A</option><option value="b">B</option></select></form>
      <h1>Ready text</h1><div id="ready">Ready</div>
      <script>window.submits=0;form.addEventListener('submit',e=>{e.preventDefault();window.submits++});</script>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = new BrowserHost({ profile: 'timing', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 1000, max_image_bytes: 196608 });
  t.after(async () => {
    try {
      const pid = host.diagnosticPid;
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.equal(existsSync(`/proc/${pid}`), false, 'the owned Chromium PID exited');
      assert.equal(host.operation, null);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}, timeoutMs = 15000) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}/` });
  const tab = host.tabs.get(targetId);
  await tab.page.waitForLoadState('load');
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const refs = name => snapshot.refs.find(row => row.name === name).ref;
  return { host, tab, call, refs, act: (request, timeoutMs = 15000) => call('act', { targetId, request }, timeoutMs) };
}

function observePhases(host, page) {
  const records = [];
  const wrapped = new WeakSet();
  const target = value => {
    if (!value || wrapped.has(value)) return value;
    wrapped.add(value);
    for (const method of ['hover', 'click', 'dblclick', 'fill', 'type', 'press', 'selectOption', 'scrollIntoViewIfNeeded', 'setChecked', 'waitFor', 'waitForElementState']) {
      if (typeof value[method] !== 'function') continue;
      const original = value[method].bind(value);
      value[method] = (...args) => {
        records.push({ method, args: structuredClone(args) });
        return original(...args);
      };
    }
    if (typeof value.first === 'function') {
      const first = value.first.bind(value);
      value.first = () => target(first());
    }
    return value;
  };
  const originalTarget = host.target.bind(host);
  host.target = async (...args) => target(await originalTarget(...args));
  for (const method of ['locator', 'getByText']) {
    const original = page[method].bind(page);
    page[method] = (...args) => target(original(...args));
  }
  for (const method of ['waitForURL', 'waitForLoadState', 'waitForFunction']) {
    const original = page[method].bind(page);
    page[method] = (...args) => {
      records.push({ method, args: args.map(value => typeof value === 'function' ? '[function]' : method === 'waitForFunction' && value?.document ? '[live document]' : structuredClone(value)) });
      return original(...args);
    };
  }
  return records;
}

test('private model-local defaults are shallow and phase ranges retain host delay extensions', () => {
  assert.equal(typeof timing.prepareActRequest, 'function');
  const batch = { kind: 'batch', actions: [{ kind: 'wait', fn: '() => true' }] };
  assert.deepEqual(timing.prepareActRequest(batch), batch);
  assert.notEqual(timing.prepareActRequest(batch), batch);
  const click = { kind: 'click', selector: '#from' };
  assert.deepEqual(timing.prepareActRequest(click), { ...click, timeoutMs: 60000 });
  assert.deepEqual(click, { kind: 'click', selector: '#from' });
  assert.equal(timing.interactionTimeoutMs({}), 8000);
  assert.equal(timing.interactionTimeoutMs({ timeoutMs: 150 }), 500);
  assert.equal(timing.interactionTimeoutMs({ timeoutMs: 80000 }), 60000);
  assert.equal(timing.waitTimeoutMs({}), 20000);
  assert.equal(timing.waitTimeoutMs({ timeoutMs: 160000 }), 120000);
  assert.equal(timing.typingTimeoutMs({ timeoutMs: 1000, slowly: true, text: 'a😀', delayMs: 1000 }), 3775);
  assert.equal(timing.pressTimeoutMs({ timeoutMs: 1000, delayMs: 120000 }), 121000);
  assert.equal(timing.evaluateInnerTimeoutMs({ timeoutMs: 10000 }), 9500);
});

test('real interactions apply independent phase options and preserve private request copies', { timeout: 60000 }, async t => {
  const { host, tab, act, refs } = await fixture(t);
  const records = observePhases(host, tab.page);
  const raw = { kind: 'type', selector: '#text', text: 'xy', slowly: true, delayMs: 80, submit: true, timeoutMs: 1600 };
  await act({ kind: 'click', selector: '#from', delayMs: 20, timeoutMs: 1400 });
  await act(raw);
  await act({ kind: 'fill', fields: [{ selector: '#text', value: 'filled' }, { selector: '#check', type: 'checkbox', value: true }], timeoutMs: 1700 });
  await act({ kind: 'press', selector: '#text', key: 'ArrowRight', delayMs: 30, timeoutMs: 1800 });
  await act({ kind: 'select', selector: '#select', values: ['b'], timeoutMs: 1900 });
  await act({ kind: 'drag', startRef: refs('From'), endRef: refs('To'), timeoutMs: 2000 });
  assert.deepEqual(raw, { kind: 'type', selector: '#text', text: 'xy', slowly: true, delayMs: 80, submit: true, timeoutMs: 1600 });
  const options = method => records.filter(row => row.method === method).map(row => row.args.at(-1));
  assert.ok(options('hover').some(value => value.timeout === 1400));
  assert.ok(options('click').some(value => value.timeout === 1400));
  assert.ok(options('click').some(value => value.timeout === 1600));
  assert.ok(options('type').some(value => value.timeout === 1610 && value.delay === 80));
  assert.ok(options('press').some(value => value.timeout === 1600));
  assert.ok(options('fill').some(value => value.timeout === 1700));
  assert.ok(options('setChecked').some(value => value.timeout === 1700));
  assert.ok(options('press').some(value => value.timeout === 1830 && value.delay === 30));
  assert.ok(options('selectOption').some(value => value.timeout === 1900));
  assert.equal(options('scrollIntoViewIfNeeded').filter(value => value.timeout === 2000).length, 2);
  assert.deepEqual(await tab.page.evaluate(() => ({ value: text.value, checked: check.checked, selected: select.value, submits: window.submits })), { value: 'filled', checked: true, selected: 'b', submits: 1 });
});

test('serial wait conditions complete past the trusted profile default with separate explicit phase allowances', { timeout: 60000 }, async t => {
  const { host, tab, act } = await fixture(t);
  await tab.page.evaluate(() => {
    ready.remove();
    document.querySelector('h1').remove();
    const loading = document.createElement('div'); loading.id = 'loading'; loading.textContent = 'Loading text'; document.body.append(loading);
    setTimeout(() => { const title = document.createElement('h1'); title.textContent = 'Ready text'; document.body.append(title); }, 1300);
    setTimeout(() => loading.remove(), 2600);
    setTimeout(() => { const element = document.createElement('div'); element.id = 'ready'; element.textContent = 'Ready'; document.body.append(element); }, 3900);
  });
  const records = observePhases(host, tab.page);
  const raw = { kind: 'wait', timeMs: 10, text: 'Ready text', textGone: 'Loading text', selector: '#ready', url: '**/*', loadState: 'load', fn: '() => Boolean(document.querySelector("#ready"))', timeoutMs: 2200 };
  const start = performance.now();
  assert.equal((await act(raw)).ok, true);
  assert.ok(performance.now() - start >= 3600);
  assert.equal(host.config.timeout_ms, 1000);
  assert.equal(raw.timeoutMs, 2200);
  assert.equal(records.filter(row => row.method === 'waitFor' && row.args[0].timeout === 2200).length, 3);
  assert.ok(records.some(row => row.method === 'waitForURL' && row.args[1].timeout === 2200));
  assert.ok(records.some(row => row.method === 'waitForLoadState' && row.args[1].timeout === 2200));
  assert.ok(records.some(row => row.method === 'waitForFunction' && row.args[2].timeout === 2200));
});

test('nested children keep source defaults while standalone defaults are injected only once', { timeout: 60000 }, async t => {
  const { host, tab, act } = await fixture(t);
  const records = observePhases(host, tab.page);
  await act({ kind: 'hover', selector: '#from' });
  const raw = { kind: 'batch', actions: [
    { kind: 'hover', selector: '#from' },
    { kind: 'batch', actions: [{ kind: 'wait', selector: '#ready', fn: '() => true' }] },
    { kind: 'hover', selector: '#to', timeoutMs: 1300 },
  ] };
  const snapshot = structuredClone(raw);
  const result = await act(raw);
  assert.equal(result.results[0].ok, true);
  assert.equal(result.results[1].results[0].ok, true);
  assert.equal(result.results[2].ok, true);
  assert.deepEqual(raw, snapshot);
  assert.deepEqual(records.filter(row => row.method === 'hover').map(row => row.args[0].timeout), [60000, 8000, 1300]);
  assert.ok(records.some(row => row.method === 'waitFor' && row.args[0].timeout === 20000));
  assert.ok(records.some(row => row.method === 'waitForFunction' && row.args[2].timeout === 20000));
});

test('source-specific async evaluate deadlines and a large finite outer allocation finish ordinary short work', { timeout: 60000 }, async t => {
  const { host, tab, act, refs } = await fixture(t);
  const observed = [];
  const evaluate = tab.page.evaluate.bind(tab.page);
  tab.page.evaluate = (fn, args) => { observed.push(args); return evaluate(fn, args); };
  const request = { kind: 'evaluate', fn: 'async () => { await new Promise(resolve => setTimeout(resolve, 40)); return {answer:42}; }', timeoutMs: 10000 };
  const result = await act(request, 2147000000);
  assert.deepEqual(result.value, { answer: 42 });
  assert.ok(observed.some(args => args?.timeoutMs === 9500 && args?.fn === request.fn));
  const refResult = await act({ kind: 'evaluate', ref: refs('From'), fn: 'async element => { await new Promise(resolve => setTimeout(resolve, 20)); return element.textContent; }', timeoutMs: 1500 });
  assert.equal(refResult.value, 'From');
  assert.equal(host.operation, null);
  assert.equal(host.status().running, true);
});
