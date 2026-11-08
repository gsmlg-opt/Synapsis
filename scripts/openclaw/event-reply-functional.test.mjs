// Positive original whole-module helper observations only.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureEventReply, EVENT_REPLY_PIN } from './capture-event-reply.mjs';

const root = '/tmp/openclaw-488631c';
const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/event-reply.json', import.meta.url)));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const rows = new Map(fixture.observations.map(row => [row.id, row]));
const sourceHashes = {
  'src/auto-reply/heartbeat.ts': '7c82c8d03e4cbcd4027b35960ec292e1716cf30aaa9faf5caf36e7f785aeeb55',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'src/shared/regexp.ts': 'bafc7ca866952c3df452c25ca0c6ef30756ff2c9f44463ad76da30857aeab35e',
  'src/auto-reply/tokens.ts': '5c19012815e8f501789bf6e98dccbf4ba6b36d4a030fd7f2badff43dea07e507',
};

test('four complete unchanged modules, pinned checkout and fixed runtime retain exact provenance', () => {
  assert.equal(fixture.referencePin, EVENT_REPLY_PIN);
  assert.equal(fixture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.deepEqual(fixture.entry, { path: 'src/auto-reply/heartbeat.ts', export: 'stripHeartbeatToken', mode: 'message', calls: 18 });
  assert.equal(fixture.sourceTree.before.verified, true);
  assert.equal(fixture.sourceTree.before.commit, fixture.referencePin);
  assert.equal(fixture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.sourceTree.before, fixture.sourceTree.after);
  assert.deepEqual(Object.fromEntries(fixture.sourceRecords.map(row => [row.path, row.sha256])), sourceHashes);
  for (const row of fixture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    assert.equal(row.executed, true);
    assert.equal(row.wholeModule, true);
    assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
  }
  assert.equal(fixture.transformation, 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
  assert.equal(fixture.exporter.sha256, hash(readFileSync(new URL('./capture-event-reply.mjs', import.meta.url))));
  assert.equal(fixture.runtime.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(fixture.runtime.version, '24.22.1');
  assert.equal(process.versions.node, fixture.runtime.version);
  assert.equal(fixture.runtime.sha256, hash(readFileSync(fixture.runtime.executable)));
  assert.deepEqual(fixture.importBindings, []);
});

test('source retains exact edge, HTML, punctuation and observed Markdown behavior', () => {
  const expected = {
    'exact-ack': '', 'prefix-meaningful': 'all good', 'suffix-meaningful': 'All done',
    'repeated-edges': 'All done', 'markdown-wrapper': '****',
    'html-wrapper-meaningful': 'all good', 'html-nbsp-wrapper': 'Ready',
    'suffix-period': 'I should not respond.', 'suffix-punctuation': 'All done!!!',
    'prefix-punctuation': '.',
  };
  for (const [id, text] of Object.entries(expected)) {
    assert.deepEqual(rows.get(id).actual, { shouldSkip: text === '', text, didStrip: true }, id);
  }
});

test('source distinguishes exact JS whitespace, ASCII word class and UTF-16 suffix units', () => {
  const expected = {
    'js-trim-and-collapse': ['Ready now', true], 'unicode-prose': ['完成 🙂', true],
    'meaningful-nel': ['\u0085Ready\u0085', true],
    'ordinary-unchanged': ['Ordinary\n\nanswer', false],
    'interior-marker-unchanged': ['hello HEARTBEAT_OK there', false],
    'four-utf16-suffix-units': ['Ready🙂🙂', true],
    'six-utf16-suffix-units': ['Ready HEARTBEAT_OK🙂🙂🙂', false],
    'ascii-word-class-unicode-suffix': ['Readyé', true],
  };
  for (const [id, [text, didStrip]] of Object.entries(expected)) {
    assert.deepEqual(rows.get(id).actual, { shouldSkip: false, text, didStrip }, id);
  }
  assert.equal(rows.size, 18);
  assert.equal(fixture.observations.length, 18);
  assert.ok(fixture.observations.every(row => row.mode === 'message'));
  assert.deepEqual(fixture.scope, { pureMessageHelperExecuted: true, heartbeatModeExecuted: false,
    normalizeReplyCallsiteExecuted: false, dispatchExecuted: false,
    nativeRuntimeExecuted: false, browserExecuted: false, cliExecuted: false });
});

test('fresh original whole-source execution reproduces all eighteen positive vectors and provenance', { timeout: 60000 }, async () => {
  assert.deepEqual(await captureEventReply(root), fixture);
});
