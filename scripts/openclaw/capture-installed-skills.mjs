// Whole unchanged installed-Skills factory/read/search with explicit supplied owner inputs.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto, { createHash } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import fsPromises from 'node:fs/promises';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import path, { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const INSTALLED_SKILLS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const fixedTypebox = '/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox';
const fsSafeRuntime = '/tmp/synapsis-skills290-source-runtime';
const fsSafeArtifacts = '/tmp/synapsis-skills290-evidence/source-runtime-artifacts.json';
const localFixtureRoot = '/tmp/synapsis-skills290-source-local-fixture';
const localFixturePath = join(localFixtureRoot, 'SKILL.md');
const localFixtureContent = '---\nname: local-guide\ndescription: Operations\n---\n\nUse kestrel deployment. Keep the entire rollback procedure.\n';
const factory = 'src/agents/tools/installed-skill-tools.ts';
const availability = 'src/agents/agent-tool-availability.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, path) => path === root || path.startsWith(root + sep);

const wholeSources = [
  factory, availability, 'src/agents/installed-skill-catalog.ts',
  'src/agents/tool-search-ranking.ts', 'src/agents/tool-search-index.ts',
  'src/agents/code-mode-skills.ts', 'src/agents/skill-instruction-result.ts',
  'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
  'src/agents/tool-input-error.ts', 'src/param-key.ts',
  'src/infra/lru-cache.ts', 'src/infra/abort-signal.ts', 'src/infra/fs-safe.ts', 'packages/retry/src/index.ts',
  ...['record-coerce', 'number-coercion', 'string-coerce', 'string-normalization']
    .map(name => `packages/normalization-core/src/${name}.ts`),
];

// Exact imports not called by these ordinary cases. Called factory, parameter,
// result, availability, ranking, cache, read and formatting algorithms stay whole.
const uncalledEdges = [
  [availability, './tool-effect-receipt.js', 'src/agents/tool-effect-receipt.ts', ['markToolExecutionRefused']],
  [availability, './tool-policy-shared.js', 'src/agents/tool-policy-shared.ts', ['createToolExecutionMatcher']],
  ['src/agents/code-mode-skills.ts', '../skills/loading/skill-prompt-catalog.js',
    'src/skills/loading/skill-prompt-catalog.ts', ['parseSkillsPromptCatalog']],
  ['src/agents/tools/common.ts', '@openclaw/media-core/mime', 'packages/media-core/src/mime.ts', ['detectMime']],
];

