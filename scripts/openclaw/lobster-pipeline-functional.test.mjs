// Independent ordinary-success expectations for the pinned pipeline parser.
// This covers valid UTF-8 strings and the default pipeline dialect only.
// The workflow executor and JavaScript prototype semantics are outside scope.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { captureLobsterPipeline } from './capture-lobster-pipeline.mjs';

// Authored from both complete upstream modules before capture/native changes.
// Do not learn these expectations from the capture or native implementation.
export const EXPECTED_VECTORS = [
  {
    id: 'stage-trim-and-spacing', input: ' \tjson  "[1,2]"  |  pick --field name \r\n',
    stages: [
      { name: 'json', args: { _: ['[1,2]'] }, raw: 'json  "[1,2]"' },
      { name: 'pick', args: { _: [], field: 'name' }, raw: 'pick --field name' },
    ],
  },
  {
    id: 'quoted-pipes', input: 'json "a|b" \'c|d\' | join "|"',
    stages: [
      { name: 'json', args: { _: ['a|b', 'c|d'] }, raw: 'json "a|b" \'c|d\'' },
      { name: 'join', args: { _: ['|'] }, raw: 'join "|"' },
    ],
  },
  {
    id: 'single-quote-escapes', input: String.raw`json 'C:\notes\q' 'it\'s'`,
    stages: [{ name: 'json', args: { _: [String.raw`C:\notes\q`, "it's"] }, raw: String.raw`json 'C:\notes\q' 'it\'s'` }],
  },
  {
    id: 'double-quote-known-escapes', input: String.raw`json "a\"b" "c\\d" "\$cash"`,
    stages: [{ name: 'json', args: { _: ['a"b', String.raw`c\d`, '$cash'] }, raw: String.raw`json "a\"b" "c\\d" "\$cash"` }],
  },
  {
    id: 'double-quote-backtick', input: 'json "\\`tick"',
    stages: [{ name: 'json', args: { _: ['`tick'] }, raw: 'json "\\`tick"' }],
  },
  {
    id: 'double-quote-unknown-escapes', input: String.raw`json "\n\t\q"`,
    stages: [{ name: 'json', args: { _: [String.raw`\n\t\q`] }, raw: String.raw`json "\n\t\q"` }],
  },
  {
    id: 'double-quote-line-continuation', input: 'json "first\\\nsecond"',
    stages: [{ name: 'json', args: { _: ['firstsecond'] }, raw: 'json "first\\\nsecond"' }],
  },
  {
    id: 'quote-concatenation-and-empty-tokens', input: 'json pre"mid"\'tail\' "" \'\'',
    stages: [{ name: 'json', args: { _: ['premidtail', '', ''] }, raw: 'json pre"mid"\'tail\' "" \'\'' }],
  },
  {
    id: 'ascii-token-whitespace', input: 'json\talpha\nbeta\rgamma',
    stages: [{ name: 'json', args: { _: ['alpha', 'beta', 'gamma'] }, raw: 'json\talpha\nbeta\rgamma' }],
  },
  {
    id: 'internal-nbsp', input: 'json alpha\u00a0beta',
    stages: [{ name: 'json', args: { _: ['alpha\u00a0beta'] }, raw: 'json alpha\u00a0beta' }],
  },
  {
    id: 'nel-preserved', input: '\u0085json value\u0085',
    stages: [{ name: '\u0085json', args: { _: ['value\u0085'] }, raw: '\u0085json value\u0085' }],
  },
  {
    id: 'ecmascript-outer-whitespace',
    input: '\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeffjson value\ufeff\u3000\u205f\u202f\u2029\u2028\u200a\u2009\u2008\u2007\u2006\u2005\u2004\u2003\u2002\u2001\u2000\u1680\u00a0 \r\f\v\n\t',
    stages: [{ name: 'json', args: { _: ['value'] }, raw: 'json value' }],
  },
  {
    id: 'unicode-text', input: 'json "雪😀" "é" "👩‍💻"',
    stages: [{ name: 'json', args: { _: ['雪😀', 'é', '👩‍💻'] }, raw: 'json "雪😀" "é" "👩‍💻"' }],
  },
  {
    id: 'flag-values-and-booleans', input: 'pick --field=name --count 2 --verbose --final --value=a=b item',
    stages: [{ name: 'pick', args: { _: ['item'], field: 'name', count: '2', verbose: true, final: true, value: 'a=b' }, raw: 'pick --field=name --count 2 --verbose --final --value=a=b item' }],
  },
  {
    id: 'repeated-flags', input: 'pick --field first --field=last --toggle --toggle=false item',
    stages: [{ name: 'pick', args: { _: ['item'], field: 'last', toggle: 'false' }, raw: 'pick --field first --field=last --toggle --toggle=false item' }],
  },
  {
    id: 'ordinary-json-value', input: 'json --json payload tail',
    stages: [{ name: 'json', args: { _: ['tail'], json: 'payload' }, raw: 'json --json payload tail' }],
  },
  {
    id: 'exec-json-boolean', input: 'exec --json printf "%s" \'{"x":1}\'',
    stages: [{ name: 'exec', args: { _: ['printf', '%s', '{"x":1}'], json: true }, raw: 'exec --json printf "%s" \'{"x":1}\'' }],
  },
  {
    id: 'exec-json-explicit-string', input: 'exec --json=false echo done',
    stages: [{ name: 'exec', args: { _: ['echo', 'done'], json: 'false' }, raw: 'exec --json=false echo done' }],
  },
  {
    id: 'empty-flag-and-positional', input: 'json --label= ""',
    stages: [{ name: 'json', args: { _: [''], label: '' }, raw: 'json --label= ""' }],
  },
  {
    id: 'quoted-flag-and-value', input: 'json "--field" "display name" item',
    stages: [{ name: 'json', args: { _: ['item'], field: 'display name' }, raw: 'json "--field" "display name" item' }],
  },
  {
    id: 'unquoted-backslashes', input: String.raw`json C:\tmp\file plain\word`,
    stages: [{ name: 'json', args: { _: [String.raw`C:\tmp\file`, String.raw`plain\word`] }, raw: String.raw`json C:\tmp\file plain\word` }],
  },
  {
    id: 'unquoted-backslash-before-pipe', input: String.raw`json left\| json right`,
    stages: [
      { name: 'json', args: { _: ['left\\'] }, raw: 'json left\\' },
      { name: 'json', args: { _: ['right'] }, raw: 'json right' },
    ],
  },
  {
    id: 'trailing-pipe', input: 'json ready | \t',
    stages: [{ name: 'json', args: { _: ['ready'] }, raw: 'json ready' }],
  },
  {
    id: 'quoted-command-name', input: '"json"  "ready now"',
    stages: [{ name: 'json', args: { _: ['ready now'] }, raw: '"json"  "ready now"' }],
  },
];

