import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync, mkdtempSync, symlinkSync, rmSync, cpSync, renameSync, existsSync } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Frozen independently BEFORE product changes. Hex is raw file content; decoded
// and rendered are explicit source-oracle expectations, never product output.
const CASES = [
  ['plain', '4869207b7b2e7d7d', 'Hi {{.}}', 'Hi 雪😀'],
  ['whitespace', '202009', '  \t', '  \t'],
  ['bom', 'efbbbf7b7b2e7d7d', '\uFEFF{{.}}', '\uFEFF雪😀'],
  ['lf', '410a7b7b2e7d7d0a', 'A\n{{.}}\n', 'A\n雪😀\n'],
  ['crlf', '410d0a7b7b2e7d7d0d0a', 'A\r\n{{.}}\r\n', 'A\r\n雪😀\r\n'],
  ['nul', '41007b7b2e7d7d', 'A\0{{.}}', 'A\0雪😀'],
  ['unicode', 'e99baaf09f9880207b7b2e7d7d', '雪😀 {{.}}', '雪😀 雪😀'],
  ['isolated-continuation', '807b7b2e7d7d', '\uFFFD{{.}}', '\uFFFD雪😀'],
  ['truncated-three', 'e282', '\uFFFD', '\uFFFD'],
  ['invalid-following-ascii', 'e228a1', '\uFFFD(\uFFFD', '\uFFFD(\uFFFD'],
  ['overlong', 'c0af', '\uFFFD\uFFFD', '\uFFFD\uFFFD'],
  ['encoded-surrogate', 'eda080', '\uFFFD\uFFFD\uFFFD', '\uFFFD\uFFFD\uFFFD'],
  ['out-of-range', 'f4908080', '\uFFFD\uFFFD\uFFFD\uFFFD', '\uFFFD\uFFFD\uFFFD\uFFFD'],
  ['arbitrary', 'fffe0041e282acf09f988080', '\uFFFD\uFFFD\0A€😀\uFFFD', '\uFFFD\uFFFD\0A€😀\uFFFD'],
  ['empty-fallback', '', '', 'FALLBACK 雪😀'],
];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const units = text => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));
const repository = fileURLToPath(new URL('../../../', import.meta.url));
const packagePath = join(repository, 'apps/synapsis_core/priv/workflow_schema');
let directory, templateCommand, headCommand, runPipeline;
before(async () => {
  const archive = process.env.SYNAPSIS_LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
  assert.equal(sha(readFileSync(archive)), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
  directory = mkdtempSync(join(tmpdir(), 'synapsis-template-files-'));
  execFileSync('tar', ['-xzf', resolve(archive), '-C', directory]);
  const upstream = join(directory, 'package');
  for (const [name, expected] of [
    ['commands/stdlib/template', '27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac'],
    ['core/filters', 'd7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14'],
    ['core/value_path', 'e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f'],
    ['runtime', '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53'],
    ['commands/stdlib/head', '3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1'],
  ]) assert.equal(sha(readFileSync(join(upstream, `dist/src/${name}.js`))), expected);
  symlinkSync(join(packagePath, 'node_modules'), join(upstream, 'node_modules'), 'dir');
  const load = name => import(pathToFileURL(join(upstream, `dist/src/${name}.js`)));
  ({ templateCommand } = await load('commands/stdlib/template'));
  ({ headCommand } = await load('commands/stdlib/head'));
  ({ runPipeline } = await load('runtime'));
});
after(() => { if (directory) rmSync(directory, { recursive: true, force: true }); });
async function collect(input) { const result = []; for await (const item of input) result.push(item); return result; }
const stage = (name, args) => ({ name, args });

test('source oracle: actual unchanged fs/template reads all 15 frozen successful byte vectors', async () => {
  assert.equal(CASES.length, 15);
  for (const [id, hex, decoded, expected] of CASES) {
    const file = join(directory, id + ' 雪 space.txt');
    await fs.writeFile(file, Buffer.from(hex, 'hex'));
    assert.deepEqual(units(await fs.readFile(file, 'utf8')), units(decoded), id);
    const { output } = await templateCommand.run({ args: { file, _: ['FALLBACK', '{{.}}'] }, input: ['雪😀'] });
    const actual = await collect(output);
    assert.deepEqual(actual.map(units), [units(expected)], id);
  }
});

test('source oracle: construction precedes demand for head0/empty; text wins; retained and independent reads', async () => {
  const file = join(directory, 'construction.txt');
  const original = fs.readFile;
  try {
    let reads = 0, pulls = 0;
    fs.readFile = async (...args) => { if (args[0] === file) reads++; return original(...args); };
    const input = items => (async function* () { for (const item of items) { pulls++; yield item; } })();
    const registry = { get: name => ({ template: templateCommand, head: headCommand })[name] };
    for (const [items, tail] of [[['A'], [stage('head', { n: '0' })]], [[], []]]) {
      reads = 0; pulls = 0; await fs.writeFile(file, 'OLD {{.}}');
      const sink = { write() { return true; } };
      const result = await runPipeline({ pipeline: [stage('template', { file }), ...tail], registry, input: input(items), stdout: sink, stderr: sink, stdin: { isTTY: false }, env: {}, mode: 'tool', renderOutput: false });
      assert.deepEqual(result.items, []); assert.equal(reads, 1); assert.equal(pulls, 0);
    }
    reads = 0;
    for (const text of ['TEXT {{.}}', '  ']) {
      const { output } = await templateCommand.run({ args: { text, file }, input: ['A'] });
      assert.deepEqual(await collect(output), [text === '  ' ? '  ' : 'TEXT A']);
    }
    assert.equal(reads, 0);
    await fs.writeFile(file, 'OLD {{.}}');
    const first = await templateCommand.run({ args: { file }, input: input(['A', 'B']) });
    await fs.writeFile(file, 'NEW {{.}}');
    assert.deepEqual(await collect(first.output), ['OLD A', 'OLD B']);
    const second = await templateCommand.run({ args: { file }, input: ['C'] });
    assert.deepEqual(await collect(second.output), ['NEW C']); assert.equal(reads, 2);
  } finally { fs.readFile = original; }
});

async function* frames(stream) {
  let pending = Buffer.alloc(0);
  for await (const bytes of stream) {
    pending = Buffer.concat([pending, bytes]);
    let lf; while ((lf = pending.indexOf(0x0a)) !== -1) { yield JSON.parse(pending.subarray(0, lf).toString('utf8')); pending = pending.subarray(lf + 1); }
  }
  assert.equal(pending.length, 0);
}
const heap = { version: 1, next_id: 2, nodes: { '1': { type: 'object', keys: ['type'], fields: { type: { type: 'string', value: 'string' } } } } };
const receipt = (id, outcome, value) => ({ type: 'result', id, result: 'ok', outcome, ...(value === undefined ? {} : { value }), cacheEntries: 1 });
async function helper(t, path) {
  const child = spawn(process.execPath, [path], { stdio: ['pipe', 'pipe', 'pipe'] });
  const completion = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const stderr = []; child.stderr.on('data', value => stderr.push(value));
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await completion; } });
  const stream = frames(child.stdout);
  const next = async () => { const result = await stream.next(); assert.equal(result.done, false); return result.value; };
  assert.deepEqual(await next(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
  const pid = child.pid;
  const fulfill = async request => { child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap }) + '\n'); const result = await next(); assert.equal(child.pid, pid); assert.equal(child.exitCode, null); assert.equal(existsSync(`/proc/${pid}`), true); return result; };
  assert.deepEqual(await fulfill({ id: 'compile', kind: 'compile_schema', schema: { type: 'reference', id: '1' } }), receipt('compile', 'compiled'));
  for (const [id, hex, decoded, rendered] of CASES) {
    const value = { type: 'string', value: decoded };
    const result = await fulfill({ id, kind: 'decode_template_file', bytes_base64: Buffer.from(hex, 'hex').toString('base64') });
    assert.deepEqual(result, receipt(id, 'decoded', value)); assert.equal(Object.keys(result).length, 6);
    const template = decoded === '' ? { type: 'string', value: 'FALLBACK {{.}}' } : result.value;
    assert.deepEqual(await fulfill({ id: id + ':render', kind: 'render_template', template, item: { type: 'string', value: '雪😀' } }), receipt(id + ':render', 'rendered', { type: 'string', value: rendered }));
    assert.deepEqual(await fulfill({ id: id + ':validate', kind: 'validate_response', schema: { type: 'reference', id: '1' }, response: result.value }), receipt(id + ':validate', 'valid'));
  }
  assert.deepEqual(await fulfill({ id: 'compile:reuse', kind: 'compile_schema', schema: { type: 'reference', id: '1' } }), receipt('compile:reuse', 'compiled'));
  child.stdin.write('{"type":"close"}\n'); assert.deepEqual(await next(), { type: 'closed' });
  assert.deepEqual(await completion, { code: 0, signal: null }); assert.equal(existsSync(`/proc/${pid}`), false);
  assert.equal((await stream.next()).done, true); assert.equal(Buffer.concat(stderr).toString('utf8'), '');
}
test('source helper decodes/renders/validates on one PID/cache with normal exit', { timeout: 120000 }, async t => {
  await helper(t, join(repository, 'packages/tool-host/src/workflow/schema-stdio.mjs'));
});
test('relocated complete package decodes/renders/validates on one PID/cache with normal exit', { timeout: 120000 }, async t => {
  const assembled = join(directory, 'assembled helper'), relocated = join(directory, 'relocated helper');
  cpSync(packagePath, assembled, { recursive: true }); renameSync(assembled, relocated);
  assert.equal(existsSync(assembled), false);
  await helper(t, join(relocated, 'schema-stdio.mjs'));
});