export function installedSkillsVectors() {
  const inline = (name, description, content, extra = {}) => ({
    name, description, content, mode: 'inline', location: `supplied://skills/${name}`, ...extra,
  });
  const opaque = (name, description, content, extra = {}) => ({
    name, description, content, mode: 'opaque-reader', location: `supplied://remote/${name}`, ...extra,
  });
  return [
    { id: 'body-only-inline', entries: [inline('guide', 'Operations', 'Use canary deployment. Keep rollback instructions whole.')],
      searches: [{ query: '  canary  ' }], reads: [{ name: 'guide' }] },
    // Without metadata's multiplier2 the shorter body's signal wins instead.
    { id: 'metadata-weight-two', entries: [inline('alpha', 'signal', 'ordinary'), inline('beta', '', 'signal')],
      searches: [{ query: 'signal' }] },
    // Opaque owners participate in metadata N/df/average, never the body population.
    { id: 'separate-populations', entries: [
      inline('alpha', 'signal', 'ordinary'), inline('beta', '', 'signal'),
      opaque('gamma', 'signal', 'Remote whole instructions'),
      opaque('delta', 'signal', 'Remote whole instructions'),
      opaque('epsilon', 'signal', 'Remote whole instructions'),
    ], searches: [{ query: 'signal' }] },
    { id: 'exact-name', entries: [inline('rival', 'guide guide guide', 'guide guide guide'),
      inline('guide', 'Operations', 'ordinary')], searches: [{ query: 'guide' }] },
    { id: 'duplicate-source-names', entries: [
      inline('same', 'signal', 'First complete instructions', { location: 'supplied://first/same' }),
      inline('same', 'signal', 'Second complete instructions', { location: 'supplied://second/same' }),
    ], searches: [{ query: 'signal' }], reads: [{ name: 'same' }] },
    { id: 'repeated-bounded-owner', entries: [{ name: 'owner-guide', description: 'Operations',
      location: 'supplied://owner/guide', mode: 'bounded-reader',
      content: 'Canary deployment. Preserve the complete rollback procedure.' }],
      searches: [{ query: 'canary', limit: 5 }, { query: 'rollback' }, { query: 'canary' }],
      reads: [{ name: 'owner-guide' }] },
    { id: 'opaque-owner-metadata-and-read', entries: [opaque('remote-guide', 'Operations reference',
      'Whole remote instructions remain owned by the supplied reader.')],
      searches: [{ query: 'operations' }], reads: [{ name: 'remote-guide' }] },
    { id: 'location-note-whole-inert-read', entries: [inline('portable-guide', 'Portable instructions',
      '# Guide\n\nLiteral $(touch /tmp/installed-skills-source-oracle) stays inert.\nFinal instruction.\n', {
        location: 'workspace-skill://workspace/portable/SKILL.md', locationNote: 'Resources belong to the supplied workspace.',
        promptListed: true,
      })], searches: [{ query: 'instruction' }], reads: [{ name: '  portable-guide  ' }] },
    { id: 'ordinary-local-prefix-and-whole-read', entries: [{ name: 'local-guide', description: 'Operations',
      content: localFixtureContent, mode: 'local-file', location: localFixturePath }],
      searches: [{ query: 'kestrel' }], reads: [{ name: 'local-guide' }] },
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), INSTALLED_SKILLS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', INSTALLED_SKILLS_PIN])
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
  const tree = git(root, ['rev-parse', `${INSTALLED_SKILLS_PIN}^{tree}`]);
  assert.equal(tree, '47509a47273231ab15f57252960fe716d7379ffb');
  return { files: new Map(files.map(row => [row.path, row])), receipt: {
    commit: INSTALLED_SKILLS_PIN, tree, trackedClean: true, verifiedTrackedFiles: files.length,
    filesSha256: hash(JSON.stringify(files)),
  } };
}

