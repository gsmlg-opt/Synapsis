import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { builtinModules, stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';

// Author-time source vendoring only. Packaged runtime uses static local ESM and
// the original CommonJS ipaddr implementation, with no TS loader or VM oracle.
const PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const IPADDR_INTEGRITY = 'sha512-aq+t5NAc+cS6rZQQVWC2x98CPqGtKKTMDd4Gaodv0wShnItdKg/51djkGJ1hqH+Oy0ivDftCbSLCQob8zso01w==';
const IPADDR_SHA256 = '586f7ae92cc869bf61612f0d2765a02d98f813c7d1fff461745b93178da626c3';
const repository = fileURLToPath(new URL('../', import.meta.url));
const hostRoot = join(repository, 'packages/tool-host/src/session-directory');
const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index], value = process.argv[index + 1];
  assert.ok(['--source', '--ipaddr-tarball', '--npm-tarballs', '--output'].includes(key) && value && !options.has(key),
    'Usage: build-session-projection.mjs [--source checkout] [--ipaddr-tarball package.tgz] [--npm-tarballs directory] [--output directory]');
  options.set(key, resolve(value));
}
const bundledSource = join(hostRoot, 'vendor/openclaw-source');
const sourceRoot = realpathSync(options.get('--source') ?? (existsSync(join(bundledSource, 'tsconfig.json')) ? bundledSource : '/tmp/openclaw-488631c'));
const output = options.get('--output') ?? join(repository, 'apps/synapsis_core/priv/session_directory');
assert.ok(output !== hostRoot && !output.startsWith(hostRoot + sep), 'Output must be separate from authored host files');
const archived = sourceRoot === bundledSource;
const prior = archived ? JSON.parse(readFileSync(join(hostRoot, 'pinned-provenance.json'))) : undefined;
const git = args => execFileSync('git', ['-C', sourceRoot, ...args], { timeout: 10_000, maxBuffer: 64 * 1024 * 1024 });
if (!archived) {
  assert.equal(realpathSync(git(['rev-parse', '--show-toplevel']).toString().trim()), sourceRoot);
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), PIN);
  assert.equal(git(['status', '--porcelain', '--untracked-files=no']).toString(), '', 'Clean tracked reference');
} else {
  assert.equal(prior.reference.commit, PIN);
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const npmManifestBytes = readFileSync(join(hostRoot, 'npm-closure.json'));
const npmManifest = JSON.parse(npmManifestBytes);
assert.equal(npmManifest.referenceCommit, PIN);
assert.equal(npmManifest.packages.length, 47, 'Pinned Markdown closure and exact Zod 4.6.7');
const npmByName = new Map(npmManifest.packages.map(row => [row.packageName, row]));
assert.equal(npmByName.size, npmManifest.packages.length, 'Single pinned version for every package');
const originals = new Map(), artifacts = new Map(), sources = [], regions = [], links = [];
const add = (path, bytes) => {
  assert.ok(!artifacts.has(path), 'Unique artifact: ' + path);
  artifacts.set(path, Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
};
function source(path) {
  if (originals.has(path)) return originals.get(path).toString('utf8');
  const file = resolve(sourceRoot, path);
  assert.ok(file.startsWith(sourceRoot + sep));
  assert.equal(realpathSync(file), file, 'Regular pinned source path');
  const bytes = readFileSync(file);
  if (archived) {
    const record = prior.originals.find(row => row.path === path);
    assert.ok(record, 'Previously pinned original: ' + path);
    assert.equal(sha256(bytes), record.sha256, 'Original hash: ' + path);
  } else {
    assert.ok(bytes.equals(git(['show', PIN + ':' + path])), 'Exact pinned blob: ' + path);
  }
  assert.ok(Buffer.from(bytes.toString('utf8')).equals(bytes), 'Complete UTF-8 source');
  originals.set(path, bytes);
  return bytes.toString('utf8');
}

// Exact complete declaration regions; generated function bodies are never
// patched. Import/export envelopes only restrict each module to its pure API.
const selected = {
  'src/gateway/session-utils-core.ts': {
    functions: ['deriveSessionTitle', 'prepareSessionTitleRead'],
    imports: [
      'import { normalizeOptionalString } from "@openclaw/normalization-core/string-coerce";',
      'import { deriveGoalSessionTitle } from "./derive-goal-session-title.js";',
    ],
    excludes: 'Archive, cost, model registry, and child-owner operations.',
  },
  'src/gateway/chat-display-projection.sanitize.ts': {
    functions: ['prepareAssistantHistoryMessage'],
    imports: [
      'import { asOptionalObjectRecord as readObjectRecord } from "@openclaw/normalization-core/record-coerce";',
      'import { prepareAgentRunReplyText } from "../agents/agent-run-terminal-reply.js";',
      'import { readAssistantTextBlocksForPhase, readTerminalSourceReplyDeliveryMirror } from "../shared/chat-message-content.js";',
      'import { isProjectedForwardedMessage } from "./chat-display-projection.helpers.js";',
    ],
    excludes: 'Full-history sanitizer, tool payloads, and workspace conflict services.',
  },
  'src/agents/agent-run-terminal-reply.ts': {
    functions: ['prepareAgentRunReplyText'],
    imports: [
      'import { stripMixedSilentReplyTokens } from "../auto-reply/reply/mixed-silent-reply-tokens.js";',
      'import { isSilentReplyText } from "../auto-reply/tokens.js";',
    ],
    excludes: 'Terminal receipt, lifecycle, route changes, and outbound presentation.',
  },
  'src/skills/discovery/chat-command-invocation.ts': {
    functions: ['normalizeSkillCommandLookup', 'findSkillCommand', 'resolveSkillCommandInvocation'],
    imports: ['import { normalizeLowercaseStringOrEmpty, normalizeOptionalLowercaseString } from "@openclaw/normalization-core/string-coerce";'],
    excludes: 'Skill discovery, file-host registry, explicit reference expansion, and command registry.',
  },
  'packages/media-core/src/mime.ts': {
    functions: ['buildMimeByExt', 'normalizeMimeType', 'getFileExtension', 'mimeTypeFromFilePath', 'kindFromMime'],
    objects: ['EXT_BY_MIME', 'MIME_BY_EXT', 'MIME_SYNONYMS'],
    imports: [
      'import path from "node:path";',
      'import { mediaKindFromMime } from "./constants.js";',
      'import { extnameFromAnyPath } from "./file-name.js";',
    ],
    excludes: 'Byte sniffing and its dynamic file-type dependency, MIME detection, and unused image/container classification.',
  },
  'src/gateway/session-transcript-title-reader.worker.ts': {
    functions: ['findFirstTitleUserText', 'findLastMessageText'],
    imports: [
      'import { asOptionalRecord } from "@openclaw/normalization-core/record-coerce";',
      'import { hasInterSessionUserProvenance } from "../sessions/input-provenance.js";',
      'import { resolveSessionTitleSource } from "../sessions/session-title-source.js";',
      'import { projectSessionDisplayMessage } from "./session-display-projection.js";',
      'import { sqliteMessageEventWithSeq } from "./session-transcript-entry-message.js";',
    ],
    exports: ['findFirstTitleUserText', 'findLastMessageText'],
    excludes: 'SQLite readers, storage authorities, watermark caches, retention, and probe scheduling.',
  },
  'src/sessions/transcript-visible-record.ts': {
    functions: ['isVisibleTranscriptRecord'],
    imports: [
      'import { asOptionalRecord } from "@openclaw/normalization-core/record-coerce";',
      'import { OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE } from "../agents/internal-runtime-context.js";',
    ],
    excludes: 'Run-result matching, nested tool receipt projection, and navigation matching.',
  },
  'src/agents/internal-runtime-context.ts': {
    constants: ['OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE'],
    imports: ['import { RUNTIME_CONTEXT_CUSTOM_TYPE } from "../llm/types.js";'],
    excludes: 'Runtime context formatting, stripping, and system-update ordering.',
  },
  'packages/llm-core/src/types.ts': {
    constants: ['RUNTIME_CONTEXT_CUSTOM_TYPE'], imports: [],
    excludes: 'Unrelated runtime markers and erased provider/model type declarations.',
  },
};

function region(path, pattern, label) {
  const original = source(path);
  const matches = [...original.matchAll(pattern)];
  assert.equal(matches.length, 1, 'One complete declaration: ' + path + ':' + label);
  const match = matches[0];
  regions.push({ path, label, startByte: Buffer.byteLength(original.slice(0, match.index)),
    endByte: Buffer.byteLength(original.slice(0, match.index + match[0].length)), sha256: sha256(match[0]) });
  return match[0];
}

const historyPlanBytes = readFileSync(join(hostRoot, 'history-source-regions.json'));
const historyPlan = JSON.parse(historyPlanBytes);
assert.equal(historyPlan.referenceCommit, PIN);
for (const row of historyPlan.modules) {
  assert.equal(sha256(source(row.path)), row.sha256, 'Pinned history source: ' + row.path);
  selected[row.path] = row.whole ? undefined : {
    byteRegions: row.regions,
    imports: row.imports.map(binding => {
      const specifier = binding.path.startsWith('node:') || binding.path === 'zod' || binding.path === 'ipaddr.js'
        ? binding.path : binding.path.startsWith('host:') ? binding.path : 'source:' + binding.path;
      const clause = binding.name === 'default' ? binding.local
        : binding.name === '*' ? '* as ' + binding.local
        : '{ ' + binding.name + (binding.name === binding.local ? '' : ' as ' + binding.local) + ' }';
      return 'import ' + clause + ' from ' + JSON.stringify(specifier) + ';';
    }),
    exports: row.exports,
    excludes: 'Only exact complete declarations reached by the frozen internal history roots; named host-service import bindings are recorded separately.',
  };
}
for (const path of historyPlan.envelopeOriginals) source(path);
const tsconfig = JSON.parse(source('tsconfig.json')).compilerOptions.paths;
const staticModule = /^(\s*(?:import|export)\s+(?:\{[^}]*\}|\*(?:\s+as\s+\w+)?|[A-Za-z_$][\w$]*)(?:\s*,\s*\{[^}]*\})?\s+from\s*)(["'])([^"'\r\n]+)\2/gm;
const targets = new Map();
function resolveImport(specifier, importer) {
  if (specifier.startsWith('node:')) return specifier;
  if (specifier.startsWith('host:')) return specifier.slice(5);
  if (specifier.startsWith('source:')) return module(specifier.slice(7));
  if (specifier === 'ipaddr.js') return 'vendor/ipaddr/ipaddr.cjs';
  const npmName = specifier.startsWith('@') ? specifier.split('/').slice(0, 2).join('/') : specifier.split('/')[0];
  if (npmByName.has(npmName)) return 'npm:' + specifier;
  let path;
  if (specifier.startsWith('.')) {
    path = posix.normalize(posix.join(posix.dirname(importer), specifier));
    if (!existsSync(join(sourceRoot, path))) path = path.replace(/\.js$/, '.ts');
  } else {
    const exact = tsconfig[specifier];
    assert.ok(exact?.length === 1, 'Exact pinned tsconfig alias: ' + specifier);
    path = exact[0].replace(/^\.\//, '');
    assert.ok(path.startsWith('packages/'), 'Pinned pure package alias');
  }
  assert.ok(path.startsWith('src/') || path.startsWith('packages/'), 'Pinned source module: ' + path);
  return module(path);
}

function module(path) {
  if (targets.has(path)) return targets.get(path);
  const target = 'vendor/openclaw/' + path.replace(/\.ts$/, '.mjs');
  targets.set(path, target);
  const original = source(path);
  const spec = selected[path];
  const chunks = [];
  if (spec) {
    chunks.push(...spec.imports);
    for (const row of spec.byteRegions ?? []) {
      const bytes = Buffer.from(original).subarray(row.startByte, row.endByte);
      assert.equal(sha256(bytes), row.sha256, 'Complete history declaration region: ' + path + ':' + row.declarations.join(','));
      chunks.push(bytes.toString('utf8'));
      regions.push({ path, label: row.declarations.join(',') || 'complete-initializer', ...row });
    }
    for (const name of spec.constants ?? []) chunks.push(region(path, new RegExp('^(?:export )?const ' + name + ' = [^\\n]+;', 'gm'), name));
    for (const name of spec.objects ?? []) chunks.push(region(path, new RegExp('^(?:export )?const ' + name + '\\b[^=]*= \\{[\\s\\S]*?^\\};', 'gm'), name));
    // Object-shaped parameters may close at column zero with `}): ... {`.
    // Only the standalone declaration-closing brace terminates a function.
    for (const name of spec.functions ?? []) chunks.push(region(path, new RegExp('^(?:export )?(?:async )?function ' + name + '\\b[\\s\\S]*?^\\}$', 'gm'), name));
    if (spec.exports?.length) chunks.push('export { ' + spec.exports.join(', ') + ' };');
  }
  const selectedSource = spec ? chunks.join('\n') : original;
  // Node's official transformer lowers constructor parameter properties in
  // this exact original class. No authored declaration/body rewrite is used.
  const compilerMode = path.endsWith('.js') ? 'none-js'
    : path === 'src/config/sessions/session-transcript-projection-error.ts' ? 'transform' : 'strip';
  const stripped = compilerMode === 'none-js' ? selectedSource
    : stripTypeScriptTypes(selectedSource, { mode: compilerMode, sourceMap: false });
  assert.ok(!/\bimport\s*\(/.test(stripped), 'No dynamic imports in packaged pure closure: ' + path);
  let generated = stripped;
  for (const match of [...stripped.matchAll(staticModule)].reverse()) {
    const dependency = resolveImport(match[3], path);
    let replacement = dependency.startsWith('npm:') ? match[3] : dependency.startsWith('node:') ? dependency : posix.relative(posix.dirname(target), dependency);
    if (!dependency.startsWith('npm:') && !replacement.startsWith('.') && !replacement.startsWith('node:')) replacement = './' + replacement;
    const start = match.index + match[1].length + 1;
    generated = generated.slice(0, start) + replacement + generated.slice(start + match[3].length);
    links.push({ importer: path, specifier: match[3], generatedImporter: target, generatedSpecifier: replacement, generatedTarget: dependency });
  }
  add(target, generated);
  sources.push({ path, kind: spec ? 'exact-source-regions' : 'complete-module', sha256: sha256(original),
    selectedSha256: sha256(selectedSource), strippedSha256: sha256(stripped), compiledSha256: sha256(stripped),
    compiler: { api: compilerMode === 'none-js' ? 'original-javascript' : 'node:module.stripTypeScriptTypes', mode: compilerMode,
      sourceMap: false, authoredBodyPatches: false, ...(compilerMode === 'transform' ? { lowering: 'TypeScript constructor parameter properties' } : {}) },
    generated: target, generatedSha256: sha256(generated),
    ...(spec ? { importEnvelope: spec.imports, exportEnvelope: spec.exports ?? [], excludes: spec.excludes } : {}) });
  return target;
}

for (const path of ['src/gateway/session-utils-core.ts', 'src/gateway/session-display-projection.ts', 'src/gateway/session-transcript-title-reader.worker.ts', ...historyPlan.roots.map(root => root.split('#')[0])]) module(path);

function tarMembers(archive) {
  const tar = gunzipSync(archive), members = new Map();
  for (let at = 0; at + 512 <= tar.length && tar[at] !== 0; ) {
    const header = tar.subarray(at, at + 512);
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/s, '');
    const prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/s, '');
    const path = prefix ? prefix + '/' + name : name;
    const size = Number.parseInt(header.subarray(124, 136).toString('ascii').replace(/\0.*$/s, '').trim(), 8);
    assert.ok(Number.isSafeInteger(size) && size >= 0 && at + 512 + size <= tar.length, 'Complete npm archive member');
    const type = header[156];
    assert.ok(type === 0 || type === 48 || type === 53, 'Regular npm package file or directory');
    if (type !== 53) {
      assert.ok(!members.has(path), 'Unique npm archive member');
      members.set(path, tar.subarray(at + 512, at + 512 + size));
    }
    at += 512 + Math.ceil(size / 512) * 512;
  }
  return members;
}

// Verify the selected lock document and exact raw package/snapshot records. This
// is a fixed graph, not a semver solver; npm manifests only check completeness.
const lock = source('pnpm-lock.yaml');
assert.equal(sha256(lock), npmManifest.lockSha256, 'Pinned complete lockfile');
function lockRecords(section) {
  const document = lock.split('\n---\n').at(-1);
  const start = document.indexOf('\n' + section + ':\n');
  assert.ok(start !== -1, 'Lock section: ' + section);
  const rest = document.slice(start + section.length + 3);
  const nextSection = rest.search(/\n[A-Za-z][^\n]*:\n/);
  const body = nextSection === -1 ? rest : rest.slice(0, nextSection);
  const matches = [...body.matchAll(/^  (\S.*?):(?: \{\})?\n/gm)];
  return new Map(matches.map((match, index) => [match[1].replace(/^'|'$/g, ''),
    body.slice(match.index, matches[index + 1]?.index ?? body.length).trimEnd() + '\n']));
}
const lockPackages = lockRecords('packages'), lockSnapshots = lockRecords('snapshots');
const npmPackages = [];
for (const row of npmManifest.packages) {
  const snapshot = lockSnapshots.get(row.pnpmSnapshotKey), resolution = lockPackages.get(row.pnpmPackageKey);
  assert.ok(snapshot && resolution, 'Exact pinned package and snapshot: ' + row.packageName);
  assert.equal(sha256(snapshot), row.snapshotSha256, 'Snapshot record: ' + row.pnpmSnapshotKey);
  assert.equal(sha256(resolution), row.packageRecordSha256, 'Package resolution: ' + row.pnpmPackageKey);
  assert.ok(resolution.includes('integrity: ' + row.integrity), 'Original lock integrity: ' + row.packageName);
  const packagePrefix = 'vendor/node_modules/' + row.packageName + '/';
  let records, archiveSha256;
  if (options.has('--npm-tarballs')) {
    const archivePath = join(options.get('--npm-tarballs'), row.archive);
    const archive = readFileSync(existsSync(archivePath) ? archivePath : join(hostRoot, 'vendor/npm-archives', row.archive));
    assert.equal('sha512-' + createHash('sha512').update(archive).digest('base64'), row.integrity, 'Original npm archive: ' + row.packageName);
    archiveSha256 = sha256(archive);
    const members = tarMembers(archive);
    const roots = [...members.keys()].filter(path => /^[^/]+\/package\.json$/.test(path));
    assert.equal(roots.length, 1, 'One original npm manifest: ' + row.packageName);
    const root = roots[0].slice(0, -'package.json'.length);
    records = [];
    for (const [original, bytes] of members) {
      assert.ok(original.startsWith(root), 'Original npm package root');
      const path = original.slice(root.length);
      assert.ok(path && !path.split('/').some(part => part === '..' || part === ''), 'Original npm member path');
      add(packagePrefix + path, bytes);
      records.push({ original, path, bytes: bytes.length, sha256: sha256(bytes) });
    }
  } else {
    const previous = prior?.npmPackages.find(pkg => pkg.packageName === row.packageName);
    assert.ok(previous, 'Initial authoring requires --npm-tarballs: ' + row.packageName);
    records = previous.files;
    archiveSha256 = previous.archiveSha256;
    for (const file of records) {
      const bytes = readFileSync(join(hostRoot, packagePrefix, file.path));
      assert.equal(sha256(bytes), file.sha256, 'Original npm file: ' + row.packageName + '/' + file.path);
      add(packagePrefix + file.path, bytes);
    }
  }
  const pkg = JSON.parse(artifacts.get(packagePrefix + 'package.json'));
  assert.equal(pkg.name, row.packageName);
  assert.equal(pkg.version, row.version);
  const pinnedDependencies = { ...row.dependencies, ...row.optionalDependencies };
  for (const name of Object.keys({ ...pkg.dependencies, ...pkg.optionalDependencies })) {
    assert.ok(pinnedDependencies[name] && npmByName.get(name)?.pnpmSnapshotKey === pinnedDependencies[name], 'Complete pinned declared dependency: ' + row.packageName + ' -> ' + name);
  }
  for (const name of Object.keys(pkg.peerDependencies ?? {})) {
    assert.ok(pkg.peerDependenciesMeta?.[name]?.optional || npmByName.has(name), 'Pinned required peer: ' + row.packageName + ' -> ' + name);
  }
  const licenses = records.filter(file => /(?:^|\/)(?:licen[cs]e|copying)(?:\.[^/]*)?$/i.test(file.path));
  assert.ok(licenses.length > 0, 'Complete original package license: ' + row.packageName);
  npmPackages.push({ ...row, archiveSha256, license: pkg.license, licenses: licenses.map(file => file.path), files: records.sort((a, b) => a.path.localeCompare(b.path)) });
}

let ipaddrFiles;
if (options.has('--ipaddr-tarball')) {
  const archive = readFileSync(options.get('--ipaddr-tarball'));
  assert.equal(sha256(archive), IPADDR_SHA256, 'Official npm tarball SHA256');
  assert.equal('sha512-' + createHash('sha512').update(archive).digest('base64'), IPADDR_INTEGRITY, 'Exact pnpm lock integrity');
  assert.ok(lock.includes('ipaddr.js@2.5.0:') && lock.includes(IPADDR_INTEGRITY), 'Pinned lock version and integrity');
  const members = tarMembers(archive);
  ipaddrFiles = [
    { original: 'package/LICENSE', path: 'vendor/ipaddr/LICENSE' },
    { original: 'package/lib/ipaddr.js', path: 'vendor/ipaddr/ipaddr.cjs' },
    { original: 'package/package.json', path: 'vendor/ipaddr/package.json' },
  ].map(row => {
    const bytes = members.get(row.original);
    assert.ok(bytes, 'Official ipaddr member: ' + row.original);
    add(row.path, bytes);
    return { ...row, bytes: bytes.length, sha256: sha256(bytes) };
  });
} else {
  assert.ok(prior?.ipaddr.files, 'Initial authoring requires --ipaddr-tarball');
  ipaddrFiles = prior.ipaddr.files;
  for (const row of ipaddrFiles) {
    const bytes = readFileSync(join(hostRoot, row.path));
    assert.equal(sha256(bytes), row.sha256, 'Pinned ipaddr member: ' + row.path);
    add(row.path, bytes);
  }
}
const npmPackage = JSON.parse(artifacts.get('vendor/ipaddr/package.json'));
assert.equal(npmPackage.name, 'ipaddr.js');
assert.equal(npmPackage.version, '2.5.0');
assert.equal(npmPackage.license, 'MIT');
add('vendor/openclaw/LICENSE', source('LICENSE'));

// fs-safe is an independently proven exact npm declaration selection. It is
// deliberately separate from the whole-package optional/native dependency graph.
const fsSafePlanBytes = readFileSync(join(hostRoot, 'fs-safe-source-regions.json'));
const fsSafePlan = JSON.parse(fsSafePlanBytes);
const fsSafeArchive = readFileSync(join(hostRoot, 'vendor/npm-archives', fsSafePlan.archive));
assert.equal(sha256(fsSafeArchive), fsSafePlan.archiveSha256);
assert.equal('sha512-' + createHash('sha512').update(fsSafeArchive).digest('base64'), fsSafePlan.integrity);
assert.ok(lock.includes(fsSafePlan.integrity), 'Pinned fs-safe archive integrity');
const fsSafeMembers = tarMembers(fsSafeArchive);
const fsSafeChunks = [...fsSafePlan.imports], fsSafeFiles = [];
for (const path of [...fsSafePlan.files.map(row => row.path), 'LICENSE', 'package.json']) {
  const bytes = fsSafeMembers.get('package/' + path);
  assert.ok(bytes, 'Exact original fs-safe member: ' + path);
  const row = fsSafePlan.files.find(row => row.path === path);
  if (row) {
    assert.equal(sha256(bytes), row.sha256);
    for (const region of row.regions) {
      const selectedBytes = bytes.subarray(region.startByte, region.endByte);
      assert.equal(sha256(selectedBytes), region.sha256);
      fsSafeChunks.push(selectedBytes.toString('utf8'));
    }
  }
  add('vendor/fs-safe/original/' + path, bytes);
  fsSafeFiles.push({ path, bytes: bytes.length, sha256: sha256(bytes) });
}
add('vendor/fs-safe/safe-file-url-to-path.mjs', fsSafeChunks.join('\n') + '\n');
add('fs-safe-source-regions.json', fsSafePlanBytes);
add('history-source-regions.json', historyPlanBytes);
// The exact archives are retained for disconnected rebuilds, not loaded at runtime.
add('vendor/npm-archives/' + fsSafePlan.archive, fsSafeArchive);
add('vendor/npm-archives/zod-4.6.7.tgz', readFileSync(join(hostRoot, 'vendor/npm-archives/zod-4.6.7.tgz')));
const hostFiles = ['session-projection.mjs', 'helper.mjs', 'worker.mjs', 'history.mjs', 'standalone-history.mjs', 'host-history-services.mjs'];
const hostRecords = [];
for (const path of hostFiles) {
  const bytes = readFileSync(join(hostRoot, path));
  add(path, bytes);
  hostRecords.push({ path, sha256: sha256(bytes) });
}
// Scan executable tokens, not source text: npm JSDoc contains type-only
// import('...') expressions, and strings/regex/template text can contain any
// JavaScript spelling. Template substitutions are executable and are scanned.
// This is author-time only; it neither evaluates source nor changes its bytes.
function runtimeSpecifiers(text, path) {
  const tokens = [];
  let offset = text.startsWith('#!') ? text.indexOf('\n') : 0;
  if (offset < 0) return [];
  const fail = message => assert.fail(message + ': ' + path + ':' + offset);
  const identifierStart = /[$_\p{ID_Start}]/u;
  const identifierPart = /[$\u200c\u200d\p{ID_Continue}]/u;
  const expressionKeywords = new Set(['return', 'throw', 'case', 'delete', 'void', 'typeof', 'new', 'in', 'instanceof', 'yield', 'await', 'extends']);
  const controlKeywords = new Set(['if', 'while', 'for', 'with', 'switch', 'catch']);
  const punctuator = /^(?:>>>=|===|!==|\*\*=|&&=|\|\|=|\?\?=|>>>|<<=|>>=|=>|==|!=|<=|>=|\+\+|--|&&|\|\||\?\?|\?\.|\*\*|<<|>>|\+=|-=|\*=|\/=|%=|&=|\|=|\^=|\.\.\.)/;
  function quoted(quote) {
    const start = offset++;
    while (offset < text.length) {
      const char = text[offset++];
      if (char === quote) return { type: 'string', raw: text.slice(start + 1, offset - 1), quote, start };
      if (char === '\\') {
        if (text[offset] === '\r' && text[offset + 1] === '\n') offset++;
        offset++;
      } else if (char === '\n' || char === '\r') fail('Unterminated JavaScript string');
    }
    fail('Unterminated JavaScript string');
  }
  function template() {
    const start = offset++;
    const token = { type: 'literal', value: '`', start };
    tokens.push(token);
    let substitutions = false;
    while (offset < text.length) {
      const char = text[offset++];
      if (char === '\\') offset++;
      else if (char === '`') {
        if (!substitutions) Object.assign(token, { type: 'string', raw: text.slice(start + 1, offset - 1), quote: '`' });
        else tokens.push({ type: 'literal', value: '`', start: offset - 1 });
        return;
      } else if (char === '$' && text[offset] === '{') {
        substitutions = true;
        offset++;
        tokens.push({ type: 'literal', value: '${', start: offset - 2 });
        code(true);
        tokens.push({ type: 'literal', value: 'template-substitution-end', start: offset - 1 });
      }
    }
    fail('Unterminated JavaScript template');
  }
  function code(substitution = false) {
    const contexts = [], functions = [], classes = [];
    let expressionAllowed = true, statementStart = !substitution, previous;
    while (offset < text.length) {
      const char = String.fromCodePoint(text.codePointAt(offset));
      if (/\s/u.test(char)) { offset += char.length; continue; }
      if (text.startsWith('//', offset)) {
        while (offset < text.length && !/[\r\n\u2028\u2029]/u.test(text[offset])) offset++;
        continue;
      }
      if (text.startsWith('/*', offset)) {
        const end = text.indexOf('*/', offset + 2);
        if (end < 0) fail('Unterminated JavaScript comment');
        offset = end + 2;
        continue;
      }
      if (char === '}' && substitution && contexts.length === 0) { offset++; return; }
      const start = offset, atStatementStart = statementStart;
      let token;
      if (char === '"' || char === "'") {
        token = quoted(char);
        expressionAllowed = statementStart = false;
      } else if (char === '`') {
        template();
        previous = { type: 'literal', value: '`', start, end: offset };
        expressionAllowed = statementStart = false;
        continue;
      } else if (char === '/' && expressionAllowed) {
        offset++;
        let inClass = false, closed = false;
        while (offset < text.length) {
          const next = text[offset++];
          if (/[\r\n\u2028\u2029]/u.test(next)) fail('Unterminated JavaScript regex');
          if (next === '\\') offset++;
          else if (next === '[') inClass = true;
          else if (next === ']') inClass = false;
          else if (next === '/' && !inClass) { closed = true; break; }
        }
        if (!closed) fail('Unterminated JavaScript regex');
        while (offset < text.length && identifierPart.test(text[offset])) offset++;
        token = { type: 'literal', value: 'regex', start };
        expressionAllowed = statementStart = false;
      } else if (identifierStart.test(char) || text.startsWith('\\u', offset)) {
        let value = '';
        while (offset < text.length) {
          const next = String.fromCodePoint(text.codePointAt(offset));
          if (text.startsWith('\\u', offset)) {
            const escape = /^\\u(?:\{([\da-f]+)\}|([\da-f]{4}))/i.exec(text.slice(offset));
            if (!escape) fail('Invalid JavaScript identifier escape');
            value += String.fromCodePoint(parseInt(escape[1] ?? escape[2], 16));
            offset += escape[0].length;
          } else if (identifierPart.test(next)) { value += next; offset += next.length; }
          else break;
        }
        const property = previous?.value === '.' || previous?.value === '?.';
        token = { type: 'word', value, start, atStatementStart, property };
        const declaration = statementStart || !expressionAllowed && previous &&
          /[\r\n\u2028\u2029]/u.test(text.slice(previous.end, start));
        if (!property && value === 'function') functions.push({ depth: contexts.length, expression: !declaration });
        if (!property && value === 'class') classes.push({ depth: contexts.length, expression: !declaration });
        expressionAllowed = !property && (expressionKeywords.has(value) || value === 'else' || value === 'do' ||
          value === 'of' && contexts.at(-1)?.control === 'for');
        statementStart = !property && (value === 'else' || value === 'do' || value === 'export' ||
          statementStart && ['export', 'default', 'async'].includes(value));
      } else if (/\d/.test(char) || char === '.' && /\d/.test(text[offset + 1] ?? '')) {
        const number = /^(?:0[xob][\da-f_]+n?|(?:\d[\d_]*\.?[\d_]*|\.[\d_]+)(?:e[+-]?[\d_]+)?n?)/i.exec(text.slice(offset));
        offset += number[0].length;
        token = { type: 'literal', value: 'number', start };
        expressionAllowed = statementStart = false;
      } else {
        const value = punctuator.exec(text.slice(offset))?.[0] ?? char;
        offset += value.length;
        token = { type: 'punct', value, start };
        if (value === '(') {
          const fn = functions.at(-1)?.depth === contexts.length ? functions.pop() : undefined;
          const control = !previous?.property && controlKeywords.has(previous?.value) ? previous.value
            : previous?.value === 'await' && tokens.at(-2)?.value === 'for' ? 'for' : undefined;
          contexts.push({ close: ')', control, fn });
          expressionAllowed = true;
          statementStart = false;
        } else if (value === '[') {
          contexts.push({ close: ']' });
          expressionAllowed = true;
          statementStart = false;
        } else if (value === '{') {
          const cls = classes.at(-1)?.depth === contexts.length ? classes.pop() : undefined;
          const fn = previous?.functionBody;
          const block = fn !== undefined || cls !== undefined || previous?.value === '=>' ||
            statementStart || previous?.value === ')' || ['try', 'catch', 'finally'].includes(previous?.value) ||
            previous?.value === 'return' && /[\r\n\u2028\u2029]/u.test(text.slice(previous.end, start));
          contexts.push({ close: '}', block, expression: fn?.expression ?? cls?.expression ?? (previous?.value === '=>') });
          expressionAllowed = true;
          statementStart = block;
        } else if ([')', ']', '}'].includes(value)) {
          const context = contexts.pop();
          if (context?.close !== value) fail('Unbalanced JavaScript delimiter');
          if (context.fn) token.functionBody = context.fn;
          expressionAllowed = value === ')' ? !!context.control : value === '}' && context.block && !context.expression;
          statementStart = expressionAllowed;
        } else {
          // A property named class/function is not a pending declaration.
          if (value === ':' || value === ';') {
            while (classes.at(-1)?.depth === contexts.length) classes.pop();
            while (functions.at(-1)?.depth === contexts.length) functions.pop();
          }
          const label = value === ':' && previous?.type === 'word' && previous.atStatementStart && contexts.at(-1)?.block;
          statementStart = value === ';' || !!label;
          if (!['++', '--'].includes(value)) expressionAllowed = !['.', '?.'].includes(value);
        }
      }
      token.end = offset;
      tokens.push(token);
      previous = token;
    }
    if (substitution || contexts.length) fail('Unterminated JavaScript expression');
  }
  code();
  function stringValue(token) {
    return token.raw.replace(/\\(?:\r\n|[\n\r\u2028\u2029]|u\{[\da-f]+\}|u[\da-f]{4}|x[\da-f]{2}|[0-3][0-7]{0,2}|[4-7][0-7]?|[\s\S])/gi, escape => {
      const value = escape.slice(1);
      if (/^(?:\r\n|[\n\r\u2028\u2029])$/u.test(value)) return '';
      if (value[0] === 'u') return String.fromCodePoint(parseInt(value[1] === '{' ? value.slice(2, -1) : value.slice(1), 16));
      if (value[0] === 'x') return String.fromCharCode(parseInt(value.slice(1), 16));
      if (/^[0-7]/.test(value)) return String.fromCharCode(parseInt(value, 8));
      return ({ b: '\b', f: '\f', n: '\n', r: '\r', t: '\t', v: '\v' })[value] ?? value;
    });
  }
  const result = [];
  const addSpecifier = (token, kind) => {
    if (token?.type === 'string') result.push({ specifier: stringValue(token), kind });
  };
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    if (token.type !== 'word' || !['import', 'export', 'require'].includes(token.value)) continue;
    const member = ['.', '?.'].includes(tokens[index - 1]?.value);
    if (member && !(token.value === 'require' && tokens[index - 2]?.value === 'module')) continue;
    let cursor = index + 1;
    if (token.value === 'require' && tokens[cursor]?.value === '?.') cursor++;
    if (tokens[cursor]?.value === '(') {
      if (token.value !== 'export' && [')', ','].includes(tokens[cursor + 2]?.value)) {
        addSpecifier(tokens[cursor + 1], token.value === 'require' ? 'literal-require' : 'local-dynamic-import');
      }
      continue;
    }
    if (member || token.value === 'require') continue;
    if (token.value === 'import' && tokens[cursor]?.type === 'string') {
      addSpecifier(tokens[cursor], 'side-effect-import');
      continue;
    }
    if (token.value === 'import' && tokens[cursor]?.type === 'word') {
      cursor++;
      if (tokens[cursor]?.value === ',') cursor++;
    }
    if (tokens[cursor]?.value === '*') {
      cursor++;
      if (tokens[cursor]?.value === 'as' && tokens[cursor + 1]?.type === 'word') cursor += 2;
    } else if (tokens[cursor]?.value === '{') {
      cursor++;
      while (cursor < tokens.length && tokens[cursor]?.value !== '}') cursor++;
      cursor++;
    }
    if (tokens[cursor]?.value === 'from') addSpecifier(tokens[cursor + 1], 'static-import-export');
  }
  return result;
}

const runtimeEdges = [];
for (const [path, bytes] of artifacts) {
  if (!/\.(?:mjs|cjs|js)$/.test(path) || path.startsWith('vendor/fs-safe/original/')) continue;
  const specifiers = runtimeSpecifiers(bytes.toString('utf8'), path);
  for (const { specifier, kind } of specifiers) {
    const npmName = specifier.startsWith('@') ? specifier.split('/').slice(0, 2).join('/') : specifier.split('/')[0];
    const local = posix.normalize(posix.join(posix.dirname(path), specifier));
    assert.ok(specifier.startsWith('node:') || builtinModules.includes(specifier) || npmByName.has(npmName) ||
      specifier.startsWith('.') && [local, local + '.js', local + '.json', local + '/index.js'].some(target => artifacts.has(target)),
      'Every literal runtime dependency is bundled: ' + path + ' -> ' + specifier);
    runtimeEdges.push({ importer: path, specifier, kind });
  }
}
const originalRecords = [...originals].map(([path, bytes]) => ({ path, sha256: sha256(bytes), bytes: bytes.length,
  gitBlob: archived ? prior.originals.find(row => row.path === path).gitBlob : git(['rev-parse', PIN + ':' + path]).toString().trim() })).sort((a, b) => a.path.localeCompare(b.path));
const provenance = {
  version: 1,
  reference: { commit: PIN, tree: archived ? prior.reference.tree : git(['rev-parse', PIN + '^{tree}']).toString().trim() },
  transformation: { api: 'node:module.stripTypeScriptTypes', nodeVersion: process.versions.node, mode: 'per-source',
    modes: ['strip', 'transform', 'none-js'], sourceMap: false,
    compilerLowering: { 'src/config/sessions/session-transcript-projection-error.ts': 'official Node transform of constructor parameter properties; exact selected author source is retained and hashed' },
    moduleRewrite: 'static import/export specifiers only; npm package imports preserved', functionBodyPatches: false },
  originals: originalRecords,
  sources: sources.sort((a, b) => a.path.localeCompare(b.path)),
  regions: regions.sort((a, b) => a.path.localeCompare(b.path) || a.startByte - b.startByte),
  links: links.sort((a, b) => a.importer.localeCompare(b.importer) || a.specifier.localeCompare(b.specifier)),
  hostFiles: hostRecords,
  license: { id: 'MIT', path: 'vendor/openclaw/LICENSE', sha256: sha256(artifacts.get('vendor/openclaw/LICENSE')) },
  ipaddr: { name: 'ipaddr.js', version: '2.5.0', url: 'https://registry.npmjs.org/ipaddr.js/-/ipaddr.js-2.5.0.tgz',
    integrity: IPADDR_INTEGRITY, archiveSha256: IPADDR_SHA256, license: 'MIT', files: ipaddrFiles },
  npmPackages,
  history: {
    protocol: 1, roots: historyPlan.roots, serviceBindings: historyPlan.serviceBindings,
    sourcePlanSha256: sha256(historyPlanBytes), fsSafe: { ...fsSafePlan, originalFiles: fsSafeFiles },
    readerScope: { sourceField: 'storePath', binding: 'synapsis:history-view:<actual private viewId>',
      meaning: 'virtual injected-reader scope checked against captured session and view; not a filesystem path, source SessionEntry, session key or lifecycle fact' },
    environmentKeys: ['OPENCLAW_HOME', 'OPENCLAW_STATE_DIR', 'OPENCLAW_CONFIG_PATH', 'OPENCLAW_PROFILE', 'HOME', 'USERPROFILE', 'PREFIX', 'ANDROID_DATA', 'NODE_ENV', 'VITEST'],
    limits: { wireBytes: 65536, rawChunkBytes: 32768, logicalTransferBytes: 8388608,
      sourcePageJSONBytes: 1048576, sourcePageRecords: 401, fragmentBytes: 65536, targets: 200,
      standalone: { mode: "standalone", defaultLimit: 200, maxLimit: 1000,
        transcriptAndPendingBytes: 81920, sourcePendingBytes: 4096, textUtf16Units: 4000,
        publicStringBytes: 262144, nativeEnvelopeBytes: 1048576,
        pendingKind: "host extension after source bound; actual extended bytes recounted",
        ordinalWindows: "bounded retained selection over complete original-revision canonical key scan" } },
  },
  runtimeEdges: runtimeEdges.sort((a, b) => a.importer.localeCompare(b.importer) ||
    a.specifier.localeCompare(b.specifier) || a.kind.localeCompare(b.kind)),
  limits: { inputBytes: 8 * 1024 * 1024, outputBytes: 1024 * 1024, workerHeapMb: 128 },
};
add('pinned-provenance.json', JSON.stringify(provenance, null, 2) + '\n');
add('npm-closure.json', npmManifestBytes);
add('manifest.json', JSON.stringify({ protocol: 1, referenceCommit: PIN,
  files: [...artifacts].map(([path, bytes]) => ({ path, bytes: bytes.length, sha256: sha256(bytes) })).sort((a, b) => a.path.localeCompare(b.path)) }, null, 2) + '\n');

// Keep original source next to generated source for offline review/rebuild. Only
// executable artifacts, provenance and licenses are copied into the release.
for (const [path, bytes] of originals) {
  const file = join(bundledSource, path);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, bytes);
}
for (const [path, bytes] of artifacts) {
  for (const root of [hostRoot, output]) {
    if (root === hostRoot && hostFiles.includes(path)) continue;
    const file = join(root, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, bytes);
  }
}
process.stdout.write(`Packaged session projection: ${relative(repository, output)} (${sources.length} pinned modules, exact ipaddr.js 2.5.0)\n`);
