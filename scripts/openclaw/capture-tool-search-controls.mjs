// Ordinary successful reference controls only. This does not implement host discovery.
import assert from 'node:assert/strict';
import { AsyncLocalStorage } from 'node:async_hooks';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const TOOL_SEARCH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'src/agents/tool-search.ts';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const agent = name => `src/agents/${name}.ts`;
const normalization = name => `packages/normalization-core/src/${name}.ts`;
const wholeSources = [entry,
  ...['tool-search-runtime', 'tool-search-catalog', 'tool-search-index', 'tool-search-ranking',
    'tool-search-request', 'tool-search-types', 'tool-search-config', 'tool-search-control-result',
    'tool-search-directory', 'tool-search-scheduling', 'tool-search-transcript', 'tool-search-json',
    'tool-search-recovery', 'tool-schema-hints', 'tool-catalog', 'tool-description-presets',
    'tool-policy-shared', 'tool-input-error', 'tool-effect-receipt', 'tool-result-error',
    'tool-result-limits', 'tool-replay-safety', 'tool-contract-error', 'tool-source-reply-completion',
    'agent-tool-availability', 'agent-tools.execution-validation', 'channel-tool-metadata',
    'before-tool-call-metadata', 'gateway-tool-policy', 'runtime/internal-hooks', 'tools/tool-results',
    'tools/automations-tool-name', 'schema/tool-output-schema', 'mcp-content', 'mcp-structured-mirror',
    'content-blocks', 'embedded-agent-runner/tool-result-text-budget'].map(agent),
  ...['string-normalization', 'string-coerce', 'utf16-slice', 'record-coerce', 'stable-stringify',
    'error-coercion', 'cjk-chars', 'expect'].map(normalization),
  'src/plugins/tool-metadata.ts', 'src/plugins/plugin-instance-owned-values.ts',
  'src/shared/sort-and-limit.ts', 'src/shared/deferred.ts', 'src/shared/global-singleton.ts',
  'src/shared/regexp.ts', 'src/shared/levenshtein-distance.ts', 'src/shared/synchronous-work.ts', 'src/utils/utf8-truncate.ts',
  'src/infra/lru-cache.ts', 'src/infra/map-size.ts', 'src/infra/abort-signal.ts',
  'src/infra/secure-random.ts', 'src/security/external-content.ts', 'src/security/external-content-source.ts',
  'packages/retry/src/index.ts', 'packages/agent-core/src/internal-hooks.ts',
  'packages/agent-core/src/tool-execution-context.ts',
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), TOOL_SEARCH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const rows = git(root, ['ls-tree', '-rz', '--full-tree', TOOL_SEARCH_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const stat = lstatSync(file);
    assert.equal(stat.isSymbolicLink(), mode === '120000', path);
    assert.ok(realpathSync(file).startsWith(root + sep));
    if (mode !== '120000') assert.equal(Boolean(stat.mode & 0o111), mode === '100755', path);
    const bytes = mode === '120000' ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    return { path, mode, gitBlob, sha256: hash(bytes) };
  });
  assert.equal(rows.length, 58558);
  return { tracked: new Map(rows.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: TOOL_SEARCH_PIN, tree: git(root, ['rev-parse', `${TOOL_SEARCH_PIN}^{tree}`]),
      verifiedTrackedFiles: rows.length, filesSha256: hash(JSON.stringify(rows)), blobModeAndSymlinkChecked: true } };
}

// Only successful target effects and absent external host context are supplied here.
// Each facade is an explicit binding below; computed control outputs are never supplied.
const hostCode = `
globalThis.__captureAudit=[];
globalThis.__serviceCalls=[];
globalThis.__targetCalls=[];
globalThis.__randomCalls=[];
globalThis.__descriptor=tool=>({name:tool.name,label:tool.label,description:tool.description,
  parameters:tool.parameters,prepareArguments:typeof tool.prepareArguments==='function'});
globalThis.__targetResult=input=>({content:[{type:'text',text:JSON.stringify({accepted:input,ok:true})},
  {type:'image',data:'aW1hZ2U=',mimeType:'image/png'}],details:{accepted:input,ok:true,rows:[{id:'row-1',title:'Ordinary note'}]}});
globalThis.__makeTarget=(name,description,extra={})=>({name,label:name+' label',description,
  parameters:{type:'object',properties:{topic:{type:'string',description:'Topic to retrieve'},count:{type:'integer',minimum:1}},
    required:['topic'],additionalProperties:false},...extra,
  async execute(toolCallId,input){__targetCalls.push({name,toolCallId,input:JSON.parse(JSON.stringify(input))});return __targetResult(input);}});
`;

class ControlsHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, AbortController, AbortSignal,
      __platform: { createHash, AsyncLocalStorage } }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script(hostCode).runInContext(this.context, { timeout: 1000 });
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.generatedExecutions = [];
  }

  bytes(path) {
    const bytes = readFileSync(join(this.root, path));
    assert.equal(hash(bytes), this.tracked.get(path), path);
    return bytes;
  }

  module(file) {
    if (this.typeboxRoot && file.startsWith(this.typeboxRoot + sep)) {
      const source = readFileSync(file);
      const key = `typebox/${relative(this.typeboxRoot, file)}`;
      this.sourceRecords.set(key, { path: key, sha256: hash(source), executed: true, wholeModule: true,
        transformation: 'none (original JavaScript)', executableSha256: hash(source) });
    } else {
      const path = relative(this.root, file);
      assert.ok(wholeSources.includes(path), `unconfigured source module ${path}`);
      if (!this.sourceRecords.has(path)) {
        const bytes = this.bytes(path);
        this.sourceRecords.set(path, { path, sha256: hash(bytes), executed: true, wholeModule: true,
          transformation, executableSha256: hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })) });
      }
    }
    return super.module(file);
  }

  binding(importer, specifier, kind, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (extra.source && this.tracked.has(extra.source) && !this.sourceRecords.has(extra.source)) {
      this.sourceRecords.set(extra.source, { path: extra.source, sha256: hash(this.bytes(extra.source)),
        executed: false, provenanceOnly: true });
    }
    if (!this.importBindings.has(key)) this.importBindings.set(key, {
      importer, specifier, kind, generatedCode: code, generatedSha256: hash(code), ...extra,
    });
    return this.synthetic('capture:controls:' + key, code);
  }

  region(importer, specifier, path, startMarker, endMarker, prelude, suffix = '') {
    const original = this.bytes(path).toString();
    const start = original.indexOf(startMarker);
    const end = original.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start, path);
    assert.equal(original.indexOf(startMarker, start + startMarker.length), -1, path);
    const selected = original.slice(start, end);
    const generated = prelude + selected + suffix;
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    const record = { path, sha256: hash(original), executed: true, wholeModule: false,
      region: { startByte: Buffer.byteLength(original.slice(0, start)), endByte: Buffer.byteLength(original.slice(0, end)),
        sha256: hash(selected), selectedSource: selected }, prelude, suffix, transformation,
      generatedSourceSha256: hash(generated), executableSha256: hash(executable) };
    this.sourceRecords.set(path, record);
    return this.binding(importer, specifier, 'exact-complete-source-region', executable, { source: path });
  }

  source(importer, specifier, path) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier,
      kind: 'whole-source-module', source: path, sourceSha256: this.tracked.get(path) });
    return this.module(join(this.root, path));
  }

  deferred(importer, specifier, path, names) {
    this.sourceRecords.set(path, { path, sha256: hash(this.bytes(path)), executed: false, provenanceOnly: true });
    return this.binding(importer, specifier, 'uninvoked-external-dependency', names.map(name =>
      `export function ${name}(){globalThis.__captureAudit.push(${JSON.stringify({ kind: 'unexpected-dependency-call', importer, specifier, name })});throw Error('uninvoked dependency ${name}');}`).join('\n'),
    { source: path, exports: names, sourceExecuted: false });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    const fromSynthetic = parent.startsWith('capture:controls:');
    if (fromSynthetic && specifier.startsWith('capture:source:')) return this.module(join(this.root, specifier.slice('capture:source:'.length)));
    if (specifier === 'typebox' || specifier === 'typebox/guard') {
      const resolved = realpathSync(createRequire(join(this.root, 'package.json')).resolve(specifier));
      if (!this.typeboxRoot) super.resolve('typebox', parent);
      assert.ok(resolved.startsWith(this.typeboxRoot + sep));
      const key = importer + ':' + specifier;
      this.importBindings.set(key, { importer, specifier, kind: 'original-typebox', source: `typebox/${relative(this.typeboxRoot, resolved)}`, version: this.typeboxVersion });
      return this.module(resolved);
    }
    if (specifier === 'node:crypto') return this.binding(importer, specifier, 'actual-hash-and-deterministic-random-input', `
export const createHash=globalThis.__platform.createHash;
export function randomBytes(size){globalThis.__randomCalls.push({importer:${JSON.stringify(importer)},size});return Buffer.alloc(size,0x31);}
export function randomInt(){throw Error('uninvoked randomInt');}
export function randomUUID(){throw Error('uninvoked randomUUID');}`, { deterministicInput: 'randomBytes(n) = Buffer.alloc(n, 0x31); boundary IDs only; no crypto claim' });
    if (specifier === 'node:async_hooks') return this.binding(importer, specifier, 'actual-platform-builtin',
      'export const AsyncLocalStorage=globalThis.__platform.AsyncLocalStorage;');
    if (specifier === 'node:buffer') return this.binding(importer, specifier, 'actual-platform-builtin',
      'export const Buffer=globalThis.Buffer;');
    if (specifier === '@openclaw/normalization-core') return this.binding(importer, specifier, 'whole-source-export-alias',
      `export {stableStringify} from 'capture:source:${normalization('stable-stringify')}';
export {expectDefined} from 'capture:source:${normalization('expect')}';`);
    if (specifier.startsWith('@openclaw/normalization-core')) {
      const name = specifier.split('/').at(-1);
      return this.source(importer, specifier, normalization(name));
    }
    const path = specifier.startsWith('.') ? relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts') : undefined;
    if (path === agent('tools/common')) return this.binding(importer, specifier, 'whole-source-export-alias',
      `export {ToolInputError,ToolAuthorizationError} from 'capture:source:${agent('tool-input-error')}';
export {textResult,jsonResult} from 'capture:source:${agent('tools/tool-results')}';
export {asNonArrayRecord as asToolParamsRecord} from 'capture:source:${normalization('record-coerce')}';`,
      { source: agent('tools/common'), sourceSha256: this.tracked.get(agent('tools/common')) });
    if (path === agent('agent-tool-metadata')) return this.region(importer, specifier, path,
      'export type AgentToolActionDescriptor', 'const memoryAction:',
      `import {PluginHostObject} from 'capture:source:src/plugins/plugin-instance-owned-values.ts';\n`,
      `\nexport function copyAgentToolMetadata(){throw Error('uninvoked metadata copy');}\n`);
    if (path === agent('code-mode-control-tools')) return this.region(importer, specifier, path,
      'const codeModeControlTools =', '/** Return whether', '');
    if (path === 'src/config/runtime-snapshot.ts') return this.binding(importer, specifier, 'absent-external-config-context',
      `export function getRuntimeConfigSnapshot(){globalThis.__serviceCalls.push({kind:'absent-runtime-config'});return undefined;}`,
      { source: path, sourceSha256: this.tracked.get(path), sourceExecuted: false });
    if (path === agent('plugin-runtime-refresh')) return this.binding(importer, specifier, 'stable-external-plugin-context',
      `export function captureAgentPluginRuntimeRefresh(){return {assertCurrent(){globalThis.__serviceCalls.push({kind:'stable-plugin-context'});}};}`,
      { source: path, sourceSha256: this.tracked.get(path), sourceExecuted: false });
    if (path === agent('agent-tools.before-tool-call')) return this.binding(importer, specifier, 'absent-external-hook-and-presentation-context', `
export {isToolWrappedWithBeforeToolCallHook} from 'capture:source:src/agents/before-tool-call-metadata.ts';
export function wrapToolWithBeforeToolCallHook(){throw Error('uninvoked hook wrapper');}
export function rewrapToolWithBeforeToolCallHook(){throw Error('uninvoked hook rewrapper');}
export function getBeforeToolCallFailureDisposition(){throw Error('uninvoked error disposition');}
export function finalizeToolTerminalPresentation(params){globalThis.__serviceCalls.push({kind:'terminal-presentation-bookkeeping',toolCallId:params.toolCallId,isError:params.isError});}`,
    { source: path, sourceSha256: this.tracked.get(path), sourceExecuted: false, hookContext: 'absent', terminalPresentationSink: 'trace only' });
    if (path === agent('code-mode-results')) return this.binding(importer, specifier, 'empty-external-code-mode-bookkeeping',
      `export function disposeCodeModeResults(){globalThis.__serviceCalls.push({kind:'empty-code-mode-results'});}`,
      { source: path, sourceSha256: this.tracked.get(path), sourceExecuted: false });
    if (path === agent('subagents/swarm/swarm-collector-capability')) return this.binding(importer, specifier, 'absent-external-swarm-context',
      `export function bindJoinedCollectorInvocation(){globalThis.__serviceCalls.push({kind:'absent-joined-collector'});}`,
      { source: path, sourceSha256: this.tracked.get(path), sourceExecuted: false });
    const deferred = {
      [agent('local-model-lean')]: ['isLocalModelLeanEnabled'],
      ['src/plugins/plugin-tool-execution.ts']: ['bindPluginToolExecutionSource'],
      ['src/logging/secret-redaction-registry.ts']: ['registerSecretValueForRedaction', 'redactRegisteredSecretValues'],
      ['src/secrets/runtime-degraded-state.ts']: ['isTrustedSecretSurfaceUnavailableError'],
    };
    if (path && deferred[path]) return this.deferred(importer, specifier, path, deferred[path]);
    if (specifier === '@openclaw/ai/internal/tool-schema') return this.deferred(importer, specifier,
      'packages/ai/src/internal/tool-schema.ts', ['getPublishedRuntimeToolInputSchema']);
    if (path && wholeSources.includes(path)) return this.source(importer, specifier, path);
    if (this.typeboxRoot && parent.startsWith(this.typeboxRoot + sep) && specifier.startsWith('.')) {
      const file = super.resolve(specifier, parent);
      this.importBindings.set(parent + ':' + specifier, { importer: `typebox/${relative(this.typeboxRoot, parent)}`,
        specifier, kind: 'original-typebox', source: `typebox/${relative(this.typeboxRoot, file)}` });
      return this.module(file);
    }
    this.audit({ kind: 'unknown-import', importer, specifier });
    throw Error(`unconfigured controls import ${importer}:${specifier}`);
  }

  run(code) {
    this.generatedExecutions.push({ code, sha256: hash(code) });
    return new vm.Script(code).runInContext(this.context, { timeout: 1000 });
  }
}

