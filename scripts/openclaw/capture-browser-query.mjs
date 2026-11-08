// Complete pinned snapshot action and real string/ref/stat helpers; successful
// transport/configuration/envelope/image bindings below are explicit facades.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, realpathSync, lstatSync, readlinkSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative, resolve, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const BROWSER_QUERY_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const browser = 'extensions/browser/src/';
const entry = browser + 'browser-tool.snapshot.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const utf16 = 'packages/normalization-core/src/utf16-slice.ts';
const common = 'src/agents/tools/common.ts';
const results = 'src/agents/tools/tool-results.ts';
const wholeSources = [entry, browser + 'browser/pw-role-snapshot.ts', browser + 'browser/snapshot-roles.ts',
  browser + 'browser/constants.ts', browser + 'browser/vision.ts', strings, records, utf16, common,
  'src/agents/tool-input-error.ts', 'src/param-key.ts', results, 'src/plugin-sdk/expect-runtime.ts',
  'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-normalization.ts'];
const provenanceSources = [browser + 'browser/client.ts', browser + 'browser-tool.runtime.ts',
  'src/security/external-content.ts', 'src/infra/fs-safe.ts', 'packages/media-core/src/mime.ts', 'src/agents/tool-result-limits.ts'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const git = (root, args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000,
  maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BROWSER_QUERY_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BROWSER_QUERY_PIN]).split('\0').filter(Boolean).map(row => {
    const [header, path] = row.split('\t'); const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path); const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])), receipt: {
    verified: true, commit: BROWSER_QUERY_PIN, tree: git(root, ['rev-parse', `${BROWSER_QUERY_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

const hostCode = `globalThis.__captureAudit=[];globalThis.__fixture=undefined;`;
class BrowserQueryHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ AbortController, TextEncoder }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script(hostCode).runInContext(this.context, { timeout: 1000 });
    this.sourceRecords = new Map(); this.importBindings = new Map();
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const path = relative(this.root, file); assert.ok(wholeSources.includes(path), path);
    const bytes = readFileSync(file); assert.equal(hash(bytes), this.tracked.get(path), path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(path, { path, sha256: hash(bytes), executed: true, wholeModule: true,
      transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: () => { throw Error('No dynamic service imports in ordinary snapshot query capture'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:browser-query:' + key, code);
  }
  alias(importer, specifier, source, exports) {
    return this.binding(importer, specifier, 'whole-source-export-alias', exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:' + source)};`,
      { source, sourceSha256: this.tracked.get(source) });
  }
  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:browser-query:') && specifier.startsWith('capture:source:')) return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    const aliases = {
      'openclaw/plugin-sdk/string-coerce-runtime': [importer === entry ? records : strings,
        importer === entry ? ['asRecord'] : ['normalizeLowercaseStringOrEmpty']],
      'openclaw/plugin-sdk/expect-runtime': ['src/plugin-sdk/expect-runtime.ts', ['expectDefined']],
      'openclaw/plugin-sdk/param-readers': [common, ['readNonNegativeIntegerParam', 'readPositiveIntegerParam']],
      'openclaw/plugin-sdk/tool-results': [results, ['textResult']],
      '@openclaw/normalization-core/number-coercion': ['packages/normalization-core/src/number-coercion.ts', ['asPositiveSafeInteger', 'asSafeIntegerInRange', 'parseStrictFiniteNumber']],
      '@openclaw/normalization-core/string-normalization': ['packages/normalization-core/src/string-normalization.ts', ['normalizeSingleOrTrimmedStringList']],
      '@openclaw/normalization-core/record-coerce': [records, ['asNonArrayRecord']],
      '@openclaw/normalization-core/string-coerce': [strings, ['lowercasePreservingWhitespace']],
    };
    if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime' && importer === entry) return this.binding(importer, specifier, 'whole-source-export-alias', ['asRecord', 'normalizeOptionalString', 'readStringValue'],
      `export {asRecord} from ${JSON.stringify('capture:source:' + records)};export {normalizeOptionalString,readStringValue} from ${JSON.stringify('capture:source:' + strings)};`,
      { sources: [records, strings].map(source => ({ source, sha256: this.tracked.get(source) })) });
    if (aliases[specifier]) return this.alias(importer, specifier, ...aliases[specifier]);
    if (specifier === 'openclaw/plugin-sdk/text-utility-runtime') {
      const source = 'src/agents/tool-result-limits.ts';
      const code = readFileSync(join(this.root, source), 'utf8').match(/^export const DEFAULT_MAX_LIVE_TOOL_RESULT_CHARS = [\d_]+;$/m)?.[0];
      assert.ok(code);
      return this.binding(importer, specifier, 'exact-source-constant-projection', ['DEFAULT_MAX_LIVE_TOOL_RESULT_CHARS'], code,
        { source, sourceSha256: this.tracked.get(source), originalWholeModuleExecuted: false });
    }
    if (specifier === 'openclaw/plugin-sdk/security-runtime') return this.binding(importer, specifier, 'ordinary-envelope-and-prefix-facade', ['formatErrorMessage', 'truncateSanitizedExternalContent', 'wrapExternalContent'],
      `import {truncateUtf16Safe} from ${JSON.stringify('capture:source:' + utf16)};
export function formatErrorMessage(){throw Error('Error projection outside ordinary query capture');}
export function truncateSanitizedExternalContent(value,maxChars){const text=truncateUtf16Safe(value,maxChars);return {text,truncated:text.length<value.length,retainedRawChars:text.length};}
export function wrapExternalContent(value){return '<browser-fixture>'+value+'</browser-fixture>';}`,
      { source: 'src/security/external-content.ts', sourceSha256: this.tracked.get('src/security/external-content.ts'), originalSourceExecuted: false });
    const facades = [
      [entry, 'openclaw/plugin-sdk/runtime-config-snapshot', 'src/config/config.ts', ['readRuntimeConfig'], 'export function readRuntimeConfig(){return {};}'],
      [entry, './browser/client.js', browser + 'browser/client.ts', ['browserSnapshot'], `export async function browserSnapshot(target,options){__fixture.calls.push({target,options});return JSON.parse(JSON.stringify(__fixture.snapshot));}`],
      [entry, './browser-tool.runtime.js', browser + 'browser-tool.runtime.ts', ['resolveRuntimeImageSanitization'], `export function resolveRuntimeImageSanitization(){return {fixture:true};}`],
      [entry, 'openclaw/plugin-sdk/channel-actions', common, ['imageResultFromFile'], `export async function imageResultFromFile(params){__fixture.imageCalls.push(params);return {content:[{type:'text',text:params.extraText},{type:'image',data:'fixture-image',mimeType:'image/png'}],details:params.details};}`],
      [common, '@openclaw/media-core/mime', 'packages/media-core/src/mime.ts', ['detectMime'], `export function detectMime(){throw Error('MIME detection outside ordinary query capture');}`],
      [common, '../../infra/fs-safe.js', 'src/infra/fs-safe.ts', ['readLocalFileSafely'], `export function readLocalFileSafely(){throw Error('Filesystem reading outside ordinary query capture');}`],
      [browser + 'browser/vision.ts', 'node:fs/promises', undefined, ['readFile'], `export function readFile(){throw Error('Vision file access outside ordinary query capture');}`],
    ].find(([owner, name]) => owner === importer && name === specifier);
    if (facades) return this.binding(importer, specifier, 'explicit-success-service-facade', facades[3], facades[4],
      { source: facades[2] ?? 'node:fs/promises', ...(facades[2] ? { sourceSha256: this.tracked.get(facades[2]) } : {}), originalImplementationExecuted: false });
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.module(join(this.root, source));
    }
    throw Error(`Unconfigured snapshot query import: ${importer} -> ${specifier}`);
  }
  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
}