const captured = await captureLobsterPipeline({
  referenceRoot: '/tmp/openclaw-488631c',
  archive: '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('complete pinned parser modules produce all independently authored successful stages', () => {
  assert.deepEqual(captured.vectors, EXPECTED_VECTORS);
});

test('capture identifies the pinned package and does not execute the workflow runtime', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.sourcePackage.name, '@clawdbot/lobster');
  assert.equal(captured.sourcePackage.version, '2026.9.16');
  assert.equal(captured.sourcePackage.integrity, 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==');
  assert.equal(captured.sourcePackage.installed, false);
  assert.equal(captured.executedRuntime, false);
});

test('capture records both whole executed modules, its harness, and the archive license', () => {
  assert.deepEqual(captured.sourceRecords.map(record => record.path).sort(), [
    'package/dist/src/command_tokens.js', 'package/dist/src/parser.js',
  ]);
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
    assert.match(record.sha256, /^[a-f0-9]{64}$/, record.path);
  }
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-pipeline.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, digest(captured.license.text));
  assert.ok(captured.license.text.length > 0);
});

test('fresh whole-module capture exactly reproduces every frozen fixture field', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-pipeline.json', import.meta.url)));
  assert.deepEqual(fixture.vectors, EXPECTED_VECTORS);
  assert.deepEqual(captured, fixture);
});
