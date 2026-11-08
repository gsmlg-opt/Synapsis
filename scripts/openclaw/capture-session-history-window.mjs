// Independent pinned-source ordinary oracle. Supplied reader pages are not raw transcripts.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const SESSION_HISTORY_WINDOW_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const typeboxRoot = '/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox';
const repository = fileURLToPath(new URL('../../', import.meta.url));
const artifactRoot = join(repository, 'packages/tool-host/src/session-directory');
const factory = 'src/agents/tools/sessions-history-tool.ts';
const kernel = 'src/gateway/server-methods/chat-history-page-kernel.ts';
const response = 'src/gateway/server-methods/chat-history-response-page.ts';
const strip = 'src/agents/tools/chat-history-text.ts';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';

// Every reader page is supplied literally. The source kernel performs projection,
// tail limiting, overread-context removal and metadata assembly on these pages.
export function sessionHistoryWindowVectors() {
  const rows = [
    { role: 'user', content: 'First question.', timestamp: 1700000000001, __openclaw: { seq: 1, id: 'message-1' } },
    { role: 'assistant', content: [{ type: 'text', text: 'First answer.' }], timestamp: 1700000000002, __openclaw: { seq: 2, id: 'message-2' } },
    { role: 'user', content: 'Second question: café.', timestamp: 1700000000003, __openclaw: { seq: 3, id: 'message-3' } },
    { role: 'assistant', content: [{ type: 'text', text: 'Second answer: ready.' }], timestamp: 1700000000004, __openclaw: { seq: 4, id: 'message-4' } },
    { role: 'user', content: 'Third question.', timestamp: 1700000000005, __openclaw: { seq: 5, id: 'message-5' } },
    { role: 'assistant', content: [{ type: 'text', text: 'Third answer.' }], timestamp: 1700000000006, __openclaw: { seq: 6, id: 'message-6' } },
  ];
  const all = rows;
  const reader = (operation, messages, extra = {}) => ({ operation, result: {
    messages, totalMessages: 6, displaySource: 'supplied-history291',
    readWindow: { source: 'supplied-history291', latestResetRawSeq: null }, ...extra,
  } });
  const key = 'agent:main:history291';
  return [
    // Original chat-history-handler.ts uses `const max = limit ?? 200`.
    { id: 'default-tail', args: { sessionKey: key }, max: 200,
      reads: [reader('recent', all)] },
    { id: 'explicit-tail-limit', args: { sessionKey: '  ' + key + '  ', limit: 2 }, max: 2,
      reads: [reader('recent', all)] },
    { id: 'offset-zero', args: { sessionKey: key, limit: 2, offset: 0 }, max: 2,
      reads: [reader('recent', all)] },
    { id: 'older-offset', args: { sessionKey: key, limit: 2, offset: 2 }, max: 2,
      reads: [reader('page', [rows[1], rows[2], rows[3]])] },
    { id: 'oldest-offset', args: { sessionKey: key, limit: 2, offset: 4 }, max: 2,
      reads: [reader('page', [rows[0], rows[1]])] },
    { id: 'present-anchor-centered', args: { sessionKey: key, limit: 3, offset: 2,
      messageId: 'message-3', sessionId: 'transcript-history291' }, max: 3,
      reads: [reader('around', [rows[1], rows[2], rows[3]], { found: true, offset: 2 })] },
    { id: 'present-anchor-limit-one', args: { sessionKey: key, limit: 1, messageId: 'message-3' }, max: 1,
      reads: [reader('around', [rows[2]], { found: true, offset: 3 })] },
    { id: 'present-anchor-near-start', args: { sessionKey: key, limit: 3, messageId: 'message-1' }, max: 3,
      reads: [reader('around', [rows[0], rows[1], rows[2]], { found: true, offset: 3 })] },
    // These action-only cases start from a supplied successful gateway page.
    // Kernel projection is deliberately not bypassed and claimed for this cohort.
    { id: 'tools-default-absent', args: { sessionKey: key, offset: 0, limit: 4 }, gatewayResult: {
      messages: [rows[0], { role: 'assistant', content: [{ type: 'toolCall', id: 'call-1', name: 'lookup', arguments: { topic: 'ordinary' } }],
        timestamp: 1700000000010, __openclaw: { seq: 2, id: 'call-message-1' } },
      { role: 'toolResult', toolCallId: 'call-1', toolName: 'lookup', content: [{ type: 'text', text: 'Found ordinary result.' }],
        timestamp: 1700000000011, __openclaw: { seq: 3, id: 'result-message-1' } }, rows[3]],
      offset: 0, nextOffset: 4, hasMore: true, totalMessages: 6,
      pendingInputs: { items: [], total: 0 },
    } },
    { id: 'tools-include-true', args: { sessionKey: key, includeTools: true, offset: 0, limit: 4 }, gatewayResult: {
      messages: [rows[0], { role: 'assistant', content: [{ type: 'toolCall', id: 'call-1', name: 'lookup', arguments: { topic: 'ordinary' } }],
        timestamp: 1700000000010, __openclaw: { seq: 2, id: 'call-message-1' } },
      { role: 'toolResult', toolCallId: 'call-1', toolName: 'lookup', content: [{ type: 'text', text: 'Found ordinary result.' }],
        timestamp: 1700000000011, __openclaw: { seq: 3, id: 'result-message-1' } }, rows[3]],
      offset: 0, nextOffset: 4, hasMore: true, totalMessages: 6,
      pendingInputs: { items: [], total: 0 },
    } },
    { id: 'queued-pending-page', args: { sessionKey: key, limit: 2, pendingBefore: 1700000000101 }, max: 2,
      reads: [reader('recent', all)], pendingInputs: { items: [
        { id: 'pending-input-1', runId: 'run-pending-1', message: { role: 'user', content: 'Next ordinary question.' },
          acceptedAt: 1700000000100, state: 'queued', queued: true },
      ], total: 2, queuedCount: 2, nextBefore: 1700000000100 } },
    { id: 'session-link', args: { sessionKey: key, limit: 2 }, max: 2,
      reads: [reader('recent', all)], sessionLinkBase: 'https://history.example.test' },
  ];
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), SESSION_HISTORY_WINDOW_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', SESSION_HISTORY_WINDOW_PIN])
    .split('\0').filter(Boolean).map(row => {
      const [header, file] = row.split('\t');
      const [mode, type, gitBlob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(file) && !file.split('/').includes('..'));
      const absolute = join(root, file);
      const symlink = lstatSync(absolute).isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      assert.ok(inside(root, realpathSync(absolute)));
      const bytes = symlink ? Buffer.from(readlinkSync(absolute)) : readFileSync(absolute);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, file);
      return { path: file, gitBlob, sha256: hash(bytes) };
    });
  assert.equal(files.length, 58558);
  const tree = git(root, ['rev-parse', `${SESSION_HISTORY_WINDOW_PIN}^{tree}`]);
  assert.equal(tree, '47509a47273231ab15f57252960fe716d7379ffb');
  return { files: new Map(files.map(row => [row.path, row])), receipt: {
    commit: SESSION_HISTORY_WINDOW_PIN, tree, trackedClean: true, verifiedTrackedFiles: files.length,
    filesSha256: hash(JSON.stringify(files)),
  } };
}

