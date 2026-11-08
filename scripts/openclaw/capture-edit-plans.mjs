// Ordinary pure planner observations from complete pinned OpenClaw modules.
// This does not execute edit.ts/write.ts, file effects, queues, or a Worker.
import assert from 'node:assert/strict';
import { Buffer as NodeBuffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import vm from 'node:vm';

const PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const EDIT_ENTRY = 'src/agents/sessions/tools/edit-diff.ts';
const WRITE_ENTRY = 'src/agents/sessions/tools/file-diff.ts';
const HARNESS = 'scripts/openclaw/capture-edit-plans.mjs';
const TRANSFORMATION = 'node:module.stripTypeScriptTypes(mode=strip,sourceMap=false)';
const DIFF_INTEGRITY = 'sha512-svtcdpS8CgJyqAjEQIXdb3OjhFVVYjzGAPO8WGCmRbrml64SPw/jJD4GoE98aR7r25A0XcgrK3F02yw9R/vhQw==';
const DIFF_PREFIX = 'diff@9.0.0/';
const SOURCE_HASHES = {
  LICENSE: '9efd316ecf1c4c60f6fd5d26433142fff2b6794d7d328e9bc6179b29bf9c82a4',
  'tsconfig.json': '7ccd7e1a86ea71116777e6fc8836b050c0b0c3307ea04a1738663a03ddb798f5',
  'package.json': '5f3a32b44b1d1a3eb9e8628845e195d054e4e41b28b1349d7dbc7dff723d9920',
  'pnpm-lock.yaml': '8ee0f9e7c0bcdecec3d791dff04f2df1f5c608c60e57fbafaf241c765eebd8d7',
  [EDIT_ENTRY]: 'a3e7ee440f55d0d4d6479b7a27219358e18e1e00a66acbc9e57425b7544e33fc',
  [WRITE_ENTRY]: 'd0fd2940666cae5607dfe6023c68312b2f7b0721f485e760a8a292404878d88a',
  'src/agents/sessions/tools/edit-replacements.ts': '98748d589728c943599fc304e087bbaf216385188d6bc92dfd339a01639be8ba',
  'src/agents/line-endings.ts': 'ee524e9a8205f430b90571091b2095ec496faa62ecc73a1851a5067521b48fad',
  'src/agents/tool-input-error.ts': '70582ae2f67d5d23ce514ee93f249e2c659ddf32e7bf70b1692dcadcf03af7bc',
  'src/shared/levenshtein-distance.ts': '83b6499c03c700fba9362d21f90e9d7415741d000bce350585828fd42cb549c0',
  'packages/normalization-core/src/index.ts': 'ae53275a1aba0f142533ad09efcac8fea3ee9ed7db06cfaaff827cec17c1e770',
  'packages/normalization-core/src/balanced-json.ts': '8146d5a69413b7d246127842446bc5dee6458524a49278b3400ffab818737ca7',
  'packages/normalization-core/src/boolean-coercion.ts': '80e0ae20af6854c84ca9cb970be7668dbfb6364e091457ad5e05b2fb2f0cfc06',
  'packages/normalization-core/src/cjk-chars.ts': '4fd72b01592ca56ac87842841ccac645d1bb4d7268ba89a154c95190d49b41d1',
  'packages/normalization-core/src/code-points.ts': '0d1f6eb4f23a2e8b86ae3bbe8a095536e33c1fda6b2d64bfca00a8ad93983d8e',
  'packages/normalization-core/src/error-coercion.ts': 'b7f977eb4b8d49b849412df8ea194ea37edc8ff333325e8122bd42ce6a42d629',
  'packages/normalization-core/src/expect.ts': 'ea995c248b00f6c9e17bbc9c3085971feeb0ee614d2bd9c8c902e8bc26cacb7a',
  'packages/normalization-core/src/format.ts': 'e629a028da50930716a7991f07741709ac6a481f22be43f558f3252371bdea03',
  'packages/normalization-core/src/json-coercion.ts': 'de0883df2f119da1a06a5d1731a1b68b019fe822b79453b4c6cb2439364431b8',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
  'packages/normalization-core/src/record-coerce.ts': '541c179840c2cad4edc5c8103f77cc7f8c6b1ee5ec3e52c7c9fe097b18917f1c',
  'packages/normalization-core/src/response-bytes.ts': '0b05d3d7fd06dd61c2aa95f871092378fa9f791d0a9a52bc9a67786f15f338fc',
  'packages/normalization-core/src/stable-stringify.ts': '675e4f2f44f143aef1cb0f069e77eac91fe3a3d693202344d503ebd987eee128',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'packages/normalization-core/src/string-normalization.ts': '3150b04501197ef417d2e2d1efa1e3160cc41ddec7505a6f4d756a654138ae3c',
  'packages/normalization-core/src/text-decoding.ts': 'f686401f7b95e09aa196f646a99a708c73d6068339d230cce029efa046cd14dc',
  'packages/normalization-core/src/utf16-slice.ts': '12fd3212b08522a1523263c92f654151ad01605ee48a0ff58a1256889fb7cb5f',
};
const ALIAS_TARGETS = {
  '@openclaw/normalization-core': 'packages/normalization-core/src/index.ts',
  '@openclaw/normalization-core/utf16-slice': 'packages/normalization-core/src/utf16-slice.ts',
};
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const byPath = (a, b) => compare(a.path, b.path);
const commandOptions = { timeout: 10_000, maxBuffer: 8 * 1024 * 1024 };

function verifiedSnapshot(root) {
  const git = args => execFileSync('git', ['-C', root, ...args], commandOptions);
  assert.equal(realpathSync(git(['rev-parse', '--show-toplevel']).toString().trim()), root);
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), PIN, 'reference commit');
  assert.equal(git(['status', '--porcelain', '--untracked-files=no']).toString(), '', 'clean tracked reference');
  const sources = Object.entries(SOURCE_HASHES).map(([path, sha256]) => {
    const file = resolve(root, path);
    assert.equal(realpathSync(file), file, `canonical source: ${path}`);
    const bytes = readFileSync(file);
    assert.ok(bytes.equals(git(['show', `${PIN}:${path}`])), `pinned blob bytes: ${path}`);
    assert.equal(digest(bytes), sha256, `pinned SHA256: ${path}`);
    const content = bytes.toString('utf8');
    assert.ok(NodeBuffer.from(content, 'utf8').equals(bytes), `complete UTF-8 source: ${path}`);
    return { path, content, sha256 };
  }).sort(byPath);
  assert.equal(sources.length, 27);
  return sources;
}

