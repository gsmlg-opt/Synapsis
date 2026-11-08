// Execute unchanged pure commands; observe JS values separately from workflow execution.
// No package install, full runtime, native effects, workflow persistence or host codec.
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

// Independently implemented execution recipes. This harness never imports tests
// or their literal expected observations. Commands consume their real iterables.
const recipeSource = String.raw`
import { pickCommand } from './pick.js';
import { mapCommand } from './map.js';

async function collect(iterable) {
  const items = [];
  for await (const item of iterable) items.push(item);
  return items;
}

export async function capture() {
  const cases = [];
  const picked = await pickCommand.run({
    input: [JSON.parse('{"present":null,"title":"mail"}')],
    args: { _: ['missing,present,title'] },
  });
  const [projection] = await collect(picked.output);
  cases.push({ id: 'pick-missing-and-null', execution: 'command', observation: {
    keys: Object.keys(projection), missingOwn: Object.hasOwn(projection, 'missing'),
    missingUndefined: projection.missing === undefined, presentNull: projection.present === null,
    title: projection.title, json: JSON.stringify(projection),
  } });

  const shared = JSON.parse('{"count":1,"label":"old"}');
  const mapped = await mapCommand.run({
    input: [shared, shared], args: { _: ['label=updated', 'echo={{count}}'] },
  });
  const mappedItems = await collect(mapped.output);
  cases.push({ id: 'map-shared-alias', execution: 'command', observation: {
    outputCount: mappedItems.length, bothSameAsInput: mappedItems.every(item => item === shared),
    outputsShare: mappedItems[0] === mappedItems[1], keys: Object.keys(shared),
    count: shared.count, label: shared.label, echo: shared.echo,
  } });

  const task = JSON.parse('{"id":"task-1"}');
  const wrapping = await mapCommand.run({ input: [task, task], args: { wrap: 'item', _: [] } });
  const wrapped = await collect(wrapping.output);
  const unwrapping = await mapCommand.run({ input: wrapped, args: { unwrap: 'item', _: [] } });
  const unwrapped = await collect(unwrapping.output);
  cases.push({ id: 'map-wrap-unwrap', execution: 'command', observation: {
    wrappedCount: wrapped.length, distinctWrappers: wrapped[0] !== wrapped[1],
    bothPointToInput: wrapped.every(item => item.item === task), unwrappedCount: unwrapped.length,
    sameInput: unwrapped.every(item => item === task), unwrappedShared: unwrapped[0] === unwrapped[1],
  } });

  const ordered = JSON.parse('{"z":1,"10":"ten","2":"two","01":"leading","4294967294":"last-index","4294967295":"ordinary","z":2,"a":3}');
  const initialKeys = Object.keys(ordered);
  const duplicateValue = ordered.z;
  ordered.z = 3;
  ordered['1'] = 'one';
  ordered.b = 4;
  cases.push({ id: 'object-order-and-replacement', execution: 'native-js', observation: {
    initialKeys, duplicateValue, finalKeys: Object.keys(ordered),
    replacementValue: ordered.z, appendedValue: ordered.b,
  } });

  const values = JSON.parse('[null,false,true,"雪😀",0,-0,0.1,9007199254740993,1e23,1e-7,-2.5,42]');
  const bits = values.slice(4).map(value => {
    const buffer = new ArrayBuffer(8);
    new DataView(buffer).setFloat64(0, value, false);
    return [...new Uint8Array(buffer)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  });
  cases.push({ id: 'binary64-json-import', execution: 'native-js', observation: {
    nullValue: values[0] === null, booleans: values.slice(1, 3), text: values[3], bits,
    negativeZero: Object.is(values[5], -0), roundedLargeEquals2Pow53: values[7] === 2 ** 53,
  } });

  const nested = JSON.parse('[{"type":"undefined","value":null},["雪😀",false],null]');
  const aliases = [nested[0], nested[0]];
  const observation = {
    tagShapedKeys: Object.keys(nested[0]), tagString: nested[0].type,
    tagValueIsNull: nested[0].value === null, nestedArray: Array.isArray(nested[1]),
    nestedString: nested[1][0], nestedBoolean: nested[1][1], rootNull: nested[2] === null,
    aliasIdentity: aliases[0] === aliases[1],
  };
  nested[0].note = 'later';
  observation.aliasMutation = aliases.map(item => item.note);
  cases.push({ id: 'nested-typed-snapshot', execution: 'native-js', observation });
  return cases;
}
`;

export async function captureLobsterValues({ referenceRoot, archive }) {
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
    'package/dist/src/commands/stdlib/pick.js',
    'package/dist/src/commands/stdlib/map.js',
    'package/dist/src/core/value_path.js',
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
  const harness = new vm.SourceTextModule(recipeSource, { context, identifier: 'value-observation-harness' });
  await harness.link((specifier, importer) => {
    if (importer.identifier === 'value-observation-harness') {
      assert.ok(specifier === './pick.js' || specifier === './map.js');
      return modules.get(sourcePaths[specifier === './pick.js' ? 0 : 1]);
    }
    assert.equal(importer.identifier, sourcePaths[1]);
    assert.equal(specifier, '../../core/value_path.js');
    return modules.get(sourcePaths[2]);
  });
  await harness.evaluate({ timeout: 1000 });
  context.capture = harness.namespace.capture;
  let timer;
  let cases;
  try {
    const pending = new vm.Script('capture()').runInContext(context, { timeout: 1000 });
    cases = await Promise.race([pending, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('value observation timeout')), 5000);
    })]);
  } finally {
    clearTimeout(timer);
  }
  return {
    referencePin: pin, referenceRecords,
    sourcePackage: { name: pkg.name, version: pkg.version, integrity, installed: false, packageJsonSha256: hash(bytes['package/package.json']) },
    executedRuntime: false, executedCommands: ['pick', 'map'], commandCalls: 4,
    sourceRecords: sourcePaths.map(path => ({ path, sha256: hash(bytes[path]), wholeModule: true, executed: true })),
    harness: { path: 'scripts/openclaw/capture-lobster-values.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))), nativeJsCases: 3, typedSnapshotRestoration: false },
    license: { path: 'package/LICENSE', sha256: hash(bytes['package/LICENSE']), text: bytes['package/LICENSE'].toString('utf8') },
    cases: JSON.parse(JSON.stringify(cases)),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && output, 'provide referenceRoot archive output');
  writeFileSync(output, JSON.stringify(await captureLobsterValues({ referenceRoot, archive }), null, 2) + '\n');
}
