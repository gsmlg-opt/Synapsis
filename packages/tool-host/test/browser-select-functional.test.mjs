import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

// Positive post-implementation coverage only; never old-host RED. Literal
// expectations: pin 488631c routes/agent.act.normalize.ts:239-247 and
// pw-tools-core.interactions.actions.ts:91-101,158-166. Refs are trimmed;
// option strings (including empty and padded strings) remain content.
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
    res.end(`<!doctype html><title>Select pin</title><form>
      <label>Single choice<select id="single" name="single"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Many choices<select id="multi" name="multi" multiple size="4"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Decoy choice<select id="decoy" name="decoy"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Local choice<select id="local" name="local"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <button type="submit">Submit form</button></form><script>
      window.events = [];
      for (const type of ['input', 'change']) document.addEventListener(type, event => {
        const el = event.target;
        if (el.tagName === 'SELECT') window.events.push([event.type, el.id, [...el.selectedOptions].map(option => option.value)]);
      });
      document.querySelector('form').onsubmit = async event => {
        event.preventDefault();
        const payload = {fields: [...new FormData(event.target)], events: window.events};
        const response = await fetch('/submit', {method: 'POST', body: JSON.stringify(payload)});
        window.submission = {status: response.status, body: await response.text(), payload};
      };
      </script>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-select-'));
  const host = new BrowserHost({ profile: 'select', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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

// Passive observers call the actual host and real Playwright selectOption.
function observe(host) {
  const leaves = []; const calls = []; const wrapped = new WeakSet();
  const act = host.act.bind(host);
  host.act = (tab, request, operation) => {
    if (request.kind === 'select') leaves.push({ ref: request.ref, selector: request.selector, values: structuredClone(request.values) });
    return act(tab, request, operation);
  };
  const target = host.target.bind(host);
  host.target = async (...args) => {
    const handle = await target(...args);
    if (!wrapped.has(handle)) {
      wrapped.add(handle);
      const select = handle.selectOption.bind(handle);
      handle.selectOption = (...params) => {
        calls.push(structuredClone(params[0]));
        return select(...params);
      };
    }
    return handle;
  };
  return { leaves, calls };
}

// Require ordered nonempty field blocks and both event types, while checking
// every raw event rather than assuming Chromium's event multiplicity.
function assertSelectEvents(actual, expected) {
  const blocks = [];
  for (const event of actual) {
    assert.ok(Array.isArray(event));
    if (blocks.at(-1)?.[0][1] === event[1]) blocks.at(-1).push(event);
    else blocks.push([event]);
  }
  assert.deepEqual(blocks.map(block => [block[0][1], block[0][2]]), expected);
  for (const [index, block] of blocks.entries()) {
    assert.deepEqual([...new Set(block.map(event => event[0]))].sort(), ['change', 'input']);
    for (const [type, id, values] of block) {
      assert.ok(['input', 'change'].includes(type));
      assert.deepEqual([id, values], expected[index]);
    }
  }
}

for (const nested of [false, true]) {
  test(`pinned select ${nested ? 'depth-two batch' : 'standalone'} trims refs, preserves option content and submits real selections`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const singleRef = f.ref('combobox', 'Single choice');
    const multiRef = f.ref('listbox', 'Many choices');
    const single = { kind: 'select', ref: ` \t${singleRef}\n`, selector: '#decoy', values: [' padded '] };
    // Request order intentionally differs from selectedOptions/FormData DOM order.
    const multi = { kind: 'select', ref: ` \t${multiRef}\n`, values: [' padded ', ''] };
    const request = nested ? { kind: 'batch', actions: [{ kind: 'batch', actions: [single, multi] }] } : [single, multi];
    const original = structuredClone(request);
    const observed = observe(f.host);
    const result = nested ? await f.act(request) : [await f.act(single), await f.act(multi)];
    const effects = await f.page.evaluate(() => ({ events: window.events, selections: Object.fromEntries([...document.querySelectorAll('select')].map(el => [el.id, [...el.selectedOptions].map(option => option.value)])) }));
    await f.act({ kind: 'click', ref: f.ref('button', 'Submit form') });
    await f.act({ kind: 'wait', fn: '() => Boolean(window.submission)' });
    const submission = await f.page.evaluate(() => window.submission);
    await f.close();

    const metadata = { generation: f.generation, targetId: f.targetId, url: f.url };
    for (const receipt of nested ? [result] : result) assert.equal(receipt[RESULT_DISPATCHED], true);
    assert.deepEqual(result, nested ? { ...metadata, results: [{ ok: true, results: [{ ok: true }, { ok: true }] }] } : [{ ...metadata, ok: true }, { ...metadata, ok: true }]);
    assert.deepEqual(effects.selections, { single: [' padded '], multi: ['', ' padded '], decoy: ['seed'], local: ['seed'] });
    assertSelectEvents(effects.events, [['single', [' padded ']], ['multi', ['', ' padded ']]]);
    const payload = { fields: [['single', ' padded '], ['multi', ''], ['multi', ' padded '], ['decoy', 'seed'], ['local', 'seed']], events: effects.events };
    assert.deepEqual(submission, { status: 200, body: 'accepted', payload });
    assert.deepEqual(f.submissions, [payload]);
    assert.deepEqual(request, original);
    assert.deepEqual(observed.leaves, [{ ref: singleRef, selector: '#decoy', values: [' padded '] }, { ref: multiRef, selector: undefined, values: [' padded ', ''] }]);
    assert.deepEqual(observed.calls, [[' padded '], [' padded ', '']]);
  });
}

test('standalone local selector extension selects the empty option value unchanged', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const request = { kind: 'select', selector: '#local', values: [''] };
  const original = structuredClone(request);
  const result = await f.act(request);
  const effects = await f.page.evaluate(() => ({ local: [...document.querySelector('#local').selectedOptions].map(option => option.value), events: window.events }));
  await f.close();
  assert.deepEqual(result, { generation: f.generation, targetId: f.targetId, url: f.url, ok: true });
  assert.deepEqual(effects.local, ['']);
  assertSelectEvents(effects.events, [['local', ['']]]);
  assert.deepEqual(request, original);
  assert.deepEqual(f.submissions, []);
});