class InstalledSkillsHarness {
  constructor(root, tracked) {
    this.root = root;
    this.tracked = tracked;
    this.modules = new Map();
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.dependencies = new Map();
    this.packageModules = new Map();
    this.fsSafeRequire = createRequire(join(fsSafeRuntime, 'package.json'));
    const artifactBytes = readFileSync(fsSafeArtifacts);
    const artifacts = JSON.parse(artifactBytes);
    this.fsSafePackages = artifacts.packages;
    assert.deepEqual(this.fsSafePackages.map(pkg => [pkg.package, pkg.version]),
      [['@openclaw/fs-safe', '0.26.8'], ['@openclaw/fs-safe-linux-x64-gnu', '0.26.8']]);
    for (const pkg of this.fsSafePackages) {
      assert.equal(pkg.root, join(fsSafeRuntime, 'node_modules', pkg.package));
      const manifest = JSON.parse(readFileSync(join(pkg.root, 'package.json'), 'utf8'));
      assert.equal(manifest.name, pkg.package);
      assert.equal(manifest.version, pkg.version);
      assert.ok(readFileSync(join(root, 'pnpm-lock.yaml'), 'utf8').includes(pkg.integrity));
      for (const file of pkg.files) {
        const bytes = readFileSync(join(pkg.root, file.path));
        assert.equal(bytes.length, file.bytes, file.path);
        assert.equal(hash(bytes), file.sha256, file.path);
      }
    }
    this.fsSafeReceipt = { path: fsSafeArtifacts, sha256: hash(artifactBytes) };
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, setTimeout, clearTimeout,
      __platform: { crypto, fsPromises, path }, __deferredCalls: [],
    }, { codeGeneration: { strings: false, wasm: false } });
    const packageJson = join(fixedTypebox, 'package.json');
    this.typeboxRoot = realpathSync(fixedTypebox);
    const pkg = JSON.parse(readFileSync(packageJson, 'utf8'));
    assert.equal(pkg.name, 'typebox');
    assert.equal(pkg.version, '1.3.37');
    const resolved = realpathSync(createRequire(join(root, 'package.json')).resolve('typebox'));
    assert.ok(inside(this.typeboxRoot, resolved));
    this.typeboxEntry = resolved;
    this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: hash(readFileSync(packageJson)) });
  }

  record(path, executed) {
    const tracked = this.tracked.get(path);
    assert.ok(tracked, path);
    const raw = readFileSync(join(this.root, path));
    assert.equal(hash(raw), tracked.sha256, path);
    const previous = this.sourceRecords.get(path);
    if (!previous || executed) this.sourceRecords.set(path, { ...tracked, bytes: raw.length,
      executed, originalSourceExecuted: executed, wholeModule: executed, provenanceOnly: !executed });
    return raw.toString('utf8');
  }

  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    let executable;
    if (inside(this.typeboxRoot, file)) {
      executable = readFileSync(file, 'utf8');
      const path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: hash(executable) });
    } else {
      const path = relative(this.root, file);
      assert.ok(wholeSources.includes(path), path);
      executable = stripTypeScriptTypes(this.record(path, true), { mode: 'transform', sourceMap: false });
      Object.assign(this.sourceRecords.get(path), { transformation, executableSha256: hash(executable) });
    }
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: () => {
        this.context.__deferredCalls.push('dynamic-import');
        throw Error('Undeclared installed-Skills dynamic import');
      },
    });
    this.modules.set(file, mod);
    return mod;
  }

  binding(importer, specifier, record, code) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, ...record });
    if (!this.modules.has(key)) this.modules.set(key,
      new vm.SourceTextModule(code, { context: this.context, identifier: 'binding:' + key }));
    return this.modules.get(key);
  }

  link(specifier, parent) {
    const owner = relative(this.root, parent.identifier);
    if (specifier.startsWith('@openclaw/fs-safe/')) {
      const file = realpathSync(this.fsSafeRequire.resolve(specifier));
      const pkg = this.fsSafePackages[0];
      assert.ok(inside(pkg.root, file));
      const packagePath = relative(pkg.root, file);
      const artifact = pkg.files.find(record => record.path === packagePath);
      assert.ok(artifact, packagePath);
      assert.equal(hash(readFileSync(file)), artifact.sha256);
      this.importBindings.set(owner + ':' + specifier, { importer: owner, specifier,
        kind: 'actual-pinned-package-export-namespace', package: pkg.package, version: pkg.version,
        path: packagePath, sha256: artifact.sha256,
        boundary: 'Whole official ESM graph executes in the host Node loader; unchanged exports cross into the source VM.' });
      if (!this.packageModules.has(file)) this.packageModules.set(file,
        import(pathToFileURL(file).href).then(namespace => new vm.SyntheticModule(Object.keys(namespace), function () {
          for (const name of Object.keys(namespace)) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: file })));
      return this.packageModules.get(file);
    }
    if (specifier === 'typebox' || inside(this.typeboxRoot, parent.identifier)) {
      let file;
      if (specifier === 'typebox') file = this.typeboxEntry;
      else {
        assert.ok(specifier.startsWith('.'), specifier);
        file = realpathSync(resolve(dirname(parent.identifier), specifier));
      }
      assert.ok(inside(this.typeboxRoot, file));
      const key = parent.identifier + ':' + specifier;
      this.importBindings.set(key, { importer: inside(this.typeboxRoot, parent.identifier)
        ? 'typebox/' + relative(this.typeboxRoot, parent.identifier) : owner,
      specifier, kind: 'actual-pinned-package-module', version: '1.3.37',
      path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(readFileSync(file)) });
      return this.module(file);
    }
    const edge = uncalledEdges.find(([importer, imported]) => importer === owner && imported === specifier);
    if (edge) {
      const [, , source, exports] = edge;
      this.record(source, false);
      const code = exports.map(name => `export function ${name}(){__deferredCalls.push(${JSON.stringify({ importer: owner, specifier, export: name })});throw Error('Uncalled installed-Skills import invoked');}`).join('\n');
      return this.binding(owner, specifier, { kind: 'throwing-uncalled-import-edge', source, exports,
        generatedCode: code, generatedSha256: hash(code), originalSourceExecuted: false }, code);
    }
    if (specifier === 'node:crypto' || specifier === 'node:fs/promises' || specifier === 'node:path') {
      const [key, exports] = specifier === 'node:crypto'
        ? ['crypto', ['createHash']] : specifier === 'node:path' ? ['path', []] : ['fsPromises', ['readFile']];
      const code = `export default globalThis.__platform.${key};\n` +
        exports.map(name => `export const ${name}=globalThis.__platform.${key}.${name};`).join('\n');
      return this.binding(owner, specifier, { kind: 'actual-platform-builtin', exports: ['default', ...exports],
        generatedCode: code, generatedSha256: hash(code) }, code);
    }
    const prefix = '@openclaw/normalization-core/';
    const path = specifier.startsWith(prefix)
      ? 'packages/normalization-core/src/' + specifier.slice(prefix.length) + '.ts'
      : relative(this.root, resolve(dirname(parent.identifier), specifier)).replace(/\.js$/, '.ts');
    assert.ok(wholeSources.includes(path), `${owner}: ${specifier}`);
    this.importBindings.set(owner + ':' + specifier, { importer: owner, specifier,
      kind: 'whole-unchanged-source-module', target: path });
    return this.module(join(this.root, path));
  }

  async load(path) {
    const mod = this.module(join(this.root, path));
    if (mod.status === 'unlinked') await mod.link((specifier, parent) => this.link(specifier, parent));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 1000 });
    assert.equal(mod.status, 'evaluated');
    return mod.namespace;
  }

  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
}

