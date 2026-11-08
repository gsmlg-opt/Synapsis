import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync,
  renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Frozen independent ordinary-success tests. Actual original sort is the oracle
// for engine-specific long permutations; the helper never generates expectations.
// No registry, dependency patches, source rewrites or fabricated receipts.
const repository = fileURLToPath(new URL('../../../', import.meta.url));
const ARCHIVE_SHA256 = 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1';
const number = bits => ({ type: 'number', bits });
const ref = id => ({ type: 'reference', id });
const string = value => ({ type: 'string', value });
const ZERO = '0000000000000000', NEG_ZERO = '8000000000000000';
const ONE = '3ff0000000000000', TWO = '4000000000000000', THREE = '4008000000000000';
const INF = '7ff0000000000000', NEG_INF = 'fff0000000000000';
const NAN = '7ff8000000000000', PAYLOAD_NAN = '7ff8000000000042', NEG_NAN = 'fff8000000000042';
const IDENTITY_96 = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
  80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
];
const CASES = [
  // Both witnessed-five literals were observed by the parent against complete
  // original source on Node24.19.0/V8 13.6.233.17-node.51 before helper changes.
  { id: 'witnessed-five', keys: [THREE, ONE, ZERO, PAYLOAD_NAN, TWO],
    asc: [2, 1, 4, 0, 3], desc: [0, 1, 2, 3, 4] },
  { id: 'nan-between-finite', keys: [THREE, PAYLOAD_NAN, ONE],
    asc: [0, 1, 2], desc: [0, 1, 2] },
  // Placement cases below are compared against actual whole original source on
  // the selected engine. No portable inconsistent-comparator order is assumed.
  { id: 'nan-first', keys: [PAYLOAD_NAN, THREE, ONE, ZERO, TWO] },
  { id: 'nan-last', keys: [THREE, ONE, ZERO, TWO, NEG_NAN] },
  { id: 'nan-in-finite-run', keys: [TWO, ONE, NEG_NAN, THREE, ZERO] },
  { id: 'signed-zero-and-infinity-ties', keys: [INF, NEG_ZERO, ZERO, NEG_INF, INF, NEG_ZERO],
    asc: [3, 1, 2, 5, 0, 4], desc: [0, 4, 1, 2, 5, 3] },
  // Repeated key values still represent distinct original input occurrences.
  { id: 'duplicate-occurrences', keys: [TWO, PAYLOAD_NAN, TWO, TWO, PAYLOAD_NAN, TWO],
    asc: [0, 1, 2, 3, 4, 5], desc: [0, 1, 2, 3, 4, 5] },
  { id: 'nan-sign-and-payload-ties', keys: [NAN, NEG_NAN, PAYLOAD_NAN, NAN],
    asc: [0, 1, 2, 3], desc: [0, 1, 2, 3] },
  { id: 'empty-dense-array', keys: [], asc: [], desc: [] },
  { id: 'singleton-nan', keys: [NEG_NAN], asc: [0], desc: [0] },
  { id: 'ordinary-96-all-nan',
    keys: Array.from({ length: 96 }, (_, i) => [NAN, PAYLOAD_NAN, NEG_NAN][i % 3]),
    asc: IDENTITY_96, desc: IDENTITY_96 },
  { id: 'ordinary-192-numeric-with-nan',
    keys: Array.from({ length: 192 }, (_, i) =>
      [THREE, ONE, ZERO, PAYLOAD_NAN, TWO, NEG_ZERO, INF, NEG_INF, TWO, NEG_NAN, ONE][i % 11]) },
  { id: 'ordinary-257-interleaved-runs',
    keys: Array.from({ length: 257 }, (_, i) =>
      [INF, THREE, TWO, ONE, ZERO, NEG_ZERO, NEG_INF, PAYLOAD_NAN, ONE, TWO, THREE, NEG_NAN][(i * 5 + Math.floor(i / 17)) % 12]) },
];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const engines = [realpathSync(process.execPath)];
if (process.env.SYNAPSIS_WORKFLOW_SORT_NODE) {
  assert.ok(isAbsolute(process.env.SYNAPSIS_WORKFLOW_SORT_NODE));
  const extra = realpathSync(process.env.SYNAPSIS_WORKFLOW_SORT_NODE);
  if (!engines.includes(extra)) engines.push(extra);
}
let temporary, relocated, sourceModulePath;
const oracleByEngine = new Map();

