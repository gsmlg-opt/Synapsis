// Ordinary successful Unicode output-budget checks; no production network.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { BRAVE_REFERENCE_PIN } from './capture-brave-search-filters.mjs';
import { captureSearchUnicode } from './capture-search-unicode.mjs';

const root = process.env.OPENCLAW_UNICODE_SOURCE ?? '/tmp/openclaw-488631c';
const fixturePath = process.env.OPENCLAW_SEARCH_UNICODE_FIXTURE;
const capture = await captureSearchUnicode(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const generic = id => {
  const row = capture.genericCases.find(item => item.id === id);
  assert.ok(row, id);
  return row.normalizedUnwrappedResult;
};
const provider = id => {
  const row = capture.providerCases.find(item => item.id === id);
  assert.ok(row, id);
  return row.resultUnwrapped;
};
const units = result => result.results.reduce((sum, row) => sum + row.url.length
  + row.title.length + (row.snippet?.length ?? 0) + (row.siteName?.length ?? 0), 0);

test('executes complete pinned normalizer, UTF16 helpers and provider clients with recorded dependency boundaries', () => {
  assert.equal(capture.pin, BRAVE_REFERENCE_PIN);
  assert.equal(capture.genericCases.length, 12);
  assert.equal(capture.providerCases.length, 7);
  assert.equal(capture.prefixCases.length, 8);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.boundaries.fullSourceModules, true);
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  for (const path of [
    'src/agents/tools/web-search-output.ts',
    'packages/normalization-core/src/utf16-slice.ts',
    'src/security/external-content.ts',
    'extensions/tavily/src/tavily-client.ts',
    'extensions/firecrawl/src/firecrawl-client.ts',
    'extensions/brave/src/brave-web-search-provider.runtime.ts',
  ]) assert.equal(capture.sources.find(source => source.path === path)?.executed, true, path);
  for (const source of capture.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(hash(bytes), source.sourceSha256, source.path);
    assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      source.executableSha256, source.path);
    assert.equal(source.wholeModule, true);
  }
  for (const facade of capture.facades) assert.equal(hash(facade.generatedCode), facade.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  assert.ok(capture.typebox.files.length > 1);
  for (const file of capture.typebox.files) {
    assert.equal(hash(readFileSync(join(typeboxRoot, file.path.slice('typebox/'.length)))), file.sha256, file.path);
  }
  assert.equal(capture.sources.find(source => source.path === 'src/web-search/runtime-error.ts')?.executed, false);
  for (const row of capture.providerCases) {
    assert.equal(row.requests.length, 1);
    assert.equal(row.audit.filter(item => item.kind === 'unused-service-invoked'
      || item.export === 'unused-service-invoked').length, 0);
  }
});

test('retains UTF16 scalar-safe prefixes without treating combining or ZWJ sequences as indivisible graphemes', () => {
  const expected = [
    ['supplementary-before-pair', 'A', 1, true],
    ['supplementary-after-pair', 'A😀', 3, true],
    ['supplementary-exact', 'A😀B', 4, false],
    ['supplementary-no-half', '', 0, true],
    ['combining-scalar-boundary', 'e', 1, true],
    ['zwj-scalar-boundary', '👩‍', 3, true],
    ['bmp-boundary', '界', 1, true],
    ['zero-budget', '', 0, true],
  ];
  assert.deepEqual(capture.prefixCases.map(row => [row.id, row.text, row.usedUnits, row.truncated]), expected);
  for (const row of capture.prefixCases) {
    assert.equal(row.retainedRawChars, row.usedUnits);
    assert.ok(row.usedUnits <= row.maxUnits);
    assert.equal(row.text.isWellFormed(), true);
  }
});

test('generic results charge supplementary code units and leave a one-unit remainder available to the next field', () => {
  const row = generic('generic-emoji-budget');
  const remaining = 20_000 - row.results[0].url.length;
  assert.equal(row.results[0].title, '😀'.repeat(Math.floor(remaining / 2)));
  assert.equal(row.results[0].snippet, 'tail'.slice(0, remaining % 2));
  assert.equal(row.results[0].siteName, '');
  assert.equal(row.truncated, true);
  assert.equal(units(row), 20_000);
});

