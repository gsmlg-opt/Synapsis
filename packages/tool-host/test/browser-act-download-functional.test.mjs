import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

const payload = (name, occurrence) => Buffer.from(`Action attachment ${name} ${occurrence}: 世界 雪😀\n`);

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

async function closeOwned(host) {
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
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'browser-act-download-'));
  const loads = { page: 0, redirects: [], attachments: [] };
  const occurrences = new Map();
  const server = createServer((req, res) => {
    if (req.url === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    if (req.url.startsWith('/redirect/')) {
      const name = req.url.slice('/redirect/'.length);
      loads.redirects.push(name);
      res.writeHead(302, { location: `/attachment/${name}` }); res.end(); return;
    }
    if (req.url.startsWith('/attachment/')) {
      const name = req.url.slice('/attachment/'.length);
      const occurrence = (occurrences.get(name) ?? 0) + 1;
      occurrences.set(name, occurrence);
      loads.attachments.push(name);
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': `attachment; filename="action-${name}.txt"`,
      });
      res.end(payload(name, occurrence)); return;
    }
    loads.page++;
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html><meta charset="utf-8"><title>Retained action page 雪😀</title>
      ${['one', 'two', 'three'].map(name => `<a id="${name}" href="/redirect/${name}">Download ${name} 雪😀</a>`).join(' ')}
      <script>
        window.effects = [];
        for (const link of document.querySelectorAll('a')) {
          link.addEventListener('click', () => window.effects.push(link.dataset.identity));
          link.dataset.identity = link.id;
        }
      </script>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const host = new BrowserHost({
    profile: 'act-download',
    executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium',
    data_dir: join(directory, 'data'), project_root: directory,
    timeout_ms: 15000, max_image_bytes: 196608,
  });
  t.after(async () => {
    try { await closeOwned(host); } finally {
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
  const tab = host.tabs.get(targetId);
  await tab.page.waitForLoadState('load');
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const refs = Object.fromEntries(['one', 'two', 'three'].map(name => {
    const item = snapshot.refs.find(entry => entry.name === `Download ${name} 雪😀` && entry.role === 'link');
    assert.ok(item);
    return [name, item.ref];
  }));
  const custody = {
    document: tab.document, snapshot: tab.snapshot, refs: [...tab.refs], metadata: [...tab.refMetadata],
    downloadListeners: tab.page.listenerCount('download'), closeListeners: tab.page.listenerCount('close'),
  };
  await tab.page.evaluate(() => {
    for (const link of document.querySelectorAll('a')) {
      link.id = `retained-${link.id}`;
      link.textContent = `Retained ${link.dataset.identity}`;
    }
  });
  return { host, directory, loads, call, base, pageUrl, targetId, tab, refs, custody,
    act: request => call('act', { targetId, request }) };
}

async function assertRetained(f, result) {
  assert.equal(result[RESULT_DISPATCHED], true);
  assert.equal(result.targetId, f.targetId);
  assert.equal(result.url, f.pageUrl);
  assert.equal(result.generation, f.host.generation);
  assert.equal(Object.hasOwn(result, 'pageState'), false);
  assert.equal(Object.hasOwn(result, 'pageStateUnavailable'), false);
  assert.equal(f.tab.document, f.custody.document);
  assert.equal(f.tab.snapshot, f.custody.snapshot);
  assert.deepEqual([...f.tab.refs], f.custody.refs);
  assert.deepEqual([...f.tab.refMetadata], f.custody.metadata);
  assert.equal(f.tab.page.url(), f.pageUrl);
  for (const [name, ref] of Object.entries(f.refs)) {
    assert.equal(await f.tab.refs.get(ref).evaluate(element => element.id), `retained-${name}`);
  }
  assert.equal(f.tab.page.listenerCount('download'), f.custody.downloadListeners);
  assert.equal(f.tab.page.listenerCount('close'), f.custody.closeListeners);
  assert.equal(f.host.fileTasks.size, 0);
  assert.equal((await readdir(f.directory, { recursive: true })).some(name => name.includes('.browser-stage-')), false);
}

async function assertReceipt(f, saved, name, occurrence = 1) {
  assert.deepEqual(Object.keys(saved).sort(), ['bytes', 'path', 'sha256', 'suggestedFilename', 'url']);
  assert.equal(saved.url, `${f.base}/attachment/${name}`);
  assert.equal(saved.suggestedFilename, `action-${name}.txt`);
  assert.equal(dirname(saved.path), join(f.directory, '.synapsis', 'browser-files'));
  assert.match(basename(saved.path), /^[0-9a-f-]{36}\./);
  const bytes = payload(name, occurrence);
  assert.deepEqual(await readFile(saved.path), bytes);
  assert.equal(saved.bytes, bytes.length);
  assert.equal(saved.sha256, createHash('sha256').update(bytes).digest('hex'));
}

const mark = value => ({ kind: 'evaluate', fn: `() => ${JSON.stringify(value)}` });

test('standalone retained-ref click reports a redirected attachment and preserves the current document and refs', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.call('act', { targetId: ' docs ', request: { kind: 'click', ref: f.refs.one } });
  assert.equal(result.ok, true);
  assert.equal(result.downloads.length, 1);
  await assertReceipt(f, result.downloads[0], 'one');
  await assertRetained(f, result);
  assert.deepEqual(await f.tab.page.evaluate(() => window.effects), ['one']);
  assert.deepEqual(f.loads, { page: 1, redirects: ['one'], attachments: ['one'] });
});

test('one root batch captures ordered downloads from every nested action while preserving rich ordered outcomes', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const result = await f.act({ kind: 'batch', actions: [
    mark('before'), { kind: 'click', ref: f.refs.one },
    { kind: 'batch', actions: [mark('inside'), { kind: 'click', ref: f.refs.two },
      { kind: 'batch', actions: [{ kind: 'click', ref: f.refs.three }, mark('deep')] }, mark('after-inside')] },
    mark('last'),
  ] });
  assert.deepEqual(result.results, [
    { ok: true, value: 'before' }, { ok: true },
    { ok: true, results: [{ ok: true, value: 'inside' }, { ok: true },
      { ok: true, results: [{ ok: true }, { ok: true, value: 'deep' }] }, { ok: true, value: 'after-inside' }] },
    { ok: true, value: 'last' },
  ]);
  assert.equal(Object.hasOwn(result, 'aborted'), false);
  assert.equal(result.downloads.length, 3);
  for (const [index, name] of ['one', 'two', 'three'].entries()) await assertReceipt(f, result.downloads[index], name);
  assert.equal(new Set(result.downloads.map(saved => saved.path)).size, 3);
  assert.equal((await readdir(join(f.directory, '.synapsis', 'browser-files'))).length, 3);
  await assertRetained(f, result);
  assert.deepEqual(await f.tab.page.evaluate(() => window.effects), ['one', 'two', 'three']);
  assert.deepEqual(f.loads, { page: 1, redirects: ['one', 'two', 'three'], attachments: ['one', 'two', 'three'] });
});

test('evaluate-triggered download keeps its value and a following ordinary evaluation omits downloads', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const text = 'Generated action attachment: 世界 雪😀\n';
  const result = await f.act({ kind: 'evaluate', fn: `() => {
    const url = URL.createObjectURL(new Blob([${JSON.stringify(text)}], {type:'application/octet-stream'}));
    const link = document.createElement('a'); link.href = url; link.download = 'generated-report.txt';
    document.body.appendChild(link); link.click(); link.remove();
    return {started:'blob', url, title:document.title};
  }` });
  assert.equal(result.value.started, 'blob');
  assert.equal(result.value.title, 'Retained action page 雪😀');
  assert.ok(result.value.url.startsWith(`blob:${f.base}/`));
  assert.equal(result.downloads.length, 1);
  const [saved] = result.downloads;
  assert.deepEqual(Object.keys(saved).sort(), ['bytes', 'path', 'sha256', 'suggestedFilename', 'url']);
  assert.equal(saved.url, result.value.url);
  assert.equal(saved.suggestedFilename, 'generated-report.txt');
  assert.equal(dirname(saved.path), join(f.directory, '.synapsis', 'browser-files'));
  assert.match(basename(saved.path), /^[0-9a-f-]{36}\./);
  assert.deepEqual(await readFile(saved.path), Buffer.from(text));
  assert.equal(saved.bytes, Buffer.byteLength(text));
  assert.equal(saved.sha256, createHash('sha256').update(text).digest('hex'));
  await assertRetained(f, result);
  const proof = await f.act({ kind: 'evaluate', fn: '() => ({effects:window.effects, url:location.href})' });
  assert.deepEqual(proof.value, { effects: [], url: f.pageUrl });
  assert.equal(Object.hasOwn(proof, 'downloads'), false);
  await assertRetained(f, proof);
  assert.deepEqual(f.loads, { page: 1, redirects: [], attachments: [] });
});

test('successive captures publish unique occurrences, release listeners and tasks, and retain all files after normal close', { timeout: 60000 }, async t => {
  const f = await fixture(t);
  const saved = [];
  for (const occurrence of [1, 2]) {
    const result = await f.act({ kind: 'click', ref: f.refs.one });
    assert.equal(result.downloads.length, 1);
    await assertReceipt(f, result.downloads[0], 'one', occurrence);
    await assertRetained(f, result);
    saved.push(result.downloads[0]);
  }
  assert.notEqual(saved[0].path, saved[1].path);
  assert.notEqual(saved[0].sha256, saved[1].sha256);
  await closeOwned(f.host);
  for (const [index, receipt] of saved.entries()) await assertReceipt(f, receipt, 'one', index + 1);
  assert.deepEqual(f.loads, { page: 1, redirects: ['one', 'one'], attachments: ['one', 'one'] });
  assert.equal((await readdir(join(f.directory, '.synapsis', 'browser-files'))).length, 2);
  assert.equal(f.host.fileTasks.size, 0);
  assert.equal((await readdir(f.directory, { recursive: true })).some(name => name.includes('.browser-stage-')), false);
});
