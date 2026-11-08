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
    if (req.url === '/frame') {
      res.end('<!doctype html><section id="frame-scope"><button id="frame-action" onclick="window.frameClicks=(window.frameClicks||0)+1">Frame action</button></section>');
      return;
    }
    res.end(`<!doctype html><title>Snapshot delta</title><meta name="viewport" content="width=device-width, initial-scale=1"><style>button{display:block;min-height:40px}#keep{width:96px;height:40px}</style>
      <section id="scope"><button id="keep" onclick="window.clicks=(window.clicks||0)+1">Keep action</button></section>
      <section id="duplicates"><button id="dup-first">Duplicate</button><button id="dup-second">Duplicate</button></section>
      <a href="/docs">Document docs</a><div id="budget"></div>
      <iframe id="same" src="/frame"></iframe><iframe id="cross" src="http://localhost:${server.address().port}/frame"></iframe>`);
  });
  server.listen(0, '0.0.0.0');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-delta-'));
  const host = new BrowserHost({ profile: 'delta', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  const origin = `http://127.0.0.1:${server.address().port}`;
  const { targetId } = await call('open', { targetUrl: `${origin}/` });
  const act = request => call('act', { targetId, request });
  await act({ kind: 'wait', loadState: 'load' });
  const tab = host.tabs.get(targetId);
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const snapshot = args => call('snapshot', { targetId, ...args });
  const markers = async () => {
    for (const frame of tab.page.frames()) assert.deepEqual(await frame.evaluate(() => {
      const roots = [document]; const names = [];
      for (const root of roots) for (const element of root.querySelectorAll('*')) {
        names.push(...element.getAttributeNames().filter(name => name.startsWith('data-synapsis-ax-')));
        if (element.shadowRoot) roots.push(element.shadowRoot);
      }
      names.push(...Object.getOwnPropertyNames(document).filter(name => name.startsWith('synapsis-ax-handle-')));
      return names;
    }), []);
  };
  return { host, call, act, tab, evaluate, snapshot, markers, targetId, origin };
}

function renderedRefs(result) {
  assert.equal(result.refCount, result.refs.length);
  assert.deepEqual([...result.snapshot.matchAll(/\[ref=(e\d+)\]/g)].map(match => match[1]), result.refs.map(item => item.ref));
  for (const info of result.refs) assert.deepEqual(Object.keys(info).sort(), ['name', 'ref', 'role']);
}

function first(result) {
  assert.equal(Object.hasOwn(result, 'newElements'), false);
  assert.equal(result.snapshot.includes(' [new]'), false);
  renderedRefs(result);
}

test('role deltas follow exact names and positional duplicate identity while retained refs act', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const options = { selector: '#scope', interactive: true };
  const baseline = await f.snapshot(options);
  first(baseline);
  const repeated = await f.snapshot(options);
  assert.equal(repeated.newElements, 0);
  assert.equal(repeated.snapshot.includes(' [new]'), false);
  assert.notEqual(repeated.refs[0].ref, baseline.refs[0].ref);
  await f.evaluate(`() => {const b=document.createElement('button');b.id='added';b.textContent='Added action';b.onclick=()=>window.addedClicks=(window.addedClicks||0)+1;document.querySelector('#scope').append(b);return true;}`);
  const added = await f.snapshot(options);
  renderedRefs(added);
  assert.equal(added.newElements, 1);
  assert.match(added.snapshot, /button "Added action".* \[new\]$/m);
  assert.doesNotMatch(added.snapshot, /button "Keep action".* \[new\]/);
  assert.ok(added.snapshot.endsWith('1 new element(s) since last snapshot'));
  const retained = added.refs.find(item => item.name === 'Added action');
  await f.act({ kind: 'click', ref: retained.ref });
  assert.equal(await f.evaluate('() => window.addedClicks'), 1);
  await f.evaluate(`() => {document.querySelector('#added').textContent='Renamed action';return true;}`);
  const renamed = await f.snapshot(options);
  assert.equal(renamed.newElements, 1);
  assert.match(renamed.snapshot, /button "Renamed action".* \[new\]$/m);
  first(await f.snapshot({ selector: '#duplicates', interactive: true }));
  await f.evaluate(`() => {const b=document.createElement('button');b.textContent='Duplicate';document.querySelector('#duplicates').prepend(b);return true;}`);
  const duplicate = await f.snapshot({ selector: '#duplicates', interactive: true });
  assert.equal(duplicate.newElements, 1);
  const duplicateLines = duplicate.snapshot.split('\n').filter(line => line.includes('button "Duplicate"'));
  assert.equal(duplicateLines.length, 3);
  assert.deepEqual(duplicateLines.map(line => line.endsWith(' [new]')), [false, false, true]);
  await f.markers();
});

