// Independent literal expectations for the complete pinned Lobster wrapper.
// The external core and successful file/cwd observations are explicit fixtures.
// This qualifies neither the external workflow engine nor native host execution.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { captureLobster } from './capture-lobster.mjs';

const root = '/tmp/openclaw-488631c';
const captured = await captureLobster(root);
const rows = new Map(captured.vectors.map(row => [row.id, row]));
const digest = value => createHash('sha256').update(value).digest('hex');

// Inputs, core requests and normalized envelopes are authored from the pinned
// wrapper source. They must not be learned from capture output or implementation.
const expected = {
  'inline-defaults': {
    arguments: { action: ' run ', pipeline: ' json "[1,2]" ' },
    method: 'runToolRequest',
    params: { pipeline: 'json "[1,2]"' },
    envelope: { ok: true, status: 'ok', output: [{ kind: 'inline', items: [1, 2] }], requiresApproval: null },
  },
  'inline-args-ignored': {
    arguments: {
      action: 'run', pipeline: ' json "[true]" | json ', argsJson: ' {"ignored":true} ',
      timeoutMs: '25000', maxStdoutBytes: '16384', extra: 'not-forwarded',
    },
    method: 'runToolRequest',
    params: { pipeline: 'json "[true]" | json' },
    envelope: { ok: true, status: 'ok', output: [true, '雪😀', null], requiresApproval: null },
  },
  'file-lobster': {
    arguments: {
      action: 'run', pipeline: ' workflows/demo.lobster ', cwd: ' work ',
      argsJson: ' {"enabled":false,"count":0,"nested":{"雪":["a",null]}} ',
    },
    cwd: '/reference/lobster/work',
    method: 'runToolRequest',
    params: {
      filePath: '/reference/lobster/work/workflows/demo.lobster',
      args: { enabled: false, count: 0, nested: { 雪: ['a', null] } },
    },
    envelope: { ok: true, status: 'ok', output: [{ file: 'demo.lobster', ready: true }], requiresApproval: null },
  },
  'file-json-no-args': {
    arguments: { action: 'run', pipeline: ' /reference/lobster/workflows/DEMO.JSON ', argsJson: '   ' },
    method: 'runToolRequest',
    params: { filePath: '/reference/lobster/workflows/DEMO.JSON' },
    envelope: { ok: true, status: 'ok', output: [], requiresApproval: null },
  },
  'run-needs-input': {
    arguments: { action: 'run', pipeline: ' json "[1]" | ask ' },
    method: 'runToolRequest',
    params: { pipeline: 'json "[1]" | ask' },
    envelope: {
      ok: true, status: 'needs_input', output: [{ step: 'before', value: 1 }], requiresApproval: null,
      requiresInput: {
        type: 'input_request', prompt: 'Choose a name', responseSchema: { type: 'string' },
        defaults: '雪😀', subject: { step: 'name' }, resumeToken: 'input-token', note: 'retained',
      },
    },
  },
  'resume-null': {
    arguments: { action: 'resume', token: ' token-null ', responseJson: ' null ' },
    method: 'resumeToolRequest', params: { token: 'token-null', response: null },
    envelope: { ok: true, status: 'ok', output: [null], requiresApproval: null },
  },
  'resume-false': {
    arguments: { action: 'resume', token: ' token-false ', responseJson: ' false ' },
    method: 'resumeToolRequest', params: { token: 'token-false', response: false },
    envelope: { ok: true, status: 'ok', output: [false], requiresApproval: null },
  },
  'resume-zero': {
    arguments: { action: 'resume', token: ' token-zero ', responseJson: ' 0 ' },
    method: 'resumeToolRequest', params: { token: 'token-zero', response: 0 },
    envelope: { ok: true, status: 'ok', output: [0], requiresApproval: null },
  },
  'resume-string': {
    arguments: { action: 'resume', token: ' token-string ', responseJson: ' " padded 雪😀 " ' },
    method: 'resumeToolRequest', params: { token: 'token-string', response: ' padded 雪😀 ' },
    envelope: { ok: true, status: 'ok', output: [' padded 雪😀 '], requiresApproval: null },
  },
  'resume-array': {
    arguments: { action: 'resume', token: ' token-array ', responseJson: ' [1,null,"雪😀"] ' },
    method: 'resumeToolRequest', params: { token: 'token-array', response: [1, null, '雪😀'] },
    envelope: { ok: true, status: 'ok', output: [[1, null, '雪😀']], requiresApproval: null },
  },
  'resume-object': {
    arguments: { action: 'resume', token: ' token-object ', responseJson: ' {"ready":true,"nested":[false,0]} ' },
    method: 'resumeToolRequest', params: { token: 'token-object', response: { ready: true, nested: [false, 0] } },
    envelope: { ok: true, status: 'ok', output: [{ ready: true, nested: [false, 0] }], requiresApproval: null },
  },
};

