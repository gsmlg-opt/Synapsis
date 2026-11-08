import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

const payload = occurrence => Buffer.from(`Navigation attachment ${occurrence}: 世界 雪😀\n`);

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'browser-navigation-download-'));
  const loads = { page: 0, redirect: 0, attachment: 0 };
  const server = createServer((req, res) => {
    if (req.url === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    if (req.url === '/redirect') {
      loads.redirect++;
      res.writeHead(302, { location: '/attachment' }); res.end(); return;
    }
    if (req.url === '/attachment') {
      loads.attachment++;
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="navigation-report.txt"',
      });
      res.end(payload(loads.attachment)); return;
    }
    loads.page++;
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html><meta charset="utf-8"><title>Retained download page 雪😀</title>
      <button id="original" onclick="window.originalClicks=(window.originalClicks||0)+1">Original control 雪😀</button>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const host = new BrowserHost({
    profile: 'navigation-download',
    executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium',
    data_dir: join(directory, 'data'), project_root: directory,
    timeout_ms: 15000, max_image_bytes: 196608,
  });
  t.after(async () => {
    try {
      const pid = host.diagnosticPid;
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const base = `http://127.0.0.1:${server.address().port}`;
  const pageUrl = `${base}/page`;
  const { targetId } = await call('open', { targetUrl: pageUrl, label: ' docs ' });
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const ref = snapshot.refs.find(item => item.name === 'Original control 雪😀')?.ref;
  assert.ok(ref);
  const tab = host.tabs.get(targetId);
  return { host, directory, loads, call, base, pageUrl, targetId, snapshot, ref, tab };
}

async function navigateDownload(f, targetUrl, occurrence, targetId = f.targetId) {
  const before = {
    document: f.tab.document, snapshot: f.tab.snapshot,
    refs: [...f.tab.refs], metadata: [...f.tab.refMetadata],
    downloadListeners: f.tab.page.listenerCount('download'),
    closeListeners: f.tab.page.listenerCount('close'),
  };
  const result = await f.call('navigate', { targetId, targetUrl });
  assert.equal(result[RESULT_DISPATCHED], true);
  assert.equal(result.targetId, f.targetId);
  assert.equal(result.url, `${f.base}/attachment`);
  assert.equal(result.generation, f.host.generation);
  assert.equal(result.documentGeneration, before.document);
  assert.equal(Object.hasOwn(result, 'pageState'), false);
  assert.equal(Object.hasOwn(result, 'pageStateUnavailable'), false);
  assert.equal(Object.hasOwn(result, 'content'), false);
  assert.deepEqual(Object.keys(result.download).sort(), ['bytes', 'path', 'sha256', 'suggestedFilename', 'url']);
  assert.equal(result.download.url, `${f.base}/attachment`);
  assert.equal(result.download.suggestedFilename, 'navigation-report.txt');
  assert.equal(dirname(result.download.path), join(f.directory, '.synapsis', 'browser-files'));
  assert.match(basename(result.download.path), /^[0-9a-f-]{36}\./);
  const bytes = await readFile(result.download.path);
  assert.deepEqual(bytes, payload(occurrence));
  assert.equal(result.download.bytes, bytes.length);
  assert.equal(result.download.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.equal(f.tab.document, before.document);
  assert.equal(f.tab.snapshot, before.snapshot);
  assert.deepEqual([...f.tab.refs], before.refs);
  assert.deepEqual([...f.tab.refMetadata], before.metadata);
  assert.equal(f.tab.page.url(), f.pageUrl);
  assert.equal(f.tab.page.listenerCount('download'), before.downloadListeners);
  assert.equal(f.tab.page.listenerCount('close'), before.closeListeners);
  assert.equal(f.host.fileTasks.size, 0);
  assert.equal((await readdir(f.directory, { recursive: true })).some(name => name.includes('.browser-stage-')), false);
  return result.download;
}

async function clickOriginal(f, clicks) {
  assert.equal((await f.call('act', { targetId: f.targetId, request: { kind: 'click', ref: f.ref } })).ok, true);
  const proof = await f.call('act', {
    targetId: f.targetId,
    request: { kind: 'evaluate', fn: '() => ({clicks:window.originalClicks,title:document.title,url:location.href})' },
  });
  assert.deepEqual(proof.value, { clicks, title: 'Retained download page 雪😀', url: f.pageUrl });
}

for (const [route, selection] of [['attachment', 'canonical'], ['redirect', 'label']]) {
  test(`normal ${route} navigation publishes actual attachment and retains the original ${selection} target refs`, { timeout: 60000 }, async t => {
    const f = await fixture(t);
    const saved = await navigateDownload(f, `${f.base}/${route}`, 1, selection === 'label' ? ' docs ' : f.targetId);
    await clickOriginal(f, 1);
    assert.deepEqual(f.loads, { page: 1, redirect: route === 'redirect' ? 1 : 0, attachment: 1 });
    const pid = f.host.diagnosticPid;
    assert.equal((await f.host.close()).cleanup_confirmed, true);
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    assert.deepEqual(await readFile(saved.path), payload(1));
    assert.equal((await readdir(f.directory, { recursive: true })).some(name => name.includes('.browser-stage-')), false);
  });
}

test('successive normal attachment navigations publish distinct exact occurrences without HTTP replay or listener growth', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const first = await navigateDownload(f, `${f.base}/attachment`, 1);
  await clickOriginal(f, 1);
  const second = await navigateDownload(f, `${f.base}/attachment`, 2, 'docs');
  await clickOriginal(f, 2);
  assert.notEqual(second.path, first.path);
  assert.notEqual(second.sha256, first.sha256);
  assert.deepEqual(await readFile(first.path), payload(1));
  assert.deepEqual(await readFile(second.path), payload(2));
  assert.deepEqual(f.loads, { page: 1, redirect: 0, attachment: 2 });
});
