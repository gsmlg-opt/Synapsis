// Positive expectations fixed from the pinned source audit before capture implementation.
// This qualifies raw-event helper execution only, not host DTO/storage/reader equivalence.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { captureSessionReaderWindow } from './capture-session-reader-window.mjs';

const PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const TREE = '47509a47273231ab15f57252960fe716d7379ffb';
const NAVIGATION = 'src/config/sessions/session-actor-memory-history-navigation.ts';
const SOURCE_PAGES = 'src/gateway/session-transcript-source-pages.ts';
const root = process.env.OPENCLAW_SESSION_SOURCE ?? '/tmp/openclaw-488631c';
const receipt = await captureSessionReaderWindow(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const rawBytes = text => Buffer.byteLength(text, 'utf8') + 1;

// These are authored source-event inputs with explicit parents, never native host records.
// Keep exact input text: property order, whitespace and the supplied message JSON matter.
const ordinary = [
  '{"type":"message","id":"event-a","parentId":null,"timestamp":"2026-11-06T00:00:00.000Z","message":{"role":"user","content":"First"}}',
  '{"type":"message","id":"event-b","parentId":"event-a","timestamp":"2026-11-06T00:00:01.000Z","message":{"role":"assistant","content":"你好😀"}}',
  '{\n  "message": { "content": "Line one\\nLine two", "role": "user" },\n  "timestamp": "2026-11-06T00:00:02.000Z", "parentId": "event-b", "id": "event-c", "type": "message"\n}',
  '{"type":"message","id":"event-d","parentId":"event-c","timestamp":"2026-11-06T00:00:03.000Z","message":{"role":"assistant","content":"Done"}}',
];
const indivisible = '{"type":"message","id":"large-soft","parentId":"event-b","timestamp":"2026-11-06T00:00:02.000Z","message":{"role":"assistant","content":"' + '文😀'.repeat(350) + '"}}';
const middle = '{"type":"message","id":"middle","parentId":"event-a","timestamp":"2026-11-06T00:00:01.000Z","message":{"role":"assistant","content":"' + 'Long ordinary text. '.repeat(80) + '"}}';
const afterMiddle = '{"type":"message","id":"last","parentId":"middle","timestamp":"2026-11-06T00:00:02.000Z","message":{"role":"user","content":"Latest"}}';
const expected = [
  {
    id: 'raw-utf8-equality-suffix', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]), maxMessages: 3, allowOversized: false },
    start: 1, selectedIds: ['event-b', 'event-c'],
  },
  {
    id: 'preserve-json-text-and-order', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: 4096, maxMessages: 3, allowOversized: false },
    start: 0, selectedIds: ['event-a', 'event-b', 'event-c'],
  },
  {
    id: 'contiguous-newest-suffix', eventJson: [ordinary[0], middle, afterMiddle],
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[0]) + rawBytes(afterMiddle), maxMessages: 3, allowOversized: false },
    start: 2, selectedIds: ['last'],
  },
  {
    id: 'max-messages-bound', eventJson: ordinary,
    options: { start: 0, end: 4, maxBytes: 4096, maxMessages: 2, allowOversized: false },
    start: 2, selectedIds: ['event-c', 'event-d'],
  },
  {
    id: 'initial-bytes-inclusive-boundary', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]) + 37, maxMessages: 3, allowOversized: false, initialBytes: 37 },
    start: 1, selectedIds: ['event-b', 'event-c'],
  },
  {
    id: 'complete-requested-subwindow', eventJson: ordinary,
    options: { start: 1, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]), maxMessages: 2, allowOversized: false, initialBytes: 0, requireComplete: true },
    start: 1, selectedIds: ['event-b', 'event-c'],
  },
  {
    id: 'eligible-window-start', eventJson: ordinary,
    options: { start: 2, end: 4, maxBytes: 4096, maxMessages: 4, allowOversized: false },
    start: 2, selectedIds: ['event-c', 'event-d'],
  },
  {
    id: 'indivisible-newest-above-soft-request', eventJson: [...ordinary.slice(0, 2), indivisible],
    options: { start: 0, end: 3, maxBytes: 1024, maxMessages: 3, allowOversized: true },
    start: 2, selectedIds: ['large-soft'],
  },
];
const vector = id => receipt.vectors.find(item => item.id === id);

