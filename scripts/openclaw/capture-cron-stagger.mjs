// Execute complete pinned pure cron scheduling modules with the pinned Croner package.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto, { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const CRON_STAGGER_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const packageRoot = '/tmp/synapsis-openclaw-cron-stagger-capture';
const packageIntegrity = 'sha512-ixNtAJndqh173VQ4KodSdJEI6nuioBWI0V1ITNKhZZsO0pEMoDxz539T4FTTbSZ/xIOSuDnzxLVRqBVSvPNE2g==';
const entry = 'src/cron/service/jobs-scheduling.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = new Set([
  entry, 'src/cron/stagger.ts', 'src/cron/schedule.ts',
  'packages/normalization-core/src/expect.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'src/infra/format-time/parse-offsetless-zoned-datetime.ts',
  'src/infra/map-size.ts', 'src/cron/parse.ts', 'src/cron/schedule-number.ts',
  'src/shared/iso-time.ts',
]);
const deferredSources = new Set([
  'src/infra/errors.ts', 'src/cron/active-jobs.ts', 'src/cron/source-schedule.ts',
  'src/cron/store/delivery-codec.ts', 'src/cron/stream-schedule.ts',
  'src/cron/service/auto-disable.ts', 'src/cron/service/one-shot-schedule.ts',
  'src/cron/service/timer-execution-timeout.ts', 'src/cron/service/trigger-interval.ts',
]);

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), CRON_STAGGER_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', CRON_STAGGER_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    return { path, gitBlob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row])),
    receipt: { verified: true, commit: CRON_STAGGER_PIN,
      tree: git(root, ['rev-parse', `${CRON_STAGGER_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

function dependency(root) {
  const lock = readFileSync(join(root, 'pnpm-lock.yaml'), 'utf8');
  assert.ok(lock.includes(`  croner@10.0.1:\n    resolution: {integrity: ${packageIntegrity}}`));
  const archive = join(packageRoot, 'croner-10.0.1.tgz');
  const archiveBytes = readFileSync(archive);
  assert.equal('sha512-' + createHash('sha512').update(archiveBytes).digest('base64'), packageIntegrity);
  const module = join(packageRoot, 'package/dist/croner.js');
  const bytes = readFileSync(module);
  assert.deepEqual(bytes, execFileSync('tar', ['-xOf', archive, 'package/dist/croner.js'], { timeout: 30_000 }));
  const manifest = JSON.parse(readFileSync(join(packageRoot, 'package/package.json')));
  assert.equal(manifest.name, 'croner');
  assert.equal(manifest.version, '10.0.1');
  return { bytes, receipt: { name: manifest.name, version: manifest.version,
    archive, integrity: packageIntegrity, archiveSha256: hash(archiveBytes),
    upstreamLockSha256: hash(lock), module, moduleSha256: hash(bytes),
    wholeModule: true, sourceImplementationExecuted: true } };
}

function namedImports(code, specifier) {
  const names = new Set();
  for (const match of code.matchAll(/import\s*\{([^}]+)\}\s*from\s*["']([^"']+)["']/g)) {
    if (match[2] !== specifier) continue;
    for (const part of match[1].split(',')) names.add(part.trim().split(/\s+as\s+/)[0]);
  }
  assert.ok(names.size, `named uninvoked import: ${specifier}`);
  return [...names].sort();
}

export async function captureCronStagger(source = '/tmp/openclaw-488631c') {
  assert.equal(process.versions.node, '24.22.1', 'use the fixed capture runtime');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  const before = checkout(root);
  const croner = dependency(root);
  const context = vm.createContext({});
  new vm.Script(`globalThis.__deferredCalls=[];globalThis.__defer=name=>{
    __deferredCalls.push(name);throw Error('uninvoked capture binding: '+name);};`).runInContext(context, { timeout: 1000 });
  const modules = new Map();
  const records = new Map();
  const bindings = new Map();
  const executables = new Map();
  const load = path => {
    assert.ok(wholeSources.has(path), `declared whole source: ${path}`);
    if (!modules.has(path)) {
      const bytes = readFileSync(join(root, path));
      assert.equal(hash(bytes), before.tracked.get(path).sha256, path);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      records.set(path, { ...before.tracked.get(path), executed: true, wholeModule: true,
        executableSha256: hash(executable) });
      executables.set(path, executable);
      modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path }));
    }
    return modules.get(path);
  };
  const cryptoBinding = new vm.SyntheticModule(['default'], function () {
    this.setExport('default', crypto);
  }, { context, identifier: 'node:crypto' });
  const cronerModule = new vm.SourceTextModule(croner.bytes.toString(), { context, identifier: 'package:croner@10.0.1' });
  const module = load(entry);
  await module.link((specifier, owner) => {
    if (specifier === 'node:crypto') return cryptoBinding;
    if (specifier === 'croner') return cronerModule;
    if (specifier === '@openclaw/normalization-core') return load('packages/normalization-core/src/expect.ts');
    if (specifier.startsWith('@openclaw/normalization-core/')) {
      return load('packages/normalization-core/src/' + specifier.split('/').at(-1) + '.ts');
    }
    assert.ok(specifier.startsWith('.'), `declared source import: ${specifier}`);
    const path = posix.normalize(posix.join(posix.dirname(owner.identifier), specifier)).replace(/\.js$/, '.ts');
    if (deferredSources.has(path)) {
      if (!modules.has(path)) {
        const names = namedImports(executables.get(owner.identifier), specifier);
        const generatedCode = names.map(name => `export const ${name}=(...args)=>__defer(${JSON.stringify(path + ':' + name)});`).join('\n');
        bindings.set(path, { path, sourceSha256: before.tracked.get(path).sha256,
          kind: 'uninvoked-throwing-binding', exports: names, sourceImplementationExecuted: false,
          generatedCode, generatedSha256: hash(generatedCode) });
        modules.set(path, new vm.SourceTextModule(generatedCode, { context, identifier: path }));
      }
      return modules.get(path);
    }
    return load(path);
  });
  await module.evaluate({ timeout: 1000 });
  assert.deepEqual([...records.keys()].sort(), [...wholeSources].sort());
  context.scheduling = module.namespace;
  context.stagger = modules.get('src/cron/stagger.ts').namespace;
  context.timestamps = modules.get('src/cron/schedule.ts').namespace;
  const invoke = code => new vm.Script(code).runInContext(context, { timeout: 1000 });
  const normalizationInputs = [0, 1, 300000, 1234.9, '0', '300000', ' +300000 '];
  const normalization = normalizationInputs.map(input => {
    context.input = input;
    return { input, normalized: invoke('stagger.normalizeCronStaggerMs(input)') };
  });
  const defaultExpressions = ['0 * * * *', '0 */2 * * *', '0 9,* * * *', '0 9 * * *',
    '30 * * * *', '0 0 * * * *', '0 0 */3 * * *'];
  const defaults = defaultExpressions.map(expr => {
    context.expr = expr;
    return { expr, staggerMs: invoke('stagger.resolveDefaultCronStaggerMs(expr)') ?? null };
  });
  const firstJob = '11111111-1111-4111-8111-111111111111';
  const secondJob = '22222222-2222-4222-8222-222222222222';
  const nowMs = Date.parse('2026-10-27T10:00:00Z');
  const expectedOffset = (id, staggerMs) => staggerMs <= 1 ? 0 : createHash('sha256').update(id).digest().readUInt32BE(0) % staggerMs;
  const firstOffset = expectedOffset(firstJob, 300000);
  const vectors = [
    ['hourly-window', firstJob, '0 * * * *', 'Etc/UTC', 300000, nowMs],
    ['hourly-before-window', firstJob, '0 * * * *', 'Etc/UTC', 300000, nowMs - 60000],
    ['hourly-at-effective-slot', firstJob, '0 * * * *', 'Etc/UTC', 300000, nowMs + firstOffset],
    ['hourly-after-effective-slot', firstJob, '0 * * * *', 'Etc/UTC', 300000, nowMs + firstOffset + 1],
    ['different-uuid-window', secondJob, '0 * * * *', 'Etc/UTC', 300000, nowMs],
    ['explicit-zero', firstJob, '0 * * * *', 'Etc/UTC', 0, nowMs],
    ['one-ms-window-offset-zero', firstJob, '0 * * * *', 'Etc/UTC', 1, nowMs],
    ['custom-minute-window', firstJob, '*/5 * * * *', 'Etc/UTC', 60000, nowMs],
    ['kathmandu-before-hour', firstJob, '0 * * * *', 'Asia/Kathmandu', 300000, nowMs],
    ['kathmandu-hour-window', firstJob, '0 * * * *', 'Asia/Kathmandu', 300000, nowMs + 900000],
    ['kathmandu-at-slot', firstJob, '0 * * * *', 'Asia/Kathmandu', 300000, nowMs + 900000 + firstOffset],
  ];
  const observations = vectors.map(([id, jobId, expr, tz, staggerMs, instant]) => {
    const job = { id: jobId, enabled: true, schedule: { kind: 'cron', expr, tz, staggerMs }, state: {} };
    context.job = job;
    context.nowMs = instant;
    const nextRunAtMs = invoke('scheduling.computeJobNextRunAtMs(job,nowMs)');
    const previousRunAtMs = invoke('scheduling.computeJobPreviousRunAtOrBeforeMs(job,nowMs)');
    assert.ok(Number.isFinite(nextRunAtMs) && nextRunAtMs > instant, id);
    assert.ok(Number.isFinite(previousRunAtMs) && previousRunAtMs <= instant, id);
    assert.deepEqual(job, { id: jobId, enabled: true, schedule: { kind: 'cron', expr, tz, staggerMs }, state: {} });
    return { id, job: plain(job), nowMs: instant, nextRunAtMs, previousRunAtMs,
      hashDerivedOffsetMs: expectedOffset(jobId, staggerMs) };
  });
  const deferredCalls = plain(context.__deferredCalls);
  assert.deepEqual(deferredCalls, []);
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return {
    schemaVersion: 1, referencePin: CRON_STAGGER_PIN,
    exporter: { path: 'scripts/openclaw/capture-cron-stagger.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    entry: { path: entry, exports: ['computeJobNextRunAtMs', 'computeJobPreviousRunAtOrBeforeMs'], calls: observations.length * 2 },
    sourceRecords: [...records.values()], package: croner.receipt,
    importAliases: [{ specifier: '@openclaw/normalization-core', source: 'packages/normalization-core/src/expect.ts',
      exports: ['expectDefined'], barrelExecuted: false }, { specifier: 'node:crypto', kind: 'actual-node-builtin' }],
    deferredBindings: [...bindings.values()].map(row => ({ ...row, invocationCount: 0 })), deferredCalls,
    scope: { pureCronNextExecuted: true, pureCronPreviousExecuted: true, staggerNormalizationExecuted: true,
      cronerExecuted: true, jobLifecycleExecuted: false, toolFactoryExecuted: false, synapsisExecutionProved: false },
    limits: [
      'Pure exported next/previous cron computation executes from complete unchanged pinned modules; this does not run job service mutation, timer ownership, lifecycle, runtime assembly or model-facing tools.',
      'Croner10.0.1 whole ESM implementation executes. Its archive integrity matches the pinned upstream lock; archive/module/runtime/exporter hashes and complete reference blob receipts are retained.',
      'Unused lifecycle imports have explicit throwing bindings with zero audited invocations. The normalization barrel resolves only its complete expect.ts leaf, not the whole barrel.',
      'All scheduling observations carry explicit effective staggerMs. New automation defaults versus legacy omitted-stagger compatibility is a separate Synapsis data-layer contract.',
      'Six-field cron expressions appear only in default-detection vectors. No local six-field cron parser support or full cron grammar equivalence is claimed.',
      'Previous occurrence is reference-source evidence only until a separately verified Synapsis previous-occurrence API exists.',
      'hashDerivedOffsetMs is independently derived from actual node:crypto SHA256, not a private function return; complete pinned computeJobNextRunAtMs executes the private offset function for every uncached job/window key.',
    ], normalization, defaults, observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-cron-stagger.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureCronStagger(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], observations: result.observations.length,
    calls: result.entry.calls, wholeModules: result.sourceRecords.length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles, deferredInvocations: result.deferredCalls.length }) + '\n');
}
