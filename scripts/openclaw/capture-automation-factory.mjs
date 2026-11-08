// Whole pinned model-facing Automations factory; Gateway callbacks are trace-only.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const AUTOMATION_FACTORY_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const runtimeRoot = '/tmp/synapsis-openclaw-capture-runtime';
const fixedNode = runtimeRoot + '/node_modules/node/bin/node';
const entry = 'src/agents/tools/cron-tool.ts';
const writeSource = 'src/agents/tools/cron-tool-write.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);

// Pure whole-module closure. Imports outside these paths need an explicit binding below.
const wholeSources = new Set([
  'agents/tools/cron-tool', 'agents/tools/cron-tool-write', 'agents/tools/cron-tool-creator-cap',
  'agents/tools/common', 'agents/tools/tool-results', 'agents/tools/cron-tool-canonicalize',
  'agents/tools/cron-tool-schema', 'agents/tools/cron-tool-output-schema',
  'agents/tools/cron-tool-description', 'agents/tools/cron-tool-presentation',
  'agents/tools/cron-tool-automation', 'agents/tools/cron-tool-context', 'agents/tools/cron-tool-self-list',
  'agents/tools/gateway', 'agents/tools/sessions-resolution', 'agents/schema/typebox',
  'agents/schema/cached-schema', 'agents/schema/string-enum', 'agents/schema/tool-output-schema',
  'agents/tools/automations-tool-name', 'agents/tools/gateway-schema', 'agents/tool-description-presets',
  'agents/tool-terminal-presentation', 'agents/tool-effect-receipt', 'agents/runtime/internal-hooks',
  'agents/tool-input-error', 'agents/agent-scope', 'routing/session-key', 'routing/account-id',
  'sessions/session-key-utils', 'shared/incognito-session-key', 'gateway/cron-creator-authority-grant',
  'agents/cron-creator-authority-context', 'infra/exec-approvals-core', 'infra/prototype-keys',
  'infra/map-size', 'infra/format-time/parse-offsetless-zoned-datetime', 'param-key', 'cli/parse-duration',
  'infra/format-time/duration-units', 'infra/outbound/channel-target', 'shared/immutable-data',
  'shared/iso-time', 'shared/chat-content', 'utils/string-readers', 'utils/utf8-truncate',
  'config/sessions/session-store-owner',
  'agents/requester-origin', 'channels/chat-type',
].map(path => 'src/' + path + '.ts'));
const deferredSources = new Set([
  'agents/agent-scope-config', 'agents/agent-tools.policy', 'agents/exec-defaults',
  'agents/exec-tool-target-pinning', 'agents/harness/host-private-capabilities',
  'agents/sandbox/config', 'agents/sandbox/runtime-status', 'agents/sandbox/stream-context',
  'agents/session-permission-exec-mode', 'agents/tool-policy-match', 'agents/tool-policy',
  'agents/tool-replay-safety', 'agents/tools/gateway-caller-availability',
  'agents/tools/gateway-session-spawn-context', 'agents/tools/gateway-session-spawn-execution-identity',
  'agents/tools/gateway-transport-errors', 'agents/tools/in-process-gateway',
  'agents/workspace-state-identity', 'config/model-input', 'config/sessions/auth-profile-override-provenance',
  'config/sessions/model-override-provenance', 'config/sessions/session-store-config',
  'cron/config-revision', 'cron/delivery-context', 'gateway/agent-runtime-execution-lineage', 'gateway/agent-runtime-identity-token',
  'gateway/call', 'gateway/credentials', 'gateway/message-action-turn-capability', 'gateway/method-scopes',
  'gateway/operator-approval-runtime-token', 'infra/agent-run-registry.automation', 'infra/agent-run-registry',
  'infra/device-identity-async', 'infra/exec-approvals-allow-always', 'infra/exec-approvals-policy',
  'infra/exec-approvals-store', 'infra/exec-policy', 'infra/fs-safe', 'infra/path-guards',
  'plugin-sdk/session-visibility-internal', 'sessions/session-id', 'skills/discovery/agent-filter',
  'utils/message-channel-core',
].map(path => 'src/' + path + '.ts'));
const aliases = {
  'src/utils.ts': { source: 'packages/normalization-core/src/record-coerce.ts', exports: ['isRecord'] },
  'src/agents/tools/sessions-helpers.ts': { source: 'src/agents/tools/sessions-resolution.ts',
    exports: ['resolveInternalSessionKey', 'resolveMainSessionAlias'] },
};

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), AUTOMATION_FACTORY_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', AUTOMATION_FACTORY_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(inside(root, realpathSync(file)));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    return { path, gitBlob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row])),
    receipt: { verified: true, commit: AUTOMATION_FACTORY_PIN,
      tree: git(root, ['rev-parse', `${AUTOMATION_FACTORY_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// These facades provide fixture context and return supplied callback replies only.
// They do not implement, validate or execute the Gateway or job service.
const facadeCode = {
  'src/config/config.ts': `
export function getRuntimeConfig(){__fixture.contextCalls.push({callback:'getRuntimeConfig'});return __runtimeConfig;}
export function resolveGatewayPort(){return __defer('resolveGatewayPort');}`,
  'src/config/runtime-snapshot.ts': `
export function getRuntimeConfigSnapshot(){__fixture.contextCalls.push({callback:'getRuntimeConfigSnapshot'});return __runtimeConfig;}
export function createRuntimeConfigReader(){return __defer('createRuntimeConfigReader');}`,
  'src/agents/tools/gateway-caller-context.ts': `
export function getGatewayToolCallerIdentity(){return globalThis.__callerIdentity;}
export async function withGatewayToolCallerIdentity(identity,run){
 const previous=globalThis.__callerIdentity;globalThis.__callerIdentity=identity;
 __fixture.contextCalls.push({callback:'withGatewayToolCallerIdentity',input:__plain(identity??null)});
 try{return await run();}finally{globalThis.__callerIdentity=previous;}
}`,
  'src/agents/tools/cron-tool-gateway.ts': `
export function createCronToolGatewayCaller(input){
 __fixture.contextCalls.push({callback:'createCronToolGatewayCaller',input:{operationSignalSupplied:!!input.operationSignal,
 managementContextSupplied:!!input.managementAuthority,requesterContextSupplied:!!input.requesterAuthority,
 onEffectsStartSupplied:typeof input.onEffectsStart==='function'}});
 return async function(method,options,params,extra){
  const f=__fixture;const index=f.gatewayCalls.length;
  f.gatewayCalls.push(__plain({method,options,params,...(extra?{extra}:{}),callerContext:globalThis.__callerIdentity??null}));
  if(method==='cron.add'||method==='cron.update')input.onEffectsStart?.();
  const reply=f.replies[index];if(!reply)throw Error('missing ordinary gateway fixture reply');
  return __plain(reply);
 };
}`,
};
const hostCode = `
globalThis.__plain=value=>JSON.parse(JSON.stringify(value));
globalThis.__deferredCalls=[];
globalThis.__defer=name=>{__deferredCalls.push(name);throw Error('uninvoked capture binding: '+name);};
globalThis.__runtimeConfig={};
globalThis.__fixture={contextCalls:[],gatewayCalls:[],replies:[]};
globalThis.__callerIdentity=undefined;
`;

// Import declarations come from unchanged transformed modules. This only names
// throwing bindings for explicitly deferred modules; it never selects source bodies.
function requestedExports(code, specifier) {
  const found = new Set();
  const pattern = /(?:import|export)\s*\{([^}]+)\}\s*from\s*["']([^"']+)["']/g;
  for (const match of code.matchAll(pattern)) if (match[2] === specifier) {
    for (const name of match[1].split(',')) found.add(name.trim().split(/\s+as\s+/)[0]);
  }
  assert.ok(found.size > 0, `named deferred import required: ${specifier}`);
  return [...found].sort();
}

class AutomationHarness {
  constructor(root, tracked) {
    this.root = root;
    this.tracked = tracked;
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, AbortController, structuredClone },
      { codeGeneration: { strings: false, wasm: false } });
    new vm.Script(hostCode).runInContext(this.context, { timeout: 1000 });
    this.modules = new Map();
    this.records = new Map();
    this.bindings = new Map();
    this.packages = new Map();
    this.code = new Map();
  }
  sourceRecord(path, executed = false) {
    const bytes = readFileSync(join(this.root, path));
    const pinned = this.tracked.get(path);
    assert.ok(pinned, path);
    assert.equal(hash(bytes), pinned.sha256, path);
    if (!this.records.has(path)) this.records.set(path, { ...pinned, executed: false });
    if (executed) {
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      this.records.set(path, { ...pinned, executed: true, wholeModule: true, transformation,
        executableSha256: hash(executable) });
      return executable;
    }
    return bytes.toString();
  }
  synthetic(key, generatedCode, evidence) {
    if (!this.modules.has(key)) {
      this.bindings.set(key, { ...evidence, generatedCode, generatedSha256: hash(generatedCode) });
      this.modules.set(key, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: key }));
    }
    return this.modules.get(key);
  }
  source(path) {
    if (this.modules.has(path)) return this.modules.get(path);
    assert.ok(wholeSources.has(path) || /^(packages\/(normalization-core|session-url-contract|gateway-protocol)\/src\/|src\/cron\/)/.test(path)
      || path === 'packages/net-policy/src/url-protocol.ts'
      || path === 'packages/agent-core/src/internal-hooks.ts', `undeclared whole module: ${path}`);
    assert.ok(!deferredSources.has(path), `deferred module execution: ${path}`);
    const executable = this.sourceRecord(path, true);
    this.code.set(path, executable);
    const module = new vm.SourceTextModule(executable, { context: this.context, identifier: path,
      importModuleDynamically: specifier => {
        this.context.__deferredCalls.push({ importer: path, specifier, kind: 'dynamic-import' });
        throw Error('dynamic import outside ordinary capture');
      } });
    this.modules.set(path, module);
    return module;
  }
  packageFile(name, file) {
    const pkg = this.packages.get(name);
    const actual = realpathSync(file);
    assert.ok(inside(pkg.root, actual));
    const path = posix.relative(pkg.root, actual);
    const bytes = readFileSync(actual);
    pkg.files.set(path, { path, sha256: hash(bytes) });
    const key = `package:${name}/${path}`;
    if (!this.modules.has(key)) this.modules.set(key,
      new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: key }));
    return this.modules.get(key);
  }
  dependency(name, specifier) {
    const root = realpathSync(runtimeRoot + '/node_modules/' + name);
    const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
    const subpath = specifier === name ? '.' : '.' + specifier.slice(name.length);
    const target = manifest.exports[subpath];
    const importTarget = typeof target === 'string' ? target : target.import ?? target.default;
    assert.equal(typeof importTarget, 'string', `${specifier} ESM package export`);
    const file = realpathSync(join(root, importTarget));
    if (!this.packages.has(name)) {
      const bytes = readFileSync(join(root, 'package.json'));
      const expectedVersion = name === 'zod' ? '4.6.7' : '1.3.37';
      assert.equal(manifest.name, name);
      assert.equal(manifest.version, expectedVersion);
      const referencePackage = JSON.parse(this.sourceRecord('package.json'));
      assert.equal(referencePackage.dependencies[name], expectedVersion);
      const lock = this.sourceRecord('pnpm-lock.yaml');
      const match = lock.match(new RegExp(`^  ${name}@${expectedVersion.replaceAll('.', '\\.')}:[\\s\\S]*?resolution: \\{integrity: ([^}]+)\\}`, 'm'));
      assert.ok(match, `pinned ${name} integrity`);
      this.packages.set(name, { name, version: expectedVersion, root, lockIntegrity: match[1],
        referenceManifest: 'package.json', referenceLock: 'pnpm-lock.yaml',
        entryResolution: 'actual package exports import condition',
        files: new Map(['package.json', name === 'zod' ? 'LICENSE' : 'license'].map(path =>
          [path, { path, sha256: hash(readFileSync(join(root, path))) }])) });
    }
    return this.packageFile(name, file);
  }
  async import(specifier, owner) {
    const importer = owner.identifier;
    if (importer.startsWith('package:')) {
      const name = importer.slice('package:'.length).split('/')[0];
      const path = importer.slice(`package:${name}/`.length);
      assert.ok(specifier.startsWith('.'), `package relative import required: ${specifier}`);
      return this.packageFile(name, resolve(this.packages.get(name).root, dirname(path), specifier));
    }
    if (specifier.startsWith('capture:source:')) return this.source(specifier.slice('capture:source:'.length));
    if (specifier.startsWith('node:')) {
      const allowed = ['node:crypto', 'node:util', 'node:util/types', 'node:async_hooks', 'node:buffer'];
      assert.ok(allowed.includes(specifier), `undeclared platform import: ${specifier}`);
      const key = 'platform:' + specifier;
      if (!this.modules.has(key)) {
        const namespace = await import(specifier);
        const names = Object.keys(namespace);
        this.bindings.set(key, { kind: 'actual-platform-builtin', specifier, exports: names });
        this.modules.set(key, new vm.SyntheticModule(names, function () {
          for (const name of names) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: key }));
      }
      return this.modules.get(key);
    }
    if (specifier === 'zod') return this.dependency('zod', specifier);
    if (specifier === 'typebox' || specifier.startsWith('typebox/')) return this.dependency('typebox', specifier);
    if (specifier === '@openclaw/media-core/mime') return this.deferred(importer, specifier,
      'packages/media-core/src/mime.ts', ['detectMime']);
    if (specifier.startsWith('@openclaw/normalization-core')) return this.source(
      'packages/normalization-core/src/' + (specifier.split('/')[2] ?? 'index') + '.ts');
    if (specifier.startsWith('@openclaw/session-url-contract')) return this.source(
      'packages/session-url-contract/src/' + (specifier.split('/')[2] ?? 'index') + '.ts');
    if (specifier === '@openclaw/net-policy/url-protocol') return this.source('packages/net-policy/src/url-protocol.ts');
    assert.ok(specifier.startsWith('.'), `undeclared import: ${importer} -> ${specifier}`);
    const target = posix.normalize(posix.join(posix.dirname(importer), specifier)).replace(/\.js$/, '.ts');
    if (target === writeSource && importer === entry) {
      this.sourceRecord(target);
      const exports = requestedExports(this.code.get(importer), specifier);
      const retained = exports.filter(name => name !== 'captureCronStreamPolicyConfigCurrentness');
      return this.synthetic('capture:write-import-edge',
        `export {${retained.join(',')}} from ${JSON.stringify('capture:source:' + target)};
export function captureCronStreamPolicyConfigCurrentness(options){
 __fixture.contextCalls.push({callback:'captureCronStreamPolicyConfigCurrentness',input:{optionsSupplied:!!options}});
 return ()=>{__fixture.policyAssertionCalls++;return __defer('uninvoked-construction-policy-assertion');};
}`,
        { importer, specifier, source: target, sourceSha256: this.tracked.get(target).sha256,
          kind: 'explicit-construction-only-callback-facade', overriddenExports: ['captureCronStreamPolicyConfigCurrentness'],
          retainedWholeSourceExports: retained, originalOverriddenFunctionExecuted: false });
    }
    if (Object.hasOwn(facadeCode, target)) {
      this.sourceRecord(target);
      return this.synthetic('capture:facade:' + target, facadeCode[target], {
        source: target, sourceSha256: this.tracked.get(target).sha256,
        kind: target === 'src/agents/tools/cron-tool-gateway.ts' ? 'explicit-trace-only-gateway-callback-facade' : 'explicit-fixture-context-callback-facade',
        originalSourceExecuted: false });
    }
    if (Object.hasOwn(aliases, target)) {
      const alias = aliases[target];
      this.sourceRecord(target);
      return this.synthetic('capture:alias:' + target,
        `export {${alias.exports.join(',')}} from ${JSON.stringify('capture:source:' + alias.source)};`,
        { kind: 'whole-source-export-alias', source: alias.source, sourceSha256: this.tracked.get(alias.source).sha256,
          replacedImportSource: target, exports: alias.exports });
    }
    if (target === 'src/gateway/client.ts') return this.deferred(importer, specifier, target, ['GatewayClientRequestError'], true);
    if (deferredSources.has(target)) return this.deferred(importer, specifier, target);
    return this.source(target);
  }
  deferred(importer, specifier, target, names, classBinding = false) {
    this.sourceRecord(target);
    names ??= requestedExports(this.code.get(importer), specifier);
    const code = names.map(name => classBinding
      ? `export class ${name} extends Error{constructor(){super();__defer(${JSON.stringify(target + ':' + name)});}}`
      : `export function ${name}(){return __defer(${JSON.stringify(target + ':' + name)});}`).join('\n');
    return this.synthetic(`capture:deferred:${importer}:${specifier}`, code, {
      importer, specifier, source: target, sourceSha256: this.tracked.get(target).sha256,
      exports: names, kind: 'uninvoked-throwing-binding', originalSourceExecuted: false });
  }
  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
  async load(path) {
    const module = this.source(path);
    if (module.status === 'unlinked') await module.link((specifier, owner) => this.import(specifier, owner));
    if (module.status === 'linked') await module.evaluate({ timeout: 1000 });
    assert.equal(module.status, 'evaluated');
    return module.namespace;
  }
}

function vectors() {
  const prompt = '  Summarize 雪😀\nKeep spacing.  \n';
  const job = { name: 'Fixture automation', delivery: { mode: 'none' }, schedule: { kind: 'every', everyMs: 1500 },
    payload: { kind: 'agentTurn', message: prompt } };
  const make = (id, action, args = {}, extra = {}) => ({ id, arguments: { action, ...args },
    expectedMethod: action === 'wake' ? 'wake' : 'cron.' + action, expectedGatewayCalls: 1, ...extra });
  return [
    make('status', 'status'),
    make('list-default', 'list'),
    make('list-page', 'list', { includeDisabled: true, limit: 5, offset: 2, agentId: 'fixture-agent' }),
    make('get-id-alias', 'get', { id: 'fixture-job' }),
    make('add-at-defaults', 'add', { job: { ...job, schedule: { kind: 'at', at: '2026-10-28T10:00:00Z' } } }),
    make('add-every', 'add', { job: { ...job, schedule: { kind: 'every', everyMs: 1500, anchorMs: 1793181600000 } } }),
    make('add-cron', 'add', { job: { ...job, schedule: { kind: 'cron', expr: '17 * * * *', tz: 'Asia/Shanghai' } } }),
    make('add-without-session-context', 'add', { job: { name: job.name, schedule: job.schedule, payload: job.payload } },
      { factoryOptions: { agentId: 'fixture-agent' } }),
    make('update-name-only', 'update', { jobId: 'fixture-job', job: { name: 'Renamed automation' } }),
    make('update-every', 'update', { jobId: 'fixture-job', job: { schedule: { kind: 'every', everyMs: 3000 } } }),
    make('update-prompt', 'update', { jobId: 'fixture-job', job: { payload: { kind: 'agentTurn', message: prompt } } }),
    make('remove', 'remove', { jobId: 'fixture-job' }, { expectedGatewayCalls: 2 }),
    make('run-default-due', 'run', { jobId: 'fixture-job' }),
    make('run-explicit-force', 'run', { jobId: 'fixture-job', runMode: 'force', timeoutMs: 2500 }),
    make('run-wait-cap', 'run', { jobId: 'fixture-job', timeoutMs: 700000 }),
    make('run-enqueued', 'run', { jobId: 'fixture-job' }),
    make('runs-specific', 'runs', { jobId: 'fixture-job', runId: 'fixture-run' }),
    make('wake-default', 'wake', { text: 'Wake 雪😀' }),
    make('wake-explicit-session', 'wake', { text: 'Follow up', mode: 'now', sessionKey: 'agent:fixture-agent:follow-up' }),
  ];
}

function replies(row) {
  const fixtureJob = { id: 'fixture-job', configRevision: 'fixture-revision', name: 'Supplied Gateway fixture job',
    enabled: true, createdAtMs: 1793181600000, updatedAtMs: 1793181600000,
    schedule: { kind: 'every', everyMs: 1500 }, sessionTarget: 'current', wakeMode: 'now',
    payload: { kind: 'agentTurn', message: 'Supplied Gateway fixture prompt' }, state: {} };
  const page = { total: 0, offset: 0, limit: 5, hasMore: false, nextOffset: null };
  const responses = {
    status: { enabled: true, jobs: 2, nextWakeAtMs: 1793181600000 },
    list: { jobs: [], ...page }, get: fixtureJob,
    add: { ...fixtureJob, id: 'fixture-added' }, update: fixtureJob,
    remove: { ok: true, removed: true }, run: { ok: true, ran: true },
    runs: { entries: [], ...page }, wake: { ok: true },
  };
  if (row.id === 'remove') return [responses.get, responses.remove];
  if (row.id === 'run-enqueued') return [{ ok: true, enqueued: true, runId: 'fixture-run' }];
  return [responses[row.arguments.action]];
}

export async function captureAutomationFactory(source = process.env.OPENCLAW_AUTOMATION_FACTORY_SOURCE ?? fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  const before = checkout(root);
  const harness = new AutomationHarness(root, before.tracked);
  harness.context.__factory = await harness.load(entry);
  const valueModule = harness.dependency('typebox', 'typebox/value');
  if (valueModule.status === 'unlinked') await valueModule.link((specifier, owner) => harness.import(specifier, owner));
  if (valueModule.status === 'linked') await valueModule.evaluate({ timeout: 1000 });
  harness.context.__value = valueModule.namespace;
  const observations = [];
  let schemas;
  for (const row of vectors()) {
    harness.context.__vector = plain({ ...row, replies: replies(row) });
    harness.run(`{
 const v=__plain(__vector);globalThis.__fixture={contextCalls:[],gatewayCalls:[],replies:v.replies,policyAssertionCalls:0};
 globalThis.__arguments=__plain(v.arguments);
 globalThis.__factoryOptions=v.factoryOptions??{agentSessionKey:'agent:fixture-agent:main',agentId:'fixture-agent'};
 globalThis.__tool=__factory.createCronTool(__factoryOptions);
 globalThis.__validInput=__value.Value.Check(__tool.parameters,__arguments);
}`);
    schemas ??= harness.run('__plain({input:__tool.parameters,output:__tool.outputSchema})');
    const result = await harness.run('__tool.execute("fixture-call",__arguments)');
    harness.context.__resultDetails = result.details;
    const validOutput = harness.run(`{
 const mapping=__tool.outputSchema['x-openclaw-input-discriminator'].mapping;
 __value.Value.Check(__tool.outputSchema.anyOf[mapping[__arguments.action]],__resultDetails);
}`);
    observations.push(plain({ ...row, result,
      factoryOptions: harness.run('__plain(__factoryOptions)'),
      tool: harness.run('({name:__tool.name,label:__tool.label,displaySummary:__tool.displaySummary,executeType:typeof __tool.execute})'),
      argumentsAfter: harness.run('__plain(__arguments)'), validInput: harness.context.__validInput, validOutput,
      policyConstructionCalls: harness.context.__fixture.contextCalls.filter(row => row.callback === 'captureCronStreamPolicyConfigCurrentness').length,
      policyAssertionCalls: harness.context.__fixture.policyAssertionCalls,
      gatewayCalls: harness.context.__fixture.gatewayCalls, contextCalls: harness.context.__fixture.contextCalls,
      suppliedReplies: harness.context.__fixture.replies, deferredCalls: harness.context.__deferredCalls }));
  }
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  assert.deepEqual(plain(harness.context.__deferredCalls), []);
  return plain({ schemaVersion: 1, referencePin: AUTOMATION_FACTORY_PIN,
    exporter: { path: 'scripts/openclaw/capture-automation-factory.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    entry: { path: entry, export: 'createCronTool', sha256: before.tracked.get(entry).sha256 },
    host: { generatedCode: hostCode, sha256: hash(hostCode) }, schemas, observations,
    sourceRecords: [...harness.records.values()].sort((a, b) => a.path.localeCompare(b.path)),
    importBindings: [...harness.bindings.values()].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    packages: [...harness.packages.values()].map(pkg => ({ ...pkg, files: [...pkg.files.values()].sort((a, b) => a.path.localeCompare(b.path)) }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    deferredCalls: harness.context.__deferredCalls,
    boundaries: { factoryInvoked: true, executeInvoked: true, factorySourceUnchanged: true,
      normalizationSourceExecuted: true, creatorHelpersSourceExecuted: true, writeHelpersSourceExecuted: true,
      schemaConstructionExecuted: true, standardResultHelpersExecuted: true,
      gatewayCallbacks: 'trace-only supplied fixture replies; no service effects',
      contextCallbacks: 'fixture config and trusted caller context only',
      policyConstructionExecuted: false, policyConstructionImportEdgeOverride: 'captureCronStreamPolicyConfigCurrentness',
      policyAssertionCalls: observations.reduce((count, row) => count + row.policyAssertionCalls, 0),
      gatewayServiceExecuted: false, jobServiceExecuted: false, storageExecuted: false, timersExecuted: false,
      lifecycleExecuted: false, executorExecuted: false, runtimeAssemblyExecuted: false, fullFactoryParity: false,
      unexecutedBranches: ['systemEvent reminder context', 'delivery inference', 'stream schedules', 'script payloads',
        'condition triggers', 'automation invocation actions', 'recovery and self-only modes',
        'management and requester grant paths', 'creator tool-policy materialization', 'legacy Gateway retry branches',
        'stream policy capture and assertion', 'actual Gateway dispatch and response production'] },
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source, output] = process.argv.slice(2);
  assert.ok(source && output && process.argv.length === 4,
    'usage: capture-automation-factory.mjs PINNED_SOURCE OUTPUT_JSON');
  const report = await captureAutomationFactory(source);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: resolve(output), observations: report.observations.length,
    gatewayCallbacks: report.observations.reduce((count, row) => count + row.gatewayCalls.length, 0),
    wholeSourceModules: report.sourceRecords.filter(row => row.executed).length }) + '\n');
}
