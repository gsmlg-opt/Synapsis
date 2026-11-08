// Metadata-only installed-skill search: whole unchanged pinned source modules.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const SKILL_SEARCH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const catalogPath = 'src/agents/installed-skill-catalog.ts';
const sourcePins = {
  [catalogPath]: ['32a53ad7a72e08bd7a4455dbad2ccb539c03be55569cf8d1f6c0bd38b7da500a', '0e940a712dcc67344cb9040510db1c3a2f64d42d'],
  'src/agents/tool-search-ranking.ts': ['aed9772d22e1e05d5de768357a12250cd074950f16ada7d3fb4cc64834938385', 'e6ceca14d41e734cfa783ae47eaa4f9aafeef4c7'],
  'src/agents/tool-search-index.ts': ['04c8c2578e677b8aa705ef20502c94e4cd57fdcbcaf9ec2fb885802920e201b0', 'b3dd8b0e847a282516de2ca37690fb2d2e49818e'],
  'src/infra/lru-cache.ts': ['8915c917e7580b9ad6614337cef68a447a7cdd44e838ba9acd2e7f64df9050f6', 'd8108e0be2434d296f3ae2ffd21d74d3c9c16b4b'],
  'packages/normalization-core/src/record-coerce.ts': ['541c179840c2cad4edc5c8103f77cc7f8c6b1ee5ec3e52c7c9fe097b18917f1c', '78eba9cd0e4c75f94e71dfb3fcb7f4cf4eeeef16'],
};
const deferred = [
  [catalogPath, '../infra/abort-signal.js', 'src/infra/abort-signal.ts', ['racePromiseWithAbortSignal']],
  [catalogPath, '../infra/fs-safe.js', 'src/infra/fs-safe.ts', ['openLocalFileSafely', 'readLocalFileSafely']],
  [catalogPath, './code-mode-skills.js', 'src/agents/code-mode-skills.ts', ['readCodeModeSkill']],
  [catalogPath, './tools/common.js', 'src/agents/tools/common.ts', ['ToolInputError']],
];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));

// Inputs are authored before capture. Independent literal expectations live in
// skill-search-ranking-functional.test.mjs and the Elixir core tests.
export function skillSearchRankingVectors() {
  const entries = rows => rows.map(([name, description, marker], index) => ({
    name, description, location: `supplied://skills/${marker ?? index}`,
    marker: marker ?? `entry-${index}`,
  }));
  const multiword = [['alpha', 'Review repository reference'], ['workflow', 'Review repository changes']];
  const frequency = [['alpha', 'signal'], ['beta', 'signal signal signal']];
  return [
    ['multiword', 'changes repository', multiword],
    ['reordered', 'repository changes', multiword],
    ['doubled-stem', 'running', [['runner', 'Running tasks'], ['planner', 'Plan schedules']]],
    ['repeated-suffix', 'reminders', [['calendar', 'Remind'], ['handbook', 'Ordinary guidance']]],
    ['ies-policy', 'policies', [['handbook', 'policy'], ['recipe', 'cooking']]],
    ['ies-cookie', 'cookies', [['recipe', 'cookie'], ['handbook', 'policy']]],
    ['identifier-parts', 'server reader 42', [['HTTPServer42_reader', 'Parse responses'], ['manual', 'Ordinary guidance']]],
    ['non-latin', '整理 团队知识', [['知识整理', '团队知识 整理'], ['manual', 'Ordinary guidance']]],
    ['exact-case', 'review', [['Review', 'review review'], ['review', 'general guide']]],
    ['first-folded-name', 'reView', [['REVIEW', 'general guide'], ['Review', 'review review']]],
    ['padded-name', ' \tReview \n', [['Review', 'general guide'], ['review', 'review review']]],
    ['punctuation-name', '.', [['.', ''], ['manual', 'Ordinary handbook']]],
    ['frequency', 'signal', frequency],
    ['length', 'signal', [['alpha', 'signal additional ordinary reference context'], ['beta', 'signal']]],
    ['name-tie', 'signal', [['zeta', 'signal'], ['alpha', 'signal']]],
    ['duplicate-query', 'signal signal signal', frequency],
    ['stable-duplicates', 'signal', [['same', 'signal', 'first'], ['same', 'signal', 'second']]],
    ['utf16-name-tie', 'catalog', [['\uE000', 'catalog'], ['😀', 'catalog']]],
    ['greek-final-sigma', 'ος', [['greek-guide', 'ΟΣ'], ['manual', 'Ordinary guidance']]],
    ['dotted-i', 'İstanbul', [['İSTANBUL', 'Travel notes'], ['manual', 'Ordinary guidance']]],
    ['literal-skill-query', 'lookup', [['lookup', 'literal catalog'], ['web', 'search find']]],
    ['kept-double-stem', 'processing', [['pipeline', 'Process logs'], ['manual', 'Ordinary guidance']]],
  ].map(([id, query, rows]) => ({ id, query, entries: entries(rows) }));
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), SKILL_SEARCH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', SKILL_SEARCH_PIN]).split('\0').filter(Boolean).map(row => {
    const [header, path] = row.split('\t');
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
  assert.equal(files.length, 58558);
  const tree = git(root, ['rev-parse', `${SKILL_SEARCH_PIN}^{tree}`]);
  assert.equal(tree, '47509a47273231ab15f57252960fe716d7379ffb');
  return { files: new Map(files.map(row => [row.path, row])), receipt: {
    commit: SKILL_SEARCH_PIN, tree, trackedClean: true, verifiedTrackedFiles: files.length,
    filesSha256: hash(JSON.stringify(files)),
  } };
}

