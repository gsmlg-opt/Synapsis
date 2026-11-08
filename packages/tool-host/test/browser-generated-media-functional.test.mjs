import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Generated media</title>
<style>html,body{margin:0;background:white}button{position:absolute;left:24px;top:32px;width:96px;height:48px;border:0;padding:0;background:rgb(30,180,70)}</style>
<button id="capture" aria-label="Saved action" onclick="window.clicks=(window.clicks||0)+1"></button>`;

async function fixture(t, { remote, mode }) {
  const server = createServer((_req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(html); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-generated-media-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'generated-media', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory,
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
  const tab = host.tabs.get(targetId);
  return { host, external, directory, url, targetId, tab, call, act,
    screenshot: args => call('screenshot', { targetId, ...args }),
    snapshot: args => call('snapshot', { targetId, interactive: true, ...args }),
    evaluate: async fn => (await act({ kind: 'evaluate', fn })).value };
}

function savedImage(f, result, type, captured) {
  assert.deepEqual(result.content.map(block => block.type), ['text', 'image']);
  const metadata = JSON.parse(result.content[0].text);
  for (const [key, value] of Object.entries(metadata)) assert.deepEqual(result[key], value);
  assert.equal(result.targetId, f.targetId); assert.equal(result.url, f.url);
  assert.equal(result.type, type);
  assert.equal(result.content[1].data.source, 'base64');
  assert.equal(result.content[1].data.media_type, `image/${type}`);
  const inline = Buffer.from(result.content[1].data.data, 'base64');
  assert.deepEqual(inline, captured);
  assert.equal(result.content[1].data.data, captured.toString('base64'));
  assert.ok(result.path.startsWith(join(f.directory, '.synapsis', 'browser-files') + '/'));
  assert.ok(result.path.endsWith(`.${type}`));
  assert.deepEqual(result.media, { outbound: false, mediaUrl: result.path });
  assert.equal(result.bytes, inline.length);
  assert.ok(result.bytes > 0 && result.bytes <= 196608);
  assert.ok(result.content[1].data.data.length <= 262144);
  assert.deepEqual(readFileSync(result.path), inline);
  assert.equal(result.sha256, createHash('sha256').update(inline).digest('hex'));
  if (type === 'png') assert.equal(inline.subarray(1, 4).toString(), 'PNG');
  else assert.equal(inline.readUInt16BE(), 0xffd8);
  assert.equal(readdirSync(dirname(result.path)).some(name => name.startsWith('.browser-stage-')), false);
  return inline;
}

function observeCaptures(f) {
  const original = f.tab.page.screenshot.bind(f.tab.page);
  const captures = [];
  f.tab.page.screenshot = async args => {
    assert.equal(f.host.fileOwners.size, 1);
    assert.equal(f.host.fileTasks.size, 1);
    const bytes = await original(args);
    captures.push(bytes);
    return bytes;
  };
  const fileTask = f.host.fileTask.bind(f.host);
  let owners = 0;
  f.host.fileTask = (operation, callback) => { owners++; return fileTask(operation, callback); };
  return { captures, owners: () => owners };
}

async function retainedAfterStop(f, results) {
  const saved = results.map(result => readFileSync(result.path));
  const names = results.map(result => basename(result.path)).sort();
  assert.equal(new Set(results.map(result => result.path)).size, results.length);
  assert.deepEqual((await readdir(dirname(results[0].path))).sort(), names);
  const pid = f.host.diagnosticPid;
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  if (f.external) {
    assert.equal(process.kill(f.external.pid, 0), true);
    assert.equal(await readFile(f.external.markerPath, 'utf8'), 'external-browser-owned-by-fixture');
    const state = await f.external.inspect('() => ({clicks:window.clicks,overlays:document.querySelectorAll("[data-synapsis-labels]").length})');
    assert.equal(state.alive, true);
    assert.deepEqual(state.pages.find(page => page.url === f.url).value, { clicks: 1, overlays: 0 });
  } else assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  assert.equal((await f.host.close()).cleanup_confirmed, true);
  assert.deepEqual(await Promise.all(results.map(result => readFile(result.path))), saved);
  assert.deepEqual((await readdir(dirname(results[0].path))).sort(), names);
}

for (const remote of [false, true]) {
  for (const mode of [undefined, 'image']) {
    test(`${remote ? 'remote' : 'managed'} ${mode ?? 'default'} image screenshots persist finalized PNG/JPEG bytes and labels`, { timeout: 90000 }, async t => {
      const f = await fixture(t, { remote, mode });
      const observation = observeCaptures(f);
      const results = [];
      for (const type of ['png', 'jpeg']) for (const labels of [false, true]) {
        const result = await f.screenshot({ type, labels });
        savedImage(f, result, type, observation.captures.at(-1));
        assert.equal(result.labels === true, labels);
        if (labels) {
          assert.equal(result.labelsCount, 1); assert.equal(result.labelsSkipped, 0);
          assert.equal(result.annotations.length, 1);
          const ref = result.annotations[0].ref;
          assert.equal(f.tab.refMetadata.get(ref).name, 'Saved action');
          assert.equal(await f.tab.refs.get(ref).evaluate(element => element.id), 'capture');
        }
        assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
        results.push(result);
      }
      assert.equal(observation.captures.length, 4); assert.equal(observation.owners(), 4);
      await f.act({ kind: 'click', ref: results.at(-1).annotations[0].ref });
      assert.equal(await f.evaluate('() => window.clicks'), 1);
      await retainedAfterStop(f, results);
    });
  }
  for (const mode of [undefined, 'image', 'path']) {
    test(`${remote ? 'remote' : 'managed'} ${mode ?? 'default'} combined role/ARIA snapshots persist before refs and delta adoption`, { timeout: 90000 }, async t => {
      const f = await fixture(t, { remote, mode });
      const observation = observeCaptures(f);
      const results = [];
      for (const refs of ['role', 'aria']) {
        const baseline = await f.snapshot({ refs });
        const epoch = f.tab.snapshot;
        const baselineKeys = [...f.host.snapshotDelta.entries.values()].map(item => [...item.keys]);
        const record = f.host.snapshotDelta.record.bind(f.host.snapshotDelta);
        let adoptions = 0; let refAdoptions = 0;
        const published = () => {
          const directory = join(f.directory, '.synapsis', 'browser-files');
          const files = readdirSync(directory);
          assert.equal(files.length, results.length + 1);
          assert.equal(files.some(name => name.startsWith('.browser-stage-')), false);
          const previous = new Set(results.map(result => basename(result.path)));
          const fresh = files.find(name => !previous.has(name));
          assert.deepEqual(readFileSync(join(directory, fresh)), observation.captures.at(-1));
          assert.deepEqual([...f.host.snapshotDelta.entries.values()].map(item => [...item.keys]), baselineKeys);
        };
        let handles = f.tab.refs;
        Object.defineProperty(f.tab, 'refs', { configurable: true, get: () => handles, set: value => {
          if (value.size) { published(); refAdoptions++; }
          handles = value;
        } });
        f.host.snapshotDelta.record = (...args) => { adoptions++; published(); return record(...args); };
        const capture = f.tab.page.screenshot;
        f.tab.page.screenshot = async args => {
          assert.equal(f.tab.snapshot, epoch + 1); assert.equal(f.tab.refs.size, 0);
          assert.deepEqual([...f.host.snapshotDelta.entries.values()].map(item => [...item.keys]), baselineKeys);
          return capture(args);
        };
        let result;
        try { result = await f.snapshot({ refs, labels: true }); }
        finally {
          f.host.snapshotDelta.record = record; f.tab.page.screenshot = capture;
          Object.defineProperty(f.tab, 'refs', { configurable: true, enumerable: true, writable: true, value: handles });
        }
        savedImage(f, result, 'png', observation.captures.at(-1));
        assert.equal(result.imagePath, result.path); assert.equal(result.imageType, 'png');
        assert.equal(adoptions, 1); assert.equal(refAdoptions, 1); assert.equal(result.snapshotGeneration, epoch + 1);
        assert.equal(result.newElements, 0); assert.equal(result.refsType, refs);
        assert.equal(result.snapshot.replace(/\[ref=e\d+\]/g, '[ref=e]'), baseline.snapshot.replace(/\[ref=e\d+\]/g, '[ref=e]'));
        assert.deepEqual(result.refs.map(item => item.name), ['Saved action']);
        assert.deepEqual(result.annotations.map(item => item.ref), result.refs.map(item => item.ref));
        assert.equal(result.labelsCount, 1); assert.equal(result.labelsSkipped, 0);
        assert.equal(await f.tab.refs.get(result.refs[0].ref).evaluate(element => element.id), 'capture');
        assert.equal(await f.tab.page.locator('[data-synapsis-labels]').count(), 0);
        results.push(result);
      }
      assert.equal(observation.captures.length, 2); assert.equal(observation.owners(), 2);
      await f.act({ kind: 'click', ref: results.at(-1).refs[0].ref });
      assert.equal(await f.evaluate('() => window.clicks'), 1);
      await retainedAfterStop(f, results);
    });
  }
}
