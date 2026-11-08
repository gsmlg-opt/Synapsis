import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Build-time filesystem access only. Generated runtime modules receive text and
// receipt labels; no fixture, source checkout, TS loader or npm tree is needed.
const repository = fileURLToPath(new URL('../', import.meta.url));
const sourceRoot = join(repository, 'packages/tool-host/src/filesystem');
const vendorRoot = join(sourceRoot, 'vendor/openclaw');
const pinnedBytes = readFileSync(join(sourceRoot, 'vendor/provenance.json'));
const pinned = JSON.parse(pinnedBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index], value = process.argv[index + 1];
  if (!['--output', '--diff-root', '--diff-archive'].includes(key) || !value || options.has(key)) {
    throw new Error('Usage: build-filesystem-planner.mjs [--output directory] [--diff-root directory] [--diff-archive archive.tgz]');
  }
  options.set(key, resolve(value));
}
const output = options.get('--output') ?? join(repository, 'apps/synapsis_core/priv/filesystem_planner');
const toolHostRequire = createRequire(join(repository, 'packages/tool-host/package.json'));

function packageRoot() {
  if (options.has('--diff-root')) return options.get('--diff-root');
  // Resolve from tool-host's declared dependency, independently of cwd. Start
  // with the actual resolved entry because package exports may hide package.json.
  let root = dirname(toolHostRequire.resolve('diff'));
  while (!existsSync(join(root, 'package.json')) || JSON.parse(readFileSync(join(root, 'package.json'))).name !== 'diff') {
    const parent = dirname(root);
    if (parent === root) throw new Error('Cannot locate resolved diff package manifest');
    root = parent;
  }
  return root;
}

function assertHash(bytes, expected, label) {
  if (sha256(bytes) !== expected) throw new Error(`Pinned SHA256 mismatch: ${label}`);
}

function filesUnder(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true })
    .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) return filesUnder(root, path);
      if (!entry.isFile()) throw new Error(`Expected regular artifact file: ${path}`);
      return [path];
    });
}

const artifacts = new Map();
const add = (path, bytes) => {
  if (artifacts.has(path)) throw new Error(`Duplicate artifact: ${path}`);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
};
const moduleTargets = new Map(pinned.sources.map(source => [source.path, `vendor/openclaw/${source.path.replace(/\.ts$/, '.mjs')}`]));
if (moduleTargets.size !== 23 || pinned.diff.files.length !== 136) throw new Error('Incomplete pinned closure');
const importMap = [];

