// Trusted fixed-source renderer/signature observation; no state I/O or runtime.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const integrity = 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==';
const hash = (bytes, algorithm = 'sha256', encoding = 'hex') => createHash(algorithm).update(bytes).digest(encoding);

// Execution recipes only, independently implemented after literal test archive.
// Neither this capture nor product code reads the independent expected table.
const recipeSource = String.raw`
import { createJsonRenderer } from './renderer.js';
import { stableStringify } from './store.js';
export function capture() {
  const inputs = [
    '0', '-0', '42', '-2.5', '0.1', '0.30000000000000004', '1.25',
    '1e-6', '9e-7', '1e-7', '1.234e-6', '1.2e-7', '1e20', '1e21',
    '1.234e21', '1e23', '1000000000000000128', '9007199254740993',
    '1.2345678901234567', '-1e-6', '-1e21', '10e-0', '1424953923781206.25',
  ];
  const numberVectors = inputs.map(input => ({ input, compact: JSON.stringify(JSON.parse(input)) }));
  const cases = [];
  cases.push({ id: 'primitives', execution: 'native-js', observation: {
    compact: JSON.stringify(JSON.parse('[null,true,false,"mail",0,-0]')),
  } });
  const controls = String.fromCharCode(0, 8, 9, 10, 11, 12, 13, 14, 31);
  const suffix = ' "\\ /雪😀\u2028\u2029 literal \\u000B';
  cases.push({ id: 'control-and-unicode-string', execution: 'native-js', observation: {
    compact: JSON.stringify(controls + suffix),
  } });
  const nestedWrites = [];
  createJsonRenderer({ write: text => nestedWrites.push(text) }).json(
    JSON.parse('{"title":"mail","items":[1,{"b":true,"empty":[]}],"nothing":{}}'),
  );
  cases.push({ id: 'pretty-nested-renderer', execution: 'source-renderer', observation: {
    writes: nestedWrites, output: nestedWrites.join(''),
  } });
  const emptyWrites = [];
  const emptyRenderer = createJsonRenderer({ write: text => emptyWrites.push(text) });
  for (const input of ['{}', '[]']) emptyRenderer.json(JSON.parse(input));
  cases.push({ id: 'empty-shapes-renderer', execution: 'source-renderer', observation: {
    writes: emptyWrites, output: emptyWrites.join(''),
  } });
  const object = { keep: null, omit: undefined, title: 'mail' };
  const array = [undefined, null, { omit: undefined, ok: true }];
  cases.push({ id: 'public-undefined', execution: 'native-js', observation: {
    rootUndefined: JSON.stringify(undefined) === undefined,
    compactObject: JSON.stringify(object), prettyObject: JSON.stringify(object, null, 2),
    compactArray: JSON.stringify(array), prettyArray: JSON.stringify(array, null, 2),
  } });
  const ordered = JSON.parse('{"z":1,"10":"ten","2":"two","\ue000":"bmp","\ud800\udc00":"astral","a":2}');
  cases.push({ id: 'own-key-order-stable', execution: 'source-stable', observation: {
    compact: JSON.stringify(ordered), stable: stableStringify(ordered),
  } });
  const nested = JSON.parse('{"b":[{"z":1,"a":2},[{"y":3,"x":4}]],"a":{"d":4,"c":3}}');
  cases.push({ id: 'stable-nested-arrays', execution: 'source-stable', observation: {
    compact: JSON.stringify(nested), stable: stableStringify(nested),
  } });
  const shared = { value: -0, label: 'mail' };
  const source = { left: shared, right: shared };
  const compact = JSON.stringify(source);
  const clone = JSON.parse(compact);
  const observation = {
    compact, sourceShared: source.left === source.right,
    sourceNegativeZero: Object.is(shared.value, -0), cloneDistinct: clone.left !== clone.right,
    clonePositiveZero: Object.is(clone.left.value, 0) && Object.is(clone.right.value, 0),
  };
  clone.left.label = 'edited';
  observation.cloneTextAfterLeftEdit = JSON.stringify(clone);
  observation.sourceLabelAfterEdit = shared.label;
  cases.push({ id: 'snapshot-alias-and-zero', execution: 'native-js', observation });
  return { numberVectors, cases };
}
`;

