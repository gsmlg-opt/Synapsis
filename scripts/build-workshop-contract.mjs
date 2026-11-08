import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';

// Author-time compilation only. Runtime loads static local modules and the
// unchanged official YAML Node package; it has no TS loader or oracle VM.
const PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const TREE = '47509a47273231ab15f57252960fe716d7379ffb';
const YAML_SHA256 = '4ef6c54cf559b8a207b7b518378230805a1c84af239b14960e8c67c7d59de5d3';
const YAML_INTEGRITY = 'sha512-3NxN8+78OdzbT7C/WjGsyfPAtJaN3FNDsWxv7Y7mcDsT/oOmgW8BpyQQFFBnvZE3j9Y2Sdz1ULFLezL7Eb2yFw==';
assert.equal(process.versions.node, '24.22.1', 'Fixed author-time Node compiler');
const repository = fileURLToPath(new URL('../', import.meta.url));
const hostRoot = join(repository, 'packages/tool-host/src/skill-workshop');
const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index], value = process.argv[index + 1];
  assert.ok(['--source', '--output'].includes(key) && value && !options.has(key),
    'Usage: build-workshop-contract.mjs [--source pinned-checkout] [--output directory]');
  options.set(key, resolve(value));
}
const sourceRoot = realpathSync(options.get('--source') ?? join(hostRoot, 'vendor/openclaw-source'));
const output = options.get('--output') ?? join(repository, 'apps/synapsis_core/priv/skill_workshop');
assert.ok(output !== hostRoot && !output.startsWith(hostRoot + sep), 'Separate generated destination');
const planBytes = readFileSync(join(hostRoot, 'source-plan.json'));
const plan = JSON.parse(planBytes);
assert.equal(plan.referenceCommit, PIN);
assert.equal(plan.referenceTree, TREE);
assert.equal(plan.npm.packageName, 'yaml');
assert.equal(plan.npm.version, '2.9.1');
assert.equal(plan.npm.sha256, YAML_SHA256);
assert.equal(plan.npm.integrity, YAML_INTEGRITY);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const gitBlob = bytes => createHash('sha1').update('blob ' + bytes.length + '\0').update(bytes).digest('hex');
const git = args => execFileSync('git', ['-C', sourceRoot, ...args], { timeout: 10_000, maxBuffer: 64 * 1024 * 1024 });
if (options.has('--source')) {
  assert.equal(realpathSync(git(['rev-parse', '--show-toplevel']).toString().trim()), sourceRoot);
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), PIN);
  assert.equal(git(['rev-parse', PIN + '^{tree}']).toString().trim(), TREE);
  assert.equal(git(['status', '--porcelain', '--untracked-files=no']).toString(), '', 'Clean tracked reference');
}
const originals = new Map();
for (const row of plan.originals) {
  const path = resolve(sourceRoot, row.path);
  assert.ok(path.startsWith(sourceRoot + sep));
  assert.equal(realpathSync(path), path, 'Regular original source');
  const bytes = readFileSync(path);
  assert.equal(bytes.length, row.bytes, row.path);
  assert.equal(sha256(bytes), row.sha256, row.path);
  assert.equal(gitBlob(bytes), row.gitBlob, row.path);
  assert.ok(Buffer.from(bytes.toString('utf8')).equals(bytes), 'Complete UTF-8 original');
  if (options.has('--source')) assert.ok(bytes.equals(git(['show', PIN + ':' + row.path])), row.path);
  assert.ok(!originals.has(row.path));
  originals.set(row.path, bytes);
}
const lock = originals.get('pnpm-lock.yaml').toString();
assert.ok(lock.includes('yaml@2.9.1:'));
assert.ok(lock.includes(YAML_INTEGRITY), 'Exact pinned registry integrity');

