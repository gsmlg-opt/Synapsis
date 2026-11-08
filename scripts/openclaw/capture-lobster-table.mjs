// Table oracle: copied bounded Collections provenance harness.
// Complete unchanged source/Ajv modules; initial lazy input lifecycle is harness code.
// No public tool runtime, checkpoint persistence, or native tool execution.
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
  'commands/stdlib/table.js',
].map(name => 'package/dist/src/' + name);
const recipes = [
  {
    "id": "false-array-preserves-original-roots",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": false,
    "observeReferences": "items"
  },
  {
    "id": "false-iterator-preserves-original-roots",
    "pipeline": "table",
    "inputKind": "iterator_items",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": false,
    "observeReferences": "items"
  },
  {
    "id": "false-downstream-zero-keeps-input-unopened",
    "pipeline": "table | head --n 0",
    "inputKind": "iterator_items",
    "input": [
      "a",
      "b"
    ],
    "renderOutput": false
  },
  {
    "id": "true-eager-despite-downstream-zero",
    "pipeline": "table | head --n 0",
    "inputKind": "iterator_items",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "empty-iterator-renders-no-results",
    "pipeline": "table",
    "inputKind": "iterator_items",
    "input": [],
    "renderOutput": true
  },
  {
    "id": "empty-array-renders-no-results",
    "pipeline": "table",
    "inputKind": "array",
    "input": [],
    "renderOutput": true
  },
  {
    "id": "sample-twenty-excludes-last-extra-key",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "long",
        "extra": "ignored"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "own-numeric-keys-order-before-insertion-keys",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "10": "ten",
        "2": "two",
        "z": "zee",
        "01": "one"
      },
      {
        "01": "uno",
        "z": "zed",
        "2": "dos",
        "10": "dix"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "utf16-supplementary-header-and-cell-width",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "😀😀": "𐀀𐀀𐀀",
        "k": "x"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "min-three-and-final-column-padding",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "a": "x",
        "b": "y"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "table-header-and-cell-flatten-only-lf",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "h\n\r": "a\nb\rc"
      }
    ],
    "renderOutput": true
  },
  {
    "id": "strings-fallback-keeps-lf-and-cr",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      "a\nb",
      "c\rd"
    ],
    "renderOutput": true
  },
  {
    "id": "arrays-fallback-compact-json",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      [
        1,
        2
      ],
      [
        3
      ]
    ],
    "renderOutput": true
  },
  {
    "id": "numbers-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      1,
      1.25,
      -2
    ],
    "renderOutput": true
  },
  {
    "id": "booleans-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      true,
      false
    ],
    "renderOutput": true
  },
  {
    "id": "null-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      null,
      null
    ],
    "renderOutput": true
  },
  {
    "id": "number-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "n": 1
      },
      {
        "n": 1.25
      },
      {
        "n": -2
      }
    ],
    "renderOutput": true
  },
  {
    "id": "boolean-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "b": true
      },
      {
        "b": false
      }
    ],
    "renderOutput": true
  },
  {
    "id": "null-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "n": null
      },
      {
        "n": null
      }
    ],
    "renderOutput": true
  },
  {
    "id": "array-valued-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "v": [
          1,
          2
        ]
      },
      {
        "v": [
          3
        ]
      }
    ],
    "renderOutput": true
  },
  {
    "id": "object-valued-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "v": {
          "a": 1
        }
      },
      {
        "v": {
          "a": 2
        }
      }
    ],
    "renderOutput": true
  },
  {
    "id": "zero-columns-empty-own-objects",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {},
      {}
    ],
    "renderOutput": true
  },
  {
    "id": "upstream-head-normal-return",
    "pipeline": "head --n 2 | table",
    "inputKind": "iterator_items",
    "input": [
      "a",
      "b",
      "c"
    ],
    "renderOutput": true
  },
  {
    "id": "rendered-empty-generator-feeds-json",
    "pipeline": "table | json",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      }
    ],
    "renderOutput": true
  }
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
    for (const [module, name] of [['ask', 'ask'], ['head', 'head'], ['pick', 'pick'], ['json', 'json'], ['table', 'table']]) {
      commands.push(await this.exported('commands/stdlib/' + module + '.js', name + 'Command'));
    }
    // Retain original roots for strict reference observations before public JSON transport.
    const initialItems = plain(recipe.input);
    const pipeline = parsePipeline(recipe.pipeline);
    const execute = async (stages, input) => {
      const trace = [], chunks = [];
      const counters = { constructors: {}, input: { opens: 0, yields: 0, finishes: 0 } };
      const registry = new Map(commands.map(command => [command.name, {
        ...command, run: async params => {
          trace.push('run:' + command.name);
          counters.constructors[command.name] = (counters.constructors[command.name] ?? 0) + 1;
          return command.run(params);
        },
      }]));
      // This is an initial input fixture, never a production/native command.
      if (recipe.inputKind === 'iterator_items') {
        const items = input;
        input = (async function* () {
          counters.input.opens += 1; trace.push('input:open');
          try {
            for (let index = 0; index < items.length; index++) {
              counters.input.yields += 1; trace.push('input:yield:' + index);
              yield items[index];
            }
          } finally {
            counters.input.finishes += 1; trace.push('input:finally');
          }
        })();
      }
      const renderOutput = recipe.renderOutput === true;
      const output = await finite(runPipeline({
        pipeline: stages, registry, input, mode: 'tool', renderOutput,
        stdin: { isTTY: false }, stdout: { write(value) { chunks.push(String(value)); } },
        stderr: { write() {} }, env: {},
      }));
      const result = {
        items: output.items, halted: output.halted,
        haltedAt: output.haltedAt ? { index: output.haltedAt.index, name: output.haltedAt.stage.name, inPlace: output.haltedAt.inPlace === true } : null,
        executionStarted: output.executionStarted, rendered: output.rendered, renderedItems: output.renderedItems,
        ...(renderOutput ? { stdout: chunks.join('') } : {}),
      };
      const observation = { trace, counters, result };
      if (recipe.observeReferences === 'items') {
        observation.outputInputIndices = output.items.map(item => initialItems.indexOf(item));
      }
      // Transport observations into the host realm after strict identity checks.
      return plain(observation);
    };
    const observation = await execute(pipeline, initialItems);
    return { ...plain(recipe), runs: [observation] };
  }
}

