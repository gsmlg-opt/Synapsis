// Bounded, exact-source Diffs preparation projections; no factory or rendering.
import assert from 'node:assert/strict';
import { Buffer as NodeBuffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const DIFFS_REQUEST_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const tool = 'extensions/diffs/src/tool.ts';
const config = 'extensions/diffs/src/config.ts';
const types = 'extensions/diffs/src/types.ts';
const common = 'src/agents/tools/common.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const paramKey = 'src/param-key.ts';
const results = 'src/agents/tools/tool-results.ts';
const errors = 'src/agents/tool-input-error.ts';
const render = 'extensions/diffs/src/render.ts';
const utils = 'src/utils.ts';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const transform = 'node:module.stripTypeScriptTypes(mode=strip,sourceMap=false)';
const sourcePaths = [tool, config, types, common, strings, numbers, paramKey, results,
  errors, render, utils, 'src/plugin-sdk/param-readers.ts',
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugin-sdk/text-utility-runtime.ts',
  'src/plugin-sdk/tool-results.ts', 'LICENSE'].sort();

function snapshot(root) {
  const git = args => execFileSync('git', ['-C', root, ...args], { timeout: 10_000 });
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), DIFFS_REQUEST_PIN);
  const sources = sourcePaths.map(path => {
    const bytes = readFileSync(resolve(root, path));
    const original = git(['show', `${DIFFS_REQUEST_PIN}:${path}`]);
    assert.ok(bytes.equals(original), `exact pinned original bytes: ${path}`);
    const content = bytes.toString('utf8');
    assert.ok(NodeBuffer.from(content).equals(bytes), `complete UTF-8 source: ${path}`);
    return { path, content, bytes: bytes.length, sha256: hash(bytes) };
  });
  return { commit: DIFFS_REQUEST_PIN, usedSourceBlobsVerified: sources.length, sources };
}

// Every region begins and ends at one unique literal source marker. Original
// bytes, offsets, hashes and packaging bytes are all retained in the receipt.
function project(source, id, startMarker, endMarker) {
  const text = source.content;
  const start = text.indexOf(startMarker);
  assert.ok(start >= 0, `${id}: start marker`);
  assert.equal(text.indexOf(startMarker, start + startMarker.length), -1, `${id}: unique start`);
  const end = endMarker === null ? text.length : text.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `${id}: end marker`);
  if (endMarker !== null) {
    assert.equal(text.indexOf(endMarker), end, `${id}: unique global end`);
    assert.equal(text.indexOf(endMarker, end + endMarker.length), -1, `${id}: unique end`);
  }
  const selectedSource = text.slice(start, end);
  return {
    id, path: source.path, sourceSha256: source.sha256,
    startByte: NodeBuffer.byteLength(text.slice(0, start)),
    endByte: NodeBuffer.byteLength(text.slice(0, end)),
    startMarker, endMarker, selectedSource, selectedSha256: hash(selectedSource),
  };
}

// These are explicit resolved inputs, not a config resolver or host policy.
const referenceDefaults = {
  fontFamily: 'Fira Code', fontSize: 15, lineSpacing: 1.6, layout: 'unified',
  showLineNumbers: true, diffIndicators: 'bars', wordWrap: true, background: true,
  theme: 'dark', fileFormat: 'png', fileQuality: 'standard', fileScale: 2,
  fileMaxWidth: 960, mode: 'both', ttlSeconds: 1800,
};