// A qualified service facade admits one ordinary target. It is not the original
// configuration, visibility, authorization, scoped-access or caller-identity owner.
const facadeCode = `
const trace=(name,args)=>{__serviceCalls.push({name,args:JSON.parse(JSON.stringify(args))});};
export function resolveSessionToolContext(opts){trace('resolveSessionToolContext',opts);return {
 cfg:{},mainKey:'main',alias:'main',effectiveRequesterKey:'agent:main:requester291',
 mainSessionKey:'agent:main:main',restrictToSpawned:false,sessionVisibility:'all',a2aPolicy:{}};}
export function resolveSessionAgentIds(args){trace('resolveSessionAgentIds',args);return {sessionAgentId:'main'};}
export function resolveSessionAgentId(args){trace('resolveSessionAgentId',args);return 'main';}
export function isSessionToolMainAlias(key,args){trace('isSessionToolMainAlias',{key,...args});return false;}
export function shouldResolveSessionIdInput(key){trace('shouldResolveSessionIdInput',{key});return false;}
export function resolvePersistedSessionStoreOwnerForKey(cfg,key){trace('resolvePersistedSessionStoreOwnerForKey',{cfg,key});return {kind:'configured',agentId:'main'};}
export async function resolveSessionReference(args){trace('resolveSessionReference',args);return {ok:true,key:'agent:main:history291',agentId:'main'};}
export function createSessionVisibilityRowChecker(args){trace('createSessionVisibilityRowChecker',args);return {check(row){trace('visibility.check',row);return {allowed:true};}};}
export async function resolveVisibleSessionReference(args){trace('resolveVisibleSessionReference',args);return {ok:true,key:'agent:main:history291',displayKey:'agent:main:history291',agentId:'main',requesterOwned:true};}
export function resolveSessionToolTargetAgentId(args){trace('resolveSessionToolTargetAgentId',args);return 'main';}
export async function resolveSessionToolAccess(args){trace('resolveSessionToolAccess',args);return {allowed:true,expectedSessionId:'transcript-history291'};}
export async function runWithScopedSessionAccess(args){const {run,...facts}=args;trace('runWithScopedSessionAccess',facts);return await run();}
export function wrapGatewayPersonalToolExecution(execute){trace('wrapGatewayPersonalToolExecution',{});return async(...args)=>{trace('wrapped.execute',{toolCallId:args[0]});return await execute(...args);};}
`;

