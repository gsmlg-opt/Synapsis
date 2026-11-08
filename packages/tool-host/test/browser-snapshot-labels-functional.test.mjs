import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';

async function fixture(t, { remote = false } = {}) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/frame') return res.end(`<!doctype html><style>body{margin:0;background:white}button{position:absolute;left:10px;top:20px;width:120px;height:40px;border:0;background:rgb(30,180,70)}</style>
      <section id="frame-scope"><button aria-label="Frame action" onclick="window.clicks=(window.clicks||0)+1"></button></section><a style="position:absolute;top:70px" href="/frame-docs">Frame docs</a>`);
    res.end(`<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Snapshot labels</title>
      <style>html,body{margin:0;padding:0;background:white}body{min-height:2200px}button{position:absolute;width:100px;height:40px;border:0;background:rgb(30,180,70)}
      #keep{left:40px;top:60px}#other{left:40px;top:110px}#far{left:40px;top:1800px}#shadow{position:absolute;left:180px;top:60px}
      iframe{position:absolute;left:20px;top:200px;width:180px;height:100px;border:0}#cross{left:240px}a{position:absolute;left:40px;top:160px}</style>
      <section id="scope"><button id="keep" aria-label="Keep action" onclick="window.clicks=(window.clicks||0)+1"></button><button id="other" aria-label="Other action"></button></section>
      <button id="far" aria-label="Offscreen action"></button><a href="/docs">Document docs</a><section id="empty"></section><div id="shadow"></div>
      <iframe id="same" src="/frame"></iframe><iframe id="cross" src="http://localhost:${server.address().port}/frame"></iframe>
      <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<style>button{width:100px;height:40px;border:0;background:rgb(30,180,70)}</style><button aria-label="Shadow action" onclick="window.shadowClicks=(window.shadowClicks||0)+1"></button>'</script>`);
  });
  server.listen(0, '0.0.0.0'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-snapshot-labels-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'snapshot-labels', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory };
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
  const snapshot = args => call('snapshot', { targetId, ...args });
  const screenshot = args => call('screenshot', { targetId, ...args });
  return { host, call, act, evaluate, snapshot, screenshot, targetId, tab: host.tabs.get(targetId), url, external };
}

function metadata(result, { inlineType = 'png' } = {}) {
  assert.deepEqual(result.content?.map(block => block.type), ['text', 'image']);
  const { content, ...publicMetadata } = result;
  assert.deepEqual(JSON.parse(content[0].text), publicMetadata);
  assert.equal(result.labels, true);
  assert.equal(result.type, 'png');
  assert.equal(content[1].data.source, 'base64');
  assert.equal(content[1].data.media_type, `image/${inlineType}`);
  const png = readFileSync(result.path);
  assert.equal(result.bytes, png.length); assert.equal(result.sha256, createHash('sha256').update(png).digest('hex'));
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const inline = Buffer.from(content[1].data.data, 'base64');
  if (inlineType === 'png') assert.deepEqual(inline, png);
  else assert.equal(inline.readUInt16BE(), 0xffd8);
  assert.deepEqual([...result.snapshot.matchAll(/\[ref=(e\d+)\]/g)].map(match => match[1]), result.refs.map(item => item.ref));
  const names = new Map(result.refs.map(item => [item.ref, item]));
  for (const item of result.annotations ?? []) {
    assert.equal(item.role, names.get(item.ref)?.role);
    assert.equal(item.name ?? '', names.get(item.ref)?.name ?? '');
  }
  return result;
}

async function pixels(f, result, points, { artifact = false } = {}) {
  const image = artifact ? { media_type: `image/${result.type}`, data: readFileSync(result.path).toString('base64') } : result.content[1].data;
  return f.evaluate(`async () => {const image=new Image();image.src=${JSON.stringify(`data:${image.media_type};base64,${image.data}`)};await image.decode();const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);return {width:canvas.width,height:canvas.height,pixels:${JSON.stringify(points)}.map(([x,y])=>[...ctx.getImageData(x,y,1,1).data])};}`);
}
const orange = pixel => assert.deepEqual(pixel, [255, 176, 32, 255]);
const normalizeRefs = text => text.replace(/\[ref=e\d+\]/g, '[ref=e]');

