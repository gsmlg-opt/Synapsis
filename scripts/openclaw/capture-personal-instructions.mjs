// Positive-only source oracle. No Synapsis production activation or identity qualification.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
  readlinkSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const PERSONAL_INSTRUCTIONS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const typeboxRoot = '/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox';
const fsSafeRuntime = '/tmp/synapsis-skills290-source-runtime';
const fsSafeReceipt = '/tmp/synapsis-skills290-evidence/source-runtime-artifacts.json';
const factoryPath = 'src/agents/tools/personal-instructions-tool.ts';
const ownerPath = 'src/gateway/server-methods/users-personal-file.ts';
const loaderPath = 'src/agents/workspace-personal-bootstrap.ts';
const promptPath = 'src/agents/system-prompt-context-files.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);

// Literals come from the independently authored personal356 contract, read before this candidate.
// These are inputs only. No result, schema, hash/compare/write or prompt algorithm is recreated.
const created = '\uFEFF# Personal preferences\r\n- Reply in 中文 😀.\r\n- Keep the original spelling: é.\r\n';
const replaced = created + '- Prefer concise answers.\r\n';
const sharedContent = '# Shared preferences\n- Use clear language.\n- Prefer detailed answers.\n';
const vectors = [
  { id: 'get-missing', input: { action: 'get' } },
  { id: 'create', input: { action: 'set', content: created, expectedHash: null } },
  { id: 'get-created', input: { action: 'get' } },
  { id: 'replace', input: { action: 'set', content: replaced,
    expectedHash: 'd6886c22884e451a1aea95b0b95ac6d2a93a5d9dbd88c8d8e6477e464e0af3bb' } },
  { id: 'get-replaced', input: { action: 'get' } },
  { id: 'empty', input: { action: 'set', content: '',
    expectedHash: '92b66df404f5b24a2f06ba89c5f97261bdb19fe88c356fd95404ddb770050d8b' } },
  { id: 'get-empty', input: { action: 'get' } },
  { id: 'restore', input: { action: 'set', content: replaced,
    expectedHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' } },
  { id: 'explicit-get', input: { action: 'get', agentId: 'fixture-main',
    content: 'Read does not replace saved preferences.', expectedHash: null } },
];

const wholeSources = new Set([
  factoryPath, ownerPath, loaderPath, promptPath,
  'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tool-input-error.ts',
  'src/param-key.ts', 'src/agents/workspace-file-read.ts', 'src/agents/workspace-bootstrap-read.ts',
  'src/agents/workspace-file-cache.ts', 'src/gateway/server-methods/workspace-fs.ts',
  'src/gateway/server-methods/validation.ts', 'src/gateway/workspace-file-limits.ts',
  'src/infra/fs-safe.ts', 'src/infra/boundary-file-read.ts', 'src/infra/errno.ts',
  'src/infra/path-guards.ts', 'src/infra/lru-cache.ts', 'src/infra/retry.ts',
  'src/infra/retry-attempt-errors.ts', 'src/infra/secure-random.ts', 'src/infra/home-dir.ts',
  'src/infra/safe-cwd.ts', 'src/shared/global-singleton.ts', 'src/shared/operator-scope-compat.ts',
  'packages/retry/src/index.ts', 'packages/gateway-protocol/src/protocol-validator.ts',
  'packages/gateway-protocol/src/validation-errors.ts', 'packages/gateway-protocol/src/gateway-error-details.ts',
  'packages/gateway-protocol/src/protocol-value-normalization.ts',
  ...['closed-object', 'primitives', 'user-profile-constants', 'string-literal-union', 'error-codes']
    .map(name => 'packages/gateway-protocol/src/schema/' + name + '.ts'),
  ...['client-info', 'secret-ref-contract', 'session-limits']
    .map(name => 'packages/gateway-protocol/src/' + name + '.ts'),
]);

const services = {
  'src/agents/admitted-run-context.ts': `
export function assertAdmittedRunOperatorAuthority(authority){__calls.push({service:'assertAdmittedRunOperatorAuthority',profileId:authority.profileId});}`,
  'src/agents/tools/gateway-caller-context.ts': `
export function getGatewayToolCallerIdentity(){__calls.push({service:'getGatewayToolCallerIdentity'});return {operatorAuthority:__authority};}
export function captureGatewayToolCallerAssertion(){__calls.push({service:'captureGatewayToolCallerAssertion'});return __assertCurrent;}
export function resolveGatewayPersonalToolParticipant(){__calls.push({service:'resolveGatewayPersonalToolParticipant'});return {assertCurrent:__assertCurrent};}`,
  'src/agents/agent-scope.ts': `
export function listAgentIds(config){__calls.push({service:'listAgentIds'});return config.agents.map(agent=>agent.id);}
export function resolveAgentWorkspaceDir(config,agentId){__calls.push({service:'resolveAgentWorkspaceDir',agentId});return config.agents.find(agent=>agent.id===agentId).workspace;}`,
  'src/agents/workspace-access.ts': `
export function getAgentWorkspaceAccess(workspace){__calls.push({service:'getAgentWorkspaceAccess',workspace});return undefined;}`,
  'src/state/user-profile-list.ts': `
export function hasMultipleResidentSessionSharingIdentities(){__calls.push({service:'hasMultipleResidentSessionSharingIdentities'});return true;}
export function hasMultipleSessionSharingIdentities(){__calls.push({service:'hasMultipleSessionSharingIdentities'});return true;}
export function readResidentUserProfileId(){__calls.push({service:'readResidentUserProfileId'});return __profileId;}
export function readResidentUserProfileIdentity(){__calls.push({service:'readResidentUserProfileIdentity'});return {profileId:__profileId,role:null};}
export function readUserProfileIdentity(){__calls.push({service:'readUserProfileIdentity'});return {profileId:__profileId};}
export function isUserProfileCatalogReady(){__calls.push({service:'isUserProfileCatalogReady'});return true;}
export async function prepareUserProfileCatalog(){__deferredCalls.push('prepareUserProfileCatalog');throw Error('Uninvoked fixture boundary');}`,
  'src/gateway/operator-role-policy.ts': `
export function resolveOperatorRolePolicyForAssignment(){__calls.push({service:'resolveOperatorRolePolicyForAssignment'});return null;}`,
  'src/agents/tools/in-process-gateway.ts': `
export function bindAgentToolGatewayRequest(options){__calls.push({service:'bindAgentToolGatewayRequest',options});return async request=>{
  __gatewayCalls.push({method:request.method,params:__plain(request.params)});
  let replied=false,publicResult;
  await __handlers[request.method]({client:__client,context:__gatewayContext,params:request.params,
    respond(ok,value,error){if(replied)throw Error('Multiple fixture responses');replied=true;
      if(!ok)throw Error('Ordinary fixture did not succeed: '+JSON.stringify(error));publicResult=value;}});
  if(!replied)throw Error('Missing fixture response');__publicResults.push(__plain(publicResult));return publicResult;
};}`,
};
const deferred = {
  'packages/media-core/src/mime.ts': ['detectMime'],
  'src/logging/secret-redaction-registry.ts': ['registerSecretValueForRedaction'],
  'src/gateway/server-methods/gateway-client-identity.ts': ['isGatewayClientProfilePending'],
  'src/gateway/server-methods/gateway-personal-caller.ts': ['isIneligiblePersonalGatewayCaller'],
};
const hostCode = `
globalThis.__plain=value=>JSON.parse(JSON.stringify(value));
globalThis.__calls=[];globalThis.__gatewayCalls=[];globalThis.__publicResults=[];globalThis.__deferredCalls=[];
globalThis.__profileId='Profile_356';
globalThis.__assertCurrent=()=>{__calls.push({service:'suppliedCurrentTurnAssertion',profileId:__profileId});};
globalThis.__authority={source:{fixture:'personal356'},profileId:__profileId,scopes:['operator.read'],assertCurrent:__assertCurrent};
globalThis.__client={connect:{role:'operator',scopes:['operator.read']},internal:{syntheticClient:true,
  operatorRunAuthority:__authority,agentRuntimeIdentity:{fixture:'personal356'}}};
globalThis.__runtimeConfig={agents:[{id:'fixture-main',workspace:__workspace}]};
globalThis.__gatewayContext={getRuntimeConfig:()=>__runtimeConfig};
`;

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), PERSONAL_INSTRUCTIONS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const rows = git(root, ['ls-tree', '-rz', '--full-tree', PERSONAL_INSTRUCTIONS_PIN])
    .split('\0').filter(Boolean).map(row => {
      const [header, path] = row.split('\t');
      const [mode, type, gitBlob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
      const file = join(root, path), linked = lstatSync(file).isSymbolicLink();
      assert.equal(linked, mode === '120000');
      assert.ok(inside(root, realpathSync(file)));
      const bytes = linked ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
      return { path, gitBlob, sha256: hash(bytes) };
    });
  assert.equal(rows.length, 58558);
  return { tracked: new Map(rows.map(row => [row.path, row])), receipt: {
    verified: true, commit: PERSONAL_INSTRUCTIONS_PIN,
    tree: git(root, ['rev-parse', PERSONAL_INSTRUCTIONS_PIN + '^{tree}']),
    verifiedTrackedFiles: rows.length, filesSha256: hash(JSON.stringify(rows)), trackedClean: true } };
}

class PersonalInstructionsHarness extends FactoryHarness {
  constructor(root, tracked, workspace) {
    super(root, tracked, { allowedSources: [...wholeSources] });
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, URLSearchParams,
      AbortController, AbortSignal, setTimeout, clearTimeout, structuredClone,
      process: { env: { NODE_ENV: 'test' }, platform: process.platform, cwd: () => root },
      __workspace: workspace }, { codeGeneration: { strings: false, wasm: false } });
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.packageModules = new Map();
    this.fsRequire = createRequire(join(fsSafeRuntime, 'package.json'));
    const receiptBytes = readFileSync(fsSafeReceipt);
    this.fsReceiptHash = hash(receiptBytes);
    this.fsPackages = JSON.parse(receiptBytes).packages;
    assert.deepEqual(this.fsPackages.map(pkg => [pkg.package, pkg.version]),
      [['@openclaw/fs-safe', '0.26.8'], ['@openclaw/fs-safe-linux-x64-gnu', '0.26.8']]);
    const lock = this.record('pnpm-lock.yaml').toString('utf8');
    for (const pkg of this.fsPackages) {
      assert.equal(pkg.root, join(fsSafeRuntime, 'node_modules', pkg.package));
      assert.ok(lock.includes(pkg.integrity), pkg.package + ' source lock integrity');
      this.verifyPackage(pkg.root, pkg.package, pkg.version, pkg.files);
    }
    this.typeboxFiles = this.inventory(typeboxRoot);
    this.verifyPackage(typeboxRoot, 'typebox', '1.3.37', this.typeboxFiles);
    this.record('LICENSE');
    this.record('package.json');
    this.record('packages/normalization-core/package.json');
    this.record('packages/gateway-protocol/package.json');
    this.importBindings.set('host', { importer: 'capture:driver', specifier: 'capture:personal356-host',
      kind: 'explicit-supplied-host-input', generatedCode: hostCode,
      generatedSha256: hash(hostCode), requesterProfileId: 'Profile_356', bootstrapSubjectProfileId: 'Profile_356',
      agentId: 'fixture-main', workspace, originalSourceExecuted: false,
      pathCanonicalization: 'After original execution only, replace the unique generated fixture root with <fixture-root> in observed strings, including JSON text; content/hash/bytes are not changed.' });
    this.run(hostCode);
  }
  inventory(root) {
    return readdirSync(root, { recursive: true, withFileTypes: true }).filter(entry => entry.isFile())
      .map(entry => { const file = join(entry.parentPath, entry.name), bytes = readFileSync(file);
        return { path: relative(root, file), bytes: bytes.length, sha256: hash(bytes) }; })
      .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  }
  verifyPackage(root, name, version, files) {
    const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    assert.equal(manifest.name, name); assert.equal(manifest.version, version);
    for (const file of files) {
      const bytes = readFileSync(join(root, file.path));
      assert.equal(bytes.length, file.bytes, name + '/' + file.path);
      assert.equal(hash(bytes), file.sha256, name + '/' + file.path);
    }
  }
  record(path, executed = false) {
    const tracked = this.tracked.get(path); assert.ok(tracked, path);
    const bytes = readFileSync(join(this.root, path)); assert.equal(hash(bytes), tracked.sha256, path);
    if (!this.sourceRecords.has(path) || executed) this.sourceRecords.set(path, { ...tracked,
      bytes: bytes.length, executed, originalSourceExecuted: executed, wholeModule: executed,
      provenanceOnly: !executed });
    return bytes;
  }
  admitted(path) {
    return wholeSources.has(path) || (path.startsWith('packages/normalization-core/src/') &&
      path.endsWith('.ts') && !path.includes('.test.'));
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const path = relative(this.root, file); assert.ok(this.admitted(path), 'Unadmitted source: ' + path);
    const executable = stripTypeScriptTypes(this.record(path, true).toString('utf8'),
      { mode: 'transform', sourceMap: false });
    Object.assign(this.sourceRecords.get(path), { transformation, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: () => { this.context.__deferredCalls.push('dynamic import');
        throw Error('Undeclared dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, code, sources = []) {
    for (const source of sources) this.record(source);
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind,
      generatedCode: code, generatedSha256: hash(code), originalSourceExecuted: false,
      sources: sources.map(path => ({ path, sha256: this.tracked.get(path).sha256 })) });
    return this.synthetic('capture:personal356:' + key, code);
  }
  alias(importer, specifier, source, exports, provenance = []) {
    return this.binding(importer, specifier, 'whole-source-export-alias',
      `export {${exports.join(',')}} from ${JSON.stringify('capture:whole:' + source)};`, [source, ...provenance]);
  }
  projection(path, pattern, preamble) {
    const identifier = 'capture:projection:' + path;
    if (this.modules.has(identifier)) return this.modules.get(identifier);
    const original = this.record(path).toString('utf8'), matches = [...original.matchAll(pattern)];
    assert.equal(matches.length, 1, 'Exact source export selection: ' + path);
    const selected = matches[0][1], start = matches[0].index + matches[0][0].indexOf(selected);
    const code = preamble + '\n' + selected;
    const executable = stripTypeScriptTypes(code, { mode: 'transform', sourceMap: false });
    const selection = { startByte: Buffer.byteLength(original.slice(0, start)),
      endByte: Buffer.byteLength(original.slice(0, start + selected.length)), sha256: hash(selected) };
    Object.assign(this.sourceRecords.get(path), { executed: true, originalSourceExecuted: true,
      wholeModule: false, provenanceOnly: false, sourceSpans: [selection] });
    this.importBindings.set(identifier, { importer: path, specifier: identifier,
      kind: 'exact-original-export-declarations', source: path, sourceSha256: this.tracked.get(path).sha256,
      selection, generatedCode: code, generatedSha256: hash(code), transformation,
      executableSha256: hash(executable), originalSourceExecuted: true, wholeModule: false });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier });
    this.modules.set(identifier, mod); return mod;
  }
  async namespace(file, metadata, key) {
    if (!this.packageModules.has(file)) this.packageModules.set(file,
      import(file.startsWith('node:') ? file : pathToFileURL(file).href).then(namespace =>
        new vm.SyntheticModule(Object.keys(namespace), function () {
          for (const name of Object.keys(namespace)) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: file })));
    this.importBindings.set(key, metadata); return this.packageModules.get(file);
  }
  async import(specifier, parent) {
    const importer = parent.startsWith(this.root + sep) ? relative(this.root, parent) : parent;
    const key = importer + ':' + specifier;
    if (specifier.startsWith('capture:whole:')) {
      const path = specifier.slice('capture:whole:'.length);
      this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module',
        source: path, sourceSha256: this.tracked.get(path)?.sha256 });
      return this.module(join(this.root, path));
    }
    if (specifier === 'capture:personal-schema') return this.projection(
      'packages/gateway-protocol/src/schema/users.ts',
      /^(export const UsersPersonalFileGetParamsSchema = [\s\S]*?^export const UsersPersonalFileSetResultSchema = UsersPersonalFileGetResultSchema;)$/gm,
      `import {Type} from 'typebox';
import {closedObject} from 'capture:whole:packages/gateway-protocol/src/schema/closed-object.ts';
import {NonEmptyString,UserProfileIdSchema} from 'capture:whole:packages/gateway-protocol/src/schema/primitives.ts';`);
    if (specifier === 'capture:personal-validators') return this.projection(
      'packages/gateway-protocol/src/validator-registry.ts',
      /^(export const validateUsersPersonalFileGetParams = compile\(S\.UsersPersonalFileGetParamsSchema\);\nexport const validateUsersPersonalFileSetParams = compile\(S\.UsersPersonalFileSetParamsSchema\);)$/gm,
      `import {lazyCompile as compile} from 'capture:whole:packages/gateway-protocol/src/protocol-validator.ts';
import * as S from 'capture:personal-schema';`);
    if (specifier === 'capture:user-filename') return this.projection(
      'src/agents/workspace-bootstrap-policy.ts', /^(export const DEFAULT_USER_FILENAME = "USER\.md";)$/gm, '');
    if (specifier.startsWith('node:')) {
      assert.ok(['node:fs', 'node:fs/promises', 'node:path', 'node:crypto', 'node:buffer',
        'node:async_hooks', 'node:os'].includes(specifier), specifier);
      return this.namespace(specifier, { importer, specifier, kind: 'actual-platform-builtin' }, key);
    }
    if (specifier === 'typebox' || specifier.startsWith('typebox/')) {
      const file = realpathSync(createRequire(join(typeboxRoot, 'package.json')).resolve(specifier));
      assert.ok(inside(typeboxRoot, file));
      return this.namespace(file, { importer, specifier, kind: 'actual-pinned-package', package: 'typebox',
        version: '1.3.37', path: relative(typeboxRoot, file), sha256: hash(readFileSync(file)),
        packageFiles: this.typeboxFiles }, key);
    }
    if (specifier.startsWith('@openclaw/fs-safe/')) {
      const file = realpathSync(this.fsRequire.resolve(specifier)), pkg = this.fsPackages[0];
      assert.ok(inside(pkg.root, file));
      const artifact = pkg.files.find(row => row.path === relative(pkg.root, file)); assert.ok(artifact, file);
      assert.equal(hash(readFileSync(file)), artifact.sha256);
      return this.namespace(file, { importer, specifier, kind: 'native-package-binding',
        package: pkg.package, version: pkg.version, path: artifact.path, sha256: artifact.sha256,
        artifactReceipt: { path: fsSafeReceipt, sha256: this.fsReceiptHash }, packages: this.fsPackages }, key);
    }
    const protocol = 'packages/gateway-protocol/src/index.ts';
    let path;
    if (specifier.startsWith('@openclaw/normalization-core/'))
      path = 'packages/normalization-core/src/' + specifier.slice('@openclaw/normalization-core/'.length) + '.ts';
    else if (specifier === '@openclaw/media-core/mime') path = 'packages/media-core/src/mime.ts';
    else if (specifier.startsWith('.')) path = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
    else throw Error('Undeclared source import: ' + importer + ' -> ' + specifier);
    if (path === protocol) return this.binding(importer, specifier, 'narrow-protocol-source-export-alias',
      `export {validateUsersPersonalFileGetParams,validateUsersPersonalFileSetParams} from 'capture:personal-validators';
export {ErrorCodes,errorShape} from 'capture:whole:packages/gateway-protocol/src/schema/error-codes.ts';
export {formatValidationErrors} from 'capture:whole:packages/gateway-protocol/src/validation-errors.ts';`, [protocol]);
    if (path === 'src/utils.ts') return this.alias(importer, specifier, 'src/infra/home-dir.ts',
      ['resolveUserPath'], [path]);
    if (path === 'src/infra/errors.ts') return this.alias(importer, specifier, 'src/infra/errno.ts',
      ['isMissingPathError'], [path]);
    if (path === 'src/agents/workspace.ts') return this.binding(importer, specifier,
      'exact-original-constant-export-alias', `export {DEFAULT_USER_FILENAME} from 'capture:user-filename';`, [path]);
    if (services[path]) return this.binding(importer, specifier, 'explicit-supplied-success-boundary', services[path], [path]);
    if (deferred[path]) return this.binding(importer, specifier, 'uninvoked-throwing-boundary',
      deferred[path].map(name => `export function ${name}(){__deferredCalls.push(${JSON.stringify(path + ':' + name)});throw Error('Uninvoked boundary');}`).join('\n'), [path]);
    assert.ok(path && this.admitted(path), 'Undeclared source import: ' + importer + ' -> ' + specifier);
    this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module', source: path,
      sourceSha256: this.tracked.get(path)?.sha256 });
    return this.module(join(this.root, path));
  }
  async load(path) {
    const mod = this.module(join(this.root, path));
    if (mod.status === 'unlinked') await mod.link((specifier, parent) => this.import(specifier, parent.identifier));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 1000 });
    assert.equal(mod.status, 'evaluated'); return mod.namespace;
  }
  run(code) {
    const key = 'capture:run:' + hash(code);
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer: 'capture:driver',
      specifier: key, kind: 'explicit-capture-driver', generatedCode: code, generatedSha256: hash(code) });
    return new vm.Script(code).runInContext(this.context, { timeout: 1000 });
  }
}

