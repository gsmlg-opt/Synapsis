// Independent ordinary-success expectations authored before capture/product code.
// Source renderer/stable calls and native-JS observations remain distinct.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { captureLobsterJSON } from './capture-lobster-json.mjs';

export const EXPECTED_NUMBERS = [
  { input: '0', compact: '0' },
  { input: '-0', compact: '0' },
  { input: '42', compact: '42' },
  { input: '-2.5', compact: '-2.5' },
  { input: '0.1', compact: '0.1' },
  { input: '0.30000000000000004', compact: '0.30000000000000004' },
  { input: '1.25', compact: '1.25' },
  { input: '1e-6', compact: '0.000001' },
  { input: '9e-7', compact: '9e-7' },
  { input: '1e-7', compact: '1e-7' },
  { input: '1.234e-6', compact: '0.000001234' },
  { input: '1.2e-7', compact: '1.2e-7' },
  { input: '1e20', compact: '100000000000000000000' },
  { input: '1e21', compact: '1e+21' },
  { input: '1.234e21', compact: '1.234e+21' },
  { input: '1e23', compact: '1e+23' },
  { input: '1000000000000000128', compact: '1000000000000000100' },
  { input: '9007199254740993', compact: '9007199254740992' },
  { input: '1.2345678901234567', compact: '1.2345678901234567' },
  { input: '-1e-6', compact: '-0.000001' },
  { input: '-1e21', compact: '-1e+21' },
  { input: '10e-0', compact: '10' },
  { input: '1424953923781206.25', compact: '1424953923781206.2' },
];

const prettyNested = '{\n  "title": "mail",\n  "items": [\n    1,\n    {\n      "b": true,\n      "empty": []\n    }\n  ],\n  "nothing": {}\n}';
export const EXPECTED_CASES = [
  {
    id: 'primitives', execution: 'native-js',
    observation: { compact: '[null,true,false,"mail",0,0]' },
  },
  {
    id: 'control-and-unicode-string', execution: 'native-js',
    observation: { compact: '"\\u0000\\b\\t\\n\\u000b\\f\\r\\u000e\\u001f \\"\\\\ /雪😀\u2028\u2029 literal \\\\u000B"' },
  },
  {
    id: 'pretty-nested-renderer', execution: 'source-renderer',
    observation: { writes: [prettyNested, '\n'], output: prettyNested + '\n' },
  },
  {
    id: 'empty-shapes-renderer', execution: 'source-renderer',
    observation: { writes: ['{}', '\n', '[]', '\n'], output: '{}\n[]\n' },
  },
  {
    id: 'public-undefined', execution: 'native-js',
    observation: {
      rootUndefined: true,
      compactObject: '{"keep":null,"title":"mail"}',
      prettyObject: '{\n  "keep": null,\n  "title": "mail"\n}',
      compactArray: '[null,null,{"ok":true}]',
      prettyArray: '[\n  null,\n  null,\n  {\n    "ok": true\n  }\n]',
    },
  },
  {
    id: 'own-key-order-stable', execution: 'source-stable',
    observation: {
      compact: '{"2":"two","10":"ten","z":1,"\ue000":"bmp","\u{10000}":"astral","a":2}',
      stable: '{"2":"two","10":"ten","a":2,"z":1,"\u{10000}":"astral","\ue000":"bmp"}',
    },
  },
  {
    id: 'stable-nested-arrays', execution: 'source-stable',
    observation: {
      compact: '{"b":[{"z":1,"a":2},[{"y":3,"x":4}]],"a":{"d":4,"c":3}}',
      stable: '{"a":{"c":3,"d":4},"b":[{"a":2,"z":1},[{"x":4,"y":3}]]}',
    },
  },
  {
    id: 'snapshot-alias-and-zero', execution: 'native-js',
    observation: {
      compact: '{"left":{"value":0,"label":"mail"},"right":{"value":0,"label":"mail"}}',
      sourceShared: true, sourceNegativeZero: true, cloneDistinct: true, clonePositiveZero: true,
      cloneTextAfterLeftEdit: '{"left":{"value":0,"label":"edited"},"right":{"value":0,"label":"mail"}}',
      sourceLabelAfterEdit: 'mail',
    },
  },
];

const captured = await captureLobsterJSON({
  referenceRoot: process.env.OPENCLAW_REFERENCE_ROOT ?? '/tmp/openclaw-488631c',
  archive: process.env.LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('finite numbers, source calls and native-JS observations match independent literals', () => {
  assert.deepEqual(captured.numberVectors, EXPECTED_NUMBERS);
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('capture identifies the pinned uninstalled package and bounded execution', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.sourcePackage.name, '@clawdbot/lobster');
  assert.equal(captured.sourcePackage.version, '2026.9.16');
  assert.equal(captured.sourcePackage.integrity, 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==');
  assert.equal(captured.sourcePackage.installed, false);
  assert.equal(captured.executedRuntime, false);
  assert.equal(captured.executedPrivateSnapshotValidator, false);
});

test('three unchanged whole-module hashes and harness/license provenance are retained', () => {
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(record => [record.path, record.sha256])), {
    'package/dist/src/renderers/json.js': '1a739a179aacb410add5fe954aec53e05fc89434b8e0aa8d8718b69fabfce681',
    'package/dist/src/state/store.js': '8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c',
    'package/dist/src/state/atomic_file.js': '87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5',
  });
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-json.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, digest(captured.license.text));
  assert.ok(captured.license.text.length > 0);
});

test('fresh capture exactly reproduces the complete frozen fixture', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-json.json', import.meta.url)));
  assert.deepEqual(fixture.numberVectors, EXPECTED_NUMBERS);
  assert.deepEqual(fixture.cases, EXPECTED_CASES);
  assert.deepEqual(captured, fixture);
});
