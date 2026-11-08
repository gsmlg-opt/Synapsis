// Frozen independently before production implementation for batch202.
// Expectations come from complete pinned original modules and the genuine fixture.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const referenceCommit = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixtureUrl = new URL('../../../apps/synapsis_agent/test/fixtures/openclaw/488631c/edit-plans.json', import.meta.url);
const fixtureBytes = readFileSync(fixtureUrl);
const fixture = JSON.parse(fixtureBytes);
const packagedDir = fileURLToPath(new URL('../../../apps/synapsis_core/priv/filesystem_planner/', import.meta.url));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const runtime = {
  node: process.versions.node,
  v8: process.versions.v8,
  unicode: process.versions.unicode,
  icu: process.versions.icu,
  cldr: process.versions.cldr,
  platform: process.platform,
  arch: process.arch,
};
const ordinaryIds = [
  'original-snapshot', 'reversed-request', 'unicode-utf16', 'identical-noop',
  'normalized-noop', 'bom-crlf', 'line-ending-style', 'fuzzy-preserves-untouched',
  'write-create', 'write-overwrite',
];

// These content/no-op literals follow prepareFileEdit's original-source semantics;
// full diff/patch/firstChangedLine expectations remain the genuine captured bytes.
const editFields = {
  'original-snapshot': { changed: true, content: 'beta\nBETA\ngamma\n', editCount: 2 },
  'reversed-request': { changed: true, content: 'beta\nBETA\ngamma\n', editCount: 2 },
  'unicode-utf16': { changed: true, content: '😀 鍵\ncafé tail\n', editCount: 2 },
  'identical-noop': { changed: false, message: 'No changes made to edit.txt. The replacement text is identical to the original.' },
  'normalized-noop': { changed: false, message: 'No changes made to edit.txt. The replacement produced identical content.' },
  'bom-crlf': { changed: true, content: '\uFEFFA\r\nB\r\nC\r\ngamma\r\n', editCount: 1 },
  'line-ending-style': { changed: true, content: '\uFEFFone\r\nTWO\nTHREE\rPLUS\rfour\r\n', editCount: 1 },
  'fuzzy-preserves-untouched': { changed: true, content: '😀 office = "new"  \nkeep ﬁ + e\u0301\n', editCount: 1 },
};

function freeze(value) {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function requestFor(row, label) {
  return freeze({
    protocol: 1,
    id: `${label}:${row.id}`,
    operation: row.kind === 'edit' ? 'edit' : 'write_diff',
    input: structuredClone(row.input),
  });
}

function expectedFor(row, request) {
  return {
    protocol: 1,
    id: request.id,
    result: row.result,
    runtime,
    referenceCommit,
    diffVersion: '9.0.0',
  };
}

function treeBytes(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true })
    .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) return [[path, 'directory'], ...treeBytes(root, path)];
      if (entry.isSymbolicLink()) return [[path, 'symlink', readlinkSync(join(root, path))]];
      return [[path, 'file', sha256(readFileSync(join(root, path)))]];
    });
}

async function checkPureApi(root, label) {
  const { planFilesystem } = await import(pathToFileURL(join(root, 'planner.mjs')).href);
  assert.equal(typeof planFilesystem, 'function');
  for (const row of fixture.cases) {
    const request = requestFor(row, label);
    const before = JSON.stringify(request);
    const actual = planFilesystem(request);
    // A synchronous complete envelope is required; awaiting a Promise would hide it.
    assert.deepEqual(actual, expectedFor(row, request), `${label}:${row.id}`);
    assert.equal(JSON.stringify(request), before, `${row.id}: pure input unchanged`);
  }
}