function sourceAliases(sources) {
  const config = sources.find(row => row.path === 'tsconfig.json');
  const paths = JSON.parse(config.content).compilerOptions.paths;
  const aliases = {};
  const evidence = Object.entries(ALIAS_TARGETS).map(([specifier, expected]) => {
    assert.deepEqual(paths[specifier], ['./' + expected], `original tsconfig alias: ${specifier}`);
    const target = paths[specifier][0].slice(2);
    aliases[specifier] = target;
    return { specifier, target, originalMapping: paths[specifier][0], path: config.path, sourceSha256: config.sha256 };
  });
  return { aliases, evidence };
}

// Retain the entire real package, including declarations, CJS, dist and LICENSE.
function packageFiles(root, directory = '') {
  return readdirSync(resolve(root, directory)).sort(compare).flatMap(name => {
    const path = directory ? directory + '/' + name : name;
    const file = resolve(root, path);
    assert.equal(realpathSync(file), file, `canonical dependency path: ${path}`);
    const stat = lstatSync(file);
    if (stat.isDirectory()) return packageFiles(root, path);
    assert.ok(stat.isFile(), `regular dependency file: ${path}`);
    const bytes = readFileSync(file);
    return [{ path, base64: bytes.toString('base64'), sha256: digest(bytes) }];
  }).sort(byPath);
}