test('whole Lobster factory produces the exact pinned public metadata and schema', () => {
  assert.deepEqual(captured.metadata, {
    name: 'lobster',
    label: 'Lobster Workflow',
    description: 'Run Lobster workflows with resumable approvals and structured input. For needs_input, ask the user the returned prompt, then resume with their answer as responseJson matching responseSchema. For approvals, resume with approve. Use cancel: true to cancel a checkpoint.',
    parameters: {
      type: 'object', required: ['action'],
      properties: {
        action: { enum: ['run', 'resume'], type: 'string' },
        pipeline: { type: 'string' }, argsJson: { type: 'string' }, token: { type: 'string' },
        approvalId: { type: 'string' }, approve: { type: 'boolean' },
        responseJson: { type: 'string', description: "User's answer as JSON for an input checkpoint. Use instead of approve." },
        cancel: { const: true, type: 'boolean' },
        cwd: { type: 'string', description: 'Relative working directory (optional). Must stay within the gateway working directory.' },
        timeoutMs: { type: 'integer', minimum: 1 }, maxStdoutBytes: { type: 'integer', minimum: 1 },
      },
    },
  });
});

test('whole callback and runner forward exact inline, file and ordinary JSON input-resume requests', () => {
  assert.deepEqual([...rows.keys()].sort(), Object.keys(expected).sort());
  for (const [id, literal] of Object.entries(expected)) {
    const row = rows.get(id);
    assert.deepEqual(row.arguments, literal.arguments, id);
    assert.equal(row.argumentsUnchanged, true, id);
    assert.deepEqual(row.coreCalls, [{
      method: literal.method, params: literal.params,
      context: {
        cwd: literal.cwd ?? '/reference/lobster', mode: 'tool', stdin: [],
        stdoutWritable: true, stderrWritable: true, signalAborted: false,
      },
    }], id);
  }
  assert.deepEqual(captured.externalCore, {
    package: '@clawdbot/lobster', version: '2026.9.16', executed: false,
    loadCount: 1, kind: 'ordinary-success-facade',
  });
  assert.deepEqual(captured.filesystem, {
    kind: 'successful-stat-facade', cwd: '/reference/lobster',
    statPaths: ['/reference/lobster/work/workflows/demo.lobster', '/reference/lobster/workflows/DEMO.JSON'],
    containmentCalls: [{ root: '/reference/lobster', target: '/reference/lobster/work', result: true }],
  });
});

test('actual jsonResult preserves exact ordered output and structured input checkpoint envelopes', () => {
  for (const [id, literal] of Object.entries(expected)) {
    assert.deepEqual(rows.get(id).result, {
      content: [{ type: 'text', text: JSON.stringify(literal.envelope, null, 2) }],
      details: literal.envelope,
    }, id);
  }
});

test('whole source helpers, pinned checkout, actual TypeBox and frozen capture remain reproducible', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.deepEqual(captured.checkout.before, captured.checkout.after);
  assert.equal(captured.checkout.before.verified, true);
  assert.equal(captured.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(captured.checkout.before.modesAndSymlinksVerified, true);
  const executed = new Set();
  for (const record of captured.sourceRecords) {
    const bytes = readFileSync(join(root, record.path));
    assert.equal(digest(bytes), record.sha256, record.path);
    if (record.executed) {
      executed.add(record.path);
      assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), record.executableSha256, record.path);
    }
  }
  for (const source of [
    'extensions/lobster/src/lobster-tool.ts', 'extensions/lobster/src/lobster-runner.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
    'src/agents/schema/typebox.ts', 'packages/retry/src/index.ts',
  ]) assert.ok(executed.has(source), source);
  assert.equal(executed.has('src/plugin-sdk/file-access-runtime.ts'), false);
  assert.ok(captured.sourceRecords.some(row => row.path === 'src/plugin-sdk/file-access-runtime.ts'));
  assert.equal(captured.typebox.version, '1.3.37');
  const entry = createRequire(join(root, 'package.json')).resolve('typebox');
  const typeboxRoot = dirname(dirname(entry));
  assert.ok(captured.typebox.files.length > 0);
  for (const dep of captured.typebox.files) {
    assert.equal(digest(readFileSync(join(typeboxRoot, dep.path.replace(/^typebox\//, '')))), dep.sha256, dep.path);
  }
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster.mjs', import.meta.url))));
  assert.ok(Array.isArray(captured.audit));
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster.json', import.meta.url)));
  assert.deepEqual(captured, fixture);
});
