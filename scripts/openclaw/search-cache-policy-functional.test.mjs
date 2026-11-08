// Ordinary successful callbacks and shared cache lifecycle; no production network.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { captureSearchCachePolicy } from './capture-search-cache-policy.mjs';

const root = process.env.OPENCLAW_BRAVE_SOURCE ?? '/tmp/openclaw-488631c';
const capture = await captureSearchCachePolicy(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const publicGroup = id => {
  const group = capture.publicGroups.find(row => row.id === id);
  assert.ok(group, id); return group;
};
const helperGroup = id => {
  const group = capture.helperGroups.find(row => row.id === id);
  assert.ok(group, id); return group;
};
const steps = id => helperGroup(id).steps;
const keys = (start, end) => Array.from({ length: end - start + 1 }, (_, i) => `k${start + i}`);
const url = step => step.result.results[0].url;

test('executes complete pinned public factory, shared cache and helper modules', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.publicGroups.length, 8);
  assert.equal(capture.publicGroups.flatMap(group => group.steps).length, 36);
  assert.equal(capture.helperGroups.length, 7);
  assert.equal(capture.boundaries.fullSourceModules, true);
  assert.equal(capture.boundaries.actualSharedCache, true);
  assert.equal(capture.boundaries.helperFunctionsInvoked, true);
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  for (const path of [
    'extensions/brave/src/brave-web-search-provider.ts',
    'extensions/brave/src/brave-web-search-provider.runtime.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/agents/tools/web-shared.ts',
    'src/infra/map-size.ts',
  ]) assert.equal(capture.sources.find(source => source.path === path)?.executed, true, path);
  for (const source of capture.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(source.sourceSha256, digest(bytes), source.path);
    assert.equal(source.executableSha256, digest(stripTypeScriptTypes(bytes.toString(), {
      mode: 'transform', sourceMap: false,
    })), source.path);
    assert.equal(source.wholeModule, true);
  }
  for (const harness of [capture.harness, ...capture.harnessDependencies]) {
    assert.equal(harness.sha256, digest(readFileSync(resolve(harness.path))), harness.path);
  }
  for (const group of capture.publicGroups) {
    assert.equal(group.audit.filter(entry => entry.kind === 'unused-service-invoked').length, 0);
    assert.ok(group.audit.some(entry => entry.kind === 'dynamic-import'
      && entry.importer === 'extensions/brave/src/brave-web-search-provider.ts'));
    assert.equal(group.audit.filter(entry => entry.export === 'timeout-cleanup').length, group.steps.length);
    for (const step of group.steps) {
      assert.equal(step.arguments.count, 2);
      assert.equal(step.result.provider, 'brave');
      assert.equal(step.result.count, 1);
      assert.equal(step.request === null, step.cached);
      if (step.request) {
        assert.equal(step.request.method, 'GET');
        assert.equal(step.request.path, group.mode === 'web'
          ? '/proxy/res/v1/web/search' : '/proxy/res/v1/llm/context');
        assert.deepEqual(step.request.query, group.mode === 'web'
          ? { q: 'ordinary cache policy', count: '2' } : { q: 'ordinary cache policy' });
      }
    }
  }
});

test('public callbacks share result identity across timeout, TTL and overridden default count', () => {
  for (const mode of ['web', 'llm-context']) {
    const row = publicGroup(`${mode}-policy-independent-identity`);
    assert.deepEqual(row.steps.map(step => step.cached), [false, true, true, true]);
    assert.deepEqual(row.steps.map(step => step.cumulativeRequests), [1, 1, 1, 1]);
    assert.deepEqual(row.steps.map(url), Array(4).fill('https://example.com/source-1'));
    assert.deepEqual(row.steps.map(step => step.policy.defaultCount), [5, 5, 9, 3]);
    for (const step of row.steps.slice(1)) {
      assert.deepEqual(step.result, { ...row.steps[0].result, cached: true });
    }
  }
});

test('zero-TTL callbacks bypass reads and writes while retaining the prior long-lived result', () => {
  for (const mode of ['web', 'llm-context']) {
    const row = publicGroup(`${mode}-zero-ttl-bypass`);
    assert.deepEqual(row.steps.map(step => step.cached), [false, false, false, true]);
    assert.deepEqual(row.steps.map(step => step.cumulativeRequests), [1, 2, 3, 3]);
    assert.deepEqual(row.steps.map(url), [1, 2, 3, 1].map(index => `https://example.com/source-${index}`));
    assert.deepEqual(row.steps[3].result, { ...row.steps[0].result, cached: true });
  }
});

