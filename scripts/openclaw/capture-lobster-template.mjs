// Whole pinned-source template command observations, separate from production.
// No source transformations, workflow runtime, Machine, transport or native tool.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import * as fsPromises from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const integrity = 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==';
const hash = (bytes, algorithm = 'sha256', encoding = 'hex') => createHash(algorithm).update(bytes).digest(encoding);
// Input recipes only. Expected outputs live exclusively in the independent tests.
const recipeSource = String.raw`
import { templateCommand } from 'reference:template';
import fs from 'node:fs/promises';
const recipes = [
  { id: "literal-unicode-and-braces", template: "\u96ea\ud83d\ude00 <b>plain</b>", item: {} },
  { id: "fields-and-nested", template: "{{title}} / {{nested.name}}", item: {title:"one",nested:{name:"雪"}} },
  { id: "path-empty-segments", template: "{{.nested..name.}}", item: {nested:{name:"yes"}} },
  { id: "array-index-and-length", template: "{{v.1.name}}/{{v.length}}", item: {v:[{name:"a"},{name:"b"}]} },
  { id: "string-index-and-length", template: "{{v.1}}/{{v.length}}", item: {v:"cat"} },
  { id: "whole-dot", template: "{{.}}", item: {z:1,a:2} },
  { id: "whole-this", template: "{{this}}", item: [1,"雪",null] },
  { id: "all-dots-whole", template: "{{...}}", item: {a:1} },
  { id: "this-property-is-literal", template: "{{this.name}}", item: {this:{name:"actual"},name:"root"} },
  { id: "missing-null-undefined", template: "a{{missing}}b{{nil}}c{{own}}d", item: {nil:null,own:undefined} },
  { id: "nullish-intermediate", template: "{{nil.child}}/{{missing.child}}", item: {nil:null} },
  { id: "whole-null", template: "[{{.}}]", item: null },
  { id: "whole-undefined", template: "[{{this}}]", item: undefined },
  { id: "whole-boolean", template: "{{.}}", item: false },
  { id: "whole-number", template: "{{this}}", item: -12.5 },
  { id: "whole-signed-zero", template: "{{.}}", item: -0 },
  { id: "compact-object-key-order", template: "{{v}}", item: {v:{z:1,"10":"ten","2":"two",a:2}} },
  { id: "compact-array-undefined", template: "{{v}}", item: {v:[1,undefined,null,"雪"]} },
  { id: "replacement-is-not-recursive", template: "{{v}}", item: {v:"{{name}}",name:"later"} },
  { id: "expression-ecmascript-whitespace", template: "{{\u00a0 v \ufeff}}", item: {v:"yes"} },
  { id: "upper-ascii", template: "{{v | upper}}", item: {v:"Ab c"} },
  { id: "upper-unicode-expansion", template: "{{v | upper}}", item: {v:"Straße 雪😀"} },
  { id: "upper-nullish", template: "{{v | upper}}", item: {v:null} },
  { id: "upper-array-coercion", template: "{{v | upper}}", item: {v:["a",null,"b"]} },
  { id: "upper-object-coercion", template: "{{v | upper}}", item: {v:{a:1}} },
  { id: "lower-ascii", template: "{{v | lower}}", item: {v:"Ab C"} },
  { id: "lower-unicode-expansion", template: "{{v | lower}}", item: {v:"İ ΣΟΣ"} },
  { id: "trim-ecmascript-whitespace", template: "{{v | trim}}", item: {v:"\t\n\r \u00a0\ufeffx\u3000\u2029"} },
  { id: "trim-retains-next-line", template: "{{v | trim}}", item: {v:"\u0085x\u0085"} },
  { id: "trim-upper-chain", template: "{{v | trim | upper}}", item: {v:"  hello  "} },
  { id: "truncate-short", template: "{{v | truncate 3}}", item: {v:"abcdef"} },
  { id: "truncate-no-op", template: "{{v | truncate 6}}", item: {v:"abcdef"} },
  { id: "truncate-default", template: "{{v | truncate}}", item: {v:"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"} },
  { id: "truncate-zero", template: "{{v | truncate 0}}", item: {v:"abc"} },
  { id: "truncate-signed-length", template: "{{v | truncate -1}}", item: {v:"abcd"} },
  { id: "truncate-decimal-prefix", template: "{{v | truncate 2tail}}", item: {v:"abcd"} },
  { id: "truncate-whole-astral", template: "{{v | truncate 2}}", item: {v:"😀x"} },
  { id: "truncate-surrogate-half", template: "{{v | truncate 1}}", item: {v:"😀x"} },
  { id: "replace-all", template: "{{v | replace \"a\" \"x\"}}", item: {v:"banana"} },
  { id: "replace-pipe-in-quoted-arg", template: "{{v | replace \"|\" \":\" | upper}}", item: {v:"a|b"} },
  { id: "replace-space-in-quoted-arg", template: "{{v | replace 'a b' 'c d'}}", item: {v:"a b a b"} },
  { id: "replace-escaped-quote", template: "{{v | replace \"\\\"\" \"'\"}}", item: {v:'a"b"'} },
  { id: "replace-escaped-backslash", template: "{{v | replace \"\\\\\" \"/\"}}", item: {v:'a\\b\\c'} },
  { id: "quoted-backslash-is-not-json-escape", template: "{{v | replace \"\\n\" \"N\"}}", item: {v:"banana"} },
  { id: "replace-dollar-match", template: "{{v | replace \"a\" \"[$&]\"}}", item: {v:"aba"} },
  { id: "replace-dollar-dollar", template: "{{v | replace \"a\" \"$$\"}}", item: {v:"aba"} },
  { id: "replace-empty-search", template: "{{v | replace \"\" \"-\"}}", item: {v:"ab"} },
  { id: "replace-empty-search-surrogates", template: "{{v | replace \"\" \"-\"}}", item: {v:"😀"} },
  { id: "replace-omitted-arguments", template: "{{v | replace}}", item: {v:"abc"} },
  { id: "split-default", template: "{{v | split}}", item: {v:"a,b,,c"} },
  { id: "split-custom", template: "{{v | split \"::\"}}", item: {v:"a::b"} },
  { id: "split-empty-ascii", template: "{{v | split \"\"}}", item: {v:"ab"} },
  { id: "split-empty-astral-json", template: "{{v | split \"\"}}", item: {v:"😀"} },
  { id: "split-first", template: "{{v | split \",\" | first}}", item: {v:"one,two"} },
  { id: "split-last", template: "{{v | split \",\" | last}}", item: {v:"one,two"} },
  { id: "split-empty-first-surrogate", template: "{{v | split \"\" | first}}", item: {v:"😀"} },
  { id: "split-empty-last-surrogate", template: "{{v | split \"\" | last}}", item: {v:"😀"} },
  { id: "split-empty-join-reconstructs", template: "{{v | split \"\" | join \"\"}}", item: {v:"😀"} },
  { id: "first-array", template: "{{v | first}}", item: {v:["a","b"]} },
  { id: "last-array", template: "{{v | last}}", item: {v:["a","b"]} },
  { id: "first-string-pass-through", template: "{{v | first}}", item: {v:"abc"} },
  { id: "last-object-pass-through", template: "{{v | last}}", item: {v:{a:1}} },
  { id: "first-empty-array", template: "[{{v | first}}]", item: {v:[]} },
  { id: "last-empty-array", template: "[{{v | last}}]", item: {v:[]} },
  { id: "length-array", template: "{{v | length}}", item: {v:[1,null,undefined]} },
  { id: "length-astral", template: "{{v | length}}", item: {v:"😀x"} },
  { id: "length-object", template: "{{v | length}}", item: {v:{length:99}} },
  { id: "length-null", template: "{{v | length}}", item: {v:null} },
  { id: "join-default", template: "{{v | join}}", item: {v:["a","b","c"]} },
  { id: "join-custom", template: "{{v | join \"|\"}}", item: {v:["a","b"]} },
  { id: "join-nullish-nested", template: "{{v | join \":\"}}", item: {v:[null,undefined,[1,2],{x:1}]} },
  { id: "join-scalar", template: "{{v | join \":\"}}", item: {v:42} },
  { id: "json-pretty-order-and-own-undefined", template: "{{v | json}}", item: {v:{z:1,"10":"ten","2":"two",own:undefined,a:[true,null]}} },
  { id: "json-undefined-root", template: "[{{v | json}}]", item: {v:undefined} },
  { id: "json-array-undefined", template: "{{v | json}}", item: {v:[undefined,null]} },
  { id: "json-string-quotes", template: "{{v | json}}", item: {v:"雪"} },
  { id: "surrogate-json-filter-escape", template: "{{v | truncate 1 | json}}", item: {v:"😀x"} },
  { id: "string-object", template: "{{v | string}}", item: {v:{a:1}} },
  { id: "string-array", template: "{{v | string}}", item: {v:["a",null,[1,2]]} },
  { id: "string-null", template: "[{{v | string}}]", item: {v:null} },
  { id: "default-missing", template: "{{v | default \"fallback\"}}", item: {} },
  { id: "default-null", template: "{{v | default \"fallback\"}}", item: {v:null} },
  { id: "default-empty", template: "{{v | default \"fallback\"}}", item: {v:""} },
  { id: "default-retains-false", template: "{{v | default \"fallback\"}}", item: {v:false} },
  { id: "default-retains-zero", template: "{{v | default \"fallback\"}}", item: {v:0} },
  { id: "default-retains-empty-array", template: "{{v | default \"fallback\"}}", item: {v:[]} },
  { id: "default-retains-empty-object", template: "{{v | default \"fallback\"}}", item: {v:{}} },
  { id: "default-pipe-quoted-chain", template: "{{v | default 'a|b' | upper}}", item: {} },
  { id: "default-internal-tab-literal", template: "{{v | default a\tb}}", item: {} },
  { id: "extra-filter-arguments-ignored", template: "{{v | upper \"ignored\" \"also\"}}", item: {v:"abc"} },
  { id: "round-two-decimals", template: "{{v | round 2}}", item: {v:12.345} },
  { id: "round-binary64-low-tie", template: "{{v | round 2}}", item: {v:1.005} },
  { id: "round-exact-tie", template: "{{v | round 1}}", item: {v:1.25} },
  { id: "round-binary64-down", template: "{{v | round 1}}", item: {v:2.55} },
  { id: "round-default-zero-digits", template: "{{v | round}}", item: {v:12.6} },
  { id: "round-decimal-prefix", template: "{{v | round 2tail}}", item: {v:12.345} },
  { id: "round-null-number-conversion", template: "{{v | round 2}}", item: {v:null} },
  { id: "round-false-number-conversion", template: "{{v | round 2}}", item: {v:false} },
  { id: "round-empty-string-number-conversion", template: "{{v | round 2}}", item: {v:""} },
  { id: "round-hex-string-number-conversion", template: "{{v | round}}", item: {v:"0x10"} },
  { id: "round-array-number-conversion", template: "{{v | round 1}}", item: {v:[1.25]} },
  { id: "round-exponent-format", template: "{{v | round 2}}", item: {v:1e21} },
  { id: "round-signed-zero-string", template: "{{v | round 1}}", item: {v:-0.01} },
  { id: "date-numeric-epoch", template: "{{v | date}}", item: {v:0} },
  { id: "date-digit-string-epoch", template: "{{v | date}}", item: {v:" 0 "} },
  { id: "date-milliseconds", template: "{{v | date}}", item: {v:1234} },
  { id: "date-offset-to-utc", template: "{{v | date}}", item: {v:"2024-02-29T12:34:56+02:00"} },
  { id: "date-format-all-utc-tokens", template: "{{v | date \"YYYY/MM/DD HH:mm:ss\"}}", item: {v:"2024-02-29T12:34:56.789Z"} },
  { id: "date-format-first-only", template: "{{v | date \"YYYY YYYY MM MM DD DD HH HH mm mm ss ss\"}}", item: {v:"2024-02-29T12:34:56Z"} },
  { id: "date-empty-format-iso", template: "{{v | date ''}}", item: {v:"2024-02-29T00:00:00Z"} },
  { id: "date-low-year-unpadded-format", template: "{{v | date \"YYYY-MM-DD\"}}", item: {v:"0001-01-02T00:00:00Z"} },
  { id: "date-then-lower-chain", template: "{{v | date | lower}}", item: {v:0} },
  { id: "string-index-surrogate", template: "{{v.0}}", item: {v:"😀"} },
  { id: "full-astral-literal-and-field", template: "\ud800\udc00{{v}}\ud83d\ude00", item: {v:"雪🚀"} }
];
async function collect(iterable) {
  const values = [];
  for await (const item of iterable) values.push(item);
  return values;
}
export async function capture(files) {
  let commandCalls = 0;
  async function run(args, input) {
    commandCalls += 1;
    return templateCommand.run({ args, input });
  }
  const renderCases = [];
  for (const recipe of recipes) {
    const result = await run({ text: recipe.template }, [recipe.item]);
    const output = await collect(result.output);
    renderCases.push({ id: recipe.id, template: recipe.template, output: output[0] });
  }
  const selectionCases = [];
  const selection = [
    ['text-wins-file-and-positional', { text: 'TEXT {{name}}', file: files.full, _: ['POSITIONAL', '{{name}}'] }],
    ['whitespace-text-wins', { text: '  ', file: files.full, _: ['POSITIONAL'] }],
    ['file-wins-positional', { file: files.full, _: ['POSITIONAL', '{{name}}'] }],
    ['empty-text-uses-file', { text: '', file: files.full, _: ['POSITIONAL', '{{name}}'] }],
    ['empty-file-falls-back-positional', { file: files.empty, _: ['POSITIONAL', '{{name}}'] }],
    ['empty-text-and-file-name-use-positional', { text: '', file: '', _: ['POSITIONAL', '{{name}}'] }],
    ['positional-joins-with-space', { _: ['Hello', '{{name}}', '!'] }],
  ];
  for (const [id, args] of selection) {
    const result = await run(args, [{ name: 'Ada' }]);
    selectionCases.push({ id, output: await collect(result.output) });
  }
  const retained = await run({ file: files.retained }, [{ name: 'Ada' }, { name: 'Bob' }]);
  // Real source fs.readFile already completed; change only our benign fixture
  // before any input is demanded, then observe the retained original content.
  await fs.writeFile(files.retained, 'AFTER {{name}}', 'utf8');
  selectionCases.push({ id: 'file-content-retained-before-pull', output: await collect(retained.output) });
  const emptyFileInput = await run({ file: files.full }, []);
  selectionCases.push({ id: 'file-constructor-empty-input', output: await collect(emptyFileInput.output) });

  function observedInput(items) {
    const counters = { opens: 0, yields: 0, finishes: 0 };
    const input = (async function* () {
      counters.opens += 1;
      try {
        for (const item of items) { counters.yields += 1; yield item; }
      } finally { counters.finishes += 1; }
    })();
    return { counters, input };
  }
  const lazyCases = [];
  {
    const { input, counters } = observedInput([{ v: 'a' }, { v: 'b' }]);
    const result = await run({ text: '{{v | upper}}' }, input);
    const before = { ...counters };
    const iterator = result.output[Symbol.asyncIterator]();
    const first = await iterator.next();
    await iterator.return();
    lazyCases.push({ id: 'constructor-does-not-pull', before, after: { ...counters }, output: [first.value] });
  }
  {
    const { input, counters } = observedInput([]);
    const result = await run({ text: '{{v}}' }, input);
    const before = { ...counters };
    const output = await collect(result.output);
    lazyCases.push({ id: 'empty-input', before, after: { ...counters }, output });
  }
  {
    const shared = { v: 'one' };
    const { input, counters } = observedInput([shared, shared]);
    const result = await run({ text: '{{v}}' }, input);
    const before = { ...counters };
    const iterator = result.output[Symbol.asyncIterator]();
    const first = await iterator.next();
    shared.v = 'two';
    const second = await iterator.next();
    await iterator.next();
    lazyCases.push({ id: 'latest-item-mutation-on-demand', before, after: { ...counters }, output: [first.value, second.value] });
  }
  return { renderCases, selectionCases, lazyCases, commandCalls };
}
`;

