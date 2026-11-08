import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Build-time access only. Runtime receives captured bytes and has its own exact
// npm closure, including Photon WASM; it needs no checkout or source loader.
const repository = fileURLToPath(new URL('../', import.meta.url));
const sourceRoot = join(repository, 'packages/tool-host/src/filesystem');
const vendorRoot = join(sourceRoot, 'read_vendor');
const pinnedBytes = readFileSync(join(vendorRoot, 'provenance.json'));
const dependencyBytes = readFileSync(join(vendorRoot, 'dependencies.json'));
const pinned = JSON.parse(pinnedBytes), dependencies = JSON.parse(dependencyBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const toolHostRequire = createRequire(join(repository, 'packages/tool-host/package.json'));
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--output' || !args[1])) {
  throw new Error('Usage: build-filesystem-read.mjs [--output directory]');
}
const output = args.length ? resolve(args[1]) : join(repository, 'apps/synapsis_core/priv/filesystem_read');
const artifacts = new Map();
function add(path, bytes) {
  if (artifacts.has(path)) throw new Error(`Duplicate artifact: ${path}`);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
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
      if (!entry.isFile()) throw new Error(`Expected regular package file: ${path}`);
      return path === '.npm-ex-cache-complete' ? [] : [path];
    });
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
function equal(left, right) {
  return JSON.stringify(canonical(left)) === JSON.stringify(canonical(right));
}