// Replace generated fixture paths only after all original source operations complete.
function tokenize(value, fixtureRoot) {
  if (typeof value === 'string') return value.replaceAll(fixtureRoot, '<fixture-root>');
  if (Array.isArray(value)) return value.map(entry => tokenize(entry, fixtureRoot));
  if (value && typeof value === 'object') return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [key, tokenize(entry, fixtureRoot)]));
  return value;
}

export async function capturePersonalInstructions(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source); assert.equal(root, fixedRoot);
  const before = checkout(root);
  const fixtureRoot = mkdtempSync('/tmp/synapsis-personal356-source-fixture-');
  try {
    const workspace = join(fixtureRoot, 'configured-main'); mkdirSync(workspace);
    writeFileSync(join(workspace, 'USER.md'), sharedContent);
    const harness = new PersonalInstructionsHarness(root, before.tracked, workspace);
    harness.context.__handlers = (await harness.load(ownerPath)).usersPersonalFileHandlers;
    harness.context.__factory = await harness.load(factoryPath);
    harness.context.__tool = harness.run('__factory.createPersonalInstructionsTool("fixture-main")');
    const factory = plain(harness.run(`({name:__tool.name,label:__tool.label,
      description:__tool.description,parameters:__tool.parameters})`));
    const cases = [];
    const personalPath = join(workspace, 'users', 'Profile_356', 'USER.md');
    for (const vector of vectors) {
      harness.context.__serializedInput = JSON.stringify(vector.input);
      harness.run('globalThis.__input=JSON.parse(__serializedInput)');
      const callOffset = harness.context.__gatewayCalls.length;
      const responseOffset = harness.context.__publicResults.length;
      const result = plain(await harness.run('__tool.execute("personal356",__input)'));
      assert.equal(harness.context.__gatewayCalls.length, callOffset + 1);
      assert.equal(harness.context.__publicResults.length, responseOffset + 1);
      assert.deepEqual(plain(harness.context.__input), vector.input);
      const bytes = existsSync(personalPath) ? readFileSync(personalPath) : null;
      cases.push({ id: vector.id, input: plain(vector.input), gateway: plain(harness.context.__gatewayCalls[callOffset]),
        publicResult: plain(harness.context.__publicResults[responseOffset]), result,
        file: bytes === null ? null : { relativePath: relative(workspace, personalPath), utf8: bytes.toString('utf8'),
          sha256: hash(bytes), bytes: [...bytes] } });
    }
    harness.context.__loader = await harness.load(loaderPath);
    harness.context.__prompt = await harness.load(promptPath);
    harness.context.__selectedPersonal = await harness.run('__loader.loadPersonalUserBootstrapFile(__workspace,__profileId)');
    harness.context.__sharedContent = readFileSync(join(workspace, 'USER.md'), 'utf8');
    const bootstrap = plain(harness.run(`(()=>{
      const shared={name:'USER.md',path:__workspace+'/USER.md',content:__sharedContent,missing:false,
        origin:{kind:'agent-workspace',rootPath:__workspace}};
      const personal=__selectedPersonal;
      const prepared=__prompt.prepareContextFilesForPrompt([shared,personal]);
      return {subjectProfileId:__profileId,workspace:__workspace,shared,personal,prepared,
        section:__prompt.buildProjectContextSection(prepared)};
    })()`));
    assert.deepEqual(plain(harness.context.__deferredCalls), []);
    harness.importBindings.get('host').observedSuccessfulFacadeCalls = plain(harness.context.__calls);
    const after = checkout(root); assert.deepEqual(after.receipt, before.receipt);
    const result = { schemaVersion: 1, referenceCommit: PERSONAL_INSTRUCTIONS_PIN,
      sourceTree: { before: before.receipt, after: after.receipt },
      sourceRecords: [...harness.sourceRecords.values()].sort((a, b) => a.path.localeCompare(b.path)),
      importBindings: [...harness.importBindings.values()], factory, cases, bootstrap,
      boundaries: {
        executed: ['original personal_instructions factory', 'original usersPersonalFileHandlers get/set owner',
          'real fixture filesystem read/write and SHA256', 'original workspace update queue',
          'original loadPersonalUserBootstrapFile', 'original prepareContextFilesForPrompt and buildProjectContextSection'],
        supplied: ['successful requester and admitted-run identity facade for Profile_356',
          'successful resident catalog and multiuser-enabled facade',
          'successful configured Agent and workspace facade for fixture-main',
          'successful gateway dispatch facade into original owner',
          'successful selected bootstrap subject facade for Profile_356'] },
      limitations: [
        'Source-only oracle; no native Synapsis production implementation or activation is qualified.',
        'Identity, catalog, multiuser and admission facades supply successful host inputs; this is not authentication qualification.',
        'The original multiuser-only eligibility remains unchanged; the actual user answer about a single-operator Synapsis adaptation is pending.',
        'Requester and session-selected bootstrap person follow distinct source policies; this ordinary fixture supplies Profile_356 for both and does not qualify cross-user or cross-Agent isolation.',
        'No security, permission, authentication, negative, error, conflict, retry, cancellation, crash, budget, threshold, truncation, eviction, race, mixed, directory or real-provider tests are executed.',
        'No 4000-limit boundary or large-existing-file parity is qualified.' ] };
    return tokenize(result, fixtureRoot);
  } finally {
    rmSync(fixtureRoot, { recursive: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 3, 'usage: capture-personal-instructions.mjs output');
  const capture = await capturePersonalInstructions(fixedRoot);
  writeFileSync(process.argv[2], JSON.stringify(capture, null, 2) + '\n');
}