function recipes() {
  const row = (id, arguments_, overrides = {}, extra = {}) => ({
    id, arguments: arguments_, resolved: { defaults: { ...referenceDefaults, ...overrides }, ...extra },
  });
  const changed = { before: 'old\n', after: 'new\n' };
  return [
    row('equal-empty', { before: '', after: '' }),
    row('equal-unicode-context', { before: '😀\r\n', after: '😀\r\n', mode: 'file' }, {}, {
      context: { agentId: '\uFEFF agent-1\u00A0', sessionId: ' session-1 ', messageChannel: '\t\n', agentAccountId: 7, unused: 'ignored' },
    }),
    row('before-after-defaults', changed),
    row('empty-optionals', { ...changed, patch: ' \n', path: '\t', lang: '\uFEFF', title: ' ' }, {}, { context: {} }),
    row('patch-title-empty', { patch: ' \n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n \t', title: ' \t' }),
    row('patch-title-omitted', { patch: '@@ -1 +1 @@\n-旧\n+新\n' }),
    row('unicode-trim-labels', { before: '😀 e\u0301\r\n', after: '鍵 é\n', path: '\uFEFF src/鍵.ts\u3000', lang: '\u00A0typescript\u2029', title: '\uFEFF\u0085Title\u0085\uFEFF' }, {}, {
      context: { agentId: ' agent ', sessionId: ' session ', messageChannel: ' web ', agentAccountId: ' account ' }, languagePackAvailable: false,
    }),
    row('view-overrides', { ...changed, mode: 'view', theme: 'light', layout: 'split', expandUnchanged: true }, {}, { languagePackAvailable: true }),
    row('image-alias', { ...changed, mode: 'image' }),
    row('file-pdf', { ...changed, mode: 'file', fileFormat: 'pdf', ttlSeconds: 21600 }),
    row('resolved-custom-defaults', changed, { mode: 'view', theme: 'light', layout: 'split', fontFamily: 'Custom Mono', fontSize: 17, lineSpacing: 1.75, showLineNumbers: false, diffIndicators: 'classic', wordWrap: false, background: false, fileFormat: 'pdf', fileQuality: 'hq', fileScale: 3.25, fileMaxWidth: 1700, ttlSeconds: 2.3459 }),
    row('explicit-same-quality-resets', { ...changed, fileQuality: 'hq' }, { fileQuality: 'hq', fileScale: 3.25, fileMaxWidth: 1700 }),
    row('print-decimal-overrides', { ...changed, fileQuality: 'print', fileScale: 1.005, fileMaxWidth: 1200.5, ttlSeconds: 1.2349, expandUnchanged: false }),
    row('hq-scale-rounding', { ...changed, fileQuality: 'hq', fileScale: 2.345, fileMaxWidth: 999.49, ttlSeconds: 1.0019 }),
    row('print-profile', { ...changed, fileQuality: 'print', mode: 'both' }),
    row('standard-explicit-overrides', { ...changed, fileQuality: 'standard', fileScale: 4, fileMaxWidth: 2400, ttlSeconds: 1, baseUrl: ' https://display.example ' }),
  ];
}

