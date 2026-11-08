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
      res.end(`<!doctype html><label>Frame value<input value="frame initial"></label><button onclick="window.frameClicks=(window.frameClicks||0)+1">Frame action</button>`);
      return;
    }
    res.end(`<!doctype html><title>ARIA fixture</title><style>button{display:block;width:96px;height:40px}input{width:110px}#second{position:absolute;left:500px;top:0}</style>
      <h2>Structured heading</h2><p>Meaningful static text</p><div>Ordinary generic text</div><section><div>Nested generic text</div></section><div role="group">Group sole text</div><a href="/destination">Destination</a>
      <label>Field<input id="field1" value="first initial" placeholder="Write here"></label>
      <label>Field<input id="field2" value="second initial" aria-describedby="description"></label>
      <p id="description">Native field description</p><textarea aria-label="Notes">Text area value</textarea>
      <input type="checkbox" aria-label="Mixed choice" id="mixed"><button aria-pressed="mixed">Toggle</button>
      <button disabled>Disabled action</button><div role="tree"><div role="treeitem" aria-expanded="true" aria-selected="true">Branch</div></div>
      <button id="first" onclick="window.clicked='first'">Duplicate</button><button id="second" onclick="window.clicked='second'">Duplicate</button>
      <div role="group"><div role="group"><button>Nested action</button></div></div><div id="shadow"></div>
      <iframe id="same" src="/frame"></iframe><iframe id="cross" src="http://localhost:${server.address().port}/frame"></iframe>
      <script>document.querySelector('#mixed').indeterminate=true;document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<button onclick="window.shadowClicks=(window.shadowClicks||0)+1">Shadow action</button>';</script>`);
  });
  server.listen(0, '0.0.0.0');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-aria-'));
  const host = new BrowserHost({ profile: 'aria', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
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
  return { host, call, act, evaluate, snapshot, markers, targetId, tab };
}

function refs(result, format = 'ai') {
  assert.equal(result.format, format);
  assert.equal(result.refsType, format === 'ai' ? 'aria' : 'ax');
  assert.equal(result.refCount, result.refs.length);
  assert.equal(new Set(result.refs.map(item => item.ref)).size, result.refCount);
  for (const item of result.refs) assert.match(item.ref, format === 'ai' ? /^e\d+$/ : /^ax\d+$/);
}

async function exactActions(f, result) {
  const second = result.refs.filter(item => item.name === 'Duplicate')[1];
  const field = result.refs.filter(item => item.role === 'textbox' && item.name === 'Field')[1];
  await f.evaluate(`() => {document.querySelector('#first').before(document.querySelector('#second'));document.querySelector('#field1').before(document.querySelector('#field2'));return true;}`);
  await f.act({ kind: 'fill', fields: [{ ref: field.ref, value: 'retained second' }] });
  await f.act({ kind: 'click', ref: second.ref });
  assert.deepEqual(await f.evaluate(`() => [window.clicked,document.querySelector('#field1').value,document.querySelector('#field2').value]`), ['second', 'first initial', 'retained second']);
  const image = await f.call('screenshot', { targetId: f.targetId, ref: second.ref });
  assert.equal(image.type, 'png');
  const bytes = Buffer.from(image.content[1].data.data, 'base64');
  assert.equal(bytes.subarray(1, 4).toString(), 'PNG');
  assert.deepEqual([bytes.readUInt32BE(16), bytes.readUInt32BE(20)], [96, 40]);
}

test('AI ARIA captures public YAML once and resolves exact main, shadow and frame source refs', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const page = f.tab.page;
  const originalYAML = page.ariaSnapshot.bind(page);
  const originalRef = page.getByRef.bind(page);
  const captures = []; const sources = [];
  page.ariaSnapshot = options => { captures.push(options); return originalYAML(options); };
  page.getByRef = source => { sources.push(source); return originalRef(source); };
  const result = await f.snapshot({ refs: 'aria' });
  refs(result);
  assert.equal(captures.length, 1);
  assert.equal(captures[0].mode, 'ai');
  assert.ok(captures[0].signal instanceof AbortSignal);
  assert.ok(Number.isFinite(captures[0].timeout) && captures[0].timeout > 0);
  assert.equal(sources.length, result.refCount);
  assert.ok(sources.some(source => /^f\d+e\d+$/.test(source)));
  for (const text of ['Meaningful static text', 'first initial', 'Text area value', 'Write here', '/destination', 'Shadow action']) assert.ok(result.snapshot.includes(text), text);
  assert.match(result.snapshot, /checkbox "Mixed choice".*\[checked=mixed\]/);
  assert.match(result.snapshot, /button "Toggle".*\[pressed=mixed\]/);
  assert.match(result.snapshot, /button "Disabled action".*\[disabled\]/);
  assert.match(result.snapshot, /treeitem "Branch".*\[expanded\]/);
  assert.match(result.snapshot, /treeitem "Branch".*\[selected\]/);
  assert.match(result.snapshot, /heading "Structured heading".*\[level=2\]/);
  await exactActions(f, result);
  await f.act({ kind: 'click', ref: result.refs.find(item => item.name === 'Shadow action').ref });
  assert.equal(await f.evaluate('() => window.shadowClicks'), 1);
  const frameRefs = result.refs.filter(item => item.name === 'Frame action');
  const frameFields = result.refs.filter(item => item.name === 'Frame value');
  assert.equal(frameRefs.length, 2); assert.equal(frameFields.length, 2);
  for (let i = 0; i < 2; i++) {
    await f.act({ kind: 'fill', fields: [{ ref: frameFields[i].ref, value: `frame ${i}` }] });
    await f.act({ kind: 'click', ref: frameRefs[i].ref });
    const frame = f.tab.page.frames().find(frame => frame !== f.tab.page.mainFrame() && new URL(frame.url()).hostname === (i === 0 ? '127.0.0.1' : 'localhost'));
    assert.deepEqual(await frame.evaluate(() => [window.frameClicks, document.querySelector('input').value]), [1, `frame ${i}`]);
    if (i === 1) {
      const session = await page.context().newCDPSession(frame);
      try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
      finally { await session.detach(); }
    }
  }
  await f.markers();
});

