// Execute unchanged pinned timestamp helpers; service scheduling is outside this capture.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const SCHEDULE_COMPUTATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'src/cron/schedule.ts';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [
  entry,
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'src/infra/format-time/parse-offsetless-zoned-datetime.ts',
  'src/infra/map-size.ts',
  'src/cron/parse.ts',
  'src/cron/schedule-number.ts',
  'src/shared/iso-time.ts',
];
const bindingCode = ['Cron', 'CronDate'].map(name =>
  `export class ${name} { constructor() { globalThis.__bindingCalls.push(${JSON.stringify(name)}); throw Error(${JSON.stringify(`uninvoked croner binding: ${name}`)}); } }`
).join('\n');

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), SCHEDULE_COMPUTATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', SCHEDULE_COMPUTATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: hash(bytes) };
  });
  return {
    tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: SCHEDULE_COMPUTATION_PIN,
      tree: git(root, ['rev-parse', `${SCHEDULE_COMPUTATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}

function vectors() {
  const nowMs = 1793095200000; // 2026-10-27T10:00:00.000Z
  const at = (id, value, expected = nowMs + 60000) => ({ id, schedule: { kind: 'at', at: value }, nowMs,
    expected, subsequentNowMs: nowMs + 30000, subsequentExpected: expected });
  const every = (id, schedule, firstOffset) => ({ id, schedule: { kind: 'every', everyMs: 1500, ...schedule },
    nowMs, expected: nowMs + firstOffset, subsequentNowMs: nowMs + firstOffset,
    subsequentExpected: nowMs + firstOffset + 1500 });
  return [
    at('absolute-z', '2026-10-27T10:01:00Z'),
    at('absolute-offset', '2026-10-27T15:46:00+05:45'),
    at('offsetless-default-utc', '2026-10-27T10:01:00'),
    at('epoch-milliseconds-string', '1793095260000'),
    at('date-only-default-utc', '2026-10-28', 1793145600000),
    at('fractional-iso-millisecond-truncation', '2026-10-27T10:01:00.123456Z', 1793095260123),
    at('offsetless-end-of-day-utc', '2026-10-27T24:00:00', 1793145600000),
    every('interval-before-anchor', { anchorMs: nowMs + 5000 }, 5000),
    every('interval-exact-anchor', { anchorMs: nowMs }, 1500),
    every('interval-fractional-step-elapsed', { anchorMs: nowMs - 500 }, 1000),
    every('interval-exact-later-boundary', { anchorMs: nowMs - 3000 }, 1500),
    every('interval-omitted-anchor-helper', {}, 1500),
  ];
}

export async function captureScheduleComputation(source = '/tmp/openclaw-488631c') {
  assert.equal(process.versions.node, '24.22.1', 'use the fixed capture runtime');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  const before = checkout(root);
  const context = vm.createContext({});
  new vm.Script('globalThis.__bindingCalls=[]').runInContext(context, { timeout: 1000 });
  const modules = new Map();
  const records = new Map();
  const load = path => {
    assert.ok(wholeSources.includes(path), `declared whole module: ${path}`);
    if (!modules.has(path)) {
      const bytes = readFileSync(join(root, path));
      assert.equal(hash(bytes), before.tracked.get(path), path);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      records.set(path, { path, sha256: hash(bytes), executableSha256: hash(executable),
        executed: true, wholeModule: true });
      modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path }));
    }
    return modules.get(path);
  };
  const binding = new vm.SourceTextModule(bindingCode, { context, identifier: 'capture:uninvoked-croner' });
  const module = load(entry);
  await module.link((specifier, owner) => {
    if (owner.identifier === entry && specifier === 'croner') return binding;
    if (specifier.startsWith('@openclaw/normalization-core/')) {
      return load(`packages/normalization-core/src/${specifier.split('/').at(-1)}.ts`);
    }
    if (owner.identifier === 'packages/normalization-core/src/number-coercion.ts' && specifier === './string-coerce.ts') {
      return load('packages/normalization-core/src/string-coerce.ts');
    }
    assert.ok(specifier.startsWith('.') && specifier.endsWith('.js'), `declared source import: ${specifier}`);
    return load(posix.normalize(posix.join(posix.dirname(owner.identifier), specifier)).replace(/\.js$/, '.ts'));
  });
  await module.evaluate({ timeout: 1000 });
  assert.deepEqual([...records.keys()].sort(), [...wholeSources].sort());
  context.scheduleExports = module.namespace;
  const compute = (schedule, nowMs) => {
    context.schedule = schedule;
    context.nowMs = nowMs;
    return new vm.Script('scheduleExports.computeNextRunAtMs(schedule, nowMs)').runInContext(context, { timeout: 1000 });
  };
  const observations = vectors().map(vector => {
    const schedule = plain(vector.schedule);
    const nextRunAtMs = compute(schedule, vector.nowMs);
    assert.equal(nextRunAtMs, vector.expected, vector.id);
    const subsequentNextRunAtMs = compute(schedule, vector.subsequentNowMs);
    assert.equal(subsequentNextRunAtMs, vector.subsequentExpected, vector.id);
    assert.deepEqual(schedule, vector.schedule, vector.id);
    return { id: vector.id, schedule, nowMs: vector.nowMs, nextRunAtMs,
      subsequent: { nowMs: vector.subsequentNowMs, nextRunAtMs: subsequentNextRunAtMs },
      scheduleAfter: plain(schedule) };
  });
  const bindingCalls = plain(context.__bindingCalls);
  assert.deepEqual(bindingCalls, []);
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return {
    schemaVersion: 1, referencePin: SCHEDULE_COMPUTATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-schedule-computation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt },
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    entry: { path: entry, export: 'computeNextRunAtMs', calls: observations.length * 2 },
    sourceRecords: [...records.values()],
    importBindings: [{ importer: entry, specifier: 'croner', exports: ['Cron', 'CronDate'],
      kind: 'uninvoked-throwing-binding', sourceImplementationExecuted: false,
      generatedCode: bindingCode, generatedSha256: hash(bindingCode), invocationCount: bindingCalls.length }],
    bindingCalls,
    scope: { pureTimestampComputationExecuted: true, cronerExecuted: false, cronBranchExecuted: false,
      jobServiceExecuted: false, oneShotLifecycleExecuted: false, toolFactoryExecuted: false,
      eligibilityExecuted: false, runtimeAssemblyExecuted: false },
    limits: [
      'Only actual pure computeNextRunAtMs timestamp computation for at/every executes, from eight complete unchanged pinned TypeScript modules. Module evaluation does not claim every exported function or function body executes.',
      'All tracked reference blobs are verified before and after; source, transformed executable, exporter, runtime and generated uninvoked binding hashes are recorded. No source or installed package is patched.',
      'Cron and CronDate are throwing bindings with zero audited invocations; Croner implementation and cron-expression branches are unexecuted.',
      'The second at call advances now while still before the same future target. The second every call advances now to its first due boundary and computes the following interval.',
      'Date-only and offsetless 24:00 inputs resolve to UTC midnight; fractional ISO seconds retain only milliseconds through the actual pinned parser and native Date.parse.',
      'The omitted-anchor vector proves helper behavior only: its anchor defaults to each supplied now. No job creation or persisted service anchor behavior executes.',
      'Job service, one-shot lifecycle, tool factory, eligibility, runtime assembly and Synapsis integration are unexecuted and require separate evidence.',
    ],
    observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-schedule-computation.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureScheduleComputation(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], vectors: result.observations.length,
    helperCalls: result.entry.calls, wholeModules: result.sourceRecords.length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles, bindingInvocations: result.bindingCalls.length }) + '\n');
}
