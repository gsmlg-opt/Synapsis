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
const html = '<!doctype html><title>CDP identity fixture</title><button onclick="window.clicks=(window.clicks||0)+1">Identity action</button><p>Identity content</p>';

async function within(promise) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('CDP identity fixture deadline')), timeoutMs); })]); }
  finally { clearTimeout(timer); }
}

// Read the browser's identity independently through the public Playwright API.
async function rawIdentity(page) {
  const session = await within(page.context().newCDPSession(page));
  try {
    const { targetInfo } = await within(session.send('Target.getTargetInfo'));
    assert.equal(targetInfo.type, 'page');
    assert.ok(targetInfo.targetId.length > 0);
    return targetInfo.targetId;
  } finally { await within(session.detach()); }
}

async function fixture(t, driver) {
  const server = createServer((_request, response) => { response.setHeader('Content-Type', 'text/html'); response.end(html); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-cdp-targets-'));
  const url = `http://127.0.0.1:${server.address().port}/`;
  let host; let external;
  t.after(async () => {
    try { if (host) assert.equal((await host.close()).cleanup_confirmed, true); }
    finally {
      try { if (external) await external.close(); }
      finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); }
    }
  });
  const common = { profile: 'cdp-identities', driver, timeout_ms: timeoutMs, max_image_bytes: 196608, project_root: directory };
  if (driver === 'remote-cdp') {
    external = await startExternalBrowser({ executable, directory, initialUrl: url });
    host = new BrowserHost({ ...common, endpoint: external.endpoint });
  } else host = new BrowserHost({ ...common, executable, data_dir: directory });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs });
  const started = await call('start');
  const context = host.browser.contexts()[0];
  const open = async (label, path = '/') => {
    const before = new Set(context.pages());
    const tab = await call('open', { targetUrl: new URL(path, url).href, ...(label === undefined ? {} : { label }) });
    const page = context.pages().find(candidate => !before.has(candidate));
    assert.ok(page, 'ordinary open exposes its public Page');
    return { tab, page, raw: await rawIdentity(page) };
  };
  const evaluate = async (targetId, fn) => (await call('act', { targetId, request: { kind: 'evaluate', fn } })).value;
  return { host, external, call, open, evaluate, started, context, url };
}

function metadata(tab, raw, label) {
  assert.equal(tab.targetId, raw);
  assert.match(tab.tabId, /^t[1-9]\d*$/);
  assert.notEqual(tab.targetId, tab.tabId);
  assert.equal(tab.suggestedTargetId, label ?? tab.tabId);
  assert.equal(tab.label, label);
}

function uniquePrefix(raw, tabs) {
  for (let size = 4; size < raw.length; size++) {
    const prefix = raw.slice(0, size);
    if (tabs.filter(tab => tab.targetId.toLowerCase().startsWith(prefix.toLowerCase())).length === 1) {
      return [...prefix].map((character, index) => index % 2 ? character.toUpperCase() : character.toLowerCase()).join('');
    }
  }
  assert.fail('ordinary browser targets should provide a unique shortened raw ID');
}

