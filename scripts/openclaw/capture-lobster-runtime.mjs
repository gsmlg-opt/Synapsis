// Ordinary pure-runtime oracle from complete unchanged, lock-verified modules.
// Custom source streams and command-run observations are explicit harness code.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import path, { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const integrity = 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==';
const digest = (bytes, algorithm = 'sha256', encoding = 'hex') => createHash(algorithm).update(bytes).digest(encoding);
const plain = value => JSON.parse(JSON.stringify(value));
const nativeRequire = createRequire(import.meta.url);
const sourcePaths = [
  'command_tokens.js', 'commands/stdlib/ask.js', 'commands/stdlib/head.js',
  'commands/stdlib/json.js', 'commands/stdlib/pick.js', 'input_request.js',
  'parser.js', 'renderers/json.js', 'runtime.js', 'state/atomic_file.js',
  'state/store.js', 'validation.js',
].map(name => 'package/dist/src/' + name);
const recipes = [
  { id: 'lazy-head-one', pipeline: 'fixture_source | head --n 1 | json', input: [], sourceItems: [{ id: 1, label: '一' }, { id: 2, label: '二' }] },
  { id: 'lazy-head-zero', pipeline: 'fixture_source | head --n 0 | json', input: [], sourceItems: [{ id: 1, label: '一' }, { id: 2, label: '二' }] },
  { id: 'pure-pick', pipeline: 'pick id,label | json', input: [{ id: 1, label: '一', extra: true }, { id: 2, label: '二', extra: false }] },
  { id: 'ask-same-stage', pipeline: 'fixture_source | ask --prompt \'Review\' --schema \'{"type":"string"}\' --subject-from-stdin | json', input: [], sourceItems: ['draft'], resume: { mode: 'same_stage', response: 'continue' } },
  { id: 'ask-emit-next-stage', pipeline: 'ask --prompt \'Review\' --schema \'{"type":"boolean"}\' --emit | json', input: ['draft'], resume: { mode: 'next_stage', response: true } },
  { id: 'json-renderer', pipeline: 'pick id,label | json', input: [{ id: 1, label: '一', extra: true }], renderOutput: true },
  { id: 'ask-known-array', pipeline: 'ask --prompt \'Review\' --schema \'{"type":"string"}\' --subject-from-stdin | json', input: ['draft'], resume: { mode: 'same_stage', response: 'continue' } },
];

function archiveFiles(archive) {
  const encoded = JSON.parse(execFileSync('python3', ['-c',
    'import tarfile,json,base64,sys\nwith tarfile.open(sys.argv[1],"r:gz") as t:\n print(json.dumps({m.name:base64.b64encode(t.extractfile(m).read()).decode() for m in t.getmembers() if m.isfile() and not m.name.endswith(".map")}))', archive],
    { maxBuffer: 64 * 1024 * 1024 }).toString());
  return new Map(Object.entries(encoded).map(([name, value]) => [name, Buffer.from(value, 'base64')]));
}

