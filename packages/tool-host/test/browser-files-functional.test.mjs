import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost, RESULT_DISPATCHED } from '../src/browser/host.mjs';

const payload = Buffer.from('Ordinary browser download 世界\n');
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'browser-files-helper-fixture-'));
  const project = join(directory, 'project');
  await mkdir(project);
  const server = createServer((req, res) => {
    if (req.url === '/download') {
      res.writeHead(200, { 'content-type': 'text/plain', 'content-disposition': 'attachment; filename="report.txt"' });
      res.end(payload); return;
    }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><title>Browser files</title><h1>Ordinary file fixture</h1>
      <a href="/download" download="report.txt">Download report</a>
      <input type="file" id="direct" aria-label="Direct file">
      <input type="file" id="chooser" aria-label="Chooser file" style="display:none">
      <button onclick="document.querySelector('#chooser').click()">Choose file</button>`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const host = new BrowserHost({ profile: 'functional', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: join(directory, 'data'), project_root: project, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => { const pid = host.diagnosticPid; assert.equal((await host.close()).cleanup_confirmed, true); if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' }); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}` });
  const act = request => call('act', { targetId, request });
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const ref = name => { const value = snapshot.refs.find(item => item.name === name)?.ref; assert.ok(value, name); return value; };
  return { host, project, call, act, targetId, ref };
}
async function receipt(result, expected) {
  assert.equal(result.ok, true); assert.equal(result[RESULT_DISPATCHED], true);
  const bytes = await readFile(result.path);
  if (expected) assert.deepEqual(bytes, expected);
  assert.equal(result.bytes, bytes.length);
  assert.equal(result.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.equal(Object.hasOwn(result, 'content'), false);
  return bytes;
}

test('PDF and downloads return durable file receipts and leave no owned staging after browser cleanup', { timeout: 60000 }, async t => {
  const { host, project, call, act, targetId, ref } = await fixture(t);
  const implicit = await call('pdf', { targetId });
  assert.match((await receipt(implicit)).subarray(0, 8).toString(), /^%PDF-/);
  assert.equal(implicit.mimeType, 'application/pdf');
  assert.equal(implicit.path.startsWith(join(project, '.synapsis', 'browser-files')), true);
  const explicit = await call('pdf', { path: join(project, 'ordinary.pdf') });
  assert.match((await receipt(explicit)).subarray(0, 8).toString(), /^%PDF-/);
  const clicked = await call('download', { targetId, ref: ref('Download report'), path: join(project, 'report.txt') });
  await receipt(clicked, payload); assert.equal(clicked.suggestedFilename, 'report.txt');
  await act({ kind: 'evaluate', fn: `() => { setTimeout(() => document.querySelector('a').click(), 200); return true; }` });
  const delayed = await call('waitfordownload', { targetId });
  await receipt(delayed, payload); assert.equal(delayed.suggestedFilename, 'report.txt');
  const pid = host.diagnosticPid;
  assert.equal((await host.close()).cleanup_confirmed, true);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  for (const result of [implicit, explicit, clicked, delayed]) await receipt(result);
  assert.equal((await readdir(project, { recursive: true })).some(name => name.includes('.browser-stage-')), false);
});

test('direct, atomic and passive uploads expose bounded per-tab completion and preserve file contents', { timeout: 60000 }, async t => {
  const { host, project, call, act, targetId, ref } = await fixture(t);
  const first = join(project, 'first.txt'), second = join(project, 'second.txt');
  await writeFile(first, 'First file 世界'); await writeFile(second, 'Second file');
  const observe = selector => act({ kind: 'evaluate', fn: `async () => { const f=document.querySelector(${JSON.stringify(selector)}).files[0]; return {name:f.name,text:await f.text()}; }` });
  const direct = await call('upload', { targetId, inputRef: ref('Direct file'), paths: [first] });
  assert.equal(direct.ok, true); assert.equal(direct.armed, false); assert.equal(direct.browserState.upload.current.state, 'completed');
  assert.deepEqual((await observe('#direct')).value, { name: 'first.txt', text: 'First file 世界' });
  await call('upload', { targetId, element: '#direct', paths: [second] });
  assert.equal((await observe('#direct')).value.text, 'Second file');
  const atomic = await call('upload', { targetId, ref: ref('Choose file'), paths: [first] });
  assert.equal(atomic.armed, false); assert.equal(atomic.browserState.upload.current.state, 'completed');
  assert.equal((await observe('#chooser')).value.text, 'First file 世界');
  const passive = await call('upload', { targetId, paths: [first], timeoutMs: 10000 });
  assert.equal(passive.armed, true); assert.equal(passive.browserState.upload.current.state, 'armed');
  const replacement = await call('upload', { targetId, paths: [second], timeoutMs: 10000 });
  assert.equal(replacement.armed, true); assert.equal(replacement.browserState.upload.recent.at(-1).state, 'superseded');
  const status = await call('status');
  assert.equal(status.tabs.find(tab => tab.targetId === targetId).browserState.upload.current.id, replacement.uploadId);
  await act({ kind: 'evaluate', fn: `() => { window.passiveDone = new Promise(resolve => document.querySelector('#chooser').addEventListener('change', () => resolve(true), {once:true})); return true; }` });
  await act({ kind: 'click', ref: ref('Choose file') });
  assert.equal((await act({ kind: 'evaluate', fn: 'async () => await window.passiveDone' })).value, true);
  assert.equal((await observe('#chooser')).value.text, 'Second file');
  const observed = (await call('tabs')).tabs.find(tab => tab.targetId === targetId).browserState.upload;
  assert.equal(observed.current.state, 'completed'); assert.equal(observed.current.id, replacement.uploadId);
  const other = await call('open');
  assert.equal((await call('status')).tabs.find(tab => tab.targetId === other.targetId).browserState.upload.current, null);
  await call('upload', { targetId: other.targetId, paths: [first], timeoutMs: 10000 });
  await call('close', { targetId: other.targetId });
  assert.equal(host.fileTasks.size, 0);
  await call('upload', { targetId, paths: [first], timeoutMs: 10000 });
  const pid = host.diagnosticPid;
  assert.equal((await host.close()).cleanup_confirmed, true);
  assert.equal(host.fileTasks.size, 0);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});