export async function captureLobsterTemplate({ referenceRoot, archive,
  temporaryRoot = tmpdir() }) {
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
    'package/dist/src/commands/stdlib/template.js',
    'package/dist/src/core/filters.js',
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
  const modules = new Map(sourcePaths.map(path => [path,
    new vm.SourceTextModule(bytes[path].toString('utf8'), { context, identifier: path })]));
  // This is the actual Node fs implementation. No fixture readFile stub or
  // source rewrite stands in for the successful file reads being observed.
  const nativeFs = new vm.SyntheticModule(['default'], function () {
    this.setExport('default', fsPromises.default);
  }, { context, identifier: 'native:node:fs/promises' });
  const harness = new vm.SourceTextModule(recipeSource, { context, identifier: 'template-observation-harness' });
  await harness.link((specifier, importer) => {
    if (specifier === 'reference:template' && importer.identifier === 'template-observation-harness') {
      return modules.get(sourcePaths[0]);
    }
    if (specifier === 'node:fs/promises') return nativeFs;
    const target = posix.normalize(posix.join(posix.dirname(importer.identifier), specifier));
    assert.ok(sourcePaths.includes(target), `unrecorded source import ${specifier}`);
    return modules.get(target);
  });
  await harness.evaluate({ timeout: 1000 });

  const fixtureRoot = mkdtempSync(join(temporaryRoot, 'template-source-files-'));
  const files = { full: join(fixtureRoot, 'full.txt'), empty: join(fixtureRoot, 'empty.txt'), retained: join(fixtureRoot, 'retained.txt') };
  let observations;
  try {
    writeFileSync(files.full, 'FILE {{name}}', 'utf8');
    writeFileSync(files.empty, '', 'utf8');
    writeFileSync(files.retained, 'BEFORE {{name}}', 'utf8');
    context.capture = harness.namespace.capture;
    context.fixturePaths = files;
    let timer;
    try {
      const pending = new vm.Script('capture(fixturePaths)').runInContext(context, { timeout: 1000 });
      observations = await Promise.race([pending, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('template source observation timeout')), 10000);
      })]);
    } finally { clearTimeout(timer); }
  } finally {
    rmSync(fixtureRoot, { recursive: true });
  }
  return {
    referencePin: pin, referenceRecords,
    sourcePackage: { name: pkg.name, version: pkg.version, integrity, installed: false },
    runtime: { node: process.versions.node, unicode: process.versions.unicode, icu: process.versions.icu,
      dateVectorsUseExplicitUTCOrNumericEpoch: true },
    executedRuntime: false, executedCommands: ['template'], commandCalls: observations.commandCalls,
    productionFormatterExecuted: false, nativeToolExecution: false, machineOrTransportExecuted: false,
    fileObservationScope: 'source-command-only', fileFixturesRemoved: !existsSync(fixtureRoot),
    sourceRecords: sourcePaths.map(path => ({ path, sha256: hash(bytes[path]), wholeModule: true,
      executed: modules.get(path).status === 'evaluated' })),
    nativeImports: ['node:fs/promises'],
    harness: { path: 'scripts/openclaw/capture-lobster-template.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))),
      sourceTransformed: false, realFilesystemBinding: true },
    license: { path: 'package/LICENSE', sha256: hash(bytes['package/LICENSE']), text: bytes['package/LICENSE'].toString('utf8') },
    // JSON.stringify escapes unpaired surrogates; JSON.parse reconstructs them
    // unchanged. No UTF8 encoder ever handles the raw observation strings.
    ...JSON.parse(JSON.stringify({ renderCases: observations.renderCases,
      selectionCases: observations.selectionCases, lazyCases: observations.lazyCases })),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && output, 'provide referenceRoot archive output');
  writeFileSync(output, JSON.stringify(await captureLobsterTemplate({ referenceRoot, archive }), null, 2) + '\n');
}
