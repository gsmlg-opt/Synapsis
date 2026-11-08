// Ordinary source arithmetic and the private host preparation contract only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { captureBrowserTiming, BROWSER_TIMING_PIN } from './capture-browser-timing.mjs';
import { prepareActRequest } from '../../packages/tool-host/src/browser/timing.mjs';

const source = process.env.OPENCLAW_BROWSER_TIMING_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = JSON.parse(readFileSync(process.env.OPENCLAW_BROWSER_TIMING_FIXTURE ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/browser-timing.json', import.meta.url), 'utf8'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const expected = {
  'model-local-default-click': 126250,
  'model-local-zero-delay-wait': 126250,
  'explicit-click': 96250,
  'delayed-click-phases': 130250,
  'nested-sequential-waits': 95000,
  'six-condition-wait': 135000,
  'standalone-slow-type-submit': 185250,
  'four-scroll-batch': 86000,
  'batch-shallow-defaults': 149250,
  'hundred-six-condition-waits': 72005000,
  'hundred-delayed-six-condition-waits': 75005000,
  'recursive-budget-saturates': 2147000000,
  'phase-floor': 80000,
  'phase-ceiling': 725000,
  'coordinate-double-delay': 21250,
};

test('records complete unchanged arithmetic modules and explicit provenance-only tool/driver boundaries', () => {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(fixture.referenceCommit, BROWSER_TIMING_PIN);
  assert.equal(fixture.runtime, '24.22.1');
  assert.equal(fixture.sourceRecords.filter(row => row.executed).length, 7);
  assert.equal(fixture.sourceRecords.filter(row => !row.executed).length, 10);
  assert.equal(fixture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.sourceTree.before, fixture.sourceTree.after);
  assert.equal(fixture.preparation.sourceExecuted, false);
  assert.ok(fixture.sourceRecords.some(row => row.path === 'extensions/browser/src/browser-tool-dispatch.ts' && row.provenanceOnly && !row.executed));
  assert.equal(fixture.exporterSha256, hash(readFileSync(new URL('./capture-browser-timing.mjs', import.meta.url))));
  for (const row of fixture.sourceRecords) {
    const bytes = readFileSync(join(source, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
    } else assert.equal(row.provenanceOnly, true);
  }
});

test('ordinary phase arithmetic includes serial wait sums, one transport slack, large valid budgets and saturation', () => {
  assert.equal(fixture.vectors.length, 15);
  assert.deepEqual(Object.fromEntries(fixture.vectors.map(row => [row.name, row.requestTimeoutMs])), expected);
  const maximumWait = fixture.vectors.find(row => row.name === 'hundred-delayed-six-condition-waits');
  assert.equal(maximumWait.preparedRequest.actions.length, 100);
  assert.ok(maximumWait.preparedRequest.actions.every(row => row.timeMs === 30000 && row.timeoutMs === 120000));
  const nested = fixture.vectors.find(row => row.name === 'nested-sequential-waits');
  assert.equal(nested.preparedRequest.actions[1].kind, 'batch');
  assert.equal(nested.requestTimeoutMs, 3 * 30000 + 5000);
});

test('host private preparation matches explicit source-reviewed pairs while raw and nested inputs stay unchanged', () => {
  for (const row of fixture.vectors) {
    const raw = structuredClone(row.rawRequest);
    const prepared = prepareActRequest(raw);
    assert.deepEqual(prepared, row.preparedRequest, row.name);
    assert.deepEqual(raw, row.rawRequestAfter, row.name);
    assert.deepEqual(row.preparedRequest, row.preparedRequestAfter, row.name);
    assert.notEqual(raw, prepared);
  }
  const batch = fixture.vectors.find(row => row.name === 'batch-shallow-defaults');
  assert.equal(batch.preparedRequest.actions[0].timeoutMs, undefined);
  assert.equal(batch.preparedRequest.actions[1].timeoutMs, undefined);
});

test('fresh complete-source VM capture equals the frozen ordinary fixture', { timeout: 60000 }, async () => {
  assert.deepEqual(await captureBrowserTiming(source), fixture);
});
