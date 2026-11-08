import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

async function fixture(t) {
  const server = createServer((req, res) => {
    if (req.url === '/data') { res.setHeader('Content-Type', 'application/json'); res.end('{"ordinary":true}'); return; }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Observation fixture</title>
      <aside>Navigation</aside><main><h1>Visible observation</h1><p id="prose">Hello 世界 🌍</p><p hidden>Hidden prose</p></main>
      <button id="confirm" onclick="window.confirmed=confirm('Keep changes?')">Confirm</button>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-observation-functional-'));
  const host = new BrowserHost({ profile: 'functional', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, timeout_ms: 15000, max_image_bytes: 196608, project_root: directory });
  t.after(async () => {
    const pid = host.diagnosticPid;
    assert.equal((await host.close()).cleanup_confirmed, true);
    if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const url = `http://127.0.0.1:${server.address().port}`;
  const { targetId } = await call('open', { targetUrl: url });
  const act = request => call('act', { targetId, request });
  return { host, call, targetId, act, url };
}

test('per-tab observation histories include ordinary page events, filtering, limits and clear', { timeout: 60000 }, async t => {
  const { call, targetId, act, url } = await fixture(t);
  await act({ kind: 'evaluate', fn: `async () => { console.log('Observation info'); console.warn('Observation warning'); console.error('Observation error'); await fetch('/data').then(r=>r.json()); setTimeout(()=>{throw new Error('Ordinary observed page exception')},0); return true; }` });
  await act({ kind: 'wait', timeMs: 50 });
  const logs = await call('console', { targetId, level: 'warn' });
  assert.deepEqual(logs.messages.map(m => m.text), ['Observation warning', 'Observation error']);
  assert.equal(logs.messages[0].type, 'warning');
  assert.equal(typeof logs.messages[0].timestamp, 'string');
  assert.equal(typeof logs.messages[0].location.lineNumber, 'number');
  assert.equal(logs.truncated, false);
  const limited = await call('console', { targetId, limit: 1 });
  assert.equal(limited.returned, 1);
  assert.equal(limited.total, 3);
  assert.equal(limited.truncated, true);
  const requests = await call('requests', { targetId, filter: '/data', clear: true });
  assert.equal(requests.requests.length, 1);
  assert.equal(requests.requests[0].url, `${url}/data`);
  assert.equal(requests.requests[0].method, 'GET');
  assert.equal(requests.requests[0].resourceType, 'fetch');
  assert.equal(requests.requests[0].status, 200);
  assert.equal(requests.requests[0].ok, true);
  assert.equal(requests.cleared, true);
  assert.equal((await call('requests', { targetId })).requests.length, 0);
  const errors = await call('errors', { targetId, clear: true });
  assert.equal(errors.errors.length, 1);
  assert.equal(errors.errors[0].message, 'Ordinary observed page exception');
  assert.equal(errors.errors[0].name, 'Error');
  assert.match(errors.errors[0].stack, /Ordinary observed page exception/);
  assert.equal((await call('errors', { targetId })).errors.length, 0);
  const other = await call('open', { targetUrl: url });
  assert.equal((await call('console', { targetId: other.targetId })).messages.length, 0);
  assert.equal((await call('console', { targetId })).messages.length, 3);
  await call('console', { targetId, clear: true });
  assert.equal((await call('console', { targetId })).messages.length, 0);
});

test('text reads rendered prose and explicitly reports ordinary shaping truncation', { timeout: 60000 }, async t => {
  const { call, targetId } = await fixture(t);
  const full = await call('text', { targetId });
  assert.equal(full.ok, true);
  assert.match(full.text, /Visible observation/);
  assert.match(full.text, /Hello 世界 🌍/);
  assert.equal(full.text.includes('Hidden prose'), false);
  assert.equal(full.text.includes('Navigation'), false);
  assert.equal(full.truncated, false);
  assert.equal((await call('text', { targetId, maxChars: 200000 })).text, full.text);
  const selected = await call('text', { targetId, selector: '#prose', maxChars: 8 });
  assert.equal(selected.text, 'Hello 世界');
  assert.equal(selected.truncated, true);
  assert.ok(Buffer.byteLength(selected.text) <= 262144);
});

test('emulation applies device, media, timezone and locale in order to the selected tab', { timeout: 60000 }, async t => {
  const { call, targetId, act, url } = await fixture(t);
  const other = await call('open', { targetUrl: url });
  const result = await call('emulate', { targetId, device: 'iPhone 13', colorScheme: 'dark', timezoneId: 'Asia/Tokyo', locale: 'fr-FR' });
  assert.deepEqual(result.applied, ['device', 'colorScheme', 'timezoneId', 'locale']);
  assert.equal(result.targetId, targetId);
  const observe = () => act({ kind: 'evaluate', fn: `() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,mobile:matchMedia('(pointer: coarse)').matches,dark:matchMedia('(prefers-color-scheme: dark)').matches,timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,locale:Intl.DateTimeFormat().resolvedOptions().locale,ua:navigator.userAgent})` });
  const observed = (await observe()).value;
  assert.deepEqual({ width: observed.width, height: observed.height, dpr: observed.dpr, screen: observed.screen }, { width: 390, height: 664, dpr: 3, screen: [390, 844] });
  assert.ok(observed.touch > 0);
  assert.equal(observed.mobile, true);
  assert.equal(observed.dark, true);
  assert.equal(observed.timezone, 'Asia/Tokyo');
  assert.equal(observed.locale, 'fr-FR');
  assert.match(observed.ua, /iPhone/);
  await act({ kind: 'evaluate', fn: '() => { document.body.style.minHeight = "1200px"; }' });
  const screenshot = await call('screenshot', { targetId, fullPage: true });
  assert.equal(screenshot.content[1].data.media_type, 'image/png');
  const afterScreenshot = (await observe()).value;
  t.diagnostic(`emulation before capture: ${JSON.stringify(observed)}`);
  t.diagnostic(`emulation after full-page capture: ${JSON.stringify(afterScreenshot)}`);
  assert.deepEqual(afterScreenshot, observed);
  const otherState = await call('act', { targetId: other.targetId, request: { kind: 'evaluate', fn: '() => ({ua:navigator.userAgent,dpr:devicePixelRatio})' } });
  assert.equal(otherState.value.ua.includes('iPhone'), false);
  assert.notEqual(otherState.value.dpr, 3);
  await call('navigate', { targetId, targetUrl: url });
  assert.equal((await observe()).value.timezone, 'Asia/Tokyo');
  await act({ kind: 'resize', width: 800, height: 600 });
  await call('emulate', { targetId, device: 'iPhone 13', colorScheme: 'light' });
  assert.equal((await observe()).value.dpr, 3);
  assert.equal((await observe()).value.width, 390);
  assert.equal((await observe()).value.dark, false);
});

test('dialogs support one-shot prearming and current dialog intervention across serialized calls', { timeout: 60000 }, async t => {
  const { call, targetId, act } = await fixture(t);
  assert.equal((await call('dialog', { targetId, accept: true, promptText: 'Ada', timeoutMs: 10000 })).armed, true);
  assert.equal((await act({ kind: 'evaluate', fn: `() => window.answer=prompt('Your name?', 'default')` })).value, 'Ada');
  const opened = await act({ kind: 'click', selector: '#confirm' });
  assert.equal(opened.dialogPending, true);
  assert.equal(opened[RESULT_DISPATCHED], true);
  const pending = opened.browserState.dialogs.pending;
  assert.equal(pending.length, 1);
  assert.equal(pending[0].type, 'confirm');
  assert.equal(pending[0].message, 'Keep changes?');
  const listed = (await call('tabs')).tabs.find(tab => tab.targetId === targetId);
  assert.equal(listed.targetId, targetId);
  assert.equal(listed.titleUnavailable, 'dialog_pending');
  assert.equal(listed.browserState.dialogs.pending[0].id, pending[0].id);
  const handled = await call('dialog', { targetId, dialogId: pending[0].id, accept: false });
  assert.equal(handled.ok, true);
  assert.equal(handled.armed, false);
  assert.equal(handled.browserState.dialogs.pending.length, 0);
  assert.equal(handled.browserState.dialogs.recent.at(-1).closedBy, 'handled');
  assert.equal((await act({ kind: 'evaluate', fn: '() => window.confirmed' })).value, false);
  await call('dialog', { targetId, accept: true, timeoutMs: 10000 });
  assert.equal((await act({ kind: 'evaluate', fn: '() => confirm("Continue?")' })).value, true);
  const next = await act({ kind: 'evaluate', fn: '() => window.secondAnswer=prompt("Second?", "second")' });
  assert.equal(next.dialogPending, true);
  await call('dialog', { targetId, dialogId: next.browserState.dialogs.pending[0].id, accept: true, promptText: 'Grace' });
  assert.equal((await act({ kind: 'evaluate', fn: '() => window.secondAnswer' })).value, 'Grace');
  const suspended = await act({ kind: 'evaluate', fn: 'async () => { window.accepted = confirm("Finish later?"); await new Promise(resolve => window.finish = resolve); window.finished = true; }' });
  assert.equal(suspended.dialogPending, true);
  assert.equal(suspended.browserState.pendingActions.length, 1);
  assert.equal(suspended.browserState.pendingActionLimit, 8);
  assert.ok(Date.parse(suspended.browserState.pendingActions[0].deadline) > Date.now());
  const response = await call('dialog', { targetId, dialogId: suspended.browserState.dialogs.pending[0].id, accept: true });
  assert.equal(response.ok, true);
  assert.equal(response.browserState.pendingActions.length, 1);
  assert.equal((await act({ kind: 'evaluate', fn: '() => { window.finish(); return window.accepted; }' })).value, true);
  assert.equal((await act({ kind: 'evaluate', fn: '() => window.finished' })).value, true);
  assert.equal((await call('dialog', { targetId, accept: true })).browserState.pendingActions.length, 0);
});