test('combined role capture preserves scoped options, URLs, refs and delta publication order', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  const options = { selector: '#scope', interactive: true, compact: true, depth: 8, limit: 10, maxChars: 5000, urls: true };
  const baseline = await f.snapshot(options);
  const epoch = f.tab.snapshot;
  const baselineKeys = [...f.host.snapshotDelta.entries.values()].map(item => [...item.keys]);
  const nativeScreenshot = f.tab.page.screenshot.bind(f.tab.page);
  let captures = 0;
  f.tab.page.screenshot = async args => {
    captures++;
    assert.equal(f.tab.snapshot, epoch + 1);
    assert.equal(f.tab.refs.size, 0);
    assert.deepEqual([...f.host.snapshotDelta.entries.values()].map(item => [...item.keys]), baselineKeys);
    assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 1);
    return nativeScreenshot(args);
  };
  let result;
  try { result = metadata(await f.snapshot({ ...options, labels: true })); }
  finally { f.tab.page.screenshot = nativeScreenshot; }
  assert.equal(captures, 1);
  assert.equal(result.snapshotGeneration, epoch + 1);
  assert.equal(result.newElements, 0);
  assert.equal(normalizeRefs(result.snapshot), normalizeRefs(baseline.snapshot));
  assert.match(result.snapshot, /Document docs.*\/docs/);
  assert.deepEqual(result.refs.map(item => item.name), ['Keep action', 'Other action']);
  assert.deepEqual(result.annotations.map(item => item.ref), result.refs.map(item => item.ref));
  assert.equal(result.labelsCount, 2); assert.equal(result.labelsSkipped, 0); assert.equal(result.truncated, false);
  orange((await pixels(f, result, [[40, 80]])).pixels[0]);
  const ref = result.refs[0].ref;
  assert.equal(await f.tab.refs.get(ref).evaluate(element => element.id), 'keep');
  await f.act({ kind: 'click', ref }); assert.equal(await f.evaluate('() => window.clicks'), 1);
  const ordinary = await f.screenshot({});
  assert.deepEqual((await pixels(f, ordinary, [[40, 80]])).pixels[0], [30, 180, 70, 255]);
  assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
  await f.evaluate(`() => {const b=document.createElement('button');b.style.cssText='left:380px;top:60px';b.textContent='Added action';document.querySelector('#scope').append(b);return true}`);
  const added = metadata(await f.snapshot({ ...options, labels: true }));
  assert.equal(added.newElements, 1); assert.match(added.snapshot, /1 new element\(s\) since last snapshot$/);
  assert.equal((await f.snapshot(options)).newElements, 0);
});

test('combined role capture retains explicit frame scope and its document URL appendix', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  const result = metadata(await f.snapshot({ labels: true, frame: '#same', selector: '#frame-scope', interactive: true, compact: true, urls: true, limit: 10 }));
  assert.deepEqual(result.refs.map(item => item.name), ['Frame action']);
  assert.match(result.snapshot, /Frame docs.*\/frame-docs/);
  assert.deepEqual(result.annotations[0].box, { x: 30, y: 220, width: 120, height: 40 });
  orange((await pixels(f, result, [[30, 240]])).pixels[0]);
  await f.act({ kind: 'click', ref: result.refs[0].ref });
  assert.equal(await f.tab.page.frames().find(frame => frame.url() === new URL('/frame', f.url).href).evaluate(() => window.clicks), 1);
});

test('combined AI ARIA labels retain main, open shadow, same-frame and OOP-frame identities', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  const result = metadata(await f.snapshot({ labels: true, refs: 'aria', interactive: true, urls: true }));
  assert.equal(result.refsType, 'aria');
  const keep = result.refs.find(item => item.name === 'Keep action');
  const shadow = result.refs.find(item => item.name === 'Shadow action');
  const framed = result.refs.filter(item => item.name === 'Frame action');
  assert.ok(keep); assert.ok(shadow); assert.equal(framed.length, 2);
  for (const item of [keep, shadow, ...framed]) assert.ok(result.annotations.some(annotation => annotation.ref === item.ref));
  const image = await pixels(f, result, [[40, 80], [180, 80], [30, 240], [250, 240]]);
  for (const pixel of image.pixels) orange(pixel);
  for (const item of [keep, shadow, ...framed]) await f.act({ kind: 'click', ref: item.ref });
  assert.equal(await f.evaluate('() => window.clicks'), 1); assert.equal(await f.evaluate('() => window.shadowClicks'), 1);
  for (const frame of f.tab.page.frames().filter(frame => frame !== f.tab.page.mainFrame())) assert.equal(await frame.evaluate(() => window.clicks), 1);
  const oop = f.tab.page.frames().find(frame => frame.url().startsWith('http://localhost:'));
  const session = await f.tab.page.context().newCDPSession(oop);
  try { assert.equal((await session.send('Target.getTargetInfo')).targetInfo.type, 'iframe'); }
  finally { await session.detach(); }
  assert.equal((await f.snapshot({ refs: 'aria', interactive: true, urls: true })).newElements, 0);
  assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
});