async function finite(operation) {
  let timer;
  try { return await Promise.race([operation, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ordinary runtime capture deadline exceeded')), 5000); })]); }
  finally { clearTimeout(timer); }
}

export async function captureLobsterTable({ referenceRoot, archive, dependencies }) {
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
    harness: { path: 'scripts/openclaw/capture-lobster-table.mjs', sha256: digest(readFileSync(fileURLToPath(import.meta.url))), stringCodeGeneration: 'actual Ajv compiler dependency evaluated; table recipes require no schema validation', sourceStream: 'explicit initial async-generator input fixture records open/yield/finally; no fixture source command', observations: 'real command.run wrappers and original-root reference observations before public JSON conversion; stdout captures actual source writes', provenanceMechanism: 'copied bounded Collections harness, older scripts/fixtures unchanged', sourceValidation: 'actual runtime/input_request/validation source closure evaluated; no schema request or response validation recipe', resume: 'not executed; no public tool_runtime/finalizer/state IO' },
    license: { path: 'package/LICENSE', sha256: digest(files.get('package/LICENSE')), text: files.get('package/LICENSE').toString('utf8') },
    cases,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, dependencies, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && dependencies && output, 'provide referenceRoot archive dependencies output');
  writeFileSync(output, JSON.stringify(await captureLobsterTable({ referenceRoot, archive, dependencies }), null, 2) + '\n');
}
