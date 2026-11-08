import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { screenshotDimensions } from '../src/browser/screenshot-labels.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Target capture fixture</title><style>
    html,body { margin:0; padding:0; overflow-x:hidden; } body { min-height:2600px; background:white; }
    button { border:0; padding:0; }
    #retained { position:absolute; left:24px; top:32px; width:96px; height:48px;
      background:linear-gradient(to right,rgb(220,30,40) 50%,rgb(20,80,210) 50%); }
    .crop { position:absolute; left:40px; top:1100px; width:120px; height:64px; background:rgb(30,180,70); }
    .crop + .crop { top:1200px; width:60px; background:rgb(230,150,20); }
    #fractional { position:absolute; left:31.25px; top:1500.25px; width:100.5px; height:50.5px; background:rgb(140,40,190); }
    #oversized { position:absolute; left:0; top:1700px; width:440px; height:760px; background:rgb(20,150,170); }
  </style><button id="retained" aria-label="Retained crop" onclick="window.cropClicks=(window.cropClicks||0)+1"></button>
  <div class="crop"></div><div class="crop"></div><div id="fractional"></div><div id="oversized"></div>`;

async function fixture(t, remote = false) {
  const server = createServer((_req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(html); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-target-capture-'));
  let host;
  let external;
  t.after(async () => {
    try {
      if (host) {
        const pid = host.diagnosticPid;
        assert.equal((await host.close()).cleanup_confirmed, true);
        if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
      }
    } finally {
      try { if (external) { await external.close(); assert.throws(() => process.kill(external.pid, 0), { code: 'ESRCH' }); } }
      finally {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
        await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
      }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'target-capture', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory };
  if (remote) {
    external = await startExternalBrowser({ executable, directory, initialUrl: url });
    host = new BrowserHost({ ...common, driver: 'remote-cdp', endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const targetId = remote ? (await call('tabs')).tabs.find(tab => tab.url === url).targetId : (await call('open', { targetUrl: url })).targetId;
  const act = request => call('act', { targetId, request });
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const capture = args => call('screenshot', { targetId, ...args });
  return { host, call, act, evaluate, capture, targetId, external, url };
}

async function decode(f, result, type = 'png', inlineType = type) {
  assert.equal(result.type, type);
  assert.deepEqual(result.content.map(block => block.type), ['text', 'image']);
  const metadata = JSON.parse(result.content[0].text);
  assert.equal(metadata.targetId, f.targetId);
  assert.equal(metadata.type, type);
  assert.equal(metadata.bytes, result.bytes);
  const image = result.content[1].data;
  assert.equal(image.source, 'base64');
  assert.equal(image.media_type, `image/${inlineType}`);
  const artifact = await readFile(result.path);
  assert.equal(artifact.length, result.bytes);
  assert.equal(createHash('sha256').update(artifact).digest('hex'), result.sha256);
  const savedDimensions = screenshotDimensions(artifact, type);
  if (type === 'png') assert.equal(artifact.subarray(1, 4).toString(), 'PNG');
  else assert.equal(artifact.readUInt16BE(), 0xffd8);
  const bytes = Buffer.from(image.data, 'base64');
  if (savedDimensions.width <= 1200 && savedDimensions.height <= 1200) assert.deepEqual(bytes, artifact);
  if (inlineType === 'png') assert.equal(bytes.subarray(1, 4).toString(), 'PNG');
  else assert.equal(bytes.readUInt16BE(), 0xffd8);
  return decodePixels(f, bytes, inlineType);
}

async function decodePixels(f, bytes, type) {
  return f.evaluate(`async () => {
    const image = new Image(); image.src = ${JSON.stringify(`data:image/${type};base64,${bytes.toString('base64')}`)};
    await image.decode(); const canvas = document.createElement('canvas');
    canvas.width=image.naturalWidth; canvas.height=image.naturalHeight;
    const context=canvas.getContext('2d'); context.drawImage(image,0,0);
    const pixel=(x,y)=>[...context.getImageData(Math.floor(x),Math.floor(y),1,1).data];
    return { width:canvas.width,height:canvas.height,left:pixel(canvas.width/4,canvas.height/2),right:pixel(canvas.width*3/4,canvas.height/2) };
  }`);
}

function pixels(actual, left, right = left, tolerance = 0) {
  for (const [name, expected] of [['left', left], ['right', right]]) {
    assert.equal(actual[name][3], 255);
    expected.forEach((value, index) => assert.ok(Math.abs(actual[name][index] - value) <= tolerance,
      `${name} channel ${index}: ${actual[name][index]} expected ${value}`));
  }
}

test('managed ref captures PNG and JPEG target pixels and remains usable after capture', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.act({ kind: 'resize', width: 640, height: 480 });
  const snapshot = await f.call('snapshot', { targetId: f.targetId, interactive: true });
  const ref = snapshot.refs.find(item => item.name === 'Retained crop').ref;
  const png = await decode(f, await f.capture({ ref }));
  assert.deepEqual([png.width, png.height], [96, 48]);
  pixels(png, [220, 30, 40], [20, 80, 210]);
  const jpeg = await decode(f, await f.capture({ ref, element: '.crop', type: 'jpeg', labels: false }), 'jpeg');
  assert.deepEqual([jpeg.width, jpeg.height], [96, 48]);
  pixels(jpeg, [220, 30, 40], [20, 80, 210], 8);
  await f.act({ kind: 'click', ref });
  assert.equal(await f.evaluate('() => window.cropClicks'), 1);
});

test('CSS element captures the first offscreen match after scrolling', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  await f.act({ kind: 'resize', width: 640, height: 480 });
  const image = await decode(f, await f.capture({ element: '.crop', labels: false }));
  assert.deepEqual([image.width, image.height], [120, 64]);
  pixels(image, [30, 180, 70]);
  assert.ok(await f.evaluate('() => scrollY') > 0);
  // A later selector capture owns a fresh temporary handle, independently of the first.
  const second = await decode(f, await f.capture({ element: '.crop + .crop' }));
  assert.deepEqual([second.width, second.height], [60, 64]);
  pixels(second, [230, 150, 20]);
});

test('device owner captures fractional and oversized targets while retaining emulation metrics', { timeout: 90000 }, async t => {
  const f = await fixture(t);
  await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate(`() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
    screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,coarse:matchMedia('(pointer:coarse)').matches,ua:navigator.userAgent})`);
  const before = await observe();
  assert.equal(before.dpr, 3);
  assert.deepEqual(before.screen, [390, 844]);
  assert.ok(before.touch > 0);
  assert.equal(before.coarse, true);
  const owner = await f.host.tabs.get(f.targetId).emulation.session;
  const send = owner.send.bind(owner); let captured;
  owner.send = async (method, args) => {
    const result = await send(method, args);
    if (method === 'Page.captureScreenshot') captured = Buffer.from(result.data, 'base64');
    return result;
  };
  const snapshot = await f.call('snapshot', { targetId: f.targetId, interactive: true });
  const ref = snapshot.refs.find(item => item.name === 'Retained crop').ref;
  const reference = await decode(f, await f.capture({ ref }));
  assert.deepEqual([reference.width, reference.height], [288, 144]);
  pixels(reference, [220, 30, 40], [20, 80, 210]);
  assert.deepEqual(await observe(), before);
  for (const type of ['png', 'jpeg']) {
    const fractional = await decode(f, await f.capture({ element: '#fractional', type }), type);
    assert.deepEqual([fractional.width, fractional.height], [303, 153]);
    pixels(fractional, [140, 40, 190], undefined, type === 'jpeg' ? 8 : 0);
    assert.ok(await f.evaluate('() => scrollY') > 0);
    assert.deepEqual(await observe(), before);
    const largeResult = await f.capture({ element: '#oversized', type });
    const large = await decode(f, largeResult, 'jpeg');
    assert.deepEqual(screenshotDimensions(captured, type), { width: 1320, height: 2280 });
    pixels(await decodePixels(f, captured, type), [20, 150, 170], undefined, type === 'jpeg' ? 8 : 0);
    assert.deepEqual(screenshotDimensions(await readFile(largeResult.path), 'jpeg'), { width: 1158, height: 2000 });
    assert.deepEqual([large.width, large.height], [695, 1200]);
    pixels(large, [20, 150, 170], undefined, 8);
    assert.deepEqual(await observe(), before);
    const fullPageResult = await f.capture({ fullPage: true, type });
    const fullPage = await decode(f, fullPageResult, 'jpeg');
    assert.ok(screenshotDimensions(captured, type).height >= 7800);
    assert.equal(screenshotDimensions(await readFile(fullPageResult.path), 'jpeg').height, 2000);
    assert.equal(fullPage.height, 1200);
    assert.deepEqual(await observe(), before);
  }
  const viewportResult = await f.capture({});
  const viewport = await decode(f, viewportResult, 'png', 'jpeg');
  assert.deepEqual(screenshotDimensions(captured, 'png'), { width: 1170, height: 1992 });
  assert.deepEqual(await readFile(viewportResult.path), captured);
  assert.deepEqual([viewport.width, viewport.height], [705, 1200]);
  assert.deepEqual(await observe(), before);
  await f.act({ kind: 'click', ref });
  assert.equal(await f.evaluate('() => window.cropClicks'), 1);
  assert.deepEqual(await observe(), before);
  t.diagnostic(`device state retained across target, full-page and viewport captures: ${JSON.stringify(before)}`);
});

test('remote CDP target capture leaves external process, profile and page available after stop', { timeout: 60000 }, async t => {
  const f = await fixture(t, true);
  const image = await decode(f, await f.capture({ element: '#retained' }));
  assert.deepEqual([image.width, image.height], [96, 48]);
  pixels(image, [220, 30, 40], [20, 80, 210]);
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.equal(process.kill(f.external.pid, 0), true);
  assert.equal(await readFile(f.external.markerPath, 'utf8'), 'external-browser-owned-by-fixture');
  const state = await f.external.inspect('() => document.querySelector("#retained").getAttribute("aria-label")');
  assert.equal(state.alive, true);
  assert.equal(state.pages.find(page => page.url === f.url).value, 'Retained crop');
});
