import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Screenshot path fixture</title>
<style>html,body{margin:0;background:white}button{position:absolute;left:24px;top:32px;width:96px;height:48px;border:0;padding:0;background:rgb(30,180,70)}</style>
<button id="capture" aria-label="Saved action" onclick="window.clicks=(window.clicks||0)+1"></button>`;

async function fixture(t, { mode, remote = false } = {}) {
  const server = createServer((_req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(html); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-screenshot-path-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'screenshot-path', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory,
    ...(mode === undefined ? {} : { screenshot_result_mode: mode }) };
  if (remote) {
    external = await startExternalBrowser({ executable, directory, initialUrl: url });
    host = new BrowserHost({ ...common, driver: 'remote-cdp', endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: join(directory, 'profile') });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const targetId = remote ? (await call('tabs')).tabs.find(tab => tab.url === url).targetId : (await call('open', { targetUrl: url })).targetId;
  const act = request => call('act', { targetId, request });
  await act({ kind: 'resize', width: 320, height: 180 });
  await act({ kind: 'wait', loadState: 'load' });
  return { host, external, directory, url, targetId, call, act,
    capture: args => call('screenshot', { targetId, ...args }),
    snapshot: args => call('snapshot', { targetId, ...args }),
    evaluate: async fn => (await act({ kind: 'evaluate', fn })).value };
}

function image(result, type = 'png') {
  assert.deepEqual(result.content.map(block => block.type), ['text', 'image']);
  assert.equal(result.content[1].data.media_type, `image/${type}`);
  return Buffer.from(result.content[1].data.data, 'base64');
}

async function artifact(f, result, type, dimensions) {
  assert.deepEqual(result.content.map(block => block.type), ['text']);
  const receipt = JSON.parse(result.content[0].text);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.path, result.path);
  assert.equal(receipt.targetId, f.targetId);
  assert.equal(receipt.url, f.url);
  assert.equal(receipt.type, type);
  assert.equal(receipt.mimeType, `image/${type}`);
  assert.deepEqual(receipt.media, { outbound: false });
  assert.ok(result.path.startsWith(join(f.directory, '.synapsis', 'browser-files') + '/'));
  assert.ok(result.path.endsWith(`.${type}`));
  assert.ok(result.path.length <= 4096);
  assert.ok(receipt.targetId.length <= 256); assert.ok(receipt.url.length <= 2048);
  assert.equal('annotations' in receipt, false);
  assert.equal('annotations' in result, false);
  assert.equal('data' in receipt, false);
  const bytes = await readFile(result.path);
  assert.equal(bytes.length, result.bytes);
  assert.ok(bytes.length > 0 && bytes.length <= 196608);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), receipt.sha256);
  if (type === 'png') assert.equal(bytes.subarray(1, 4).toString(), 'PNG');
  else assert.equal(bytes.readUInt16BE(), 0xffd8);
  const decoded = await f.evaluate(`async () => {const image=new Image();image.src=${JSON.stringify(`data:image/${type};base64,${bytes.toString('base64')}`)};await image.decode();const c=document.createElement('canvas');c.width=image.width;c.height=image.height;const ctx=c.getContext('2d');ctx.drawImage(image,0,0);return {width:c.width,height:c.height,pixel:[...ctx.getImageData(Math.floor(c.width/2),Math.floor(c.height/2),1,1).data]};}`);
  assert.deepEqual([decoded.width, decoded.height], dimensions);
  for (const [i, expected] of [30, 180, 70, 255].entries()) assert.ok(Math.abs(decoded.pixel[i] - expected) <= (type === 'jpeg' ? 8 : 0));
  return bytes;
}

for (const mode of [undefined, 'image']) {
  test(`${mode ?? 'default'} screenshot mode retains image content`, { timeout: 60000 }, async t => {
    const f = await fixture(t, { mode });
    const result = await f.capture({ element: '#capture' });
    assert.equal(image(result).subarray(1, 4).toString(), 'PNG');
    assert.deepEqual(await readFile(result.path), image(result));
    assert.equal(result.sha256, createHash('sha256').update(image(result)).digest('hex'));
    assert.deepEqual(result.media, { outbound: false, mediaUrl: result.path });
    assert.ok(result.path.startsWith(join(f.directory, '.synapsis', 'browser-files') + '/'));
    assert.deepEqual(await readdir(dirname(result.path)), [result.path.split('/').at(-1)]);
  });
}

test('managed path captures publish unique PNG/JPEG files and retain labeled snapshot refs and artifacts', { timeout: 90000 }, async t => {
  const f = await fixture(t, { mode: 'path' });
  const snapshot = await f.snapshot({ labels: true, interactive: true });
  assert.equal(image(snapshot).subarray(1, 4).toString(), 'PNG');
  assert.deepEqual(await readFile(snapshot.path), image(snapshot));
  assert.equal(snapshot.imagePath, snapshot.path); assert.equal(snapshot.imageType, 'png');
  assert.equal(snapshot.sha256, createHash('sha256').update(image(snapshot)).digest('hex'));
  assert.deepEqual(snapshot.media, { outbound: false, mediaUrl: snapshot.path });
  const ref = snapshot.refs.find(item => item.name === 'Saved action').ref;
  const results = [];
  for (const type of ['png', 'jpeg']) {
    const result = await f.capture({ ref, labels: true, type });
    await artifact(f, result, type, [96, 48]);
    assert.equal(result.annotationCount, 1);
    results.push(result);
  }
  const ordinary = await f.capture({ ref, labels: false });
  await artifact(f, ordinary, 'png', [96, 48]);
  assert.equal('annotationCount' in ordinary, false);
  results.push(ordinary);
  assert.equal(new Set(results.map(result => result.path)).size, 3);
  await f.act({ kind: 'click', ref });
  assert.equal(await f.evaluate('() => window.clicks'), 1);
  const artifacts = [snapshot, ...results];
  const saved = await Promise.all(artifacts.map(result => readFile(result.path)));
  const directory = dirname(results[0].path);
  assert.deepEqual((await readdir(directory)).sort(), artifacts.map(result => result.path.split('/').at(-1)).sort());
  const pid = f.host.diagnosticPid;
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  assert.equal((await f.host.close()).cleanup_confirmed, true);
  assert.deepEqual(await Promise.all(artifacts.map(result => readFile(result.path))), saved);
  assert.deepEqual((await readdir(directory)).sort(), artifacts.map(result => result.path.split('/').at(-1)).sort());
});

test('remote CDP publishes a path artifact and disconnects while the external page and artifact survive', { timeout: 60000 }, async t => {
  const f = await fixture(t, { mode: 'path', remote: true });
  const result = await f.capture({ element: '#capture', type: 'jpeg' });
  const saved = await artifact(f, result, 'jpeg', [96, 48]);
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.equal(process.kill(f.external.pid, 0), true);
  assert.equal(await readFile(f.external.markerPath, 'utf8'), 'external-browser-owned-by-fixture');
  const state = await f.external.inspect('() => document.querySelector("#capture").getAttribute("aria-label")');
  assert.equal(state.alive, true);
  assert.equal(state.pages.find(page => page.url === f.url).value, 'Saved action');
  assert.equal((await f.host.close()).cleanup_confirmed, true);
  assert.deepEqual(await readFile(result.path), saved);
  assert.deepEqual(await readdir(dirname(result.path)), [result.path.split('/').at(-1)]);
});
