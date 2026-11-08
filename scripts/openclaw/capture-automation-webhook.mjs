// Ordinary primary-webhook lifecycle through unchanged pinned whole modules.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const AUTOMATION_WEBHOOK_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const runtimeRoot = '/tmp/synapsis-openclaw-capture-runtime';
const dependencyRoot = process.env.OPENCLAW_AUTOMATION_WEBHOOK_DEPENDENCIES ?? '/tmp/synapsis-openclaw-automation-webhook-deps';
const fixedNode = runtimeRoot + '/node_modules/node/bin/node';
const entry = 'src/cron/service/timer-job-runner.ts';
const transport = 'src/gateway/server-cron-notifications.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);

const wholeSources = new Set([
  'cron/service/timer-job-runner', 'cron/service/timer-job-runner.interruption',
  'cron/service/timer-execution', 'cron/service/active-run-cancellation',
  'cron/service/agent-watchdog', 'cron/service/timeout-policy', 'cron/service/admission-deferred',
  'cron/service/occurrence-admission', 'cron/service/state', 'cron/service/timer-session-route',
  'cron/service/timer-trigger', 'cron/service/execution-errors',
  'cron/active-jobs', 'cron/agent-id', 'cron/active-hours', 'cron/completion-status',
  'cron/delivery-plan', 'cron/delivery-defaults', 'cron/store/delivery-codec', 'cron/public-job',
  'cron/plugin-command-schedule', 'cron/plugin-command-schedule.types', 'cron/run-authority',
  'cron/scheduled-occurrence', 'cron/scheduled-tool-policy', 'cron/own-record',
  'cron/command-output-summary', 'cron/webhook-url', 'cron/execution-error-constants',
  'cron/isolated-agent/delivery-dispatch-policy',
  'gateway/server-cron-notifications', 'routing/session-key', 'routing/account-id',
  'sessions/session-key-utils', 'shared/incognito-session-key', 'agents/date-time',
  'shared/async-work-scope', 'shared/deferred', 'shared/global-singleton',
  'shared/detached-async-context', 'shared/lazy-promise', 'shared/effect-authority',
  'infra/errors', 'infra/retry', 'infra/retry-attempt-errors', 'infra/secure-random', 'infra/prototype-keys',
  'infra/test-runtime-env', 'infra/fetch-headers', 'infra/http-response-body',
  'infra/net/fetch-guard', 'infra/net/fetch-request-authority', 'infra/net/runtime-fetch',
  'infra/net/ssrf', 'infra/net/hostname', 'infra/net/ssrf-trusted-host-linklocal-exemptions',
  'infra/net/configured-local-origin-bypass', 'infra/net/guarded-body-stream',
  'infra/net/pinned-dispatcher-pool', 'infra/net/proxy-env', 'infra/net/redirect-headers',
  'infra/net/form-data', 'utils/fetch-timeout', 'utils/timer-delay', 'utils/string-readers',
  'utils/message-channel-core', 'utils/message-channel-constants',
  'logging/subsystem', 'secrets/runtime-degraded-state', 'secrets/resolve-errors',
  'cli/command-format', 'cli/profile-utils',
].map(path => 'src/' + path + '.ts'));

// These modules are outside the selected ordinary branch. Every callable binding
// throws and is recorded if touched; none supplies a successful control decision.
const deferredSources = new Set([
  'agents/run-termination', 'agents/admitted-run-context', 'agents/timeout',
  'agents/embedded-agent-runner/execution-phase',
  'infra/system-event-ownership', 'infra/format-time/format-datetime', 'infra/errno',
  'logging/secret-redaction-registry',
  'config/sessions/session-source-authority', 'infra/gateway-work-metrics-events',
  'cron/proactive-job-receipt', 'cron/proactive-job-receipt.kernel', 'cron/run-diagnostics',
  'cron/scratch-contract', 'cron/scratch-read', 'cron/script-failure', 'cron/session-target',
  'cron/source-schedule', 'cron/stream-schedule', 'cron/isolated-agent/session-key',
  'cron/service/execution-idle', 'cron/service/timer-execution-script',
  'cron/service/timer-execution-timeout', 'cron/service/delivery-attempt-fence',
  'cron/service/jobs-scheduling', 'cron/retry-hint', 'cron/delivery-target-validation', 'cron/run-id',
  'cron/isolated-agent/delivery-target', 'infra/outbound/channel-target-prefix',
  'channels/ids', 'channels/registry-normalize',
  'gateway/operator-run-recovery-source.codec', 'shared/pid-alive',
  'config/control-ui-link-base', 'config/sessions/paths', 'infra/backoff',
  'infra/delivery-queue-sqlite', 'infra/delivery-recovery.shared',
  'infra/outbound/target-normalization', 'plugin-sdk/channel-route',
  'tts/tts-config', 'tts/tts-preferences',
  'logger', 'infra/fs-safe', 'infra/http-response-body-timeout',
  'infra/net/undici-runtime', 'infra/net/undici-dispatcher-options',
  'infra/net/undici-family-policy', 'infra/net/proxy/active-proxy-state',
  'logging/console', 'logging/levels', 'logging/logger', 'logging/redact', 'logging/state',
  'global-state', 'infra/diagnostic-event-listener-presence', 'infra/diagnostic-events',
  'runtime', 'infra/home-dir',
  'process/gateway-work-admission', 'gateway/agent-turn/agent-job',
  'gateway/server-recovery-runtime-context',
].map(path => 'src/' + path + '.ts'));

