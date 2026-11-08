import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repository = fileURLToPath(new URL('../', import.meta.url));
const sourceRoot = join(repository, 'packages/tool-host/src/diffs');
const prefix = 'packages/tool-host/src/diffs/openclaw';
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--output' || !args[1])) {
  throw new Error('Usage: build-diffs-renderer.mjs [--output directory]');
}
const output = args.length ? resolve(args[1]) : join(repository, 'apps/synapsis_core/priv/diffs_renderer');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
// Rebuild only a fresh directory or the exact previously produced capsule.
// Unexpected output bytes are never overwritten or removed.
function allFiles(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).flatMap(entry => {
    const path = join(prefix, entry.name);
    if (entry.isDirectory()) return allFiles(root, path);
    if (!entry.isFile()) throw new Error(`Nonregular output: ${path}`);
    return [path];
  });
}
if (existsSync(output)) {
  if (!lstatSync(output).isDirectory() || realpathSync(output) !== output) throw new Error('Output must be a canonical directory');
  const files = allFiles(output);
  if (files.length) {
    const previous = JSON.parse(readFileSync(join(output, 'provenance.json')));
    if (previous.version !== 1 || previous.reference !== '488631c18fae7cc541ba8fc8beff6cbb0438787b') throw new Error('Unowned output directory');
    const recorded = new Map(previous.artifacts.map(item => [item.path, item]));
    if (files.length !== recorded.size + 1 || files.some(path => path !== 'provenance.json' && !recorded.has(path))) throw new Error('Unexpected output files');
    for (const [path, item] of recorded) {
      const bytes = readFileSync(join(output, path));
      if (bytes.length !== item.bytes || sha(bytes) !== item.sha256) throw new Error(`Changed output: ${path}`);
    }
  }
}
const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
function filesUnder(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : 1).flatMap(entry => {
    if (entry.name === 'node_modules' || entry.name === '.npm-ex-cache-complete') return [];
    const path = join(prefix, entry.name);
    if (entry.isDirectory()) return filesUnder(root, path);
    if (!entry.isFile()) throw new Error(`Nonregular package file: ${path}`);
    return [path];
  });
}
function location(origin, name) {
  const req = createRequire(join(repository, origin, 'package.json'));
  const absolute = req.resolve.paths(name).map(base => join(base, name)).find(path => existsSync(join(path, 'package.json')));
  if (!absolute) throw new Error(`Missing installed dependency ${origin}: ${name}`);
  return relative(repository, absolute);
}
const artifacts = new Map();
function add(path, bytes) {
  if (artifacts.has(path)) throw new Error(`Duplicate artifact ${path}`);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
}
function flush() {
  for (const [path, bytes] of artifacts) {
    const target = join(output, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, bytes);
  }
}
const pinnedBytes = readFileSync(join(sourceRoot, 'vendor/provenance.json'));
const pinned = JSON.parse(pinnedBytes);
const dependencyBytes = readFileSync(join(sourceRoot, 'dependencies.json'));
const deps = JSON.parse(dependencyBytes);
const lockBytes = readFileSync(join(repository, deps.sourceLock));
if (deps.version !== 1 || deps.sourceLock !== 'package-lock.json' || sha(lockBytes) !== deps.sourceLockSha256) throw new Error('Pinned root lock mismatch');
if (pinned.reference !== '488631c18fae7cc541ba8fc8beff6cbb0438787b') throw new Error('Pinned source mismatch');
const lock = JSON.parse(lockBytes), reached = new Set(), pending = Object.values(deps.roots);
for (const [name, expected] of Object.entries(deps.roots)) {
  if (location('packages/tool-host', name) !== expected) throw new Error(`Root resolution changed ${name}`);
}
while (pending.length) {
  const path = pending.shift();
  if (reached.has(path)) continue;
  const pin = deps.packages[path];
  if (!pin || path.split('/').some(part => part === '..') || !equal(lock.packages[path], pin.lock)) throw new Error(`Pinned location mismatch ${path}`);
  reached.add(path);
  const root = join(repository, path), manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  if (manifest.name !== pin.name || manifest.version !== pin.version || !equal(filesUnder(root).sort(), Object.keys(pin.files).sort())) throw new Error(`Pinned package mismatch ${path}`);
  const edges = { ...manifest.dependencies, ...manifest.optionalDependencies };
  if (!equal(Object.keys(edges).sort(), Object.keys(pin.dependencies).sort())) throw new Error(`Pinned edges changed ${path}`);
  for (const [name, target] of Object.entries(pin.dependencies)) {
    if (location(path, name) !== target) throw new Error(`Pinned edge resolution changed ${path}:${name}`);
    pending.push(target);
  }
  let total = 0;
  for (const [file, digest] of Object.entries(pin.files)) {
    const bytes = readFileSync(join(root, file));
    if (sha(bytes) !== digest) throw new Error(`Pinned bytes changed ${path}/${file}`);
    total += bytes.length;
    add(`${path}/${file}`, bytes);
  }
  if (total !== pin.bytes) throw new Error(`Pinned size changed ${path}`);
}
if (!equal([...reached].sort(), Object.keys(deps.packages).sort())) throw new Error('Unreachable pinned package');
const executable = new Set(['render', 'language-hints', 'shiki-curated-languages', 'viewer-client', 'viewer-payload', 'types'].map(n => `extensions/diffs/src/${n}.ts`));
executable.add('src/shared/html-escape.ts');
executable.add('scripts/diffs-shiki-curated.ts');
const sourceRecords = [];
for (const [path, hash] of Object.entries(pinned.files)) {
  const bytes = readFileSync(join(sourceRoot, 'vendor/openclaw', path));
  if (sha(bytes) !== hash) throw new Error(`Pinned source changed ${path}`);
  add(`vendor/openclaw/${path}`, bytes);
  if (!executable.has(path)) continue;
  let generated = stripTypeScriptTypes(bytes.toString(), { mode: 'strip', sourceMap: false });
  const adaptations = ['Node type stripping only'];
  if (path === 'extensions/diffs/src/render.ts') {
    const sdk = '"openclaw/plugin-sdk/text-utility-runtime"';
    if (generated.split(sdk).length !== 2) throw new Error('SDK import mismatch');
    generated = generated.replace(sdk, '"../../../src/shared/html-escape.js"');
    adaptations.push('Resolve SDK escapeHtml re-export to its exact original implementation');
  }
  const target = `${prefix}/${path.replace(/\.ts$/, '.js')}`;
  add(target, generated);
  sourceRecords.push({ path, sourceSha256: hash, generated: target, generatedSha256: sha(generated), adaptations });
}
add('package.json', '{"private":true,"type":"module"}\n');
add('pinned-dependencies.json', dependencyBytes);
add('pinned-source.json', pinnedBytes);
// Host files are kept outside the captured source and are never transformed.
const host = [];
for (const name of ['renderer.mjs', 'worker.mjs', 'stdio.mjs']) {
  const bytes = readFileSync(join(sourceRoot, name));
  add(name, bytes);
  host.push({ path: `packages/tool-host/src/diffs/${name}`, sha256: sha(bytes) });
}
flush();
const build = spawnSync('mix', ['run', '--no-start', join(repository, 'scripts/build-diffs-viewer.exs'), '--', output], {
  cwd: repository, encoding: 'utf8', timeout: 300_000, maxBuffer: 4 * 1024 * 1024
});
process.stdout.write(build.stdout ?? '');
process.stderr.write(build.stderr ?? '');
if (build.error || build.status !== 0) throw new Error(`Duskmoon viewer build failed: ${build.error?.message ?? build.status}`);
const assetRoot = join(output, 'assets');
const runtime = readFileSync(join(assetRoot, 'viewer-runtime.js'));
writeFileSync(join(assetRoot, 'viewer.js'), `import "./viewer-runtime.js?v=${createHash('sha1').update(runtime).digest('hex').slice(0, 12)}";\n`);
const assets = {};
for (const name of filesUnder(assetRoot)) {
  const bytes = readFileSync(join(assetRoot, name));
  add(`assets/${name}`, bytes);
  assets[name] = { sha256: sha(bytes), bytes: bytes.length };
}
const capsule = { version: 1, reference: pinned.reference, languagePackAvailable: false, roots: deps.roots,
  packages: Object.fromEntries(Object.entries(deps.packages).map(([path, pin]) => [path, { name: pin.name, version: pin.version }])), assets };
add('capsule.json', JSON.stringify(capsule, null, 2) + '\n');
const provenance = { version: 1, reference: pinned.reference, sourceLockSha256: deps.sourceLockSha256, source: sourceRecords, host,
  builder: ['scripts/build-diffs-renderer.mjs', 'scripts/build-diffs-viewer.exs', 'scripts/diffs_viewer_plugin.exs'].map(path => ({ path, sha256: sha(readFileSync(join(repository, path))) })),
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, sha256: sha(bytes), bytes: bytes.length })).sort((a, b) => a.path < b.path ? -1 : 1) };
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');
flush();
console.log(JSON.stringify({ output, files: artifacts.size, packageLocations: reached.size, sourceModules: sourceRecords.length, assetCount: Object.keys(assets).length }));