test('AI ARIA shapes interactive, compact, rendered depth and explicit efficient overrides', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const interactive = await f.snapshot({ refs: 'aria', interactive: true });
  refs(interactive);
  assert.doesNotMatch(interactive.snapshot, /^ +-|heading|^- iframe/m);
  assert.equal(interactive.refs.filter(item => item.name === 'Frame action').length, 2);
  const efficient = await f.snapshot({ refs: 'aria', mode: 'efficient' });
  assert.ok(Math.min(...efficient.refs.map(item => Number(item.ref.slice(1)))) > Math.max(...interactive.refs.map(item => Number(item.ref.slice(1)))));
  assert.equal(efficient.snapshot.replace(/e\d+/g, 'REF'), interactive.snapshot.replace(/e\d+/g, 'REF'));
  const complete = await f.snapshot({ refs: 'aria' });
  for (const text of ['Ordinary generic text', 'Nested generic text', 'Group sole text']) assert.ok(complete.snapshot.includes(text), text);
  const compact = await f.snapshot({ refs: 'aria', compact: true });
  assert.ok(compact.snapshot.includes('Meaningful static text'));
  // The pinned YAML shaper removes an unnamed structural line including its scalar.
  for (const text of ['Ordinary generic text', 'Nested generic text', 'Group sole text']) assert.equal(compact.snapshot.includes(text), false, text);
  assert.ok(compact.snapshot.includes('first initial'));
  assert.ok(compact.snapshot.includes('/destination'));
  assert.doesNotMatch(compact.snapshot, /- group(?: \[ref=e\d+\])?:?$/m);
  const shallow = await f.snapshot({ refs: 'aria', mode: 'efficient', interactive: false, compact: false, depth: 0 });
  assert.ok(shallow.snapshot.length > 0);
  assert.ok(shallow.snapshot.split('\n').every(line => !line.startsWith('  ')));
  assert.doesNotMatch(shallow.snapshot, /Nested action/);
  const explicit = await f.snapshot({ refs: 'aria', mode: 'efficient', interactive: false, compact: false, depth: 100 });
  assert.match(explicit.snapshot, /heading "Structured heading"/);
  const empty = await f.snapshot({ refs: 'aria', mode: 'efficient', maxChars: 0 });
  assert.equal(empty.snapshot, ''); assert.equal(empty.refCount, 0); assert.equal(empty.truncated, true);
  const limited = await f.snapshot({ refs: 'aria', interactive: true, limit: 2 });
  assert.equal(limited.snapshot.split('\n').length, 2); assert.equal(limited.refCount, 2); assert.equal(limited.truncated, true);
  await f.markers();
});