// Barrel-only aliases retain the original defining whole module, and make the
// other exports throwing bindings. They do not copy implementation bodies.
const aliases = {
  'src/cron/delivery.ts': { source: 'src/cron/delivery-plan.ts', names: ['resolveCronDeliveryPlan'] },
  'src/infra/env.ts': { source: 'src/infra/test-runtime-env.ts', names: ['isFastTestRuntimeEnv'] },
  'src/infra/http-body.ts': { source: 'src/infra/http-response-body.ts', names: ['cancelUnreadResponseBody'] },
};

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), AUTOMATION_WEBHOOK_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', AUTOMATION_WEBHOOK_PIN]).split('\0').filter(Boolean).map(item => {
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
  return { tracked: new Map(files.map(row => [row.path, row])), receipt: {
    verified: true, commit: AUTOMATION_WEBHOOK_PIN, tree: git(root, ['rev-parse', `${AUTOMATION_WEBHOOK_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}
function packageTree(root) {
  const rows = [];
  const visit = dir => {
    for (const name of readdirSync(dir).sort()) {
      const file = join(dir, name);
      assert.ok(inside(root, realpathSync(file)));
      const stat = lstatSync(file);
      assert.equal(stat.isSymbolicLink(), false, file);
      if (stat.isDirectory()) visit(file);
      else { assert.ok(stat.isFile(), file); rows.push({ path: posix.relative(root, file), sha256: hash(readFileSync(file)) }); }
    }
  };
  visit(root);
  return rows;
}
function requestedExports(code, specifier) {
  const names = new Set();
  for (const match of code.matchAll(/(?:import|export)\s*\{([^}]+)\}\s*from\s*["']([^"']+)["']/g)) {
    if (match[2] === specifier) for (const name of match[1].split(',')) names.add(name.trim().split(/\s+as\s+/)[0]);
  }
  if (/delivery-recovery\.shared\.js$/.test(specifier)) {
    names.add('resolveDeliveryNotSentRetryability'); names.add('isProvenDeliveryNotSentError');
  }
  for (const match of code.matchAll(/import\s+\w+\s+from\s*["']([^"']+)["']/g)) {
    if (match[1] === specifier) names.add('default');
  }
  assert.ok(names.size, `explicit named/default uncalled imports required: ${specifier}`);
  return [...names].sort();
}
const hostCode = `
globalThis.__plain=value=>JSON.parse(JSON.stringify(value));
globalThis.__deferredCalls=[];
globalThis.__defer=name=>{__deferredCalls.push(name);throw Error('uninvoked capture binding: '+name);};
globalThis.__trace=[];
globalThis.__postRequests=[];
globalThis.__warnings=[];
// This is the original runtime-fetch's documented fixture injection contract.
globalThis.fetch=Object.assign(async function(url,init){
 __trace.push('receiver-request');
 __postRequests.push({url,method:init.method,headers:Object.fromEntries(new Headers(init.headers)),body:init.body,
  signalSupplied:!!init.signal,redirect:init.redirect});
 __receiverEntered();
 await __receiverAck;
 __trace.push('receiver-ack-204');
 return new Response(null,{status:204});
},{mock:{}});
`;

class WebhookHarness {
  constructor(root, tracked) {
    this.root = root; this.tracked = tracked;
    this.timers = new Set();
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, URLSearchParams,
      AbortController, AbortSignal, Response, Request, Headers, Blob, FormData, DOMException,
      ReadableStream, TransformStream, structuredClone,
      process: { env: {}, versions: { node: process.versions.node }, platform: process.platform,
        getBuiltinModule: process.getBuiltinModule },
      setTimeout: (callback, delay, ...args) => {
        const timer = setTimeout(() => { this.timers.delete(timer); callback(...args); }, delay);
        this.timers.add(timer); return timer;
      },
      clearTimeout: timer => { clearTimeout(timer); this.timers.delete(timer); },
    }, { codeGeneration: { strings: false, wasm: false } });
    this.run(hostCode);
    this.modules = new Map(); this.records = new Map(); this.code = new Map();
    this.bindings = new Map(); this.packages = new Map();
  }
  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
  record(path, executed = false) {
    const bytes = readFileSync(join(this.root, path));
    const pinned = this.tracked.get(path);
    assert.ok(pinned, path); assert.equal(hash(bytes), pinned.sha256, path);
    if (!this.records.has(path)) this.records.set(path, { ...pinned, executed: false });
    if (!executed) return bytes.toString();
    const code = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.records.set(path, { ...pinned, executed: true, wholeModule: true, transformation, executableSha256: hash(code) });
    return code;
  }
  synthetic(key, code, evidence) {
    if (!this.modules.has(key)) {
      this.bindings.set(key, { ...evidence, generatedCode: code, generatedSha256: hash(code) });
      this.modules.set(key, new vm.SourceTextModule(code, { context: this.context, identifier: key }));
    }
    return this.modules.get(key);
  }
  source(path) {
    if (this.modules.has(path)) return this.modules.get(path);
    assert.ok(wholeSources.has(path) || /^packages\/(normalization-core|session-url-contract|net-policy|retry|gateway-client)\/src\//.test(path),
      `undeclared whole module: ${path}`);
    const code = this.record(path, true); this.code.set(path, code);
    const module = new vm.SourceTextModule(code, { context: this.context, identifier: path,
      importModuleDynamically: specifier => {
        this.context.__deferredCalls.push({ importer: path, specifier, kind: 'dynamic-import' });
        throw Error('dynamic import outside ordinary capture');
      } });
    this.modules.set(path, module); return module;
  }
  deferred(importer, specifier, target, names) {
    if (target.startsWith('src/') || target.startsWith('packages/')) this.record(target);
    names ??= requestedExports(this.code.get(importer), specifier);
    const code = names.map(name => name === 'default'
      ? `export default function(){return __defer(${JSON.stringify(target + ':default')});}`
      : `export function ${name}(){return __defer(${JSON.stringify(target + ':' + name)});}`).join('\n');
    return this.synthetic(`uncalled:${importer}:${specifier}`, code,
      { kind: 'uninvoked-throwing-binding', importer, specifier, source: target,
        ...(this.tracked.has(target) ? { sourceSha256: this.tracked.get(target).sha256 } : {}),
        exports: names, originalSourceExecuted: false });
  }
  dependency(name) {
    if (this.packages.has(name)) return this.packages.get(name);
    const root = realpathSync(join(name === 'ipaddr.js' ? dependencyRoot : runtimeRoot, 'node_modules', name));
    const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
    const version = name === 'ipaddr.js' ? '2.5.0' : '4.6.7';
    assert.equal(manifest.name, name); assert.equal(manifest.version, version);
    const referenceManifest = name === 'ipaddr.js' ? 'packages/net-policy/package.json' : 'package.json';
    assert.equal(JSON.parse(this.record(referenceManifest)).dependencies[name], version);
    const lockLines = this.record('pnpm-lock.yaml').split('\n');
    const packageIndex = lockLines.indexOf(`  ${name}@${version}:`);
    assert.ok(packageIndex >= 0, `pinned ${name} package entry`);
    const match = lockLines[packageIndex + 1].match(/resolution: \{integrity: ([^}]+)\}/);
    assert.ok(match, `pinned ${name} integrity`);
    const before = packageTree(root);
    const pkg = { name, version, root, manifest, referenceManifest, before, lockIntegrity: match[1], loaded: new Set() };
    this.packages.set(name, pkg); return pkg;
  }
  packageFile(name, file) {
    const pkg = this.dependency(name); const actual = realpathSync(file);
    assert.ok(inside(pkg.root, actual));
    const path = posix.relative(pkg.root, actual); pkg.loaded.add(path);
    const key = `package:${name}/${path}`;
    if (!this.modules.has(key)) {
      const bytes = readFileSync(actual);
      assert.equal(hash(bytes), pkg.before.find(row => row.path === path)?.sha256);
      this.modules.set(key, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: key }));
    }
    return this.modules.get(key);
  }
  packageEntry(name) {
    const pkg = this.dependency(name);
    if (name === 'ipaddr.js') {
      const path = pkg.manifest.main;
      const key = 'package:ipaddr.js:commonjs';
      if (!this.modules.has(key)) {
        const file = realpathSync(join(pkg.root, path)); assert.ok(inside(pkg.root, file));
        const relative = posix.relative(pkg.root, file); const code = readFileSync(file, 'utf8');
        assert.equal(hash(code), pkg.before.find(row => row.path === relative)?.sha256); pkg.loaded.add(relative);
        this.context.__cjsModule = { exports: {} };
        // The entire original CommonJS module executes without rewriting its body.
        this.run(`(function(module,exports){\n${code}\n})(__cjsModule,__cjsModule.exports);`);
        const namespace = this.context.__cjsModule.exports;
        this.bindings.set(key, { kind: 'actual-installed-whole-commonjs-module', package: name,
          path: relative, sha256: hash(code), wrapper: '(function(module,exports){ ORIGINAL_FULL_BYTES })(module,module.exports)' });
        this.modules.set(key, new vm.SyntheticModule(['default'], function () { this.setExport('default', namespace); },
          { context: this.context, identifier: key }));
      }
      return this.modules.get(key);
    }
    return this.packageFile(name, join(pkg.root, pkg.manifest.exports['.'].import));
  }
  async import(specifier, owner) {
    const importer = owner.identifier;
    if (importer.startsWith('package:zod/')) {
      assert.ok(specifier.startsWith('.'));
      return this.packageFile('zod', resolve(this.packages.get('zod').root, dirname(importer.slice('package:zod/'.length)), specifier));
    }
    if (specifier.startsWith('capture:source:')) return this.source(specifier.slice('capture:source:'.length));
    if (specifier === 'ipaddr.js' || specifier === 'zod') return this.packageEntry(specifier);
    if (specifier === 'chalk') return this.deferred(importer, specifier, 'external:chalk', ['Chalk']);
    if (specifier.startsWith('node:')) {
      const allowed = ['node:async_hooks', 'node:crypto', 'node:util', 'node:buffer'];
      if (!allowed.includes(specifier)) return this.deferred(importer, specifier, 'platform:' + specifier);
      const key = 'platform:' + specifier;
      if (!this.modules.has(key)) {
        const namespace = await import(specifier); const names = Object.keys(namespace);
        this.bindings.set(key, { kind: 'actual-platform-builtin', specifier, exports: names });
        this.modules.set(key, new vm.SyntheticModule(names, function () {
          for (const name of names) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: key }));
      }
      return this.modules.get(key);
    }
    const workspace = specifier.match(/^@openclaw\/(normalization-core|session-url-contract|net-policy|retry)(?:\/(.+))?$/);
    if (workspace) return this.source(`packages/${workspace[1]}/src/${workspace[2] ?? 'index'}.ts`);
    assert.ok(specifier.startsWith('.'), `undeclared import: ${importer} -> ${specifier}`);
    const target = posix.normalize(posix.join(posix.dirname(importer), specifier)).replace(/\.js$/, '.ts');
    const alias = aliases[target];
    if (alias) {
      this.record(target);
      const names = requestedExports(this.code.get(importer), specifier);
      const retained = names.filter(name => alias.names.includes(name));
      const uncalled = names.filter(name => !alias.names.includes(name));
      const code = (retained.length ? `export {${retained.join(',')}} from ${JSON.stringify('capture:source:' + alias.source)};\n` : '') +
        uncalled.map(name => `export function ${name}(){return __defer(${JSON.stringify(target + ':' + name)});}`).join('\n');
      return this.synthetic(`alias:${importer}:${specifier}`, code, { kind: 'whole-source-export-alias', importer, specifier,
        replacedImportSource: target, source: alias.source, retainedWholeSourceExports: retained, uncalledExports: uncalled,
        sourceSha256: this.tracked.get(alias.source).sha256 });
    }
    if (target === 'packages/terminal-core/src/progress-line.ts') return this.deferred(importer, specifier, target);
    if (deferredSources.has(target)) return this.deferred(importer, specifier, target);
    return this.source(target);
  }
  async load(path) {
    const module = this.source(path);
    if (module.status === 'unlinked') await module.link((specifier, owner) => this.import(specifier, owner));
    if (module.status === 'linked') await module.evaluate({ timeout: 1000 });
    assert.equal(module.status, 'evaluated'); return module.namespace;
  }
  dispose() { for (const timer of this.timers) clearTimeout(timer); this.timers.clear(); }
}

async function bounded(promise, label) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(Error('capture deadline: ' + label)), 5000);
  })]); } finally { clearTimeout(timer); }
}

export async function captureAutomationWebhook(source = process.env.OPENCLAW_AUTOMATION_WEBHOOK_SOURCE ?? fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); const before = checkout(root);
  const harness = new WebhookHarness(root, before.tracked);
  try {
    harness.context.__runner = await harness.load(entry);
    harness.context.__transport = await harness.load(transport);
    harness.context.__work = await harness.load('src/shared/async-work-scope.ts');
    harness.context.__active = await harness.load('src/cron/service/active-run-cancellation.ts');
    const observations = [];
    const vectors = [
      { id: 'unicode-attributed-held-ack', summary: '  Completed 雪😀\nPreserve spacing.  ', attributed: true },
      { id: 'unicode-optional-fields-omitted-held-ack', summary: 'Done 雪😀', attributed: false },
      { id: 'whitespace-summary-suppressed', summary: ' \t\n ', attributed: true },
      { id: 'empty-summary-suppressed', summary: '', attributed: false },
    ];
    for (const vector of vectors) {
      let entered; let acknowledge;
      const receiverEntered = new Promise(resolve => { entered = resolve; });
      harness.context.__receiverEntered = entered;
      harness.context.__receiverAck = new Promise(resolve => { acknowledge = resolve; });
      harness.context.__vector = plain(vector);
      harness.run(`{
 const v=__plain(__vector);__trace=[];__postRequests=[];__warnings=[];
 globalThis.__job={id:'fixture-webhook-job',agentId:'fixture-agent',name:'Primary webhook fixture',enabled:true,
  createdAtMs:1793181600000,updatedAtMs:1793181600000,schedule:{kind:'every',everyMs:60000},
  sessionTarget:'isolated',wakeMode:'now',payload:{kind:'agentTurn',message:'Produce fixture completion',timeoutSeconds:30},
  delivery:{mode:'webhook',to:'https://webhook.example.com/automation'},state:{runningAtMs:1793181600000}};
 globalThis.__suppliedResult={status:'ok',summary:v.summary,...(v.attributed?{
  sessionId:'fixture-session',sessionKey:'agent:fixture-agent:cron:fixture-webhook-job',
  model:'fixture-model',provider:'fixture-provider',usage:{input_tokens:17,output_tokens:9,total_tokens:26}}:{})};
 globalThis.__executorCalls=[];globalThis.__transportOutcomes=[];
 globalThis.__state={deps:{nowMs:()=>1793181600123,storePath:'/fixture/not-accessed/jobs.json',
  log:{warn:(obj,msg)=>__warnings.push(__plain({obj,msg})),debug:()=>__defer('unexpected-debug-log')},
  runIsolatedAgentJob:async input=>{
   __trace.push('executor-completed');
   __executorCalls.push({jobId:input.job.id,message:input.message,abortSignalSupplied:!!input.abortSignal,
    admissionSource:input.admissionSource,occurrenceSupplied:!!input.occurrence});
   input.onExecutionStarted?.(v.attributed?{model:__suppliedResult.model,provider:__suppliedResult.provider}:undefined);
   return __plain(__suppliedResult);
  },
  sendCronWebhook:async input=>{
   __trace.push('webhook-adapter-entered');
   const outcome=await __transport.sendGatewayCronWebhook(input);
   __transportOutcomes.push(__plain(outcome));__trace.push('webhook-adapter-settled');return outcome;
  }}};
 globalThis.__scope=new __work.AsyncWorkScope();globalThis.__settled=false;
 globalThis.__run=__scope.track(()=>__runner.executeJobCoreWithTimeout(__state,__job,{migrationPending:false}));
 __run.then(()=>{__settled=true;__trace.push('run-completion-authored');},()=>{__settled=true;});
}`);
      let pending;
      if (vector.summary.trim()) {
        await bounded(receiverEntered, vector.id + ': receiver entry');
        // A full event-loop turn drains reactions without resolving the held ACK.
        await new Promise(resolve => setImmediate(resolve));
        pending = plain(harness.run(`({receiverPending:true,runSettled:__settled,
 scopeHasPendingWork:__scope.hasPendingWork,activeCoreCount:__active.getSuspensionVisibleCronTaskRunCount(),
 postCount:__postRequests.length,trace:__plain(__trace)})`));
        assert.equal(pending.runSettled, false); assert.equal(pending.scopeHasPendingWork, true);
        assert.equal(pending.activeCoreCount, 1); acknowledge();
      } else acknowledge();
      const result = plain(await bounded(harness.context.__run, vector.id + ': completion'));
      await bounded(harness.context.__scope.drain(), vector.id + ': async work drain');
      await new Promise(resolve => setImmediate(resolve));
      observations.push(plain({ ...vector, suppliedExecutorResult: harness.context.__suppliedResult,
        pending: pending ?? null, result,
        ...harness.run(`({job:__plain(__job),requests:__plain(__postRequests),executorCalls:__plain(__executorCalls),
 transportOutcomes:__plain(__transportOutcomes),trace:__plain(__trace),warnings:__plain(__warnings),
 runSettled:__settled,scopeHasPendingWork:__scope.hasPendingWork,
 activeCoreCount:__active.getSuspensionVisibleCronTaskRunCount()})`),
      }));
      assert.equal(harness.timers.size, 0, 'ordinary completion releases capture-owned timers');
    }
    assert.deepEqual(plain(harness.context.__deferredCalls), []);
    const packages = [...harness.packages.values()].map(pkg => {
      const after = packageTree(pkg.root); assert.deepEqual(after, pkg.before);
      return { name: pkg.name, version: pkg.version, root: pkg.root, lockIntegrity: pkg.lockIntegrity,
        referenceManifest: pkg.referenceManifest, referenceLock: 'pnpm-lock.yaml',
        before: pkg.before, after, loadedFiles: [...pkg.loaded].sort(), originalInstalledTreeUnchanged: true };
    }).sort((a, b) => a.name.localeCompare(b.name));
    const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
    return plain({ schemaVersion: 1, referencePin: AUTOMATION_WEBHOOK_PIN,
      exporter: { path: 'scripts/openclaw/capture-automation-webhook.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
      runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
      sourceTree: { before: before.receipt, after: after.receipt }, transformation,
      entry: { path: entry, export: 'executeJobCoreWithTimeout', sha256: before.tracked.get(entry).sha256 },
      transport: { path: transport, export: 'sendGatewayCronWebhook', sha256: before.tracked.get(transport).sha256 },
      host: { generatedCode: hostCode, sha256: hash(hostCode) }, observations,
      sourceRecords: [...harness.records.values()].sort((a, b) => a.path.localeCompare(b.path)),
      importBindings: [...harness.bindings.values()].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
      packages, deferredCalls: harness.context.__deferredCalls,
      boundaries: { wholeRunnerExecuted: true, wholeCoreExecuted: true, originalEventConstructorExecuted: true,
        wholePrimaryTransportExecuted: true, wholeFetchGuardExecuted: true, originalOrdinaryGuardsRetained: true,
        ordinaryTimersExecutedAndReleased: true, asyncWorkTrackingExecuted: true,
        executor: 'deterministic supplied domain callback; no provider run or occurrence mint',
        network: 'documented global fixture fetch with mock marker; held ACK and original Response204',
        dnsExecuted: false, socketExecuted: false, dispatcherExecuted: false,
        storageExecuted: false, runtimeAssemblyExecuted: false, schedulerExecuted: false,
        runQueueFinalizationExecuted: false, modelFactoryExecuted: false,
        scriptsExecuted: false, triggersExecuted: false, realProviderExecuted: false, fullAutomationParity: false,
        sourceOnlyReview: { acceptedAckCleanup: 'accepted=true; cleanup().catch(()=>undefined); sendGatewayCronWebhook retains delivered outcome',
          failureTestsExecuted: false },
      },
    });
  } finally { harness.dispose(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source, output] = process.argv.slice(2);
  assert.ok(source && output && process.argv.length === 4, 'usage: capture-automation-webhook.mjs PINNED_SOURCE OUTPUT_JSON');
  const report = await captureAutomationWebhook(source);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: resolve(output), observations: report.observations.length,
    wholeSourceModules: report.sourceRecords.filter(row => row.executed).length }) + '\n');
}
