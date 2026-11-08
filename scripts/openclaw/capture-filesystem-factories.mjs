// Construction-only metadata from complete pinned filesystem factories.
// This trusted-source harness never invokes execute, render or prepareArguments.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FactoryHarness } from './capture-recipes.mjs';

const referenceCommit = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const ordered = value => Array.isArray(value) ? value.map(ordered)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const tools = 'src/agents/sessions/tools/';
const read = tools + 'read.ts';
const write = tools + 'write.ts';
const edit = tools + 'edit.ts';
const wrapper = tools + 'tool-definition-wrapper.ts';
const codeMode = 'src/agents/code-mode-control-tools.ts';
const replay = 'src/agents/tool-replay-safety.ts';
const catalog = 'src/agents/tool-catalog.ts';
const fileDiff = tools + 'file-diff.ts';
const wholeSources = [read, write, edit, wrapper, codeMode, replay,
  'src/plugins/plugin-instance-owned-values.ts', 'src/agents/runtime/internal-hooks.ts',
  'packages/agent-core/src/internal-hooks.ts', tools + 'tool-schemas.ts',
  'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts',
  'src/infra/outbound/channel-target.ts', tools + 'truncate.ts',
  'packages/agent-core/src/harness/utils/truncate.ts', 'src/agents/tool-input-error.ts'];
const allowedSources = [...wholeSources, catalog, fileDiff];

// Each binding is referenced only by deferred execution, rendering, argument
// preparation or replay classification. Unknown imports are never synthesized.
const serviceRules = [
  [read, 'node:fs', ['constants']],
  [read, 'node:fs/promises', ['access', 'readdir', 'stat']],
  [read, 'node:path', ['basename', 'dirname', 'isAbsolute', 'relative', 'resolve', 'sep']],
  [read, '@earendil-works/pi-tui', ['getKeybindings']],
  [read, '@openclaw/media-core/attachment-classify', ['classifyAttachmentBytes']],
  [read, '../../../infra/abort-signal.js', ['racePromiseWithAbortSignal']],
  [read, '../../../infra/errors.js', ['hasErrnoCode', 'toErrorObject']],
  [read, '../../../infra/windows-encoding.js', ['decodeWindowsTextFileBuffer']],
  [read, '../../../media/media-reference.js', ['classifyMediaReferenceSource', 'normalizeMediaReferenceSource', 'resolveMediaReferenceLocalPath']],
  [read, '../../../shared/ignore-rules.js', ['normalizeNativePathSeparators']],
  [read, '../../../shared/levenshtein-distance.js', ['levenshteinDistance']],
  [read, '../../modes/interactive/theme/theme.js', ['getLanguageFromPath', 'highlightCode', 'interactiveAgentTheme']],
  [read, '../../package-metadata.js', ['getReadmePath']],
  [read, '../../utils/image-resize.js', ['processImage']],
  [read, '../../utils/mime.js', ['detectSupportedImageMimeType']],
  [read, '../../utils/paths.js', ['formatPathRelativeToCwdOrAbsolute']],
  [read, './file-mutation-queue.js', ['resolveFileMutationQueueKey', 'withFileMutationQueueKeysResolution']],
  [read, './file-tool-abort.js', ['assertFileToolNotAborted']],
  [read, './limits.js', ['normalizePositiveLimit']],
  [read, './path-utils.js', ['getReadPathVariants', 'getReadQueuePaths', 'resolveLocalPathToCwd', 'resolveToCwd']],
  [read, './read-file.js', ['readLocalFile']],
  [read, './read-page.js', ['createBoundedReadTextPage']],
  [read, './render-utils.js', ['getTextOutput', 'invalidArgText', 'replaceTabs', 'reuseTextComponent', 'shortenPath', 'str', 'trimTrailingEmptyLines']],
  [write, 'node:fs/promises', ['mkdir', 'readFile', 'writeFile']],
  [write, 'node:path', ['dirname']],
  [write, '../../../infra/errors.js', ['isMissingPathError']],
  ...[write, edit].flatMap(source => [
    [source, '../../agent-tool-source-execution-guard.js', ['captureAgentToolSourceExecutionGuard', 'runWithAgentToolSourceExecutionScope']],
    [source, '../../tools/tool-results.js', ['textResult']],
    [source, './file-mutation-queue.js', ['resolveFileMutationQueueKey', 'withFileMutationQueueKeyResolution']],
    [source, './file-tool-abort.js', ['assertFileToolNotAborted']],
    [source, './file-write-verification.js', ['readPersistedFileStat', 'verifyPersistedUtf8File']],
    [source, './path-utils.js', ['resolveLocalPathToCwd', 'resolveToCwd']],
  ]),
  [write, './file-tool-planning.js', ['planFileWriteDiff']],
  [edit, 'node:fs', ['constants']],
  [edit, 'node:fs/promises', ['access', 'readFile', 'writeFile']],
  [edit, '@openclaw/ai/internal/runtime', ['repairJson']],
  [edit, '@openclaw/normalization-core/record-coerce', ['isRecord']],
  [edit, '@openclaw/normalization-core/utf16-slice', ['truncateUtf16Safe']],
  [edit, '../../../infra/errno.js', ['hasErrnoCode']],
  [edit, '../../utf8-file.js', ['decodeUtf8File']],
  [edit, './file-tool-planning.js', ['planFileEdit']],
  [codeMode, '@openclaw/normalization-core/string-coerce', ['readNonBlankString']],
  [codeMode, '../utils.js', ['isPlainObject']],
  [codeMode, './tool-policy.js', ['normalizeToolPolicyName']],
  [replay, './tool-policy-shared.js', ['normalizeToolPolicyName']],
];

