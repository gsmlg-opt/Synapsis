import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../', import.meta.url));
const sourceRoot = join(repository, 'packages/tool-host/src/web-fetch');
const vendorRoot = join(sourceRoot, 'vendor');
const pinnedBytes = readFileSync(join(vendorRoot, 'provenance.json'));
const dependencyBytes = readFileSync(join(vendorRoot, 'dependencies.json'));
const pinned = JSON.parse(pinnedBytes), dependencies = JSON.parse(dependencyBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--output' || !args[1])) throw new Error('Usage: build-web-fetch.mjs [--output directory]');
const output = args.length ? resolve(args[1]) : join(repository, 'apps/synapsis_core/priv/web_fetch');
const artifacts = new Map();
function add(path, bytes) {
  if (artifacts.has(path)) throw new Error(`Duplicate artifact: ${path}`);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
}
function assertHash(bytes, expected, label) {
  if (sha256(bytes) !== expected) throw new Error(`Pinned SHA256 mismatch: ${label}`);
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
function filesUnder(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : 1)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (path === 'node_modules' || path === '.npm-ex-cache-complete') return [];
      if (entry.isDirectory()) return filesUnder(root, path);
      if (!entry.isFile()) throw new Error(`Expected regular package file: ${path}`);
      return [path];
    });
}
function packagePosition(name, from) {
  const require = createRequire(join(from, 'package.json'));
  const root = require.resolve.paths(name)?.map(base => join(base, name)).find(path => existsSync(join(path, 'package.json')));
  if (!root) throw new Error(`Missing installed dependency: ${name}`);
  return relative(repository, root).split('\\').join('/');
}

const lockBytes = readFileSync(join(repository, dependencies.sourceLock));
assertHash(lockBytes, dependencies.sourceLockSha256, dependencies.sourceLock);
const lock = JSON.parse(lockBytes), packageRecords = [];
const primary = { '@mozilla/readability': '0.6.0', linkedom: '0.18.13', entities: '8.1.0' };
if (!equal(Object.keys(dependencies.roots).sort(), Object.keys(primary).sort())) throw new Error('Incomplete readable dependency roots');
const seenPackages = new Set();
function verifyPackage(path) {
  if (seenPackages.has(path)) return;
  const pin = dependencies.packages[path];
  if (!pin || !equal(lock.packages[path], pin.lock)) throw new Error(`Pinned lock entry mismatch: ${path}`);
  const root = join(repository, path);
  const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  if (manifest.name !== pin.name || manifest.version !== pin.version ||
      !equal(filesUnder(root).sort(), Object.keys(pin.files).sort()) ||
      !equal(Object.keys(manifest.dependencies ?? {}).sort(), Object.keys(pin.dependencies).sort())) throw new Error(`Pinned dependency closure mismatch: ${path}`);
  seenPackages.add(path);
  let bytes = 0;
  for (const [file, expected] of Object.entries(pin.files)) {
    const content = readFileSync(join(root, file));
    assertHash(content, expected, `${path}/${file}`);
    bytes += content.length;
    // Preserve physical npm positions, including nested version conflicts.
    add(`${path}/${file}`, content);
  }
  if (bytes !== pin.bytes || !Object.hasOwn(pin.files, 'package.json')) throw new Error(`Pinned package bytes mismatch: ${path}`);
  const licenses = Object.fromEntries(Object.entries(pin.files).filter(([file]) => /(?:^|\/)(?:licen[sc]e|copying|notice)(?:\.|$)/i.test(file)));
  if (!equal(licenses, pin.licenses)) throw new Error(`Pinned license closure mismatch: ${path}`);
  for (const [name, dependency] of Object.entries(pin.dependencies)) {
    if (packagePosition(name, root) !== dependency) throw new Error(`Installed dependency position mismatch: ${path} -> ${name}`);
    verifyPackage(dependency);
  }
  packageRecords.push({ path, ...pin });
}
for (const [name, version] of Object.entries(primary)) {
  const path = dependencies.roots[name];
  if (packagePosition(name, join(repository, 'packages/tool-host')) !== path || dependencies.packages[path]?.version !== version) throw new Error(`Root dependency mismatch: ${name}`);
  verifyPackage(path);
}
if (!equal([...seenPackages].sort(), Object.keys(dependencies.packages).sort())) throw new Error('Unreachable dependency pin');

