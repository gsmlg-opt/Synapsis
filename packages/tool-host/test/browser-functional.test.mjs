import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BrowserHost, ACTIONS, ACT_KINDS } from '../src/browser/host.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><html><body><h1>Browser fixture</h1>
<form action="/done"><label>Name<input name="name" aria-label="Name"></label><button type="submit">Save</button></form>
<label>Choice<select aria-label="Choice"><option value="a">Alpha</option><option value="b">Beta</option></select></label>
<button id="counter" onclick="this.textContent='Clicked'">Count</button>
<div draggable="true" role="button" aria-label="Drag source" style="width:70px;height:30px">Drag</div>
<div role="button" aria-label="Drop target" style="width:70px;height:30px" ondragover="event.preventDefault()" ondrop="this.textContent='Dropped'">Drop</div>
</body></html>`;

async function fixture() {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html');
    res.end(req.url.startsWith('/done') ? '<html><body><h1>Saved</h1><p>Finished</p></body></html>' : html);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-functional-'));
  const cleanup = async () => {
    try {
      await new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
        server.closeAllConnections();
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  };
  return { url: `http://127.0.0.1:${server.address().port}`, cleanup,
    config: { profile: 'functional', executable, data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 } };
}

async function assertImageArtifact(image, projectRoot, png) {
  // invoke adds its generation envelope after the screenshot text is serialized.
  const { content, generation, ...metadata } = image;
  assert.ok(Number.isInteger(generation));
  assert.deepEqual(JSON.parse(content[0].text), metadata);
  assert.equal(image.type, 'png');
  assert.equal(image.bytes, png.length);
  assert.equal(image.sha256, createHash('sha256').update(png).digest('hex'));
  assert.equal(dirname(image.path), join(projectRoot, '.synapsis', 'browser-files'));
  assert.ok(image.path.endsWith('.png'));
  assert.deepEqual(image.media, { outbound: false, mediaUrl: image.path });
  assert.deepEqual(await readFile(image.path), png);
}

function assertExited(pid) {
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
}