test('current-caller age and stored expiry each bound public callback reuse', () => {
  for (const mode of ['web', 'llm-context']) {
    const shortened = publicGroup(`${mode}-shorter-caller-refresh`);
    assert.deepEqual(shortened.steps.map(step => step.elapsedMs), [0, 59_999, 60_000, 60_001, 120_000, 120_001]);
    assert.deepEqual(shortened.steps.map(step => step.cached), [false, true, false, true, false, true]);
    assert.deepEqual(shortened.steps.map(step => step.cumulativeRequests), [1, 1, 2, 2, 3, 3]);
    assert.deepEqual(shortened.steps.map(url), [1, 1, 2, 2, 3, 3].map(index => `https://example.com/source-${index}`));
    const expiry = publicGroup(`${mode}-stored-expiry-ceiling`);
    assert.deepEqual(expiry.steps.map(step => step.cached), [false, true, false, true]);
    assert.deepEqual(expiry.steps.map(step => step.cumulativeRequests), [1, 1, 2, 2]);
    assert.deepEqual(expiry.steps.map(url), [1, 1, 2, 2].map(index => `https://example.com/source-${index}`));
  }
});

test('shared helper retains still-live entries for longer callers and skips zero-TTL mutations', () => {
  const row = steps('caller-age-and-zero-retain');
  assert.deepEqual(row.map(step => step.result), [
    null, { value: { text: 'original' }, cached: true }, null,
    { value: { text: 'original' }, cached: true }, null, null,
    { value: { text: 'original' }, cached: true }, null,
  ]);
  for (const step of row.slice(0, 7)) {
    assert.deepEqual(step.state.keys, ['original']);
    assert.deepEqual(step.state.target, {
      value: { text: 'original' }, insertedAtMs: 0, expiresAtMs: 900,
    });
  }
  assert.deepEqual(row[7].state, { size: 0, keys: [], target: null });
  const expiry = steps('stored-expiry-ceiling');
  assert.deepEqual(expiry[1].result, { value: { text: 'short' }, cached: true });
  assert.deepEqual(expiry[2].state, { size: 0, keys: [], target: null });
  assert.deepEqual(expiry[4].result, { value: { text: 'replacement' }, cached: true });
  assert.deepEqual(expiry[5].state, { size: 0, keys: [], target: null });
});

test('shared helper preserves update order and only removes the requested expired entry', () => {
  const update = steps('update-preserves-insertion-order');
  assert.deepEqual(update[2].state.keys, ['a', 'b']);
  assert.deepEqual(update[3].result, { value: { text: 'updated' }, cached: true });
  assert.deepEqual(update[4].state.keys, ['a', 'b', 'c']);
  const expiry = steps('expiry-is-key-local');
  assert.deepEqual(expiry[2].state.keys, ['expired-neighbor', 'live']);
  assert.deepEqual(expiry[3].state.keys, ['expired-neighbor', 'live', 'new']);
  assert.deepEqual(expiry[4].state.keys, ['live', 'new']);
  assert.deepEqual(expiry[5].result, { value: { text: 'live' }, cached: true });
});

test('shared helper prunes to ninety-nine before set and preserves existing Map positions', () => {
  const update = steps('capacity-prunes-before-existing-update');
  assert.deepEqual(update[99].state.keys, keys(0, 99));
  assert.deepEqual(update[100].state.keys, keys(0, 99));
  assert.deepEqual(update[101].state.keys, keys(1, 100));
  assert.equal(update[102].state.size, 99);
  assert.deepEqual(update[102].state.keys, keys(2, 100));
  assert.deepEqual(update[103].result, { value: { text: 'updated' }, cached: true });
  const oldest = steps('capacity-oldest-reinsert-appends');
  assert.equal(oldest[100].state.size, 100);
  assert.deepEqual(oldest[100].state.keys, [...keys(1, 99), 'k0']);
  assert.deepEqual(oldest[101].result, { value: { text: 'updated oldest' }, cached: true });
  const disabled = steps('capacity-zero-ttl-preserves-state');
  for (const step of disabled.slice(99)) assert.deepEqual(step.state.keys, keys(0, 99));
  assert.deepEqual(disabled[103].result, { value: { text: 'value-50' }, cached: true });
});

test('matches an explicitly supplied frozen parent capture', () => {
  const fixture = process.env.OPENCLAW_SEARCH_CACHE_POLICY_FIXTURE;
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
  else assert.equal(capture.helperGroups.flatMap(group => group.steps).length, 336);
});