// Resolve the real ESM export using Node's import conditions and manifest order.
// In particular linkedom/worker is its public worker.js bundle, not require DOM.
function exportedTarget(name, subpath = '.') {
  const path = dependencies.roots[name];
  const manifest = JSON.parse(artifacts.get(`${path}/package.json`));
  function select(value) {
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) {
      for (const item of value) { const target = select(item); if (target) return target; }
      return undefined;
    }
    if (value && typeof value === 'object') {
      for (const [condition, item] of Object.entries(value)) {
        if (['node', 'import', 'default', 'node-addons'].includes(condition)) {
          const target = select(item); if (target) return target;
        }
      }
    }
    return undefined;
  }
  const exports = manifest.exports;
  const entry = exports && typeof exports === 'object' && !Array.isArray(exports) && Object.keys(exports).some(key => key.startsWith('.')) ? exports[subpath] : subpath === '.' ? exports : undefined;
  const target = exports ? select(entry) : subpath === '.' ? manifest.main ?? './index.js' : undefined;
  if (typeof target !== 'string' || target.includes('..') || !artifacts.has(posix.join(path, target))) throw new Error(`Missing pinned ESM export: ${name}/${subpath}`);
  return posix.join(path, target);
}
const externalTargets = { entities: exportedTarget('entities'), '@mozilla/readability': exportedTarget('@mozilla/readability'), 'linkedom/worker': exportedTarget('linkedom', './worker') };
if (!externalTargets['linkedom/worker'].endsWith('/worker.js')) throw new Error('Expected actual linkedom worker export');

const NORMAL = 'packages/normalization-core/src/';
const TOOLS = 'src/agents/tools/';
const MARKDOWN = 'packages/markdown-core/src/html-scanner.ts';
const sourceLinks = {
  'extensions/web-readability/web-content-extractor.ts': { 'openclaw/plugin-sdk/lazy-runtime': 'src/shared/lazy-runtime.ts', 'openclaw/plugin-sdk/web-content-extractor': 'src/plugin-sdk/web-content-extractor.ts' },
  [`${TOOLS}web-shared.ts`]: { '@openclaw/normalization-core': 'normalization.mjs', '@openclaw/normalization-core/number-coercion': `${NORMAL}number-coercion.ts`, '../../infra/map-size.js': 'src/infra/map-size.ts' },
  [`${TOOLS}web-fetch-utils.ts`]: { '@openclaw/normalization-core/utf16-slice': `${NORMAL}utf16-slice.ts`, '../../../packages/markdown-core/src/html-scanner.js': MARKDOWN, '../../infra/unicode-visibility.js': 'src/infra/unicode-visibility.ts', '../../shared/html-entities.js': 'src/shared/html-entities.ts', './web-fetch-attributes.js': `${TOOLS}web-fetch-attributes.ts`, './web-fetch-visibility.js': `${TOOLS}web-fetch-visibility.ts` },
  [`${TOOLS}web-fetch-attributes.ts`]: { '../../../packages/markdown-core/src/html-scanner.js': MARKDOWN },
  [`${TOOLS}web-fetch-visibility.ts`]: { '@openclaw/normalization-core/string-coerce': `${NORMAL}string-coerce.ts`, '../../../packages/markdown-core/src/html-scanner.js': MARKDOWN, './web-fetch-attributes.js': `${TOOLS}web-fetch-attributes.ts` },
  'src/plugin-sdk/web-content-extractor.ts': { '../agents/tools/web-fetch-utils.js': `${TOOLS}web-fetch-utils.ts`, '../agents/tools/web-fetch-visibility.js': `${TOOLS}web-fetch-visibility.ts`, '../infra/unicode-visibility.js': 'src/infra/unicode-visibility.ts' },
  'src/infra/map-size.ts': {}, 'src/infra/unicode-visibility.ts': {},
  'src/security/external-content.ts': { 'node:crypto': 'node:crypto', '@openclaw/normalization-core/utf16-slice': `${NORMAL}utf16-slice.ts`, '../shared/regexp.js': 'src/shared/regexp.ts', './external-content-source.js': 'src/security/external-content-source.ts' },
  'src/security/external-content-source.ts': { '@openclaw/normalization-core/string-coerce': `${NORMAL}string-coerce.ts` },
  'src/shared/html-entities.ts': { entities: externalTargets.entities },
  'src/shared/lazy-runtime.ts': { './lazy-promise.js': 'src/shared/lazy-promise.ts' },
  'src/shared/lazy-promise.ts': {}, 'src/shared/regexp.ts': {}, [MARKDOWN]: {},
  [`${NORMAL}number-coercion.ts`]: { './string-coerce.ts': `${NORMAL}string-coerce.ts` },
  [`${NORMAL}string-coerce.ts`]: {}, [`${NORMAL}utf16-slice.ts`]: {}, [`${NORMAL}response-bytes.ts`]: {}, [`${NORMAL}text-decoding.ts`]: {},
};
const referenceOnly = ['src/agents/tools/web-fetch.ts', 'extensions/web-readability/package.json'];
if (pinned.reference.commit !== '488631c18fae7cc541ba8fc8beff6cbb0438787b' ||
    !equal(pinned.referenceOnly, referenceOnly) ||
    !equal(Object.keys(pinned.sources).sort(), [...Object.keys(sourceLinks), ...referenceOnly, 'LICENSE'].sort())) throw new Error('Incomplete readable source closure');