function verifiedDependency(root, sources) {
  const sourcePackage = sources.find(row => row.path === 'package.json');
  const sourceLock = sources.find(row => row.path === 'pnpm-lock.yaml');
  assert.equal(JSON.parse(sourcePackage.content).dependencies.diff, '9.0.0', 'original manifest dependency');
  const lockRecord = sourceLock.content.match(/^  diff@9\.0\.0:\n    resolution: \{integrity: ([^}\n]+)\}/m);
  assert.ok(lockRecord, 'original diff lock record');
  assert.equal(lockRecord[1], DIFF_INTEGRITY, 'original lock integrity');
  assert.match(sourceLock.content, /\n      diff:\n        specifier: 9\.0\.0\n        version: 9\.0\.0\n/);
  const archivePath = resolve(root, '..', 'diff-9.0.0.tgz');
  assert.equal(realpathSync(archivePath), archivePath, 'canonical dependency archive');
  const archiveBytes = readFileSync(archivePath);
  const integrity = 'sha512-' + createHash('sha512').update(archiveBytes).digest('base64');
  assert.equal(integrity, DIFF_INTEGRITY, 'archive matches the original lock SHA512');
  const tar = args => execFileSync('tar', [...args, archivePath], commandOptions);
  const members = tar(['-tzf']).toString('utf8').trimEnd().split('\n');
  const files = packageFiles(root);
  assert.equal(files.length, 136, 'complete diff9 package file count');
  assert.equal(new Set(members).size, members.length, 'unique archive entries');
  assert.deepEqual(members.filter(path => !path.endsWith('/')).sort(compare), files.map(row => 'package/' + row.path).sort(compare));
  for (const file of files) {
    // -O streams each original archive member; no extraction or file mutation.
    const original = execFileSync('tar', ['-xOzf', archivePath, '--', 'package/' + file.path], commandOptions);
    assert.ok(original.equals(NodeBuffer.from(file.base64, 'base64')), `extracted bytes equal verified archive: ${file.path}`);
  }
  const manifestRow = files.find(row => row.path === 'package.json');
  const manifest = JSON.parse(NodeBuffer.from(manifestRow.base64, 'base64').toString('utf8'));
  assert.equal(manifest.name, 'diff');
  assert.equal(manifest.version, '9.0.0');
  assert.equal(manifest.license, 'BSD-3-Clause');
  assert.equal(manifest.type, 'module');
  assert.equal(manifest.dependencies, undefined, 'diff9 has no runtime package dependencies');
  const entry = manifest.exports['.'].import.default;
  assert.equal(typeof entry, 'string', 'real import/default package export');
  const entryPath = posix.normalize(entry);
  assert.ok(files.some(row => row.path === entryPath), 'actual exported ESM entry bytes retained');
  const esmFiles = files.filter(row => row.path.startsWith('libesm/') && row.path.endsWith('.js'));
  assert.equal(esmFiles.length, 21);
  const license = files.find(row => row.path === 'LICENSE');
  const content = NodeBuffer.from(license.base64, 'base64').toString('utf8');
  assert.ok(content.startsWith('BSD 3-Clause License\n'));
  return {
    name: manifest.name, version: manifest.version, integrity, files,
    entry: { path: entryPath, originalExport: entry, conditions: ['import', 'default'], manifestSha256: manifestRow.sha256 },
    license: { id: manifest.license, path: license.path, content, sha256: license.sha256 },
    archive: {
      path: 'diff-9.0.0.tgz', url: 'https://registry.npmjs.org/diff/-/diff-9.0.0.tgz',
      bytes: archiveBytes.length, base64: archiveBytes.toString('base64'),
      sha256: digest(archiveBytes), integrity, extractedFileBytesVerified: true,
    },
    originalDependency: { manifest: sourcePackage.path, manifestSha256: sourcePackage.sha256, lock: sourceLock.path, lockSha256: sourceLock.sha256 },
    completeFileBytes: files.reduce((sum, row) => sum + NodeBuffer.from(row.base64, 'base64').length, 0),
  };
}

function verifyDependencyUnchanged(root, dependency) {
  assert.deepEqual(packageFiles(root), dependency.files, 'entire dependency package unchanged after capture');
  const archiveBytes = readFileSync(resolve(root, '..', dependency.archive.path));
  assert.equal(archiveBytes.toString('base64'), dependency.archive.base64, 'verified archive unchanged after capture');
}

function recipes() {
  const edit = (id, content, edits) => ({ id, kind: 'edit', input: { content, edits, path: 'edit.txt' } });
  return [
    edit('original-snapshot', 'alpha\nbeta\ngamma\n', [
      { oldText: 'alpha', newText: 'beta' }, { oldText: 'beta', newText: 'BETA' },
    ]),
    edit('reversed-request', 'alpha\nbeta\ngamma\n', [
      { oldText: 'beta', newText: 'BETA' }, { oldText: 'alpha', newText: 'beta' },
    ]),
    edit('unicode-utf16', '😀 key\ncafe\u0301 tail\n', [
      { oldText: 'key', newText: '鍵' }, { oldText: 'cafe\u0301', newText: 'café' },
    ]),
    edit('identical-noop', '\uFEFFalpha\r\nkeep\n', [{ oldText: 'alpha', newText: 'alpha' }]),
    edit('normalized-noop', 'alpha\r\nkeep\r\n', [{ oldText: 'alpha\r\n', newText: 'alpha\n' }]),
    edit('bom-crlf', '\uFEFFalpha\r\nbeta\r\ngamma\r\n', [{ oldText: 'alpha\nbeta\n', newText: 'A\nB\nC\n' }]),
    edit('line-ending-style', '\uFEFFone\r\ntwo\nthree\rfour\r\n', [{ oldText: 'two\nthree\n', newText: 'TWO\nTHREE\nPLUS\n' }]),
    edit('fuzzy-preserves-untouched', '😀 oﬃce = “old”  \nkeep ﬁ + e\u0301\n', [{ oldText: 'office = "old"', newText: 'office = "new"' }]),
    { id: 'write-create', kind: 'write', input: { path: 'write.txt', content: 'new\n', created: true } },
    { id: 'write-overwrite', kind: 'write', input: { path: 'write.txt', content: 'new\n', beforeText: 'old\n', created: false } },
  ];
}

