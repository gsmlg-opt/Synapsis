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
    response.end(`<!doctype html><title>Replacement ${request.url}</title><main><h1>Replacement ${request.url}</h1><section id="scope"><button onclick="window.clicks=(window.clicks||0)+1">Replacement action</button></section></main>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-replacement-'));
  const url = `http://127.0.0.1:${server.address().port}/`;
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const common = { profile: 'replacement', driver, timeout_ms: timeoutMs, max_image_bytes: 196608, project_root: directory };
  if (driver === 'remote-cdp') {
    external = await startExternalBrowser({ executable, directory, initialUrl: `${url}initial` });
    host = new BrowserHost({ ...common, endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  await call('start');
  const context = () => host.browser.contexts()[0];
  const pageFor = path => context().pages().find(page => page.url() === `${url}${path}`);
  const open = (label, path = label) => call('open', { targetUrl: `${url}${path}`, ...(label === undefined ? {} : { label }) });
  const externalPage = async path => {
    const page = await context().newPage();
    await page.goto(`${url}${path}`, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    return page;
  };
  return { host, external, call, context, pageFor, open, externalPage, url };
}

async function rawIdentity(page) {
  const session = await page.context().newCDPSession(page);
  try { return (await session.send('Target.getTargetInfo')).targetInfo.targetId; }
  finally { await session.detach(); }
}

function migrated(tab, previous, targetId) {
  assert.equal(tab.targetId, targetId);
  assert.notEqual(tab.targetId, previous.targetId);
  assert.equal(tab.tabId, previous.tabId);
  assert.equal(tab.label, previous.label);
  assert.equal(tab.suggestedTargetId, previous.label ?? previous.tabId);
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
    assert.deepEqual((await call(action)).tabs.filter(tab => tab.active).map(tab => tab.targetId), targetId ? [targetId] : []);
  }
}

for (const driver of ['managed-host', 'remote-cdp']) {
  test(`${driver} one-for-one changed-URL replacement preserves aliases and implicit selection`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const original = await f.open('continuity', 'before');
    const oldPage = f.pageFor('before');
    const replacement = await f.externalPage('after');
    const targetId = await rawIdentity(replacement);
    await oldPage.close();
    const implicit = await f.call('text');
    assert.equal(implicit.targetId, targetId);
    assert.match(implicit.text, /Replacement \/after/);
    const tabs = (await f.call('tabs')).tabs;
    migrated(tabs.find(tab => tab.targetId === targetId), original, targetId);
    for (const reference of [' continuity ', original.tabId, targetId, uniquePrefix(targetId, tabs)]) {
      assert.equal((await f.call('text', { targetId: reference })).targetId, targetId);
    }
    await selected(f.call, targetId);
  });

  test(`${driver} simultaneous distinct-URL replacements match URL buckets rather than arrival order`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver);
    const first = await f.open('first', 'url-first'); const second = await f.open('second', 'url-second');
    const oldFirst = f.pageFor('url-first'); const oldSecond = f.pageFor('url-second');
    const newSecond = await f.externalPage('url-second');
    const newFirst = await f.externalPage('url-first');
    const [firstId, secondId] = await Promise.all([rawIdentity(newFirst), rawIdentity(newSecond)]);
    await Promise.all([oldFirst.close(), oldSecond.close()]);
    const tabs = (await f.call('tabs')).tabs;
    migrated(tabs.find(tab => tab.targetId === firstId), first, firstId);
    migrated(tabs.find(tab => tab.targetId === secondId), second, secondId);
    assert.deepEqual(tabs.filter(tab => [firstId, secondId].includes(tab.targetId)).map(tab => tab.targetId), [secondId, firstId]);
    await selected(f.call, secondId);
    assert.equal((await f.call('text')).targetId, secondId);
    assert.equal((await f.call('text', { targetId: first.tabId })).targetId, firstId);
    assert.equal((await f.call('text')).targetId, firstId);
  });

  test(`${driver} replacement snapshots establish fresh refs and delta before ordinary nested effects`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const original = await f.open('snapshot-owner', 'snapshot');
    const background = await f.open('background');
    const options = { selector: '#scope', interactive: true };
    await f.pageFor('snapshot').bringToFront();
    await selected(f.call, background.targetId);
    const before = await f.call('snapshot', { targetId: original.tabId, ...options });
    assert.equal((await f.call('snapshot', options)).newElements, 0);
    const oldPage = f.pageFor('snapshot'); const replacement = await f.externalPage('snapshot');
    const targetId = await rawIdentity(replacement);
    await oldPage.close();
    migrated((await f.call('tabs')).tabs.find(tab => tab.targetId === targetId), original, targetId);
    await selected(f.call, targetId);
    await f.call('text', { targetId: background.tabId });
    // Public foregrounding is an ordinary pointer-input fixture precondition.
    // It must leave the host's remembered selection on the background tab.
    await replacement.bringToFront();
    await selected(f.call, background.targetId);
    const snapshot = await f.call('snapshot', { targetId: original.label, ...options });
    assert.equal(snapshot.targetId, targetId);
    assert.equal(Object.hasOwn(snapshot, 'newElements'), false);
    assert.equal(snapshot.snapshot.includes(' [new]'), false);
    assert.ok(snapshot.refs.every(item => !before.refs.some(old => old.ref === item.ref)));
    const ref = snapshot.refs.find(item => item.name === 'Replacement action').ref;
    const prefix = uniquePrefix(targetId, (await f.call('tabs')).tabs);
    const request = { kind: 'batch', targetId: original.tabId, actions: [
      { kind: 'click', ref, targetId: original.label },
      { kind: 'batch', targetId: prefix, actions: [
        { kind: 'evaluate', targetId, fn: '() => window.clicks' },
      ] },
    ] };
    const input = structuredClone(request);
    const result = await f.call('act', { request });
    assert.equal(result.targetId, targetId);
    assert.equal(result.results[0].ok, true);
    assert.equal(result.results[1].results[0].value, 1);
    assert.deepEqual(request, input);
    assert.equal(await replacement.evaluate(() => window.clicks), 1);
    assert.equal((await f.call('snapshot', options)).newElements, 0);
    assert.equal((await f.call('text')).targetId, targetId);
  });

  test(`${driver} dedicated open claims its own alias and observed close does not recycle identities`, { timeout: 60000 }, async t => {
    const f = await fixture(t, driver); const original = await f.open('retired', 'original');
    await f.pageFor('original').close();
    const opened = await f.open('fresh', 'fresh');
    assert.ok(Number(opened.tabId.slice(1)) > Number(original.tabId.slice(1)));
    assert.equal(opened.label, 'fresh');
    const tabs = (await f.call('tabs')).tabs;
    assert.equal(tabs.some(tab => tab.tabId === original.tabId || tab.label === original.label), false);
    assert.equal((await f.call('text')).targetId, opened.targetId);
    await f.pageFor('fresh').close();
    assert.equal((await f.call('tabs')).tabs.some(tab => tab.tabId === opened.tabId), false);
    const laterPage = await f.externalPage('later');
    const targetId = await rawIdentity(laterPage);
    const later = (await f.call('tabs')).tabs.find(tab => tab.targetId === targetId);
    assert.ok(Number(later.tabId.slice(1)) > Number(opened.tabId.slice(1)));
    assert.equal(Object.hasOwn(later, 'label'), false);
    assert.equal(later.suggestedTargetId, later.tabId);
    assert.equal((await f.call('text', { targetId: later.tabId })).targetId, targetId);
  });

  for (const closeKind of ['dedicated', 'nested act']) {
    test(`${driver} ${closeKind} close retires replacement aliases before the next external page`, { timeout: 60000 }, async t => {
      const f = await fixture(t, driver); const original = await f.open('explicit', 'explicit-before');
      const oldPage = f.pageFor('explicit-before'); const replacement = await f.externalPage('explicit-after');
      const targetId = await rawIdentity(replacement);
      await oldPage.close();
      migrated((await f.call('tabs')).tabs.find(tab => tab.targetId === targetId), original, targetId);
      const result = closeKind === 'dedicated'
        ? await f.call('close', { targetId: original.label })
        : await f.call('act', { targetId: original.tabId, request: { kind: 'batch', actions: [{ kind: 'batch', actions: [{ kind: 'close' }] }] } });
      assert.equal(result.targetId, targetId);
      if (closeKind === 'dedicated') assert.equal(result.closed, true);
      else assert.equal(result.results[0].results[0].closed, true);
      const laterPage = await f.externalPage('explicit-later');
      const laterId = await rawIdentity(laterPage);
      const tabs = (await f.call('tabs')).tabs;
      const later = tabs.find(tab => tab.targetId === laterId);
      assert.ok(Number(later.tabId.slice(1)) > Number(original.tabId.slice(1)));
      assert.equal(Object.hasOwn(later, 'label'), false);
      assert.equal(tabs.some(tab => tab.active), false);
      assert.equal((await f.call('text')).targetId, tabs[0].targetId);
    });
  }

  test(`${driver} stop and reconnect reconcile profile aliases and remembered selection`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver); const original = await f.open('connection-label', 'connection-before');
    const oldPage = f.pageFor('connection-before'); const replacement = await f.externalPage('connection-after');
    const targetId = await rawIdentity(replacement);
    await oldPage.close();
    migrated((await f.call('tabs')).tabs.find(tab => tab.targetId === targetId), original, targetId);
    assert.equal((await f.call('text')).targetId, targetId);
    assert.equal((await f.call('stop')).cleanup_confirmed, true);
    assert.deepEqual((await f.call('status')).tabs, []);
    const restarted = await f.call('start');
    assert.ok(restarted.tabs.length > 0);
    if (driver === 'remote-cdp') {
      const surviving = restarted.tabs.find(tab => tab.targetId === targetId);
      assert.ok(surviving);
      migrated(surviving, original, targetId);
      await selected(f.call, targetId);
      assert.equal((await f.call('text')).targetId, targetId);
      assert.equal((await f.external.inspect()).alive, true);
    } else {
      assert.ok(restarted.tabs.every(tab => !Object.hasOwn(tab, 'label')));
      await selected(f.call, null);
      assert.equal((await f.call('text', { targetId: restarted.tabs[0].targetId })).targetId, restarted.tabs[0].targetId);
    }
  });
}
