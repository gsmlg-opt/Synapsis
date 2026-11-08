import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, posix, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Build-time filesystem reads only. The relocated helper receives unchanged
// modules and the complete locked installed dependency trees, including licenses.
const repository = fileURLToPath(new URL('../', import.meta.url));
const sourceRoot = join(repository, 'packages/tool-host/src/workflow');
const dependencyBytes = readFileSync(join(sourceRoot, 'dependencies.json'));
const dependencies = JSON.parse(dependencyBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--output' || !args[1])) {
  throw new Error('Usage: build-workflow-schema.mjs [--output directory]');
}
const output = args.length ? resolve(args[1]) : join(repository, 'apps/synapsis_core/priv/workflow_schema');
const artifacts = new Map();
function add(path, bytes) {
  const value = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  // Ajv's whole installed tree already contains its nested fast-uri package.
  // Its independent package pin must agree byte for byte with that same tree.
  if (artifacts.has(path)) {
    if (!artifacts.get(path).equals(value)) throw new Error(`Overlapping artifact mismatch: ${path}`);
  } else artifacts.set(path, value);
}
function assertHash(bytes, expected, label) {
  if (sha256(bytes) !== expected) throw new Error(`Pinned SHA256 mismatch: ${label}`);
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
function filesUnder(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true })
    .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) return filesUnder(root, path);
      if (!entry.isFile()) throw new Error(`Expected regular package file: ${path}`);
      return entry.name === '.npm-ex-cache-complete' ? [] : [path];
    });
}
function packageLocation(origin, name) {
  const resolver = createRequire(join(repository, origin, 'package.json'));
  const root = resolver.resolve.paths(name)
    .map(base => join(base, name))
    .find(candidate => existsSync(join(candidate, 'package.json')));
  if (!root || !lstatSync(root).isDirectory()) throw new Error(`Pinned installed package missing: ${name}`);
  return relative(repository, root).split('\\').join('/');
}
function relativePath(path) {
  return typeof path === 'string' && path.length > 0 && !path.includes('\\') &&
    !path.includes('\0') && !posix.isAbsolute(path) && posix.normalize(path) === path &&
    path.split('/').every(part => part !== '.' && part !== '..');
}

if (dependencies.version !== 1 || dependencies.sourceLock !== 'package-lock.json' ||
    !equal(dependencies.roots, { ajv: 'node_modules/ajv', 'fast-uri': 'node_modules/fast-uri' }) ||
    Object.keys(dependencies.packages).length !== 6) {
  throw new Error('Incomplete pinned workflow schema dependency closure');
}
const lockBytes = readFileSync(join(repository, dependencies.sourceLock));
assertHash(lockBytes, dependencies.sourceLockSha256, dependencies.sourceLock);
const lock = JSON.parse(lockBytes), packageRecords = [];
const reached = new Set(), pending = Object.values(dependencies.roots);
for (const [name, path] of Object.entries(dependencies.roots)) {
  if (packageLocation('packages/tool-host', name) !== path) throw new Error(`Pinned root resolution mismatch: ${name}`);
}
while (pending.length) {
  const path = pending.shift();
  if (reached.has(path)) continue;
  const pin = dependencies.packages[path];
  if (!pin || !relativePath(path) || !path.startsWith('node_modules/')) {
    throw new Error(`Missing pinned dependency location: ${path}`);
  }
  reached.add(path);
  pending.push(...Object.values(pin.dependencies));
}
if (!equal([...reached].sort(), Object.keys(dependencies.packages).sort())) {
  throw new Error('Unreachable package in pinned workflow schema closure');
}

