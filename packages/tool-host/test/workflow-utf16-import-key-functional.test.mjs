import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync, mkdtempSync, symlinkSync, cpSync, renameSync, rmSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Writable } from 'node:stream';
import { finished } from 'node:stream/promises';
import { decodeRoots } from '../src/workflow/schema.mjs';

// Independent successful literals. Expected values never use the product's
// importer, encoder, key sorter or runtime as an oracle.
const STRINGS = [
  ['"\\ud83d"', [55357], '"\\ud83d"'],
  ['"\\ude00"', [56832], '"\\ude00"'],
  ['"\\uD83D\\uDE00"', [55357, 56832], '"😀"'],
  ['"😀"', [55357, 56832], '"😀"'],
  ['"\\ud83d\\ud83d\\ude00\\ude00"', [55357, 55357, 56832, 56832], '"\\ud83d😀\\ude00"'],
  ['"\\ud800A\\udfff"', [55296, 65, 57343], '"\\ud800A\\udfff"'],
  ['"\\\\ud83d"', [92, 117, 100, 56, 51, 100], '"\\\\ud83d"'],
  ['"\\u0000\\b\\t\\n\\f\\r\\\"\\\\\\/"', [0, 8, 9, 10, 12, 13, 34, 92, 47], '"\\u0000\\b\\t\\n\\f\\r\\\"\\\\/"'],
  ['"雪😀"', [38634, 55357, 56832], '"雪😀"'],
  ['""', [], '""'],
];
const HIGH = { type: 'string', utf16le: 'Pdg=' };
const LOW = { type: 'string', utf16le: 'AN4=' };
const RESPONSE = '{"\\ud83d":"\\ude00","Pdg=":"ordinary","nested":{"\\ude00":"\\ud83d"}}';
const PROJECTION = '{\n  "\\ud83d": "\\ude00",\n  "Pdg=": "ordinary",\n  "nested": {\n    "\\ude00": "\\ud83d"\n  }\n}';
const SCHEMA = '{"type":"object","required":["\\ud83d"]}';
const units = text => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));
const string = value => ({ type: 'string', value });
const ref = id => ({ type: 'reference', id });
const digest = value => createHash('sha256').update(value).digest('hex');
const repository = fileURLToPath(new URL('../../../', import.meta.url));
const packageRoot = join(repository, 'apps/synapsis_core/priv/workflow_schema');
let temporary, upstream, relocated, commands, runPipeline, compileCached;