function vectors() {
  const refs = { e2: { role: 'button', name: 'Sign out' }, e1: { role: 'button', name: 'Sign IN 雪😀' }, e3: { role: 'heading', name: 'A guide' } };
  const ai = { ok: true, format: 'ai', targetId: 'source-tab', url: 'https://fixture.example/', snapshot: '- button "Sign IN 雪😀" [ref=e1]\n- button "Sign out" [ref=e2]\n- heading "A guide" [ref=e3]', refs };
  const nodes = [{ ref: 'ax1', role: 'button', name: 'Sign IN 雪😀', actionable: true },
    { ref: 'ax2', role: 'InlineTextBox', name: 'Sign out', actionable: false },
    { ref: 'ax3', role: 'StaticText', name: 'Sign IN 雪😀', actionable: false },
    { ref: 'ax4', role: 'textbox', name: 'Notes', value: 'Ordinary value 雪😀', description: 'Long description', actionable: true }];
  const raw = { ok: true, format: 'aria', targetId: 'source-tab', url: ai.url, nodes };
  const make = (id, snapshot, input) => ({ id, snapshot, input: { action: 'snapshot', ...input } });
  return [
    make('ai-case-unicode-whitespace', ai, { query: ' \uFEFFIN\tSIGN\u00a0雪😀 ' }),
    make('ai-source-order-and-repeated-tokens', ai, { query: 'sign sign' }),
    make('raw-full-line-role-token', raw, { snapshotFormat: 'aria', query: 'Sign IN' }),
    make('raw-unicode', raw, { snapshotFormat: 'aria', query: 'sign in 雪😀' }),
    make('raw-value-description', raw, { snapshotFormat: 'aria', query: 'value description' }),
    make('ai-zero-match', ai, { query: 'ordinary zero matches' }),
    make('raw-zero-match', raw, { snapshotFormat: 'aria', query: 'ordinary zero matches' }),
    make('ai-small-cap', ai, { query: 'sign in', maxChars: 5 }),
    make('raw-small-cap', raw, { snapshotFormat: 'aria', query: 'button sign in', maxChars: 5 }),
    make('ai-marker-cap', { ...ai, snapshot: '- button ' + JSON.stringify('Long ordinary title '.repeat(12)) + ' [ref=e1]' }, { query: 'ordinary', maxChars: 70 }),
    make('raw-zero-cap-default', raw, { snapshotFormat: 'aria', query: 'button sign', maxChars: 0 }),
    make('ai-source-truncated', { ...ai, truncated: true }, { query: 'sign in' }),
    make('ai-delta-selection', { ...ai, snapshot: ai.snapshot.replace('[ref=e1]', '[ref=e1] [new]').replace('[ref=e2]', '[ref=e2] [new]'), newElements: 2 }, { query: 'sign in' }),
    make('ai-blank-pass-through', ai, { query: ' \t\uFEFF\u00a0 ' }),
    make('raw-blank-pass-through', raw, { snapshotFormat: 'aria', query: ' \t ' }),
    make('ai-labels-selection', { ...ai, imagePath: '/fixture/image.png', imageType: 'png', labels: true, labelsCount: 2, labelsSkipped: 0, annotations: [{ ref: 'e1' }, { ref: 'e2' }] }, { query: 'sign in', labels: true }),
    make('ai-lexical-yaml-ref', { ...ai, snapshot: `- 'button "Sign IN 雪😀" [ref=e1]':\n  - /url: https://fixture.example/sign`, refs: { e1: refs.e1 } }, { query: 'sign in' }),
  ];
}