export const TOOL_SEARCH_VECTOR_IDS = [
  'scalar-default-limit', 'scalar-null-default-limit', 'scalar-configured-limit', 'scalar-explicit-positive-limit',
  'lexical-capability', 'exact-id-promotion', 'unique-name-promotion', 'stopword-exact-promotion',
  'batch-group-order', 'scalar-plus-batch-order', 'mcp-compact-metadata',
  'describe-core-id', 'describe-core-name', 'describe-mcp-id', 'describe-mcp-name',
  'dispatch-canonical', 'dispatch-toolId-input', 'dispatch-name-flattened', 'dispatch-dotted-args',
  'dispatch-empty-wrapper-flattened', 'dispatch-prepared-nested-selector',
];

const setupCode = `
const instructions='Use the supplied notebook catalog to find ordinary project notes. '.repeat(9)+'Keep the exact note title and row identifier in the result.';
globalThis.__core=__makeTarget('catalog_notes','Retrieve catalog notebook project notes.',{
 outputSchema:{type:'object',properties:{ok:{type:'boolean'},rows:{type:'array',items:{type:'object',properties:{id:{type:'string'},title:{type:'string'}},required:['id','title'],additionalProperties:false}}},required:['ok','rows'],additionalProperties:false}});
globalThis.__mcp=__makeTarget('notes_lookup','Find project notes from the supplied notebook server.',{resultContentSource:'network'});
__metadata.setPluginToolMeta(__mcp,{pluginId:'fixture-notebook',optional:false,mcp:{
 serverName:'Notebook Server',safeServerName:'notebook',toolName:'notes.lookup',operation:'tool',instructions}});
const fillers=Array.from({length:10},(_,i)=>__makeTarget('note_archive_'+String(i).padStart(2,'0'),'Retrieve archived catalog notebook project notes.'));
globalThis.__direct=__makeTarget('file_read','Read a selected project file.');
globalThis.__only=__makeTarget('image_preview','Preview a supplied image.',{catalogMode:'direct-only'});
globalThis.__stopword=__makeTarget('do','Run an ordinary project task.');
globalThis.__ref=__factory.createToolSearchCatalogRef();
globalThis.__config={tools:{toolSearch:{enabled:true,mode:'tools'}}};
globalThis.__controls=__factory.createToolSearchTools({config:__config,catalogRef:__ref});
globalThis.__assembly=__factory.applyToolSearchCatalog({tools:[...__controls,__core,__mcp,...fillers,__direct,__only,__stopword],
 config:__config,catalogRef:__ref,directToolNames:['file_read']});
globalThis.__configured=__factory.createToolSearchTools({config:{tools:{toolSearch:{enabled:true,mode:'tools',searchDefaultLimit:3,maxSearchLimit:12}}},catalogRef:__ref});
globalThis.__execute=async(control,input,id,configured=false,prepare=false)=>{
 const tool=(configured?__configured:__controls).find(tool=>tool.name===control);
 const prepared=prepare?tool.prepareArguments(input):input;
 const start=__targetCalls.length;
 const result=await tool.execute('ordinary-'+id,prepared);
 return {id,control,input,preparedInput:prepared,result,targetCalls:__targetCalls.slice(start)};
};
`;