// Compare complete official TypeScript stripping, allowing static module-specifier changes
// only. A selected/retyped function body cannot satisfy this whole-module assertion.
function normalizeImportSpecifiers(source) {
  return source.replace(/\b(import|export)(\s+(?:[^;]*?\s+from\s*)?)(["'])([^"'\r\n]+)\3/g,
    (_match, keyword, clause) => keyword + clause + '"<static-module>"');
}

test('receipt declares exact reference and separate source hard/caller soft limits', () => {
  assert.equal(receipt.version, 1);
  assert.deepEqual(receipt.reference, { commit: PIN, tree: TREE, trackedClean: true });
  assert.equal(receipt.scope, 'ordinary-raw-event-window-helper');
  assert.deepEqual(receipt.limits, { sourcePageMaxBytes: 8 * 1024 * 1024, historyPageMaxBytes: 1024 * 1024 });
  assert.deepEqual(receipt.evidence.facadeCalls, []);
  assert.ok(Array.isArray(receipt.evidence.facadeEdges));
  for (const edge of receipt.evidence.facadeEdges) {
    assert.equal(typeof edge.importer, 'string');
    assert.equal(typeof edge.specifier, 'string');
    assert.ok(Array.isArray(edge.exports) && edge.exports.length > 0);
    const source = readFileSync(root + '/' + edge.importer, 'utf8');
    assert.ok(source.includes(edge.specifier), 'facade is an actual declared import edge');
  }
});

test('complete actual helper modules retain source hashes and executable bodies', () => {
  const { sources, transforms } = receipt.evidence;
  for (const path of [NAVIGATION, SOURCE_PAGES]) {
    assert.ok(sources.some(item => item.path === path), 'source receipt: ' + path);
    assert.ok(transforms.some(item => item.path === path), 'executed complete module: ' + path);
  }
  for (const item of sources) {
    const bytes = readFileSync(root + '/' + item.path);
    assert.equal(item.sha256, hash(bytes), item.path);
    assert.equal(item.bytes, bytes.length, item.path);
    assert.match(item.gitBlob, /^[a-f0-9]{40}$/);
  }
  for (const item of transforms) {
    const source = sources.find(value => value.path === item.path);
    assert.ok(source, 'every executed module has original source proof');
    assert.equal(item.mode, 'whole-module');
    assert.equal(item.sourceSha256, source.sha256);
    assert.equal(typeof item.generatedSource, 'string');
    const original = readFileSync(root + '/' + item.path, 'utf8');
    const stripped = stripTypeScriptTypes(original, { mode: 'strip', sourceMap: false });
    assert.equal(normalizeImportSpecifiers(item.generatedSource), normalizeImportSpecifiers(stripped), item.path);
  }
  assert.deepEqual(receipt.evidence.calls, expected.map(item => ({
    path: NAVIGATION, export: 'resolveSessionActorMemoryHistoryStart', result: item.start,
  })));
});

test('literal ordinary vectors admit only the expected newest contiguous ASC windows', () => {
  assert.deepEqual(receipt.vectors.map(item => item.id), expected.map(item => item.id));
  for (const item of expected) {
    const actual = vector(item.id);
    assert.deepEqual(actual.eventJson, item.eventJson, item.id);
    assert.deepEqual(actual.options, item.options, item.id);
    assert.deepEqual(actual.serializedBytes, item.eventJson.map(rawBytes), item.id);
    assert.deepEqual(actual.result, {
      start: item.start,
      selectedIds: item.selectedIds,
      selectedEventJson: item.eventJson.slice(item.start, item.options.end),
    }, item.id);
  }
});

test('raw UTF8 event JSON plus LF differs from projected DTO/message-array bytes', () => {
  const actual = vector('raw-utf8-equality-suffix');
  assert.equal(rawBytes(actual.eventJson[1]) > actual.eventJson[1].length + 1, true);
  const sourceBytes = actual.serializedBytes.reduce((sum, bytes) => sum + bytes, 0);
  const projectedMessages = actual.eventJson.map((text, index) => ({
    ...JSON.parse(text).message, __openclaw: { seq: index + 1 },
  }));
  assert.notEqual(sourceBytes, Buffer.byteLength(JSON.stringify(projectedMessages), 'utf8'));
  const reordered = vector('preserve-json-text-and-order').eventJson[2];
  assert.equal(reordered, ordinary[2]);
  assert.notEqual(reordered, JSON.stringify(JSON.parse(reordered)));
  assert.equal(actual.serializedBytes[2], Buffer.byteLength(reordered, 'utf8') + 1);
  assert.equal(JSON.parse(reordered).message.content, 'Line one\nLine two');
});

test('first indivisible entry may exceed soft bytes while remaining well within source hard limit', () => {
  const actual = vector('indivisible-newest-above-soft-request');
  const lastBytes = actual.serializedBytes.at(-1);
  assert.ok(lastBytes > actual.options.maxBytes);
  assert.ok(lastBytes < 16 * 1024);
  assert.ok(lastBytes < receipt.limits.sourcePageMaxBytes);
  assert.deepEqual(actual.result.selectedIds, ['large-soft']);
  assert.equal(actual.result.selectedEventJson[0], indivisible);
});