test('raw ARIA retains native preorder, document/text, names, values and descriptions with separate actionable refs', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const session = await f.tab.page.context().newCDPSession(f.tab.page);
  let native;
  try { native = (await session.send('Accessibility.getFullAXTree')).nodes; }
  finally { await session.detach(); }
  const result = await f.snapshot({ snapshotFormat: 'aria' });
  refs(result, 'aria');
  assert.equal(result.nodeCount, result.nodes.length);
  assert.ok(result.nodeCount > result.refCount);
  assert.equal(result.nodes[0].role, 'RootWebArea'); assert.equal(result.nodes[0].depth, 0); assert.equal(result.nodes[0].actionable, false);
  assert.ok(result.nodes.some(node => node.role === 'StaticText' && node.name === 'Meaningful static text' && !node.actionable));
  assert.ok(result.nodes.some(node => node.role === 'InlineTextBox' && !node.actionable));
  const field = result.nodes.find(node => node.description === 'Native field description');
  assert.equal(field.value, 'second initial'); assert.equal(field.actionable, true); assert.equal(field.role, 'textbox');
  const byId = new Map(native.map(node => [node.nodeId, node]));
  const childIds = new Set(native.flatMap(node => node.childIds ?? []));
  const pending = [{ node: native.find(node => !childIds.has(node.nodeId)), depth: 0 }];
  const expected = [];
  while (pending.length) {
    const { node, depth } = pending.pop();
    expected.push([node.role?.value || 'unknown', node.name?.value || '', depth]);
    for (const id of [...(node.childIds ?? [])].reverse()) if (byId.has(id)) pending.push({ node: byId.get(id), depth: depth + 1 });
  }
  assert.deepEqual(result.nodes.map(node => [node.role, node.name, node.depth]), expected);
  assert.deepEqual(result.refs.map(item => item.ref), result.nodes.filter(node => node.actionable).map(node => node.ref));
  await exactActions(f, result);
  await f.markers();
});

