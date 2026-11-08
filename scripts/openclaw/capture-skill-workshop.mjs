// Whole unchanged pinned Workshop source; adapters bind only named external owners.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync,
  realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const SKILL_WORKSHOP_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const typeboxRoot = '/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox';
const fsSafeRuntime = '/tmp/synapsis-skills290-source-runtime';
const fsSafeReceipt = '/tmp/synapsis-skills290-evidence/source-runtime-artifacts.json';
const yamlReceipt = '/tmp/synapsis-workshop292-evidence/yaml-artifact.json';
const fixtureRoot = '/tmp/synapsis-workshop292-source-fixture';
const rawReceipt = '/tmp/synapsis-workshop292-source-raw.json';
const factory = 'src/agents/tools/skill-workshop-tool-factory.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);
const initial = '---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\n\n# Deploy\n\n1. Inspect the release.\n2. Record the result.\n';

export function skillWorkshopVectors() {
  return [
    { id: 'list-empty', args: { action: 'list' } },
    { id: 'create', args: { action: 'create', name: 'deploy-guide', content: initial } },
    { id: 'view-initial', args: { action: 'view', name: 'deploy-guide' } },
    { id: 'write-reference', args: { action: 'write_file', name: 'deploy-guide',
      file_path: 'references/notes.md', content: 'Reference café.\nKeep the release record.\n' } },
    { id: 'write-template', args: { action: 'write_file', name: 'deploy-guide',
      file_path: 'templates/check.txt', content: 'Release: <version>\nResult: <result>\n' } },
    { id: 'patch-main', args: { action: 'patch', name: 'deploy-guide',
      old_text: 'Inspect the release.', new_text: 'Inspect the approved release.', reason: 'clarify the approval check' } },
    { id: 'patch-reference', args: { action: 'patch', name: 'deploy-guide',
      file_path: 'references/notes.md', old_text: 'release record', new_text: 'approved release record' } },
    { id: 'view-reference', args: { action: 'view', name: 'deploy-guide', file_path: 'references/notes.md' } },
    { id: 'view-saved', args: { action: 'view', name: 'deploy-guide' }, versionFrom: 'write-reference' },
    { id: 'remove-reference', args: { action: 'remove_file', name: 'deploy-guide', file_path: 'references/notes.md' } },
    { id: 'write-extra', args: { action: 'write_file', name: 'deploy-guide',
      file_path: 'examples/trial.txt', content: 'Trial procedure.\n' } },
    { id: 'restore-explicit', args: { action: 'restore', name: 'deploy-guide',
      reason: 'restore the complete saved tree' }, versionFrom: 'remove-reference' },
    { id: 'view-restored', args: { action: 'view', name: 'deploy-guide', file_path: 'references/notes.md' } },
    { id: 'archive', args: { action: 'archive', name: 'deploy-guide', reason: 'retain the reusable procedure' } },
    { id: 'list-archived', args: { action: 'list' } },
    { id: 'restore-newest', args: { action: 'restore', name: 'deploy-guide' } },
    { id: 'list-restored', args: { action: 'list' } },
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), SKILL_WORKSHOP_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', SKILL_WORKSHOP_PIN])
    .split('\0').filter(Boolean).map(row => {
      const [header, path] = row.split('\t');
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
  assert.equal(files.length, 58558);
  const tree = git(root, ['rev-parse', `${SKILL_WORKSHOP_PIN}^{tree}`]);
  assert.equal(tree, '47509a47273231ab15f57252960fe716d7379ffb');
  return { files: new Map(files.map(row => [row.path, row])), receipt: {
    commit: SKILL_WORKSHOP_PIN, tree, trackedClean: true, verifiedTrackedFiles: files.length,
    filesSha256: hash(JSON.stringify(files)),
  } };
}

const wholeSources = new Set([
  factory, 'src/agents/tools/skill-workshop-tool.ts', 'src/agents/tools/skill-workshop-tool-schema.ts',
  'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tool-input-error.ts',
  'src/param-key.ts', 'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts',
  'src/infra/outbound/channel-target.ts', 'src/agents/tool-description-presets.ts', 'src/agents/utils/paths.ts',
  'src/skills/workshop/config.ts', 'src/skills/workshop/skills-root.ts', 'src/skills/workshop/library.ts',
  'src/skills/workshop/skill-versions.ts', 'src/skills/workshop/skill-lint.ts',
  'src/skills/workshop/skill-authoring-standards.ts', 'src/skills/lifecycle/workspace-skill-write.ts',
  'src/skills/loading/frontmatter.ts', 'packages/markdown-core/src/frontmatter.ts',
  'src/skills/security/skill-bundle-scan.ts', 'src/skills/security/scanner.ts',
  'src/skills/security/scan-evidence.ts', 'src/security/scan-paths.ts', 'src/shared/regexp.ts',
  'src/plugin-sdk/keyed-async-queue.ts', 'src/infra/fs-safe.ts', 'src/infra/fs-safe-remove.ts',
  'src/infra/errno.ts', 'src/infra/mutation-authority.ts', 'src/infra/crypto-digest.ts',
  'src/infra/map-size.ts',
]);

// Each boundary is an external owner explicitly allowed by this source-only contract.
// The captured append-only array is an observation sink, not a replacement database.
const services = {
  'src/agents/agent-scope-config.ts': `
export function resolveAgentDir(config,agentId,env){__services.push({kind:'resolveAgentDir',config,agentId,envPassed:env!==undefined});if(agentId!=='agent292')throw Error('Unexpected fixture owner');return __fixtureRoot;}
export function resolveAgentWorkspaceDir(){__deferredCalls.push('resolveAgentWorkspaceDir');throw Error('Uncalled hook workspace owner');}`,
  'src/skills/workshop/changes.ts': `
export async function recordWorkshopChange(change){__services.push({kind:'recordWorkshopChange',change});__ledger.push(structuredClone(change));}
export function listWorkshopChanges(){__deferredCalls.push('listWorkshopChanges');throw Error('Source SQL query not bound');}`,
  'src/skills/runtime/refresh.ts': `
export async function refreshSkillsDiscovery(params){__services.push({kind:'refreshSkillsDiscovery',params});}`,
  'src/skills/lifecycle/skill-change-hook.ts': `
export function hasCommittedSkillChangeHooks(){__services.push({kind:'hasCommittedSkillChangeHooks',result:false});return false;}
export function dispatchCommittedSkillChangeBestEffort(){__deferredCalls.push('dispatchCommittedSkillChangeBestEffort');throw Error('No hook owner supplied');}
export function snapshotCommittedSkillArtifactBestEffort(){__deferredCalls.push('snapshotCommittedSkillArtifactBestEffort');throw Error('No hook owner supplied');}`,
  'src/agents/agent-tools.before-tool-call.diagnostics.ts': `
export function recordSkillUsed(params){__services.push({kind:'recordSkillUsed',params});}`,
  'src/logging/subsystem.ts': `
export function createSubsystemLogger(name){__services.push({kind:'createSubsystemLogger',name});return {warn(message){__services.push({kind:'logger.warn',name,message});throw Error('Unexpected ordinary-path warning');}};}`,
  'src/agents/agent-tool-source-execution-guard.ts': `
function assertAdmitted(){__services.push({kind:'assertAdmittedSource',owner:__admission.owner});if(__admission.owner!=='source-oracle292'||!__admission.active)throw Error('Fixture admission not current');}
export function captureAgentToolSourceExecutionGuard(signal){__services.push({kind:'captureAdmittedSource',signalPresent:signal!==undefined});if(signal!==undefined)throw Error('No signal vector admitted');assertAdmitted();return assertAdmitted;}
export async function runWithAgentToolSourceExecutionScope(assertion,run){__services.push({kind:'runWithAdmittedSource'});assertion();return await run();}`,
  'src/config/sessions/session-source-authority.ts': `
export function composeSessionSourceAssertion(sources,check){__services.push({kind:'composeAdmittedSource',sources:sources.length});return ()=>check(()=>{for(const source of sources)source?.();});}`,
};

// Only unused imports are cut. An unexpected call is a hard capture failure.
const uncalled = {
  'src/config/config.ts': ['getRuntimeConfig'],
  'src/agents/tools/skill-workshop-tool-library.ts': ['createLibrarySkillWorkshopTool'],
  'packages/media-core/src/mime.ts': ['detectMime'],
  'src/infra/errors.ts': ['formatErrorMessage', 'hasErrnoCode'],
  'src/infra/path-existence.ts': ['statIfExists'],
  'src/infra/npm-registry-spec.ts': ['validateRegistryNpmSpec'],
  'src/shared/frontmatter.ts': ['applyOpenClawManifestInstallCommonFields', 'getFrontmatterString',
    'parseOpenClawManifestInstallBase', 'parseFrontmatterBool', 'resolveOpenClawManifestBlock',
    'resolveOpenClawManifestInstall', 'resolveOpenClawManifestOs', 'resolveOpenClawManifestRequires'],
};

class WorkshopHarness {
  constructor(root, tracked) {
    this.root = root;
    this.tracked = tracked;
    this.modules = new Map();
    this.sourceRecords = new Map();
    this.bindings = new Map();
    this.packageModules = new Map();
    this.packageExports = new Map();
    this.packageLicensing = new Map();
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, URLSearchParams,
      AbortController, AbortSignal, setTimeout, clearTimeout, structuredClone,
      process: { env: { NODE_ENV: 'test' }, platform: process.platform, cwd: () => root },
      __fixtureRoot: fixtureRoot, __admission: { owner: 'source-oracle292', active: true },
      __services: [], __ledger: [], __deferredCalls: [],
    }, { codeGeneration: { strings: false, wasm: false } });
    this.fsRequire = createRequire(join(fsSafeRuntime, 'package.json'));
    const bytes = readFileSync(fsSafeReceipt);
    this.fsPackages = JSON.parse(bytes).packages;
    assert.deepEqual(this.fsPackages.map(pkg => [pkg.package, pkg.version]),
      [['@openclaw/fs-safe', '0.26.8'], ['@openclaw/fs-safe-linux-x64-gnu', '0.26.8']]);
    this.fsReceiptHash = hash(bytes);
    const lock = this.record('pnpm-lock.yaml', false);
    for (const pkg of this.fsPackages) {
      assert.equal(pkg.root, join(fsSafeRuntime, 'node_modules', pkg.package));
      assert.ok(lock.includes(pkg.integrity));
      this.verifyPackage(pkg.root, pkg.package, pkg.version, pkg.files);
    }
    const yamlBytes = readFileSync(yamlReceipt);
    this.yaml = JSON.parse(yamlBytes);
    assert.equal(this.yaml.package, 'yaml');
    assert.equal(this.yaml.version, '2.9.1');
    assert.equal(this.yaml.root, '/tmp/synapsis-workshop292-source-runtime/node_modules/yaml');
    assert.equal(this.yaml.tarballSHA256, '4ef6c54cf559b8a207b7b518378230805a1c84af239b14960e8c67c7d59de5d3');
    assert.ok(lock.includes(this.yaml.lockAndRegistryIntegrity));
    this.verifyPackage(this.yaml.root, 'yaml', '2.9.1', this.yaml.files);
    this.yamlReceiptHash = hash(yamlBytes);
    this.typeboxFiles = this.inventory(typeboxRoot);
    this.verifyPackage(typeboxRoot, 'typebox', '1.3.37', this.typeboxFiles);
    this.record('LICENSE', false);
    this.record('package.json', false);
    this.record('packages/markdown-core/package.json', false);
    this.record('packages/normalization-core/package.json', false);
  }

  inventory(root) {
    return readdirSync(root, { recursive: true, withFileTypes: true }).filter(entry => entry.isFile())
      .map(entry => { const file = join(entry.parentPath, entry.name), bytes = readFileSync(file);
        return { path: relative(root, file), bytes: bytes.length, sha256: hash(bytes) }; })
      .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  }

  verifyPackage(root, name, version, files) {
    const manifestBytes = readFileSync(join(root, 'package.json'));
    const manifest = JSON.parse(manifestBytes);
    assert.equal(manifest.name, name);
    assert.equal(manifest.version, version);
    for (const file of files) {
      const bytes = readFileSync(join(root, file.path));
      assert.equal(bytes.length, file.bytes, name + '/' + file.path);
      assert.equal(hash(bytes), file.sha256, name + '/' + file.path);
    }
    const distributedLicenseFiles = files.filter(file => /license/i.test(file.path));
    assert.equal(typeof manifest.license, 'string', name + ' declared license');
    assert.ok(manifest.license.length > 0, name + ' declared license');
    if (name === '@openclaw/fs-safe-linux-x64-gnu') {
      // The official native artifact ships only its addon and manifest. Its MIT
      // declaration is evidence; no separately distributed license text is present.
      assert.deepEqual(files.map(file => file.path).sort(), ['fs-safe-native.node', 'package.json']);
      assert.equal(manifest.license, 'MIT');
      assert.equal(distributedLicenseFiles.length, 0);
    } else {
      assert.ok(distributedLicenseFiles.length > 0, name + ' distributed license inventory');
    }
    this.packageLicensing.set(name, { package: name, version, declaredLicense: manifest.license,
      declaration: { path: 'package.json', sha256: hash(manifestBytes) },
      distributedLicenseFiles, licenseTextIncluded: distributedLicenseFiles.length > 0,
      repositoryReference: manifest.repository ?? null,
      referenceLimit: 'Repository metadata is a reference only; no external license text was fetched or inferred.' });
  }

  record(file, executed) {
    const tracked = this.tracked.get(file);
    assert.ok(tracked, file);
    const bytes = readFileSync(join(this.root, file));
    assert.equal(hash(bytes), tracked.sha256, file);
    const previous = this.sourceRecords.get(file);
    if (!previous || executed) this.sourceRecords.set(file, { ...tracked, bytes: bytes.length,
      executed, originalSourceExecuted: executed, wholeModule: executed, provenanceOnly: !executed });
    return bytes.toString('utf8');
  }

  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    assert.ok(wholeSources.has(file) || (file.startsWith('packages/normalization-core/src/') &&
      file.endsWith('.ts') && !file.includes('.test.')), 'Unadmitted source module: ' + file);
    const executable = stripTypeScriptTypes(this.record(file, true), { mode: 'transform', sourceMap: false });
    Object.assign(this.sourceRecords.get(file), { transformation, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: join(this.root, file),
      importModuleDynamically: async (specifier, parent) => {
        const linked = await this.link(specifier, parent);
        if (linked.status === 'unlinked') await linked.link((s, p) => this.link(s, p));
        if (linked.status === 'linked') await linked.evaluate({ timeout: 1000 });
        return linked;
      },
    });
    this.modules.set(file, mod);
    return mod;
  }

  binding(file, kind, code) {
    this.record(file, false);
    if (!this.bindings.has(file)) this.bindings.set(file,
      { path: file, kind, originalSourceExecuted: false, generatedCode: code, generatedSha256: hash(code) });
    const key = 'binding:' + file;
    if (!this.modules.has(key)) this.modules.set(key,
      new vm.SourceTextModule(code, { context: this.context, identifier: key }));
    return this.modules.get(key);
  }

  async namespace(file, metadata) {
    this.packageExports.set(file, { ...metadata, sha256: hash(readFileSync(file)) });
    if (!this.packageModules.has(file)) this.packageModules.set(file,
      import(pathToFileURL(file).href).then(namespace => new vm.SyntheticModule(Object.keys(namespace), function () {
        for (const key of Object.keys(namespace)) this.setExport(key, namespace[key]);
      }, { context: this.context, identifier: file })));
    return this.packageModules.get(file);
  }

  async link(specifier, parent) {
    if (specifier.startsWith('node:')) {
      assert.ok(['node:fs', 'node:fs/promises', 'node:path', 'node:crypto', 'node:buffer'].includes(specifier), specifier);
      if (!this.packageModules.has(specifier)) this.packageModules.set(specifier,
        import(specifier).then(namespace => new vm.SyntheticModule(Object.keys(namespace), function () {
          for (const key of Object.keys(namespace)) this.setExport(key, namespace[key]);
        }, { context: this.context, identifier: specifier })));
      return this.packageModules.get(specifier);
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(typeboxRoot, 'package.json')).resolve('typebox'));
      assert.ok(inside(typeboxRoot, file));
      return this.namespace(file, { package: 'typebox', version: '1.3.37', path: relative(typeboxRoot, file) });
    }
    if (specifier === 'yaml') {
      const file = realpathSync(createRequire(join(this.yaml.root, 'package.json')).resolve('yaml'));
      assert.ok(inside(this.yaml.root, file));
      return this.namespace(file, { package: 'yaml', version: '2.9.1', path: relative(this.yaml.root, file) });
    }
    if (specifier.startsWith('@openclaw/fs-safe/')) {
      const file = realpathSync(this.fsRequire.resolve(specifier));
      const pkg = this.fsPackages[0];
      assert.ok(inside(pkg.root, file));
      const artifact = pkg.files.find(row => row.path === relative(pkg.root, file));
      assert.ok(artifact, file);
      assert.equal(hash(readFileSync(file)), artifact.sha256);
      return this.namespace(file, { package: pkg.package, version: pkg.version, path: artifact.path });
    }
    const owner = relative(this.root, parent.identifier);
    let file;
    if (specifier === '@openclaw/normalization-core') file = 'packages/normalization-core/src/index.ts';
    else if (specifier.startsWith('@openclaw/normalization-core/'))
      file = 'packages/normalization-core/src/' + specifier.slice('@openclaw/normalization-core/'.length) + '.ts';
    else if (specifier === '@openclaw/media-core/mime') file = 'packages/media-core/src/mime.ts';
    else {
      assert.ok(specifier.startsWith('.'), owner + ': ' + specifier);
      file = relative(this.root, resolve(dirname(parent.identifier), specifier)).replace(/\.js$/, '.ts');
    }
    if (services[file]) return this.binding(file, 'explicit-named-owner-service', services[file]);
    if (uncalled[file]) {
      const code = uncalled[file].map(name => `export function ${name}(){__deferredCalls.push(${JSON.stringify(file + ':' + name)});throw Error('Uncalled source import invoked');}`).join('\n');
      return this.binding(file, 'throwing-uncalled-import-edge', code);
    }
    return this.module(file);
  }

  async load(file) {
    const mod = this.module(file);
    if (mod.status === 'unlinked') await mod.link((specifier, parent) => this.link(specifier, parent));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 1000 });
    assert.equal(mod.status, 'evaluated');
    return mod.namespace;
  }

  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
}

