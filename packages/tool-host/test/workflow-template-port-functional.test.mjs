// Independently frozen ordinary expectations; no formatter computes expected output.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { decodeRoots } from '../src/workflow/schema.mjs';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/workflow-template-requests.json', import.meta.url), 'utf8'));
const helperPath = fileURLToPath(new URL('../src/workflow/schema-stdio.mjs', import.meta.url));
const emptyHeap = () => ({ version: 1, next_id: 1, nodes: {} });
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

function freeze(value) {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function utf16(value) {
  return value.utf16le === undefined
    ? Buffer.from(value.value, 'utf16le')
    : Buffer.from(value.utf16le, 'base64');
}

function units(bytes) {
  return Array.from({ length: bytes.length / 2 }, (_, index) => bytes.readUInt16LE(index * 2));
}

function stringSchema(id, kind, response) {
  const request = { id, kind, schema: { type: 'reference', id: '1' } };
  if (kind === 'validate_response') request.response = response;
  return {
    request,
    heap: {
      version: 1, next_id: 2,
      nodes: { '1': { type: 'object', keys: ['type'], fields: { type: { type: 'string', value: 'string' } } } }
    }
  };
}

function enumSchema(id, kind, lone) {
  const request = { id, kind, schema: { type: 'reference', id: '1' } };
  if (kind === 'validate_response') request.response = lone;
  return {
    request,
    heap: {
      version: 1, next_id: 3,
      nodes: {
        '1': { type: 'object', keys: ['enum'], fields: { enum: { type: 'reference', id: '2' } } },
        '2': { type: 'array', items: [lone] }
      }
    }
  };
}

function receipt(id, outcome, cacheEntries, value) {
  return { type: 'result', id, result: 'ok', outcome, ...(value === undefined ? {} : { value }), cacheEntries };
}

test('frozen corpus retains both independent source hashes and all 137 literal expectations', () => {
  assert.equal(fixture.version, 1);
  assert.equal(fixture.provenance.template_count, 114);
  assert.equal(fixture.provenance.utf16_count, 23);
  assert.equal(fixture.provenance.total_count, 137);
  assert.equal(fixture.cases.length, 137);
  assert.equal(new Set(fixture.cases.map(item => item.id)).size, 137);
  const templateSource = readFileSync(new URL('./workflow-template-functional.test.mjs', import.meta.url), 'utf8');
  assert.equal(sha(templateSource), fixture.provenance.template_source_sha256);
  const literal = templateSource.match(/const CASES = (\[[\s\S]*?\n\]);/)[1];
  assert.equal(sha(literal), fixture.provenance.template_literal_sha256);
  assert.equal(sha(readFileSync(new URL('./fixtures/workflow-utf16-string-cases.json', import.meta.url))),
    fixture.provenance.utf16_source_sha256);
  assert.equal(fixture.cases.filter(item => item.corpus === 'template_literals').length, 114);
  assert.equal(fixture.cases.filter(item => item.corpus === 'utf16_passthrough').length, 23);
  for (const item of fixture.cases) {
    assert.equal(item.request.id, item.id);
    assert.equal(item.request.kind, 'render_template');
    assert.equal(utf16(item.expected).toString('base64'), item.expected_utf16le, item.id);
    assert.deepEqual(units(utf16(item.expected)), item.expected_units, item.id);
    // JSON.parse is only a test observation of the already frozen JSON literal.
    assert.deepEqual(units(Buffer.from(JSON.parse(item.expected_json), 'utf16le')), item.expected_units, item.id);
  }
});

test('decodeRoots preserves a shared nested heap, own undefined, signed zero and lone UTF16 strings', () => {
  const graph = freeze({
    request: { schema: { type: 'reference', id: '1' }, response: { type: 'reference', id: '3' } },
    heap: {
      version: 1, next_id: 4,
      nodes: {
        '1': {
          type: 'object', keys: ['z', 'own', 'zero', 'lone', 'nested'], fields: {
            z: { type: 'boolean', value: true }, own: { type: 'undefined' },
            zero: { type: 'number', bits: '8000000000000000' },
            lone: { type: 'string', utf16le: 'Pdg=' }, nested: { type: 'reference', id: '2' }
          }
        },
        '2': { type: 'array', items: [{ type: 'reference', id: '1' }, { type: 'string', utf16le: 'AN4=' }] },
        '3': { type: 'array', items: [{ type: 'reference', id: '1' }, { type: 'reference', id: '2' }] }
      }
    }
  });
  const before = JSON.stringify(graph);
  const { schema, response } = decodeRoots(graph.request, graph.heap);
  assert.deepEqual(Object.keys(schema), ['z', 'own', 'zero', 'lone', 'nested']);
  assert.equal(Object.hasOwn(schema, 'own'), true);
  assert.equal(schema.own, undefined);
  assert.equal(Object.is(schema.zero, -0), true);
  assert.deepEqual(Array.from(schema.lone, char => char.charCodeAt(0)), [0xd83d]);
  assert.equal(schema.lone.length, 1);
  assert.equal(schema.nested[1].charCodeAt(0), 0xde00);
  assert.equal(schema.nested[1].length, 1);
  assert.strictEqual(response[0], schema);
  assert.strictEqual(response[1], schema.nested);
  assert.strictEqual(schema.nested[0], schema);
  schema.nested.push('changed decoded graph');
  assert.equal(response[1][2], 'changed decoded graph');
  assert.equal(JSON.stringify(graph), before);
});

async function* lfFrames(stream) {
  let pending = Buffer.alloc(0);
  for await (const chunk of stream) {
    pending = Buffer.concat([pending, chunk]);
    let lf;
    while ((lf = pending.indexOf(0x0a)) !== -1) {
      const frame = pending.subarray(0, lf);
      pending = pending.subarray(lf + 1);
      yield frame.toString('utf8');
    }
  }
  if (pending.length !== 0) throw new Error('unterminated helper frame');
}

async function withSession(t, run) {
  const child = spawn(process.execPath, [helperPath], { stdio: ['pipe', 'pipe', 'pipe'] });
  const stderr = [];
  child.stderr.on('data', bytes => stderr.push(bytes));
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const iterator = lfFrames(child.stdout);
  let watchdog;
  const bounded = (operation, label) => Promise.race([
    operation,
    new Promise((_, reject) => { watchdog = setTimeout(() => reject(new Error(label + ' timed out')), 20_000); })
  ]).finally(() => clearTimeout(watchdog));
  t.after(async () => {
    // Defensive owned-process cleanup only if an ordinary assertion fails.
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
      await bounded(completion, 'defensive process cleanup');
    }
  });
  async function nextFrame() {
    const next = await bounded(iterator.next(), 'helper frame');
    assert.equal(next.done, false, Buffer.concat(stderr).toString('utf8'));
    return JSON.parse(next.value);
  }
  assert.deepEqual(await nextFrame(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
  const pid = child.pid;
  assert.equal(existsSync('/proc/' + pid), true);
  await run(async ({ request, heap }) => {
    const before = JSON.stringify({ request, heap });
    child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap }) + '\n');
    const result = await nextFrame();
    assert.equal(child.pid, pid);
    assert.equal(child.exitCode, null);
    assert.equal(existsSync('/proc/' + pid), true);
    assert.equal(JSON.stringify({ request, heap }), before);
    return result;
  });
  child.stdin.write('{"type":"close"}\n');
  assert.deepEqual(await nextFrame(), { type: 'closed' });
  assert.deepEqual(await bounded(completion, 'normal helper exit'), { code: 0, signal: null });
  assert.equal(existsSync('/proc/' + pid), false);
  assert.equal((await bounded(iterator.next(), 'stdout completion')).done, true);
  assert.equal(Buffer.concat(stderr).toString('utf8'), '');
}