async function checkStdio(root, cwd, row, label) {
  const request = requestFor(row, label);
  const child = spawn(process.execPath, [resolve(root, 'stdio.mjs')], {
    cwd,
    // Remove inherited loader/module search settings; the artifact is complete.
    env: { ...process.env, NODE_PATH: '', NODE_OPTIONS: '' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const output = [], diagnostics = [], inputErrors = [];
  let exitObserved, closeObserved, spawnError, inputFinished = false;
  child.stdout.on('data', chunk => output.push(chunk));
  child.stderr.on('data', chunk => diagnostics.push(chunk));
  child.stdin.on('finish', () => { inputFinished = true; });
  child.stdin.on('error', error => inputErrors.push(error));
  child.once('error', error => { spawnError = error; });
  child.once('exit', (code, signal) => { exitObserved = { code, signal }; });
  const closed = new Promise(resolveClose => {
    child.once('close', (code, signal) => {
      closeObserved = { code, signal };
      resolveClose();
    });
  });
  let observationTimer;
  // This bounds the test observer only. No timeout/deadline request is sent.
  const observationBound = new Promise((_, reject) => {
    observationTimer = setTimeout(() => reject(new Error(`${label}:${row.id}: helper closure was not observed`)), 15_000);
  });
  try {
    // Deliberately never end stdin: its open pipe is the ownership channel.
    child.stdin.write(JSON.stringify(request) + '\n');
    await Promise.race([closed, observationBound]);
    if (spawnError) throw spawnError;
    assert.deepEqual(exitObserved, { code: 0, signal: null }, `${row.id}: exit`);
    assert.deepEqual(closeObserved, { code: 0, signal: null }, `${row.id}: close`);
    assert.equal(inputFinished, false, `${row.id}: caller held stdin open through closure`);
    assert.deepEqual(inputErrors, [], `${row.id}: request written completely`);
    assert.equal(Buffer.concat(diagnostics).toString('utf8'), '', `${row.id}: ordinary diagnostics`);
    const wire = Buffer.concat(output).toString('utf8');
    assert.ok(wire.endsWith('\n'), `${row.id}: LF-terminated response`);
    assert.equal(wire.split('\n').length, 2, `${row.id}: exactly one response frame`);
    assert.deepEqual(JSON.parse(wire), expectedFor(row, request), `${label}:${row.id}`);
    assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' }, `${row.id}: helper reaped`);
  } finally {
    clearTimeout(observationTimer);
    if (!closeObserved) {
      // Harness cleanup only; ordinary passing cases always exit naturally.
      child.kill('SIGKILL');
      await closed;
    }
  }
}

test('frozen independent source contract retains all ten genuine ordinary results', () => {
  assert.equal(sha256(fixtureBytes), 'a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0');
  assert.equal(fixture.reference.commit, referenceCommit);
  assert.deepEqual(fixture.cases.map(row => row.id), ordinaryIds);
  for (const row of fixture.cases.filter(row => row.kind === 'edit')) {
    const { receipt, ...fields } = row.result;
    assert.deepEqual(fields, editFields[row.id], row.id);
    if (fields.changed) assert.deepEqual(Object.keys(receipt).sort(), ['diff', 'firstChangedLine', 'patch']);
  }
  assert.deepEqual(fixture.cases[0].result, fixture.cases[1].result);
  assert.deepEqual(fixture.cases.filter(row => row.kind === 'write').map(row => row.input), [
    { path: 'write.txt', content: 'new\n', created: true },
    { path: 'write.txt', content: 'new\n', beforeText: 'old\n', created: false },
  ]);
});

test('packaged synchronous API returns all ten exact plans and preserves package bytes', async () => {
  const before = treeBytes(packagedDir);
  await checkPureApi(packagedDir, 'packaged-import');
  assert.deepEqual(treeBytes(packagedDir), before);
  assert.deepEqual(readFileSync(fixtureUrl), fixtureBytes);
});

test('packaged stdio completes all ten requests with stdin open and normal OS closure', async () => {
  const before = treeBytes(packagedDir);
  for (const row of fixture.cases) await checkStdio(packagedDir, packagedDir, row, 'packaged-stdio');
  assert.deepEqual(treeBytes(packagedDir), before);
});

test('complete copied artifact imports and executes all ten requests outside the repository without node_modules', async () => {
  const temporaryRoot = mkdtempSync(join(tmpdir(), 'synapsis-filesystem-planner-contract-'));
  try {
    const artifact = join(temporaryRoot, 'artifact');
    const before = treeBytes(packagedDir);
    cpSync(packagedDir, artifact, { recursive: true, dereference: true });
    assert.deepEqual(treeBytes(artifact), before, 'complete artifact copy');
    assert.equal(treeBytes(temporaryRoot).some(([path]) => path.split('/').includes('node_modules')), false);
    await checkPureApi(artifact, 'copied-import');
    for (const row of fixture.cases) await checkStdio(artifact, temporaryRoot, row, 'copied-stdio');
    assert.deepEqual(treeBytes(artifact), before, 'copied artifact bytes unchanged after use');
    assert.deepEqual(treeBytes(packagedDir), before, 'original artifact bytes unchanged after use');
    assert.deepEqual(readFileSync(fixtureUrl), fixtureBytes);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});