test('AI ARIA uses stable source refs across host aliases and same/OOP frame additions', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const options = { refs: 'aria', interactive: true };
  const initial = await f.snapshot(options);
  first(initial);
  const repeated = await f.snapshot(options);
  assert.equal(repeated.newElements, 0);
  assert.ok(repeated.refs.every(item => !initial.refs.some(old => old.ref === item.ref)));
  for (const selector of ['#same', '#cross']) {
    const element = await f.tab.page.locator(selector).elementHandle();
    try {
      const frame = await element.contentFrame();
      await frame.evaluate(() => { const button = document.createElement('button'); button.textContent = 'Added frame action'; button.onclick = () => window.addedClicks = (window.addedClicks || 0) + 1; document.querySelector('#frame-scope').append(button); });
      const changed = await f.snapshot(options);
      renderedRefs(changed);
      assert.equal(changed.newElements, 1);
      const added = changed.refs.filter(item => item.name === 'Added frame action').at(-1);
      assert.match(changed.snapshot, new RegExp(`\\[ref=${added.ref}\\].* \\[new\\]$`, 'm'));
      await f.act({ kind: 'click', ref: added.ref });
      assert.equal(await frame.evaluate(() => window.addedClicks), 1);
      if (selector === '#cross') {
        const session = await f.tab.page.context().newCDPSession(frame);
        try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
        finally { await session.detach(); }
      }
      assert.equal((await f.snapshot(options)).newElements, 0);
    } finally { await element.dispose(); }
  }
  await f.markers();
});

test('loader identity retains same-document hashes and resets same-URL reload baselines', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const options = { selector: '#scope', interactive: true };
  first(await f.snapshot(options));
  const hashChanged = f.tab.page.waitForEvent('framenavigated', { predicate: frame => frame === f.tab.page.mainFrame(), timeout: 15000 });
  await f.tab.page.evaluate(() => { location.hash = 'ordinary-section'; });
  await hashChanged;
  assert.equal((await f.snapshot(options)).newElements, 0);
  await f.tab.page.reload({ waitUntil: 'load' });
  first(await f.snapshot(options));
  assert.equal((await f.snapshot(options)).newElements, 0);
  await f.markers();
});

test('frame-tree replacement resets explicit-frame and ARIA families while main role remains comparable', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const main = { selector: '#scope', interactive: true };
  const framed = { frame: '#same', selector: '#frame-scope', interactive: true };
  const aria = { refs: 'aria', interactive: true };
  first(await f.snapshot(main)); first(await f.snapshot(framed)); first(await f.snapshot(aria));
  const cross = f.tab.page.frames().find(frame => frame.url().startsWith('http://localhost:'));
  const frameChanged = f.tab.page.waitForEvent('framenavigated', { predicate: frame => frame === cross, timeout: 15000 });
  await f.tab.page.locator('#cross').evaluate(frame => { frame.src = frame.src; });
  await frameChanged;
  await cross.waitForLoadState('load');
  assert.equal((await f.snapshot(main)).newElements, 0);
  first(await f.snapshot(framed)); first(await f.snapshot(aria));
  assert.equal((await f.snapshot(framed)).newElements, 0);
  assert.equal((await f.snapshot(aria)).newElements, 0);
  await f.markers();
});

test('normalized option families use bounded LRU and normal tab/host lifetime', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const options = { selector: '#scope', interactive: true };
  for (let depth = 0; depth < 32; depth++) first(await f.snapshot({ ...options, depth }));
  assert.equal((await f.snapshot({ ...options, depth: 0 })).newElements, 0);
  first(await f.snapshot({ ...options, depth: 32 }));
  first(await f.snapshot({ ...options, depth: 1 }));
  assert.equal((await f.snapshot({ ...options, depth: 0 })).newElements, 0);
  first(await f.snapshot({ ...options, compact: true }));
  const second = await f.call('open', { targetUrl: `${f.origin}/` });
  const secondTab = f.host.tabs.get(second.targetId);
  await secondTab.page.waitForLoadState('load');
  first(await f.call('snapshot', { targetId: second.targetId, ...options, depth: 0 }));
  await f.call('close', { targetId: second.targetId });
  assert.equal((await f.snapshot({ ...options, depth: 0 })).newElements, 0);
  const pid = f.host.diagnosticPid;
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  await f.call('start');
  const reopened = await f.call('open', { targetUrl: `${f.origin}/` });
  await f.host.tabs.get(reopened.targetId).page.waitForLoadState('load');
  first(await f.call('snapshot', { targetId: reopened.targetId, ...options, depth: 0 }));
});

