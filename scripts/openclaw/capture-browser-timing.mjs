// Complete pinned act-policy arithmetic. No Browser/driver/policy code executes.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, lstatSync, realpathSync, readlinkSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const BROWSER_TIMING_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const browser = 'extensions/browser/src/browser/';
const policyPath = browser + 'act-policy.ts';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sdkAliases = {
  'openclaw/plugin-sdk/number-runtime': 'packages/normalization-core/src/number-coercion.ts',
  'openclaw/plugin-sdk/string-coerce-runtime': 'packages/normalization-core/src/record-coerce.ts',
};
const provenancePaths = [
  'src/plugin-sdk/number-runtime.ts', 'src/plugin-sdk/string-coerce-runtime.ts',
  'extensions/browser/src/browser-tool.ts', 'extensions/browser/src/browser-tool-dispatch.ts',
  browser + 'client-actions.ts', browser + 'routes/agent.act.normalize.ts',
  browser + 'pw-tools-core.interactions.actions.ts', browser + 'pw-tools-core.interactions.content.ts',
  browser + 'pw-tools-core.interactions.execution.ts', browser + 'pw-tools-core.shared.ts',
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BROWSER_TIMING_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BROWSER_TIMING_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t');
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
  return { verified: true, commit: BROWSER_TIMING_PIN,
    tree: git(root, ['rev-parse', `${BROWSER_TIMING_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

function vectors() {
  const conditions = { text: 'ready', textGone: 'loading', selector: '#ready', url: '**/ready', loadState: 'load', fn: '() => true' };
  const row = (name, rawRequest, expectedMs, preparedRequest = rawRequest) => ({ name, rawRequest, preparedRequest, expectedMs });
  const click = { kind: 'click', ref: 'e1' };
  const wait = { kind: 'wait', timeMs: 0 };
  const type = { kind: 'type', ref: 'e1', text: 'abc', slowly: true, submit: true };
  return [
    row('model-local-default-click', click, 126250, { ...click, timeoutMs: 60000 }),
    row('model-local-zero-delay-wait', wait, 126250, { ...wait, timeoutMs: 60000 }),
    row('explicit-click', { ...click, timeoutMs: 45000 }, 96250),
    row('delayed-click-phases', { ...click, timeoutMs: 60000, delayMs: 5000 }, 130250),
    row('nested-sequential-waits', { kind: 'batch', actions: [{ kind: 'wait', timeMs: 30000 }, { kind: 'batch', actions: [{ kind: 'wait', timeMs: 30000 }, { kind: 'wait', timeMs: 30000 }] }] }, 95000),
    row('six-condition-wait', { kind: 'wait', timeMs: 10000, timeoutMs: 20000, ...conditions }, 135000),
    row('standalone-slow-type-submit', type, 185250, { ...type, timeoutMs: 60000 }),
    row('four-scroll-batch', { kind: 'batch', actions: Array.from({ length: 4 }, () => ({ kind: 'scrollIntoView', ref: 'e1' })) }, 86000),
    row('batch-shallow-defaults', { kind: 'batch', actions: [{ kind: 'type', ref: 'e1', text: 'abc', slowly: true, submit: true }, { kind: 'wait', ...conditions }] }, 149250),
    row('hundred-six-condition-waits', { kind: 'batch', actions: Array.from({ length: 100 }, () => ({ kind: 'wait', timeoutMs: 120000, ...conditions })) }, 72005000),
    row('hundred-delayed-six-condition-waits', { kind: 'batch', actions: Array.from({ length: 100 }, () => ({ kind: 'wait', timeMs: 30000, timeoutMs: 120000, ...conditions })) }, 75005000),
    row('recursive-budget-saturates', { kind: 'batch', actions: [
      { kind: 'clickCoords', x: 10, y: 20, timeoutMs: 2147000000 },
      { kind: 'clickCoords', x: 20, y: 30, timeoutMs: 2147000000 },
    ] }, 2147000000),
    row('phase-floor', { kind: 'batch', actions: Array.from({ length: 100 }, () => ({ kind: 'hover', ref: 'e1', timeoutMs: 100 })) }, 80000),
    row('phase-ceiling', { kind: 'batch', actions: [{ kind: 'wait', timeoutMs: 200000, ...conditions }] }, 725000),
    row('coordinate-double-delay', { kind: 'clickCoords', x: 10, y: 20, doubleClick: true, delayMs: 5000, timeoutMs: 1000 }, 21250),
  ];
}

export async function captureBrowserTiming(source) {
  assert.equal(process.versions.node, '24.22.1', 'use the supported fixed capture runtime');
  const root = realpathSync(source);
  const treeBefore = checkout(root);
  const context = vm.createContext({});
  const modules = new Map();
  const records = new Map();
  const pinnedBytes = path => {
    const bytes = readFileSync(join(root, path));
    const expected = execFileSync('git', ['-C', root, 'show', `${BROWSER_TIMING_PIN}:${path}`], { timeout: 30_000, maxBuffer: 8 * 1024 * 1024 });
    assert.ok(bytes.equals(expected), path);
    return bytes;
  };
  const load = path => {
    if (!modules.has(path)) {
      const bytes = pinnedBytes(path);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      records.set(path, { path, sha256: hash(bytes), executableSha256: hash(executable), executed: true, wholeModule: true });
      modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path }));
    }
    return modules.get(path);
  };
  const module = load(policyPath);
  await module.link((specifier, parent) => {
    const path = sdkAliases[specifier] ?? (specifier.startsWith('.') && /\.[jt]s$/.test(specifier)
      ? relative(root, resolve(root, dirname(parent.identifier), specifier)).replace(/\.js$/, '.ts') : undefined);
    assert.ok(path && !path.startsWith('..'), `unconfigured source import ${specifier}`);
    return load(path);
  });
  await module.evaluate({ timeout: 1000 });
  for (const path of provenancePaths) records.set(path, { path, sha256: hash(pinnedBytes(path)), executed: false, provenanceOnly: true });
  const observations = vectors().map(vector => {
    const rawRequest = plain(vector.rawRequest);
    const preparedRequest = plain(vector.preparedRequest);
    context.request = preparedRequest;
    context.policy = module.namespace;
    const requestTimeoutMs = new vm.Script('policy.resolveBrowserActRequestTimeoutMs(request)').runInContext(context, { timeout: 1000 });
    assert.equal(requestTimeoutMs, vector.expectedMs, vector.name);
    assert.deepEqual(rawRequest, vector.rawRequest);
    assert.deepEqual(preparedRequest, vector.preparedRequest);
    return { name: vector.name, rawRequest, preparedRequest, requestTimeoutMs,
      rawRequestAfter: plain(rawRequest), preparedRequestAfter: plain(preparedRequest) };
  });
  const treeAfter = checkout(root);
  assert.deepEqual(treeAfter, treeBefore);
  return {
    referenceCommit: BROWSER_TIMING_PIN, runtime: process.versions.node,
    exporterSha256: hash(readFileSync(fileURLToPath(import.meta.url))),
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false), unchanged whole modules',
    sourceTree: { before: treeBefore, after: treeAfter },
    sourceRecords: [...records.values()].sort((a, b) => a.path.localeCompare(b.path)),
    importRedirections: sdkAliases,
    preparation: { method: 'Explicit raw/prepared vector pairs reflect source-reviewed shallow model-local defaults.',
      source: 'extensions/browser/src/browser-tool-dispatch.ts:79-93,405-412', sourceExecuted: false,
      boundary: 'browser-tool-dispatch, full browser tool/runtime/driver/navigation assembly are not executed.' },
    boundaries: [
      'Complete unchanged act-policy and actual pure normalization/constants/act-kinds/timer modules execute, including private recursive runtime calculation and existing-session outer arithmetic.',
      'All tracked source blobs verified before/after and loaded bytes compared with the fixed pin; SDK aliases redirect to complete actual pure implementation modules.',
      'Prepared input pairs are explicit source-reviewed model-local examples, not an executed browser-tool-dispatch claim. Batches retain their raw child timeouts.',
      'Only arithmetic executes. No Browser operation, driver, navigation policy/recheck, provider, network, runtime assembly, security/permission or refusal suite executes.',
      'Host wait/ref/selector-fill/targeted-press/drag/slow-delay extensions are separate conservative adaptations; this exact-source fixture does not claim those as reference behavior.',
      'Large valid calculation and saturation cases allocate arithmetic inputs only; they do not wait for the selected duration or establish full Browser parity.',
    ],
    vectors: observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const output = process.argv[3];
  assert.ok(output, 'usage: capture-browser-timing.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureBrowserTiming(process.argv[2]);
  writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output, vectors: result.vectors.length, executedModules: result.sourceRecords.filter(row => row.executed).length,
    provenanceOnly: result.sourceRecords.filter(row => !row.executed).length, trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