function files(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).flatMap(entry => {
    const path = join(prefix, entry.name);
    if (entry.isDirectory()) return files(root, path);
    assert.ok(entry.isFile(), 'complete helper package contains regular files');
    return [path];
  }).sort();
}

// This child harness imports the whole untouched sort module. It contains no
// copy of its comparator, decoder, sort algorithm or command implementation.
const ORIGINAL_ORACLE_SOURCE = String.raw`
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const { sortCommand } = await import(process.argv[1]);
assert.equal(sortCommand.name, 'sort');
const vectors = JSON.parse(readFileSync(0, 'utf8'));
const observations = [];
for (const vector of vectors) {
  for (const direction of ['asc', 'desc']) {
    const rows = vector.keys.map((bits, occurrence) => ({
      n: Buffer.from(bits, 'hex').readDoubleBE(0), occurrence,
    }));
    const before = rows.map(row => row.occurrence);
    const result = await sortCommand.run({ input: rows, args: { _: [], key: 'n', desc: direction === 'desc' } });
    const indices = [];
    for await (const item of result.output) {
      assert.strictEqual(item, rows[item.occurrence]);
      indices.push(item.occurrence);
    }
    assert.deepEqual(rows.map(row => row.occurrence), before);
    if (Object.hasOwn(vector, direction)) assert.deepEqual(indices, vector[direction], vector.id + ':' + direction);
    observations.push({ id: vector.id, direction, indices });
  }
}
process.stdout.write(JSON.stringify({ executable: process.execPath, node: process.versions.node,
  v8: process.versions.v8, wholeOriginalSort: true, sourceTransformed: false, observations }));
`;

before(() => {
  const staged = process.env.SYNAPSIS_WORKFLOW_SORT_HELPER_ROOT;
  assert.ok(staged && isAbsolute(staged), 'supply absolute SYNAPSIS_WORKFLOW_SORT_HELPER_ROOT for the staged complete package');
  const archive = process.env.SYNAPSIS_LOBSTER_NUMBER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
  assert.equal(sha256(readFileSync(archive)), ARCHIVE_SHA256);
  temporary = mkdtempSync(join(tmpdir(), 'synapsis-number-sort-'));
  execFileSync('tar', ['-xzf', resolve(archive), '-C', temporary],
    { timeout: 10_000, maxBuffer: 1024 * 1024 });
  const pkg = JSON.parse(readFileSync(join(temporary, 'package/package.json'), 'utf8'));
  assert.equal(pkg.name, '@clawdbot/lobster');
  assert.equal(pkg.version, '2026.9.16');
  sourceModulePath = join(temporary, 'package/dist/src/commands/stdlib/sort.js');
  const assembled = join(temporary, 'assembled helper');
  relocated = join(temporary, 'relocated helper');
  cpSync(staged, assembled, { recursive: true });
  renameSync(assembled, relocated);
  const paths = files(staged);
  assert.deepEqual(files(relocated), paths);
  assert.ok(paths.includes('schema-stdio.mjs'));
  assert.ok(paths.includes('schema-worker.mjs'));
  for (const path of paths) assert.deepEqual(readFileSync(join(relocated, path)), readFileSync(join(staged, path)), path);
  for (const engine of engines) {
    const observed = JSON.parse(execFileSync(engine,
      ['--input-type=module', '-e', ORIGINAL_ORACLE_SOURCE, pathToFileURL(sourceModulePath).href],
      { input: JSON.stringify(CASES), encoding: 'utf8', timeout: 20_000, maxBuffer: 1024 * 1024 }));
    assert.equal(realpathSync(observed.executable), engine);
    assert.equal(observed.wholeOriginalSort, true);
    assert.equal(observed.sourceTransformed, false);
    assert.equal(observed.observations.length, CASES.length * 2);
    oracleByEngine.set(engine, observed);
  }
});
after(() => { if (temporary) rmSync(temporary, { recursive: true, force: true }); });

