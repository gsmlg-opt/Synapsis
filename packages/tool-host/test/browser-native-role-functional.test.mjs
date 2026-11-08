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
    if (req.url === '/frame') { res.end('<!doctype html><button onclick="window.frameClicks=(window.frameClicks||0)+1">Frame action</button>'); return; }
    res.end(`<!doctype html><title>Native roles</title><style>button{min-width:80px;min-height:30px}</style>
      <section id="scope"><h2>Native heading</h2><button id="named">Save <span aria-hidden="true">decoration</span></button>
      <label>Quantity<input type="number" value="3"></label><input type="search" aria-label="Find records">
      <div role="tree"><div role="treeitem" aria-expanded="true" aria-selected="true">Branch</div></div>
      <input type="checkbox" aria-label="Mixed choice" id="mixed"><button aria-pressed="mixed">Toggle</button>
      <button id="first" onclick="window.clicked='first'">Duplicate</button><button id="second" onclick="window.clicked='second'">Duplicate</button>
      <div id="depth"><h3>Depth zero</h3></div><div role="group"><div role="group"><button>Nested action</button></div></div>
      </section><button>Outside action</button><div id="shadow"></div><iframe id="same" src="/frame"></iframe>
      <iframe id="cross" src="http://localhost:${server.address().port}/frame"></iframe>
      <script>document.querySelector('#mixed').indeterminate=true;document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<section><h2>Shadow title</h2><button>Shadow action</button></section>';</script>`);
  });
  server.listen(0, '0.0.0.0');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-native-role-'));
  const host = new BrowserHost({ profile: 'native-role', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const snapshot = args => call('snapshot', { targetId, ...args });
  const markers = () => evaluate(`() => {const roots=[document];let found=[];for(const root of roots)for(const e of root.querySelectorAll('*')){found.push(...e.getAttributeNames().filter(n=>n.startsWith('data-synapsis-ax-')));if(e.shadowRoot)roots.push(e.shadowRoot)}return found;}`);
  return { host, call, act, evaluate, snapshot, markers, targetId };
}

function exported(result) {
  assert.equal(result.refCount, result.refs.length);
  assert.deepEqual([...result.snapshot.matchAll(/\[ref=(e\d+)\]/g)].map(match => match[1]), result.refs.map(item => item.ref));
}

test('native names, roles, states and named content are exported with exact retained identity', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.snapshot({ selector: '#scope' });
  exported(result);
  assert.ok(result.refs.some(item => item.role === 'button' && item.name === 'Save '));
  assert.ok(result.refs.some(item => item.role === 'spinbutton' && item.name === 'Quantity'));
  assert.ok(result.refs.some(item => item.role === 'searchbox' && item.name === 'Find records'));
  assert.ok(result.refs.some(item => item.role === 'heading' && item.name === 'Native heading'));
  assert.match(result.snapshot, /treeitem "Branch".*\[expanded\].*\[selected\]/);
  assert.match(result.snapshot, /checkbox "Mixed choice".*\[checked=mixed\]/);
  assert.match(result.snapshot, /button "Toggle".*\[pressed=mixed\]/);
  assert.match(result.snapshot, /spinbutton "Quantity".*value="3"/);
  assert.doesNotMatch(result.snapshot, /decoration|Outside action/);
  const second = result.refs.filter(item => item.name === 'Duplicate')[1];
  await f.evaluate(`() => {const first=document.querySelector('#first');first.before(document.querySelector('#second'));return true;}`);
  await f.act({ kind: 'click', ref: second.ref });
  assert.equal(await f.evaluate('() => window.clicked'), 'second');
  const image = await f.call('screenshot', { targetId: f.targetId, ref: second.ref });
  assert.equal(image.type, 'png');
  assert.ok(image.bytes > 0);
  assert.deepEqual(await f.markers(), []);
});

