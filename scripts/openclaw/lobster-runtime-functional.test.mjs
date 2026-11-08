// Independent ordinary-success expectations from the complete published modules.
// Resume slicing is a harness recipe; checkpoint persistence and tool runtime
// execution are outside this fixture's evidence boundary.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { captureLobsterRuntime } from './capture-lobster-runtime.mjs';

// Authored before the capture implementation. Keep all expected observations
// literal and independent of both the capture and native implementations.
export const EXPECTED_CASES = [
  {
    id: 'lazy-head-one',
    pipeline: 'fixture_source | head --n 1 | json',
    input: [],
    sourceItems: [{ id: 1, label: '一' }, { id: 2, label: '二' }],
    runs: [{
      trace: ['run:fixture_source', 'run:head', 'run:json', 'pull:1'],
      result: {
        items: [{ id: 1, label: '一' }],
        halted: false,
        haltedAt: null,
        executionStarted: true,
        rendered: false,
        renderedItems: [],
      },
    }],
  },
  {
    id: 'lazy-head-zero',
    pipeline: 'fixture_source | head --n 0 | json',
    input: [],
    sourceItems: [{ id: 1, label: '一' }, { id: 2, label: '二' }],
    runs: [{
      trace: ['run:fixture_source', 'run:head', 'run:json'],
      result: {
        items: [],
        halted: false,
        haltedAt: null,
        executionStarted: true,
        rendered: false,
        renderedItems: [],
      },
    }],
  },
  {
    id: 'pure-pick',
    pipeline: 'pick id,label | json',
    input: [{ id: 1, label: '一', extra: true }, { id: 2, label: '二', extra: false }],
    runs: [{
      trace: ['run:pick', 'run:json'],
      result: {
        items: [{ id: 1, label: '一' }, { id: 2, label: '二' }],
        halted: false,
        haltedAt: null,
        executionStarted: true,
        rendered: false,
        renderedItems: [],
      },
    }],
  },
  {
    id: 'ask-same-stage',
    pipeline: 'fixture_source | ask --prompt \'Review\' --schema \'{"type":"string"}\' --subject-from-stdin | json',
    input: [],
    sourceItems: ['draft'],
    resume: { mode: 'same_stage', response: 'continue' },
    runs: [
      {
        trace: ['run:fixture_source', 'run:ask', 'pull:draft'],
        result: {
          items: [{
            type: 'input_request',
            prompt: 'Review',
            responseSchema: { type: 'string' },
            subject: { text: 'draft' },
            items: [],
            commandInput: {
              pending: {
                requestIndex: 0,
                metadata: {
                  prompt: 'Review',
                  responseSchema: { type: 'string' },
                  subject: { text: 'draft' },
                  signature: '{"prompt":"Review","responseSchema":{"type":"string"},"subject":{"text":"draft"}}',
                },
                suspendedState: { type: 'ask', subject: { text: 'draft' } },
              },
              history: [],
            },
          }],
          halted: true,
          haltedAt: { index: 1, name: 'ask', inPlace: true },
          executionStarted: true,
          rendered: false,
          renderedItems: [],
        },
      },
      {
        trace: ['run:ask', 'run:json'],
        result: {
          items: ['continue'],
          halted: false,
          haltedAt: null,
          executionStarted: true,
          rendered: false,
          renderedItems: [],
        },
      },
    ],
  },
  {
    id: 'ask-emit-next-stage',
    pipeline: 'ask --prompt \'Review\' --schema \'{"type":"boolean"}\' --emit | json',
    input: ['draft'],
    resume: { mode: 'next_stage', response: true },
    runs: [
      {
        trace: ['run:ask'],
        result: {
          items: [{
            type: 'input_request',
            prompt: 'Review',
            responseSchema: { type: 'boolean' },
            items: ['draft'],
          }],
          halted: true,
          haltedAt: { index: 0, name: 'ask', inPlace: false },
          executionStarted: false,
          rendered: false,
          renderedItems: [],
        },
      },
      {
        trace: ['run:json'],
        result: {
          items: [true],
          halted: false,
          haltedAt: null,
          executionStarted: true,
          rendered: false,
          renderedItems: [],
        },
      },
    ],
  },
  {
    id: 'json-renderer',
    pipeline: 'pick id,label | json',
    input: [{ id: 1, label: '一', extra: true }],
    renderOutput: true,
    runs: [{
      trace: ['run:pick', 'run:json'],
      result: {
        items: [],
        halted: false,
        haltedAt: null,
        executionStarted: true,
        rendered: true,
        renderedItems: [{ id: 1, label: '一' }],
        stdout: '[\n  {\n    "id": 1,\n    "label": "一"\n  }\n]\n',
      },
    }],
  },
  {
    id: 'ask-known-array',
    pipeline: 'ask --prompt \'Review\' --schema \'{"type":"string"}\' --subject-from-stdin | json',
    input: ['draft'],
    resume: { mode: 'same_stage', response: 'continue' },
    runs: [
      {
        trace: ['run:ask'],
        result: {
          items: [{
            type: 'input_request',
            prompt: 'Review',
            responseSchema: { type: 'string' },
            subject: { text: 'draft' },
            items: ['draft'],
            commandInput: {
              pending: {
                requestIndex: 0,
                metadata: {
                  prompt: 'Review',
                  responseSchema: { type: 'string' },
                  subject: { text: 'draft' },
                  signature: '{"prompt":"Review","responseSchema":{"type":"string"},"subject":{"text":"draft"}}',
                },
                suspendedState: { type: 'ask', subject: { text: 'draft' } },
              },
              history: [],
            },
          }],
          halted: true,
          haltedAt: { index: 0, name: 'ask', inPlace: true },
          executionStarted: false,
          rendered: false,
          renderedItems: [],
        },
      },
      {
        trace: ['run:ask', 'run:json'],
        result: {
          items: ['continue'],
          halted: false,
          haltedAt: null,
          executionStarted: true,
          rendered: false,
          renderedItems: [],
        },
      },
    ],
  },
];

