import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { devices } from 'playwright-core';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

// Pinned OpenClaw488631c pw-tools-core.state.ts37-59 keeps the device metrics
// owner on an equal-size viewport write;287-315 installs these descriptor fields.
const PHONE = Object.freeze({ width: 390, height: 664, dpr: 3, screen: [390, 844] });
const METRICS = `() => ({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
  screen:[screen.width,screen.height],touch:navigator.maxTouchPoints,
  coarse:matchMedia('(pointer: coarse)').matches,ua:navigator.userAgent})`;

async function processTree(pid) {
  const children = await readFile(`/proc/${pid}/task/${pid}/children`, 'utf8');
  const descendants = await Promise.all(children.trim().split(/\s+/).filter(Boolean).map(async child => {
    try { return await processTree(Number(child)); } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }));
  return [pid, ...descendants.flat()];
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-browser-emulation-resize-'));
  let pageLoads = 0;
  const server = createServer((request, response) => {
    if (request.url === '/favicon.ico') { response.writeHead(204); response.end(); return; }
    pageLoads++;
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Device resize</title><main>Device resize fixture</main>');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = new BrowserHost({ profile: 'emulation-resize', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => {
    try {
      const owned = host.diagnosticPid ? await processTree(host.diagnosticPid) : [];
      assert.equal((await host.close()).cleanup_confirmed, true);
      const deadline = performance.now() + 15000;
      for (const pid of owned) {
        while (true) {
          try { process.kill(pid, 0); } catch (error) { assert.equal(error.code, 'ESRCH'); break; }
          assert.ok(performance.now() < deadline, `owned Chromium process ${pid} exited`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      }
      assert.equal(host.operation, null);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const url = `http://127.0.0.1:${server.address().port}/page`;
  const { targetId } = await call('open', { targetUrl: url });
  const act = request => call('act', { targetId, request });
  return { host, call, act, targetId, url, pageLoads: () => pageLoads };
}

function assertPhone(actual, desktop) {
  assert.deepEqual({ width: actual.width, height: actual.height, dpr: actual.dpr, screen: actual.screen }, PHONE);
  assert.equal(actual.ua, devices['iPhone 13'].userAgent);
  assert.equal(actual.touch, 1);
  assert.equal(actual.coarse, true);
  assert.notEqual(actual.dpr, desktop.dpr);
}

test('same-size standalone and nested resize preserve actual phone metrics; different size and device restoration remain effective', { timeout: 90000 }, async t => {
  const descriptor = devices['iPhone 13'];
  assert.deepEqual(descriptor.viewport, { width: 390, height: 664 });
  assert.deepEqual(descriptor.screen, { width: 390, height: 844 });
  assert.equal(descriptor.deviceScaleFactor, 3);
  assert.equal(descriptor.isMobile, true);
  assert.equal(descriptor.hasTouch, true);
  const f = await fixture(t);
  const desktop = (await f.act({ kind: 'evaluate', fn: METRICS })).value;
  assert.equal(desktop.dpr, 1);
  const applied = await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' });
  const metadata = { generation: f.host.generation, targetId: f.targetId, url: f.url };
  assert.deepEqual(applied, { ...metadata, ok: true, applied: ['device'] });
  const before = (await f.act({ kind: 'evaluate', fn: METRICS })).value;
  assertPhone(before, desktop);
  const pid = f.host.diagnosticPid;

  const request = Object.freeze({ kind: 'resize', width: 390, height: 664 });
  const raw = structuredClone(request);
  const resized = await f.act(request);
  assert.deepEqual(resized, { ...metadata, ok: true });
  assert.equal(resized[RESULT_DISPATCHED], true);
  assert.deepEqual(request, raw);
  const after = (await f.act({ kind: 'evaluate', fn: METRICS })).value;
  assert.deepEqual(after, before);
  assertPhone(after, desktop);

  const batch = { kind: 'batch', actions: [
    { kind: 'batch', actions: [{ kind: 'resize', width: 390, height: 664 }, { kind: 'evaluate', fn: METRICS }] },
    { kind: 'resize', width: 800, height: 600 },
    { kind: 'evaluate', fn: METRICS },
  ] };
  const batchRaw = structuredClone(batch);
  const changed = { ...before, width: 800, height: 600, dpr: desktop.dpr, screen: [800, 600] };
  const result = await f.act(batch);
  assert.deepEqual(result, { ...metadata, results: [
    { ok: true, results: [{ ok: true }, { ok: true, value: before }] },
    { ok: true }, { ok: true, value: changed },
  ] });
  assert.deepEqual(batch, batchRaw);
  assert.deepEqual((await f.act({ kind: 'evaluate', fn: METRICS })).value, changed);

  assert.deepEqual(await f.call('emulate', { targetId: f.targetId, device: 'iPhone 13' }), applied);
  const restored = (await f.act({ kind: 'evaluate', fn: METRICS })).value;
  assert.deepEqual(restored, before);
  assertPhone(restored, desktop);
  assert.equal(f.host.diagnosticPid, pid);
  assert.equal(f.pageLoads(), 1);
});
