// Complete pinned Lobster wrapper callbacks; the external core and successful
// filesystem observations are explicit fixtures, not a host workflow engine.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path, { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { Readable, Writable } from 'node:stream';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/lobster/src/lobster-tool.ts';
const runner = 'extensions/lobster/src/lobster-runner.ts';
const readers = 'src/agents/tools/common.ts';
const results = 'src/agents/tools/tool-results.ts';
const sdk = 'openclaw/plugin-sdk/';
const cwd = '/reference/lobster';
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const from = (names, source) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + source)};`;
const sources = new Set([factory, runner, results, 'packages/retry/src/index.ts',
  'packages/normalization-core/src/error-coercion.ts', 'src/agents/schema/typebox.ts',
  'src/agents/schema/string-enum.ts', 'src/infra/outbound/channel-target.ts']);
const facades = {
  [sdk + 'channel-actions']: from(['optionalPositiveIntegerSchema'], 'src/agents/schema/typebox.ts'),
  [sdk + 'param-readers']: from(['readPositiveIntegerParam'], readers),
  [sdk + 'tool-results']: from(['jsonResult'], results),
  [sdk + 'time-runtime']: from(['raceWithTimeout'], 'packages/retry/src/index.ts'),
  [sdk + 'error-runtime']: from(['extractErrorCode','toErrorObject'], 'packages/normalization-core/src/error-coercion.ts'),
};

class LobsterCapture extends BraveCapture {
  constructor(root) {
    super(root);
    this.dependencies = new Map(); this.generatedFacades = new Map();
    this.coreCalls = []; this.coreLoads = 0; this.statPaths = []; this.containmentCalls = [];
    this.timerDurations = [];
    this.context.process = { cwd: () => cwd, env: { LOBSTER_CAPTURE: 'ordinary-success' } };
    this.context.AbortController = AbortController;
    this.context.setTimeout = (callback, ms) => { this.timerDurations.push(ms); return setTimeout(callback, ms); };
    this.context.clearTimeout = clearTimeout;
  }
  source(source) {
    if (!sources.has(source)) return super.source(source);
    if (!this.modules.has(source)) this.modules.set(source, new vm.SourceTextModule(this.verifiedSource(source), {
      context: this.context, identifier: source,
      importModuleDynamically: async specifier => {
        this.audit.push({ kind: 'dynamic-import', importer: source, specifier });
        const target = this.import(specifier, source); await this.evaluate(target); return target;
      },
    }));
    return this.modules.get(source);
  }
  typeboxModule(file) {
    assert.ok(file.startsWith(this.typeboxRoot + sep));
    const id = 'lobster:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file), source = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(source, { path: source, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  core() {
    if (!this.modules.has('lobster:core-success')) this.coreLoads++;
    const run = method => async request => {
      const { ctx, ...params } = request;
      const input = []; for await (const value of ctx.stdin) input.push(value);
      this.coreCalls.push({ method, params: plain(params), context: {
        cwd: ctx.cwd, mode: ctx.mode, stdin: input,
        stdoutWritable: ctx.stdout instanceof Writable, stderrWritable: ctx.stderr instanceof Writable,
        signalAborted: ctx.signal.aborted,
      } });
      this.audit.push({ kind: 'external-core-success-fixture', method });
      return plain(this.envelope);
    };
    return this.synthetic('lobster:core-success', {
      runToolRequest: run('runToolRequest'), resumeToolRequest: run('resumeToolRequest'),
    }, Object.fromEntries(['runToolRequest','resumeToolRequest'].map(name => [name, {
      kind: 'ordinary-success-facade', behavior: 'records exact request and returns declared envelope; no external runtime execution',
    }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === '@clawdbot/lobster/core') {
      link('external-core-success-fixture', 'lobster:core-success'); return this.core();
    }
    if (specifier === 'typebox' || specifier.startsWith('typebox/')) {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve(specifier));
      let root = dirname(file); while (!existsSync(join(root, 'package.json'))) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json')), pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox'); assert.equal(pkg.version, '1.3.37');
      if (this.typeboxRoot) assert.equal(root, this.typeboxRoot);
      this.typeboxRoot = root; this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file)); return this.typeboxModule(file);
    }
    if (importer.startsWith('lobster:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('lobster:typebox:'.length)), specifier)));
    }
    if (specifier === 'node:path' || specifier === 'node:stream') {
      link('native-platform', specifier);
      const bindings = specifier === 'node:path' ? { default: path } : { Readable, Writable };
      return this.synthetic(specifier, bindings, Object.fromEntries(Object.keys(bindings).map(name => [name, { kind: 'native-platform', behavior: `actual ${specifier}:${name}` }])));
    }
    if (specifier === 'node:fs/promises') {
      link('successful-stat-fixture', 'lobster:stat');
      return this.synthetic('lobster:stat', { stat: async file => {
        assert.ok(['/reference/lobster/work/workflows/demo.lobster','/reference/lobster/workflows/DEMO.JSON'].includes(file));
        this.statPaths.push(file); this.audit.push({ kind: 'successful-stat-fixture', path: file });
        return { isFile: () => true };
      } }, { stat: { kind: 'successful-stat-fixture', behavior: 'two declared regular files only; no filesystem IO' } });
    }
    if (specifier === sdk + 'file-access-runtime') {
      this.verifiedSource('src/plugin-sdk/file-access-runtime.ts', false);
      this.verifiedSource('src/infra/path-guards.ts', false);
      link('successful-containment-fixture', 'lobster:containment');
      return this.synthetic('lobster:containment', { isPathInside: (root, target) => {
        assert.equal(root, cwd); assert.equal(target, cwd + '/work');
        this.containmentCalls.push({ root, target, result: true });
        this.audit.push({ kind: 'successful-containment-fixture', root, target }); return true;
      } }, { isPathInside: { kind: 'successful-containment-fixture', behavior: 'one declared contained cwd; external fs-safe classifier unexecuted' } });
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts';
      this.verifiedSource(provenance, false);
      if (specifier === sdk + 'error-runtime') this.verifiedSource('src/infra/errors.ts', false);
      const code = facades[specifier], id = 'lobster:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode: code, sha256: digest(code) });
      link('whole-module-re-export-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(code, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    if (importer === readers && specifier === './tool-results.js') {
      link('executed-whole-module', results); return this.source(results);
    }
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t'), [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path), stat = lstatSync(file), symlink = stat.isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', path + ' executable mode');
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, mode, gitBlob: blob, sha256: digest(bytes) };
  });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN, tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, modesAndSymlinksVerified: true, filesSha256: digest(JSON.stringify(files)) };
}
function recipes() {
  const success = output => ({ protocolVersion: 1, ok: true, status: 'ok', output, requiresApproval: null, requiresInput: null });
  return [
    { id: 'inline-defaults', arguments: { action: ' run ', pipeline: ' json "[1,2]" ' }, envelope: success([{ kind: 'inline', items: [1,2] }]) },
    { id: 'inline-args-ignored', arguments: { action: 'run', pipeline: ' json "[true]" | json ', argsJson: ' {"ignored":true} ', timeoutMs: '25000', maxStdoutBytes: '16384', extra: 'not-forwarded' }, envelope: success([true,'雪😀',null]) },
    { id: 'file-lobster', arguments: { action: 'run', pipeline: ' workflows/demo.lobster ', cwd: ' work ', argsJson: ' {"enabled":false,"count":0,"nested":{"雪":["a",null]}} ' }, envelope: success([{ file: 'demo.lobster', ready: true }]) },
    { id: 'file-json-no-args', arguments: { action: 'run', pipeline: ' /reference/lobster/workflows/DEMO.JSON ', argsJson: '   ' }, envelope: { protocolVersion: 1, ok: true } },
    { id: 'run-needs-input', arguments: { action: 'run', pipeline: ' json "[1]" | ask ' }, envelope: { protocolVersion: 1, ok: true, status: 'needs_input', output: [{ step: 'before', value: 1 }], requiresInput: { type: 'engine_input', prompt: 'Choose a name', responseSchema: { type: 'string' }, defaults: '雪😀', subject: { step: 'name' }, resumeToken: 'input-token', note: 'retained' } } },
    ...[
      ['null',' null ',null], ['false',' false ',false], ['zero',' 0 ',0],
      ['string',' " padded 雪😀 " ',' padded 雪😀 '], ['array',' [1,null,"雪😀"] ',[1,null,'雪😀']],
      ['object',' {"ready":true,"nested":[false,0]} ',{ ready: true, nested: [false,0] }],
    ].map(([id,responseJson,response]) => ({ id: 'resume-' + id, arguments: { action: 'resume', token: ' token-' + id + ' ', responseJson }, envelope: success([response]) })),
  ];
}

export async function captureLobster(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root); const before = checkout(root);
  const capture = new LobsterCapture(root), module = capture.source(factory);
  await capture.evaluate(module);
  const tool = module.namespace.createLobsterTool();
  const metadata = plain({ name: tool.name, label: tool.label, description: tool.description, parameters: tool.parameters });
  const vectors = [];
  for (const recipe of recipes()) {
    const args = plain(recipe.arguments), original = plain(args);
    capture.envelope = recipe.envelope;
    const callsBefore = capture.coreCalls.length, timersBefore = capture.timerDurations.length;
    const result = plain(await tool.execute('source-' + recipe.id, args));
    assert.deepEqual(args, original);
    assert.equal(capture.coreCalls.length, callsBefore + 1);
    assert.equal(capture.timerDurations.length, timersBefore + 1);
    vectors.push({ id: recipe.id, arguments: original, argumentsUnchanged: true,
      coreCalls: capture.coreCalls.slice(callsBefore), result,
      observationTimeoutMs: capture.timerDurations[timersBefore] });
  }
  assert.equal(capture.coreLoads, 1);
  assert.equal(capture.audit.filter(row => row.kind === 'unused-service-invoked').length, 0);
  const after = checkout(root); assert.deepEqual(after, before);
  const sorted = values => [...values].sort((a,b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  const sourceRecords = sorted([...capture.sources.values()].map(row => ({ ...row, sha256: row.sourceSha256 })));
  return {
    referencePin: BRAVE_REFERENCE_PIN, schemaVersion: 1,
    referenceRole: 'independent-full-wrapper-callback-success-oracle',
    runtimeContractAuthority: 'backplane_agent_runtime; this source capture installs no host tool',
    metadata, vectors,
    externalCore: { package: '@clawdbot/lobster', version: '2026.9.16', executed: false, loadCount: capture.coreLoads, kind: 'ordinary-success-facade' },
    filesystem: { kind: 'successful-stat-facade', cwd, statPaths: capture.statPaths, containmentCalls: capture.containmentCalls },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true, publicCallbackInvoked: true,
      externalRuntimeExecuted: false, hostCatalogInstalled: false, actualCheckpointPersistence: false,
      limits: [
        'Whole pinned tool/runner and actual readers/jsonResult/raceWithTimeout execute, with actual TypeBox1.3.37 module graph',
        'External core returns explicitly declared successful envelopes; no workflow parsing, step dispatch, checkpoint persistence, schema response validation or resume execution is qualified',
        'node:path and node:stream are actual platform modules; two stat observations and one contained cwd are declared success fixtures, no filesystem or external fs-safe behavior is qualified',
        'Runtime import is cached per actual runner; normal timer arming/clearing executes; timeout, cancellation and remote cleanup are untested',
        'Actual JSON parse/stringify preserve supported native JavaScript values; input extras retained by source spread and protocolVersion omitted by source projection',
        'No approvals, permission/security/auth/TLS, negative/unavailable/overflow/mixed/failure/cancel/crash/expiry/real-provider tests',
      ] },
    checkout: { before, after }, sourceRecords,
    typebox: { version: capture.typeboxVersion, files: sorted(capture.dependencies.values()) },
    aliases: sorted(capture.aliases.values()), facades: sorted(capture.generatedFacades.values()), stubs: sorted(capture.stubBindings.values()), audit: capture.audit,
    counts: { vectors: vectors.length, callbacks: vectors.length, executedWholeModules: sourceRecords.filter(row => row.executed).length, provenanceOnlyModules: sourceRecords.filter(row => !row.executed).length },
    harness: { path: 'scripts/openclaw/capture-lobster.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs', sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))) }],
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root,'LICENSE'))), text: readFileSync(join(root,'LICENSE'),'utf8') },
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2); let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n++) {
    if (args[n] === '--write') output = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster.json';
    else {
      assert.ok(['--source','--output'].includes(args[n]) && args[n+1], 'use --source ROOT --output FILE or --write');
      if (args[n] === '--source') root = args[++n]; else output = args[++n];
    }
  }
  const json = JSON.stringify(await captureLobster(root),null,2) + '\n';
  if (output) writeFileSync(output,json); else process.stdout.write(json);
}