test('generic results count combining scalars, preserve ordinary trim semantics and keep every source URL', () => {
  const combining = generic('generic-combining-budget');
  const available = 20_000 - combining.results[0].url.length;
  assert.equal(combining.results[0].title, 'e\u0301'.repeat(10_000).slice(0, available));
  assert.equal(combining.results[0].snippet, '');
  assert.equal(units(combining), 20_000);
  const small = generic('generic-short-unicode');
  assert.equal(small.results[0].title, '界😀e\u0301');
  assert.equal(small.results[0].snippet, '👩‍💻文');
  assert.equal(small.truncated, undefined);
  const ten = generic('generic-ten-urls-first');
  assert.deepEqual(ten.results.map(row => row.url), Array.from({ length: 10 }, (_, index) =>
    `https://unicode.example/source-${index}`));
  assert.equal(ten.count, 10);
  assert.equal(ten.truncated, true);
  assert.equal(units(ten), 20_000);
  for (const result of capture.genericCases.map(row => row.normalizedUnwrappedResult)) {
    assert.ok(units(result) <= 20_000, result.query);
    for (const row of result.results) {
      assert.equal(row.title.isWellFormed(), true);
      assert.equal((row.snippet ?? '').isWellFormed(), true);
    }
  }
});

test('full Tavily client spends its shared budget on title then snippet, later rows and answer', () => {
  const leftover = provider('tavily-emoji-leftover');
  assert.equal(leftover.results[0].title, '界'.repeat(19_999));
  assert.equal(leftover.results[0].snippet, '');
  assert.equal(leftover.results[1].title, 'Z');
  assert.equal(leftover.results[1].snippet, '');
  assert.equal(leftover.answer, '');
  assert.equal(leftover.truncated, true);
  const combining = provider('tavily-combining-prefix');
  assert.equal(combining.results[0].title, 'e\u0301'.repeat(10_000));
  assert.equal(combining.results[0].snippet, '');
  const answer = provider('tavily-answer-prefix');
  assert.equal(answer.results[0].title, 'A');
  assert.equal(answer.results[0].snippet, '界'.repeat(19_996));
  assert.equal(answer.answer, '😀X');
  assert.equal(answer.truncated, true);
});

test('full Firecrawl client shares its title, description and scraped-content budget in source order', () => {
  const leftover = provider('firecrawl-emoji-leftover');
  assert.equal(leftover.results[0].title, '界'.repeat(19_999));
  assert.equal(leftover.results[0].description, '');
  assert.equal(leftover.results[0].content, 'A');
  assert.equal(leftover.results[1].title, '');
  assert.equal(leftover.results[1].description, '');
  assert.equal(leftover.results[1].content, '');
  assert.equal(leftover.truncated, true);
  const combining = provider('firecrawl-combining-prefix');
  assert.equal(combining.results[0].title, 'e\u0301'.repeat(10_000));
  assert.equal(combining.results[0].description, '');
  assert.equal(combining.results[0].content, '');
});

test('full Brave callbacks retain provider prose so the generic boundary can trim before budgeting later sources', () => {
  for (const mode of ['web', 'llm']) {
    const id = `brave-${mode}-no-provider-cap`;
    const raw = capture.providerCases.find(row => row.id === id).result;
    const unframed = capture.providerCases.find(row => row.id === id).resultContentUnframed;
    assert.equal(raw.results[0].title.includes(' '.repeat(20_000)), true);
    assert.equal(unframed.results[0].title, ' '.repeat(20_000));
    assert.equal(raw.truncated, undefined);
    assert.equal(provider(id).results[1].title, 'Later 😀 source');
    const normalized = generic('normalized-' + id);
    assert.equal(normalized.results[0].title, '');
    assert.equal(normalized.results[1].title, 'Later 😀 source');
    assert.equal(normalized.results[1].snippet, 'Visible 文 passage');
    assert.equal(normalized.truncated, undefined);
  }
});

test('matches a parent-generated frozen fixture when explicitly supplied', () => {
  if (fixturePath) assert.deepEqual(capture, JSON.parse(readFileSync(fixturePath, 'utf8')));
  else assert.equal(capture.providerCases.every(row => row.result.tookMs === 0), true);
});