function git(root, args) {
  const result = spawnSync('git', ['-C', root, ...args], {
    encoding: 'utf8', timeout: 30000, maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  });
  if (result.status !== 0) throw Error(`reference Git inspection failed: ${result.stderr.trim()}`);
  return result.stdout;
}

function assertCheckout(root) {
  if (realpathSync(git(root, ['rev-parse', '--show-toplevel']).trim()) !== root) throw Error('reference must be a complete checkout root');
  if (git(root, ['rev-parse', 'HEAD']).trim() !== referenceCommit) throw Error('reference commit does not match the pinned filesystem source');
  if (git(root, ['status', '--porcelain', '--untracked-files=no']).trim()) throw Error('reference tracked files have changed');
}

function sourceSnapshot(root) {
  assertCheckout(root);
  const snapshots = new Map();
  for (const path of [...allowedSources, 'LICENSE']) {
    const file = join(root, path);
    if (!realpathSync(file).startsWith(root + sep)) throw Error(`reference source escapes checkout: ${path}`);
    const content = readFileSync(file, 'utf8');
    if (content !== git(root, ['show', `${referenceCommit}:${path}`])) throw Error(`reference source differs from pinned Git blob: ${path}`);
    snapshots.set(path, { path, sha256: hash(content), content });
  }
  return snapshots;
}

class FilesystemFactoryHarness extends FactoryHarness {
  constructor(root, snapshots) {
    super(root, new Map([...snapshots].map(([path, file]) => [path, file.sha256])), { allowedSources });
    this.snapshots = snapshots;
    this.transforms = new Map();
    this.generatedModules = new Map();
  }

  synthetic(identifier, code) {
    const previous = this.generatedModules.get(identifier);
    if (previous && previous.content !== code) throw Error(`generated filesystem module changed: ${identifier}`);
    this.generatedModules.set(identifier, { identifier, content: code, sha256: hash(code) });
    return super.synthetic(identifier, code);
  }

  checkedSource(source) {
    const snapshot = this.snapshots.get(source);
    if (!snapshot || !allowedSources.includes(source)) throw Error(`unlisted filesystem source: ${source}`);
    const content = readFileSync(join(this.root, source), 'utf8');
    if (content !== snapshot.content) throw Error(`filesystem source changed during capture: ${source}`);
    return content;
  }

  module(file) {
    const source = relative(this.root, file);
    if (wholeSources.includes(source)) {
      const content = this.checkedSource(source);
      const executable = stripTypeScriptTypes(content, { mode: 'transform', sourceMap: false });
      this.transforms.set(source, { source, sourceSha256: this.snapshots.get(source).sha256,
        executableSha256: hash(executable), method: 'node:module.stripTypeScriptTypes/transform' });
    } else if (!this.typeboxRoot || !(file === this.typeboxRoot || file.startsWith(this.typeboxRoot + sep))) {
      throw Error(`unlisted complete filesystem module: ${source}`);
    }
    return super.module(file);
  }

