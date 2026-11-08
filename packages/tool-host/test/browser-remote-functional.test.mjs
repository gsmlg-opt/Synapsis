import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { BrowserHost, ACTIONS } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = '/run/current-system/sw/bin/chromium';
const html = '<!doctype html><html><head><title>External Browser fixture</title></head><body><h1>External Browser fixture</h1><p id="marker">External initial</p><input aria-label="Remote upload" type="file" onchange="window.uploadedName=this.files[0].name"></body></html>';

async function fixture(t) {
  const server = createServer((_request, response) => { response.setHeader('Content-Type', 'text/html'); response.end(html); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-remote-'));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const external = await startExternalBrowser({ executable, directory, initialUrl: url });
  t.after(async () => {
    try { await external.close(); }
    finally {
      server.closeAllConnections();
      await new Promise(resolveClose => server.close(resolveClose));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  return { external, directory, url, config: { driver: 'remote-cdp', endpoint: external.endpoint, profile: 'remote', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory } };
}

async function assertExternal(f, expected) {
  assert.equal(process.kill(f.external.pid, 0), true);
  assert.equal(await readFile(f.external.markerPath, 'utf8'), 'external-browser-owned-by-fixture');
  const result = await f.external.inspect('() => ({marker:document.querySelector("#marker")?.textContent, count:window.remoteCount ?? 0, uploadedName:window.uploadedName ?? null})');
  assert.equal(result.alive, true);
  assert.deepEqual(result.pages.find(page => page.url === f.url)?.value, expected);
}

test('remote CDP retains external page, profile and process across stop, reconnect, cancel and close', { timeout: 90000 }, async t => {
  const f = await fixture(t);
  // HTTP discovery and direct WS attachment are both supported public paths.
  const host = new BrowserHost({ ...f.config, endpoint: `http://${new URL(f.external.endpoint).host}` });
  t.after(() => host.close());
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  const dormant = await call('status');
  assert.equal(dormant.driver, 'remote-cdp');
  assert.equal(dormant.running, false);
  assert.equal(host.diagnosticPid, null);
  assert.deepEqual(dormant.actions, ACTIONS.filter(action => !['download', 'waitfordownload'].includes(action)));
  assert.equal((await call('doctor')).endpointConfigured, true);
  assert.equal((await call('profiles')).profiles[0].driver, 'remote-cdp');
  assert.equal((await call('start')).running, true);
  const targetId = (await call('tabs')).tabs.find(tab => tab.url === f.url).targetId;
  const mutate = '() => { window.remoteCount = (window.remoteCount || 0) + 1; document.querySelector("#marker").textContent="Remote retained"; return window.remoteCount; }';
  assert.equal((await call('act', { targetId, request: { kind: 'evaluate', fn: mutate } })).value, 1);
  const snapshot = await call('snapshot', { targetId });
  assert.match(snapshot.snapshot, /Remote retained/);
  const image = await call('screenshot', { targetId });
  assert.equal(Buffer.from(image.content[1].data.data, 'base64').subarray(1, 4).toString(), 'PNG');
  const pdf = await call('pdf', { targetId, path: join(f.directory, 'external.pdf') });
  assert.equal((await readFile(pdf.path)).subarray(0, 5).toString(), '%PDF-');
  const uploadPath = join(f.directory, 'remote-upload.txt');
  await writeFile(uploadPath, 'ordinary remote upload');
  const uploadRef = snapshot.refs.find(ref => ref.name === 'Remote upload').ref;
  await call('upload', { targetId, inputRef: uploadRef, paths: [uploadPath] });
  assert.equal((await f.external.inspect('async () => document.querySelector("input").files[0].text()')).pages.find(page => page.url === f.url).value, 'ordinary remote upload');
  const expected = { marker: 'Remote retained', count: 1, uploadedName: 'remote-upload.txt' };
  assert.equal((await call('stop')).cleanup_confirmed, true);
  assert.equal((await call('status')).running, false);
  await assertExternal(f, expected);
  assert.equal((await call('start')).running, true);
  assert.match((await call('snapshot', { targetId: (await call('tabs')).tabs.find(tab => tab.url === f.url).targetId })).snapshot, /Remote retained/);
  assert.equal((await host.cancel()).cleanup_confirmed, true);
  await assertExternal(f, expected);
  assert.equal((await call('start')).running, true);
  assert.equal((await host.close()).cleanup_confirmed, true);
  await assertExternal(f, expected);
});

test('remote cancellation settles its client wait while external JavaScript can finish later', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const host = new BrowserHost(f.config);
  t.after(() => host.close());
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const targetId = (await call('tabs')).tabs.find(tab => tab.url === f.url).targetId;
  const pending = call('act', { targetId, request: { kind: 'evaluate', fn: 'async () => { window.cancelEntered=true; await new Promise(resolve => { window.releaseRemoteWait=resolve; }); window.afterCancel=(window.afterCancel || 0)+1; return window.afterCancel; }' } }).then(value => ({ value }), error => ({ error }));
  const deadline = Date.now() + 10000;
  let entered;
  while (!entered) {
    entered = (await f.external.inspect('() => window.cancelEntered === true')).pages.find(page => page.url === f.url)?.value;
    assert.ok(Date.now() < deadline, 'external page did not enter ordinary pending work');
    if (!entered) await delay(10);
  }
  const cancelled = await host.cancel();
  assert.equal(cancelled.cancelled, true);
  assert.equal(cancelled.cleanup_confirmed, true);
  assert.equal(cancelled.cleanupScope, 'connection');
  assert.equal((await pending).error.class, 'cancelled');
  await assertExternal(f, { marker: 'External initial', count: 0, uploadedName: null });
  await f.external.inspect('() => { window.releaseRemoteWait(); return true; }');
  let finished;
  while (!finished) {
    finished = (await f.external.inspect('() => window.afterCancel === 1')).pages.find(page => page.url === f.url)?.value;
    assert.ok(Date.now() < deadline, 'external JavaScript did not settle after fixture release');
    if (!finished) await delay(10);
  }
  assert.equal((await host.close()).cleanup_confirmed, true);
  await assertExternal(f, { marker: 'External initial', count: 0, uploadedName: null });
});