const moduleTargets = new Map(Object.keys(sourceLinks).map(path => [path, `vendor/openclaw/${path.replace(/\.ts$/, '.mjs')}`]));
const staticModule = /^([\t ]*(?:import|export)\s+(?:\{[^}]*\}|\*(?:\s+as\s+\w+)?|[A-Za-z_$][\w$]*)\s+from\s*)(["'])([^"'\r\n]+)\2/gm;
const importMap = [], sourceRecords = [];
const localSpecifier = (from, to) => {
  if (to.startsWith('node:')) return to;
  const path = posix.relative(posix.dirname(from), to);
  return path.startsWith('.') ? path : `./${path}`;
};
for (const [path, expectedHash] of Object.entries(pinned.sources)) {
  const original = readFileSync(join(vendorRoot, 'openclaw', path));
  assertHash(original, expectedHash, path);
  const target = moduleTargets.get(path);
  if (!target) {
    add(`vendor/openclaw/${path}`, original);
    sourceRecords.push({ path, sourceSha256: expectedHash, generated: `vendor/openclaw/${path}`, generatedSha256: expectedHash, referenceOnly: referenceOnly.includes(path) });
    continue;
  }
  let generated = stripTypeScriptTypes(original.toString('utf8'), { mode: 'strip', sourceMap: false });
  const links = [...generated.matchAll(staticModule)];
  // lazy-runtime imports and reexports the same original module.
  if (!equal([...new Set(links.map(match => match[3]))].sort(), Object.keys(sourceLinks[path]).sort())) throw new Error(`Pinned source import graph mismatch: ${path}`);
  for (const match of links.reverse()) {
    const dependency = sourceLinks[path][match[3]];
    const dependencyTarget = dependency.startsWith('node:') ? dependency : moduleTargets.get(dependency) ?? dependency;
    const specifier = localSpecifier(target, dependencyTarget);
    const start = match.index + match[1].length + 1;
    generated = generated.slice(0, start) + specifier + generated.slice(start + match[3].length);
    importMap.push({ importer: path, specifier: match[3], target: dependency, generatedImporter: target, generatedSpecifier: specifier, generatedTarget: dependencyTarget });
  }
  const dynamic = [...generated.matchAll(/\bimport\(\s*([^)]*?)\s*\)/g)].map(match => match[1]);
  const expectedDynamic = path === 'extensions/web-readability/web-content-extractor.ts' ? ['READABILITY_MODULE', 'LINKEDOM_MODULE'] : [];
  if (!equal(dynamic, expectedDynamic)) throw new Error(`Pinned dynamic import graph mismatch: ${path}`);
  if (expectedDynamic.length) {
    for (const [variable, name] of [['READABILITY_MODULE', '@mozilla/readability'], ['LINKEDOM_MODULE', 'linkedom/worker']]) {
      const declaration = `const ${variable} = "${name}";`;
      if (generated.split(declaration).length !== 2) throw new Error(`Pinned dynamic constant mismatch: ${variable}`);
      const specifier = localSpecifier(target, externalTargets[name]);
      generated = generated.replace(declaration, `const ${variable} = ${JSON.stringify(specifier)};`);
      importMap.push({ importer: path, specifier: name, dynamicBinding: variable, generatedImporter: target, generatedSpecifier: specifier, generatedTarget: externalTargets[name] });
    }
  }
  add(target, generated);
  sourceRecords.push({ path, sourceSha256: expectedHash, generated: target, generatedSha256: sha256(generated) });
}
const hostRecords = [];
for (const path of ['document.mjs', 'normalization.mjs', 'worker.mjs', 'stdio.mjs']) {
  const bytes = readFileSync(join(sourceRoot, path));
  add(path, bytes);
  hostRecords.push({ path: `packages/tool-host/src/web-fetch/${path}`, generated: path, sourceSha256: sha256(bytes), generatedSha256: sha256(bytes) });
}
for (const { path, generated } of hostRecords) {
  const content = artifacts.get(generated).toString('utf8');
  for (const match of content.matchAll(staticModule)) {
    const specifier = match[3];
    const target = specifier.startsWith('node:') ? specifier : posix.normalize(posix.join(posix.dirname(generated), specifier));
    if (!specifier.startsWith('node:') && (!specifier.startsWith('.') || !artifacts.has(target))) throw new Error(`Host import outside pinned artifact: ${path} -> ${specifier}`);
    importMap.push({ importer: path, specifier, generatedImporter: generated, generatedSpecifier: specifier, generatedTarget: target });
  }
  const workers = [...content.matchAll(/new URL\('([^']+)', import\.meta\.url\)/g)].map(match => match[1]);
  if (!equal(workers, generated === 'stdio.mjs' ? ['./worker.mjs'] : [])) throw new Error(`Host worker graph mismatch: ${path}`);
  for (const worker of workers) importMap.push({ importer: path, specifier: worker, worker: true, generatedImporter: generated, generatedSpecifier: worker, generatedTarget: 'worker.mjs' });
  if (/\bimport\s*\(/.test(content)) throw new Error(`Unexpected dynamic host import: ${path}`);
}
add('pinned-provenance.json', pinnedBytes);
add('pinned-dependencies.json', dependencyBytes);
importMap.sort((a, b) => `${a.importer}\0${a.specifier}` < `${b.importer}\0${b.specifier}` ? -1 : 1);
packageRecords.sort((a, b) => a.path < b.path ? -1 : 1);
const provenance = {
  version: 1, reference: pinned.reference,
  transformation: { version: 1, api: 'node:module.stripTypeScriptTypes', mode: 'strip', sourceMap: false,
    moduleRewrite: 'Explicit static edges and two verified variable-bound dynamic ESM export edges only' },
  sources: sourceRecords, host: hostRecords, aliases: pinned.aliases, assembly: pinned.assembly,
  sourceLock: { path: dependencies.sourceLock, sha256: dependencies.sourceLockSha256 },
  dependencies: packageRecords, importMap,
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, sha256: sha256(bytes) })).sort((a, b) => a.path < b.path ? -1 : 1),
};
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');
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
process.stdout.write(`Packaged readable fetch: ${relative(repository, output)} (${sourceRecords.length} originals, ${packageRecords.length} dependency packages)\n`);