const facadeEdges = [
  [factory, '../../config/sessions/session-store-owner.js', 'src/config/sessions/session-store-owner.ts', ['resolvePersistedSessionStoreOwnerForKey']],
  [factory, '../agent-scope.js', 'src/agents/agent-scope.ts', ['resolveSessionAgentId', 'resolveSessionAgentIds']],
  [factory, './gateway-caller-context.js', 'src/agents/tools/gateway-caller-context.ts', ['wrapGatewayPersonalToolExecution']],
  [factory, './scoped-session-access.js', 'src/agents/tools/scoped-session-access.ts', ['resolveSessionToolTargetAgentId', 'runWithScopedSessionAccess']],
  [factory, './sessions-helpers.js', 'src/agents/tools/sessions-helpers.ts', [
    'createSessionVisibilityRowChecker', 'isSessionToolMainAlias', 'resolveSessionReference',
    'resolveSessionToolAccess', 'resolveSessionToolContext', 'resolveVisibleSessionReference', 'shouldResolveSessionIdInput']],
];
const uncalledEdges = [
  [factory, './in-process-gateway.js', 'src/agents/tools/in-process-gateway.ts', ['callAgentToolGatewayRequest']],
  [factory, '../../routing/session-key.js', 'src/routing/session-key.ts', ['parseAgentSessionKey']],
  ['src/agents/tools/common.ts', '@openclaw/media-core/mime', 'packages/media-core/src/mime.ts', ['detectMime']],
  ['src/agents/tools/common.ts', '../../infra/fs-safe.js', 'src/infra/fs-safe.ts', ['readLocalFileSafely']],
];