const IMAGE_RESIZE = 'src/agents/utils/image-resize.ts';
const MEDIA_ROOT = 'packages/media-core/src/';
const sourceLinks = {
  'src/agents/utils/mime.ts': {},
  [IMAGE_RESIZE]: { '../../media/image-ops.js': 'read_codec.mjs' },
  [`${MEDIA_ROOT}attachment-classify.ts`]: { 'node:util': 'node:util', './mime.js': `${MEDIA_ROOT}mime.ts` },
  [`${MEDIA_ROOT}mime.ts`]: { 'node:path': 'node:path', './constants.js': `${MEDIA_ROOT}constants.ts`, './file-name.js': `${MEDIA_ROOT}file-name.ts` },
  [`${MEDIA_ROOT}constants.ts`]: {},
  [`${MEDIA_ROOT}file-name.ts`]: { 'node:path': 'node:path' },
};
if (pinned.reference.commit !== '488631c18fae7cc541ba8fc8beff6cbb0438787b' ||
    !equal(Object.keys(pinned.sources).sort(), [...Object.keys(sourceLinks), 'LICENSE'].sort()) ||
    !equal(pinned.aliases, { 'src/media/image-ops.ts': 'packages/tool-host/src/filesystem/read_codec.mjs' })) {
  throw new Error('Incomplete pinned read source closure');
}
const moduleTargets = new Map(Object.keys(sourceLinks).map(path => [path, `vendor/openclaw/${path.replace(/\.ts$/, '.mjs')}`]));
const staticModule = /^([\t ]*(?:import|export)\s+(?:\{[^}]*\}|\*(?:\s+as\s+\w+)?|[A-Za-z_$][\w$]*)\s+from\s*)(["'])([^"'\r\n]+)\2/gm;
const importMap = [], sourceRecords = [];
for (const [path, expectedHash] of Object.entries(pinned.sources)) {
  const original = readFileSync(join(vendorRoot, 'openclaw', path));
  assertHash(original, expectedHash, path);
  if (path === 'LICENSE') {
    add('vendor/openclaw/LICENSE', original);
    sourceRecords.push({ path, sourceSha256: expectedHash, generated: 'vendor/openclaw/LICENSE', generatedSha256: expectedHash });
    continue;
  }
  const target = moduleTargets.get(path);
  let generated = stripTypeScriptTypes(original.toString('utf8'), { mode: 'strip', sourceMap: false });
  const links = [...generated.matchAll(staticModule)];
  if (!equal(links.map(match => match[3]).sort(), Object.keys(sourceLinks[path]).sort())) {
    throw new Error(`Pinned source import graph mismatch: ${path}`);
  }
  for (const match of links.reverse()) {
    const dependency = sourceLinks[path][match[3]];
    const dependencyTarget = dependency.startsWith('node:') ? dependency : moduleTargets.get(dependency) ?? dependency;
    let specifier = dependencyTarget.startsWith('node:') ? dependencyTarget : posix.relative(posix.dirname(target), dependencyTarget);
    if (!specifier.startsWith('node:') && !specifier.startsWith('.')) specifier = `./${specifier}`;
    const start = match.index + match[1].length + 1;
    generated = generated.slice(0, start) + specifier + generated.slice(start + match[3].length);
    importMap.push({ importer: path, specifier: match[3], target: dependency, generatedImporter: target, generatedSpecifier: specifier, generatedTarget: dependencyTarget });
  }
  const dynamic = [...generated.matchAll(/\bimport\(\s*["']([^"']+)["']\s*\)/g)].map(match => match[1]);
  if (!equal(dynamic, path === `${MEDIA_ROOT}mime.ts` ? ['file-type'] : [])) {
    throw new Error(`Pinned dynamic import graph mismatch: ${path}`);
  }
  for (const specifier of dynamic) importMap.push({ importer: path, specifier, generatedImporter: target, generatedSpecifier: specifier, generatedTarget: `node_modules/${specifier}` });
  add(target, generated);
  sourceRecords.push({ path, sourceSha256: expectedHash, generated: target, generatedSha256: sha256(generated) });
}

const lockBytes = readFileSync(join(repository, dependencies.sourceLock));
assertHash(lockBytes, dependencies.sourceLockSha256, dependencies.sourceLock);
const lock = JSON.parse(lockBytes), packageRecords = [];
if (Object.keys(dependencies.packages).length !== 12 ||
    Object.values(dependencies.packages).reduce((sum, entry) => sum + Object.keys(entry.files).length, 0) !== 108) {
  throw new Error('Incomplete pinned read dependency closure');
}
for (const [name, pin] of Object.entries(dependencies.packages)) {
  if (!equal(lock.packages[`node_modules/${name}`], pin.lock)) throw new Error(`Pinned lock entry mismatch: ${name}`);
  // Includes the type-only @tokenizer/token package, which has no JS entry to
  // resolve. These are Node's actual package search locations from tool-host.
  const root = toolHostRequire.resolve.paths(name)
    .map(base => join(base, name))
    .find(candidate => existsSync(join(candidate, 'package.json')));
  if (!root) throw new Error(`Pinned installed package missing: ${name}`);
  const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  if (manifest.name !== name || manifest.version !== pin.version ||
      !equal(filesUnder(root).sort(), Object.keys(pin.files).sort()) ||
      Object.keys(manifest.dependencies ?? {}).some(dependency => !Object.hasOwn(dependencies.packages, dependency))) {
    throw new Error(`Pinned package closure mismatch: ${name}`);
  }
  let bytes = 0;
  for (const [path, hash] of Object.entries(pin.files)) {
    const content = readFileSync(join(root, path));
    assertHash(content, hash, `${name}/${path}`);
    bytes += content.length;
    add(`node_modules/${name}/${path}`, content);
  }
  if (bytes !== pin.bytes) throw new Error(`Pinned package byte count mismatch: ${name}`);
  packageRecords.push({ name, ...pin });
}

const hostRecords = [];
for (const [source, target] of [
  ['read_content.mjs', 'read_content.mjs'], ['read_codec.mjs', 'read_codec.mjs'],
  ['read_worker.mjs', 'worker.mjs'], ['stdio.mjs', 'stdio.mjs'],
]) {
  const bytes = readFileSync(join(sourceRoot, source));
  add(target, bytes);
  hostRecords.push({ path: `packages/tool-host/src/filesystem/${source}`, generated: target, sourceSha256: sha256(bytes), generatedSha256: sha256(bytes) });
}
for (const { path, generated } of hostRecords) {
  for (const match of artifacts.get(generated).toString('utf8').matchAll(staticModule)) {
    const specifier = match[3];
    const target = specifier.startsWith('node:') ? specifier
      : specifier.startsWith('.') ? posix.normalize(posix.join(posix.dirname(generated), specifier))
        : `node_modules/${specifier}`;
    if (!specifier.startsWith('node:') &&
        (specifier.startsWith('.') ? !artifacts.has(target) : !Object.hasOwn(dependencies.packages, specifier))) {
      throw new Error(`Host import outside pinned artifact: ${path} -> ${specifier}`);
    }
    importMap.push({ importer: path, specifier, generatedImporter: generated, generatedSpecifier: specifier, generatedTarget: target });
  }
}
add('pinned-provenance.json', pinnedBytes);
add('pinned-dependencies.json', dependencyBytes);
importMap.sort((a, b) => `${a.importer}\0${a.specifier}` < `${b.importer}\0${b.specifier}` ? -1 : 1);
const provenance = {
  version: 1,
  reference: pinned.reference,
  transformation: { version: 1, api: 'node:module.stripTypeScriptTypes', mode: 'strip', sourceMap: false, moduleRewrite: 'only static specifiers in the explicit pinned source graph' },
  sources: sourceRecords,
  host: hostRecords,
  aliases: pinned.aliases,
  sourceLock: { path: dependencies.sourceLock, sha256: dependencies.sourceLockSha256 },
  dependencies: packageRecords,
  importMap,
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, sha256: sha256(bytes) })).sort((a, b) => a.path < b.path ? -1 : 1),
};
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');

// Never delete a tree or overwrite unrelated entries. Only this complete pinned
// artifact file set may already exist in the selected output directory.
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
process.stdout.write(`Packaged filesystem read: ${relative(repository, output)} (${sourceRecords.length} originals, ${packageRecords.length} dependency packages)\n`);