export async function captureLobsterJSON({ referenceRoot, archive }) {
  const git = args => execFileSync('git', ['-C', referenceRoot, ...args], { timeout: 10000, maxBuffer: 32 * 1024 * 1024 });
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), pin);
  const referenceRecords = ['extensions/lobster/package.json', 'pnpm-lock.yaml'].map(path => {
    const bytes = readFileSync(resolve(referenceRoot, path));
    assert.deepEqual(bytes, git(['show', `${pin}:${path}`]));
    return { path, sha256: hash(bytes) };
  });
  const manifest = JSON.parse(readFileSync(resolve(referenceRoot, referenceRecords[0].path)));
  assert.equal(manifest.dependencies['@clawdbot/lobster'], '2026.9.16');
  const lock = readFileSync(resolve(referenceRoot, 'pnpm-lock.yaml'), 'utf8');
  assert.ok(lock.includes(`'@clawdbot/lobster@2026.9.16':\n    resolution: {integrity: ${integrity}}`));
  assert.equal('sha512-' + hash(readFileSync(archive), 'sha512', 'base64'), integrity);
  const sourcePaths = [
    'package/dist/src/renderers/json.js',
    'package/dist/src/state/store.js',
    'package/dist/src/state/atomic_file.js',
  ];
  const paths = ['package/package.json', 'package/LICENSE', ...sourcePaths];
  const encoded = JSON.parse(execFileSync('python3', ['-c',
    'import tarfile,json,base64,sys\nwith tarfile.open(sys.argv[1],"r:gz") as t:\n print(json.dumps({p:base64.b64encode(t.extractfile(p).read()).decode() for p in sys.argv[2:]}))', archive, ...paths],
    { timeout: 10000, maxBuffer: 1024 * 1024 }).toString());
  const bytes = Object.fromEntries(paths.map(path => [path, Buffer.from(encoded[path], 'base64')]));
  const pkg = JSON.parse(bytes['package/package.json']);
  assert.equal(pkg.name, '@clawdbot/lobster');
  assert.equal(pkg.version, '2026.9.16');

  const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
  const modules = new Map(sourcePaths.map(path => [path, new vm.SourceTextModule(bytes[path].toString('utf8'), { context, identifier: path })]));
  const nativeSpecifiers = ['node:os', 'node:path', 'node:fs', 'node:crypto'];
  const natives = new Map(await Promise.all(nativeSpecifiers.map(async specifier => {
    const namespace = await import(specifier);
    return [specifier, new vm.SyntheticModule(Object.keys(namespace), function () {
      for (const key of Object.keys(namespace)) this.setExport(key, namespace[key]);
    }, { context, identifier: specifier })];
  })));
  const harness = new vm.SourceTextModule(recipeSource, { context, identifier: 'json-observation-harness' });
  await harness.link((specifier, importer) => {
    if (importer.identifier === 'json-observation-harness') {
      assert.ok(specifier === './renderer.js' || specifier === './store.js');
      return modules.get(sourcePaths[specifier === './renderer.js' ? 0 : 1]);
    }
    if (specifier === './atomic_file.js') {
      assert.equal(importer.identifier, sourcePaths[1]);
      return modules.get(sourcePaths[2]);
    }
    assert.ok(importer.identifier === sourcePaths[1] || importer.identifier === sourcePaths[2]);
    assert.ok(natives.has(specifier));
    return natives.get(specifier);
  });
  await harness.evaluate({ timeout: 1000 });
  context.capture = harness.namespace.capture;
  const result = new vm.Script('capture()').runInContext(context, { timeout: 1000 });
  return {
    referencePin: pin, referenceRecords,
    sourcePackage: { name: pkg.name, version: pkg.version, integrity, installed: false, packageJsonSha256: hash(bytes['package/package.json']) },
    executedRuntime: false, executedPrivateSnapshotValidator: false, stateIOInvoked: false,
    sourceCalls: { rendererJSON: 3, stableStringify: 2 },
    sourceRecords: sourcePaths.map(path => ({ path, sha256: hash(bytes[path]), wholeModule: true, executed: true })),
    harness: { path: 'scripts/openclaw/capture-lobster-json.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))), nodeVersion: process.version, nativeImportBindings: nativeSpecifiers },
    license: { path: 'package/LICENSE', sha256: hash(bytes['package/LICENSE']), text: bytes['package/LICENSE'].toString('utf8') },
    ...JSON.parse(JSON.stringify(result)),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && output, 'provide referenceRoot archive output');
  writeFileSync(output, JSON.stringify(await captureLobsterJSON({ referenceRoot, archive }), null, 2) + '\n');
}
