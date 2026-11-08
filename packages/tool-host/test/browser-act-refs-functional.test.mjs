import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

// Positive post-implementation coverage only; never run against the old host.
// Literal expectations are independent of host normalization: OpenClaw 488631c
// extensions/browser/src/browser/routes/agent.act.normalize.ts:40-47,153-158,
// 193-201,218-237,302-308 and routes/utils.ts:96-101 trim ordinary refs through
// toStringOrEmpty. This bounded change preserves local selector and fn content.
const markFn = ' \n element => { element.dataset.marks = String(Number(element.dataset.marks || 0) + 1); return {id:element.id,marks:Number(element.dataset.marks),scrolled:document.querySelector("#scroller").scrollTop > 0}; } \t';

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
  const server = createServer((_request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><title>Act refs</title>
      <style>button,input{width:160px;height:40px;margin:8px}#scroller{height:140px;width:500px;overflow:auto}#scroll{margin-top:900px;display:block}#drag-area{display:flex}</style>
      <button id="click">Click target</button><label>Text target<input id="text" value="seed"></label>
      <button id="hover">Hover target</button><button id="decoy">Decoy target</button>
      <label>Decoy text<input id="decoy-text" value="seed"></label>
      <div id="drag-area"><button id="source">Drag source</button><button id="destination">Drag destination</button></div>
      <div id="scroller"><button id="scroll">Scroll target</button></div>
      <script>
        window.effects = {clicks:[],hovers:[],inputs:[],drags:[]}; let dragStart;
        document.querySelector('#click').onclick = () => { effects.clicks.push('click'); document.querySelector('#scroller').scrollTop = 0; };
        document.querySelector('#decoy').onclick = () => effects.clicks.push('decoy');
        for (const id of ['hover','decoy']) document.querySelector('#'+id).onmouseenter = () => effects.hovers.push(id);
        document.querySelector('#text').oninput = event => effects.inputs.push(event.target.value);
        document.querySelector('#source').onmousedown = event => { dragStart = event.target.id; };
        document.querySelector('#destination').onmouseup = event => { effects.drags.push([dragStart,event.target.id]); dragStart = null; };
      </script>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-act-refs-'));
  const host = new BrowserHost({ profile: 'act-refs', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
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
  return { host, page, ref, close, targetId, url, generation: host.generation, act: request => call('act', { targetId, request }) };
}

for (const nested of [false, true]) {
  test(`ordinary act ${nested ? 'depth-two batch' : 'standalone'} trims private refs and performs each DOM effect`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const refs = { click: f.ref('button', 'Click target'), text: f.ref('textbox', 'Text target'), hover: f.ref('button', 'Hover target'), scroll: f.ref('button', 'Scroll target'), source: f.ref('button', 'Drag source'), destination: f.ref('button', 'Drag destination') };
    const actions = [
      { kind: 'click', ref: ` \t${refs.click}\n`, selector: '  #decoy  ' },
      { kind: 'type', ref: ` \t${refs.text}\n`, selector: '  #decoy-text  ', text: ' padded text ' },
      { kind: 'hover', ref: ` \t${refs.hover}\n`, selector: '  #decoy  ' },
      { kind: 'scrollIntoView', ref: ` \t${refs.scroll}\n`, selector: '  #decoy  ' },
      { kind: 'evaluate', ref: ` \t${refs.scroll}\n`, selector: '  #decoy  ', fn: markFn },
      { kind: 'drag', startRef: ` \t${refs.source}\n`, endRef: ` \t${refs.destination}\n` },
    ];
    const request = nested ? { kind: 'batch', actions: [{ kind: 'batch', actions }] } : actions;
    const original = structuredClone(request);
    const leaves = [];
    const act = f.host.act.bind(f.host);
    f.host.act = (tab, item, operation) => {
      if (item.kind !== 'batch') leaves.push(Object.fromEntries(Object.entries(item).filter(([key]) => ['kind','ref','startRef','endRef','selector','text','fn'].includes(key))));
      return act(tab, item, operation);
    };
    const result = nested ? await f.act(request) : await (async () => {
      const receipts = [];
      for (const action of actions) receipts.push(await f.act(action));
      return receipts;
    })();
    const effects = await f.page.evaluate(() => ({ ...window.effects, text: document.querySelector('#text').value, decoyText: document.querySelector('#decoy-text').value, marks: document.querySelector('#scroll').dataset.marks, scrolled: document.querySelector('#scroller').scrollTop > 0 }));
    await f.close();

    const metadata = { generation: f.generation, targetId: f.targetId, url: f.url };
    const values = [{ ok: true }, { ok: true }, { ok: true }, { ok: true }, { ...(nested ? { ok: true } : {}), value: { id: 'scroll', marks: 1, scrolled: true } }, { ok: true }];
    assert.deepEqual(result, nested ? { ...metadata, results: [{ ok: true, results: values }] } : values.map(value => ({ ...metadata, ...value })));
    for (const receipt of nested ? [result] : result) assert.equal(receipt[RESULT_DISPATCHED], true);
    assert.deepEqual(effects, { clicks: ['click'], hovers: ['hover'], inputs: [' padded text '], drags: [['source','destination']], text: ' padded text ', decoyText: 'seed', marks: '1', scrolled: true });
    assert.deepEqual(request, original);
    // Independent literal leaf expectations also prove content/selector bytes survive.
    assert.deepEqual(leaves, [
      { kind: 'click', ref: refs.click, selector: '  #decoy  ' },
      { kind: 'type', ref: refs.text, selector: '  #decoy-text  ', text: ' padded text ' },
      { kind: 'hover', ref: refs.hover, selector: '  #decoy  ' },
      { kind: 'scrollIntoView', ref: refs.scroll, selector: '  #decoy  ' },
      { kind: 'evaluate', ref: refs.scroll, selector: '  #decoy  ', fn: markFn },
      { kind: 'drag', startRef: refs.source, endRef: refs.destination },
    ]);
  });
}