export async function captureSkillSearchRanking(sourceRoot = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(sourceRoot);
  assert.equal(root, fixedRoot);
  const before = verifyCheckout(root);
  const context = vm.createContext({ Buffer, __deferredCalls: [] }, { codeGeneration: { strings: false, wasm: false } });
  const modules = new Map();
  const sourceRecords = new Map();
  const importBindings = [];
  const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';

  function record(path, executed) {
    const tracked = before.files.get(path);
    assert.ok(tracked, path);
    const bytes = readFileSync(join(root, path));
    assert.equal(hash(bytes), tracked.sha256, path);
    const expected = sourcePins[path];
    if (expected) assert.deepEqual([tracked.sha256, tracked.gitBlob], expected, path);
    sourceRecords.set(path, { ...tracked, bytes: bytes.length, executed,
      originalSourceExecuted: executed, wholeModule: executed, provenanceOnly: !executed });
    return bytes.toString('utf8');
  }

  function original(path) {
    if (modules.has(path)) return modules.get(path);
    assert.ok(Object.hasOwn(sourcePins, path), path);
    const executable = stripTypeScriptTypes(record(path, true), { mode: 'transform', sourceMap: false });
    Object.assign(sourceRecords.get(path), { transformation, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context, identifier: path,
      importModuleDynamically: () => { context.__deferredCalls.push('dynamic-import'); throw Error('Undeclared dynamic import'); } });
    modules.set(path, mod);
    return mod;
  }

  function link(specifier, importer) {
    const owner = importer.identifier;
    const edge = deferred.find(([path, imported]) => path === owner && imported === specifier);
    if (edge) {
      const [, , source, exports] = edge;
      record(source, false);
      const identifier = `uncalled:${owner}:${specifier}`;
      if (!modules.has(identifier)) {
        const code = exports.map(name => `export function ${name}(){__deferredCalls.push(${JSON.stringify({ importer: owner, specifier, export: name })});throw Error('Uncalled metadata-search import invoked');}`).join('\n');
        importBindings.push({ importer: owner, specifier, kind: 'throwing-uncalled-import-edge', source,
          exports, generatedCode: code, generatedSha256: hash(code), originalSourceExecuted: false });
        modules.set(identifier, new vm.SourceTextModule(code, { context, identifier }));
      }
      return modules.get(identifier);
    }
    if (specifier === 'node:crypto') {
      const identifier = 'native:node:crypto';
      if (!modules.has(identifier)) {
        importBindings.push({ importer: owner, specifier, kind: 'actual-platform-builtin', exports: ['createHash'] });
        modules.set(identifier, new vm.SyntheticModule(['createHash'], function () { this.setExport('createHash', createHash); }, { context, identifier }));
      }
      return modules.get(identifier);
    }
    const target = specifier === '@openclaw/normalization-core/record-coerce'
      ? 'packages/normalization-core/src/record-coerce.ts'
      : relative(root, resolve(root, dirname(owner), specifier)).replace(/\.js$/, '.ts');
    assert.ok(Object.hasOwn(sourcePins, target), `${owner}: ${specifier}`);
    importBindings.push({ importer: owner, specifier, kind: 'whole-unchanged-source-module', target });
    return original(target);
  }

  const catalog = original(catalogPath);
  await catalog.link(link);
  await catalog.evaluate({ timeout: 1000 });
  context.__catalog = catalog.namespace;
  const observations = [];
  for (const input of skillSearchRankingVectors()) {
    context.__serialized = JSON.stringify(input);
    new vm.Script('globalThis.__input=JSON.parse(__serialized);').runInContext(context, { timeout: 1000 });
    const result = await new vm.Script('__catalog.searchInstalledSkills(__input.entries,__input.query)').runInContext(context, { timeout: 1000 });
    observations.push({ ...input, result: plain(result), argumentsAfter: plain(context.__input) });
    assert.deepEqual(plain(context.__input), input, 'input preserved: ' + input.id);
  }
  assert.deepEqual(plain(context.__deferredCalls), []);
  const after = verifyCheckout(root);
  assert.deepEqual(before.receipt, after.receipt);
  return {
    schemaVersion: 1, referencePin: SKILL_SEARCH_PIN,
    exporter: { path: 'scripts/openclaw/capture-skill-search-ranking.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    sourceRecords: [...sourceRecords.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
    importBindings, observations, deferredCalls: plain(context.__deferredCalls),
    boundaries: { actualInstalledCatalog: true, actualRanking: true, actualIndex: true, actualLruCache: true,
      actualRecordCoerceModule: true, metadataOnly: true, bodyReadExecuted: false,
      assemblyExecuted: false, eligibilityExecuted: false, persistenceExecuted: false, networkExecuted: false },
    limits: [
      'Whole unchanged installed-skill-catalog, tool-search-ranking, tool-search-index, LruCache and record-coerce modules execute after TypeScript-only transformation; no ranking/search replacement or source-region extraction.',
      'Inputs are explicit supplied already-eligible metadata catalogs. Installed discovery, assignment, eligibility, owner freshness, tool assembly, provider transport and persistence do not execute in this source oracle.',
      'searchInstalledSkills uses its ordinary default metadata-only mode. Body/filesystem reads, abort-race helpers, Code Mode instruction reading and common input-error imports are exact uncalled throwing edges, each recorded against its original source.',
      'All cases are ordinary positive searches below existing output/description limits. No budget, cache eviction, invalid input, negative/error, authority/permission, cancellation, failure or real-provider behavior is qualified.',
      'Synapsis keeps its existing source-qualified metadata, limits, snapshots and reads. This reference proves metadata lexical ordering only, not wholesale upstream output-contract or body-search parity.',
    ],
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 4, 'usage: capture-skill-search-ranking.mjs source-root output');
  const capture = await captureSkillSearchRanking(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ vectors: capture.observations.length, wholeModules: capture.sourceRecords.filter(row => row.executed).length }) + '\n');
}