class HistoryHarness {
  constructor(root, tracked) {
    this.root = root;
    this.tracked = tracked;
    this.modules = new Map();
    this.packageModules = new Map();
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.dependencies = new Map();
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, URLSearchParams,
      AbortController, AbortSignal, setTimeout, clearTimeout, structuredClone,
      process: { env: { NODE_ENV: 'test' }, platform: process.platform, cwd: () => root },
      __serviceCalls: [], __deferredCalls: [],
    // Actual Zod cursor validators may compile their own object parser.
    }, { codeGeneration: { strings: true, wasm: false } });
    const planBytes = readFileSync(join(artifactRoot, 'history-source-regions.json'));
    const plan = JSON.parse(planBytes);
    assert.equal(plan.referenceCommit, SESSION_HISTORY_WINDOW_PIN);
    this.regionPlan = new Map(plan.modules.map(row => [row.path, row]));
    this.planReceipt = { path: 'packages/tool-host/src/session-directory/history-source-regions.json', sha256: hash(planBytes) };
    this.tsconfig = JSON.parse(this.record('tsconfig.json', false)).compilerOptions.paths;
    const provenanceBytes = readFileSync(join(artifactRoot, 'pinned-provenance.json'));
    const provenance = JSON.parse(provenanceBytes);
    assert.equal(provenance.reference.commit, SESSION_HISTORY_WINDOW_PIN);
    this.npmPackages = provenance.npmPackages;
    this.packageFiles = new Map();
    const lock = this.record('pnpm-lock.yaml', false);
    for (const pkg of this.npmPackages) {
      assert.ok(lock.includes(pkg.integrity), pkg.packageName);
      const root = join(artifactRoot, 'vendor/node_modules', pkg.packageName);
      const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
      assert.equal(manifest.name, pkg.packageName);
      assert.equal(manifest.version, pkg.version);
      for (const file of pkg.files) {
        const absolute = join(root, file.path), bytes = readFileSync(absolute);
        assert.equal(bytes.length, file.bytes, absolute);
        assert.equal(hash(bytes), file.sha256, absolute);
        this.packageFiles.set(absolute, { package: pkg.packageName, version: pkg.version,
          path: relative(join(artifactRoot, 'vendor'), absolute), sha256: file.sha256 });
      }
    }
    // ipaddr is the separately inventoried original CommonJS artifact, outside
    // the 47-package ESM/Markdown closure. Load its real namespace unchanged.
    this.ipaddr = provenance.ipaddr;
    assert.equal(this.ipaddr.name, 'ipaddr.js');
    assert.equal(this.ipaddr.version, '2.5.0');
    assert.equal(this.ipaddr.integrity, 'sha512-aq+t5NAc+cS6rZQQVWC2x98CPqGtKKTMDd4Gaodv0wShnItdKg/51djkGJ1hqH+Oy0ivDftCbSLCQob8zso01w==');
    assert.equal(this.ipaddr.archiveSha256, '586f7ae92cc869bf61612f0d2765a02d98f813c7d1fff461745b93178da626c3');
    assert.ok(lock.includes(this.ipaddr.integrity), 'Pinned original ipaddr lock integrity');
    assert.deepEqual(this.ipaddr.files.map(file => [file.path, file.sha256]), [
      ['vendor/ipaddr/LICENSE', '62568a2d1337b77171ecca9db10579163446de1ba6151678e81f06cdc199971b'],
      ['vendor/ipaddr/ipaddr.cjs', '52bcb70a2b313469c52a511ab405a4bd73599e36581d6075bbefdb2cfc4b80d8'],
      ['vendor/ipaddr/package.json', 'a124e0548d4c1f9e2c694807947ef527fa7f7f3012474d54c1df3cc21a5ddb9c'],
    ]);
    for (const file of this.ipaddr.files) {
      const absolute = join(artifactRoot, file.path), bytes = readFileSync(absolute);
      assert.equal(realpathSync(absolute), absolute);
      assert.equal(bytes.length, file.bytes, absolute);
      assert.equal(hash(bytes), file.sha256, absolute);
      this.packageFiles.set(absolute, { package: this.ipaddr.name, version: this.ipaddr.version,
        path: relative(join(artifactRoot, 'vendor'), absolute), sha256: file.sha256 });
    }
    const ipaddrManifest = JSON.parse(readFileSync(join(artifactRoot, 'vendor/ipaddr/package.json')));
    assert.equal(ipaddrManifest.name, this.ipaddr.name);
    assert.equal(ipaddrManifest.version, this.ipaddr.version);
    this.ipaddrEntry = join(artifactRoot, 'vendor/ipaddr/ipaddr.cjs');
    this.npmReceipt = { path: 'packages/tool-host/src/session-directory/pinned-provenance.json', sha256: hash(provenanceBytes) };
    this.typeboxRoot = realpathSync(typeboxRoot);
    const packageJson = join(this.typeboxRoot, 'package.json');
    const typebox = JSON.parse(readFileSync(packageJson));
    assert.equal(typebox.name, 'typebox');
    assert.equal(typebox.version, '1.3.37');
    this.typeboxEntry = realpathSync(createRequire(join(typeboxRoot, 'package.json')).resolve('typebox'));
    this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: hash(readFileSync(packageJson)) });
  }

  record(file, executed, mode = 'complete-module') {
    const tracked = this.tracked.get(file);
    assert.ok(tracked, file);
    const bytes = readFileSync(join(this.root, file));
    assert.equal(hash(bytes), tracked.sha256, file);
    const previous = this.sourceRecords.get(file);
    if (!previous || executed) this.sourceRecords.set(file, { ...tracked, bytes: bytes.length,
      executed, originalSourceExecuted: executed, wholeModule: executed && mode === 'complete-module',
      kind: executed ? mode : 'provenance-only' });
    return bytes.toString('utf8');
  }

  selectedSource(file) {
    // The factory, common parameter/result helpers and actual protocol/schema
    // modules stay whole. History algorithm regions are exact original bytes.
    if (file === factory || file === 'src/agents/tools/common.ts' || file === 'src/agents/tools/tool-results.ts' ||
        file.startsWith('packages/gateway-protocol/') || file.startsWith('packages/normalization-core/')) {
      return this.record(file, true);
    }
    const plan = this.regionPlan.get(file);
    if (plan) {
      const raw = this.record(file, true, plan.whole ? 'complete-module' : 'exact-source-regions');
      assert.equal(hash(raw), plan.sha256, file);
      if (plan.whole) return raw;
      const chunks = plan.imports.map(binding => {
        let target = binding.path, name = binding.name;
        if (name === 'projectHostHistoryMessagesWithState') {
          target = 'src/gateway/chat-display-projection.core.ts'; name = 'projectChatDisplayMessagesWithState';
        }
        const clause = name === 'default' ? binding.local : name === '*' ? '* as ' + binding.local
          : '{ ' + name + (name === binding.local ? '' : ' as ' + binding.local) + ' }';
        return 'import ' + clause + ' from ' + JSON.stringify(target.startsWith('node:') || target === 'zod' || target === 'ipaddr.js' || target.startsWith('host:')
          ? target : 'source:' + target) + ';';
      });
      const regions = [];
      for (const region of plan.regions) {
        const bytes = Buffer.from(raw).subarray(region.startByte, region.endByte);
        assert.equal(hash(bytes), region.sha256, file);
        chunks.push(bytes.toString('utf8'));
        regions.push(region);
      }
      if (file === 'src/utils.ts') chunks.push('export { truncateUtf16Safe } from "@openclaw/normalization-core/utf16-slice";');
      chunks.push('export { ' + plan.exports.join(', ') + ' };');
      this.sourceRecords.get(file).regions = regions;
      this.sourceRecords.get(file).importEnvelope = chunks.slice(0, plan.imports.length);
      return chunks.join('\n');
    }
    if (file === 'src/gateway/session-transcript-readers.ts') {
      const raw = this.record(file, true, 'exact-source-regions');
      return this.exactRegion(file, raw, /^export \{ capArrayByJsonBytes \} from "\.\/session-utils\.fs\.js";$/gm, 'capArrayByJsonBytes re-export');
    }
    if (file === 'src/gateway/session-utils.fs.ts') {
      const raw = this.record(file, true, 'exact-source-regions');
      return 'import { expectDefined } from "source:packages/normalization-core/src/expect.ts";\n' +
        'import { jsonUtf8Bytes } from "../infra/json-utf8-bytes.js";\n' +
        this.exactRegion(file, raw, /^export function capArrayByJsonBytes\b[\s\S]*?^\}$/gm, 'capArrayByJsonBytes');
    }
    if (file === 'src/agents/agent-run-terminal-reply.ts') {
      const raw = this.record(file, true, 'exact-source-regions');
      return 'import { stripMixedSilentReplyTokens } from "../auto-reply/reply/mixed-silent-reply-tokens.js";\n' +
        'import { isSilentReplyText } from "../auto-reply/tokens.js";\n' +
        this.exactRegion(file, raw, /^export function prepareAgentRunReplyText\b[\s\S]*?^\}$/gm, 'prepareAgentRunReplyText');
    }
    return this.record(file, true);
  }

  exactRegion(file, raw, pattern, declaration) {
    const matches = [...raw.matchAll(pattern)];
    assert.equal(matches.length, 1, file + ':' + declaration);
    const match = matches[0];
    const row = this.sourceRecords.get(file);
    row.regions ??= [];
    row.regions.push({ declarations: [declaration], startByte: Buffer.byteLength(raw.slice(0, match.index)),
      endByte: Buffer.byteLength(raw.slice(0, match.index + match[0].length)), sha256: hash(match[0]) });
    return match[0];
  }

  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    let executable;
    if (inside(this.typeboxRoot, file) || this.packageFiles.has(file)) {
      executable = readFileSync(file, 'utf8');
      const record = inside(this.typeboxRoot, file)
        ? { path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(executable) }
        : this.packageFiles.get(file);
      assert.equal(hash(executable), record.sha256, file);
      this.dependencies.set(record.path, record);
    } else {
      const owner = relative(this.root, file);
      const selected = this.selectedSource(owner);
      executable = file.endsWith('.js') ? selected : stripTypeScriptTypes(selected, { mode: 'transform', sourceMap: false });
      Object.assign(this.sourceRecords.get(owner), { transformation: file.endsWith('.js') ? 'original-javascript' : transformation,
        selectedSha256: hash(selected), executableSha256: hash(executable) });
    }
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: () => { this.context.__deferredCalls.push('dynamic-import'); throw Error('Undeclared source dynamic import'); },
    });
    this.modules.set(file, mod);
    return mod;
  }

  binding(key, record, code) {
    if (!this.importBindings.has(key)) this.importBindings.set(key, { ...record, generatedCode: code, generatedSha256: hash(code) });
    const id = 'binding:' + key;
    if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(code, { context: this.context, identifier: id }));
    return this.modules.get(id);
  }

  async link(specifier, parent) {
    const owner = relative(this.root, parent.identifier), key = owner + ':' + specifier;
    const facade = facadeEdges.find(row => row[0] === owner && row[1] === specifier);
    if (facade) {
      this.record(facade[2], false);
      // The denial formatter is only imported; none of the ordinary cases calls it.
      const extra = specifier === './sessions-helpers.js'
        ? '\nexport function formatSessionToolAccessDenial(){__deferredCalls.push("formatSessionToolAccessDenial");throw Error("Uncalled denial edge");}' : '';
      return this.binding(key, { importer: owner, specifier, kind: 'qualified-supplied-host-service-facade',
        source: facade[2], exports: facade[3], originalSourceExecuted: false }, facadeCode + extra);
    }
    const deferred = uncalledEdges.find(row => row[0] === owner && row[1] === specifier);
    if (deferred) {
      this.record(deferred[2], false);
      const code = deferred[3].map(name => `export function ${name}(){__deferredCalls.push(${JSON.stringify(key + '#' + name)});throw Error('Uncalled source import edge invoked');}`).join('\n');
      return this.binding(key, { importer: owner, specifier, kind: 'throwing-uncalled-import-edge',
        source: deferred[2], exports: deferred[3], originalSourceExecuted: false }, code);
    }
    if (specifier === 'host:host-history-services.mjs') {
      return this.binding(key, { importer: owner, specifier, kind: 'supplied-invocation-logging-config',
        source: 'src/logging/config.ts', originalSourceExecuted: false },
      'export function readInvocationLoggingConfig(){__serviceCalls.push({name:"readInvocationLoggingConfig",args:{kind:"pinned-default",mappedOverride:"absent"}});return undefined;}');
    }
    if (specifier === 'host:vendor/fs-safe/safe-file-url-to-path.mjs') {
      return this.binding(key, { importer: owner, specifier, kind: 'throwing-uncalled-import-edge',
        originalSourceExecuted: false }, 'export function safeFileURLToPath(){__deferredCalls.push("safeFileURLToPath");throw Error("Uncalled file URL edge");}');
    }
    if (specifier.startsWith('node:')) {
      const id = 'builtin:' + specifier;
      this.importBindings.set(key, { importer: owner, specifier, kind: 'actual-platform-builtin' });
      if (!this.modules.has(id)) {
        const namespace = await import(specifier);
        this.modules.set(id, new vm.SyntheticModule(Object.keys(namespace), function () {
          for (const name of Object.keys(namespace)) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: id }));
      }
      return this.modules.get(id);
    }
    if (specifier === 'typebox' || inside(this.typeboxRoot, parent.identifier)) {
      const file = specifier === 'typebox' ? this.typeboxEntry : realpathSync(resolve(dirname(parent.identifier), specifier));
      assert.ok(inside(this.typeboxRoot, file));
      this.importBindings.set(key, { importer: owner, specifier, kind: 'actual-pinned-TypeBox-module',
        path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(readFileSync(file)) });
      return this.module(file);
    }
    const npmPackage = this.npmPackages.find(row => specifier === row.packageName || specifier.startsWith(row.packageName + '/'));
    if (specifier === 'ipaddr.js' || npmPackage || this.packageFiles.has(parent.identifier)) {
      const importer = this.packageFiles.has(parent.identifier) ? parent.identifier : join(artifactRoot, 'vendor/package.json');
      const file = specifier === 'ipaddr.js' ? this.ipaddrEntry : realpathSync(createRequire(importer).resolve(specifier));
      assert.ok(this.packageFiles.has(file), 'Exact npm artifact: ' + file);
      const artifact = this.packageFiles.get(file);
      this.importBindings.set(key, { importer: owner, specifier, kind: 'actual-pinned-npm-export-namespace', ...artifact,
        boundary: 'Official unchanged package export namespace and host Node dependency graph; entry execution is observed, individual dependency module execution is not instrumented.' });
      this.dependencies.set(artifact.path, artifact);
      if (!this.packageModules.has(file)) this.packageModules.set(file,
        import(pathToFileURL(file).href).then(namespace => new vm.SyntheticModule(Object.keys(namespace), function () {
          for (const name of Object.keys(namespace)) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: file })));
      return this.packageModules.get(file);
    }
    let target;
    if (specifier.startsWith('source:')) target = specifier.slice(7);
    else if (specifier.startsWith('.')) {
      const absolute = resolve(dirname(parent.identifier), specifier);
      target = relative(this.root, existsSync(absolute) ? absolute : absolute.replace(/\.js$/, '.ts'));
    } else {
      const alias = this.tsconfig[specifier];
      assert.ok(alias?.length === 1, 'Pinned exact tsconfig alias: ' + specifier);
      target = alias[0].replace(/^\.\//, '');
    }
    assert.ok(this.tracked.has(target), owner + ':' + specifier + ' -> ' + target);
    this.importBindings.set(key, { importer: owner, specifier, kind: 'unchanged-pinned-source', target });
    return this.module(join(this.root, target));
  }

  async load(file) {
    const mod = this.module(join(this.root, file));
    if (mod.status === 'unlinked') await mod.link((specifier, parent) => this.link(specifier, parent));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 10_000 });
    assert.equal(mod.status, 'evaluated');
    return mod.namespace;
  }

  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 10_000 }); }
}

