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

function documentHtml(direction) {
  const html5 = direction === 'html5';
  const sourceTop = direction === 'up' ? 2300 : 40;
  const destinationTop = direction === 'down' ? 2300 : 40;
  return `<!doctype html><meta charset="utf-8"><title>Retained drag ${direction}</title>
    <style>
      #scroller{height:240px;width:640px;overflow:auto;scroll-behavior:auto}
      #area{height:${html5 ? 240 : 2500}px;position:relative}
      [role=button]{position:absolute;width:180px;height:60px;box-sizing:border-box;background:#ddd;user-select:none}
      [data-identity="original-source"]{left:30px;top:${sourceTop}px}
      [data-identity="original-destination"]{left:${html5 ? 330 : 30}px;top:${destinationTop}px}
    </style>
    <div id="scroller"><div id="area">
      <div role="button" tabindex="0" id="source" data-identity="original-source" ${html5 ? 'draggable="true"' : ''}>Drag source</div>
      <div role="button" tabindex="0" id="destination" data-identity="original-destination">Drag destination</div>
    </div></div><output id="result">waiting</output>
    <script>
      var source = document.getElementById('source');
      var destination = document.getElementById('destination');
      var scroller = document.getElementById('scroller');
      var dragStart;
      window.effects = {presses:[],releases:[],transfers:[],starts:[],drops:[],overSeen:false};
      function visible(element) {
        var bounds = element.getBoundingClientRect(); var viewport = scroller.getBoundingClientRect();
        return bounds.top >= viewport.top && bounds.bottom <= viewport.bottom;
      }
      source.addEventListener('mousedown', function(event) {
        if (${html5}) return;
        event.preventDefault(); dragStart = this.dataset.identity;
        effects.presses.push({source:dragStart,button:event.button,buttons:event.buttons,
          trusted:event.isTrusted,destinationVisible:visible(destination)});
      });
      destination.addEventListener('mouseup', function(event) {
        if (${html5}) return;
        effects.releases.push({destination:this.dataset.identity,button:event.button,buttons:event.buttons,trusted:event.isTrusted});
        effects.transfers.push([dragStart,this.dataset.identity]);
        document.getElementById('result').textContent = dragStart + ' -> ' + this.dataset.identity;
      });
      source.addEventListener('dragstart', function(event) {
        event.dataTransfer.setData('text/plain','retained payload 雪😀');
        event.dataTransfer.effectAllowed = 'copy';
        effects.starts.push({source:this.dataset.identity,trusted:event.isTrusted});
      });
      destination.addEventListener('dragover', function(event) {
        event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; effects.overSeen = true;
      });
      destination.addEventListener('drop', function(event) {
        event.preventDefault();
        var payload = event.dataTransfer.getData('text/plain');
        effects.drops.push({destination:this.dataset.identity,payload:payload,
          types:Array.from(event.dataTransfer.types),trusted:event.isTrusted});
        document.getElementById('result').textContent = payload;
      });
      window.prepareDrag = function() {
        for (var element of [source,destination]) {
          var id = element.id; var name = element.textContent;
          element.id = 'retained-' + id; element.textContent = 'Retained ' + id;
          var decoy = document.createElement('div');
          decoy.id = id; decoy.setAttribute('role','button'); decoy.tabIndex = 0;
          decoy.textContent = name; decoy.style.left = '440px';
          decoy.style.top = element.offsetTop + 'px';
          document.getElementById('area').appendChild(decoy);
        }
        return {source:source.id,destination:destination.id};
      };
      window.dragProof = function() {
        return {...effects,output:document.getElementById('result').textContent,
          source:source.id,destination:destination.id,
          sourceVisible:visible(source),destinationVisible:visible(destination),scrolled:scroller.scrollTop > 0};
      };
      window.dragReady = true;
    </script>`;
}

