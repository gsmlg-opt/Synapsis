import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// Independent ordinary builtin-stat expectations. No permission, link, failure,
// cancellation, race or output-budget qualification belongs to these cases.
const helper = fileURLToPath(new URL('../../../apps/synapsis_core/priv/filesystem_metadata/stdio.mjs', import.meta.url));
const runtime = {
  node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
  icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch,
};

async function invoke(request, args = []) {
  const child = spawn(process.execPath, [helper, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
  const output = [], errors = [];
  child.stdout.on('data', chunk => output.push(chunk));
  child.stderr.on('data', chunk => errors.push(chunk));
  const closed = once(child, 'close');
  child.stdin.end(JSON.stringify(request) + '\n');
  const [status, signal] = await closed;
  assert.equal(status, 0);
  assert.equal(signal, null);
  assert.equal(child.exitCode, 0);
  assert.equal(Buffer.concat(errors).toString(), '');
  const bytes = Buffer.concat(output).toString();
  assert.equal(bytes.trim().split('\n').length, 1);
  const envelope = JSON.parse(bytes);
  assert.equal(envelope.protocol, 1);
  assert.equal(envelope.pid, child.pid);
  assert.deepEqual(envelope.runtime, runtime);
  assert.deepEqual(Object.keys(envelope).sort(), ['pid', 'protocol', 'result', 'runtime']);
  if (process.platform === 'linux') assert.equal(existsSync(`/proc/${child.pid}`), false);
  return envelope.result;
}

test('ordinary precise metadata retains actual fractional mtimes and source Unicode ordering', async t => {
  const root = await mkdtemp(join(tmpdir(), 'synapsis-workshop295-stat-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'examples'));
  await mkdir(join(root, 'templates'));
  const contents = {
    'SKILL.md': '---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\nInspect the release.\n',
    'examples/雪.md': 'Example café 雪 😀.\n',
    'templates/café.txt': 'Release: <version>\r\nResult: <result>\n',
  };
  for (const [file, content] of Object.entries(contents)) await writeFile(join(root, file), content);
  await utimes(join(root, 'SKILL.md'), 1_794_000_000.125, 1_794_000_000.125);
  await utimes(join(root, 'examples/雪.md'), 1_794_000_001.875, 1_794_000_001.875);
  await utimes(join(root, 'templates/café.txt'), 1_794_000_001.5, 1_794_000_001.5);
  const stats = await Promise.all(Object.keys(contents).map(file => stat(join(root, file))));
  const mtime = Math.trunc(Math.max(...stats.map(value => value.mtimeMs)));
  assert.notEqual(mtime % 1000, 0, 'ordinary fixture actually contains millisecond metadata');
  assert.deepEqual(await invoke({ root, files: ['templates/café.txt', 'examples/雪.md', 'SKILL.md'],
    names: ['zeta', 'éclair', 'alpha', 'alpha'] }, ['--timeout-ms', '5000']), {
    files: ['SKILL.md', 'examples/雪.md', 'templates/café.txt'],
    sizeBytes: stats.reduce((sum, value) => sum + value.size, 0), updatedAtMs: mtime,
    names: ['alpha', 'alpha', 'éclair', 'zeta'],
  });
  for (const [file, content] of Object.entries(contents)) assert.equal(await readFile(join(root, file), 'utf8'), content);
});

test('a fresh ordinary capture observes rewritten file facts with the default helper timeout', async t => {
  const root = await mkdtemp(join(tmpdir(), 'synapsis-workshop295-reopen-stat-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const file = join(root, 'SKILL.md');
  await writeFile(file, 'Initial reviewed procedure.\n');
  await utimes(file, 1_794_000_002.25, 1_794_000_002.25);
  const first = await stat(file);
  assert.deepEqual(await invoke({ root, files: ['SKILL.md'] }), {
    files: ['SKILL.md'], sizeBytes: first.size, updatedAtMs: Math.trunc(first.mtimeMs), names: [],
  });
  const revised = 'Revised procedure café 雪 😀.\nRecord the complete result.\n';
  await writeFile(file, revised);
  await utimes(file, 1_794_000_003.625, 1_794_000_003.625);
  const second = await stat(file);
  assert.notEqual(second.size, first.size);
  assert.ok(second.mtimeMs > first.mtimeMs);
  assert.deepEqual(await invoke({ root, files: ['SKILL.md'] }), {
    files: ['SKILL.md'], sizeBytes: second.size, updatedAtMs: Math.trunc(second.mtimeMs), names: [],
  });
  assert.equal(await readFile(file, 'utf8'), revised);
});