  deferred(importer, specifier, name) {
    const entry = JSON.stringify({ kind: 'deferred-service', importer, specifier, export: name });
    const message = JSON.stringify(`filesystem constructor must not use deferred binding: ${specifier}:${name}`);
    // A Proxy also audits property reads on deferred objects such as fs.constants
    // and interactiveAgentTheme, instead of silently providing fake values.
    return `(()=>{const blocked=()=>{globalThis.__captureAudit.push(${entry});throw Error(${message});};return new Proxy(blocked,{apply:blocked,construct:blocked,get:blocked});})()`;
  }

  deferredExports(importer, specifier, names) {
    if (!this.stubs.some(item => item.importer === importer && item.specifier === specifier)) {
      this.stubs.push({ importer, specifier, exports: names, boundary: 'execution-render-or-argument-preparation-only' });
    }
    return names.map(name => `export const ${name}=${this.deferred(importer, specifier, name)};`).join('\n');
  }

  constantProjection(importer, specifier, source, name, deferred = []) {
    const content = this.checkedSource(source);
    const matches = [...content.matchAll(new RegExp(`^export const ${name} = [^;]+;$`, 'gm'))];
    if (matches.length !== 1) throw Error(`constant projection is not unique: ${source}:${name}`);
    const selected = matches[0][0];
    const startByte = Buffer.byteLength(content.slice(0, matches[0].index));
    const generatedCode = selected + '\n' + (deferred.length ? this.deferredExports(importer, specifier, deferred) : '');
    const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
    this.loadedFiles.set(source, { path: source, sha256: this.snapshots.get(source).sha256 });
    this.projections.push({ importer, specifier, source, sourceSha256: this.snapshots.get(source).sha256,
      exports: [name, ...deferred], kind: 'complete-exported-constant',
      selections: [{ kind: 'complete-exported-constant', startByte, endByte: startByte + Buffer.byteLength(selected), sha256: hash(selected) }],
      generatedCode, generatedSha256: hash(generatedCode), executableSha256: hash(executable), executionOnlyExports: deferred });
    return this.synthetic(`capture:filesystem-constant:${importer}:${specifier}`, executable);
  }

  import(specifier, importer) {
    const owner = relative(this.root, importer);
    if (owner === write && specifier === './file-diff.js') {
      return this.constantProjection(owner, specifier, fileDiff, 'WRITE_DIFF_MAX_BYTES');
    }
    if (owner === replay && specifier === './tool-catalog.js') {
      return this.constantProjection(owner, specifier, catalog, 'TOOL_CALL_RAW_TOOL_NAME', ['resolveCoreToolFacts']);
    }
    const rule = serviceRules.find(([source, name]) => source === owner && name === specifier);
    if (rule) return this.synthetic(`capture:filesystem-deferred:${owner}:${specifier}`, this.deferredExports(owner, specifier, rule[2]));
    return super.import(specifier, importer);
  }