test('managed host retains ordinary browser state and settles owned Chromium', { timeout: 90000 }, async (t) => {
  const f = await fixture();
  const host = new BrowserHost(f.config);
  t.after(async () => {
    try { await host.close(); }
    finally { await f.cleanup(); }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  assert.equal((await call('status')).running, false);
  assert.equal(host.diagnosticPid, null);
  assert.deepEqual((await call('status')).actions, [...ACTIONS]);
  assert.deepEqual((await call('status')).actKinds, [...ACT_KINDS]);
  assert.equal((await call('doctor')).executableAvailable, true);
  assert.equal((await call('profiles')).profiles[0].name, 'functional');
  await call('start');
  const firstPid = host.diagnosticPid;
  assert.ok(firstPid > 0);
  const opened = await call('open', { targetUrl: f.url });
  const targetId = opened.targetId;
  assert.equal((await call('tabs')).tabs.find(tab => tab.targetId === targetId).url, `${f.url}/`);
  await call('focus', { targetId });
  let snapshot = await call('snapshot', { targetId, interactive: true, compact: true, limit: 20, maxChars: 10000 });
  assert.match(snapshot.snapshot, /Name.*\[ref=e\d+\]/);
  assert.equal(snapshot.format, 'ai');
  const ref = name => snapshot.refs.find(item => item.name === name)?.ref;
  assert.ok(ref('Name'));
  const act = request => call('act', { targetId, request });
  await act({ kind: 'fill', fields: [{ ref: ref('Name'), value: 'Ada' }] });
  assert.equal((await act({ kind: 'evaluate', fn: '() => document.querySelector("input").value' })).value, 'Ada');
  await act({ kind: 'type', ref: ref('Name'), text: 'Grace' });
  await act({ kind: 'press', ref: ref('Name'), key: 'End' });
  await act({ kind: 'hover', ref: ref('Name') });
  await act({ kind: 'scrollIntoView', ref: ref('Name') });
  await act({ kind: 'select', ref: ref('Choice'), values: ['b'] });
  assert.equal((await act({ kind: 'evaluate', fn: '() => document.querySelector("select").value' })).value, 'b');
  await act({ kind: 'resize', width: 800, height: 600 });
  await act({ kind: 'wait', text: 'Browser fixture', selector: '#counter', loadState: 'domcontentloaded' });
  await act({ kind: 'drag', startRef: ref('Drag source'), endRef: ref('Drop target') });
  await act({ kind: 'click', ref: ref('Count') });
  assert.equal((await act({ kind: 'evaluate', fn: '() => document.querySelector("#counter").textContent' })).value, 'Clicked');
  const coords = (await act({ kind: 'evaluate', fn: '() => { const r = document.querySelector("#counter").getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; }' })).value;
  await act({ kind: 'clickCoords', ...coords });
  const batch = await act({ kind: 'batch', actions: [{ kind: 'type', ref: ref('Name'), text: 'Lin' }, { kind: 'evaluate', fn: '() => document.querySelector("input").value' }] });
  assert.equal(batch.results.length, 2);
  assert.equal(batch.results[1].value, 'Lin');
  const image = await call('screenshot', { targetId });
  assert.equal(image.content[1].data.media_type, 'image/png');
  const png = Buffer.from(image.content[1].data.data, 'base64');
  assert.equal(png.subarray(1,4).toString(), 'PNG');
  assert.ok(png.length <= f.config.max_image_bytes);
  await assertImageArtifact(image, f.config.project_root, png);
  const previousDocument = snapshot.documentGeneration;
  await act({ kind: 'click', ref: ref('Save') });
  await act({ kind: 'wait', url: '**/done?name=Lin', text: 'Saved' });
  assert.match((await call('tabs')).tabs.find(tab => tab.targetId === targetId).url, /done\?name=Lin/);
  snapshot = await call('snapshot', { targetId });
  assert.match(snapshot.snapshot, /Saved/);
  assert.ok(snapshot.documentGeneration > previousDocument);
  await call('navigate', { targetId, targetUrl: f.url });
  assert.equal((await call('snapshot', { targetId, depth: 0 })).snapshot.includes('Browser fixture'), true);
  const extra = await call('open', { targetUrl: f.url });
  await call('act', { targetId: extra.targetId, request: { kind: 'close' } });
  const stopped = await call('stop');
  assert.equal(stopped.cleanup_confirmed, true);
  assertExited(firstPid);
  await call('start');
  const secondPid = host.diagnosticPid;
  const second = await call('open', { targetUrl: f.url });
  await call('close', { targetId: second.targetId });
  const closed = await host.close();
  assert.equal(closed.cleanup_confirmed, true);
  assertExited(secondPid);
  assert.deepEqual(await readFile(image.path), png);
});

test('stdio initialize is dormant and close flushes then exits after Chromium', { timeout: 60000 }, async (t) => {
  const f = await fixture();
  const processHost = spawn(process.execPath, [fileURLToPath(new URL('../src/browser/stdio.mjs', import.meta.url))], { stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = once(processHost, 'exit');
  let output = '';
  const requests = new Map();
  let sequence = 0;
  let stderr = '';
  processHost.stderr.on('data', chunk => { stderr += chunk; });
  processHost.stdout.on('data', chunk => {
    output += chunk.toString();
    while (output.includes('\n')) {
      const index = output.indexOf('\n');
      const frame = JSON.parse(output.slice(0, index));
      output = output.slice(index + 1);
      requests.get(frame.id)?.(frame);
      requests.delete(frame.id);
    }
  });
  const rpc = (method, params, fixedId) => {
    const id = fixedId ?? `r${++sequence}`;
    const promise = new Promise(resolve => requests.set(id, resolve));
    processHost.stdin.write(`${JSON.stringify({ version: 1, id, method, params })}\n`);
    return promise;
  };
  let generation = 0;
  const call = async (action, args = {}) => {
    const frame = await rpc('call', { generation, action, args, timeout_ms: 15000 });
    assert.equal(frame.error, undefined, JSON.stringify(frame.error));
    generation = frame.result.generation;
    return frame.result;
  };
  t.after(async () => {
    try {
      if (processHost.exitCode === null && processHost.signalCode === null) { processHost.stdin.end(); await exited; }
    } finally {
      await f.cleanup();
    }
  });
  const initialized = await rpc('initialize', f.config);
  assert.equal(initialized.result.running, false);
  await call('start');
  const tab = await call('open', { targetUrl: f.url });
  assert.match((await call('snapshot', { targetId: tab.targetId })).snapshot, /Browser fixture/);
  const image = await call('screenshot', { targetId: tab.targetId });
  assert.equal(image.content[1].type, 'image');
  assert.equal(image.content[1].data.media_type, 'image/png');
  const png = Buffer.from(image.content[1].data.data, 'base64');
  assert.equal(png.subarray(1,4).toString(), 'PNG');
  assert.ok(png.length <= f.config.max_image_bytes);
  await assertImageArtifact(image, f.config.project_root, png);
  const waiting = rpc('call', { generation, action: 'act', args: { targetId: tab.targetId, request: { kind: 'wait', timeMs: 10000 } }, timeout_ms: 15000 }, 'ordinary-wait');
  const observed = await rpc('call', { generation, action: 'status', args: {}, timeout_ms: 15000 });
  assert.equal(observed.result.running, true);
  const cancelled = await rpc('cancel', { id: 'ordinary-wait' });
  assert.equal(cancelled.result.cleanup_confirmed, true);
  assert.equal((await waiting).error.class, 'cancelled');
  generation = cancelled.result.generation;
  await call('start');
  await call('open', { targetUrl: f.url });
  const closed = await rpc('close', {});
  assert.equal(closed.result.cleanup_confirmed, true);
  assert.equal((await exited)[0], 0);
  assert.equal(stderr, '');
  assert.deepEqual(await readFile(image.path), png);
});


test('ordinary action timeout settles owned browser before reopening', { timeout: 60000 }, async (t) => {
  const f = await fixture();
  const host = new BrowserHost(f.config);
  t.after(async () => {
    try { await host.close(); }
    finally { await f.cleanup(); }
  });
  const call = (action, args = {}, timeoutMs = 15000) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  await call('start');
  const pid = host.diagnosticPid;
  const tab = await call('open', { targetUrl: f.url });
  await assert.rejects(call('act', { targetId: tab.targetId, request: { kind: 'wait', timeMs: 10000 } }, 100), error => {
    assert.equal(error.class, 'timeout');
    assert.equal(error.cleanup.cleanup_confirmed, true);
    return true;
  });
  assertExited(pid);
  assert.equal((await call('status')).running, false);
  await call('start');
  const reopened = await call('open', { targetUrl: f.url });
  assert.match((await call('snapshot', { targetId: reopened.targetId })).snapshot, /Browser fixture/);
  assert.equal((await host.close()).cleanup_confirmed, true);
});
