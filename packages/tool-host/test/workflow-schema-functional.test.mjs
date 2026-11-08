import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { createValidator, decodeRoots } from '../src/workflow/schema.mjs';

const cases = JSON.parse(readFileSync(new URL('./fixtures/workflow-schema-cases.json', import.meta.url), 'utf8'));
const helperPath = fileURLToPath(new URL('../src/workflow/schema-stdio.mjs', import.meta.url));

// Independently authored before the product implementation. The expected
// outcomes in the fixture are literals, not computed by the validator.
// This encoder belongs only to tests; it does not call a product encoder.
function encode(value, heap, seen = new WeakMap()) {
  if (value === undefined) return { type: 'undefined' };
  if (value === null) return { type: 'null' };
  if (typeof value === 'boolean') return { type: 'boolean', value };
  if (typeof value === 'string') return { type: 'string', value };
  if (typeof value === 'number') {
    const bytes = Buffer.alloc(8);
    bytes.writeDoubleBE(value);
    return { type: 'number', bits: bytes.toString('hex') };
  }
  assert.equal(typeof value, 'object');
  if (seen.has(value)) return { type: 'reference', id: seen.get(value) };

  const id = String(heap.next_id++);
  seen.set(value, id);
  if (Array.isArray(value)) {
    const node = { type: 'array', items: [] };
    heap.nodes[id] = node;
    node.items = value.map(item => encode(item, heap, seen));
  } else {
    const keys = Object.keys(value);
    const node = { type: 'object', keys, fields: Object.create(null) };
    heap.nodes[id] = node;
    for (const key of keys) node.fields[key] = encode(value[key], heap, seen);
  }
  return { type: 'reference', id };
}

function wire(id, kind, schema, responseJson) {
  const heap = { version: 1, next_id: 1, nodes: {} };
  const seen = new WeakMap();
  const request = {
    id, kind, boundary: 'ordinary_literal',
    schema: encode(schema, heap, seen)
  };
  if (kind === 'validate_response') request.response = encode(JSON.parse(responseJson), heap, seen);
  return { request, heap };
}

function success(id, outcome) {
  return { id, result: 'ok', outcome };
}

function operations() {
  return [
    ...cases.compile_cases.map(item => ({
      ...wire('compile:' + item.id, 'compile_schema', item.schema),
      outcome: 'compiled'
    })),
    ...cases.validation_cases.map(item => ({
      ...wire('validate:' + item.id, 'validate_response', item.schema, item.response_json),
      outcome: 'valid'
    }))
  ];
}

test('actual Ajv compiles the four literal normal schemas', () => {
  assert.equal(cases.compile_cases.length, 4);
  for (const item of cases.compile_cases) {
    assert.equal(item.expected, 'compiled');
    const validator = createValidator();
    const { request, heap } = wire(item.id, 'compile_schema', item.schema);
    assert.deepEqual(validator.fulfill(request, heap), success(item.id, 'compiled'), item.id);
    assert.equal(validator.cacheSize(), 1);
  }
});

test('actual Ajv accepts the 34 literal ordinary responses', () => {
  assert.equal(cases.validation_cases.length, 34);
  for (const item of cases.validation_cases) {
    assert.equal(item.expected_valid, true);
    const validator = createValidator();
    const { request, heap } = wire(item.id, 'validate_response', item.schema, item.response_json);
    const before = JSON.stringify({ request, heap });
    if (item.expected_number_bits) assert.equal(request.response.bits, item.expected_number_bits);
    assert.deepEqual(validator.fulfill(request, heap), success(item.id, 'valid'), item.id);
    assert.equal(validator.cacheSize(), 1);
    assert.equal(JSON.stringify({ request, heap }), before);
  }
});

test('the public decoder preserves six ordinary roots, finite bits, own undefined, key order and aliases', () => {
  for (const id of ['root_null', 'root_boolean', 'root_number', 'root_string', 'root_array', 'root_object']) {
    const item = cases.validation_cases.find(entry => entry.id === id);
    const { request, heap } = wire(id, 'validate_response', item.schema, item.response_json);
    const decoded = decodeRoots(request, heap);
    assert.deepEqual(decoded.schema, item.schema);
    assert.deepEqual(decoded.response, JSON.parse(item.response_json));
    if (id === 'root_array') {
      assert.equal(Array.isArray(decoded.response), true);
      assert.equal(Object.getPrototypeOf(decoded.response), Array.prototype);
    }
    if (id === 'root_object') assert.equal(Object.getPrototypeOf(decoded.response), Object.prototype);
  }

  const fixture = cases.codec_cases_deferred_until_api_frozen[0].fixture;
  const request = {
    id: 'decode:graph', kind: 'validate_response', boundary: 'ordinary_codec',
    schema: { type: 'boolean', value: true }, response: fixture.root
  };
  const { schema, response } = decodeRoots(request, fixture.heap);
  assert.equal(schema, true);
  assert.equal(Object.getPrototypeOf(response), Object.prototype);
  assert.deepEqual(Object.keys(response), ['negative_zero', 'positive_zero', 'amount', 'left', 'right', 'missing']);
  assert.equal(Object.is(response.negative_zero, -0), true);
  assert.equal(Object.is(response.positive_zero, 0), true);
  assert.equal(Object.is(response.positive_zero, -0), false);
  assert.equal(response.amount, 1.5);
  assert.equal(response.left, response.right);
  assert.deepEqual(response.left, { label: 'shared' });
  assert.equal(Object.getPrototypeOf(response.left), Object.prototype);
  assert.equal(Object.hasOwn(response, 'missing'), true);
  assert.equal(response.missing, undefined);

  const shared = { label: '一🚀' };
  const original = { z: 1.5, a: shared, b: shared, missing: undefined };
  const heap = { version: 1, next_id: 1, nodes: {} };
  const second = decodeRoots({
    id: 'decode:independent', kind: 'validate_response', boundary: 'ordinary_codec',
    schema: { type: 'boolean', value: true }, response: encode(original, heap)
  }, heap).response;
  assert.deepEqual(Object.keys(second), ['z', 'a', 'b', 'missing']);
  assert.equal(second.a, second.b);
  assert.deepEqual(second.a, { label: '一🚀' });
  assert.equal(Object.hasOwn(second, 'missing'), true);
});