  evidence() {
    return {
      attemptedCalls: this.call('globalThis.__captureAudit'),
      loadedFiles: [...this.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
      projections: this.projections,
      stubs: this.stubs,
      generatedModules: [...this.generatedModules.values()].sort((a, b) => a.identifier.localeCompare(b.identifier)),
      transforms: [...this.transforms.values()].sort((a, b) => a.source.localeCompare(b.source)),
    };
  }
}

function recipes() {
  const cwd = '/reference/workspace';
  return [
    ['read/default', 'read', [cwd]],
    ['read/empty-options', 'read', [cwd, {}]],
    ['read/prepared', 'read', [cwd, { autoResizeImages: true, maxBytes: 8192, modelHasVision: true }]],
    ['write/default', 'write', [cwd]],
    ['write/empty-options', 'write', [cwd, {}]],
    ['edit/default', 'edit', [cwd]],
    ['edit/empty-options', 'edit', [cwd, {}]],
  ].map(([id, tool, args]) => ({ id, tool, args, source: tools + tool + '.ts', export: `create${tool[0].toUpperCase() + tool.slice(1)}Tool` }));
}

export async function captureFilesystemFactories(sourceRoot) {
  const harnessFiles = ['capture-filesystem-factories.mjs', 'capture-recipes.mjs'].map(name => ({
    path: `scripts/openclaw/${name}`, sha256: hash(readFileSync(new URL(name, import.meta.url))),
  }));
  const root = realpathSync(sourceRoot);
  const snapshots = sourceSnapshot(root);
  const rows = [];
  const capturedSources = new Map([['LICENSE', { ...snapshots.get('LICENSE'), execution: 'license' }]]);
  const dependencies = new Map();
  for (const recipe of recipes()) {
    const harness = new FilesystemFactoryHarness(root, snapshots);
    await harness.load(recipe.source);
    const descriptor = harness.call(`(()=>{const tool=__exports[${JSON.stringify(recipe.export)}](...${JSON.stringify(recipe.args)});return {
      metadata:{name:tool.name,label:tool.label,description:tool.description,parameters:tool.parameters,outputSchema:tool.outputSchema},
      executeObserved:typeof tool.execute==='function',prepareArgumentsObserved:typeof tool.prepareArguments==='function'
    };})()`);
    const evidence = harness.evidence();
    if (evidence.attemptedCalls.length) throw Error(`filesystem constructor used a deferred binding: ${recipe.id}`);
    if (descriptor.metadata.name !== recipe.tool || !descriptor.executeObserved) throw Error(`unexpected filesystem constructor result: ${recipe.id}`);
    rows.push({ id: recipe.id, source: recipe.source, sourceSha256: snapshots.get(recipe.source).sha256,
      export: recipe.export, args: recipe.args, ...descriptor, ...evidence,
      executeInvoked: false, prepareArgumentsInvoked: false, renderInvoked: false,
      eligibilityVerified: false, assemblyVerified: false, actionVerified: false,
      evidence: 'factory-return',
    });
    for (const file of evidence.loadedFiles) {
      capturedSources.set(file.path, { ...snapshots.get(file.path), execution: wholeSources.includes(file.path) ? 'whole-module' : 'source-projection' });
    }
    for (const file of harness.dependencies.values()) {
      const path = file.path.slice('typebox/'.length);
      const content = readFileSync(join(harness.typeboxRoot, path), 'utf8');
      if (hash(content) !== file.sha256) throw Error(`TypeBox dependency changed during capture: ${file.path}`);
      if (dependencies.has(file.path) && dependencies.get(file.path).sha256 !== file.sha256) throw Error(`TypeBox dependency changed between recipes: ${file.path}`);
      dependencies.set(file.path, { ...file, content });
    }
    const licenseContent = readFileSync(join(harness.typeboxRoot, 'license'), 'utf8');
    if (dependencies.has('typebox/license') && dependencies.get('typebox/license').sha256 !== hash(licenseContent)) throw Error('TypeBox license changed between recipes');
    dependencies.set('typebox/license', { path: 'typebox/license', sha256: hash(licenseContent), content: licenseContent });
  }
  assertCheckout(root);
  for (const file of snapshots.values()) {
    if (readFileSync(join(root, file.path), 'utf8') !== file.content || git(root, ['show', `${referenceCommit}:${file.path}`]) !== file.content) {
      throw Error(`reference source changed after capture: ${file.path}`);
    }
  }
  // Recheck all actual dependency bytes after the final recipe, not just their
  // individual import time. The root is resolved afresh from the real package.
  const typeboxRoot = realpathSync(join(root, 'node_modules/typebox'));
  for (const file of dependencies.values()) {
    if (hash(readFileSync(join(typeboxRoot, file.path.slice('typebox/'.length)))) !== file.sha256) throw Error(`TypeBox dependency changed after capture: ${file.path}`);
  }
  for (const file of harnessFiles) {
    if (hash(readFileSync(new URL(file.path.slice('scripts/openclaw/'.length), import.meta.url))) !== file.sha256) throw Error(`capture harness changed during capture: ${file.path}`);
  }
  return ordered({ referenceCommit, referenceRole: 'capability_reference', runtimeContractAuthority: 'backplane_agent_runtime',
    captureMethod: 'complete filesystem constructors and real metadata/identity helpers; importer-specific deferred services never called',
    captureRuntime: { node: process.version, typescriptTransform: 'node:module.stripTypeScriptTypes/transform', toolRuntimeExecuted: false },
    harness: { files: harnessFiles },
    rows, typebox: { version: '1.3.37', files: [...dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) },
    sourceFiles: [...capturedSources.values()].sort((a, b) => a.path.localeCompare(b.path)),
    assemblyVerified: false, actionVerified: false, eligibilityVerified: false,
    limits: ['constructor metadata only', 'deferred execution/render/argument-preparation bindings are not implementation evidence',
      'runtime assembly and admission unexecuted', 'filesystem effects and process/resource lifecycle unexecuted'],
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  const [sourceRoot, output, ...extra] = process.argv.slice(2);
  if (!sourceRoot || !output || extra.length) throw Error('usage: capture-filesystem-factories.mjs SOURCE_ROOT OUTPUT_JSON');
  const report = await captureFilesystemFactories(sourceRoot);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
}