// This code supplies fixture pages and records calls; no history selection,
// projection, sanitization, byte counting or pagination algorithm is authored here.
const observeCode = `(async()=>{
  const readerCalls=[],gatewayCalls=[];let readIndex=0;
  const read=async(operation,scope,options)=>{
    readerCalls.push({operation,scope,options});
    const supplied=__input.reads[readIndex++];
    if(!supplied||supplied.operation!==operation)throw Error('Unexpected supplied-reader request');
    return JSON.parse(JSON.stringify(supplied.result));
  };
  const readers={readRecentSessionMessagesWithStatsAsync:(scope,options)=>read('recent',scope,options),
    readSessionMessagesPageWithStatsAsync:(scope,options)=>read('page',scope,options),
    readSessionMessagesAroundIdWithStatsAsync:(scope,options)=>read('around',scope,options)};
  let kernelPage,preparedPage,gatewayResult;
  const callGateway=async request=>{
    gatewayCalls.push(JSON.parse(JSON.stringify(request)));
    if(request.method!=='chat.history')throw Error('Unexpected gateway method');
    if(__input.gatewayResult){gatewayResult=JSON.parse(JSON.stringify(__input.gatewayResult));return gatewayResult;}
    const params={sessionId:request.params.sessionId??'transcript-history291',sessionAgentId:request.params.agentId,
      canonicalKey:request.params.sessionKey,storePath:'supplied:history291',max:request.params.limit??__input.max,
      maxHistoryBytes:1048576,responseHistoryBytes:1048576,effectiveMaxChars:4000,
      ...(request.params.offset===undefined?{}:{offset:request.params.offset}),
      ...(request.params.messageId===undefined?{}:{messageId:request.params.messageId})};
    kernelPage=await __kernel.readChatHistoryPageKernel(params,{readers,readOnly:true});
    preparedPage=__response.prepareChatHistoryResponsePage(kernelPage,params);
    // This explicit gateway adapter maps actual kernel response fields. It is
    // supplied service plumbing, not execution of the original gateway router.
    gatewayResult={messages:preparedPage.messages,
      ...(kernelPage.responseOffset===undefined?{}:{offset:kernelPage.responseOffset}),
      ...(preparedPage.nextOffset===undefined?{}:{nextOffset:preparedPage.nextOffset}),
      ...(preparedPage.hasMore===undefined?{}:{hasMore:preparedPage.hasMore}),
      ...(preparedPage.totalMessages===undefined?{}:{totalMessages:preparedPage.totalMessages}),
      pendingInputs:__input.pendingInputs??{items:[],total:0}};
    return gatewayResult;
  };
  const tool=__factory.createSessionsHistoryTool({agentSessionKey:'agent:main:requester291',config:{},callGateway,
    ...(__input.sessionLinkBase?{sessionLinkBase:__input.sessionLinkBase}:{})});
  const definition={name:tool.name,label:tool.label,displaySummary:tool.displaySummary,description:tool.description,
    parameters:tool.parameters,outputSchema:tool.outputSchema,executePresent:typeof tool.execute==='function'};
  const result=await tool.execute('history291/'+__input.id,__input.args);
  if(readIndex!== (__input.reads??[]).length)throw Error('Unused supplied reader page');
  return {definition,result,readerCalls,gatewayCalls,gatewayResult,
    ...(kernelPage?{kernelPage,preparedPage}:{}),argumentsAfter:__input.args};
})()`;