export async function captureBrowserQuery(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1'); assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot); const before = checkout(root);
  const harness = new BrowserQueryHarness(root, before.tracked); await harness.load(entry);
  const observations = [];
  for (const vector of vectors()) {
    harness.context.__fixture = plain({ ...vector, calls: [], imageCalls: [] });
    const result = await harness.run('__exports.executeSnapshotAction({input:__fixture.input,target:{fixture:true}})');
    const output = plain(result);
    const text = output.content[0].text;
    const start = text.indexOf('<browser-fixture>'); const end = text.lastIndexOf('</browser-fixture>');
    const boundedText = text.slice(start + '<browser-fixture>'.length, end);
    observations.push({ ...vector, result: output, boundedText, calls: harness.call('__fixture.calls'), imageCalls: harness.call('__fixture.imageCalls') });
  }
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const path of provenanceSources) if (!sourceRecords.some(row => row.path === path)) sourceRecords.push({ path, sha256: before.tracked.get(path), executed: false, provenanceOnly: true });
  const after = checkout(root); assert.deepEqual(before.receipt, after.receipt);
  return { schemaVersion: 1, referencePin: BROWSER_QUERY_PIN,
    exporter: { path: 'scripts/openclaw/capture-browser-query.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    host: { generatedCode: hostCode, sha256: hash(hostCode) }, sourceTree: { before: before.receipt, after: after.receipt },
    sourceRecords, importBindings: [...harness.importBindings.values()], observations,
    boundaries: { wholeSnapshotActionExecuted: true, realBrowserTransportExecuted: false, realConfigServiceExecuted: false,
      realExternalEnvelopeExecuted: false, realSanitizerExecuted: false, realImageLoadingExecuted: false, networkExecuted: false },
    limits: ['Complete pinned snapshot action, actual normalization/numeric readers, ref parser/finalizer/role sets and text-result execute.',
      'Lower browserSnapshot/configuration/image-loading are explicit successful input facades; no browser runtime, registration, network or file reading executes.',
      'External envelope and sanitized prefix are explicit ordinary-text facades using the actual UTF16 helper. No security, permission or sanitizer behavior is tested or established.',
      'Source wrapping retains the real 16000 live-text constant and query budget arithmetic with a deterministic synthetic envelope. Host uses existing native JSON/UTF8 budgets and no new text envelope; full byte parity is not claimed.',
      'Host raw AX aliases/actionable-only public refs and filtered nodes are explicit adaptations. Full captured private handles and delta baselines remain independent of query projection.'] };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3]); const capture = await captureBrowserQuery(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ vectors: capture.observations.length, wholeModules: capture.sourceRecords.filter(row => row.executed).length }) + '\n');
}