async function fixture(t, direction) {
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-drag-'));
  let pageLoads = 0;
  const server = createServer((request, response) => {
    if (request.url === '/favicon.ico') { response.writeHead(204); response.end(); return; }
    pageLoads++;
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(documentHtml(direction));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = new BrowserHost({ profile: 'drag', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => {
    try {
      const owned = host.diagnosticPid ? await processTree(host.diagnosticPid) : [];
      assert.equal((await host.close()).cleanup_confirmed, true);
      const deadline = performance.now() + 15000;
      for (const pid of owned) {
        while (true) {
          try { process.kill(pid, 0); } catch (error) { assert.equal(error.code, 'ESRCH'); break; }
          assert.ok(performance.now() < deadline, `owned Chromium process ${pid} exited`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      }
      assert.equal(host.operation, null);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const url = `http://127.0.0.1:${server.address().port}/page`;
  const { targetId } = await call('open', { targetUrl: url });
  const tab = host.tabs.get(targetId);
  await tab.page.waitForLoadState('load');
  assert.equal(await tab.page.evaluate(() => window.dragReady), true);
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const ref = name => {
    const found = snapshot.refs.find(item => item.role === 'button' && item.name === name);
    assert.ok(found, `snapshot includes ${name}`);
    return found.ref;
  };
  const startRef = ref('Drag source'); const endRef = ref('Drag destination');
  const custody = { document: tab.document, snapshot: tab.snapshot, refs: [...tab.refs], metadata: [...tab.refMetadata] };
  assert.deepEqual(await tab.page.evaluate(() => window.prepareDrag()), { source: 'retained-source', destination: 'retained-destination' });
  return { host, tab, call, targetId, url, startRef, endRef, custody, pageLoads: () => pageLoads };
}

async function drag(f) {
  const request = Object.freeze({ kind: 'drag', startRef: ` \t${f.startRef}\n`, endRef: ` \t${f.endRef}\n` });
  const args = Object.freeze({ targetId: f.targetId, request });
  const original = structuredClone(args);
  const pid = f.host.diagnosticPid;
  const result = await f.call('act', args);
  const proof = await f.tab.page.evaluate(() => window.dragProof());
  assert.deepEqual(result, { generation: f.host.generation, targetId: f.targetId, url: f.url, ok: true });
  assert.equal(result[RESULT_DISPATCHED], true);
  assert.deepEqual(args, original);
  assert.equal(f.host.diagnosticPid, pid);
  assert.equal(f.pageLoads(), 1);
  assert.equal(f.tab.document, f.custody.document);
  assert.equal(f.tab.snapshot, f.custody.snapshot);
  assert.deepEqual([...f.tab.refs], f.custody.refs);
  assert.deepEqual([...f.tab.refMetadata], f.custody.metadata);
  assert.equal(await f.tab.refs.get(f.startRef).evaluate(element => element.id), 'retained-source');
  assert.equal(await f.tab.refs.get(f.endRef).evaluate(element => element.id), 'retained-destination');
  return proof;
}

for (const direction of ['down', 'up']) {
  test(`retained handles drag ${direction} across a scrollable distance with a real source press and destination release`, { timeout: 60000 }, async t => {
    const f = await fixture(t, direction);
    assert.deepEqual(await drag(f), {
      presses: [{ source: 'original-source', button: 0, buttons: 1, trusted: true, destinationVisible: false }],
      releases: [{ destination: 'original-destination', button: 0, buttons: 0, trusted: true }],
      transfers: [['original-source', 'original-destination']], starts: [], drops: [], overSeen: false,
      output: 'original-source -> original-destination', source: 'retained-source', destination: 'retained-destination',
      sourceVisible: false, destinationVisible: true, scrolled: direction === 'down',
    });
  });
}

test('retained handles perform an ordinary trusted HTML5 draggable DataTransfer drop', { timeout: 60000 }, async t => {
  const f = await fixture(t, 'html5');
  assert.deepEqual(await drag(f), {
    presses: [], releases: [], transfers: [],
    starts: [{ source: 'original-source', trusted: true }],
    drops: [{ destination: 'original-destination', payload: 'retained payload 雪😀', types: ['text/plain'], trusted: true }],
    overSeen: true, output: 'retained payload 雪😀', source: 'retained-source', destination: 'retained-destination',
    sourceVisible: true, destinationVisible: true, scrolled: false,
  });
});
