import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { captureBrowserQuery } from './capture-browser-query.mjs';
import { projectSnapshotQuery } from '../../packages/tool-host/src/browser/snapshot-query.mjs';

const fixtureUrl = new URL('../../packages/tool-host/test/fixtures/browser-query.json', import.meta.url);
const fixture = JSON.parse(readFileSync(fixtureUrl));
const rows = new Map(fixture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');
function hostSource(source) {
  const raw = source.format === 'aria';
  const refs = raw ? source.nodes.filter(node => node.actionable).map(({ ref, role, name }) => ({ ref, role, name }))
    : Object.entries(source.refs).map(([ref, info]) => ({ ref, ...info }));
  return { ...source, refs, refCount: refs.length, ...(raw ? { nodeCount: source.nodes.length } : {}) };
}

test('actual complete snapshot action exercises ordinary AI/raw queries, parser stats and labels', () => {
  assert.equal(rows.size, 17);
  for (const row of rows.values()) {
    assert.equal(row.calls.length, 1);
    assert.equal(Object.hasOwn(row.calls[0].options, 'query'), false);
    assert.equal(row.calls[0].options.timeoutMs, 20000);
    assert.equal(row.result.details.format, row.snapshot.format);
    if (row.input.query.trim()) assert.ok(row.result.details.stats);
  }
  const selected = rows.get('ai-case-unicode-whitespace');
  assert.equal(selected.result.details.matchCount, 1);
  assert.deepEqual(selected.result.details.stats, { lines: 1, chars: 31, refs: 1, interactive: 1 });
  assert.equal(rows.get('raw-full-line-role-token').result.details.matchCount, 3);
  assert.ok(rows.get('raw-full-line-role-token').boundedText.includes('InlineTextBox "Sign out"'));
  assert.equal(rows.get('raw-unicode').result.details.matchCount, 2);
  assert.equal(rows.get('raw-value-description').result.details.matchCount, 1);
  assert.equal(rows.get('ai-zero-match').result.details.matchCount, 0);
  assert.deepEqual(rows.get('ai-zero-match').result.details.stats, { lines: 0, chars: 0, refs: 0, interactive: 0 });
  assert.equal(rows.get('ai-small-cap').boundedText, '- but');
  assert.equal(rows.get('ai-marker-cap').boundedText.length, 70);
  assert.ok(rows.get('ai-marker-cap').boundedText.endsWith('[truncated — retry with a smaller maxChars or limit]'));
  assert.equal(rows.get('ai-delta-selection').result.details.newElements, 1);
  assert.equal(rows.get('ai-lexical-yaml-ref').result.details.refs, 1);
  const labels = rows.get('ai-labels-selection');
  assert.equal(labels.imageCalls.length, 1);
  assert.equal(labels.result.content[1].type, 'image');
  assert.equal(labels.result.details.labelsCount, 2);
  assert.equal(labels.result.details.annotations.length, 2);
  assert.equal(labels.result.details.refs, 1);
});

test('host query body/stat/summary results equal executed source while public refs stay actionable', () => {
  for (const row of rows.values()) {
    const source = hostSource(row.snapshot);
    const result = projectSnapshotQuery(source, row.input);
    const expected = row.result.details;
    if (!row.input.query.trim()) {
      assert.strictEqual(result, source);
      assert.equal(Object.hasOwn(expected, 'matchCount'), false);
      continue;
    }
    assert.equal(result.snapshot, row.boundedText, row.id);
    assert.equal(result.matchCount, expected.matchCount, row.id);
    assert.deepEqual(result.stats, expected.stats, row.id);
    assert.equal(result.truncated, expected.truncated === true, row.id);
    assert.equal(result.newElements, expected.newElements, row.id);
    assert.equal(row.result.content[0].text.slice(0, row.result.content[0].text.indexOf('\n')), result.summary, row.id);
    assert.equal(result.refCount, result.refs.length);
    if (source.format === 'aria') {
      assert.equal(result.nodeCount, result.nodes.length);
      assert.equal(result.nodeCount, result.stats.refs);
      assert.ok(result.refs.every(ref => result.nodes.some(node => node.ref === ref.ref && node.actionable)));
    }
  }
  const raw = projectSnapshotQuery(hostSource(rows.get('raw-full-line-role-token').snapshot), { query: 'Sign IN' });
  assert.equal(raw.stats.refs, 3);
  assert.equal(raw.refCount, 1);
  const ordered = projectSnapshotQuery(hostSource(rows.get('ai-source-order-and-repeated-tokens').snapshot), { query: 'sign sign' });
  assert.deepEqual(ordered.refs.map(ref => ref.ref), ['e2', 'e1']);
  assert.ok(ordered.snapshot.indexOf('[ref=e1]') < ordered.snapshot.indexOf('[ref=e2]'));
});

test('source/executable/harness/runtime and every generated import binding hash are reproducible', () => {
  assert.equal(fixture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(fixture.sourceRecords.filter(row => row.executed).length, 15);
  for (const row of fixture.sourceRecords) {
    const bytes = readFileSync(join('/tmp/openclaw-488631c', row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256);
    }
  }
  for (const row of fixture.importBindings) {
    assert.equal(hash(row.generatedCode), row.generatedSha256);
    if (row.source && !row.source.startsWith('node:')) assert.equal(hash(readFileSync(join('/tmp/openclaw-488631c', row.source))), row.sourceSha256);
    for (const source of row.sources ?? []) assert.equal(hash(readFileSync(join('/tmp/openclaw-488631c', source.source))), source.sha256);
  }
  assert.equal(hash(readFileSync(fixture.runtime.executable)), fixture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-browser-query.mjs', import.meta.url))), fixture.exporter.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))), fixture.harness.sha256);
  assert.equal(hash(fixture.host.generatedCode), fixture.host.sha256);
  assert.equal(fixture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.sourceTree.before, fixture.sourceTree.after);
});

test('facade boundaries disclose lower transport/envelope/image and host representation adaptations', () => {
  assert.equal(fixture.boundaries.wholeSnapshotActionExecuted, true);
  for (const field of ['realBrowserTransportExecuted', 'realConfigServiceExecuted', 'realExternalEnvelopeExecuted', 'realSanitizerExecuted', 'realImageLoadingExecuted', 'networkExecuted']) assert.equal(fixture.boundaries[field], false);
  for (const word of ['actual normalization', 'facades', 'UTF16', '16000', 'actionable-only']) assert.ok(fixture.limits.some(line => line.includes(word)), word);
});

test('fresh source capture equals the entire frozen standalone fixture', async () => {
  assert.deepEqual(await captureBrowserQuery(), fixture);
});