test('transparent roots, compact indentation and interactive shaping follow AX depth', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const shallow = await f.snapshot({ selector: '#depth', depth: 0 });
  assert.match(shallow.snapshot, /^- heading "Depth zero".*\[level=3\]/);
  const compact = await f.snapshot({ selector: '#scope', compact: true });
  assert.match(compact.snapshot, /^    - button "Nested action"/m);
  const interactive = await f.snapshot({ selector: '#scope', interactive: true });
  assert.doesNotMatch(interactive.snapshot, /heading|^ +-/m);
  assert.ok(interactive.refs.some(item => item.role === 'treeitem'));
  const efficient = await f.snapshot({ selector: '#scope', mode: 'efficient' });
  assert.equal(efficient.snapshot.replace(/e\d+/g, 'REF'), interactive.snapshot.replace(/e\d+/g, 'REF'));
  const explicit = await f.snapshot({ selector: '#depth', mode: 'efficient', interactive: false, compact: false, depth: 0 });
  assert.match(explicit.snapshot, /heading "Depth zero"/);
  assert.equal((await f.snapshot({ mode: 'efficient', maxChars: 0 })).snapshot, '');
  assert.deepEqual(await f.markers(), []);
});

test('selector inside shadow DOM and explicit same-process and OOP iframe scopes retain acts', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const shadow = await f.snapshot({ selector: '#shadow section' });
  assert.ok(shadow.refs.some(item => item.name === 'Shadow action'));
  assert.doesNotMatch(shadow.snapshot, /Outside action/);
  for (const frame of ['#same', '#cross']) {
    const result = await f.snapshot({ frame, interactive: true });
    exported(result);
    assert.deepEqual(result.refs.map(item => item.name), ['Frame action']);
    await f.act({ kind: 'click', ref: result.refs[0].ref });
    const selected = await f.host.tabs.get(f.targetId).page.locator(frame).elementHandle();
    try {
      const content = await selected.contentFrame();
      assert.equal(await content.evaluate(() => window.frameClicks), 1);
      assert.deepEqual(await content.evaluate(() => [...document.querySelectorAll('*')].flatMap(element => element.getAttributeNames().filter(name => name.startsWith('data-synapsis-ax-')))), []);
      if (frame === '#cross') {
        const session = await content.page().context().newCDPSession(content);
        try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
        finally { await session.detach(); }
      }
    }
    finally { await selected.dispose(); }
  }
  const main = await f.snapshot({ interactive: true });
  assert.equal(main.refs.filter(item => item.role === 'iframe').length, 2);
  assert.doesNotMatch(main.snapshot, /Frame action/);
  assert.deepEqual(await f.markers(), []);
});

test('record budgets export exactly rendered refs and preserve native emulation state', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate(`() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,coarse:matchMedia('(pointer:coarse)').matches,ua:navigator.userAgent})`);
  const before = await observe();
  assert.equal(before.dpr, 3);
  const limited = await f.snapshot({ interactive: true, limit: 2 });
  exported(limited);
  assert.equal(limited.truncated, true);
  assert.equal(limited.refs.length, 2);
  await f.evaluate(`() => {document.querySelector('#named').setAttribute('aria-label','界'.repeat(2000));return true;}`);
  const budget = await f.snapshot({ selector: '#scope', interactive: true, maxChars: 200 });
  exported(budget);
  assert.equal(budget.truncated, true);
  assert.ok(budget.snapshot.length <= 200);
  assert.ok(Buffer.byteLength(budget.snapshot) <= 262144);
  await f.evaluate(`() => {document.querySelector('#named').setAttribute('aria-label','L'.repeat(25000));return true;}`);
  const defaultBudget = await f.snapshot({ selector: '#named', interactive: true });
  exported(defaultBudget);
  assert.ok(defaultBudget.snapshot.length > 20000);
  assert.equal(defaultBudget.refs[0].name.length, 25000);
  const efficientBudget = await f.snapshot({ selector: '#named', mode: 'efficient' });
  assert.equal(efficientBudget.snapshot, '');
  assert.equal(efficientBudget.truncated, true);
  const overrideBudget = await f.snapshot({ selector: '#named', mode: 'efficient', maxChars: 40000 });
  assert.equal(overrideBudget.refs[0].name.length, 25000);
  assert.deepEqual(await observe(), before);
  assert.deepEqual(await f.markers(), []);
});
