// Ordinary successful public Brave callbacks; no production network or mixed suite.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, captureBraveSearchFilters,
} from './capture-brave-search-filters.mjs';

const root = process.env.OPENCLAW_BRAVE_SOURCE ?? '/tmp/openclaw-488631c';
const fixturePath = process.env.OPENCLAW_BRAVE_FILTER_FIXTURE;
const capture = await captureBraveSearchFilters(root);
const group = id => {
  const row = capture.groups.find(value => value.id === id);
  assert.ok(row, id);
  return row;
};
const query = step => step.request.query;
const cached = (row, expected) => assert.deepEqual(row.steps.map(step => step.cached), expected, row.id);
const hash = value => createHash('sha256').update(value).digest('hex');

test('executes complete pinned public factory/runtime/helpers with explicit fixture boundaries', () => {
  assert.equal(capture.pin, BRAVE_REFERENCE_PIN);
  assert.equal(capture.clock, BRAVE_REFERENCE_CLOCK);
  assert.equal(capture.groups.length, 23);
  assert.equal(capture.invocation, 'createBraveWebSearchProvider().createTool(setup).execute(arguments)');
  assert.equal(capture.boundaries.callbackInvoked, true);
  assert.equal(capture.boundaries.fullSourceModules, true);
  assert.equal(capture.boundaries.actualSharedCache, true);
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  for (const path of [
    'extensions/brave/src/brave-web-search-provider.ts',
    'extensions/brave/src/brave-web-search-provider.runtime.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-shared.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/shared/lazy-runtime.ts', 'src/shared/lazy-promise.ts',
  ]) {
    assert.equal(capture.sources.find(source => source.path === path)?.executed, true, path);
  }
  for (const source of capture.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(source.sourceSha256, hash(bytes), source.path);
    assert.equal(source.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), {
      mode: 'transform', sourceMap: false,
    })), source.path);
    assert.equal(source.wholeModule, true);
  }
  for (const facade of capture.facades) assert.equal(facade.sha256, hash(facade.generatedCode));
  assert.ok(capture.stubs.some(stub => stub.export === 'withSelfHostedWebToolsEndpoint'));
  assert.ok(capture.stubs.some(stub => stub.export === 'normalizeResolvedSecretInputString'));
  assert.ok(capture.aliases.some(alias => alias.kind === 'literal-config-fixture'));
  for (const row of capture.groups) {
    assert.ok(row.audit.some(entry => entry.kind === 'dynamic-import'
      && entry.importer === 'extensions/brave/src/brave-web-search-provider.ts'));
    assert.equal(row.audit.filter(entry => entry.kind === 'unused-service-invoked').length, 0);
    assert.equal(row.audit.filter(entry => entry.export === 'buildTimeoutAbortSignal').length, row.steps.length);
    assert.equal(row.audit.filter(entry => entry.export === 'timeout-cleanup').length, row.steps.length);
    assert.equal(row.descriptor.parameters.properties.count.maximum, 10);
    assert.equal(row.setup.config.plugins.entries.brave.config.webSearch.mode, row.mode);
    for (const step of row.steps) {
      assert.equal(step.result.provider, 'brave');
      assert.equal(step.result.count, 1);
      assert.equal(step.result.results[0].siteName, 'example.com');
      assert.equal(step.result.query, step.arguments.query.trim());
      assert.equal(step.request === null, step.cached);
      if (step.request) {
        assert.equal(step.request.method, 'GET');
        assert.equal(step.request.path, row.mode === 'web'
          ? '/proxy/res/v1/web/search' : '/proxy/res/v1/llm/context');
      }
    }
  }
});

