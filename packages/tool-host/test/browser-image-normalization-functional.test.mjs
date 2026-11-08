import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { channel } from 'node:diagnostics_channel';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { normalizeScreenshot, scaleScreenshotAnnotations } from '../src/browser/screenshot-normalization.mjs';
import { screenshotDimensions } from '../src/browser/screenshot-labels.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';
import { makeReferencePng } from '../../../scripts/openclaw/capture-browser-images.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Normalized capture</title>
<style>html,body{margin:0;background:white}button{position:absolute;left:25.25px;top:36.25px;width:101.5px;height:41.5px;border:0;padding:0;background:rgb(30,180,70)}</style>
<button id="capture" aria-label="Normalized action" onclick="window.clicks=(window.clicks||0)+1"></button>`;

async function fixture(t, { remote = false, mode = 'image' } = {}) {
  const server = createServer((_req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(html); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-normalized-image-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'image-normalization', timeout_ms: 15000, max_image_bytes: 196608,
    project_root: directory, screenshot_result_mode: mode };
  if (remote) {
    external = await startExternalBrowser({ executable, directory, initialUrl: url });
    host = new BrowserHost({ ...common, driver: 'remote-cdp', endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: join(directory, 'profile') });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const targetId = remote ? (await call('tabs')).tabs.find(tab => tab.url === url).targetId : (await call('open', { targetUrl: url })).targetId;
  const act = request => call('act', { targetId, request });
  await act({ kind: 'wait', loadState: 'load' });
  const tab = host.tabs.get(targetId);
  const captures = [];
  const workers = [];
  const workerChannel = channel('worker_threads');
  const observeWorker = ({ worker }) => {
    const state = { worker, exited: false, code: undefined, ticks: 0 }; workers.push(state);
    let timer;
    worker.once('online', () => { timer = setInterval(() => { state.ticks++; }, 1); });
    worker.once('exit', code => { clearInterval(timer); state.exited = true; state.code = code; });
  };
  workerChannel.subscribe(observeWorker);
  t.after(() => workerChannel.unsubscribe(observeWorker));
  const original = tab.page.screenshot.bind(tab.page);
  tab.page.screenshot = async args => {
    assert.equal(host.fileOwners.size, 1); assert.equal(host.fileTasks.size, 1);
    const buffer = await original(args); captures.push({ args, buffer }); return buffer;
  };
  return { host, tab, directory, external, captures, workers, targetId, call, act,
    resize: (width, height) => act({ kind: 'resize', width, height }),
    screenshot: args => call('screenshot', { targetId, ...args }),
    snapshot: args => call('snapshot', { targetId, interactive: true, ...args }) };
}

const dimensions = (buffer, type) => screenshotDimensions(buffer, type);
const inline = result => Buffer.from(result.content[1].data.data, 'base64');
const sha256 = buffer => createHash('sha256').update(buffer).digest('hex');

function joinedWorkers(f, count) {
  assert.equal(f.workers.length, count);
  for (const state of f.workers) {
    assert.equal(state.exited, true); assert.equal(state.code, 0); assert.equal(state.worker.threadId, -1);
    assert.ok(state.ticks > 0, 'the host event loop stays responsive during image computation');
  }
}

async function saved(result) {
  const buffer = await readFile(result.path);
  assert.equal(result.bytes, buffer.length); assert.equal(result.sha256, sha256(buffer));
  assert.ok(buffer.length <= 196608); assert.ok(buffer.toString('base64').length <= 262144);
  assert.ok(result.path.endsWith(`.${result.type}`));
  assert.deepEqual(result.media, { outbound: false, mediaUrl: result.path });
  assert.equal((await readdir(dirname(result.path))).some(name => name.startsWith('.browser-stage-')), false);
  const { content, ...metadata } = result;
  for (const [key, value] of Object.entries(JSON.parse(content[0].text))) assert.deepEqual(metadata[key], value);
  assert.equal(JSON.stringify(metadata).includes('base64'), false);
  assert.equal(Object.values(metadata).some(value => Buffer.isBuffer(value)), false);
  return buffer;
}

function annotationBox(result, source, output) {
  const box = result.annotations.find(item => item.name === 'Normalized action').box;
  assert.deepEqual(box, { x: Math.round(25 * output.width / source.width), y: Math.round(36 * output.height / source.height),
    width: Math.max(1, Math.round(102 * output.width / source.width)), height: Math.max(1, Math.round(42 * output.height / source.height)) });
}

for (const remote of [false, true]) {
  test(`${remote ? 'remote' : 'managed'} saves 2000px screenshots and independently sanitizes inline images to 1200px`, { timeout: 90000 }, async t => {
    const f = await fixture(t, { remote });
    await f.resize(2400, 1600);
    const result = await f.screenshot({ labels: true });
    const artifact = await saved(result);
    assert.equal(result.type, 'jpeg');
    assert.deepEqual(dimensions(artifact, 'jpeg'), { width: 2000, height: 1333 });
    assert.equal(result.content[1].data.media_type, 'image/jpeg');
    assert.deepEqual(dimensions(inline(result), 'jpeg'), { width: 1200, height: 800 });
    assert.notEqual(sha256(inline(result)), result.sha256);
    joinedWorkers(f, 2);
    assert.deepEqual(dimensions(f.captures.at(-1).buffer, 'png'), { width: 2400, height: 1600 });
    annotationBox(result, { width: 2400, height: 1600 }, dimensions(artifact, 'jpeg'));
    const ref = result.annotations[0].ref;
    assert.equal(await f.tab.refs.get(ref).evaluate(element => element.id), 'capture');
    assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
    if (remote) await f.tab.page.bringToFront();
    await f.act({ kind: 'click', ref });
    assert.equal(await f.tab.page.evaluate(() => window.clicks), 1);
    assert.equal(f.host.fileOwners.size, 0); assert.equal(f.host.fileTasks.size, 0);
    assert.equal((await f.call('stop')).cleanup_confirmed, true);
    assert.deepEqual(await readFile(result.path), artifact);
    if (remote) assert.equal(process.kill(f.external.pid, 0), true);
  });

  test(`${remote ? 'remote' : 'managed'} preserves 1600px PNG artifact metadata while inline MIME and pixels become JPEG`, { timeout: 90000 }, async t => {
    const f = await fixture(t, { remote }); await f.resize(1600, 1000);
    const result = await f.screenshot({ labels: true }); const artifact = await saved(result);
    assert.equal(result.type, 'png'); assert.deepEqual(artifact, f.captures.at(-1).buffer);
    assert.deepEqual(dimensions(artifact, 'png'), { width: 1600, height: 1000 });
    assert.equal(result.content[1].data.media_type, 'image/jpeg');
    assert.deepEqual(dimensions(inline(result), 'jpeg'), { width: 1200, height: 750 });
    joinedWorkers(f, 1);
    annotationBox(result, { width: 1600, height: 1000 }, dimensions(artifact, 'png'));
  });
}

test('trusted path mode skips inline sanitization while combined role/ARIA labels always retain inline images', { timeout: 90000 }, async t => {
  const f = await fixture(t, { mode: 'path' }); await f.resize(1600, 1000);
  const result = await f.screenshot({ labels: true });
  assert.deepEqual(result.content.map(block => block.type), ['text']);
  assert.equal(result.type, 'png'); assert.equal(result.mimeType, 'image/png');
  assert.deepEqual(await readFile(result.path), f.captures.at(-1).buffer);
  assert.equal(result.annotationCount, 1); assert.equal(result.annotations, undefined);
  joinedWorkers(f, 0);
  for (const refs of ['role', 'aria']) {
    const baseline = await f.snapshot({ refs }); const combined = await f.snapshot({ refs, labels: true });
    const artifact = await saved(combined);
    assert.equal(combined.imagePath, combined.path); assert.equal(combined.imageType, 'png');
    assert.equal(combined.type, 'png'); assert.deepEqual(artifact, f.captures.at(-1).buffer);
    assert.equal(combined.content[1].data.media_type, 'image/jpeg');
    assert.deepEqual(dimensions(inline(combined), 'jpeg'), { width: 1200, height: 750 });
    assert.equal(combined.newElements, 0);
    assert.equal(combined.snapshot.replace(/\[ref=e\d+\]/g, '[ref=e]'), baseline.snapshot.replace(/\[ref=e\d+\]/g, '[ref=e]'));
    assert.deepEqual(combined.annotations.map(item => item.ref), combined.refs.map(item => item.ref));
    annotationBox(combined, { width: 1600, height: 1000 }, dimensions(artifact, 'png'));
    joinedWorkers(f, refs === 'role' ? 1 : 2);
    assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
  }
});

test('ordinary JPEG capture uses Playwright default quality and device-owner capture uses CDP quality85', { timeout: 90000 }, async t => {
  const f = await fixture(t); await f.resize(320, 180);
  const ordinary = await f.screenshot({ type: 'jpeg' });
  assert.equal(f.captures.at(-1).args.quality, undefined);
  assert.deepEqual(await saved(ordinary), f.captures.at(-1).buffer);
  assert.deepEqual(inline(ordinary), f.captures.at(-1).buffer);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const state = () => f.tab.page.evaluate(() => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio, touch: navigator.maxTouchPoints }));
  const before = await state();
  const session = await f.tab.emulation.session;
  const original = session.send.bind(session); let quality; let capture;
  session.send = async (method, args) => {
    const result = await original(method, args);
    if (method === 'Page.captureScreenshot') { quality = args.quality; capture = Buffer.from(result.data, 'base64'); }
    return result;
  };
  const result = await f.screenshot({ type: 'jpeg', labels: true });
  assert.equal(quality, 85);
  assert.deepEqual(dimensions(await saved(result), 'jpeg'), { width: 1170, height: 1992 });
  assert.deepEqual(await readFile(result.path), capture);
  assert.deepEqual(dimensions(inline(result), 'jpeg'), { width: 705, height: 1200 });
  assert.deepEqual(dimensions(capture, 'jpeg'), { width: 1170, height: 1992 });
  assert.deepEqual(await state(), before);
  assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
});

test('path and combined captures above2000px retain JPEG artifact identity and scale finalized annotations once', { timeout: 90000 }, async t => {
  const f = await fixture(t, { mode: 'path' }); await f.resize(2400, 1600);
  const path = await f.screenshot({ labels: true });
  assert.deepEqual(path.content.map(block => block.type), ['text']);
  assert.equal(path.type, 'jpeg'); assert.equal(path.mimeType, 'image/jpeg');
  const artifact = await readFile(path.path);
  assert.deepEqual(dimensions(artifact, 'jpeg'), { width: 2000, height: 1333 });
  assert.equal(path.bytes, artifact.length); assert.equal(path.sha256, sha256(artifact));
  assert.equal(path.annotationCount, 1); joinedWorkers(f, 1);
  for (const refs of ['role', 'aria']) {
    await f.snapshot({ refs });
    const record = f.host.snapshotDelta.record.bind(f.host.snapshotDelta);
    let adoptions = 0;
    f.host.snapshotDelta.record = (...args) => {
      // Normalization and its owned threads settle before staged refs/delta adoption.
      joinedWorkers(f, refs === 'role' ? 3 : 5); adoptions++;
      return record(...args);
    };
    let result;
    try { result = await f.snapshot({ refs, labels: true }); }
    finally { f.host.snapshotDelta.record = record; }
    assert.equal(adoptions, 1);
    const bytes = await saved(result);
    assert.equal(result.type, 'jpeg'); assert.equal(result.imageType, 'jpeg'); assert.equal(result.imagePath, result.path);
    assert.deepEqual(dimensions(bytes, 'jpeg'), { width: 2000, height: 1333 });
    assert.deepEqual(dimensions(inline(result), 'jpeg'), { width: 1200, height: 800 });
    assert.notEqual(result.sha256, sha256(inline(result)));
    annotationBox(result, { width: 2400, height: 1600 }, dimensions(bytes, 'jpeg'));
    assert.deepEqual(result.annotations.map(item => item.ref), result.refs.map(item => item.ref));
    assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
  }
});

const reference = JSON.parse(await readFile(new URL('./fixtures/browser-image-normalization.json', import.meta.url), 'utf8'));
const facts = (buffer, type) => ({ bytes: buffer.length, sha256: sha256(buffer), mimeType: `image/${type}`, dimensions: dimensions(buffer, type) });
for (const vector of reference.vectors) {
  test(`frozen OpenClaw ${vector.name} matches saved/inline bytes, dimensions, MIME and annotations`, async () => {
    const source = makeReferencePng(vector.recipe);
    assert.deepEqual(facts(source, 'png'), vector.expected.input);
    const beforeAnnotations = structuredClone(vector.inputAnnotations);
    const artifact = await normalizeScreenshot(source, 'png');
    assert.deepEqual(facts(artifact.buffer, artifact.type), vector.expected.saved);
    const annotations = scaleScreenshotAnnotations(vector.inputAnnotations, artifact.sourceDimensions, artifact.dimensions);
    assert.deepEqual(annotations, vector.expected.annotations);
    const image = await normalizeScreenshot(artifact.buffer, artifact.type, { maxSide: 1200 });
    assert.deepEqual(facts(image.buffer, image.type), vector.expected.inline);
    assert.deepEqual(annotations, vector.expected.annotations);
    assert.deepEqual(vector.inputAnnotations, beforeAnnotations);
    assert.deepEqual(facts(artifact.buffer, artifact.type), vector.expected.saved);
    if (vector.expected.saved.sha256 === vector.expected.input.sha256) assert.equal(artifact.buffer, source);
    if (vector.expected.inline.sha256 === vector.expected.saved.sha256) assert.equal(image.buffer, artifact.buffer);
  });
}
