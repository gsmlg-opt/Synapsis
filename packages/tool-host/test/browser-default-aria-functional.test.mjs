import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

async function fixture(t) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/same' || req.url === '/cross') {
      const name = req.url === '/same' ? 'Same' : 'Cross';
      res.end(`<!doctype html><title>${name} child</title><label>${name} field<input value="${name} initial"></label><button onclick="window.clicks=(window.clicks||0)+1">${name} action</button>`);
      return;
    }
    res.end(`<!doctype html><title>Default page-wide source</title>
      <section id="scope"><h2>Main heading</h2><label>Main field<input id="main-field" value="Main initial"></label>
      <button onclick="window.mainClicks=(window.mainClicks||0)+1">Main action</button><a href="/details">Details</a></section>
      <div id="shadow"></div><iframe id="same" title="Same child" src="/same"></iframe>
      <iframe id="cross" title="Cross child" src="http://localhost:${server.address().port}/cross"></iframe>
      <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<label>Shadow field<input value="Shadow initial"></label><button onclick="window.shadowClicks=(window.shadowClicks||0)+1">Shadow action</button>';</script>`);
  });
  server.listen(0, '0.0.0.0');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-default-aria-'));
  const host = new BrowserHost({ profile: 'default-aria', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => {
    try {
      const pid = host.diagnosticPid;
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}/` });
  const act = request => call('act', { targetId, request });
  await act({ kind: 'wait', loadState: 'load' });
  const page = host.tabs.get(targetId).page;
  const same = page.frames().find(frame => new URL(frame.url()).pathname === '/same');
  const cross = page.frames().find(frame => new URL(frame.url()).pathname === '/cross');
  assert.ok(same); assert.ok(cross);
  for (const frame of [same, cross]) assert.equal(await frame.evaluate(() => document.readyState), 'complete');
  const session = await page.context().newCDPSession(cross);
  try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
  finally { await session.detach(); }
  const captures = []; const bindings = [];
  const ariaSnapshot = page.ariaSnapshot.bind(page); const getByRef = page.getByRef.bind(page);
  page.ariaSnapshot = async options => { const yaml = await ariaSnapshot(options); captures.push({ options, yaml }); return yaml; };
  page.getByRef = source => { bindings.push(source); return getByRef(source); };
  return { host, page, same, cross, captures, bindings, act, snapshot: args => call('snapshot', { targetId, ...args }) };
}

function exported(result, type) {
  assert.equal(result.format, 'ai'); assert.equal(result.refsType, type);
  assert.equal(result.truncated, false);
  assert.equal(result.refCount, result.refs.length);
  assert.deepEqual([...result.snapshot.matchAll(/\[ref=(e\d+)\]/g)].map(match => match[1]), result.refs.map(info => info.ref));
  assert.equal(new Set(result.refs.map(info => info.ref)).size, result.refCount);
  for (const info of result.refs) assert.deepEqual(Object.keys(info).sort(), ['name', 'ref', 'role']);
}

function ref(result, role, name) {
  const info = result.refs.find(info => info.role === role && info.name === name);
  assert.ok(info, `missing ${role} ${name}`);
  return info.ref;
}

async function pageWideActions(f, result) {
  await f.act({ kind: 'fill', fields: ['Main', 'Shadow', 'Same', 'Cross'].map(name => ({ ref: ref(result, 'textbox', `${name} field`), value: `${name} filled` })) });
  for (const name of ['Main', 'Shadow', 'Same', 'Cross']) await f.act({ kind: 'click', ref: ref(result, 'button', `${name} action`) });
  assert.deepEqual(await f.page.evaluate(() => [window.mainClicks, document.querySelector('#main-field').value, window.shadowClicks, document.querySelector('#shadow').shadowRoot.querySelector('input').value]), [1, 'Main filled', 1, 'Shadow filled']);
  for (const [name, frame] of [['Same', f.same], ['Cross', f.cross]]) assert.deepEqual(await frame.evaluate(() => [window.clicks, document.querySelector('input').value]), [1, `${name} filled`]);
}

// The pin tests request intent before installing shaping defaults. refs=role,
// false flags and ordinary output limits do not themselves request native roles.
for (const [name, args] of [
  ['default AI', { snapshotFormat: 'ai' }],
  ['refs role alone', { refs: 'role' }],
  ['false flags and ordinary limits', { interactive: false, compact: false, labels: false, urls: false, limit: 100, maxChars: 40000 }],
]) test(`${name} captures public page-wide AI YAML once with actionable main, shadow, same and OOP refs`, { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.snapshot(args);
  exported(result, 'aria');
  assert.match(result.semantics, /Page-wide public Playwright AI YAML/);
  assert.equal(f.captures.length, 1);
  const [{ options, yaml }] = f.captures;
  assert.equal(options.mode, 'ai');
  assert.ok(options.signal instanceof AbortSignal);
  assert.ok(Number.isFinite(options.timeout) && options.timeout > 0);
  assert.equal(f.bindings.length, result.refCount);
  assert.ok(f.bindings.some(source => /^f\d+e\d+$/.test(source)));
  // Return host aliases, while preserving the single public source's exact text.
  const sourceByAlias = new Map(result.refs.map((info, index) => [info.ref, f.bindings[index]]));
  assert.equal(result.snapshot.replace(/\[ref=(e\d+)\]/g, (_all, alias) => `[ref=${sourceByAlias.get(alias)}]`), yaml);
  await pageWideActions(f, result);
});

test('stable defaults share the ARIA delta family, refresh aliases and include a newly added child control', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const first = await f.snapshot({});
  const second = await f.snapshot({});
  exported(first, 'aria'); exported(second, 'aria');
  assert.equal(Object.hasOwn(first, 'newElements'), false);
  assert.equal(second.newElements, 0);
  assert.ok(second.refs.every(info => !first.refs.some(old => old.ref === info.ref)));
  assert.ok(second.snapshotGeneration > first.snapshotGeneration);
  assert.equal(second.documentGeneration, first.documentGeneration);
  const explicit = await f.snapshot({ refs: 'aria' });
  exported(explicit, 'aria'); assert.equal(explicit.newElements, 0);
  await f.cross.evaluate(() => {
    const button = document.createElement('button'); button.textContent = 'New cross action';
    button.onclick = () => { window.newClicks = (window.newClicks || 0) + 1; };
    document.body.append(button);
  });
  const changed = await f.snapshot({});
  exported(changed, 'aria'); assert.equal(changed.newElements, 1);
  assert.match(changed.snapshot, /button "New cross action" \[ref=e\d+\] \[new\]/);
  await f.act({ kind: 'click', ref: ref(changed, 'button', 'New cross action') });
  assert.equal(await f.cross.evaluate(() => window.newClicks), 1);
  await pageWideActions(f, changed);
  assert.equal(f.captures.length, 4);
});

test('ordinary role-triggering options preserve native main leaves and exact selected-frame actions', { timeout: 90000 }, async t => {
  const f = await fixture(t);
  for (const args of [{ interactive: true }, { mode: 'efficient' }, { compact: true }, { depth: 100 }, { urls: true }, { labels: true }]) {
    const result = await f.snapshot(args);
    exported(result, 'role');
    assert.equal(result.refs.filter(info => info.role === 'iframe').length, 2);
    assert.doesNotMatch(result.snapshot, /Same action|Cross action/);
    assert.ok(result.refs.some(info => info.name === 'Main action'));
  }
  const selected = await f.snapshot({ selector: '#scope' });
  exported(selected, 'role');
  assert.doesNotMatch(selected.snapshot, /Shadow action|Same action|Cross action/);
  await f.act({ kind: 'click', ref: ref(selected, 'button', 'Main action') });
  assert.equal(await f.page.evaluate(() => window.mainClicks), 1);
  for (const [selector, name, frame] of [['#same', 'Same', f.same], ['#cross', 'Cross', f.cross]]) {
    const result = await f.snapshot({ frame: selector, interactive: true });
    exported(result, 'role');
    assert.deepEqual(result.refs.map(info => info.name), [`${name} field`, `${name} action`]);
    await f.act({ kind: 'fill', fields: [{ ref: ref(result, 'textbox', `${name} field`), value: `${name} native` }] });
    await f.act({ kind: 'click', ref: ref(result, 'button', `${name} action`) });
    assert.deepEqual(await frame.evaluate(() => [window.clicks, document.querySelector('input').value]), [1, `${name} native`]);
  }
  assert.equal(f.captures.length, 0);
  const explicit = await f.snapshot({ refs: 'aria', interactive: true, mode: 'efficient' });
  exported(explicit, 'aria');
  assert.ok(explicit.refs.some(info => info.name === 'Cross action'));
  assert.equal(f.captures.length, 1);
});
