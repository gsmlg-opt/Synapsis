import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync, symlinkSync, rmSync } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Independent source oracle: all semantic modules are whole unchanged archive
// files. No Synapsis implementation executes. Expected literals precede product.
const corpus = JSON.parse(readFileSync(new URL('./fixtures/workflow-template-requests.json', import.meta.url)));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const units = text => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));
let directory, templateCommand, headCommand, mapCommand, runPipeline;
const stage = (name, args) => ({ name, args });

before(async () => {
  const archive = process.env.SYNAPSIS_LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
  assert.equal(digest(readFileSync(archive)), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
  directory = mkdtempSync(join(tmpdir(), 'synapsis-machine-template-source-'));
  execFileSync('tar', ['-xzf', resolve(archive), '-C', directory]);
  const upstream = join(directory, 'package');
  const source = {
    'dist/src/commands/stdlib/template.js': '27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac',
    'dist/src/core/filters.js': 'd7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14',
    'dist/src/core/value_path.js': 'e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f',
    'dist/src/commands/stdlib/map.js': 'faeebf18c5db3903ae5e03270b87f49e5a1b8a5324276add6ca52c83763d8e27',
    'dist/src/runtime.js': '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53',
    'dist/src/input_request.js': '4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4',
    'dist/src/commands/stdlib/head.js': '3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1',
  };
  for (const [path, expected] of Object.entries(source)) assert.equal(digest(readFileSync(join(upstream, path))), expected, path);
  // Dependencies are supplied unchanged by the existing helper package.
  symlinkSync(fileURLToPath(new URL('../../../apps/synapsis_core/priv/workflow_schema/node_modules', import.meta.url)), join(upstream, 'node_modules'), 'dir');
  const load = path => import(pathToFileURL(join(upstream, `dist/src/${path}.js`)));
  ({ templateCommand } = await load('commands/stdlib/template'));
  ({ headCommand } = await load('commands/stdlib/head'));
  ({ mapCommand } = await load('commands/stdlib/map'));
  ({ runPipeline } = await load('runtime'));
});
after(() => { if (directory) rmSync(directory, { recursive: true, force: true }); });

async function collect(input) { const items = []; for await (const item of input) items.push(item); return items; }
function materialize(root, heap, memo = new Map()) {
  switch (root.type) {
    case 'undefined': return undefined;
    case 'null': return null;
    case 'boolean': return root.value;
    case 'number': return Buffer.from(root.bits, 'hex').readDoubleBE();
    case 'string': return root.utf16le === undefined ? root.value : Buffer.from(root.utf16le, 'base64').toString('utf16le');
    case 'reference': {
      if (memo.has(root.id)) return memo.get(root.id);
      const node = heap.nodes[root.id];
      const value = node.type === 'array' ? [] : {};
      memo.set(root.id, value);
      if (node.type === 'array') value.push(...node.items.map(item => materialize(item, heap, memo)));
      else for (const key of node.keys) Object.defineProperty(value, key, { value: materialize(node.fields[key], heap, memo), enumerable: true, writable: true, configurable: true });
      return value;
    }
    default: assert.fail(`unexpected frozen tag ${root.type}`);
  }
}
function observed(items, events = []) {
  const counters = { opens: 0, yields: 0, finishes: 0 };
  return { counters, input: (async function* () {
    counters.opens++; events.push('input:open');
    try { for (const item of items) { counters.yields++; events.push('input:yield'); yield item; } }
    finally { counters.finishes++; events.push('input:finish'); }
  })() };
}
async function runtime(pipeline, input, events = []) {
  const commands = { template: templateCommand, head: headCommand, map: mapCommand };
  const registry = { get(name) {
    const command = commands[name];
    return { ...command, async run(args) {
      events.push(`construct:${name}`);
      const result = await command.run(args);
      events.push(`constructed:${name}`);
      return result;
    } };
  } };
  const sink = { write() { return true; } };
  return runPipeline({ pipeline, registry, input, stdout: sink, stderr: sink, stdin: { isTTY: false }, env: {}, mode: 'tool', renderOutput: false });
}

test('all 137 frozen strings execute through the original lazy template command', async () => {
  assert.equal(corpus.cases.length, 137);
  for (const item of corpus.cases) {
    const result = await templateCommand.run({ args: { text: materialize(item.request.template, item.heap) }, input: [materialize(item.request.item, item.heap)] });
    const output = await collect(result.output);
    assert.equal(output.length, 1, item.id);
    assert.deepEqual(units(output[0]), item.expected_units, item.id);
    assert.equal(JSON.stringify(output[0]), item.expected_json, item.id);
  }
});

test('typed text/file guards, whitespace, empty-file fallback and positional joining', async () => {
  const full = join(directory, 'full.txt'), empty = join(directory, 'empty.txt');
  await fs.writeFile(full, 'FILE {{name}}'); await fs.writeFile(empty, '');
  const vectors = [
    [{ text: 'TEXT {{name}}', file: full, _: ['POSITIONAL'] }, 'TEXT Ada'],
    [{ text: '  ', file: full }, '  '],
    [{ text: '', file: full }, 'FILE Ada'],
    [{ text: true, file: full }, 'FILE Ada'],
    [{ file: empty, _: ['POSITIONAL', '{{name}}'] }, 'POSITIONAL Ada'],
    [{ text: '', file: '', _: ['Hello', '{{name}}', '!'] }, 'Hello Ada !'],
    [{ text: true, file: true, _: ['TYPED', '{{name}}'] }, 'TYPED Ada'],
    [{ text: false, file: 3, _: ['JOIN', null, 'END'] }, 'JOIN  END'],
  ];
  for (const [args, expected] of vectors) {
    const result = await templateCommand.run({ args, input: [{ name: 'Ada' }] });
    assert.deepEqual(await collect(result.output), [expected]);
  }
});

test('actual runtime reads during construction before downstream and before input, including head0/empty', async () => {
  const file = join(directory, 'order.txt'); await fs.writeFile(file, 'BEFORE {{name}}');
  const original = fs.readFile;
  try {
    for (const [items, tail, expected, counts] of [
      [[{ name: 'Ada' }, { name: 'Bob' }], [stage('head', { n: '0' })], [], { opens: 0, yields: 0, finishes: 0 }],
      [[], [], [], { opens: 1, yields: 0, finishes: 1 }],
      [[{ name: 'Ada' }, { name: 'Bob' }], [stage('head', { n: '1' })], ['BEFORE Ada'], { opens: 1, yields: 1, finishes: 1 }],
    ]) {
      const events = [];
      fs.readFile = async (...args) => { if (args[0] === file) events.push('read:file'); return original(...args); };
      const { input, counters } = observed(items, events);
      const result = await runtime([stage('template', { file }), ...tail], input, events);
      assert.deepEqual(result.items, expected);
      assert.deepEqual(counters, counts);
      assert.deepEqual(events.slice(0, 3), ['construct:template', 'read:file', 'constructed:template']);
      assert.equal(events.filter(event => event === 'read:file').length, 1);
      if (tail.length) assert.deepEqual(events.slice(3, 5), ['construct:head', 'constructed:head']);
      assert.equal(result.rendered, false); assert.deepEqual(result.renderedItems, []);
    }
  } finally { fs.readFile = original; }
});

test('loaded file text stays retained across demands and two constructors read independently', async () => {
  const file = join(directory, 'retained.txt'); await fs.writeFile(file, 'BEFORE {{name}}');
  const { input, counters } = observed([{ name: 'Ada' }, { name: 'Bob' }]);
  const result = await templateCommand.run({ args: { file }, input });
  assert.deepEqual(counters, { opens: 0, yields: 0, finishes: 0 });
  await fs.writeFile(file, 'AFTER {{name}}');
  const iterator = result.output[Symbol.asyncIterator]();
  assert.deepEqual(await iterator.next(), { done: false, value: 'BEFORE Ada' });
  assert.deepEqual(counters, { opens: 1, yields: 1, finishes: 0 });
  assert.deepEqual(await iterator.next(), { done: false, value: 'BEFORE Bob' });
  await iterator.return();
  assert.deepEqual(counters, { opens: 1, yields: 2, finishes: 1 });
  const second = join(directory, 'second.txt'); await fs.writeFile(second, '[{{.}}]');
  const original = fs.readFile, reads = [];
  try {
    fs.readFile = async (...args) => { if ([file, second].includes(args[0])) reads.push(args[0]); return original(...args); };
    assert.deepEqual((await runtime([stage('template', { file }), stage('template', { file: second })], [{ name: 'Ada' }])).items, ['[AFTER Ada]']);
    assert.deepEqual(reads, [file, second]);
    reads.length = 0;
    await fs.writeFile(file, '{{.}}!');
    assert.deepEqual((await runtime([stage('template', { file }), stage('template', { file })], ['A'])).items, ['A!!']);
    assert.deepEqual(reads, [file, file]);
  } finally { fs.readFile = original; }
});

test('one render per demand observes current shared object and keeps earlier strings immutable', async () => {
  const item = { v: 'one' }, { input, counters } = observed([item, item]);
  const result = await templateCommand.run({ args: { text: '{{v}}' }, input });
  const iterator = result.output[Symbol.asyncIterator]();
  const first = await iterator.next(); assert.equal(first.value, 'one');
  assert.deepEqual(counters, { opens: 1, yields: 1, finishes: 0 });
  item.v = 'two';
  assert.equal((await iterator.next()).value, 'two'); assert.equal(first.value, 'one');
  await iterator.return(); assert.equal(counters.finishes, 1);
  const shared = { v: 'A' };
  assert.deepEqual((await runtime([stage('map', { _: ['v={{v}}!'] }), stage('template', { text: '{{v}}' })], [shared, shared])).items, ['A!', 'A!!']);
});