test('one actual stdio PID renders all literals and keeps the same Ajv cache across rendering and reuse', { timeout: 120000 }, async t => {
  await withSession(t, async fulfill => {
    assert.deepEqual(await fulfill(stringSchema('compile:before', 'compile_schema')),
      receipt('compile:before', 'compiled', 1));
    assert.deepEqual(await fulfill(stringSchema('validate:before', 'validate_response', { type: 'string', value: 'ordinary' })),
      receipt('validate:before', 'valid', 1));
    let generatedLone;
    for (const item of fixture.cases) {
      const operation = freeze(structuredClone({ request: item.request, heap: item.heap }));
      const actual = await fulfill(operation);
      assert.deepEqual(actual, receipt(item.id, 'rendered', 1, item.expected), item.id);
      assert.equal(utf16(actual.value).toString('base64'), item.expected_utf16le, item.id);
      assert.deepEqual(units(utf16(actual.value)), item.expected_units, item.id);
      if (item.id === 'split-empty-first-surrogate') generatedLone = actual.value;
    }
    // Separate from the 137 frozen cases: both template and item roots must
    // decode in the same heap, including lone units in the template itself.
    const loneTemplate = {
      request: {
        id: 'lone:template-root', kind: 'render_template',
        template: { type: 'string', utf16le: 'Pdh7AHsAdgB9AH0AAN4=' },
        item: { type: 'reference', id: '1' }
      },
      heap: {
        version: 1, next_id: 2,
        nodes: { '1': { type: 'object', keys: ['v'], fields: { v: { type: 'string', value: '雪' } } } }
      }
    };
    const templateResult = await fulfill(freeze(loneTemplate));
    assert.deepEqual(templateResult,
      receipt('lone:template-root', 'rendered', 1, { type: 'string', utf16le: 'PdjqlgDe' }));
    assert.deepEqual(units(utf16(templateResult.value)), [0xd83d, 0x96ea, 0xde00]);
    assert.deepEqual(await fulfill(stringSchema('compile:after', 'compile_schema')),
      receipt('compile:after', 'compiled', 1));
    assert.deepEqual(await fulfill(stringSchema('validate:after', 'validate_response', { type: 'string', value: 'ordinary' })),
      receipt('validate:after', 'valid', 1));
    assert.deepEqual(generatedLone, { type: 'string', utf16le: 'Pdg=' });
    assert.deepEqual(await fulfill(enumSchema('enum:compile', 'compile_schema', generatedLone)),
      receipt('enum:compile', 'compiled', 2));
    assert.deepEqual(await fulfill(enumSchema('enum:validate', 'validate_response', generatedLone)),
      receipt('enum:validate', 'valid', 2));
    const reuse = {
      request: { id: 'reuse:lone', kind: 'render_template', template: { type: 'string', value: '{{.}}' }, item: generatedLone },
      heap: emptyHeap()
    };
    assert.deepEqual(await fulfill(reuse), receipt('reuse:lone', 'rendered', 2, { type: 'string', utf16le: 'Pdg=' }));
    const length = {
      request: { id: 'reuse:length', kind: 'render_template', template: { type: 'string', value: '{{. | length}}' }, item: generatedLone },
      heap: emptyHeap()
    };
    assert.deepEqual(await fulfill(length), receipt('reuse:length', 'rendered', 2, { type: 'string', value: '1' }));
  });
});
