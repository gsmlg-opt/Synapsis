import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Labels fixture</title>
<style>html,body{margin:0;padding:0;overflow-x:hidden}body{min-height:2200px;background:white}
button{border:0;padding:0;background:rgb(30,180,70)}
#visible{position:absolute;left:40px;top:60px;width:100px;height:40px}
.crop{position:absolute;left:40px;top:1100px;width:120px;height:64px}.crop+.crop{top:1200px;width:60px}
#fractional{position:absolute;left:31.25px;top:1500.25px;width:100.5px;height:50.5px}
iframe{position:absolute;left:180px;top:80px;width:180px;height:100px;border:0}</style>
<button id="visible" aria-label="Visible action" onclick="window.clicks=(window.clicks||0)+1"></button>
<button class="crop" aria-label="First crop"></button><button class="crop" aria-label="Second crop"></button>
<button id="fractional" aria-label="Fractional crop"></button><iframe src="/frame"></iframe>`;

async function fixture(t, { remote = false, many = false } = {}) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/frame') return res.end('<!doctype html><style>body{margin:0}button{width:120px;height:50px;background:white;border:0}</style><button aria-label="Frame action" onclick="window.frameClicks=(window.frameClicks||0)+1"></button>');
    res.end(many ? `<!doctype html><style>body{margin:0}button{display:block;width:140px;height:24px;border:0;background:white}</style>${Array.from({ length: 151 }, (_, i) => `<button aria-label="Item ${i}"></button>`).join('')}`
      : html.replace('<iframe src="/frame"></iframe>', `<iframe src="/frame"></iframe><iframe style="left:380px" src="http://localhost:${server.address().port}/frame"></iframe>`));
  });
  server.listen(0, '0.0.0.0'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-labels-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'labels', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory };
  if (remote) {
    external = await startExternalBrowser({ executable, directory, initialUrl: url });
    host = new BrowserHost({ ...common, driver: 'remote-cdp', endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const targetId = remote ? (await call('tabs')).tabs.find(tab => tab.url === url).targetId : (await call('open', { targetUrl: url })).targetId;
  const act = request => call('act', { targetId, request });
  await act({ kind: 'wait', loadState: 'load' });
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const capture = args => call('screenshot', { targetId, ...args });
  const snapshot = args => call('snapshot', { targetId, ...args });
  return { host, call, act, evaluate, capture, snapshot, targetId, external, url };
}

function metadata(result) {
  assert.deepEqual(result.content.map(block => block.type), ['text', 'image']);
  const value = JSON.parse(result.content[0].text);
  for (const key of ['targetId', 'type', 'bytes', 'labels', 'labelsCount', 'labelsSkipped', 'annotations', 'truncated']) assert.deepEqual(value[key], result[key], key);
  assert.equal(value.labels, true);
  return value;
}

async function pixels(f, result, points = [], { artifact = false, type = result.type } = {}) {
  const image = artifact ? { media_type: `image/${result.type}`, data: (await readFile(result.path)).toString('base64') } : result.content[1].data;
  assert.equal(image.media_type, `image/${artifact ? result.type : type}`);
  return f.evaluate(`async () => {const image=new Image();image.src=${JSON.stringify(`data:${image.media_type};base64,${image.data}`)};await image.decode();const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);return {width:canvas.width,height:canvas.height,pixels:${JSON.stringify(points)}.map(([x,y])=>[...ctx.getImageData(x,y,1,1).data])};}`);
}
const orange = pixel => { assert.equal(pixel[3], 255); for (const [i, n] of [255, 176, 32].entries()) assert.ok(Math.abs(pixel[i] - n) <= 12, `orange channel ${i}: ${pixel[i]}`); };
const annotation = (result, name) => result.annotations.find(item => item.name === name);

test('viewport labels refresh native refs, draw pixels and leave a clean ordinary screenshot', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  const result = await f.capture({ labels: true }); const value = metadata(result);
  const visible = annotation(value, 'Visible action'); assert.ok(visible);
  assert.deepEqual(visible.box, { x: 40, y: 60, width: 100, height: 40 });
  assert.ok(value.labelsCount >= 1); assert.ok(value.labelsSkipped >= 3);
  assert.ok(annotation(value, 'First crop').box.y > 480);
  orange((await pixels(f, result, [[40, 80]])).pixels[0]);
  await f.act({ kind: 'click', ref: visible.ref }); assert.equal(await f.evaluate('() => window.clicks'), 1);
  const ordinary = await f.capture({ labels: false });
  assert.deepEqual((await pixels(f, ordinary, [[40, 80]])).pixels[0], [30, 180, 70, 255]);
  assert.deepEqual(await f.evaluate('() => [...document.querySelectorAll("*")].filter(e=>e.getAttributeNames().some(n=>n.includes("labels"))).map(e=>e.outerHTML)'), []);
  await f.evaluate(`() => {const fragment=document.createDocumentFragment();for(let i=0;i<600;i++){const button=document.createElement('button');button.setAttribute('aria-label','Tail '+i);button.style.cssText='position:absolute;left:0;top:'+(2200+i*20)+'px;width:100px;height:20px';fragment.append(button)}document.body.append(fragment);return true}`);
  const bounded = metadata(await f.capture({ labels: true }));
  assert.equal(bounded.truncated, true); assert.ok(bounded.labelsCount >= 1);
  assert.equal(f.host.tabs.get(f.targetId).snapshotTruncated, true);
});

test('explicit ref wins and retains the exact adopted snapshot across PNG and JPEG labels', { timeout: 60000 }, async t => {
  const f = await fixture(t); const snap = await f.snapshot({ interactive: true });
  const ref = snap.refs.find(item => item.name === 'Visible action').ref;
  const tab = f.host.tabs.get(f.targetId); const epoch = tab.snapshot; const retained = tab.refs.get(ref);
  for (const type of ['png', 'jpeg']) {
    const result = await f.capture({ labels: true, ref, element: '.crop', type }); const value = metadata(result);
    assert.equal(tab.snapshot, epoch); assert.equal(tab.refs.get(ref), retained);
    assert.deepEqual(annotation(value, 'Visible action').box, { x: 0, y: 0, width: 100, height: 40 });
    const image = await pixels(f, result, [[0, 20]]); assert.deepEqual([image.width, image.height], [100, 40]); orange(image.pixels[0]);
  }
  await f.act({ kind: 'click', ref }); assert.equal(await f.evaluate('() => window.clicks'), 1);
});

test('CSS labels use the first match after scrolling and clip annotations to that element', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  const result = await f.capture({ labels: true, element: '.crop' }); const value = metadata(result);
  assert.deepEqual(value.annotations.map(item => item.name), ['First crop']);
  assert.deepEqual(value.annotations[0].box, { x: 0, y: 0, width: 120, height: 64 });
  const image = await pixels(f, result, [[0, 32]]); assert.deepEqual([image.width, image.height], [120, 64]); orange(image.pixels[0]);
  assert.ok(await f.evaluate('() => scrollY') > 0);
});

test('full-page labels draw the first 150 refs and count the normal remaining tail', { timeout: 60000 }, async t => {
  const f = await fixture(t, { many: true }); await f.act({ kind: 'resize', width: 640, height: 480 });
  const page = f.host.tabs.get(f.targetId).page; const screenshot = page.screenshot.bind(page); let raw;
  page.screenshot = async args => { raw = await screenshot(args); return raw; };
  const result = await f.capture({ labels: true, fullPage: true }); const value = metadata(result);
  assert.equal(value.labelsCount, 150); assert.equal(value.labelsSkipped, 1); assert.equal(value.annotations.length, 150);
  assert.equal(value.annotations[0].name, 'Item 0'); assert.equal(value.annotations.at(-1).name, 'Item 149');
  // Keep exact overlay/tail pixels on the real native PNG, and independently
  // verify the saved and model projections of that same full-height capture.
  const rawResult = { type: 'png', content: [null, { data: { media_type: 'image/png', data: raw.toString('base64') } }] };
  const image = await pixels(f, rawResult, [[0, 12], [0, 149 * 24 + 12], [0, 150 * 24 + 12]]);
  assert.ok(image.height >= 151 * 24); orange(image.pixels[0]); orange(image.pixels[1]); assert.deepEqual(image.pixels[2], [255, 255, 255, 255]);
  assert.equal(result.type, 'jpeg');
  const artifact = await pixels(f, result, [], { artifact: true });
  const model = await pixels(f, result);
  assert.equal(artifact.height, 2000); assert.equal(model.height, 1200);
  assert.equal(artifact.width, Math.round(image.width * 2000 / image.height));
  assert.equal(model.width, Math.round(artifact.width * 1200 / artifact.height));
  assert.deepEqual(value.annotations.at(-1).box, { x: 0, y: Math.round(149 * 24 * artifact.height / image.height),
    width: Math.round(140 * artifact.width / image.width), height: Math.round(24 * artifact.height / image.height) });
  for (const [projection, saved] of [[artifact, true], [model, false]]) {
    const points = [12, 149 * 24 + 12, 150 * 24 + 12].map(y => [0, Math.floor(y * projection.height / image.height)]);
    const encoded = await pixels(f, result, points, { artifact: saved });
    // Subpixel borders blend during the two real resizes; their orange hue and
    // the untouched white tail must still survive JPEG projection.
    for (const [red, green, blue, alpha] of encoded.pixels.slice(0, 2)) {
      assert.equal(alpha, 255); assert.ok(red > 200 && green > 120 && green < 235 && blue < 180);
    }
    for (const channel of encoded.pixels[2]) assert.ok(Math.abs(channel - 255) <= 12);
  }
});

test('emulated fractional target labels follow encoded image pixels and preserve the device owner', { timeout: 90000 }, async t => {
  const f = await fixture(t); await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate('() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,scale:visualViewport.scale})');
  const before = await observe(); assert.equal(before.dpr, 3);
  const snap = await f.snapshot({ interactive: true }); const ref = snap.refs.find(item => item.name === 'Fractional crop').ref;
  for (const type of ['png', 'jpeg']) {
    const result = await f.capture({ labels: true, ref, type }); const value = metadata(result); const item = annotation(value, 'Fractional crop');
    assert.deepEqual(item.box, { x: 1, y: 1, width: 302, height: 152 });
    const image = await pixels(f, result, [[2, 60]]); assert.deepEqual([image.width, image.height], [303, 153]); orange(image.pixels[0]);
    assert.deepEqual(await observe(), before);
  }
  await f.evaluate('() => {scrollTo(0,0);return true}');
  const owner = await f.host.tabs.get(f.targetId).emulation.session;
  await owner.send('Emulation.setPageScaleFactor', { pageScaleFactor: 2 });
  const initialZoomView = await owner.send('Page.getLayoutMetrics');
  t.diagnostic(`zoom visual viewport before fixture placement: ${JSON.stringify(initialZoomView.cssVisualViewport)}`);
  // Chromium may preserve a panned visual viewport after an offscreen crop.
  // Put a real control in that viewport, then derive its expected image box
  // independently from its DOM document rect and the native capture clip.
  const documentRect = await f.evaluate(`async () => {const button=document.querySelector('#visible');button.style.left=(visualViewport.pageLeft+40)+'px';button.style.top=(visualViewport.pageTop+40)+'px';await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));const rect=button.getBoundingClientRect();return {x:rect.left+scrollX,y:rect.top+scrollY,width:rect.width,height:rect.height}}`);
  const zoomClip = (await owner.send('Page.getLayoutMetrics')).cssVisualViewport;
  const zoomedBefore = await observe(); assert.equal(zoomedBefore.scale, 2);
  const zoomed = await f.capture({ labels: true }); const zoomedMetadata = metadata(zoomed);
  assert.equal(zoomed.type, 'png');
  const zoomedImage = await pixels(f, zoomed, [], { artifact: true });
  const modelImage = await pixels(f, zoomed, [], { type: 'jpeg' });
  assert.deepEqual([zoomedImage.width, zoomedImage.height], [1170, 1992]);
  assert.deepEqual([modelImage.width, modelImage.height], [705, 1200]);
  const scale = zoomedImage.width / Math.ceil(390 / zoomClip.scale);
  const expected = { x: Math.round((documentRect.x - zoomClip.pageX) * scale), y: Math.round((documentRect.y - zoomClip.pageY) * scale),
    width: Math.round(documentRect.width * scale), height: Math.round(documentRect.height * scale) };
  assert.deepEqual(annotation(zoomedMetadata, 'Visible action').box, expected);
  assert.equal(scale, 6); assert.ok(expected.x >= 0 && expected.y >= 0);
  orange((await pixels(f, zoomed, [[expected.x + 1, expected.y + Math.floor(expected.height / 2)]], { artifact: true })).pixels[0]);
  const modelPoint = [Math.round((expected.x + 4) * modelImage.width / zoomedImage.width),
    Math.round((expected.y + expected.height / 2) * modelImage.height / zoomedImage.height)];
  orange((await pixels(f, zoomed, [modelPoint], { type: 'jpeg' })).pixels[0]);
  assert.deepEqual(await observe(), zoomedBefore);
});

test('AI ARIA iframe refs and raw actionable Element refs annotate their retained identities', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const ai = await f.snapshot({ refs: 'aria' }); const frame = ai.refs.find(item => item.name === 'Frame action'); assert.ok(frame);
  const result = await f.capture({ labels: true, ref: frame.ref }); const value = metadata(result);
  assert.ok(value.annotations.some(item => item.ref === frame.ref && item.name === 'Frame action'));
  orange((await pixels(f, result, [[0, 25]])).pixels[0]);
  await f.act({ kind: 'click', ref: frame.ref });
  assert.equal(await f.host.tabs.get(f.targetId).page.frames().find(frame => frame.url().endsWith('/frame')).evaluate(() => window.frameClicks), 1);
  const frameRefs = ai.refs.filter(item => item.name === 'Frame action'); assert.equal(frameRefs.length, 2);
  const oopRef = frameRefs[1]; const oopCapture = await f.capture({ labels: true, ref: oopRef.ref });
  assert.ok(metadata(oopCapture).annotations.some(item => item.ref === oopRef.ref && item.name === 'Frame action'));
  orange((await pixels(f, oopCapture, [[0, 25]])).pixels[0]);
  await f.act({ kind: 'click', ref: oopRef.ref });
  const oop = f.host.tabs.get(f.targetId).page.frames().find(frame => new URL(frame.url()).hostname === 'localhost');
  assert.equal(await oop.evaluate(() => window.frameClicks), 1);
  const session = await oop.page().context().newCDPSession(oop);
  try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
  finally { await session.detach(); }
  const raw = await f.snapshot({ snapshotFormat: 'aria' }); const ref = raw.refs.find(item => item.name === 'Visible action').ref;
  const rawImage = await f.capture({ labels: true, ref }); const rawMetadata = metadata(rawImage);
  const actionable = new Set(raw.refs.map(item => item.ref)); assert.ok(rawMetadata.annotations.every(item => actionable.has(item.ref)));
  assert.ok(rawMetadata.annotations.some(item => item.ref === ref));
});

test('remote PNG and JPEG labels retain the external browser page and process', { timeout: 60000 }, async t => {
  const f = await fixture(t, { remote: true });
  for (const type of ['png', 'jpeg']) {
    const result = await f.capture({ labels: true, element: '#visible', type }); const value = metadata(result);
    assert.equal(annotation(value, 'Visible action').box.width, 100); orange((await pixels(f, result, [[0, 20]])).pixels[0]);
  }
  assert.equal((await f.call('stop')).cleanup_confirmed, true); assert.equal(process.kill(f.external.pid, 0), true);
  const state = await f.external.inspect('() => document.querySelector("#visible").getAttribute("aria-label")');
  assert.equal(state.pages.find(page => page.url === f.url).value, 'Visible action');
});
