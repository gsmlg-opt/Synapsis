import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';
import { startExternalBrowser } from './fixtures/external-browser.mjs';

const executable = process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium';
const timeoutMs = 15000;

async function fixture(t, driver) {
  const server = createServer((request, response) => {
    response.setHeader('Content-Type', 'text/html');
    response.end(`<!doctype html><title>Sticky ${request.url}</title><main><h1>Sticky ${request.url}</h1><button onclick="window.clicks=(window.clicks||0)+1">Sticky action</button></main>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-sticky-targets-'));
  const url = `http://127.0.0.1:${server.address().port}/`;
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const common = { profile: 'sticky-targets', driver, timeout_ms: timeoutMs, max_image_bytes: 196608, project_root: directory };
  if (driver === 'remote-cdp') {
    external = await startExternalBrowser({ executable, directory, initialUrl: `${url}initial` });
    host = new BrowserHost({ ...common, endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  await call('start');
  const open = label => call('open', { targetUrl: `${url}${label}`, label });
  return { host, external, call, open, url };
}

function uniquePrefix(targetId, tabs) {
  for (let length = 4; length < targetId.length; length++) {
    const prefix = targetId.slice(0, length);
    if (tabs.filter(tab => tab.targetId.toLowerCase().startsWith(prefix.toLowerCase())).length === 1) {
      return [...prefix].map((letter, index) => index % 2 ? letter.toUpperCase() : letter.toLowerCase()).join('');
    }
  }
  assert.fail('ordinary Chromium targets have a unique shortened identity');
}

async function selected(call, targetId) {
  for (const action of ['tabs', 'status']) {
    const result = await call(action);
    assert.deepEqual(result.tabs.filter(tab => tab.active).map(tab => tab.targetId), targetId ? [targetId] : [], `${action} reports the selected identity`);
  }
}

for (const driver of ['managed-host', 'remote-cdp']) {
  test(`${driver} explicit reads observations acts and navigation select the next implicit target`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver); const a = await f.open('page-a'); const b = await f.open('page-b');
    const prefix = uniquePrefix(a.targetId, (await f.call('tabs')).tabs);
    const choices = [
      ['text', { targetId: a.targetId }],
      ['snapshot', { targetId: a.tabId }],
      ['text', { targetId: ' page-a ' }],
      ['console', { targetId: prefix }],
      ['requests', { targetId: a.tabId }],
      ['errors', { targetId: 'page-a' }],
      ['act', { targetId: prefix, request: { kind: 'evaluate', fn: '() => document.title' } }],
      ['navigate', { targetId: a.targetId, targetUrl: `${f.url}page-a-next` }],
    ];
    for (const [action, args] of choices) {
      await f.call('focus', { targetId: b.targetId });
      const result = await f.call(action, args);
      assert.equal(result.targetId, a.targetId, `${action} resolves the explicit identity`);
      await selected(f.call, a.targetId);
      const implicit = await f.call('text');
      assert.equal(implicit.targetId, a.targetId, `${action} retains selection for the omitted targetId`);
      assert.match(implicit.text, /Sticky \/page-a/);
      await selected(f.call, a.targetId);
    }
  });

  test(`${driver} read selection keeps public page focus unchanged`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const a = await f.open('page-a'); const b = await f.open('page-b');
    const pages = f.host.browser.contexts()[0].pages();
    const pageA = pages.find(page => page.url() === `${f.url}page-a`);
    const pageB = pages.find(page => page.url() === `${f.url}page-b`);
    await f.call('focus', { targetId: b.targetId });
    for (const page of [pageA, pageB]) await page.evaluate(() => {
      window.stickyFocusEvents = 0;
      window.addEventListener('focus', () => window.stickyFocusEvents++);
    });
    const before = await Promise.all([pageA, pageB].map(page => page.evaluate(() => document.hasFocus())));
    assert.equal((await f.call('text', { targetId: a.targetId })).targetId, a.targetId);
    assert.equal((await f.call('snapshot')).targetId, a.targetId);
    assert.deepEqual(await Promise.all([pageA, pageB].map(page => page.evaluate(() => document.hasFocus()))), before);
    assert.deepEqual(await Promise.all([pageA, pageB].map(page => page.evaluate(() => window.stickyFocusEvents))), [0, 0]);
    await selected(f.call, a.targetId);
  });

  test(`${driver} implicit acts keep selected snapshot refs and nested batch context`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const a = await f.open('page-a'); const b = await f.open('page-b');
    // Ordinary pointer input needs a foreground Page in remote noDefaults mode;
    // this fixture precondition must leave the host's sticky selection on B.
    await f.host.browser.contexts()[0].pages().find(page => page.url() === `${f.url}page-a`).bringToFront();
    await selected(f.call, b.targetId);
    const snapshot = await f.call('snapshot', { targetId: a.tabId });
    const ref = snapshot.refs.find(item => item.name === 'Sticky action').ref;
    const result = await f.call('act', { request: { kind: 'batch', actions: [
      { kind: 'click', ref },
      { kind: 'batch', targetId: 'page-a', actions: [
        { kind: 'evaluate', targetId: a.targetId, fn: '() => window.clicks' },
      ] },
    ] } });
    assert.equal(result.targetId, a.targetId);
    assert.equal(result.results[0].ok, true);
    assert.equal(result.results[1].results[0].value, 1);
    assert.equal((await f.call('text')).targetId, a.targetId);
    await selected(f.call, a.targetId);
  });

  test(`${driver} closing a background tab preserves the selected identity`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const a = await f.open('page-a'); const b = await f.open('page-b');
    assert.equal((await f.call('close', { targetId: a.tabId })).closed, true);
    await selected(f.call, b.targetId);
    assert.equal((await f.call('text')).targetId, b.targetId);
    assert.match((await f.call('text')).text, /Sticky \/page-b/);
  });

  test(`${driver} explicitly closing the selected tab lets the next implicit action select the first live tab`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); await f.open('page-a'); const b = await f.open('page-b');
    const first = (await f.call('tabs')).tabs[0];
    assert.equal((await f.call('close', { targetId: b.targetId })).closed, true);
    await selected(f.call, null);
    assert.equal((await f.call('text')).targetId, first.targetId);
    await selected(f.call, first.targetId);
  });

  for (const kind of ['close', 'nested batch close']) {
    test(`${driver} ordinary act ${kind} retires the closed selected identity`, { timeout: 60000 }, async t => {
      const f = await fixture(t, driver); await f.open('page-a'); const b = await f.open('page-b');
      const first = (await f.call('tabs')).tabs[0];
      const request = kind === 'close' ? { kind: 'close' } : { kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'close' }] }] };
      const result = await f.call('act', { targetId: b.tabId, request });
      assert.equal(result.targetId, b.targetId);
      if (kind === 'close') assert.equal(result.closed, true);
      else assert.equal(result.results[0].results[0].closed, true);
      await selected(f.call, null);
      assert.equal((await f.call('text')).targetId, first.targetId);
      await selected(f.call, first.targetId);
    });
  }

  test(`${driver} popup adoption leaves the existing selected identity in place`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const a = await f.open('page-a'); await f.open('page-b');
    const context = f.host.browser.contexts()[0];
    const popupReady = context.waitForEvent('page', { timeout: timeoutMs });
    await f.call('act', { targetId: a.tabId, request: { kind: 'evaluate', fn: '() => {window.open("/popup", "sticky-popup");return true}' } });
    const popup = await popupReady;
    await popup.waitForLoadState('domcontentloaded', { timeout: timeoutMs });
    const tabs = (await f.call('tabs')).tabs;
    assert.ok(tabs.some(tab => tab.url === `${f.url}popup`));
    await selected(f.call, a.targetId);
    assert.equal((await f.call('text')).targetId, a.targetId);
  });

  test(`${driver} start and stop reconcile profile selection against the actual live list`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver);
    const initial = (await f.call('tabs')).tabs[0];
    await selected(f.call, null);
    assert.equal((await f.call('text')).targetId, initial.targetId);
    await selected(f.call, initial.targetId);
    const opened = await f.open('page-a');
    assert.equal((await f.call('text')).targetId, opened.targetId);
    assert.equal((await f.call('stop')).cleanup_confirmed, true);
    assert.deepEqual((await f.call('status')).tabs, []);
    const restarted = await f.call('start');
    if (driver === 'remote-cdp') {
      assert.ok(restarted.tabs.some(tab => tab.targetId === opened.targetId));
      await selected(f.call, opened.targetId);
      assert.equal((await f.call('text')).targetId, opened.targetId);
    } else {
      await selected(f.call, null);
      assert.equal(f.host.activeTarget, opened.tabId);
      assert.equal((await f.call('text', { targetId: restarted.tabs[0].targetId })).targetId, restarted.tabs[0].targetId);
      await selected(f.call, restarted.tabs[0].targetId);
    }
  });
}