before(async () => {
  const archive = process.env.SYNAPSIS_LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
  assert.equal(digest(readFileSync(archive)), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
  temporary = mkdtempSync(join(tmpdir(), 'synapsis-utf16-import-key-'));
  execFileSync('tar', ['-xzf', resolve(archive), '-C', temporary]);
  upstream = join(temporary, 'package');
  const pins = {
    'dist/src/commands/stdlib/map.js': 'faeebf18c5db3903ae5e03270b87f49e5a1b8a5324276add6ca52c83763d8e27',
    'dist/src/commands/stdlib/table.js': 'a95a58ca8153f97596e7bf5eb1236e25c0ebdd0ddbf416fadcf2a4f4d07dd13e',
    'dist/src/commands/stdlib/ask.js': '9133cbe30bddd28d322d3017f428317a6f98ab2bd9f43992b9f74594e3af6537',
    'dist/src/commands/stdlib/template.js': '27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac',
    'dist/src/runtime.js': '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53',
    'dist/src/input_request.js': '4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4',
    'dist/src/validation.js': 'a9e087f2b5502be86dc223f2746c1d598446d4c1b5537f697003418417933f6b',
    'dist/src/state/store.js': '8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c',
    'dist/src/core/filters.js': 'd7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14',
    'dist/src/core/value_path.js': 'e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f',
  };
  for (const [path, pin] of Object.entries(pins)) assert.equal(digest(readFileSync(join(upstream, path))), pin, path);
  symlinkSync(join(packageRoot, 'node_modules'), join(upstream, 'node_modules'), 'dir');
  const load = path => import(pathToFileURL(join(upstream, 'dist/src/' + path + '.js')));
  commands = {
    map: (await load('commands/stdlib/map')).mapCommand,
    table: (await load('commands/stdlib/table')).tableCommand,
    ask: (await load('commands/stdlib/ask')).askCommand,
    template: (await load('commands/stdlib/template')).templateCommand,
  };
  ({ runPipeline } = await load('runtime'));
  ({ compileCached } = await load('validation'));
  const assembled = join(temporary, 'assembled helper');
  relocated = join(temporary, 'relocated helper');
  cpSync(packageRoot, assembled, { recursive: true });
  renameSync(assembled, relocated);
  function files(root, prefix = '') {
    return readdirSync(join(root, prefix), { withFileTypes: true }).flatMap(entry => {
      const path = join(prefix, entry.name);
      return entry.isDirectory() ? files(root, path) : [path];
    }).sort();
  }
  assert.equal(files(relocated).length, 599);
  assert.deepEqual(files(relocated), files(packageRoot));
  for (const path of files(relocated)) assert.deepEqual(readFileSync(join(relocated, path)), readFileSync(join(packageRoot, path)), path);
});
after(() => { if (temporary) rmSync(temporary, { recursive: true, force: true }); });

for (const [raw, expected, json] of STRINGS) {
  test('native JSON exact root/nested units: ' + raw, () => {
    const value = JSON.parse(raw);
    assert.deepEqual(units(value), expected);
    assert.equal(JSON.stringify(value), json);
    assert.deepEqual(units(JSON.parse('{"v":[' + raw + ']}').v[0]), expected);
  });
}

test('native key duplicate equivalence, numeric enumeration and positional collision literals', () => {
  const value = JSON.parse('{"z":0,"\\uD83D":"first","2":"two","\\ud83d":"last","10":"ten","a":1,"\\u0061":2,"😀":"raw","\\ud83d\\ude00":"pair-last","Pdg=":"ordinary"}');
  assert.deepEqual(Object.keys(value).map(units), [[50], [49, 48], [122], [55357], [97], [55357, 56832], [80, 100, 103, 61]]);
  assert.equal(JSON.stringify(value), '{"2":"two","10":"ten","z":0,"\\ud83d":"last","a":2,"😀":"pair-last","Pdg=":"ordinary"}');
  const raw = '{"\\ud83d":"\\ude00","\\u0000":"\\ud83d","\\\\ud83d":"\\u0000","":"\\ud800","﷐":"\\udfff","\\ude00":"\\\\ude00"}';
  const collision = JSON.parse(raw);
  assert.deepEqual(Object.keys(collision).map(units), [[55357], [0], [92, 117, 100, 56, 51, 100], [57344], [64976], [56832]]);
  assert.deepEqual(Object.values(collision).map(units), [[56832], [55357], [0], [55296], [57343], [92, 117, 100, 101, 48, 48]]);
  assert.equal(JSON.stringify(collision), raw);
});

test('native empty control astral unpaired member names and finite signed-zero numbers', () => {
  const value = JSON.parse('{"":0,"\\u0000":1,"a\\tb":2,"\\ud800A\\udfff":3,"\\ud83d\\ud83d\\ude00\\ude00":4,"雪😀":5}');
  assert.deepEqual(Object.keys(value).map(units), [[], [0], [97, 9, 98], [55296, 65, 57343], [55357, 55357, 56832, 56832], [38634, 55357, 56832]]);
  assert.equal(JSON.stringify(value), '{"":0,"\\u0000":1,"a\\tb":2,"\\ud800A\\udfff":3,"\\ud83d😀\\ude00":4,"雪😀":5}');
  const numbers = JSON.parse('["\\ud83d",-0,-0e2,-0.0,0,9007199254740993,1e23,1e-7,0.1]');
  const bits = numbers.slice(1).map(number => { const bytes = Buffer.alloc(8); bytes.writeDoubleBE(number); return bytes.toString('hex'); });
  assert.deepEqual(bits, ['8000000000000000', '8000000000000000', '8000000000000000', '0000000000000000', '4340000000000000', '44b52d02c7e14af6', '3e7ad7f29abcaf48', '3fb999999999999a']);
  assert.equal(JSON.stringify(numbers), '["\\ud83d",0,0,0,0,9007199254740992,1e+23,1e-7,0.1]');
});

function graph() {
  return {
    version: 1, next_id: 8, nodes: {
      '1': { type: 'object', keys: [HIGH, 'Pdg=', 'nested', 'own', 'zero'], fields: { 'Pdg=': string('ordinary'), nested: ref('2'), own: { type: 'undefined' }, zero: { type: 'number', bits: '8000000000000000' } }, fields_utf16le: { 'Pdg=': LOW } },
      '2': { type: 'object', keys: [LOW], fields: {}, fields_utf16le: { 'AN4=': HIGH } },
      '3': { type: 'array', items: [ref('1'), ref('2'), ref('1')] },
      '4': { type: 'object', keys: ['type', 'required'], fields: { type: string('object'), required: ref('7') } },
      '7': { type: 'array', items: [HIGH] },
    }
  };
}

test('decodeRoots mixed-key shells preserve own fields aliases signed zero and exact units', () => {
  const heap = graph();
  heap.next_id = 8;
  const before = JSON.stringify(heap);
  const { schema, response } = decodeRoots({ schema: ref('1'), response: ref('3') }, heap);
  assert.deepEqual(Object.keys(schema).map(units), [[55357], [80, 100, 103, 61], [110, 101, 115, 116, 101, 100], [111, 119, 110], [122, 101, 114, 111]]);
  assert.deepEqual(units(schema['\ud83d']), [56832]);
  assert.equal(schema['Pdg='], 'ordinary');
  assert.equal(Object.hasOwn(schema, 'own'), true);
  assert.equal(schema.own, undefined);
  assert.equal(Object.is(schema.zero, -0), true);
  assert.strictEqual(response[0], schema);
  assert.strictEqual(response[1], schema.nested);
  assert.strictEqual(response[2], schema);
  assert.deepEqual(units(schema.nested['\ude00']), [55357]);
  schema.nested['\ude00'] = 'changed decoded graph';
  assert.equal(response[1]['\ude00'], 'changed decoded graph');
  assert.equal(JSON.stringify(heap), before);
});

async function collect(input) { const items = []; for await (const item of input) items.push(item); return items; }
async function runtime(pipeline, input, resume) {
  const sink = { write() { return true; } };
  return runPipeline({ pipeline, registry: { get(name) { return commands[name]; } }, input, mode: 'tool', renderOutput: false, stdin: { isTTY: false }, stdout: sink, stderr: sink, env: {}, requestInputResume: resume });
}

test('whole original map and template commands retain arbitrary siblings and shared aliases', async () => {
  const item = JSON.parse('{"\\ud83d":"\\ude00","v":"A"}');
  const mapped = await commands.map.run({ input: [item, item], args: { _: ['v={{v}}!'] } });
  const values = await collect(mapped.output);
  assert.strictEqual(values[0], item);
  assert.strictEqual(values[1], item);
  assert.equal(item.v, 'A!!');
  assert.deepEqual(units(item['\ud83d']), [56832]);
  const output = await commands.template.run({ input: [JSON.parse(RESPONSE)], args: { text: '{{. | json}}' } });
  assert.deepEqual(await collect(output.output), [PROJECTION]);
});

test('whole original runtime and actual Ajv support same/next ordinary successful resume', async () => {
  assert.equal(compileCached(JSON.parse(SCHEMA))(JSON.parse(RESPONSE)), true);
  for (const emit of [false, true]) {
    const stages = [{ name: 'ask', args: { prompt: 'Review', schema: SCHEMA, emit } }, { name: 'template', args: { text: '{{. | json}}' } }];
    const first = await runtime(stages, []);
    assert.equal(first.halted, true);
    const [request] = first.items;
    assert.equal(request.prompt, 'Review');
    assert.deepEqual(request.responseSchema.required.map(units), [[55357]]);
    let completed;
    if (emit) completed = await runtime(stages.slice(1), [JSON.parse(RESPONSE)]);
    else {
      const resume = { state: JSON.parse(JSON.stringify(request.commandInput)), response: JSON.parse(RESPONSE), consumed: false };
      completed = await runtime(stages, [], resume);
      assert.equal(resume.consumed, true);
    }
    assert.equal(completed.halted, false);
    assert.deepEqual(completed.items, [PROJECTION]);
  }
});

test('whole original table writes exact header units through an actual Node Writable', async () => {
  const writes = [], chunks = [];
  const sink = new Writable({ write(chunk, _encoding, done) { chunks.push(Buffer.from(chunk)); done(); } });
  const original = sink.write.bind(sink);
  sink.write = (text, ...args) => { writes.push(text); return original(text, ...args); };
  const rows = JSON.parse('[{"\\ud83d":"\\ude00","😀":"X","a\\nb":"Y"}]');
  const before = JSON.stringify(rows);
  const result = await commands.table.run({ input: rows, ctx: { renderOutput: true, stdout: sink } });
  sink.end();
  await finished(sink);
  assert.deepEqual(writes.map(text => JSON.stringify(text)), ['"\\ud83d    😀   a b\\n"', '"---  ---  ---\\n"', '"\\ude00    X    Y  \\n"']);
  assert.deepEqual(units(writes[0]), [55357, 32, 32, 32, 32, 55357, 56832, 32, 32, 32, 97, 32, 98, 10]);
  assert.deepEqual(Buffer.concat(chunks), Buffer.from('�    😀   a b\n---  ---  ---\n�    X    Y  \n'));
  assert.equal(result.rendered, true);
  assert.deepEqual(await collect(result.output), []);
  assert.equal(JSON.stringify(rows), before);
});

async function* frames(stream) {
  let buffer = '';
  for await (const bytes of stream) {
    buffer += bytes.toString('utf8');
    let lf;
    while ((lf = buffer.indexOf('\n')) !== -1) { yield JSON.parse(buffer.slice(0, lf)); buffer = buffer.slice(lf + 1); }
  }
  assert.equal(buffer, '');
}

async function helperSession(t, path) {
  const child = spawn(process.execPath, [path], { stdio: ['pipe', 'pipe', 'pipe'] });
  const stderr = [];
  child.stderr.on('data', bytes => stderr.push(bytes));
  const completion = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const iterator = frames(child.stdout);
  function bounded(promise) {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ordinary helper deadline')), 20000); })]).finally(() => clearTimeout(timer));
  }
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await bounded(completion); } });
  async function next() { const frame = await bounded(iterator.next()); assert.equal(frame.done, false); return frame.value; }
  assert.deepEqual(await next(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
  const pid = child.pid;
  const heap = graph(); heap.next_id = 8;
  // A separate strictly JSON response excludes the graph's own undefined field.
  heap.nodes['8'] = { type: 'object', keys: [HIGH, 'Pdg=', 'nested'], fields: { 'Pdg=': string('ordinary'), nested: ref('2') }, fields_utf16le: { 'Pdg=': LOW } };
  heap.next_id = 9;
  async function fulfill(request) {
    const before = JSON.stringify(heap);
    child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap }) + '\n');
    const result = await next();
    assert.equal(child.pid, pid);
    assert.equal(child.exitCode, null);
    assert.equal(existsSync('/proc/' + pid), true);
    assert.equal(JSON.stringify(heap), before);
    return result;
  }
  const receipt = (id, outcome, value) => ({ type: 'result', id, result: 'ok', outcome, ...(value ? { value } : {}), cacheEntries: 1 });
  assert.deepEqual(await fulfill({ id: 'compile', kind: 'compile_schema', schema: ref('4') }), receipt('compile', 'compiled'));
  assert.deepEqual(await fulfill({ id: 'valid', kind: 'validate_response', schema: ref('4'), response: ref('8') }), receipt('valid', 'valid'));
  assert.deepEqual(await fulfill({ id: 'render', kind: 'render_template', template: string('{{. | json}}'), item: ref('8') }), receipt('render', 'rendered', string(PROJECTION)));
  assert.deepEqual(await fulfill({ id: 'compile-again', kind: 'compile_schema', schema: ref('4') }), receipt('compile-again', 'compiled'));
  assert.deepEqual(await fulfill({ id: 'valid-again', kind: 'validate_response', schema: ref('4'), response: ref('8') }), receipt('valid-again', 'valid'));
  child.stdin.write('{"type":"close"}\n');
  assert.deepEqual(await next(), { type: 'closed' });
  assert.deepEqual(await bounded(completion), { code: 0, signal: null });
  assert.equal((await bounded(iterator.next())).done, true);
  assert.equal(existsSync('/proc/' + pid), false);
  assert.equal(Buffer.concat(stderr).toString('utf8'), '');
}

test('source helper keeps one PID and Ajv cache for exact lone names and safe JSON template', { timeout: 120000 }, async t => {
  await helperSession(t, join(repository, 'packages/tool-host/src/workflow/schema-stdio.mjs'));
});
test('physically relocated complete helper keeps one PID and cache and exits normally', { timeout: 120000 }, async t => {
  await helperSession(t, join(relocated, 'schema-stdio.mjs'));
});
