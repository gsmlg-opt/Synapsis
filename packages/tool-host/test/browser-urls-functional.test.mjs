import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

const HEADER = '\n\nLinks:\n';
const longLabel = `${'L'.repeat(119)}😀tail`;

async function fixture(t) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/frame') {
      res.end('<!doctype html><section id="frame-scope"><button onclick="window.frameClicks=(window.frameClicks||0)+1">Frame action</button></section><a href="/frame-destination">Frame outside scope</a>');
      return;
    }
    res.end(`<!doctype html><title>URL appendix</title><meta name="viewport" content="width=device-width, initial-scale=1"><style>#keep{display:block;width:96px;height:40px}a{overflow-wrap:anywhere}</style>
      <section id="scope"><button id="keep" onclick="window.clicks=(window.clicks||0)+1">Keep action</button><a id="scope-link" href="/scope-destination" onclick="event.preventDefault();window.linkClicks=(window.linkClicks||0)+1">Scope link</a></section>
      <div id="empty-root"></div><a href="relative?x=1#part"> Relative\n  label </a><a href="relative?x=1#part">Later duplicate</a>
      <a href="/aria-label" aria-label="ARIA fallback"></a><a href="/empty-label"></a><a href="/long-label">${longLabel}</a><a href="/unicode">中文标签</a><a href="/space" aria-label="Unused because whitespace text exists">   </a>
      <div id="shadow"></div><iframe id="same" src="/frame"></iframe><iframe id="cross" src="http://localhost:${server.address().port}/frame"></iframe>
      <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<a href="/shadow-destination">Shadow link</a>';</script>`);
  });
  server.listen(0, '0.0.0.0');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-urls-'));
  const host = new BrowserHost({ profile: 'urls', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const snapshot = args => call('snapshot', { targetId, ...args });
  const tab = host.tabs.get(targetId);
  const markers = async () => {
    for (const frame of tab.page.frames()) assert.deepEqual(await frame.evaluate(() => {
      const roots = [document]; const attributes = [];
      for (const root of roots) for (const element of root.querySelectorAll('*')) {
        attributes.push(...element.getAttributeNames().filter(name => name.startsWith('data-synapsis-ax-')));
        if (element.shadowRoot) roots.push(element.shadowRoot);
      }
      attributes.push(...Object.getOwnPropertyNames(document).filter(name => name.startsWith('synapsis-ax-handle-')));
      return attributes;
    }), []);
  };
  return { host, call, act, evaluate, snapshot, markers, targetId, tab, origin };
}

function appendix(result) {
  const parts = result.snapshot.split(HEADER);
  assert.equal(parts.length, 2, result.snapshot);
  return parts[1].split('\n');
}

function renderedRefs(result) {
  assert.equal(result.refCount, result.refs.length);
  assert.deepEqual([...result.snapshot.matchAll(/\[ref=(e\d+)\]/g)].map(match => match[1]), result.refs.map(item => item.ref));
}

test('role URL appendix uses the selected document, absolute first-occurrence URLs and normalized labels', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.snapshot({ selector: '#scope', urls: true });
  assert.deepEqual(appendix(result), [
    `1. Scope link -> ${f.origin}/scope-destination`,
    `2. Relative label -> ${f.origin}/relative?x=1#part`,
    `3. ARIA fallback -> ${f.origin}/aria-label`,
    `4. ${f.origin}/empty-label -> ${f.origin}/empty-label`,
    `5. ${'L'.repeat(119)} -> ${f.origin}/long-label`,
    `6. 中文标签 -> ${f.origin}/unicode`,
    `7. ${f.origin}/space -> ${f.origin}/space`,
  ]);
  assert.equal(result.truncated, false);
  assert.doesNotMatch(result.snapshot, /\[url=/);
  assert.deepEqual(result.refs.map(item => item.name).sort(), ['Keep action', 'Scope link']);
  renderedRefs(result);
  const link = result.refs.find(item => item.name === 'Scope link');
  const button = result.refs.find(item => item.name === 'Keep action');
  await f.act({ kind: 'click', ref: link.ref });
  await f.act({ kind: 'click', ref: button.ref });
  assert.deepEqual(await f.evaluate('() => [window.linkClicks,window.clicks]'), [1, 1]);
  const image = await f.call('screenshot', { targetId: f.targetId, ref: button.ref });
  const bytes = Buffer.from(image.content[1].data.data, 'base64');
  assert.deepEqual([bytes.readUInt32BE(16), bytes.readUInt32BE(20)], [96, 40]);
  for (const args of [{}, { urls: false }]) {
    const plain = await f.snapshot({ selector: '#scope', ...args });
    assert.equal(plain.snapshot.includes(HEADER), false);
    renderedRefs(plain);
  }
  await f.markers();
});

test('explicit same-process and OOP role frames collect their whole fixed document beyond the root', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  for (const selector of ['#same', '#cross']) {
    const result = await f.snapshot({ frame: selector, selector: '#frame-scope', urls: true });
    const element = await f.tab.page.locator(selector).elementHandle();
    try {
      const frame = await element.contentFrame();
      assert.deepEqual(appendix(result), [`1. Frame outside scope -> ${new URL('/frame-destination', frame.url()).href}`]);
      assert.deepEqual(result.refs.map(item => item.name), ['Frame action']);
      renderedRefs(result);
      await f.act({ kind: 'click', ref: result.refs[0].ref });
      assert.equal(await frame.evaluate(() => window.frameClicks), 1);
      if (selector === '#cross') {
        const session = await f.tab.page.context().newCDPSession(frame);
        try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
        finally { await session.detach(); }
      }
    } finally { await element.dispose(); }
  }
  await f.markers();
});