test('content cache survives distinct schemas with the same root ID and reordered keys', () => {
  const validator = createValidator();
  const sequence = cases.sequence_cases[0];
  const expectedSizes = [1, 1, 2, 2, 2, 2];
  sequence.steps.forEach((step, index) => {
    const kind = step.operation === 'compile' ? 'compile_schema' : 'validate_response';
    const outcome = step.operation === 'compile' ? 'compiled' : 'valid';
    const id = 'reuse:' + index;
    const { request, heap } = wire(id, kind, step.schema, step.response_json);
    assert.deepEqual(validator.fulfill(request, heap), success(id, outcome));
    assert.equal(validator.cacheSize(), expectedSizes[index]);
  });
});

async function withStdioSession(t, run) {
  t.diagnostic('Actual helper Node: ' + process.version + ' (' + process.execPath + ')');
  const child = spawn(process.execPath, [helperPath], { stdio: ['pipe', 'pipe', 'pipe'] });
  const diagnostics = [];
  child.stderr.on('data', bytes => diagnostics.push(bytes));
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const iterator = lines[Symbol.asyncIterator]();
  t.after(() => {
    lines.close();
    // Defensive cleanup for a failed test assertion only; cancellation behavior
    // is outside this ordinary-success test's assertions.
    if (child.exitCode === null && child.signalCode === null) child.kill();
  });
  async function nextFrame() {
    const next = await iterator.next();
    assert.equal(next.done, false, Buffer.concat(diagnostics).toString('utf8'));
    return JSON.parse(next.value);
  }
  assert.deepEqual(await nextFrame(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
  assert.equal(existsSync('/proc/' + child.pid), true);

  await run(async (request, heap) => {
    // Canonical protocol prefix: type, timeoutMs, request, heap. Keep the
    // bounded dispatch/deadline prefix ahead of full worker-owned JSON parsing.
    child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap }) + '\n');
    const result = await nextFrame();
    assert.equal(result.type, 'result');
    assert.equal(result.id, request.id);
    assert.equal(result.result, 'ok');
    assert.equal(Number.isInteger(result.cacheEntries), true);
    return result;
  });

  assert.equal(child.exitCode, null);
  assert.equal(existsSync('/proc/' + child.pid), true);
  child.stdin.write(JSON.stringify({ type: 'close' }) + '\n');
  assert.deepEqual(await nextFrame(), { type: 'closed' });
  assert.deepEqual(await completion, { code: 0, signal: null });
  assert.equal(existsSync('/proc/' + child.pid), false);
  assert.equal((await iterator.next()).done, true);
}

test('one persistent stdio helper validates the corpus, retains reused-ID cache and closes normally', { timeout: 90000 }, async t => {
  assert.equal(cases.compile_cases.length, 4);
  assert.equal(cases.validation_cases.length, 34);
  await withStdioSession(t, async fulfill => {
    let baseSize = 0;
    for (const { request, heap, outcome } of operations()) {
      const result = await fulfill(request, heap);
      assert.equal(result.outcome, outcome);
      assert.ok(result.cacheEntries >= 1);
      baseSize = result.cacheEntries;
    }
    const expectedSizes = [1, 1, 2, 2, 2, 2];
    for (const [index, step] of cases.sequence_cases[0].steps.entries()) {
      const kind = step.operation === 'compile' ? 'compile_schema' : 'validate_response';
      const outcome = step.operation === 'compile' ? 'compiled' : 'valid';
      const { request, heap } = wire('stdio:reuse:' + index, kind, step.schema, step.response_json);
      const result = await fulfill(request, heap);
      assert.equal(result.outcome, outcome);
      assert.equal(result.cacheEntries, baseSize + expectedSizes[index]);
    }
  });
});
