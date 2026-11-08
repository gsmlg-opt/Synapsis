// Independent ordinary-success observations authored before capture/host code.
// Only three unchanged command/helper modules execute; no workflow runtime runs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { captureLobsterValues } from './capture-lobster-values.mjs';

export const EXPECTED_CASES = [
  {
    id: 'pick-missing-and-null', execution: 'command',
    observation: {
      keys: ['missing', 'present', 'title'], missingOwn: true,
      missingUndefined: true, presentNull: true, title: 'mail',
      json: '{"present":null,"title":"mail"}',
    },
  },
  {
    id: 'map-shared-alias', execution: 'command',
    observation: {
      outputCount: 2, bothSameAsInput: true, outputsShare: true,
      keys: ['count', 'label', 'echo'], count: 1, label: 'updated', echo: '1',
    },
  },
  {
    id: 'map-wrap-unwrap', execution: 'command',
    observation: {
      wrappedCount: 2, distinctWrappers: true, bothPointToInput: true,
      unwrappedCount: 2, sameInput: true, unwrappedShared: true,
    },
  },
  {
    id: 'object-order-and-replacement', execution: 'native-js',
    observation: {
      initialKeys: ['2', '10', '4294967294', 'z', '01', '4294967295', 'a'],
      duplicateValue: 2,
      finalKeys: ['1', '2', '10', '4294967294', 'z', '01', '4294967295', 'a', 'b'],
      replacementValue: 3, appendedValue: 4,
    },
  },
  {
    id: 'binary64-json-import', execution: 'native-js',
    observation: {
      nullValue: true, booleans: [false, true], text: '雪😀',
      bits: [
        '0000000000000000', '8000000000000000', '3fb999999999999a',
        '4340000000000000', '44b52d02c7e14af6', '3e7ad7f29abcaf48',
        'c004000000000000', '4045000000000000',
      ],
      negativeZero: true, roundedLargeEquals2Pow53: true,
    },
  },
  {
    id: 'nested-typed-snapshot', execution: 'native-js',
    observation: {
      tagShapedKeys: ['type', 'value'], tagString: 'undefined', tagValueIsNull: true,
      nestedArray: true, nestedString: '雪😀', nestedBoolean: false, rootNull: true,
      aliasIdentity: true, aliasMutation: ['later', 'later'],
    },
  },
];

const captured = await captureLobsterValues({
  referenceRoot: process.env.OPENCLAW_REFERENCE_ROOT ?? '/tmp/openclaw-488631c',
  archive: process.env.LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('real command outputs and separate native-JS observations match independent literals', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('capture identifies the pinned package without claiming workflow runtime execution', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.sourcePackage.name, '@clawdbot/lobster');
  assert.equal(captured.sourcePackage.version, '2026.9.16');
  assert.equal(captured.sourcePackage.integrity, 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==');
  assert.equal(captured.sourcePackage.installed, false);
  assert.equal(captured.executedRuntime, false);
  assert.deepEqual(captured.executedCommands, ['pick', 'map']);
});

test('whole-module hashes, harness and archive license retain exact provenance', () => {
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(record => [record.path, record.sha256])), {
    'package/dist/src/commands/stdlib/pick.js': '3d224840f187aa86c8414873f3782827e80e0ef9e176c085ceb2bb05f12d402c',
    'package/dist/src/commands/stdlib/map.js': 'faeebf18c5db3903ae5e03270b87f49e5a1b8a5324276add6ca52c83763d8e27',
    'package/dist/src/core/value_path.js': 'e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f',
  });
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-values.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, digest(captured.license.text));
  assert.ok(captured.license.text.length > 0);
});

test('fresh capture reproduces the complete frozen fixture', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-values.json', import.meta.url)));
  assert.deepEqual(fixture.cases, EXPECTED_CASES);
  assert.deepEqual(captured, fixture);
});
