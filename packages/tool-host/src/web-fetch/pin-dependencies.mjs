// Build-time pin capture, run once after the supported npm install. Runtime never
// loads this file. The builder independently verifies the frozen lock/file graph.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const lockBytes = readFileSync(join(repository, 'package-lock.json'));
const lock = JSON.parse(lockBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const primary = { '@mozilla/readability': '0.6.0', linkedom: '0.18.13', entities: '8.1.0' };
const packages = {};
function findPackage(name, from) {
  const require = createRequire(join(from, 'package.json'));
  const root = require.resolve.paths(name)?.map(path => join(path, name))
    .find(path => existsSync(join(path, 'package.json')));
  if (!root) throw new Error(`Missing declared dependency: ${name}`);
  const path = relative(repository, root).split('\\').join('/');
  if (path.startsWith('../') || !lock.packages[path]) throw new Error(`Package has no exact lock row: ${path}`);
  return { root, path };
}
function files(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : 1)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (path === 'node_modules' || path === '.npm-ex-cache-complete') return [];
      if (entry.isDirectory()) return files(root, path);
      if (!entry.isFile()) throw new Error(`Not a regular package file: ${path}`);
      return [path];
    });
}
function capture(name, from) {
  const { root, path } = findPackage(name, from);
  if (packages[path]) return path;
  const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  if (manifest.name !== name || manifest.version !== lock.packages[path].version) throw new Error(`Package identity mismatch: ${path}`);
  const pin = { name, version: manifest.version, lock: lock.packages[path], dependencies: {}, files: {}, bytes: 0, licenses: {} };
  packages[path] = pin;
  for (const file of files(root)) {
    const bytes = readFileSync(join(root, file));
    const hash = sha256(bytes);
    pin.files[file] = hash;
    pin.bytes += bytes.length;
    if (/(?:^|\/)(?:licen[sc]e|copying|notice)(?:\.|$)/i.test(file)) pin.licenses[file] = hash;
  }
  for (const dependency of Object.keys(manifest.dependencies ?? {}).sort()) pin.dependencies[dependency] = capture(dependency, root);
  return path;
}
const roots = {};
for (const [name, version] of Object.entries(primary)) {
  const path = capture(name, join(repository, 'packages/tool-host'));
  if (packages[path].version !== version) throw new Error(`Wrong root version: ${name}`);
  roots[name] = path;
}
const result = { version: 1, sourceLock: 'package-lock.json', sourceLockSha256: sha256(lockBytes), roots,
  packages: Object.fromEntries(Object.entries(packages).sort(([a], [b]) => a < b ? -1 : 1)) };
writeFileSync(new URL('./vendor/dependencies.json', import.meta.url), JSON.stringify(result, null, 2) + '\n');
process.stdout.write(`Pinned readable-fetch dependency closure (${Object.keys(packages).length} packages)\n`);