export async function captureDiffsRequest(referenceRoot = fixedRoot) {
  const root = realpathSync(resolve(referenceRoot));
  const harnessBytes = readFileSync(fileURLToPath(import.meta.url));
  const before = snapshot(root);
  const sources = new Map(before.sources.map(row => [row.path, row]));
  const projections = [];
  const region = (path, id, start, end) => {
    const projection = project(sources.get(path), id, start, end);
    projections.push(projection);
    return projection.selectedSource;
  };
  const modules = new Map();
  const executables = [];
  const context = vm.createContext({ Buffer: NodeBuffer });
  function module(path, source, kind, projectionIds = []) {
    const executable = stripTypeScriptTypes(source, { mode: 'strip', sourceMap: false });
    executables.push({ path, kind, projectionIds, generatedSource: source,
      generatedSourceSha256: hash(source), executable, executableSha256: hash(executable), transformation: transform });
    modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path,
      importModuleDynamically() { throw Error('unexpected dynamic import'); } }));
  }
  for (const path of [strings, numbers, paramKey, results, errors]) {
    module(path, sources.get(path).content, 'whole-original-module');
  }
  module(types, region(types, 'diff-enums', 'export const DIFF_LAYOUTS', '\nexport type DiffLayout'), 'exact-source-projections', ['diff-enums']);
  module(utils, region(utils, 'clamps', 'export function clampNumber(', '\n/** Alias for clampNumber'), 'exact-source-projections', ['clamps']);
  module(render, region(render, 'diff-input-error', 'export class DiffInputError', '\nfunction escapeCssString'), 'exact-source-projections', ['diff-input-error']);
  const numericReaders = region(common, 'numeric-readers', 'export function readNumberParam(', '\nexport function readStringArrayParam(\n  params: Record<string, unknown>,\n  key: string,\n  options: StringParamOptions & { required: true },\n');
  module(common, `import {asPositiveSafeInteger,asSafeIntegerInRange,parseStrictFiniteNumber} from '${numbers}';\nimport {readSnakeCaseParamRaw} from '${paramKey}';\nimport {ToolInputError} from '${errors}';\n` + numericReaders,
    'exact-source-projections-with-import-packaging', ['numeric-readers']);
  const profiles = region(config, 'image-profiles-and-reference-defaults', 'const DEFAULT_IMAGE_QUALITY_PROFILES', '\nconst DEFAULT_DIFFS_PLUGIN_SECURITY');
  const imageNormalizers = region(config, 'image-normalizers', 'function normalizeFileFormat(', '\nfunction normalizeTtlSeconds(');
  const imageResolver = region(config, 'image-resolver', 'export function resolveDiffImageRenderOptions(', null);
  module(config, `import {asFiniteNumber} from '${numbers}';\nimport {clampNumber} from '${utils}';\nimport {DIFF_OUTPUT_FORMATS,DIFF_IMAGE_QUALITY_PRESETS} from '${types}';\n` + profiles + imageNormalizers + imageResolver,
    'exact-source-projections-with-import-packaging', ['image-profiles-and-reference-defaults', 'image-normalizers', 'image-resolver']);
  const constants = region(tool, 'input-limits', 'const MAX_BEFORE_AFTER_BYTES', '\nconst loadDiffsBrowserRuntime');
  const inputHelpers = region(tool, 'context-input-byte-helpers', 'function buildArtifactContext(', '\nfunction normalizeBaseUrl(');
  const ttl = region(tool, 'ttl-milliseconds', 'function normalizeTtlMs(', null);
  const planning = region(tool, 'execute-planning-through-render-target', '      const artifactContext = buildArtifactContext(params.context);', '\n\n      const rendered =');
  const renderOptions = region(tool, 'render-options-object', '        {\n          presentation: {', ',\n        renderTarget,');
  const prelude = `import {readFiniteNumberParam} from '${common}';\nimport {normalizeOptionalString} from '${strings}';\nimport {textResult} from '${results}';\nimport {resolveDiffImageRenderOptions} from '${config}';\nimport {DiffInputError} from '${render}';\nimport {DIFF_MODES,DIFF_THEMES,DIFF_LAYOUTS,DIFF_OUTPUT_FORMATS,DIFF_IMAGE_QUALITY_PRESETS} from '${types}';\n`;
  const wrapperBefore = '\nexport function prepare(toolParams, params) {\nconst rawRecord = toolParams;\n';
  const wrapperAfter = '\nreturn {input, options, renderTarget, mode, ttlMs, ...(artifactContext ? {context:artifactContext} : {})};\n}\n';
  module(tool, prelude + constants + inputHelpers + ttl + wrapperBefore + planning + '\nconst options = ' + renderOptions + ';\n' + wrapperAfter,
    'exact-source-projections-with-import-and-output-packaging', ['input-limits', 'context-input-byte-helpers', 'ttl-milliseconds', 'execute-planning-through-render-target', 'render-options-object']);

  // Facades are provenance evidence, not executed SDK aggregators. Each route
  // below is checked against the exact pinned facade before binding originals.
  const facadeEvidence = [
    ['src/plugin-sdk/param-readers.ts', 'readFiniteNumberParam', '../agents/tools/common.js'],
    ['src/plugin-sdk/string-coerce-runtime.ts', 'normalizeOptionalString', '../../packages/normalization-core/src/string-coerce.js'],
    ['src/plugin-sdk/string-coerce-runtime.ts', 'asFiniteNumber', '../../packages/normalization-core/src/number-coercion.js'],
    ['src/plugin-sdk/tool-results.ts', 'textResult', '../agents/tools/tool-results.js'],
    ['src/plugin-sdk/text-utility-runtime.ts', 'clampNumber', '../utils.js'],
  ].map(([path, name, target]) => {
    const source = sources.get(path);
    assert.ok(source.content.includes(name), `${path}: exact exported helper`);
    assert.ok(source.content.includes(`from "${target}"`), `${path}: original helper route`);
    return { path, name, target, sourceSha256: source.sha256, executed: false };
  });
  const links = [];
  const aliases = { '@openclaw/normalization-core/string-coerce': strings };
  const entry = modules.get(tool);
  await entry.link((specifier, importer) => {
    const target = modules.has(specifier) ? specifier
      : aliases[specifier] ?? (specifier.startsWith('.')
        ? posix.normalize(posix.join(posix.dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts')
        : undefined);
    assert.ok(target && modules.has(target), `unknown import: ${importer.identifier}:${specifier}`);
    links.push({ importer: importer.identifier, specifier, target });
    return modules.get(target);
  });
  await entry.evaluate({ timeout: 10_000 });
  const vectors = recipes().map(row => ({ ...row, result: plain(entry.namespace.prepare(row.arguments, row.resolved)) }));
  const after = snapshot(root);
  assert.deepEqual(after, before, 'all used original source bytes and pin unchanged after capture');
  assert.ok(readFileSync(fileURLToPath(import.meta.url)).equals(harnessBytes), 'capture harness unchanged');
  return {
    version: 1, referenceCommit: DIFFS_REQUEST_PIN,
    reference: { usedSourceBlobsVerifiedBeforeAndAfter: true, usedSourceCount: before.sources.length },
    sourceRecords: before.sources, projections, executables, facadeEvidence,
    importBindings: links.sort((a, b) => (a.importer + ':' + a.specifier).localeCompare(b.importer + ':' + b.specifier)),
    nativeBindings: ['Buffer=node:buffer.Buffer'], unknownImports: 'throw', vectors,
    exporter: { path: 'scripts/openclaw/capture-diffs-request.mjs', sha256: hash(harnessBytes) },
    runtime: { node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode, icu: process.versions.icu, platform: process.platform, arch: process.arch, loader: 'node:vm.SourceTextModule', transformation: transform },
    boundaries: {
      completeFactory: false, fullExecuteCallback: false, renderExecuted: false,
      sourceProjectionsOnly: true, sourceStatementEnd: 'const renderTarget = mode === "view" ? "viewer" : artifactOnly ? "image" : "both";',
      inputDomain: 'Schema-admitted typed JSON arguments and explicit already-resolved defaults. The executed original numeric readers retain raw coercion branches, but vectors and Core do not qualify numeric strings or snake-case aliases.',
      packaging: 'Generated imports link exact original helper exports. A generated prepare wrapper executes unchanged context/input/early-result/planning statements and the exact render-options object; only the JSON plan return is generated.',
      baseUrl: 'Viewer URL normalization/building occurs after render and is outside this stage; baseUrl is not consumed. path is a display label, not a filesystem target.',
      effects: [], serviceBindings: [],
      limits: 'No config reads, TypeBox/schema execution, factory, complete callback, renderer, HTML/image/PDF, store, URL generation, delivery, registration, runtime or file application. Ordinary positive cases only; no security/permission/auth, negative/failure/cancel/crash/TLS/mixed/budget/eviction or real-provider tests.',
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , root = fixedRoot, output] = process.argv;
  assert.ok(output, 'usage: capture-diffs-request.mjs ROOT OUTPUT');
  const report = await captureDiffsRequest(root);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output, vectors: report.vectors.length, projections: report.projections.length }) + '\n');
}