test('AI ARIA appends only main document anchors while native raw ignores valid urls', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const aria = await f.snapshot({ refs: 'aria', urls: true });
  const links = appendix(aria);
  assert.equal(links.length, 7);
  assert.ok(aria.snapshot.includes('Shadow link'));
  assert.equal(aria.refs.filter(item => item.name === 'Frame outside scope').length, 2);
  assert.ok(links.every(line => !line.includes('Shadow link') && !line.includes('Frame outside scope')));
  renderedRefs(aria);
  const plain = await f.snapshot({ refs: 'aria', urls: false });
  assert.equal(plain.snapshot.includes(HEADER), false);
  assert.ok(plain.snapshot.includes('/scope-destination'));
  const raw = await f.snapshot({ snapshotFormat: 'aria', urls: true });
  assert.equal(raw.format, 'aria');
  assert.equal(raw.snapshot, undefined);
  assert.equal(raw.nodeCount, raw.nodes.length);
  assert.ok(raw.nodeCount > raw.refCount);
  await f.markers();
});

test('URL collection caps at the first hundred unique entries and leaves an empty document unchanged', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.evaluate(`() => { for(const a of document.querySelectorAll('a[href]')) a.remove();for(let i=0;i<105;i++){const a=document.createElement('a');a.href='/item-'+i;a.textContent='Item '+i;document.body.append(a);if(i===0)document.body.append(a.cloneNode(true));}return true; }`);
  const capped = await f.snapshot({ selector: '#empty-root', urls: true });
  const lines = appendix(capped);
  assert.equal(lines.length, 100);
  assert.equal(lines[0], `1. Item 0 -> ${f.origin}/item-0`);
  assert.equal(lines[99], `100. Item 99 -> ${f.origin}/item-99`);
  assert.equal(capped.refCount, 0);
  await f.evaluate(`() => {for(const a of document.querySelectorAll('a[href]')) a.remove();return true;}`);
  const empty = await f.snapshot({ selector: '#empty-root', urls: true });
  assert.equal(empty.snapshot, '(empty)'); assert.equal(empty.truncated, false); assert.equal(empty.refCount, 0);
  await f.markers();
});

test('complete URL lines share character and UTF8 budgets without disturbing refs, emulation or cleanup', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate(`() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,ua:navigator.userAgent})`);
  const before = await observe();
  const owner = f.tab.emulation.session;
  const bounded = await f.snapshot({ selector: '#scope', urls: true, maxChars: 170 });
  renderedRefs(bounded);
  assert.equal(bounded.truncated, true); assert.ok(bounded.snapshot.length <= 170);
  const body = bounded.snapshot.split(HEADER)[0];
  assert.ok(body.includes('Keep action'));
  assert.ok(!bounded.snapshot.endsWith('Links:\n'));
  const retained = bounded.refs.find(item => item.name === 'Keep action');
  await f.act({ kind: 'click', ref: retained.ref });
  assert.equal(await f.evaluate('() => window.clicks'), 1);
  const zero = await f.snapshot({ selector: '#scope', urls: true, maxChars: 0 });
  assert.equal(zero.snapshot, ''); assert.equal(zero.refCount, 0); assert.equal(zero.truncated, true);
  await f.evaluate(`() => {for(const a of document.querySelectorAll('a[href]'))a.remove();for(let i=0;i<20;i++){const a=document.createElement('a');a.href='https://example.test/'+i+'/'+'界'.repeat(3000);a.textContent='Long '+i;document.body.append(a);}return true;}`);
  const { collectSnapshotUrls, appendSnapshotUrls } = await import('../src/browser/snapshot-urls.mjs');
  const collected = await collectSnapshotUrls(f.tab.page);
  assert.equal(collected.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(collected)) <= 262144);
  assert.ok(collected.entries.length > 0 && collected.entries.length < 20);
  assert.ok(collected.entries.every(entry => entry.url.endsWith('%E7%95%8C'.repeat(3000))));
  const unicodeBody = '界'.repeat(85000);
  const utf8 = appendSnapshotUrls(unicodeBody, { entries: [{ text: 'Ordinary label', url: `https://example.test/${'a'.repeat(10000)}` }], truncated: false }, 131072);
  assert.deepEqual(utf8, { snapshot: unicodeBody, truncated: true });
  const budget = await f.snapshot({ selector: '#scope', urls: true, maxChars: 131072 });
  renderedRefs(budget);
  assert.equal(budget.truncated, true);
  assert.ok(budget.snapshot.length <= 131072); assert.ok(Buffer.byteLength(budget.snapshot) <= 262144);
  assert.ok(appendix(budget).every(line => line.endsWith('%E7%95%8C'.repeat(3000))));
  assert.equal(f.tab.emulation.session, owner);
  assert.deepEqual(await observe(), before);
  await f.markers();
});