const captured = await captureLobsterRuntime({
  referenceRoot: '/tmp/openclaw-488631c',
  archive: '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
  dependencies: '/tmp/synapsis-workflow186-fydsjreq/npm/manifest.json',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole published runtime reproduces independently authored ordinary stream and resume cases', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('capture identifies the pinned source and real validation dependencies without installing a catalog', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.sourcePackage.name, '@clawdbot/lobster');
  assert.equal(captured.sourcePackage.version, '2026.9.16');
  assert.equal(captured.sourcePackage.integrity, 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==');
  assert.equal(captured.sourcePackage.installed, false);
  assert.equal(captured.executedWorkflowRuntime, true);
  assert.equal(captured.productionCatalogInstalled, false);
  assert.deepEqual(captured.dependencies.map(({ name, version }) => ({ name, version })).sort((a, b) => a.name.localeCompare(b.name)), [
    { name: 'ajv', version: '8.20.0' },
    { name: 'fast-deep-equal', version: '3.1.3' },
    { name: 'fast-uri', version: '4.2.2' },
    { name: 'json-schema-traverse', version: '1.0.0' },
    { name: 'require-from-string', version: '2.0.2' },
  ]);
});

test('capture records exact whole-module hashes, its harness, and the published license', () => {
  const expectedHashes = {
    'package/dist/src/command_tokens.js': 'a8cd45e37b2348cc3f847c1b06b2e2959594f360e05521f3ae45f57966a495fa',
    'package/dist/src/commands/stdlib/ask.js': '9133cbe30bddd28d322d3017f428317a6f98ab2bd9f43992b9f74594e3af6537',
    'package/dist/src/commands/stdlib/head.js': '3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1',
    'package/dist/src/commands/stdlib/json.js': '9e3f24e0a2bcba55e466f300901fd0f0b2d079fa075a55ee296c54201df76b58',
    'package/dist/src/commands/stdlib/pick.js': '3d224840f187aa86c8414873f3782827e80e0ef9e176c085ceb2bb05f12d402c',
    'package/dist/src/input_request.js': '4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4',
    'package/dist/src/parser.js': 'e8f3f5cc67b1739b7347da70ea9a543d68f8e5f622387910d0202bb0f5b030ce',
    'package/dist/src/renderers/json.js': '1a739a179aacb410add5fe954aec53e05fc89434b8e0aa8d8718b69fabfce681',
    'package/dist/src/runtime.js': '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53',
    'package/dist/src/state/atomic_file.js': '87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5',
    'package/dist/src/state/store.js': '8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c',
    'package/dist/src/validation.js': 'a9e087f2b5502be86dc223f2746c1d598446d4c1b5537f697003418417933f6b',
  };
  assert.equal(captured.sourceRecords.length, Object.keys(expectedHashes).length);
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(({ path, sha256 }) => [path, sha256])), expectedHashes);
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-runtime.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, '0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb');
  assert.equal(captured.license.sha256, digest(captured.license.text));
});

test('fresh whole-module capture exactly reproduces every frozen runtime fixture field', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-runtime.json', import.meta.url)));
  assert.deepEqual(fixture.cases, EXPECTED_CASES);
  assert.deepEqual(captured, fixture);
});