class RuntimeCapture {
  constructor(files, packages) {
    this.files = files; this.packages = packages;
    // Ajv's actual compiler requires string code generation. This is trusted
    // pinned-source execution, not a sandbox claim or hostile plugin loader.
    this.context = vm.createContext({ Buffer, console, URL, TextEncoder, TextDecoder }, { codeGeneration: { strings: true, wasm: false } });
    this.modules = new Map(); this.commonjs = new Map(); this.dependencies = new Map(); this.nativeImports = new Set();
  }
  dependency(request, importer) {
    if (builtinModules.includes(request) || request.startsWith('node:')) {
      this.nativeImports.add(request); return nativeRequire(request);
    }
    let name, relative;
    if (request.startsWith('.')) {
      name = importer.name;
      relative = path.posix.normalize(path.posix.join(path.posix.dirname(importer.relative), request));
    } else {
      const parts = request.split('/'); name = parts.shift(); relative = parts.join('/');
    }
    const pkg = this.packages.get(name); assert.ok(pkg, `unrecorded dependency ${request}`);
    if (!relative) relative = pkg.metadata.main || 'index.js';
    const candidate = [relative, relative + '.js', relative + '.json', relative + '/index.js'].find(file => pkg.files.has('package/' + file));
    assert.ok(candidate, `dependency file missing ${name}/${relative}`);
    const id = name + '/' + candidate;
    if (this.commonjs.has(id)) return this.commonjs.get(id).exports;
    const bytes = pkg.files.get('package/' + candidate);
    const module = { exports: {}, filename: '/reference/node_modules/' + id, children: [], parent: null };
    this.commonjs.set(id, module);
    this.dependencies.set(id, { path: id, sha256: digest(bytes), wholeModule: true, executed: !candidate.endsWith('.json'), kind: candidate.endsWith('.json') ? 'json-data' : 'commonjs' });
    if (candidate.endsWith('.json')) module.exports = JSON.parse(bytes.toString('utf8'));
    else {
      const source = '(function(exports,require,module,__filename,__dirname){\n' + bytes.toString('utf8') + '\n})';
      const factory = new vm.Script(source, { filename: id }).runInContext(this.context, { timeout: 5000 });
      const require = requested => this.dependency(requested, { name, relative: candidate });
      this.context.__cjsFactory = factory;
      this.context.__cjsArguments = [module.exports, require, module, module.filename, path.posix.dirname(module.filename)];
      new vm.Script('__cjsFactory(...__cjsArguments)').runInContext(this.context, { timeout: 5000 });
    }
    return module.exports;
  }
  source(id) {
    assert.ok(sourcePaths.includes(id), `unrecorded source module ${id}`);
    if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(this.files.get(id).toString('utf8'), { context: this.context, identifier: id }));
    return this.modules.get(id);
  }
  async link(specifier, importer) {
    if (specifier.startsWith('.')) return this.source(path.posix.normalize(path.posix.join(path.posix.dirname(importer.identifier), specifier)));
    const id = 'binding:' + specifier;
    if (!this.modules.has(id)) {
      let exports;
      if (specifier === 'ajv') exports = { Ajv: this.dependency('ajv') };
      else {
        assert.ok(specifier.startsWith('node:'), `unrecorded import ${specifier}`);
        this.nativeImports.add(specifier); exports = await import(specifier);
      }
      const names = Object.keys(exports);
      this.modules.set(id, new vm.SyntheticModule(names, function () {
        for (const name of names) this.setExport(name, exports[name]);
      }, { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  async exported(relative, name) {
    const module = this.source('package/dist/src/' + relative);
    if (module.status === 'unlinked') await module.link((specifier, importer) => this.link(specifier, importer));
    if (module.status === 'linked') await module.evaluate({ timeout: 5000 });
    return module.namespace[name];
  }
  async run(recipe) {
    const runPipeline = await this.exported('runtime.js', 'runPipeline');
    const parsePipeline = await this.exported('parser.js', 'parsePipeline');
    const commands = [];
    for (const name of ['ask', 'head', 'pick', 'json']) commands.push(await this.exported('commands/stdlib/' + name + '.js', name + 'Command'));
    const pipeline = parsePipeline(recipe.pipeline);
    const execute = async (stages, input, requestInputResume) => {
      const trace = [], chunks = [];
      const source = { name: 'fixture_source', meta: {}, async run() {
        return { output: (async function* () {
          for (const item of plain(recipe.sourceItems)) {
            trace.push('pull:' + (typeof item === 'string' ? item : item.id)); yield item;
          }
        })() };
      } };
      const registry = new Map([...commands, source].map(command => [command.name, {
        ...command, run: async params => { trace.push('run:' + command.name); return command.run(params); },
      }]));
      const renderOutput = recipe.renderOutput === true;
      const options = {
        pipeline: stages, registry, input, mode: 'tool', renderOutput,
        stdin: { isTTY: false }, stdout: { write(value) { chunks.push(String(value)); } }, stderr: { write() {} },
        env: {}, ...(requestInputResume ? { requestInputResume } : {}),
      };
      const output = await finite(runPipeline(options));
      const result = {
        items: plain(output.items), halted: output.halted,
        haltedAt: output.haltedAt ? { index: output.haltedAt.index, name: output.haltedAt.stage.name, inPlace: output.haltedAt.inPlace === true } : null,
        executionStarted: output.executionStarted, rendered: output.rendered, renderedItems: plain(output.renderedItems),
        ...(renderOutput ? { stdout: chunks.join('') } : {}),
      };
      return { trace, result, output };
    };
    const first = await execute(pipeline, plain(recipe.input));
    const runs = [{ trace: first.trace, result: first.result }];
    if (recipe.resume) {
      const request = first.output.items[0]; assert.equal(request.type, 'input_request');
      const same = recipe.resume.mode === 'same_stage';
      const remaining = pipeline.slice(first.output.haltedAt.index + (same ? 0 : 1));
      const next = await execute(remaining, same ? request.items : [plain(recipe.resume.response)], same ? { state: request.commandInput, response: plain(recipe.resume.response) } : undefined);
      runs.push({ trace: next.trace, result: next.result });
    }
    return { ...plain(recipe), runs };
  }
}

async function finite(operation) {
  let timer;
  try { return await Promise.race([operation, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ordinary runtime capture deadline exceeded')), 5000); })]); }
  finally { clearTimeout(timer); }
}

export async function captureLobsterRuntime({ referenceRoot, archive, dependencies }) {
  const git = args => execFileSync('git', ['-C', referenceRoot, ...args], { maxBuffer: 32 * 1024 * 1024 });
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), pin);
  const referenceRecords = ['extensions/lobster/package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'package.json'].map(path => {
    const bytes = readFileSync(resolve(referenceRoot, path)); assert.deepEqual(bytes, git(['show', `${pin}:${path}`]));
    return { path, sha256: digest(bytes) };
  });
  const lock = readFileSync(resolve(referenceRoot, 'pnpm-lock.yaml'), 'utf8');
  assert.ok(lock.includes(`'@clawdbot/lobster@2026.9.16':\n    resolution: {integrity: ${integrity}}`));
  assert.equal(JSON.parse(readFileSync(resolve(referenceRoot, 'extensions/lobster/package.json'))).dependencies['@clawdbot/lobster'], '2026.9.16');
  assert.equal('sha512-' + digest(readFileSync(archive), 'sha512', 'base64'), integrity);
  const files = archiveFiles(archive), metadata = JSON.parse(files.get('package/package.json'));
  assert.equal(metadata.name, '@clawdbot/lobster'); assert.equal(metadata.version, '2026.9.16');
  const packages = new Map();
  const pinned = { ajv: '8.20.0', 'fast-uri': '4.2.2', 'fast-deep-equal': '3.1.3', 'json-schema-traverse': '1.0.0', 'require-from-string': '2.0.2' };
  const rows = JSON.parse(readFileSync(dependencies)); assert.equal(rows.length, Object.keys(pinned).length);
  for (const row of rows) {
    assert.equal(pinned[row.name], row.version); assert.ok(!packages.has(row.name));
    assert.equal('sha512-' + digest(readFileSync(row.archive), 'sha512', 'base64'), row.integrity);
    assert.ok(lock.includes(`  ${row.name}@${row.version}:\n    resolution: {integrity: ${row.integrity}}`));
    const dependencyFiles = archiveFiles(row.archive), metadata = JSON.parse(dependencyFiles.get('package/package.json'));
    assert.equal(metadata.name, row.name); assert.equal(metadata.version, row.version);
    const licensePath = [...dependencyFiles.keys()].find(path => /^package\/licen[sc]e(?:\.txt|\.md)?$/i.test(path)); assert.ok(licensePath, row.name);
    packages.set(row.name, { files: dependencyFiles, metadata, record: {
      name: row.name, version: row.version, integrity: row.integrity, installed: false,
      packageJsonSha256: digest(dependencyFiles.get('package/package.json')),
      license: { path: licensePath, sha256: digest(dependencyFiles.get(licensePath)), text: dependencyFiles.get(licensePath).toString('utf8') },
    } });
  }
  assert.ok(lock.includes('  ajv@8.20.0:\n    dependencies:\n      fast-deep-equal: 3.1.3\n      fast-uri: 4.2.2\n      json-schema-traverse: 1.0.0\n      require-from-string: 2.0.2'));
  assert.equal(JSON.parse(readFileSync(resolve(referenceRoot, 'package.json'))).dependencies['fast-uri'], '4.2.2');
  assert.ok(readFileSync(resolve(referenceRoot, 'pnpm-workspace.yaml'), 'utf8').includes('\n  fast-uri: 4.2.2\n'));
  const cases = [], dependencyFiles = new Map(), nativeImports = new Set();
  for (const recipe of recipes) {
    const capture = new RuntimeCapture(files, packages); cases.push(await capture.run(recipe));
    for (const [path, record] of capture.dependencies) dependencyFiles.set(path, record);
    for (const native of capture.nativeImports) nativeImports.add(native);
    for (const path of sourcePaths) assert.equal(capture.modules.get(path)?.status, 'evaluated', path);
  }
  return {
    referencePin: pin, referenceRecords,
    sourcePackage: { name: metadata.name, version: metadata.version, integrity, installed: false, packageJsonSha256: digest(files.get('package/package.json')) },
    executedWorkflowRuntime: true, productionCatalogInstalled: false,
    checkpointPersistenceExecuted: false, fullToolRuntimeExecuted: false, nativeToolExecution: false,
    sourceRecords: sourcePaths.map(path => ({ path, sha256: digest(files.get(path)), wholeModule: true, executed: true })),
    dependencies: [...packages.values()].map(pkg => pkg.record).sort((a, b) => a.name.localeCompare(b.name)),
    dependencyFiles: [...dependencyFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
    nativeImports: [...nativeImports].sort(),
    harness: { path: 'scripts/openclaw/capture-lobster-runtime.mjs', sha256: digest(readFileSync(fileURLToPath(import.meta.url))), stringCodeGeneration: 'actual Ajv compiler', sourceStream: 'explicit async-generator fixture', observations: 'wrappers record real command.run order; source fixture records each yield', resume: 'explicit recipe slices remaining pipeline and supplies state/response as fixed tool runtime does; no persistence' },
    license: { path: 'package/LICENSE', sha256: digest(files.get('package/LICENSE')), text: files.get('package/LICENSE').toString('utf8') },
    cases,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, dependencies, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && dependencies && output, 'provide referenceRoot archive dependencies output');
  writeFileSync(output, JSON.stringify(await captureLobsterRuntime({ referenceRoot, archive, dependencies }), null, 2) + '\n');
}