// This is explicit supplied resource-owner behavior, not a replacement search/read algorithm.
// Opaque and bounded callbacks return only small fixed strings and record every call.
const observeVector = `(async()=>{
  const calls=[];
  const catalog=__input.entries.map((entry,index)=>{
    const skill={name:entry.name,description:entry.description,location:entry.location,
      source:{filePath:entry.mode==='local-file'?entry.location:'/private/supplied-owner/'+index+'/SKILL.md'},
      ...(entry.locationNote===undefined?{}:{locationNote:entry.locationNote}),
      ...(entry.promptListed===undefined?{}:{promptListed:entry.promptListed})};
    if(entry.mode==='inline')skill.source.readContent=entry.content;
    else if(entry.mode!=='local-file'){
      skill.reader=async params=>{
        calls.push({kind:'whole-reader',index,location:params.location,signalPresent:params.signal!==undefined});
        return entry.content;
      };
      if(entry.mode==='bounded-reader')skill.readSearchContent=async(maxBytes,signal)=>{
        calls.push({kind:'bounded-search-reader',index,maxBytes,signalPresent:signal!==undefined});
        if(Buffer.byteLength(entry.content)>maxBytes)throw Error('Ordinary supplied owner input exceeds declared bound');
        return entry.content;
      };
    }
    return skill;
  });
  const tools=__factory.createInstalledSkillTools(catalog);
  __availability.finalizeAgentToolAvailability(tools);
  const definitions=tools.map(tool=>({name:tool.name,label:tool.label,description:tool.description,
    parameters:tool.parameters,outputSchemaDeclared:Object.hasOwn(tool,'outputSchema'),
    outputSchema:tool.outputSchema??null,executePresent:typeof tool.execute==='function',
    availabilityBindingPresent:__availability.getAgentToolAvailabilityBinding(tool)!==undefined}));
  const search=tools.find(tool=>tool.name==='skills_search');
  const read=tools.find(tool=>tool.name==='skills_read');
  const searches=[];
  for(const [index,args] of __input.searches.entries()){
    const before=JSON.parse(JSON.stringify(args));
    const result=await search.execute(__input.id+'/search/'+index,args);
    searches.push({argumentsBefore:before,argumentsAfter:args,result,ownerCallsAfter:JSON.parse(JSON.stringify(calls))});
  }
  const reads=[];
  for(const [index,args] of (__input.reads??[]).entries()){
    const before=JSON.parse(JSON.stringify(args));
    const result=await read.execute(__input.id+'/read/'+index,args);
    reads.push({argumentsBefore:before,argumentsAfter:args,result,ownerCallsAfter:JSON.parse(JSON.stringify(calls))});
  }
  return {definitions,searches,reads,ownerCalls:calls,argumentsAfter:__input};
})()`;