test('complete-line budgets count visible keys and place delta summary after URL appendix', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const options = { selector: '#scope', interactive: true, urls: true };
  first(await f.snapshot(options));
  await f.evaluate(`() => {const button=document.createElement('button');button.textContent='New action';document.querySelector('#scope').append(button);return true;}`);
  const withUrls = await f.snapshot(options);
  renderedRefs(withUrls);
  assert.equal(withUrls.newElements, 1);
  assert.ok(withUrls.snapshot.indexOf('\n\nLinks:\n') < withUrls.snapshot.indexOf('1 new element(s) since last snapshot'));
  const short = { selector: '#budget', interactive: true, maxChars: 50 };
  await f.evaluate(`() => {document.querySelector('#budget').innerHTML='<button id="budget-first">First action</button><button>Second action</button>';return true;}`);
  const initial = await f.snapshot(short);
  first(initial); assert.equal(initial.refCount, 1); assert.equal(initial.truncated, true);
  await f.evaluate(`() => {document.querySelector('#budget-first').remove();return true;}`);
  const visible = await f.snapshot(short);
  renderedRefs(visible);
  assert.equal(visible.newElements, 1); assert.equal(visible.refCount, 1);
  assert.match(visible.snapshot, /button "Second action".* \[new\]$/);
  assert.equal(visible.truncated, true);
  assert.equal(visible.snapshot.includes('new element(s)'), false);
  assert.equal((await f.snapshot(short)).newElements, 0);
  const zero = { selector: '#scope', interactive: true, maxChars: 0 };
  first(await f.snapshot(zero));
  const empty = await f.snapshot(zero);
  assert.equal(empty.newElements, 0); assert.equal(empty.refCount, 0); assert.equal(empty.snapshot, '');
  const unicode = { selector: '#budget', interactive: true, maxChars: 131072 };
  await f.evaluate(`() => {document.querySelector('#budget').replaceChildren();return true;}`);
  first(await f.snapshot(unicode));
  await f.evaluate(`() => {const button=document.createElement('button');button.textContent='界'.repeat(87365);document.querySelector('#budget').append(button);return true;}`);
  const bounded = await f.snapshot(unicode);
  renderedRefs(bounded);
  assert.equal(bounded.newElements, 1); assert.equal(bounded.refCount, 1); assert.equal(bounded.truncated, true);
  assert.equal(bounded.refs[0].name.length, 87365);
  assert.ok(Buffer.byteLength(bounded.snapshot) <= 262144);
  assert.equal(bounded.snapshot.includes('new element(s)'), false);
  assert.equal((await f.snapshot(unicode)).newElements, 0);
  await f.markers();
});

test('raw snapshots leave AI baseline intact and delta captures preserve exact screenshot/emulation ownership', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate(`() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,ua:navigator.userAgent})`);
  const before = await observe();
  const owner = f.tab.emulation.session;
  const context = f.tab.page.context(); const attach = context.newCDPSession.bind(context); const captures = [];
  context.newCDPSession = async (...args) => {
    const session = await attach(...args); const record = { methods: [], detached: false }; captures.push(record);
    const send = session.send.bind(session); const detach = session.detach.bind(session);
    session.send = (method, ...params) => { record.methods.push(method); return send(method, ...params); };
    session.detach = async () => { await detach(); record.detached = true; };
    return session;
  };
  const options = { selector: '#scope', interactive: true };
  first(await f.snapshot(options));
  const raw = await f.snapshot({ snapshotFormat: 'aria' });
  assert.equal(Object.hasOwn(raw, 'newElements'), false); assert.equal(raw.format, 'aria');
  const repeated = await f.snapshot(options);
  assert.equal(repeated.newElements, 0);
  const keep = repeated.refs.find(item => item.name === 'Keep action');
  await f.act({ kind: 'click', ref: keep.ref });
  assert.equal(await f.evaluate('() => window.clicks'), 1);
  const image = await f.call('screenshot', { targetId: f.targetId, ref: keep.ref });
  const bytes = Buffer.from(image.content[1].data.data, 'base64');
  assert.deepEqual([bytes.readUInt32BE(16), bytes.readUInt32BE(20)], [288, 120]);
  assert.equal(f.tab.emulation.session, owner);
  assert.deepEqual(await observe(), before);
  assert.ok(captures.some(record => record.methods.filter(method => method === 'Page.getFrameTree').length === 2));
  assert.ok(captures.every(record => record.detached));
  await f.markers();
});