test('combined empty refs, zero text and ordinary limits preserve snapshot truncation', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  for (const options of [{ selector: '#empty', interactive: true }, { selector: '#scope', interactive: true, maxChars: 0 }]) {
    const result = metadata(await f.snapshot({ ...options, labels: true }));
    assert.equal(result.snapshot, options.maxChars === 0 ? '' : '(no interactive elements)'); assert.deepEqual(result.refs, []);
    assert.equal(result.labelsCount, 0); assert.equal(result.labelsSkipped, 0);
    assert.equal(result.truncated, options.maxChars === 0);
    assert.deepEqual([...(await pixels(f, result, [[40, 80]])).pixels[0]], [30, 180, 70, 255]);
  }
  const limited = metadata(await f.snapshot({ selector: '#scope', interactive: true, compact: true, limit: 1, labels: true }));
  assert.deepEqual(limited.refs.map(item => item.name), ['Keep action']); assert.equal(limited.truncated, true); assert.equal(limited.labelsCount, 1);
  const offscreen = metadata(await f.snapshot({ labels: true, selector: '#far', interactive: true }));
  assert.equal(offscreen.refs[0].name, 'Offscreen action'); assert.equal(offscreen.labelsCount, 0); assert.equal(offscreen.labelsSkipped, 1);
  assert.ok(offscreen.annotations[0].box.y > 480); assert.equal(offscreen.truncated, false);
});

test('combined viewport capture applies the 150 label budget to the finalized refs', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.act({ kind: 'resize', width: 640, height: 480 });
  await f.evaluate(`() => {const section=document.createElement('section');section.id='many';document.body.append(section);for(let i=0;i<151;i++){const b=document.createElement('button');b.setAttribute('aria-label','Item '+i);b.style.cssText='left:'+(i%10*60)+'px;top:'+Math.floor(i/10)*28+'px;width:50px;height:24px';section.append(b)}return true}`);
  const result = metadata(await f.snapshot({ labels: true, selector: '#many', interactive: true, limit: 500, maxChars: 40000 }));
  assert.equal(result.refCount, 151); assert.equal(result.labelsCount, 150); assert.equal(result.labelsSkipped, 1); assert.equal(result.truncated, false);
  assert.deepEqual(result.annotations.map(item => item.ref), result.refs.slice(0, 150).map(item => item.ref));
  const image = await pixels(f, result, [[0, 12], [540, 14 * 28 + 12], [0, 15 * 28 + 12]]);
  assert.deepEqual([image.width, image.height], [640, 480]); orange(image.pixels[0]); orange(image.pixels[1]); assert.deepEqual(image.pixels[2], [30, 180, 70, 255]);
  await f.act({ kind: 'click', ref: result.refs.at(-1).ref });
});

test('combined PNG viewport capture preserves device metrics and their owner', { timeout: 60000 }, async t => {
  const f = await fixture(t); await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const observe = () => f.evaluate('() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,scale:visualViewport.scale})');
  const before = await observe(); const owner = f.tab.emulation.session; assert.equal(before.dpr, 3);
  const result = metadata(await f.snapshot({ labels: true, selector: '#scope', interactive: true }), { inlineType: 'jpeg' });
  assert.equal(f.tab.emulation.session, owner); assert.deepEqual(await observe(), before);
  assert.equal(result.labelsCount, 2);
  const keep = result.annotations.find(item => item.name === 'Keep action');
  assert.deepEqual(keep.box, { x: 120, y: 180, width: 300, height: 120 });
  const artifact = await pixels(f, result, [[120, 240]], { artifact: true });
  const model = await pixels(f, result, [[74, 145]]);
  assert.deepEqual([artifact.width, artifact.height], [1170, 1992]);
  assert.deepEqual([model.width, model.height], [705, 1200]);
  orange(artifact.pixels[0]);
  for (const [i, expected] of [255, 176, 32, 255].entries()) assert.ok(Math.abs(model.pixels[0][i] - expected) <= 12);
  await f.act({ kind: 'click', ref: keep.ref }); assert.equal(await f.evaluate('() => window.clicks'), 1);
});

test('remote combined capture leaves the external page and browser process owned by its fixture', { timeout: 60000 }, async t => {
  const f = await fixture(t, { remote: true });
  const result = metadata(await f.snapshot({ labels: true, selector: '#scope', interactive: true }));
  assert.equal(result.labelsCount, 2); orange((await pixels(f, result, [[40, 80]])).pixels[0]);
  await f.act({ kind: 'click', ref: result.refs[0].ref });
  assert.equal((await f.call('stop')).cleanup_confirmed, true); assert.equal(process.kill(f.external.pid, 0), true);
  const state = await f.external.inspect('() => ({clicks:window.clicks,overlays:document.querySelectorAll("[data-synapsis-labels]").length})');
  assert.deepEqual(state.pages.find(page => page.url === f.url).value, { clicks: 1, overlays: 0 });
});