const artifacts = new Map();
const add = (path, bytes) => {
  assert.ok(!artifacts.has(path), 'Unique artifact: ' + path);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
};
const modulePlans = new Map(plan.modules.map(row => [row.path, row]));
assert.equal(modulePlans.size, plan.modules.length);
const targets = new Map(), sources = [], regions = [], links = [];
const staticImport = /^(\s*(?:import|export)\s+(?:\{[^}]*\}|\*(?:\s+as\s+\w+)?|[A-Za-z_$][\w$]*)(?:\s*,\s*\{[^}]*\})?\s+from\s*)(["'])([^"'\r\n]+)\2/gm;
function resolveImport(specifier, importer) {
  if (specifier === 'yaml') return 'vendor/npm/yaml/dist/index.js';
  if (specifier.startsWith('host:')) {
    assert.equal(specifier, 'host:host-diagnostics.mjs');
    return 'host-diagnostics.mjs';
  }
  let path;
  if (specifier.startsWith('source:')) path = specifier.slice(7);
  else if (specifier.startsWith('@openclaw/normalization-core/'))
    path = 'packages/normalization-core/src/' + specifier.slice('@openclaw/normalization-core/'.length) + '.ts';
  else {
    assert.ok(specifier.startsWith('.'), 'Closed pure import: ' + importer + ':' + specifier);
    path = posix.normalize(posix.join(posix.dirname(importer), specifier)).replace(/\.js$/, '.ts');
  }
  return compile(path);
}
function compile(path) {
  if (targets.has(path)) return targets.get(path);
  const spec = modulePlans.get(path);
  assert.ok(spec, 'Explicit pure module: ' + path);
  const original = originals.get(path);
  assert.ok(original, 'Pinned whole original: ' + path);
  const target = 'vendor/openclaw/' + path.replace(/\.ts$/, '.mjs');
  targets.set(path, target);
  let selected = original.toString();
  if (!spec.whole) {
    const chunks = [...spec.imports];
    for (const row of spec.regions) {
      const bytes = original.subarray(row.startByte, row.endByte);
      assert.equal(sha256(bytes), row.sha256, 'Exact complete declarations: ' + path);
      assert.ok(Buffer.from(bytes.toString()).equals(bytes));
      chunks.push(bytes.toString());
      regions.push({ path, ...row });
    }
    if (spec.exports.length) chunks.push('export { ' + spec.exports.join(', ') + ' };');
    selected = chunks.join('\n');
  }
  const stripped = stripTypeScriptTypes(selected, { mode: 'strip', sourceMap: false });
  assert.ok(!/\bimport\s*\(/.test(stripped), 'Static imports only: ' + path);
  let generated = stripped;
  for (const match of [...stripped.matchAll(staticImport)].reverse()) {
    const dependency = resolveImport(match[3], path);
    let replacement = posix.relative(posix.dirname(target), dependency);
    if (!replacement.startsWith('.')) replacement = './' + replacement;
    const at = match.index + match[1].length + 1;
    generated = generated.slice(0, at) + replacement + generated.slice(at + match[3].length);
    links.push({ importer: path, specifier: match[3], generatedImporter: target,
      generatedSpecifier: replacement, generatedTarget: dependency });
  }
  add(target, generated);
  sources.push({ path, kind: spec.whole ? 'complete-module' : 'exact-source-regions',
    sha256: sha256(original), gitBlob: gitBlob(original), selectedSha256: sha256(selected),
    compiledSha256: sha256(stripped), generated: target, generatedSha256: sha256(generated),
    compiler: { api: 'node:module.stripTypeScriptTypes', mode: 'strip', sourceMap: false, authoredBodyPatches: false },
    ...(!spec.whole ? { importEnvelope: spec.imports, exportEnvelope: spec.exports } : {}) });
  return target;
}
for (const row of plan.modules) compile(row.path);

function tarMembers(archive) {
  const tar = gunzipSync(archive), members = new Map();
  for (let at = 0; at + 512 <= tar.length && tar[at] !== 0;) {
    const header = tar.subarray(at, at + 512);
    const name = header.subarray(0, 100).toString().replace(/\0.*$/s, '');
    const prefix = header.subarray(345, 500).toString().replace(/\0.*$/s, '');
    const path = prefix ? prefix + '/' + name : name;
    const size = Number.parseInt(header.subarray(124, 136).toString('ascii').replace(/\0.*$/s, '').trim(), 8);
    assert.ok(Number.isSafeInteger(size) && size >= 0 && at + 512 + size <= tar.length);
    assert.ok(header[156] === 0 || header[156] === 48 || header[156] === 53, 'Regular official archive entry');
    if (header[156] !== 53) {
      assert.ok(path.startsWith('package/') && !path.split('/').includes('..') && !members.has(path));
      members.set(path, tar.subarray(at + 512, at + 512 + size));
    }
    at += 512 + Math.ceil(size / 512) * 512;
  }
  return members;
}
const archive = readFileSync(join(hostRoot, plan.npm.archive));
assert.equal(sha256(archive), YAML_SHA256);
assert.equal('sha512-' + createHash('sha512').update(archive).digest('base64'), YAML_INTEGRITY);
const members = tarMembers(archive);
const yamlPackage = JSON.parse(members.get('package/package.json'));
assert.equal(yamlPackage.name, 'yaml');
assert.equal(yamlPackage.version, '2.9.1');
assert.equal(yamlPackage.license, plan.npm.license);
assert.equal(yamlPackage.main, './dist/index.js');
assert.ok(!yamlPackage.dependencies || Object.keys(yamlPackage.dependencies).length === 0);
for (const row of plan.npm.files) {
  const bytes = members.get('package/' + row.path);
  assert.ok(bytes && bytes.length === row.bytes);
  assert.equal(sha256(bytes), row.sha256);
  assert.ok(bytes.equals(readFileSync(join(hostRoot, 'vendor/npm/yaml', row.path))), 'Exact vendored YAML file');
  add('vendor/npm/yaml/' + row.path, bytes);
}
add('vendor/npm-archives/yaml-2.9.1.tgz', archive);
for (const [path, bytes] of originals) add('vendor/openclaw-source/' + path, bytes);
add('vendor/openclaw/LICENSE', originals.get('LICENSE'));
add('source-plan.json', planBytes);
for (const path of ['contract.mjs', 'worker.mjs', 'evaluation-worker.mjs', 'host-diagnostics.mjs'])
  add(path, readFileSync(join(hostRoot, path)));
const provenance = {
  reference: { commit: PIN, tree: TREE }, sourcePlanSha256: sha256(planBytes),
  transformation: { api: 'node:module.stripTypeScriptTypes', nodeVersion: process.versions.node,
    mode: 'strip', sourceMap: false, authoredBodyPatches: false, runtimeCompiler: false },
  originals: plan.originals,
  sources: sources.sort((a, b) => a.path.localeCompare(b.path)),
  regions: regions.sort((a, b) => a.path.localeCompare(b.path) || a.startByte - b.startByte),
  imports: links.sort((a, b) => a.importer.localeCompare(b.importer) || a.specifier.localeCompare(b.specifier)),
  npm: { ...plan.npm, runtime: 'unchanged official Node CommonJS dist', packageManagerRun: false, lifecycleRun: false },
  hostAdapters: plan.hostAdapters,
  licenses: [{ owner: 'OpenClaw pinned source', path: 'vendor/openclaw/LICENSE', sha256: sha256(originals.get('LICENSE')) },
    { owner: 'yaml@2.9.1', path: 'vendor/npm/yaml/LICENSE', sha256: sha256(members.get('package/LICENSE')) }],
  builderSha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
  artifacts: [...artifacts].map(([path, bytes]) => ({ path, bytes: bytes.length, sha256: sha256(bytes) }))
    .sort((a, b) => a.path.localeCompare(b.path)),
};
add('provenance.json', JSON.stringify(provenance, null, 2) + '\n');
for (const [path, bytes] of artifacts) {
  const destination = join(output, path);
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, bytes);
}
process.stdout.write(`Packaged workshop content contract: ${relative(repository, output)} (${sources.length} pinned modules; official yaml 2.9.1)\n`);
