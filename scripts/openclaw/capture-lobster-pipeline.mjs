// Execute the two unchanged pure parser modules from the lock-verified archive.
// No package install, workflow executor, filesystem facade, or command runs.
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
const whitespace = '\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff';
const recipes = [
  ['stage-trim-and-spacing', ' \tjson  "[1,2]"  |  pick --field name \r\n'],
  ['quoted-pipes', 'json "a|b" \'c|d\' | join "|"'],
  ['single-quote-escapes', String.raw`json 'C:\notes\q' 'it\'s'`],
  ['double-quote-known-escapes', String.raw`json "a\"b" "c\\d" "\$cash"`],
  ['double-quote-backtick', 'json "\\`tick"'],
  ['double-quote-unknown-escapes', String.raw`json "\n\t\q"`],
  ['double-quote-line-continuation', 'json "first\\\nsecond"'],
  ['quote-concatenation-and-empty-tokens', 'json pre"mid"\'tail\' "" \'\''],
  ['ascii-token-whitespace', 'json\talpha\nbeta\rgamma'],
  ['internal-nbsp', 'json alpha\u00a0beta'],
  ['nel-preserved', '\u0085json value\u0085'],
  ['ecmascript-outer-whitespace', whitespace + 'json value' + [...whitespace].reverse().join('')],
  ['unicode-text', 'json "雪😀" "é" "👩‍💻"'],
  ['flag-values-and-booleans', 'pick --field=name --count 2 --verbose --final --value=a=b item'],
  ['repeated-flags', 'pick --field first --field=last --toggle --toggle=false item'],
  ['ordinary-json-value', 'json --json payload tail'],
  ['exec-json-boolean', 'exec --json printf "%s" \'{"x":1}\''],
  ['exec-json-explicit-string', 'exec --json=false echo done'],
  ['empty-flag-and-positional', 'json --label= ""'],
  ['quoted-flag-and-value', 'json "--field" "display name" item'],
  ['unquoted-backslashes', String.raw`json C:\tmp\file plain\word`],
  ['unquoted-backslash-before-pipe', String.raw`json left\| json right`],
  ['trailing-pipe', 'json ready | \t'],
  ['quoted-command-name', '"json"  "ready now"'],
];

export async function captureLobsterPipeline({ referenceRoot, archive }) {
  const git = args => execFileSync('git', ['-C', referenceRoot, ...args], { maxBuffer: 32 * 1024 * 1024 });
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
  const paths = ['package/package.json', 'package/LICENSE', 'package/dist/src/parser.js', 'package/dist/src/command_tokens.js'];
  const encoded = JSON.parse(execFileSync('python3', ['-c',
    'import tarfile,json,base64,sys\nwith tarfile.open(sys.argv[1],"r:gz") as t:\n print(json.dumps({p:base64.b64encode(t.extractfile(p).read()).decode() for p in sys.argv[2:]}))', archive, ...paths],
    { maxBuffer: 1024 * 1024 }).toString());
  const bytes = Object.fromEntries(paths.map(path => [path, Buffer.from(encoded[path], 'base64')]));
  const pkg = JSON.parse(bytes['package/package.json']);
  assert.equal(pkg.name, '@clawdbot/lobster'); assert.equal(pkg.version, '2026.9.16');
  const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
  const sourcePaths = paths.slice(2);
  const modules = new Map(sourcePaths.map(path => [path, new vm.SourceTextModule(bytes[path].toString('utf8'), { context, identifier: path })]));
  const parser = modules.get(sourcePaths[0]);
  await parser.link((specifier, importer) => {
    assert.equal(importer.identifier, sourcePaths[0]); assert.equal(specifier, './command_tokens.js');
    return modules.get(sourcePaths[1]);
  });
  await parser.evaluate({ timeout: 1000 });
  context.parsePipeline = parser.namespace.parsePipeline;
  const invoke = new vm.Script('parsePipeline(input)');
  const vectors = recipes.map(([id, input]) => {
    context.input = input;
    return { id, input, stages: JSON.parse(JSON.stringify(invoke.runInContext(context, { timeout: 1000 }))) };
  });
  return {
    referencePin: pin, referenceRecords,
    sourcePackage: { name: pkg.name, version: pkg.version, integrity, installed: false, packageJsonSha256: hash(bytes['package/package.json']) },
    executedRuntime: false,
    sourceRecords: sourcePaths.map(path => ({ path, sha256: hash(bytes[path]), wholeModule: true, executed: true })),
    harness: { path: 'scripts/openclaw/capture-lobster-pipeline.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    license: { path: 'package/LICENSE', sha256: hash(bytes['package/LICENSE']), text: bytes['package/LICENSE'].toString('utf8') },
    vectors,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && output, 'provide referenceRoot archive output');
  writeFileSync(output, JSON.stringify(await captureLobsterPipeline({ referenceRoot, archive }), null, 2) + '\n');
}