for (const driver of ['managed-host', 'remote-cdp']) {
  test(`${driver} publishes actual CDP identities with separate exact friendly aliases`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver);
    for (const page of f.context.pages()) {
      const raw = await rawIdentity(page);
      metadata(f.started.tabs.find(tab => tab.targetId === raw) ?? {}, raw);
    }
    const first = await f.open('docs'); metadata(first.tab, first.raw, 'docs');
    const second = await f.open(); metadata(second.tab, second.raw);
    const tabs = (await f.call('tabs')).tabs;
    for (const action of ['status', 'doctor']) {
      const result = await f.call(action);
      metadata(result.tabs.find(tab => tab.tabId === first.tab.tabId), first.raw, 'docs');
      metadata(result.tabs.find(tab => tab.tabId === second.tab.tabId), second.raw);
    }
    const prefix = uniquePrefix(first.raw, tabs);
    for (const reference of [first.raw, first.raw.toLowerCase(), first.tab.tabId, ' docs ', prefix]) {
      assert.equal((await f.call('text', { targetId: reference })).targetId, first.raw);
    }
    assert.equal((await f.call('focus', { targetId: first.tab.tabId })).targetId, first.raw);
    assert.equal((await f.call('text')).targetId, first.raw);
    const snapshot = await f.call('snapshot', { targetId: prefix });
    assert.equal(snapshot.targetId, first.raw);
    const repeated = await f.call('snapshot', { targetId: first.tab.tabId });
    assert.equal(repeated.targetId, first.raw); assert.equal(repeated.newElements, 0);
    const ref = repeated.refs.find(item => item.name === 'Identity action').ref;
    await f.call('act', { targetId: first.raw, request: { kind: 'click', ref } });
    assert.equal(await f.evaluate(first.tab.tabId, '() => window.clicks'), 1);
    assert.equal((await f.call('screenshot', { targetId: 'docs', ref })).targetId, first.raw);
    assert.equal((await f.call('snapshot', { targetId: first.tab.tabId, mode: 'efficient' })).targetId, first.raw);

    // Exact labels win before raw-prefix fallback; duplicate exact aliases for
    // one page still select that one page.
    const exact = await f.open(prefix); metadata(exact.tab, exact.raw, prefix);
    assert.equal((await f.call('text', { targetId: prefix })).targetId, exact.raw);
    const nextAlias = `t${Number(exact.tab.tabId.slice(1)) + 1}`;
    const deduplicated = await f.open(nextAlias); metadata(deduplicated.tab, deduplicated.raw, nextAlias);
    assert.equal(deduplicated.tab.tabId, nextAlias);
    assert.equal((await f.call('text', { targetId: nextAlias })).targetId, deduplicated.raw);
  });

  test(`${driver} canonicalizes the bounded act tree across raw IDs aliases and prefixes`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver); const opened = await f.open('batch');
    metadata(opened.tab, opened.raw, 'batch');
    const prefix = uniquePrefix(opened.raw, (await f.call('tabs')).tabs);
    const request = { kind: 'batch', targetId: opened.tab.tabId, actions: [
      { kind: 'evaluate', targetId: opened.raw, fn: "() => {window.order=['raw'];return 1}" },
      { kind: 'batch', targetId: 'batch', actions: [
        { kind: 'evaluate', targetId: prefix, fn: "() => {window.order.push('prefix');return 2}" },
        { kind: 'evaluate', targetId: ` ${opened.tab.tabId} `, fn: "() => {window.order.push('tab');return 3}" },
      ] },
    ] };
    const original = structuredClone(request);
    const result = await f.call('act', { targetId: prefix, request });
    assert.equal(result.targetId, opened.raw); assert.equal(result.results[0].ok, true); assert.equal(result.results[1].ok, true);
    assert.deepEqual(request, original);
    const flat = { kind: 'batch', targetId: opened.raw, actions: [{ kind: 'evaluate', targetId: 'batch', fn: "() => {window.order.push('flat');return true}" }] };
    const flatOriginal = structuredClone(flat);
    assert.equal((await f.call('act', flat)).results[0].ok, true); assert.deepEqual(flat, flatOriginal);
    assert.deepEqual(await f.evaluate(prefix, '() => window.order'), ['raw', 'prefix', 'tab', 'flat']);
  });

  test(`${driver} adopts popup identities and retains target identity through navigation and ordinary close`, { timeout: 90000 }, async t => {
    const f = await fixture(t, driver); const opened = await f.open('opener');
    metadata(opened.tab, opened.raw, 'opener');
    await f.evaluate('opener', '() => {window.open("/popup", "ordinary-popup");return true}');
    const popup = await within((async () => {
      for (const page of f.context.pages()) if (await page.opener() === opened.page) return page;
      return f.context.waitForEvent('page', { timeout: timeoutMs, predicate: async page => await page.opener() === opened.page });
    })());
    await popup.waitForLoadState('domcontentloaded', { timeout: timeoutMs });
    const raw = await rawIdentity(popup);
    const adopted = (await f.call('tabs')).tabs.find(tab => tab.targetId === raw);
    assert.ok(adopted); metadata(adopted, raw);
    assert.equal((await f.call('focus', { targetId: adopted.tabId })).targetId, raw);
    assert.equal((await f.call('text')).targetId, raw);
    const navigated = await f.call('navigate', { targetId: 'opener', targetUrl: `${f.url}next` });
    assert.equal(navigated.targetId, opened.raw); assert.equal(await rawIdentity(opened.page), opened.raw);
    metadata((await f.call('tabs')).tabs.find(tab => tab.tabId === opened.tab.tabId), opened.raw, 'opener');
    assert.equal((await f.call('close', { targetId: adopted.tabId })).targetId, raw);
    const next = await f.open('next'); metadata(next.tab, next.raw, 'next');
    assert.notEqual(next.raw, raw); assert.ok(Number(next.tab.tabId.slice(1)) > Number(adopted.tabId.slice(1)));
    assert.equal((await f.call('tabs')).tabs.some(tab => tab.targetId === raw), false);
  });
}

test('remote reconnect keeps raw CDP identity and renews connection-local aliases', { timeout: 90000 }, async t => {
  const f = await fixture(t, 'remote-cdp'); const opened = await f.open('remote');
  metadata(opened.tab, opened.raw, 'remote');
  await f.evaluate('remote', '() => {window.retainedIdentity=7;return true}');
  assert.equal((await f.call('stop')).cleanup_confirmed, true);
  assert.deepEqual((await f.call('status')).tabs, []);
  const restarted = await f.call('start');
  const reconnected = restarted.tabs.find(tab => tab.targetId === opened.raw);
  assert.ok(reconnected); metadata(reconnected, opened.raw);
  assert.ok(Number(reconnected.tabId.slice(1)) > Number(opened.tab.tabId.slice(1)));
  const retained = (await f.call('tabs')).tabs.find(tab => tab.targetId === opened.raw);
  assert.equal(retained.tabId, reconnected.tabId);
  assert.equal(await f.evaluate(reconnected.tabId, '() => window.retainedIdentity'), 7);
  const rawIds = await Promise.all(f.host.browser.contexts()[0].pages().map(page => rawIdentity(page)));
  assert.ok(rawIds.includes(opened.raw));
  assert.equal((await f.call('text', { targetId: opened.raw })).targetId, opened.raw);
});