export async function captureSessionHistoryWindow(sourceRoot = fixedRoot, inputs = sessionHistoryWindowVectors()) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(sourceRoot);
  assert.equal(root, fixedRoot);
  const before = verifyCheckout(root);
  const harness = new HistoryHarness(root, before.files);
  harness.record('src/gateway/server-methods/chat-history-handler.ts', false);
  harness.context.__kernel = await harness.load(kernel);
  harness.context.__response = await harness.load(response);
  harness.context.__strip = await harness.load(strip);
  harness.context.__factory = await harness.load(factory);
  const observations = [];
  for (const input of inputs) {
    harness.context.__serialized = JSON.stringify(input);
    harness.run('globalThis.__input=JSON.parse(__serialized);globalThis.__serviceCalls=[];');
    const observation = plain(await harness.run(observeCode));
    assert.deepEqual(observation.argumentsAfter, input.args, input.id);
    observations.push({ ...input, ...observation, serviceCalls: plain(harness.context.__serviceCalls) });
  }
  assert.deepEqual(plain(harness.context.__deferredCalls), []);
  const after = verifyCheckout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return {
    schemaVersion: 1, referencePin: SESSION_HISTORY_WINDOW_PIN,
    exporter: { path: 'scripts/openclaw/capture-session-history-window.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    sourceRecords: [...harness.sourceRecords.values()].sort((a, b) => a.path.localeCompare(b.path, 'en')),
    importBindings: [...harness.importBindings.values()],
    typebox: { root: harness.typeboxRoot, version: '1.3.37', files: [...harness.dependencies.values()].filter(row => row.path.startsWith('typebox/')).sort((a, b) => a.path.localeCompare(b.path, 'en')) },
    npm: { packages: harness.npmPackages, artifactReceipt: harness.npmReceipt,
      loadedNamespaceEntries: [...harness.dependencies.values()].filter(row => !row.path.startsWith('typebox/')).sort((a, b) => a.path.localeCompare(b.path, 'en')),
      observationLimit: 'All inventoried artifact files are hash-verified; actual official namespace entry loading does not claim that every dependency file executed.' },
    ipaddr: { ...harness.ipaddr, artifactRoot, entryPath: 'vendor/ipaddr/ipaddr.cjs',
      namespaceLoaded: harness.packageModules.has(harness.ipaddrEntry),
      observationLimit: 'Exact original CommonJS/manifest/license bytes and lock integrity verified; namespace loading does not claim every exported network primitive executes.' },
    historyRegionPlan: harness.planReceipt,
    suppliedHostServices: { code: facadeCode, sha256: hash(facadeCode),
      boundary: 'Explicit accepted one-target config, reference, visibility, access, scoped-execution and personal-caller facades; actual source algorithms for these owners do not execute.' },
    suppliedReaderCode: { code: observeCode, sha256: hash(observeCode),
      boundary: 'Literal mapped reader pages and successful gateway action pages. No original reader, raw transcript file bytes, append/tree semantics or persistence ownership is qualified.' },
    observations, deferredCalls: plain(harness.context.__deferredCalls),
    boundaries: { actualFactory: true, actualTypeBox: true, actualProtocolSchemas: true,
      actualCommonParameterHelpers: true, actualJsonResult: true, actualKernel: true, actualPrepareResponse: true,
      actualStripToolMessages: true, actualDisplayProjection: true, actualHistorySanitizer: true,
      originalReaderExecuted: false, originalGatewayRouterExecuted: false, originalPersonalCallerWrapperExecuted: false,
      assemblyExecuted: false, eligibilityExecuted: false, authorityExecuted: false, persistenceExecuted: false,
      liveReaderExecuted: false, networkExecuted: false, productionModulesExecuted: false },
    limits: [
      'The whole original tool factory and real TypeBox protocol schemas/common/jsonResult execute. Host-service import facades are explicitly qualified and traced.',
      'Original history algorithms execute from exact pinned declaration bytes, using their original projector. No product-generated algorithm modules are loaded.',
      'The region plan and actual npm artifacts are reused as source/package provenance inputs only; all source bytes and region hashes are verified against the fixed checkout.',
      'Window reader replies are supplied ordinary mapped messages. Kernel tail limiting, projection, offset context handling, anchored projection and response preparation execute; original file/window reader selection does not.',
      'The factory-only tools cohort consumes explicitly supplied successful gateway pages. IncludeTools and original output sanitization execute; this cohort does not claim kernel tool projection.',
      'Pending custody/IDs/times are supplied fixture facts. Original factory pending projection executes; real queue admission/custody owners do not.',
      'Short successful ordinary text/tool/pending vectors only. No security, permission, auth/TLS, negative, error, failure, cancel, crash, mixed, budget, truncation, eviction or real-provider scenarios.',
    ],
  };
}