for (const [path, pin] of Object.entries(dependencies.packages).sort(([a], [b]) => a < b ? -1 : 1)) {
  if (!equal(lock.packages[path], pin.lock)) throw new Error(`Pinned lock entry mismatch: ${path}`);
  const root = join(repository, path);
  if (!lstatSync(root).isDirectory()) throw new Error(`Expected installed package directory: ${path}`);
  const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  if (manifest.name !== pin.name || manifest.version !== pin.version ||
      !equal(manifest.dependencies ?? {}, pin.lock.dependencies ?? {}) ||
      !equal(Object.keys(manifest.dependencies ?? {}).sort(), Object.keys(pin.dependencies).sort()) ||
      !equal(filesUnder(root).sort(), Object.keys(pin.files).sort())) {
    throw new Error(`Pinned package closure mismatch: ${path}`);
  }
  for (const [name, target] of Object.entries(pin.dependencies)) {
    if (!Object.hasOwn(dependencies.packages, target) ||
        dependencies.packages[target].name !== name || packageLocation(path, name) !== target) {
      throw new Error(`Pinned nested dependency resolution mismatch: ${path} -> ${name}`);
    }
  }
  let bytes = 0;
  for (const [file, hash] of Object.entries(pin.files)) {
    if (!relativePath(file)) throw new Error(`Invalid pinned package path: ${path}/${file}`);
    const content = readFileSync(join(root, file));
    assertHash(content, hash, `${path}/${file}`);
    bytes += content.length;
    add(`${path}/${file}`, content);
  }
  const licenses = Object.fromEntries(Object.entries(pin.files)
    .filter(([file]) => /^(?:license|copying)/i.test(posix.basename(file))));
  if (bytes !== pin.bytes || Object.keys(licenses).length === 0 || !equal(licenses, pin.licenses)) {
    throw new Error(`Pinned package byte count/license mismatch: ${path}`);
  }
  packageRecords.push({ path, ...pin });
}

const hostRecords = [], importMap = [];
for (const name of ['schema-stdio.mjs', 'schema-worker.mjs', 'schema.mjs', 'template.mjs']) {
  const bytes = readFileSync(join(sourceRoot, name));
  add(name, bytes);
  hostRecords.push({ path: `packages/tool-host/src/workflow/${name}`, generated: name,
    sourceSha256: sha256(bytes), generatedSha256: sha256(bytes) });
}
const staticImport = /\bimport\s+(?:\{[^}]*\}|[A-Za-z_$][\w$]*)\s+from\s*['"]([^'"\r\n]+)['"]/g;
const workerURL = /new\s+URL\(\s*['"]([^'"\r\n]+)['"]\s*,\s*import\.meta\.url\s*\)/g;
for (const { path, generated } of hostRecords) {
  const text = artifacts.get(generated).toString('utf8');
  const specifiers = [...text.matchAll(staticImport), ...text.matchAll(workerURL)].map(match => match[1]);
  for (const specifier of specifiers) {
    const target = specifier.startsWith('node:') ? specifier
      : specifier.startsWith('.') ? posix.normalize(posix.join(posix.dirname(generated), specifier))
        : dependencies.roots[specifier];
    if (!target || (!specifier.startsWith('node:') &&
        (specifier.startsWith('.') ? !artifacts.has(target) : !dependencies.packages[target]))) {
      throw new Error(`Host import outside pinned artifact: ${path} -> ${specifier}`);
    }
    importMap.push({ importer: path, specifier, generatedImporter: generated, generatedSpecifier: specifier, generatedTarget: target });
  }
}
add('pinned-dependencies.json', dependencyBytes);
importMap.sort((a, b) => `${a.importer}\0${a.specifier}` < `${b.importer}\0${b.specifier}` ? -1 : 1);
const provenance = {
  version: 1,
  transformation: { version: 1, mode: 'byte-copy' },
  host: hostRecords,
  sourceLock: { path: dependencies.sourceLock, sha256: dependencies.sourceLockSha256 },
  dependencies: packageRecords,
  importMap,
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, sha256: sha256(bytes) })).sort((a, b) => a.path < b.path ? -1 : 1),
};
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');

// No recursive removal. An existing output may contain only this exact artifact
// set and its directories; inspect the whole tree before writing any bytes.
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
process.stdout.write(`Packaged workflow schema: ${relative(repository, output)} (${hostRecords.length} unchanged host modules, ${packageRecords.length} dependency locations, ${artifacts.size} files)\n`);