// The pinned graph contains default/named imports and named/star re-exports.
// Anchoring at the declaration and limiting the grammar to these forms avoids
// replacing arbitrary string literals, comments, function bodies or templates.
// The independent pinned link list must match every declaration exactly.
const staticModule = /^([\t ]*(?:import|export)\s+(?:\{[^}]*\}|\*(?:\s+as\s+\w+)?|[A-Za-z_$][\w$]*)\s+from\s*)(["'])([^"'\r\n]+)\2/gm;
function moduleLinks(code, importer) {
  const actual = [...code.matchAll(staticModule)];
  const expected = pinned.links.filter(link => link.importer === importer);
  const actualNames = actual.map(match => match[3]).sort();
  const expectedNames = expected.map(link => link.specifier).sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) throw new Error(`Pinned module graph mismatch: ${importer}`);
  return actual.map(match => ({ match, link: expected.find(link => link.specifier === match[3]) }));
}

const sourceRecords = [];
for (const source of pinned.sources) {
  const original = readFileSync(join(vendorRoot, source.path));
  assertHash(original, source.sha256, source.path);
  const stripped = stripTypeScriptTypes(original.toString('utf8'), { mode: 'strip', sourceMap: false });
  const target = moduleTargets.get(source.path);
  let generated = stripped;
  for (const { match, link } of moduleLinks(stripped, source.path).reverse()) {
    const dependencyTarget = link.target === `diff@${pinned.diff.version}/${pinned.diff.entry.path}`
      ? `vendor/diff/${pinned.diff.entry.path}` : moduleTargets.get(link.target);
    if (!dependencyTarget) throw new Error(`Import outside pinned closure: ${source.path} -> ${link.target}`);
    let specifier = posix.relative(posix.dirname(target), dependencyTarget);
    if (!specifier.startsWith('.')) specifier = `./${specifier}`;
    const start = match.index + match[1].length + 1;
    generated = generated.slice(0, start) + specifier + generated.slice(start + match[3].length);
    importMap.push({ importer: source.path, specifier: link.specifier, target: link.target, generatedImporter: target, generatedSpecifier: specifier, generatedTarget: dependencyTarget });
  }
  add(target, generated);
  sourceRecords.push({ path: source.path, sourceSha256: source.sha256, generated: target, generatedSha256: sha256(generated) });
}

const diffRoot = packageRoot();
const diffFiles = filesUnder(diffRoot);
const expectedDiffFiles = pinned.diff.files.map(file => file.path).sort();
if (JSON.stringify(diffFiles.slice().sort()) !== JSON.stringify(expectedDiffFiles)) throw new Error('Pinned diff package file list mismatch');
for (const file of pinned.diff.files) {
  const bytes = readFileSync(join(diffRoot, file.path));
  assertHash(bytes, file.sha256, `diff/${file.path}`);
  add(`vendor/diff/${file.path}`, bytes);
}
const manifestBytes = artifacts.get('vendor/diff/package.json');
assertHash(manifestBytes, pinned.diff.entry.manifestSha256, 'diff/package.json');
const manifest = JSON.parse(manifestBytes);
if (manifest.name !== 'diff' || manifest.version !== '9.0.0' || manifest.type !== 'module' ||
    manifest.license !== pinned.diff.license.id || manifest.exports['.'].import.default !== pinned.diff.entry.originalExport) {
  throw new Error('Pinned diff manifest/ESM entry mismatch');
}
assertHash(artifacts.get(`vendor/diff/${pinned.diff.license.path}`), pinned.diff.license.sha256, 'diff/LICENSE');
// All 21 complete ESM files are retained. The source oracle evaluated 19; its
// other two files have no import declarations and remain explicitly unlinked.
for (const file of pinned.diff.esmModules) {
  const importer = `diff@${pinned.diff.version}/${file.path}`;
  for (const { link } of moduleLinks(artifacts.get(`vendor/diff/${file.path}`).toString('utf8'), importer)) {
    const resolved = posix.normalize(posix.join(posix.dirname(file.path), link.specifier));
    if (!link.specifier.startsWith('.') || link.target !== `diff@${pinned.diff.version}/${resolved}` ||
        !artifacts.has(`vendor/diff/${resolved}`)) throw new Error(`Invalid pinned diff import: ${importer}`);
    importMap.push({ importer, specifier: link.specifier, target: link.target, generatedImporter: `vendor/diff/${file.path}`, generatedSpecifier: link.specifier, generatedTarget: `vendor/diff/${resolved}` });
  }
}

// An unpacked installed dependency is verified against every original archive
// member hash. When its original archive is supplied (or sits beside --diff-root)
// also verify the original lock integrity. Build locations never enter artifacts.
const adjacentArchive = join(dirname(diffRoot), pinned.diff.archive.path);
const archivePath = options.get('--diff-archive') ?? (options.has('--diff-root') && existsSync(adjacentArchive) ? adjacentArchive : undefined);
if (archivePath) {
  const archive = readFileSync(archivePath);
  assertHash(archive, pinned.diff.archive.sha256, 'diff archive');
  const integrity = `sha512-${createHash('sha512').update(archive).digest('base64')}`;
  if (archive.length !== pinned.diff.archive.bytes || integrity !== pinned.diff.integrity || integrity !== pinned.diff.archive.integrity) {
    throw new Error('Pinned diff archive lock integrity mismatch');
  }
}

const sourceLicense = readFileSync(join(vendorRoot, pinned.sourceLicense.path));
assertHash(sourceLicense, pinned.sourceLicense.sha256, 'OpenClaw/LICENSE');
add('vendor/openclaw/LICENSE', sourceLicense);
add('pinned-provenance.json', pinnedBytes);
const hostRecords = [];
for (const path of ['planner.mjs', 'worker.mjs', 'stdio.mjs']) {
  const bytes = readFileSync(join(sourceRoot, path));
  add(path, bytes);
  hostRecords.push({ path: `packages/tool-host/src/filesystem/${path}`, generated: path, sourceSha256: sha256(bytes), generatedSha256: sha256(bytes) });
}
for (const { generated: path } of hostRecords) {
  for (const match of artifacts.get(path).toString('utf8').matchAll(staticModule)) {
    const specifier = match[3];
    const target = specifier.startsWith('node:') ? specifier : posix.normalize(posix.join(posix.dirname(path), specifier));
    if (!specifier.startsWith('node:') && (!specifier.startsWith('.') || !artifacts.has(target))) {
      throw new Error(`Host import outside artifact: ${path} -> ${specifier}`);
    }
    importMap.push({ importer: `packages/tool-host/src/filesystem/${path}`, specifier, target, generatedImporter: path, generatedSpecifier: specifier, generatedTarget: target });
  }
}
importMap.sort((a, b) => `${a.importer}\0${a.specifier}` < `${b.importer}\0${b.specifier}` ? -1 : 1);
const provenance = {
  version: 1,
  reference: pinned.reference,
  fixture: pinned.fixture,
  transformation: { version: 1, api: 'node:module.stripTypeScriptTypes', mode: 'strip', sourceMap: false, moduleRewrite: 'only static import/export specifiers from the explicit pinned module graph' },
  sources: sourceRecords,
  host: hostRecords,
  sourceLicense: pinned.sourceLicense,
  aliases: pinned.aliases,
  aliasEvidence: pinned.aliasEvidence,
  diff: pinned.diff,
  importMap,
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, sha256: sha256(bytes) })).sort((a, b) => a.path < b.path ? -1 : 1),
};
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');

// Never recursively delete an output directory. Only the exact planned artifact
// files may be overwritten; unrelated existing files/directories block the build.
const plannedDirectories = new Set(['']);
for (const path of artifacts.keys()) {
  let parent = posix.dirname(path);
  while (parent !== '.') { plannedDirectories.add(parent); parent = posix.dirname(parent); }
}
function inspectOutput(prefix = '') {
  for (const entry of readdirSync(join(output, prefix), { withFileTypes: true })) {
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory() && plannedDirectories.has(path)) inspectOutput(path);
    else if (!entry.isFile() || !artifacts.has(path)) throw new Error(`Unrelated path in output directory: ${path}`);
  }
}
if (existsSync(output)) {
  if (!lstatSync(output).isDirectory()) throw new Error('Output must be a directory');
  inspectOutput();
}
for (const [path, bytes] of [...artifacts].sort(([a], [b]) => a < b ? -1 : 1)) {
  const destination = join(output, path);
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, bytes);
}
process.stdout.write(`Packaged filesystem planner: ${relative(repository, output)} (${sourceRecords.length} source modules, ${pinned.diff.files.length} diff files)\n`);
