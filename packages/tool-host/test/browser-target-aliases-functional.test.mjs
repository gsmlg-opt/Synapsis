import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const html = '<!doctype html><title>Alias fixture</title><button onclick="window.clicks=(window.clicks||0)+1">Alias action</button><input type="file" aria-label="Alias upload" onchange="window.uploaded=this.files[0].name"><p>Alias content</p>';

async function fixture(t, remote = false) {
  const server = createServer((req, res) => {
    if (req.url === '/data') { res.setHeader('Content-Type', 'application/json'); res.end('{"value":"ordinary alias request"}'); return; }
    res.setHeader('Content-Type', 'text/html'); res.end(html);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-target-aliases-'));
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const common = { profile: 'aliases', timeout_ms: 15000, max_image_bytes: 196608, project_root: directory };
  if (remote) { external = await startExternalBrowser({ executable, directory, initialUrl: url }); host = new BrowserHost({ ...common, driver: 'remote-cdp', endpoint: external.endpoint }); }
  else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const open = (label, path = '/') => call('open', { targetUrl: new URL(path, url).href, ...(label === undefined ? {} : { label }) });
  const evaluate = async (targetId, fn) => (await call('act', { targetId, request: { kind: 'evaluate', fn } })).value;
  return { host, external, call, open, evaluate, url, directory };
}

function aliases(tab, label) {
  assert.match(tab.tabId, /^t[1-9]\d*$/); assert.notEqual(tab.tabId, tab.targetId); assert.match(tab.targetId, /^[A-Fa-f0-9]{32}$/);
  assert.equal(tab.suggestedTargetId, label ?? tab.tabId);
  assert.equal(tab.label, label);
  if (label === undefined) assert.equal(Object.hasOwn(tab, 'label'), false);
}

test('open labels normalize and tab metadata retains stable registration order', { timeout: 60000 }, async t => {
  const f = await fixture(t); const first = await f.open('  docs:Main  '); aliases(first, 'docs:Main');
  const second = await f.open(); aliases(second);
  const third = await f.open('Other_1'); aliases(third, 'Other_1');
  const tabs = (await f.call('tabs')).tabs;
  const ids = [first.targetId, second.targetId, third.targetId];
  assert.deepEqual(tabs.filter(tab => ids.includes(tab.targetId)).map(tab => tab.targetId), ids);
  for (const [i, label] of ['docs:Main', undefined, 'Other_1'].entries()) aliases(tabs.find(tab => tab.targetId === ids[i]), label);
  const status = await f.call('status');
  for (const [i, label] of ['docs:Main', undefined, 'Other_1'].entries()) aliases(status.tabs.find(tab => tab.targetId === ids[i]), label);
  aliases((await f.call('doctor')).tabs.find(tab => tab.targetId === first.targetId), 'docs:Main');
});

test('exact trimmed aliases route observations captures dialogs and ordinary files', { timeout: 60000 }, async t => {
  const f = await fixture(t); const opened = await f.open('docs'); const id = opened.targetId;
  const snapshot = await f.call('snapshot', { targetId: ' docs ' }); assert.equal(snapshot.targetId, id);
  const ref = snapshot.refs.find(item => item.name === 'Alias action').ref;
  await f.call('act', { targetId: 'docs', request: { kind: 'click', ref } }); assert.equal(await f.evaluate(id, '() => window.clicks'), 1);
  const image = await f.call('screenshot', { targetId: 'docs', ref }); assert.equal(image.targetId, id); assert.ok(image.bytes > 0);
  assert.equal(Object.hasOwn(image, 'label'), false); assert.equal(Object.hasOwn(snapshot, 'tabId'), false);
  assert.match((await f.call('text', { targetId: 'docs' })).text, /Alias content/);
  await f.evaluate('docs', "async () => {console.log('Alias log');await fetch('/data');return true}");
  assert.ok((await f.call('console', { targetId: 'docs' })).messages.some(item => item.text === 'Alias log'));
  assert.ok((await f.call('requests', { targetId: 'docs' })).requests.some(item => item.url.endsWith('/data')));
  assert.deepEqual((await f.call('errors', { targetId: 'docs' })).errors, []);
  assert.equal((await f.call('dialog', { targetId: 'docs', accept: true })).armed, true);
  await f.evaluate('docs', "() => {alert('Alias dialog');return true}");
  const upload = join(f.directory, 'alias-upload.txt'); await writeFile(upload, 'Alias upload data');
  await f.call('upload', { targetId: 'docs', element: 'input', paths: [upload] });
  assert.equal(await f.evaluate(id, '() => window.uploaded'), 'alias-upload.txt');
  const pdf = await f.call('pdf', { targetId: 'docs', path: join(f.directory, 'alias.pdf') }); assert.equal(pdf.targetId, id); assert.equal((await readFile(pdf.path)).subarray(0, 5).toString(), '%PDF-');
  await f.call('focus', { targetId: ' docs ' }); assert.equal(f.host.activeTarget, opened.tabId);
  const navigation = await f.call('navigate', { targetId: 'docs', targetUrl: `${f.url}next` }); assert.equal(navigation.targetId, id);
  assert.equal((await f.call('text', { targetId: id })).targetId, id);
});

test('nested and flattened acts canonicalize equivalent targets without mutating input', { timeout: 60000 }, async t => {
  const f = await fixture(t); const opened = await f.open('batch');
  const request = { kind: 'batch', targetId: ' batch ', actions: [
    { kind: 'evaluate', targetId: opened.targetId, fn: "() => {window.order=['first'];return 1}" },
    { kind: 'batch', targetId: 'batch', actions: [
      { kind: 'evaluate', targetId: ` ${opened.targetId} `, fn: "() => {window.order.push('nested');return 2}" },
      { kind: 'evaluate', targetId: 'batch', fn: "() => {window.order.push('last');return 3}" },
    ] },
  ] };
  const original = structuredClone(request);
  const result = await f.call('act', { targetId: ' batch ', request });
  assert.equal(result.targetId, opened.targetId); assert.equal(result.results[0].ok, true); assert.equal(result.results[1].ok, true);
  assert.deepEqual(request, original); assert.deepEqual(await f.evaluate(opened.targetId, '() => window.order'), ['first', 'nested', 'last']);
  const flattened = { kind: 'batch', targetId: 'batch', actions: [{ kind: 'evaluate', targetId: opened.targetId, fn: "() => {window.order.push('flat');return true}" }] };
  const flatOriginal = structuredClone(flattened); const flatResult = await f.call('act', flattened);
  assert.equal(flatResult.results[0].ok, true); assert.deepEqual(flattened, flatOriginal);
  assert.deepEqual(await f.evaluate('batch', '() => window.order'), ['first', 'nested', 'last', 'flat']);
});

test('moving a label preserves old handles and case-distinct labels while close never recycles ids', { timeout: 60000 }, async t => {
  const f = await fixture(t); const first = await f.open('docs'); const upper = await f.open('Docs'); const replacement = await f.open('docs');
  aliases(replacement, 'docs'); const tabs = (await f.call('tabs')).tabs;
  aliases(tabs.find(tab => tab.targetId === first.targetId)); aliases(tabs.find(tab => tab.targetId === upper.targetId), 'Docs');
  assert.equal((await f.call('text', { targetId: 'docs' })).targetId, replacement.targetId);
  assert.equal((await f.call('text', { targetId: 'Docs' })).targetId, upper.targetId);
  assert.equal((await f.call('text', { targetId: first.targetId })).targetId, first.targetId);
  await f.call('close', { targetId: 'docs' }); const next = await f.open('fresh'); aliases(next, 'fresh');
  assert.ok(Number(next.tabId.slice(1)) > Number(replacement.tabId.slice(1)));
  aliases((await f.call('tabs')).tabs.find(tab => tab.targetId === upper.targetId), 'Docs');
});

test('managed stop reconciles its new live pages and keeps monotonic tab identity lifecycle', { timeout: 60000 }, async t => {
  const f = await fixture(t); const first = await f.open('first'); aliases(first, 'first');
  assert.equal((await f.call('stop')).cleanup_confirmed, true); assert.deepEqual((await f.call('status')).tabs, []);
  await f.call('start'); const second = await f.open('second'); aliases(second, 'second');
  assert.ok(Number(second.tabId.slice(1)) > Number(first.tabId.slice(1)));
  assert.equal((await f.call('status')).tabs.some(tab => tab.label === 'first'), false);
});

test('remote aliases remain profile-owned while external preexisting and newly labelled pages survive', { timeout: 60000 }, async t => {
  const f = await fixture(t, true); const original = (await f.call('tabs')).tabs.find(tab => tab.url === f.url); aliases(original);
  const opened = await f.open('remote', '/created'); aliases(opened, 'remote');
  await f.evaluate('remote', '() => {window.externalMarker=7;return true}');
  assert.equal((await f.call('stop')).cleanup_confirmed, true); assert.equal(process.kill(f.external.pid, 0), true);
  const external = await f.external.inspect('() => window.externalMarker ?? 0');
  assert.equal(external.pages.find(page => page.url.endsWith('/created')).value, 7); assert.ok(external.pages.some(page => page.url === f.url));
  await f.call('start'); const tabs = (await f.call('tabs')).tabs;
  aliases(tabs.find(tab => tab.targetId === original.targetId));
  const reconnected = tabs.find(tab => tab.url.endsWith('/created'));
  aliases(reconnected, 'remote');
  assert.equal(reconnected.tabId, opened.tabId);
  assert.equal(tabs.find(tab => tab.targetId === original.targetId).tabId, original.tabId);
  assert.equal(await f.evaluate(reconnected.targetId, '() => window.externalMarker'), 7);
});