test('canonicalizes country, language aliases, explicit precedence and swapped locale through real cache', () => {
  const locale = group('locale-canonical-cache');
  assert.deepEqual(query(locale.steps[0]), {
    q: 'locale', country: 'DE', search_lang: 'jp', count: '5', ui_lang: 'en-US',
  });
  assert.equal(locale.steps[0].arguments.country, ' de ');
  assert.equal(locale.steps[0].arguments.language, ' JA ');
  cached(locale, [false, true, true, false, false, false]);
  assert.equal(query(locale.steps[3]).country, 'US');
  assert.equal(query(locale.steps[4]).count, '3');
  assert.equal(query(locale.steps[5]).ui_lang, 'en-GB');
  const swapped = group('swapped-locale-cache');
  assert.deepEqual(query(swapped.steps[0]), {
    q: 'swapped', search_lang: 'jp', count: '5', ui_lang: 'en-US',
  });
  cached(swapped, [false, true]);
  const precedence = group('explicit-language-precedence');
  assert.equal(query(precedence.steps[0]).search_lang, 'de');
  cached(precedence, [false, true]);
  assert.equal(query(group('country-all').steps[0]).country, 'ALL');
  for (const [alias, canonical] of [['zh', 'zh-hans'], ['zh-cn', 'zh-hans'], ['zh-sg', 'zh-hans'],
    ['zh-hk', 'zh-hant'], ['zh-tw', 'zh-hant']]) {
    const row = group('language-' + alias);
    assert.equal(query(row.steps[0]).search_lang, canonical);
    cached(row, [false, true]);
  }
});

test('applies the literal dual-purpose locale swap exactly once', () => {
  const row = group('dual-purpose-locale');
  assert.deepEqual(row.steps[0].arguments, {
    query: 'dual-purpose', search_lang: 'en-gb', ui_lang: 'pt-BR',
  });
  assert.deepEqual(query(row.steps[0]), {
    q: 'dual-purpose', search_lang: 'pt-br', count: '5', ui_lang: 'en-GB',
  });
  cached(row, [false]);
});

test('canonicalizes all ordinary freshness names/shortcuts and date forms in both modes', () => {
  for (const mode of ['web', 'llm-context']) {
    const freshness = group(`${mode}-freshness-cache`);
    cached(freshness, [false, true, false, true, false, true, false, true]);
    assert.deepEqual(freshness.steps.filter(step => step.request).map(step => query(step).freshness),
      ['pd', 'pw', 'pm', 'py']);
    const bounded = group(`${mode}-bounded-date-cache`);
    cached(bounded, [false, true, false]);
    assert.equal(query(bounded.steps[0]).freshness, '2025-01-02to2025-01-31');
    assert.equal(query(bounded.steps[2]).freshness, '2025-01-02to2025-02-01');
    const range = group(`${mode}-freshness-range-cache`);
    cached(range, [false, true]);
    assert.equal(query(range.steps[0]).freshness, '2025-01-02to2025-01-31');
    assert.equal(query(group(`${mode}-same-day`).steps[0]).freshness, '2025-01-02to2025-01-02');
    const after = group(`${mode}-after-only-cache`);
    cached(after, [false, true]);
    assert.equal(query(after.steps[0]).freshness, '2025-01-02to2026-10-27');
    if (mode === 'llm-context') {
      for (const row of capture.groups.filter(row => row.mode === mode)) {
        for (const step of row.steps.filter(step => step.request)) {
          assert.equal(Object.hasOwn(query(step), 'count'), false);
          assert.equal(Object.hasOwn(query(step), 'ui_lang'), false);
        }
      }
    }
  }
  const before = group('web-before-only-cache');
  cached(before, [false, true]);
  assert.equal(query(before.steps[0]).freshness, '1970-01-01to2025-01-31');
});

test('records pinned LLM UTC rollover and web after-only cache asymmetry', () => {
  const llm = group('llm-context-utc-rollover');
  cached(llm, [false, false]);
  assert.equal(query(llm.steps[0]).freshness, '2025-01-02to2026-10-27');
  assert.equal(query(llm.steps[1]).freshness, '2025-01-02to2026-10-28');
  const web = group('web-utc-rollover');
  cached(web, [false, true]);
  assert.equal(query(web.steps[0]).freshness, '2025-01-02to2026-10-27');
  assert.deepEqual(web.steps[1].result, { ...web.steps[0].result, cached: true });
});

test('matches a parent-generated frozen fixture when explicitly supplied', () => {
  if (fixturePath) assert.deepEqual(capture, JSON.parse(readFileSync(fixturePath, 'utf8')));
  else assert.equal(capture.groups.flatMap(row => row.steps).length, 60);
});