test('ordinary ARIA budgets, capture cleanup and emulation owner remain stable across replacement captures', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate(`() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,ua:navigator.userAgent})`);
  const before = await observe();
  const owner = await f.tab.emulation.session;
  const context = f.tab.page.context(); const attach = context.newCDPSession.bind(context);
  const allCaptures = [];
  context.newCDPSession = async target => {
    const session = await attach(target); const send = session.send.bind(session); const detach = session.detach.bind(session);
    const record = { session, methods: [], detached: false }; allCaptures.push(record);
    session.send = (method, args) => { record.methods.push(method); return send(method, args); };
    session.detach = async () => { await detach(); record.detached = true; };
    return session;
  };
  const ai = await f.snapshot({ refs: 'aria', limit: 2 });
  const aiCaptureCount = allCaptures.length;
  assert.ok(aiCaptureCount > 0);
  assert.ok(allCaptures.every(record => record.detached && record.session !== owner));
  assert.ok(allCaptures.every(record => record.methods.filter(method => method === 'Page.getFrameTree').length === 2));
  assert.ok(allCaptures.every(record => record.methods.every(method => method === 'Page.getFrameTree')));
  const oldHandles = [...f.tab.refs.values()];
  const raw = await f.snapshot({ snapshotFormat: 'aria', limit: 5, depth: 0, interactive: true, compact: true, maxChars: 0, refs: 'aria' });
  const captures = allCaptures.slice(aiCaptureCount);
  refs(raw, 'aria');
  assert.equal(raw.nodeCount, 5); assert.equal(raw.truncated, true);
  assert.ok(raw.nodes.some(node => node.depth > 0));
  assert.ok(raw.refs.every(item => !ai.refs.some(old => old.ref === item.ref)));
  assert.ok(oldHandles.every(handle => ![...f.tab.refs.values()].includes(handle)));
  assert.equal(captures.length, 1); assert.notEqual(captures[0].session, owner); assert.equal(captures[0].detached, true);
  assert.ok(captures[0].methods.includes('Accessibility.getFullAXTree'));
  assert.ok(captures[0].methods.includes('Runtime.releaseObject'));
  assert.ok(captures[0].methods.every(method => !method.startsWith('Emulation.') && !method.startsWith('Page.captureScreenshot')));
  await f.evaluate(`() => {document.querySelector('#first').setAttribute('aria-label','界'.repeat(2000));return true;}`);
  const bounded = await f.snapshot({ refs: 'aria', interactive: true, maxChars: 200 });
  assert.ok(bounded.snapshot.length <= 200); assert.equal(bounded.truncated, true);
  await f.evaluate(`() => {document.querySelector('#first').setAttribute('aria-label','L'.repeat(25000));return true;}`);
  const large = await f.snapshot({ refs: 'aria', interactive: true, limit: 500 });
  // The public YAML formatter omits names longer than 900 UTF-16 units.
  // The source reference still binds the original control without another capture.
  const omitted = large.refs.find(item => item.role === 'button' && item.name === '');
  assert.ok(omitted);
  assert.deepEqual(await f.tab.refs.get(omitted.ref).evaluate(element => [element.id, element.getAttribute('aria-label').length]), ['first', 25000]);
  await f.act({ kind: 'click', ref: omitted.ref });
  assert.equal(await f.evaluate('() => window.clicked'), 'first');
  const small = await f.snapshot({ refs: 'aria', mode: 'efficient' });
  assert.equal(small.truncated, false); assert.ok(small.snapshot.length <= 8000);
  await f.evaluate(`() => {document.querySelector('#first').setAttribute('aria-label','界'.repeat(100000));return true;}`);
  const rawBudget = await f.snapshot({ snapshotFormat: 'aria', limit: 2000 });
  assert.equal(rawBudget.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(rawBudget.nodes)) <= 262144);
  assert.ok(rawBudget.nodes.every(node => !node.name.startsWith('界')));
  assert.deepEqual(await observe(), before);
  await f.markers();
});

test('YAML renderer preserves ordinary scalar text, states and nested properties', async () => {
  const { renderAriaYaml } = await import('../src/browser/aria-yaml.mjs');
  let sequence = 0;
  const yaml = `- generic [ref=e1]:
  - text: loose text
  - textbox "Notes" [active] [ref=f2e4]: entered value
    - /placeholder: Hint
  - checkbox "Choice" [checked=mixed] [ref=e5]
  - link "Page" [cursor=pointer] [ref=e6]:
    - /url: /path`;
  const result = renderAriaYaml(yaml, { limit: 100, depth: 100, maxChars: 40000, compact: true, interactive: false }, () => `e${++sequence}`);
  for (const text of ['loose text', 'entered value', '[active]', '[checked=mixed]', '/placeholder: Hint', '[cursor=pointer]', '/url: /path']) assert.ok(result.snapshot.includes(text), text);
  assert.deepEqual(result.refs.map(({ ref, sourceRef }) => [ref, sourceRef]), [['e1', 'f2e4'], ['e2', 'e5'], ['e3', 'e6']]);
});
