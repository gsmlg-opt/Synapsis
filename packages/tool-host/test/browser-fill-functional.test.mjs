import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

// Positive post-implementation tests only. Literal expectations come from pin
// 488631c browser/form-fields.ts and pw-tools-core.interactions.actions.ts.
// These capabilities must never be dispatched against the old helper as RED.
const textCases = [
  { id: 'quantity', htmlType: 'number', raw: { type: ' number ', value: 7 }, normalized: { type: 'number', value: 7 }, expected: '7' },
  { id: 'numeric-text', raw: { value: 12 }, normalized: { type: 'text', value: 12 }, expected: '12' },
  { id: 'boolean-false', raw: { value: false }, normalized: { type: 'text', value: false }, expected: 'false' },
  { id: 'boolean-true', raw: { type: ' text ', value: true }, normalized: { type: 'text', value: true }, expected: 'true' },
  { id: 'null-clear', raw: { value: null }, normalized: { type: 'text' }, expected: '' },
  { id: 'missing-clear', raw: {}, normalized: { type: 'text' }, expected: '' },
  { id: 'email', htmlType: 'email', raw: { type: 'email', value: 'ada@example.test' }, normalized: { type: 'email', value: 'ada@example.test' }, expected: 'ada@example.test' },
  { id: 'notes', textarea: true, raw: { type: ' textarea ', value: '  notes\nkept  ' }, normalized: { type: 'textarea', value: '  notes\nkept  ' }, expected: '  notes\nkept  ' },
  { id: 'case-sensitive', raw: { type: 'Checkbox', value: false }, normalized: { type: 'Checkbox', value: false }, expected: 'false' },
  { id: 'blank-type', raw: { type: ' \t', value: '  spaced value  ' }, normalized: { type: 'text', value: '  spaced value  ' }, expected: '  spaced value  ' },
  { id: 'nonstring-type', raw: { type: 7, value: true }, normalized: { type: 'text', value: true }, expected: 'true' },
];
const checkCases = [
  { id: 'true-boolean', raw: { value: true }, normalized: { value: true }, expected: true },
  { id: 'true-number', raw: { value: 1 }, normalized: { value: 1 }, expected: true },
  { id: 'true-one', raw: { value: '1' }, normalized: { value: '1' }, expected: true },
  { id: 'true-string', raw: { value: 'true' }, normalized: { value: 'true' }, expected: true },
  { id: 'false-boolean', raw: { value: false }, normalized: { value: false }, expected: false },
  { id: 'false-number', raw: { value: 0 }, normalized: { value: 0 }, expected: false },
  { id: 'false-zero', raw: { value: '0' }, normalized: { value: '0' }, expected: false },
  { id: 'false-string', raw: { value: 'false' }, normalized: { value: 'false' }, expected: false },
  { id: 'false-case', raw: { value: 'TRUE' }, normalized: { value: 'TRUE' }, expected: false },
  { id: 'false-padded', raw: { value: ' true ' }, normalized: { value: ' true ' }, expected: false },
  { id: 'false-other-number', raw: { value: 2 }, normalized: { value: 2 }, expected: false },
  { id: 'false-empty', raw: { value: '' }, normalized: { value: '' }, expected: false },
  { id: 'false-null', raw: { value: null }, normalized: {}, expected: false },
  { id: 'false-missing', raw: {}, normalized: {}, expected: false },
];

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
  const submissions = [];
  const server = createServer(async (req, res) => {
    if (req.method === 'POST' && req.url === '/submit') {
      let body = '';
      for await (const chunk of req) body += chunk;
      submissions.push(JSON.parse(body));
      res.end('accepted');
      return;
    }
    if (req.url === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><title>Form fill pin</title><form id="form">
      ${textCases.map(item => `<label>${item.id}${item.textarea ? `<textarea id="${item.id}" name="${item.id}">seed</textarea>` : `<input id="${item.id}" name="${item.id}" type="${item.htmlType ?? 'text'}" value="${item.htmlType === 'number' ? '3' : 'seed'}">`}</label>`).join('')}
      ${checkCases.map(item => `<label>${item.id}<input id="${item.id}" name="${item.id}" type="checkbox" ${item.expected ? '' : 'checked'}></label>`).join('')}
      <label>Radio previous<input id="radio-old" type="radio" name="choice" value="old" checked></label>
      <label>Radio chosen<input id="radio-new" type="radio" name="choice" value="new"></label>
      <label>Local field<input id="local" name="local" value="seed"></label>
      <button type="submit">Submit form</button></form><script>
      window.events = [];
      document.addEventListener('input', event => {
        const el = event.target;
        window.events.push([el.id, el.type === 'checkbox' || el.type === 'radio' ? el.checked : el.value]);
      });
      document.querySelector('form').onsubmit = async event => {
        event.preventDefault();
        const payload = {fields: Object.fromEntries(new FormData(event.target)), events: window.events};
        const response = await fetch('/submit', {method: 'POST', body: JSON.stringify(payload)});
        window.submission = {status: response.status, body: await response.text(), payload};
      };
      </script>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-fill-'));
  const host = new BrowserHost({ profile: 'fill', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  let closed = false;
  const close = async () => {
    if (closed) return;
    const pids = host.diagnosticPid ? await processTree(host.diagnosticPid) : [];
    assert.equal((await host.close()).cleanup_confirmed, true);
    const deadline = performance.now() + 15000;
    for (const pid of pids) {
      while (true) {
        try { process.kill(pid, 0); } catch (error) { assert.equal(error.code, 'ESRCH'); break; }
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
  const snapshot = await call('snapshot', { targetId });
  const ref = (role, name) => {
    const found = snapshot.refs.find(info => info.role === role && info.name === name);
    assert.ok(found, `snapshot has ${role} ${name}`);
    return found.ref;
  };
  return { host, page, ref, close, submissions, targetId, url, generation: host.generation, act: request => call('act', { targetId, request }) };
}

// Passive observers: no argument rewriting, no fabricated locator returns.
function observe(host) {
  const leaves = []; const calls = []; const wrapped = new WeakSet();
  const act = host.act.bind(host);
  host.act = (tab, request, operation) => {
    if (request.kind === 'fill') leaves.push(structuredClone(request.fields));
    return act(tab, request, operation);
  };
  const target = host.target.bind(host);
  host.target = async (...args) => {
    const handle = await target(...args);
    if (!wrapped.has(handle)) {
      wrapped.add(handle);
      for (const method of ['fill', 'setChecked']) {
        const original = handle[method].bind(handle);
        handle[method] = (...params) => {
          calls.push({ method, value: params[0], options: params[1] });
          return original(...params);
        };
      }
    }
    return handle;
  };
  return { leaves, calls };
}

// The pin promises ordered field writes, not Chromium's native event count.
// Keep every raw event, require one nonempty contiguous block per literal write,
// and validate every event in the block; no event is filtered or rewritten.
function assertEventBlocks(actual, expected) {
  const blocks = [];
  for (const event of actual) {
    assert.ok(Array.isArray(event));
    const previous = blocks.at(-1);
    if (previous && previous[0][0] === event[0]) previous.push(event);
    else blocks.push([event]);
  }
  assert.deepEqual(blocks.map(block => block[0]), expected);
  for (const [index, block] of blocks.entries()) {
    for (const event of block) assert.deepEqual(event, expected[index]);
    if (expected[index][0] === 'after') assert.equal(block.length, 1);
  }
}

for (const nested of [false, true]) {
  test(`pinned scalar form fill ${nested ? 'nested batch' : 'standalone'} changes real refs in order and submits once`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const fields = textCases.map(item => ({ ref: ` \t${f.ref(item.htmlType === 'number' ? 'spinbutton' : 'textbox', item.id)}\n`, ...item.raw }));
    const normalized = textCases.map(item => ({ ref: f.ref(item.htmlType === 'number' ? 'spinbutton' : 'textbox', item.id), ...item.normalized }));
    for (const item of checkCases) {
      const ref = f.ref('checkbox', item.id);
      fields.push({ ref, type: ' checkbox ', ...item.raw });
      normalized.push({ ref, type: 'checkbox', ...item.normalized });
    }
    const radio = f.ref('radio', 'Radio chosen');
    fields.push({ ref: ` ${radio} `, type: ' radio ', value: 'true' });
    normalized.push({ ref: radio, type: 'radio', value: 'true' });
    const fill = { kind: 'fill', fields };
    const marker = { kind: 'evaluate', fn: '() => { window.events.push(["after", "filled"]); return "filled"; }' };
    const request = nested ? { kind: 'batch', actions: [{ kind: 'batch', actions: [fill, marker] }] } : fill;
    const original = structuredClone(request);
    const observed = observe(f.host);
    const result = await f.act(request);
    const events = [...textCases.map(item => [item.id, item.expected]), ...checkCases.map(item => [item.id, item.expected]), ['radio-new', true], ...(nested ? [['after', 'filled']] : [])];
    const values = Object.fromEntries(textCases.map(item => [item.id, item.expected]));
    const effects = await f.page.evaluate(() => ({ events: window.events, values: Object.fromEntries([...document.querySelectorAll('input:not([type=checkbox]):not([type=radio]), textarea')].map(el => [el.id, el.value])), checked: [...document.querySelectorAll('input[type=checkbox]')].map(el => [el.id, el.checked]), radio: [...document.querySelectorAll('input[type=radio]')].map(el => el.checked) }));
    await f.act({ kind: 'click', ref: f.ref('button', 'Submit form') });
    await f.act({ kind: 'wait', fn: '() => Boolean(window.submission)' });
    const submission = await f.page.evaluate(() => window.submission);
    await f.close();

    assert.equal(result[RESULT_DISPATCHED], true);
    assert.deepEqual(result, { generation: f.generation, targetId: f.targetId, url: f.url, ...(nested ? { results: [{ ok: true, results: [{ ok: true }, { ok: true, value: 'filled' }] }] } : { ok: true }) });
    const { events: rawEvents, ...state } = effects;
    assertEventBlocks(rawEvents, events);
    assert.deepEqual(state, { values: { ...values, local: 'seed' }, checked: checkCases.map(item => [item.id, item.expected]), radio: [false, true] });
    const payload = { fields: { ...values, 'true-boolean': 'on', 'true-number': 'on', 'true-one': 'on', 'true-string': 'on', choice: 'new', local: 'seed' }, events: rawEvents };
    assert.deepEqual(submission, { status: 200, body: 'accepted', payload });
    assert.deepEqual(f.submissions, [payload]);
    assert.deepEqual(request, original);
    assert.deepEqual(observed.leaves, [normalized]);
    assert.deepEqual(observed.calls.map(({ method, value }) => [method, value]), [...textCases.map(item => ['fill', item.expected]), ...checkCases.map(item => ['setChecked', item.expected]), ['setChecked', true]]);
    for (const call of observed.calls) assert.deepEqual(call.options, nested ? { timeout: 8000 } : { timeout: 60000 });
  });
}

test('local selector extension retains pinned default text and explicit checkbox semantics', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const request = { kind: 'fill', fields: [{ selector: '#local', value: false }, { selector: '#false-string', type: 'checkbox', value: 'false' }] };
  const original = structuredClone(request);
  const result = await f.act(request);
  const effects = await f.page.evaluate(() => ({ local: document.querySelector('#local').value, checked: document.querySelector('#false-string').checked, events: window.events }));
  await f.close();
  assert.deepEqual(result, { generation: f.generation, targetId: f.targetId, url: f.url, ok: true });
  assert.deepEqual(effects, { local: 'false', checked: false, events: [['local', 'false'], ['false-string', false]] });
  assert.deepEqual(request, original);
  assert.deepEqual(f.submissions, []);
});
