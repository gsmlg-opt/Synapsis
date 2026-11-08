import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const timeoutMs = 15000;

async function fixture(t) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html');
    res.end(`<!doctype html><title>Reconnect ${req.url}</title><button onclick="window.clicks=(window.clicks||0)+1">Reconnect action</button><p>${req.url}</p>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-reconnect-'));
  let external; let host;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  external = await startExternalBrowser({ executable, directory, initialUrl: `${url}initial` });
  host = new BrowserHost({ profile: 'reconnect', driver: 'remote-cdp', endpoint: external.endpoint, project_root: directory, timeout_ms: timeoutMs, max_image_bytes: 196608 });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  await call('start');
  const open = (label, path) => call('open', { targetUrl: `${url}${path}`, label });
  return { host, external, call, open, url };
}

const metadata = tab => Object.fromEntries(['targetId', 'url', 'tabId', 'suggestedTargetId', 'label'].filter(key => Object.hasOwn(tab, key)).map(key => [key, tab[key]]));

test('remote stop/start keeps exact aliases labels and selection with fresh page state and refs', { timeout: 90000 }, async t => {
  const f = await fixture(t);
  const first = await f.open('first', 'first'); const second = await f.open('second', 'second');
  await f.call('focus', { targetId: 'first' });
  const before = await f.call('snapshot');
  const oldRef = before.refs.find(item => item.name === 'Reconnect action').ref;
  await f.call('act', { request: { kind: 'click', ref: oldRef } });
  await f.call('act', { request: { kind: 'evaluate', fn: "() => {console.log('old attach log');return window.clicks}" } });
  const oldTabs = (await f.call('tabs')).tabs;
  const oldPage = f.host.tabs.get(first.targetId).page;
  assert.ok((await f.call('console')).messages.some(item => item.text === 'old attach log'));
  const generation = f.host.generation;
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.deepEqual((await f.call('status')).tabs, []);
  assert.equal((await f.external.inspect('() => window.clicks || 0')).pages.find(page => page.url.endsWith('/first')).value, 1);
  const started = await f.call('start');
  assert.ok(started.generation > generation);
  assert.deepEqual(started.tabs.map(metadata).sort((a, b) => a.targetId.localeCompare(b.targetId)), oldTabs.map(metadata).sort((a, b) => a.targetId.localeCompare(b.targetId)));
  const newTab = f.host.tabs.get(first.targetId);
  assert.notEqual(newTab.page, oldPage);
  assert.equal(newTab.refs.size, 0);
  assert.deepEqual((await f.call('console')).messages, []);
  for (const action of ['tabs', 'status']) assert.deepEqual((await f.call(action)).tabs.filter(tab => tab.active).map(tab => tab.targetId), [first.targetId]);
  assert.equal((await f.call('text')).targetId, first.targetId);
  assert.equal((await f.call('text', { targetId: ' first ' })).targetId, first.targetId);
  const after = await f.call('snapshot');
  assert.equal(Object.hasOwn(after, 'newElements'), false);
  const newRef = after.refs.find(item => item.name === 'Reconnect action').ref;
  assert.notEqual(newRef, oldRef);
  const request = { kind: 'batch', targetId: first.tabId, actions: [{ kind: 'click', targetId: 'first', ref: newRef }, { kind: 'batch', targetId: first.targetId, actions: [{ kind: 'evaluate', fn: '() => window.clicks' }] }] };
  const raw = structuredClone(request);
  const result = await f.call('act', { targetId: 'first', request });
  assert.equal(result.results[1].results[0].value, 2); assert.deepEqual(request, raw);
  assert.equal((await f.external.inspect('() => window.clicks || 0')).pages.find(page => page.url.endsWith('/first')).value, 2);
  const moved = await f.open('first', 'moved');
  assert.ok(Number(moved.tabId.slice(1)) > Math.max(...oldTabs.map(tab => Number(tab.tabId.slice(1)))));
  assert.equal((await f.call('tabs')).tabs.find(tab => tab.targetId === first.targetId).label, undefined);
  assert.equal((await f.call('text', { targetId: 'second' })).targetId, second.targetId);
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  await f.call('start');
  assert.equal((await f.call('text')).targetId, second.targetId);
  assert.equal((await f.call('text', { targetId: 'first' })).targetId, moved.targetId);
  assert.equal((await f.host.close()).cleanup_confirmed, true);
  assert.equal(f.host.tabAliases.size, 0); assert.equal(f.host.activeTarget, null);
  assert.equal((await f.external.inspect()).alive, true);
});

test('remote reconnect reconciles replacements made while disconnected with surviving aliases', { timeout: 90000 }, async t => {
  const f = await fixture(t); const first = await f.open('first', 'first'); const second = await f.open('second', 'second');
  await f.call('focus', { targetId: 'first' });
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  const browser = await chromium.connectOverCDP(f.external.endpoint, { timeout: timeoutMs, noDefaults: true });
  let firstId; let secondId;
  try {
    const context = browser.contexts()[0]; context.setDefaultTimeout(timeoutMs);
    const oldFirst = context.pages().find(page => page.url() === `${f.url}first`);
    const oldSecond = context.pages().find(page => page.url() === `${f.url}second`);
    const newSecond = await context.newPage(); await newSecond.goto(`${f.url}second`);
    const newFirst = await context.newPage(); await newFirst.goto(`${f.url}first`);
    for (const [page, save] of [[newFirst, id => { firstId = id; }], [newSecond, id => { secondId = id; }]]) {
      const session = await context.newCDPSession(page);
      try { save((await session.send('Target.getTargetInfo')).targetInfo.targetId); } finally { await session.detach(); }
    }
    await oldFirst.close(); await oldSecond.close();
  } finally { await browser.close(); }
  const started = await f.call('start');
  for (const [old, targetId] of [[first, firstId], [second, secondId]]) {
    const actual = started.tabs.find(tab => tab.targetId === targetId);
    assert.deepEqual(metadata(actual), { ...metadata(old), targetId });
  }
  assert.deepEqual(started.tabs.filter(tab => tab.active).map(tab => tab.targetId), [firstId]);
  assert.equal((await f.call('text')).targetId, firstId);
  assert.equal((await f.call('text', { targetId: 'second' })).targetId, secondId);
});