// Arbitrary supplied ordinary mapped DTO pages use precisely the same original
// factory/kernel closure. Host identity/custody adaptation belongs in its caller.
// Arrays amortize the complete checkout audit over several independent cases.
export async function computeSessionHistoryWindow(input, sourceRoot = fixedRoot) {
  const many = Array.isArray(input);
  const inputs = (many ? input : [input]).map((row, index) => ({ id: 'supplied-ordinary-' + index, ...row }));
  const captured = await captureSessionHistoryWindow(sourceRoot, inputs);
  const { observations, ...provenance } = captured;
  return many ? { observations, provenance } : { ...observations[0], provenance };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--compute-stdin') {
    assert.equal(process.argv.length, 3, 'usage: capture-session-history-window.mjs --compute-stdin');
    const input = JSON.parse(readFileSync(0, 'utf8'));
    process.stdout.write(JSON.stringify(await computeSessionHistoryWindow(input)) + '\n');
  } else {
    assert.equal(process.argv.length, 4, 'usage: capture-session-history-window.mjs source-root output');
    const captured = await captureSessionHistoryWindow(process.argv[2]);
    writeFileSync(process.argv[3], JSON.stringify(captured, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ vectors: captured.observations.length,
      sourceFiles: captured.sourceRecords.length, typeboxFiles: captured.typebox.files.length,
      npmNamespaceEntries: captured.npm.loadedNamespaceEntries.length }) + '\n');
  }
}