function operation(id, keyBits, desc) {
  // Reuse the same trusted number tag object for repeated values. The numeric
  // keys remain dense and homogeneous; output indices identify occurrences.
  const tags = new Map();
  const keys = keyBits.map(bits => {
    if (!tags.has(bits)) tags.set(bits, number(bits));
    return tags.get(bits);
  });
  return {
    request: { id, kind: 'sort_items', keys: ref('1'), desc, stage_index: 0 },
    heap: { version: 1, next_id: 4, nodes: {
      '1': { type: 'array', items: keys },
      '2': { type: 'object', keys: [], fields: {} },
      '3': { type: 'object', keys: ['type'], fields: { type: string('string') } },
    } },
  };
}

async function* frames(stream) {
  let pending = Buffer.alloc(0);
  for await (const chunk of stream) {
    pending = Buffer.concat([pending, chunk]);
    let lf;
    while ((lf = pending.indexOf(10)) !== -1) {
      const raw = pending.subarray(0, lf);
      pending = pending.subarray(lf + 1);
      yield JSON.parse(raw.toString('utf8'));
    }
  }
  assert.equal(pending.length, 0);
}

function bounded(promise, label) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(label + ' timed out')), 20_000);
  })]).finally(() => clearTimeout(timer));
}

async function helperSession(t, engine, helper, label) {
  const source = oracleByEngine.get(engine);
  const expectedByCase = new Map(source.observations.map(item => [item.id + ':' + item.direction, item.indices]));
  const child = spawn(engine, [helper], { stdio: ['pipe', 'pipe', 'pipe'] });
  const stderr = [];
  child.stderr.on('data', bytes => stderr.push(bytes));
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const iterator = frames(child.stdout);
  t.after(async () => {
    // Defensive cleanup of this test's owned process only. It is not failure,
    // cancellation or crash qualification, and never counts as normal close.
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
      await bounded(completion, 'owned helper cleanup');
    }
  });
  const next = async () => {
    const frame = await bounded(iterator.next(), 'helper frame');
    assert.equal(frame.done, false, Buffer.concat(stderr).toString('utf8'));
    return frame.value;
  };
  assert.deepEqual(await next(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
  const pid = child.pid;
  assert.ok(Number.isSafeInteger(pid));
  assert.equal(existsSync('/proc/' + pid), true);
  assert.equal(realpathSync('/proc/' + pid + '/exe'), engine);
  let sortRequests = 0;
  async function fulfill(request, heap) {
    const frozenInput = JSON.stringify({ request, heap });
    child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap }) + '\n');
    const receipt = await next();
    assert.equal(child.pid, pid);
    assert.equal(child.exitCode, null);
    assert.equal(existsSync('/proc/' + pid), true);
    assert.equal(realpathSync('/proc/' + pid + '/exe'), engine);
    assert.equal(JSON.stringify({ request, heap }), frozenInput);
    return receipt;
  }
  async function sort(vector, direction, cacheEntries, suffix = '') {
    const id = label + ':' + vector.id + ':' + direction + suffix;
    const { request, heap } = operation(id, vector.keys, direction === 'desc');
    const taggedBefore = JSON.stringify(heap);
    const actual = await fulfill(request, heap);
    const indices = expectedByCase.get(vector.id + ':' + direction);
    // Exact shape contains only a permutation, never decoded nonfinite values.
    assert.deepEqual(actual, { type: 'result', id, result: 'ok', outcome: 'sorted', indices, cacheEntries }, id);
    assert.equal(actual.indices.length, vector.keys.length);
    assert.ok(actual.indices.every(index => Number.isSafeInteger(index) && index >= 0 && index < vector.keys.length));
    assert.equal(new Set(actual.indices).size, vector.keys.length);
    assert.deepEqual([...actual.indices].sort((a, b) => a - b), vector.keys.map((_, index) => index));
    assert.equal(JSON.stringify(heap), taggedBefore);
    assert.deepEqual(heap.nodes['1'].items.map(tag => tag.bits), vector.keys);
    sortRequests += 1;
  }
  const heap = operation('schema-heap', [], false).heap;
  // The same process sorts before compilation, then keeps the actual Ajv cache
  // through all sorts, validation, a second real compile and cache reuse.
  await sort(CASES[0], 'asc', 0, ':before-compile');
  assert.deepEqual(await fulfill({ id: 'compile-empty', kind: 'compile_schema', schema: ref('2') }, heap),
    { type: 'result', id: 'compile-empty', result: 'ok', outcome: 'compiled', cacheEntries: 1 });
  for (const vector of CASES) {
    await sort(vector, 'asc', 1);
    await sort(vector, 'desc', 1);
  }
  assert.deepEqual(await fulfill({ id: 'validate-empty', kind: 'validate_response', schema: ref('2'), response: string('ordinary') }, heap),
    { type: 'result', id: 'validate-empty', result: 'ok', outcome: 'valid', cacheEntries: 1 });
  assert.deepEqual(await fulfill({ id: 'compile-string', kind: 'compile_schema', schema: ref('3') }, heap),
    { type: 'result', id: 'compile-string', result: 'ok', outcome: 'compiled', cacheEntries: 2 });
  await sort(CASES[0], 'desc', 2, ':after-second-compile');
  assert.deepEqual(await fulfill({ id: 'compile-empty-again', kind: 'compile_schema', schema: ref('2') }, heap),
    { type: 'result', id: 'compile-empty-again', result: 'ok', outcome: 'compiled', cacheEntries: 2 });
  assert.deepEqual(await fulfill({ id: 'validate-string', kind: 'validate_response', schema: ref('3'), response: string('ordinary') }, heap),
    { type: 'result', id: 'validate-string', result: 'ok', outcome: 'valid', cacheEntries: 2 });
  assert.equal(sortRequests, CASES.length * 2 + 2);
  child.stdin.write('{"type":"close"}\n');
  assert.deepEqual(await next(), { type: 'closed' });
  assert.deepEqual(await bounded(completion, 'normal helper exit'), { code: 0, signal: null });
  assert.equal((await bounded(iterator.next(), 'helper stdout completion')).done, true);
  assert.equal(existsSync('/proc/' + pid), false);
  assert.equal(Buffer.concat(stderr).toString('utf8'), '');
  t.diagnostic(JSON.stringify({ qualification: 'same-engine whole-original-sort versus actual stdio helper',
    target: label, executable: engine, node: source.node, v8: source.v8,
    originalSortCalls: source.observations.length, helperSortRequests: sortRequests,
    homogeneousNumericOnly: true, normalCloseAndExitObserved: true,
    nativeSegmentExecution: false, concordExecution: false, publicNanProducer: false }));
}

for (const engine of engines) {
  test('source helper: full numeric occurrence sort, same PID/cache and normal exit on ' + engine,
    { timeout: 120_000 }, async t => {
      await helperSession(t, engine, join(repository, 'packages/tool-host/src/workflow/schema-stdio.mjs'), 'source');
    });
  test('physically relocated complete helper: numeric occurrence sort, same PID/cache and normal exit on ' + engine,
    { timeout: 120_000 }, async t => {
      await helperSession(t, engine, join(relocated, 'schema-stdio.mjs'), 'relocated');
    });
}