export async function captureInstalledSkills(sourceRoot = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(sourceRoot);
  assert.equal(root, fixedRoot);
  const before = verifyCheckout(root);
  const harness = new InstalledSkillsHarness(root, before.files);
  harness.context.__factory = await harness.load(factory);
  harness.context.__availability = await harness.load(availability);
  const observations = [];
  mkdirSync(localFixtureRoot);
  try {
    writeFileSync(localFixturePath, localFixtureContent, { flag: 'wx' });
    for (const input of installedSkillsVectors()) {
      harness.context.__serialized = JSON.stringify(input);
      harness.run('globalThis.__input=JSON.parse(__serialized);');
      const observation = plain(await harness.run(observeVector));
      assert.deepEqual(observation.argumentsAfter, input, 'input preserved: ' + input.id);
      observations.push({ ...input, ...observation });
    }
    assert.equal(readFileSync(localFixturePath, 'utf8'), localFixtureContent);
  } finally {
    rmSync(localFixtureRoot, { recursive: true });
  }
  assert.deepEqual(plain(harness.context.__deferredCalls), []);
  const after = verifyCheckout(root);
  assert.deepEqual(before.receipt, after.receipt);
  return {
    schemaVersion: 1, referencePin: INSTALLED_SKILLS_PIN,
    exporter: { path: 'scripts/openclaw/capture-installed-skills.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)) },
    sourceTree: { before: before.receipt, after: after.receipt }, transformation,
    sourceRecords: [...harness.sourceRecords.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0),
    importBindings: [...harness.importBindings.values()],
    typebox: { version: '1.3.37', root: harness.typeboxRoot,
      files: [...harness.dependencies.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0) },
    fsSafe: { artifactReceipt: harness.fsSafeReceipt, packages: harness.fsSafePackages,
      exportNamespaceBoundary: 'Official unchanged export functions, loaded with their actual ESM graph and platform builtins; no IO stand-in.',
      nativeBindingLoaded: Boolean(harness.fsSafeRequire.cache[join(harness.fsSafePackages[1].root, 'fs-safe-native.node')]),
      nativeObservationLimit: 'Native require-cache presence observes addon loading only, not individual native primitive execution.' },
    localFixture: { path: localFixturePath, bytes: Buffer.byteLength(localFixtureContent),
      sha256: hash(localFixtureContent), removedAfterCapture: true },
    suppliedOwnerCode: { code: observeVector, sha256: hash(observeVector),
      boundary: 'Explicit supplied small inline/bounded/opaque owner content plus a task-owned ordinary local file. Local IO uses whole original fs-safe.ts and actual pinned package exports; no remote transport.' },
    observations, deferredCalls: plain(harness.context.__deferredCalls),
    boundaries: { actualFactory: true, actualAvailabilityFinalization: true, actualParameterHelpers: true,
      actualResultHelpers: true, actualCatalog: true, actualRanking: true, actualIndex: true,
      actualLruCache: true, actualCodeModeRead: true, actualInstructionFormatter: true,
      actualReadOwners: false, actualLocalFileRead: true, actualLocalFileWrapper: true,
      actualPinnedFsSafeExports: true, commonFileReadHelperCalled: false, assemblyExecuted: false,
      eligibilityExecuted: false, persistenceExecuted: false, networkExecuted: false },
    deferredVectors: [],
    limits: [
      'Whole unchanged modules execute after TypeScript-only transformation. No source-region extraction or replacement of a called algorithm.',
      'Already eligible catalog inputs are explicitly supplied; discovery, installation, owner assembly, policy admission and persistence do not execute.',
      'Factory schemas and complete source results are captured as source facts; no host schema migration or authority/budget change is inferred.',
      'Actual CodeMode read dispatch runs against supplied owner content. A separate ordinary local vector executes whole fs-safe.ts with actual pinned0.26.8 package exports and genuine Node IO for bounded search and full read. No remote transport or instruction execution is qualified.',
      'All703 official fs-safe artifact files are hash-verified; this inventory does not claim every package module or native primitive executed. Namespace imports execute their actual official host module graph; addon loading is observed separately.',
      'Repeated successful searches retain the same catalog and execute the original body-view cache and abort-race helper without a signal; no cancellation or eviction behavior is qualified.',
      'Only ordinary small successful vectors. No negative/authority/permission/error/failure/cancel/crash/budget/truncation/eviction/real-provider tests.',
    ],
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 4, 'usage: capture-installed-skills.mjs source-root output');
  const captured = await captureInstalledSkills(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(captured, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ vectors: captured.observations.length,
    wholeModules: captured.sourceRecords.filter(row => row.executed).length,
    typeboxFiles: captured.typebox.files.length, deferredVectors: captured.deferredVectors.length }) + '\n');
}