function tree() {
  return readdirSync(fixtureRoot, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile()).map(entry => {
      const file = join(entry.parentPath, entry.name), bytes = readFileSync(file);
      assert.ok(Buffer.from(bytes.toString('utf8')).equals(bytes), 'Ordinary text fixture');
      return { path: relative(fixtureRoot, file), content: bytes.toString('utf8'),
        bytes: bytes.length, sha256: hash(bytes) };
    }).sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
}

function assertListStats(result) {
  for (const skill of result.details.skills ?? []) {
    const root = join(fixtureRoot, 'workshop-skills', skill.name);
    const stats = skill.files.map(file => statSync(join(root, file)));
    assert.equal(skill.sizeBytes, stats.reduce((sum, value) => sum + value.size, 0));
    assert.equal(skill.updatedAtMs, Math.trunc(Math.max(...stats.map(value => value.mtimeMs))));
  }
}

export async function captureSkillWorkshop(sourceRoot = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(sourceRoot);
  assert.equal(root, fixedRoot);
  assert.equal(existsSync(fixtureRoot), false, 'Fixture must be absent; never overwrite another run');
  const before = verifyCheckout(root);
  const harness = new WorkshopHarness(root, before.files);
  harness.context.__factory = await harness.load(factory);
  harness.context.__config = await harness.load('src/skills/workshop/config.ts');
  const constructors = plain(harness.run(`(()=>{
    const defaults={};
    const custom={skills:{workshop:{maxSkillBytes:8192,autonomous:{mode:'off',channelNotices:true}}}};
    const inputs=[{id:'default',config:defaults,agentId:'agent292'},
      {id:'custom',config:custom,agentId:'agent292'},
      {id:'foreground',config:custom,agentId:'agent292',sessionKey:'  agent:agent292:source  ',runId:'  run292  '}];
    globalThis.__tool=__factory.createConfiguredSkillWorkshopTool(inputs[2]);
    return inputs.map(input=>{const tool=__factory.createConfiguredSkillWorkshopTool(input);return {id:input.id,input,
      definition:{name:tool.name,label:tool.label,displaySummary:tool.displaySummary,description:tool.description,
        parameters:tool.parameters,outputSchemaDeclared:Object.hasOwn(tool,'outputSchema'),executePresent:typeof tool.execute==='function'}};});
  })()`));
  const configurations = plain(harness.run(`[
    {id:'default',result:__config.resolveSkillWorkshopConfig({})},
    {id:'custom',result:__config.resolveSkillWorkshopConfig({skills:{workshop:{maxSkillBytes:8192,autonomous:{mode:'off',channelNotices:true}}}})}
  ]`));
  const observations = [];
  const executionWindows = [];
  const versionIds = [], changeIds = [];
  const versionsByRow = new Map();
  const versionTimes = new Map();
  let lastVersionTime = -1;
  mkdirSync(fixtureRoot);
  try {
    for (const input of skillWorkshopVectors()) {
      const args = { ...input.args };
      if (input.versionFrom) {
        assert.ok(versionsByRow.has(input.versionFrom), input.versionFrom);
        args.version = versionsByRow.get(input.versionFrom);
      }
      const argsBefore = plain(args);
      harness.context.__serialized = JSON.stringify(args);
      harness.run('globalThis.__args=JSON.parse(__serialized)');
      const startedAtMs = Date.now();
      const result = plain(await harness.run('__tool.execute("source292",__args)'));
      const endedAtMs = Date.now();
      executionWindows.push({ id: input.id, startedAtMs, endedAtMs });
      const argsAfter = plain(harness.context.__args);
      assert.deepEqual(argsAfter, argsBefore);
      const change = result.details.change;
      if (change) {
        assert.match(change.id, /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/);
        assert.ok(!changeIds.includes(change.id));
        assert.ok(change.createdAtMs >= startedAtMs && change.createdAtMs <= endedAtMs);
        changeIds.push(change.id);
        assert.deepEqual(plain(harness.context.__ledger.at(-1)), change);
        if (change.versionId) {
          const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3})Z-(patch|write_file|remove_file|archive|restore)$/.exec(change.versionId);
          assert.ok(match, change.versionId);
          const time = Date.UTC(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6], +match[7]);
          assert.ok(time > lastVersionTime);
          assert.ok(time >= startedAtMs && time <= Math.max(endedAtMs, lastVersionTime + 1));
          lastVersionTime = time;
          versionTimes.set(change.versionId, time);
          versionIds.push(change.versionId);
          versionsByRow.set(input.id, change.versionId);
        }
      }
      if (input.args.action === 'list') {
        assertListStats(result);
        for (const archived of result.details.archived) for (const version of archived.versions)
          assert.equal(version.createdAtMs, versionTimes.get(version.id));
      }
      observations.push({ id: input.id, argumentsBefore: argsBefore, argumentsAfter: argsAfter,
        result, tree: tree(), serviceCallsThrough: plain(harness.context.__services).length });
    }
    assert.equal(versionIds.length, 8);
    assert.equal(changeIds.length, 10);
    assert.deepEqual(plain(harness.context.__deferredCalls), []);
    writeFileSync(rawReceipt, JSON.stringify({ referencePin: SKILL_WORKSHOP_PIN,
      capturedAt: new Date().toISOString(), constructors, configurations, observations,
      changeLedger: plain(harness.context.__ledger), services: plain(harness.context.__services),
      executionWindows, versionTimes: Object.fromEntries(versionTimes), actualRelationshipsChecked: true }, null, 2) + '\n');
  } finally {
    harness.context.__admission.active = false;
    rmSync(fixtureRoot, { recursive: true });
  }
  const versions = new Map(versionIds.map((id, index) => [id,
    `version-${String(index + 1).padStart(2, '0')}-${id.slice(id.indexOf('Z-') + 2)}`]));
  const changes = new Map(changeIds.map((id, index) => [id, `change-${String(index + 1).padStart(2, '0')}`]));
  const replace = value => {
    if (typeof value === 'string') {
      let result = value.split(fixtureRoot).join('$FIXTURE');
      for (const [raw, symbol] of [...versions, ...changes]) result = result.split(raw).join(symbol);
      return result;
    }
    if (Array.isArray(value)) return value.map(replace);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => {
      if (key === 'createdAtMs') {
        const symbol = versions.get(value.id) ?? changes.get(value.id);
        assert.ok(symbol, 'Every normalized timestamp has a correlated source identity');
        return [key, symbol + '::time'];
      }
      if (key === 'updatedAtMs') { assert.ok(Number.isInteger(item)); return [key, '$LIVE_TREE_MTIME']; }
      return [key, replace(item)];
    }));
    return value;
  };
  const after = verifyCheckout(root);
  assert.deepEqual(before.receipt, after.receipt);
  const constantSources = [
    ['src/skills/workshop/skill-versions.ts', /const WORKSHOP_CHANGE_ACTIONS = \[[\s\S]*?\] as const;/],
    ['src/skills/workshop/skill-versions.ts', /const MAX_VERSIONS_PER_SKILL = 10;/],
    ['src/skills/lifecycle/workspace-skill-write.ts', /const ALLOWED_SUPPORT_FILE_ROOTS = new Set\([\s\S]*?\);/],
    ['src/skills/lifecycle/workspace-skill-write.ts', /export const MAX_WORKSPACE_SKILL_SUPPORT_FILE_BYTES = 256 \* 1024;/],
  ].map(([path, pattern]) => {
    const source = readFileSync(join(root, path), 'utf8'), matched = pattern.exec(source);
    assert.ok(matched, path + ': constant declaration');
    const startByte = Buffer.byteLength(source.slice(0, matched.index));
    return { path, startByte, endByte: startByte + Buffer.byteLength(matched[0]),
      originalDeclaration: matched[0], sha256: hash(matched[0]) };
  });
  return {
    schemaVersion: 1, referencePin: SKILL_WORKSHOP_PIN,
    exporter: { path: 'scripts/openclaw/capture-skill-workshop.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    sourceRecords: [...harness.sourceRecords.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
    constantSources,
    ownerBindings: [...harness.bindings.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
    packageExports: [...harness.packageExports.values()].sort((a, b) => (a.package + '/' + a.path).localeCompare(b.package + '/' + b.path)),
    packageLicensing: [...harness.packageLicensing.values()].sort((a, b) => a.package.localeCompare(b.package)),
    typebox: { version: '1.3.37', root: typeboxRoot, files: harness.typeboxFiles },
    yaml: { ...harness.yaml, artifactReceipt: { path: yamlReceipt, sha256: harness.yamlReceiptHash } },
    fsSafe: { artifactReceipt: { path: fsSafeReceipt, sha256: harness.fsReceiptHash }, packages: harness.fsPackages,
      nativeBindingLoaded: Boolean(harness.fsRequire.cache[join(harness.fsPackages[1].root, 'fs-safe-native.node')]),
      nativeObservationLimit: 'Addon require-cache presence observes loading, not individual native primitive execution.',
      namespaceBoundary: 'Unchanged official package graph executes in the actual host Node loader; no file-operation stand-in.' },
    normalization: { rawReceipt, actualRelationshipsChecked: true, versionSymbols: [...versions.values()],
      rule: 'Actual UUIDs are checked unique and correlated with captured changes; version IDs/time/order and live listing stat metadata are checked before replacing paths, change/version identities, createdAtMs and mtime with explicit symbols. Raw complete outputs, IDs and times remain in the temporary receipt. Date/crypto/filesystem algorithms are unchanged.' },
    constructors: replace(constructors), configurations, observations: replace(observations),
    changeLedger: replace(plain(harness.context.__ledger)), services: replace(plain(harness.context.__services)),
    deferredCalls: plain(harness.context.__deferredCalls), fixtureRemoved: !existsSync(fixtureRoot),
    boundaries: { actualFactory: true, actualSchema: true, actualLibrary: true, actualVersionAlgorithms: true,
      actualFileAlgorithms: true, actualValidationAndLint: true, actualYamlParser: true,
      actualPinnedFsSafeExports: true, sourceDatabaseExecuted: false, discoveryExecuted: false,
      hooksExecuted: false, usagePersistenceExecuted: false, hostProductExecuted: false,
      learningSchedulerExecuted: false, networkExecuted: false },
    limits: [
      'Whole unchanged pinned factory/schema/library/version and reached parsing/formatting/lint/scan/file algorithms execute after official TypeScript-only transformation. Source originals, constants, license and complete tracked before/after bytes are recorded.',
      'Named AgentDir/workspace, committed change sink, discovery notification, usage, logger/hooks and trusted admitted-fixture source ownership are explicit captured service bindings. Their source SQL/storage, discovery, security/permission authority, hooks, learning scheduler and host product are not qualified. This array is an observation sink, not a second database.',
      'Foreground default/custom constructors and ordinary list/view/create/patch/write_file/remove_file/archive/restore only. No review policy, negative/error/failure/security/permission/authTLS/cancel/crash/mixed/budget/truncation/eviction/provider tests; eight saved versions do not exercise pruning.',
      'Only nondeterministic identities, absolute fixture paths, wall-clock timestamps and filesystem mtimes are symbolically normalized after actual relationship checks. Raw complete source outputs and identity/time correlations remain in the separate temporary receipt.',
      'Actual fs-safe0.26.8 and yaml2.9.1 artifacts are fully hash-verified from existing official receipts. TypeBox1.3.37 package files and licenses are inventoried; host namespace imports execute original package graphs. Package inventory does not claim every package function/native primitive executed.',
    ],
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 4, 'usage: capture-skill-workshop.mjs source-root output');
  const captured = await captureSkillWorkshop(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(captured, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ observations: captured.observations.length,
    wholeModules: captured.sourceRecords.filter(row => row.executed).length,
    savedVersions: captured.normalization.versionSymbols.length,
    nativeBindingLoaded: captured.fsSafe.nativeBindingLoaded, fixtureRemoved: captured.fixtureRemoved }) + '\n');
}