export async function captureToolSearchControls(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, realpathSync(fixedRoot));
  const before = checkout(root);
  const harness = new ControlsHarness(root, before.tracked);
  await harness.load('src/plugins/tool-metadata.ts');
  harness.run('globalThis.__metadata=globalThis.__exports;');
  await harness.load(entry);
  harness.run('globalThis.__factory=globalThis.__exports;');
  harness.run(setupCode);
  const descriptors = harness.call('__controls.map(__descriptor)');
  const configuredDescriptors = harness.call('__configured.map(__descriptor)');
  const assembly = harness.call(`({visibleTools:__assembly.tools.map(__descriptor),compacted:__assembly.compacted,
    catalogToolCount:__assembly.catalogToolCount,catalogRegistered:__assembly.catalogRegistered,catalogReused:__assembly.catalogReused,
    entries:__ref.current.entries.map(({tool,...entry})=>entry),directOnlyToolNames:[...__ref.directOnlyToolNames]})`);
  const recipes = [
    ['tool_search', { query: 'notebook' }],
    ['tool_search', { query: 'notebook', limit: null }],
    ['tool_search', { query: 'notebook' }, true],
    ['tool_search', { query: 'notebook', limit: 2 }],
    ['tool_search', { query: 'selected project file', limit: 1 }],
    ['tool_search', { query: 'openclaw:core:catalog_notes', limit: 1 }],
    ['tool_search', { query: 'catalog_notes', limit: 2 }],
    ['tool_search', { query: 'do', limit: 2 }],
    ['tool_search', { queries: [{ query: 'file_read', limit: 1 }, { query: 'do', limit: 1 }] }],
    ['tool_search', { query: 'catalog_notes', limit: 1, queries: [{ query: 'file_read', limit: 1 }, { query: 'do', limit: 1 }] }],
    ['tool_search', { query: 'mcp:notebook:notes_lookup', limit: 1 }],
    ['tool_describe', { id: 'openclaw:core:catalog_notes' }],
    ['tool_describe', { id: 'catalog_notes' }],
    ['tool_describe', { id: 'mcp:notebook:notes_lookup' }],
    ['tool_describe', { name: 'notes_lookup' }],
    ['dispatch_action', { id: 'mcp:notebook:notes_lookup', args: { topic: 'release', count: 2 } }],
    ['dispatch_action', { toolId: 'mcp:notebook:notes_lookup', input: { topic: 'design' } }],
    ['dispatch_action', { name: 'notes_lookup', topic: 'schema', count: 1 }],
    ['dispatch_action', { id: 'notes_lookup', 'args.topic': 'runtime', 'args.count': 3 }],
    ['dispatch_action', { id: 'notes_lookup', args: {}, topic: 'storage' }],
    ['dispatch_action', { args: { toolId: 'notes_lookup', args: { topic: 'prepared' } } }, false, true],
  ];
  assert.equal(recipes.length, TOOL_SEARCH_VECTOR_IDS.length);
  const vectors = [];
  for (const [index, [control, input, configured = false, prepare = false]] of recipes.entries()) {
    const id = TOOL_SEARCH_VECTOR_IDS[index];
    harness.run(`globalThis.__observationPromise=__execute(${JSON.stringify(control)},${JSON.stringify(input)},${JSON.stringify(id)},${configured},${prepare});`);
    const observation = plain(await harness.context.__observationPromise);
    assert.deepEqual(observation.input, input);
    vectors.push(observation);
  }
  const audit = harness.call('__captureAudit');
  assert.deepEqual(audit, [], 'unknown imports, dynamic imports and deferred calls must fail capture');
  const after = checkout(root);
  assert.deepEqual(before.receipt, after.receipt);
  const sourceRecords = [...harness.sourceRecords.values()].sort((a, b) => a.path.localeCompare(b.path));
  return {
    referenceCommit: TOOL_SEARCH_PIN,
    runtime: { node: process.versions.node, v8: process.versions.v8, platform: process.platform, arch: process.arch,
      executable: fixedNode, executableSha256: hash(readFileSync(realpathSync(process.execPath))),
      typebox: { version: harness.typeboxVersion, dependencies: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) } },
    exporterSha256: hash(readFileSync(fileURLToPath(import.meta.url))),
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))), taskModified: false },
    sourceTree: { before: before.receipt, after: after.receipt }, sourceRecords,
    importBindings: [...harness.importBindings.values()],
    generatedHost: [hostCode, setupCode].map(code => ({ code, sha256: hash(code) })),
    generatedExecutions: harness.generatedExecutions,
    audit, descriptors, configuredDescriptors, assembly, vectors,
    serviceCalls: harness.call('__serviceCalls'), randomInputs: harness.call('__randomCalls'),
    targetExecutors: { kind: 'successful-in-memory-MCP-fixture', source: 'generatedHost[0].__makeTarget',
      calls: harness.call('__targetCalls'), realMcp: false, network: false },
    boundaries: {
      completeFactory: true, completeRuntime: true, completeCatalogRequestRankingIndexConfigAndControlText: true,
      sourceMetadata: 'Real setPluginToolMeta/classifyAgentToolSource with explicitly supplied MCP registration metadata.',
      coreCalls: 'Not invoked: the complete runtime dynamically loads core schema validation; dynamic imports are forbidden here. Core full schemas/output metadata are observed through real assembly and describe.',
      dispatch: 'Real Runtime.call, scheduling, result acceptance, detached transcript snapshot and factory envelope; only the successful MCP target executor is supplied.',
      externalContext: 'No hooks, plugin refresh, swarm scope, Code Mode result store, runtime config snapshot or presentation sink. Explicit facade ledger records these absent-service boundaries.',
      modes: 'Only explicitly configured tools mode; directory entrypoint is linked but not invoked. No host mode/default policy adopted.',
      hostEquivalent: false, wholeReferenceComplete: false,
      limits: 'Ordinary positive source evidence only. No negative selectors, rejected policy, overflow, failure, cancellation, crash, security, permissions, auth, TLS or real providers.',
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , source = fixedRoot, output] = process.argv;
  assert.ok(output, 'usage: capture-tool-search-controls.mjs /tmp/openclaw-488631c output.json');
  const capture = await captureToolSearchControls(source);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output, vectors: capture.vectors.length,
    wholeModules: capture.sourceRecords.filter(row => row.wholeModule).length,
    trackedBlobsBeforeAndAfter: capture.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