export async function captureEditPlans(referenceRoot, diffRoot) {
  const root = realpathSync(resolve(referenceRoot));
  const packageRoot = realpathSync(resolve(diffRoot));
  const sources = verifiedSnapshot(root);
  const { aliases, evidence } = sourceAliases(sources);
  const dependency = verifiedDependency(packageRoot, sources);
  const harnessBytes = readFileSync(new URL(import.meta.url));
  // These are real Node globals. Intl.Segmenter remains the actual ICU-backed
  // constructor, including the original planner's module-scoped instance.
  const context = vm.createContext({
    Buffer: NodeBuffer, Intl, TextDecoder, TextEncoder, atob, btoa, setTimeout, clearTimeout,
  });
  const modules = new Map();
  const transforms = [];
  const links = new Map();
  for (const source of sources.filter(row => row.path.endsWith('.ts'))) {
    const executable = stripTypeScriptTypes(source.content, { mode: 'strip', sourceMap: false });
    transforms.push({
      path: source.path, sourceSha256: source.sha256, executable,
      executableSha256: digest(executable), transformation: TRANSFORMATION,
    });
    modules.set(source.path, new vm.SourceTextModule(executable, { context, identifier: source.path }));
  }
  const esmFiles = dependency.files.filter(row => row.path.startsWith('libesm/') && row.path.endsWith('.js'));
  for (const file of esmFiles) {
    const bytes = NodeBuffer.from(file.base64, 'base64');
    const executable = bytes.toString('utf8');
    assert.ok(NodeBuffer.from(executable, 'utf8').equals(bytes), `whole ESM UTF-8 bytes: ${file.path}`);
    modules.set(DIFF_PREFIX + file.path, new vm.SourceTextModule(executable, {
      context, identifier: DIFF_PREFIX + file.path,
    }));
  }
  assert.equal(transforms.length, 23);
  const entry = modules.get(EDIT_ENTRY);
  await entry.link((specifier, importer) => {
    let target;
    let kind;
    if (importer.identifier.startsWith(DIFF_PREFIX)) {
      assert.ok(specifier.startsWith('.') && specifier.endsWith('.js'), `original dependency relative import: ${specifier}`);
      const relative = posix.normalize(posix.join(posix.dirname(importer.identifier.slice(DIFF_PREFIX.length)), specifier));
      target = DIFF_PREFIX + relative;
      kind = 'original-dependency-relative-esm';
    } else if (specifier === 'diff') {
      target = DIFF_PREFIX + dependency.entry.path;
      kind = 'original-package-import-default-export';
    } else if (Object.hasOwn(aliases, specifier)) {
      target = aliases[specifier];
      kind = 'exact-original-tsconfig-source-alias';
    } else {
      assert.ok(specifier.startsWith('.') && /\.(js|ts)$/.test(specifier), `original source relative import: ${specifier}`);
      target = posix.normalize(posix.join(posix.dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts');
      kind = specifier.endsWith('.ts') ? 'original-relative-ts' : 'original-relative-js-to-ts';
    }
    assert.ok(modules.has(target), `complete original module in closure: ${target}`);
    links.set(`${importer.identifier}:${specifier}`, { importer: importer.identifier, specifier, target, kind });
    return modules.get(target);
  });
  await entry.evaluate({ timeout: 10_000 });
  for (const source of transforms) assert.equal(modules.get(source.path).status, 'evaluated', source.path);
  assert.equal(context.Buffer, NodeBuffer);
  assert.equal(context.Intl, Intl);
  assert.equal(vm.runInContext('Intl.Segmenter', context, { timeout: 10_000 }), Intl.Segmenter);
  const dependencyModules = esmFiles.map(file => ({
    path: file.path, sourceSha256: file.sha256, executableSha256: file.sha256,
    transformation: 'none; complete original package ESM bytes',
    status: modules.get(DIFF_PREFIX + file.path).status,
  })).sort(byPath);
  const linkedDependencyTargets = new Set([...links.values()].map(row => row.target).filter(path => path.startsWith(DIFF_PREFIX)));
  for (const target of linkedDependencyTargets) assert.equal(modules.get(target).status, 'evaluated', target);
  const write = modules.get(WRITE_ENTRY);
  const cases = recipes().map(({ id, kind, input }) => {
    const result = kind === 'edit'
      ? entry.namespace.prepareFileEdit(input.content, input.edits, input.path)
      : write.namespace.prepareFileWriteDiff(input);
    assert.ok(result && typeof result === 'object', `ordinary planner result: ${id}`);
    return { id, kind, input, result: plain(result) };
  });
  assert.deepEqual(verifiedSnapshot(root), sources, 'reference pin and whole original blob bytes unchanged after capture');
  verifyDependencyUnchanged(packageRoot, dependency);
  assert.ok(readFileSync(new URL(import.meta.url)).equals(harnessBytes), 'harness unchanged during capture');
  const license = sources.find(row => row.path === 'LICENSE');
  assert.equal(JSON.parse(sources.find(row => row.path === 'package.json').content).license, 'MIT');
  return {
    version: 1,
    reference: {
      repository: 'openclaw/openclaw', commit: PIN,
      trackedCleanBefore: true, trackedCleanAfter: true,
      originalBlobBytesVerifiedBeforeAndAfter: true,
    },
    cases,
    provenance: {
      sources, transforms: transforms.sort(byPath),
      dependency: { ...dependency, esmModules: dependencyModules, packageBytesUnchangedAfterCapture: true },
      sourceLicense: { id: 'MIT', path: license.path, sha256: license.sha256 },
      aliases, aliasEvidence: evidence,
      links: [...links.values()].sort((a, b) => compare(`${a.importer}:${a.specifier}`, `${b.importer}:${b.specifier}`)),
      nativeEvidence: { globalBufferIsNodeBuffer: true, globalIntlIsNodeIntl: true, segmenterIsNodeIntlSegmenter: true },
      nativeGlobals: ['Buffer', 'Intl', 'TextDecoder', 'TextEncoder', 'atob', 'btoa', 'setTimeout', 'clearTimeout'],
      moduleIdentity: 'One cached SourceTextModule per canonical original source or dependency path in one shared VM realm; relative .js and .ts imports share their original source identity',
      harness: { path: HARNESS, sha256: digest(harnessBytes) },
      runtime: {
        node: process.version, v8: process.versions.v8, unicode: process.versions.unicode,
        icu: process.versions.icu, cldr: process.versions.cldr,
        platform: process.platform, arch: process.arch,
        loader: 'node:vm.SourceTextModule', transformation: TRANSFORMATION,
      },
    },
    boundaries: {
      invocation: ['prepareFileEdit(content, edits, path)', 'prepareFileWriteDiff(input)'],
      completeOriginalModules: transforms.length,
      retainedDependencyEsmModules: dependencyModules.length,
      evaluatedDependencyEsmModules: dependencyModules.filter(row => row.status === 'evaluated').length,
      serviceBindings: [], sourceRewrites: [], effectEnvelopes: [],
      ordinaryPurePlansOnly: true,
      limits: [
        'Eight literal edit inputs and two literal write inputs invoke the actual pure planner exports; private functions are retained in complete modules.',
        'Unlinked dependency ESM files are retained as package bytes and identified by status; the real manifest entry and its full transitive graph are evaluated.',
        'No edit.ts/write.ts tool constructors, Worker entrypoint, WorkerTaskPool, mutation queue, path/source authority, file effects or persisted-byte verification are executed.',
        'Write results are pure diff receipts; write-tool success/no-op envelopes and byte-count messages are not observed or fabricated.',
        'Exact/normalized edit no-ops return planner messages only; no actual filesystem byte-retention claim is made.',
        'Successful ordinary mixed line endings are exercised; no mixed success/failure case is exercised.',
        'No security, permission, auth, TLS, negative, unavailable, failure, cancellation, crash, expiry, budget, real-provider or overflow/underflow scenario is exercised.',
      ],
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: {
    'reference-root': { type: 'string', default: '/tmp/openclaw-488631c' },
    'diff-root': { type: 'string' }, output: { type: 'string' },
  } });
  assert.ok(values['diff-root'], 'Provide the verified diff9 package root with sibling diff-9.0.0.tgz');
  const report = await captureEditPlans(values['reference-root'], values['diff-root']);
  const json = JSON.stringify(report, null, 2) + '\n';
  if (values.output) writeFileSync(values.output, json);
  else process.stdout.write(json);
}
