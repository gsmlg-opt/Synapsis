import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Writable } from 'node:stream';
import { finished } from 'node:stream/promises';

// Same frozen literals as ExUnit. Only unchanged full upstream modules execute
// command semantics; this harness supplies ordinary input/context and observes it.
const fixture = JSON.parse(readFileSync(new URL('./fixtures/workflow-machine-utf16-cases.json', import.meta.url)));
const units = text => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
let directory;
let commands;

before(async () => {
  const archive = process.env.SYNAPSIS_LOBSTER_ARCHIVE;
  assert.ok(archive, 'set SYNAPSIS_LOBSTER_ARCHIVE to the pinned official archive');
  assert.equal(hash(readFileSync(archive)), fixture.provenance.archive_sha256);
  directory = mkdtempSync(join(tmpdir(), 'synapsis-machine-utf16-source-'));
  execFileSync('tar', ['-xzf', resolve(archive), '-C', directory]);
  const upstream = join(directory, 'package');
  for (const [relative, expected] of Object.entries(fixture.provenance.source_sha256)) {
    assert.equal(hash(readFileSync(join(upstream, relative))), expected, relative);
  }
  const dependencies = fileURLToPath(new URL('../../../apps/synapsis_core/priv/workflow_schema/node_modules', import.meta.url));
  symlinkSync(dependencies, join(upstream, 'node_modules'), 'dir');
  commands = {};
  for (const [name, module, exported] of [
    ['map', 'map', 'mapCommand'], ['sort', 'sort', 'sortCommand'],
    ['where', 'where', 'whereCommand'], ['dedupe', 'dedupe', 'dedupeCommand'],
    ['groupBy', 'group_by', 'groupByCommand'], ['table', 'table', 'tableCommand'],
    ['ask', 'ask', 'askCommand']
  ]) {
    commands[name] = (await import(pathToFileURL(join(upstream, `dist/src/commands/stdlib/${module}.js`))))[exported];
  }
});

after(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});

function materialize(value) {
  if (value && !Array.isArray(value) && Object.hasOwn(value, '$string')) {
    return Buffer.from(fixture.strings[value.$string].base64, 'base64').toString('utf16le');
  }
  if (Array.isArray(value)) return value.map(materialize);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, materialize(v)]));
  return value;
}

async function collect(input) {
  const items = [];
  for await (const item of input) items.push(item);
  return items;
}

for (const [name, item] of Object.entries(fixture.strings)) {
  test(`literal string code units and JSON: ${name}`, () => {
    const value = materialize({ $string: name });
    assert.deepEqual(units(value), item.units);
    assert.equal(Buffer.from(value, 'utf16le').toString('base64'), item.base64);
    assert.equal(JSON.stringify(value), item.json);
  });
}

for (const item of fixture.cases) {
  test(`whole original commands: ${item.id}`, async () => {
    const roots = materialize(item.input);
    if (item.alias_first) roots.push(roots[0]);
    let output = roots;
    for (const stage of item.stages) {
      output = (await commands[stage.name].run({ input: output, args: stage.args })).output;
    }
    const result = await collect(output);
    assert.deepEqual(result.map(value => JSON.stringify(value)), item.expected_json);
    if (item.indices) assert.deepEqual(result.map(value => roots.indexOf(value)), item.indices);
    if (item.alias_first) assert.equal(result[0], result[1]);
    for (const [field, names] of Object.entries(item.fields ?? {})) {
      names.forEach((name, i) => assert.deepEqual(units(result[i][field]), fixture.strings[name].units));
    }
    if (item.group_indices) {
      item.group_indices.forEach((indices, i) => {
        assert.deepEqual(result[i].items.map(value => roots.indexOf(value)), indices);
        assert.deepEqual(units(result[i].key), fixture.strings[item.group_keys[i]].units);
      });
    }
  });
}

for (const item of fixture.previews) {
  test(`whole original ask with actual Ajv: ${item.id}`, async () => {
    const input = item.input_repeat
      ? [String.fromCharCode(item.input_repeat.unit).repeat(item.input_repeat.count) + item.input_repeat.suffix]
      : materialize(item.input);
    const result = await commands.ask.run({
      input, args: { prompt: 'Review', schema: '{}', emit: true, 'subject-from-stdin': true },
      ctx: { mode: 'tool', stdin: { isTTY: false } }
    });
    assert.equal(result.halt, true);
    const [request] = await collect(result.output);
    const expectedUnits = item.expected_repeat
      ? [...Array(item.expected_repeat.count).fill(item.expected_repeat.unit), ...item.expected_repeat.tail_units]
      : item.expected_units;
    const expectedJSON = item.expected_json_repeat
      ? `"${item.expected_json_repeat.prefix.repeat(item.expected_json_repeat.count)}${item.expected_json_repeat.tail}"`
      : item.expected_json;
    assert.deepEqual(units(request.subject.text), expectedUnits);
    assert.equal(JSON.stringify(request.subject.text), expectedJSON);
    assert.deepEqual(request.responseSchema, {});
    assert.deepEqual(request.items, input);
  });
}

for (const item of fixture.tables) {
  test(`whole original table through real Node Writable: ${item.id}`, async () => {
    const chunks = [];
    const writes = [];
    // decodeStrings defaults to true: Node itself converts each string write.
    const sink = new Writable({ write(chunk, _encoding, done) { chunks.push(Buffer.from(chunk)); done(); } });
    const originalWrite = sink.write.bind(sink);
    sink.write = (text, ...args) => { writes.push(text); return originalWrite(text, ...args); };
    const input = materialize(item.input);
    const before = input.map(value => JSON.stringify(value));
    const result = await commands.table.run({ input, ctx: { renderOutput: true, stdout: sink } });
    sink.end();
    await finished(sink);
    assert.equal(result.rendered, true);
    assert.deepEqual(await collect(result.output), []);
    assert.deepEqual(writes.map(value => JSON.stringify(value)), item.writes_json);
    assert.deepEqual(Buffer.concat(chunks), Buffer.from(item.stdout, 'utf8'));
    assert.deepEqual(input.map(value => JSON.stringify(value)), before);
  });
}
