// Ordinary successful provider/normalizer observations from unchanged pinned source.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { capturePerplexitySearch } from './capture-perplexity-search.mjs';

const root = process.env.OPENCLAW_PERPLEXITY_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_PERPLEXITY_FIXTURE;
const capture = await capturePerplexitySearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => {
  const value = capture.groups.find(row => row.id === id);
  assert.ok(value, id);
  return value;
};
const normalized = id => {
  const value = capture.normalizerCases.find(row => row.id === id);
  assert.ok(value, id);
  return value.publicUnwrappedResult;
};
const first = id => group(id).steps[0];
const answerUnits = row => row.content.length + row.citations.reduce((sum, entry) =>
  sum + entry.url.length + (entry.title?.length ?? 0), 0);

test('records complete pinned provider, configuration, cache and normalizer modules with explicit platform boundaries', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verified, true);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.ok(capture.checkout.before.verifiedTrackedFiles > 58_000);
  assert.equal(capture.typebox.version, '1.3.37');
  assert.equal(capture.boundaries.bodyProjections, false);
  assert.equal(capture.boundaries.productionNetworkInvoked, false);
  assert.equal(capture.boundaries.pluginRegistrationInvoked, false);
  for (const path of [
    'extensions/perplexity/src/perplexity-web-search-provider.ts',
    'extensions/perplexity/src/perplexity-web-search-provider.shared.ts',
    'extensions/perplexity/src/perplexity-web-search-provider.runtime.ts',
    'src/agents/tools/web-search-output.ts', 'src/agents/tools/web-search-provider-config.ts',
    'src/config/plugin-web-search-config.ts', 'src/agents/tools/web-search-provider-common.ts',
    'src/agents/tools/web-shared.ts', 'packages/normalization-core/src/string-normalization.ts',
  ]) assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(digest(bytes), row.sourceSha256, row.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      row.executableSha256, row.path);
    assert.equal(row.wholeModule, true);
  }
  for (const row of capture.facades) assert.equal(digest(row.generatedCode), row.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) {
    assert.equal(digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.sha256);
  }
  for (const row of capture.groups) {
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false);
    assert.ok(row.audit.some(item => item.kind === 'header-policy-fixture'));
    for (const step of row.steps) assert.deepEqual(step.argumentsAfter, step.arguments);
  }
  assert.equal(capture.counts.executedWholeModules,
    capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules,
    capture.sources.filter(row => !row.executed).length);
});

test('constructs the exact two public schemas using actual runtime metadata', () => {
  const structured = group('search-default');
  const chat = group('chat-direct-default');
  assert.deepEqual(structured.metadata, { perplexityTransport: 'search_api' });
  assert.deepEqual(chat.metadata, { perplexityTransport: 'chat_completions' });
  assert.deepEqual(Object.keys(structured.descriptor.parameters.properties), [
    'query', 'count', 'freshness', 'country', 'language', 'date_after', 'date_before',
    'domain_filter', 'max_tokens', 'max_tokens_per_page',
  ]);
  assert.deepEqual(Object.keys(chat.descriptor.parameters.properties), ['query', 'count', 'freshness']);
  for (const row of [structured, chat]) {
    assert.deepEqual(row.descriptor.parameters.required, ['query']);
    assert.equal(row.descriptor.parameters.properties.count.minimum, 1);
    assert.equal(row.descriptor.parameters.properties.count.maximum, 10);
  }
  assert.equal(structured.descriptor.parameters.properties.max_tokens.maximum, 1_000_000);
  assert.equal(structured.descriptor.parameters.properties.max_tokens_per_page.minimum, 1);
});

test('Search API forwards all ordinary structured options with exact date and domain mapping', () => {
  assert.deepEqual(first('search-default').request.body,
    { query: 'search-default', max_results: 5 });
  const allow = first('search-options-allow');
  assert.equal(allow.request.url, 'https://api.perplexity.ai/search');
  assert.equal(allow.request.method, 'POST');
  assert.equal(allow.request.timeoutSeconds, 12);
  assert.deepEqual(allow.request.body, {
    query: 'structured options', max_results: 2, country: 'US',
    search_domain_filter: ['alpha.example', 'alpha.example', 'beta.example'],
    search_language_filter: ['EN'], search_after_date_filter: '1/2/2025',
    search_before_date_filter: '1/31/2025', max_tokens: 1_000_000, max_tokens_per_page: 1,
  });
  assert.deepEqual(first('search-options-deny').request.body.search_domain_filter,
    ['-alpha.example', '-alpha.example', '-beta.example']);
  assert.equal(first('search-options-deny').request.body.max_tokens, 1);
  assert.equal(first('search-options-deny').request.body.max_tokens_per_page, 2);
  assert.equal(first('search-configured-count').request.body.max_results, 3);
  assert.equal(first('search-count-ten').providerResult.count, 10);
  assert.equal(first('search-count-ten').publicUnwrappedResult.count, 10);
  assert.deepEqual(first('search-count-ten').publicUnwrappedResult.results.map(row => row.url),
    Array.from({ length: 10 }, (_, index) => `https://source.example/${index + 1}`));
});

test('freshness aliases and equivalent date spellings use real preparation and shared cache', () => {
  const steps = group('search-freshness-aliases').steps;
  assert.deepEqual(steps.map(row => row.cached), [false, true, false, true, false, true, false, true]);
  assert.deepEqual(steps.filter(row => row.request).map(row => row.request.body.search_recency_filter),
    ['day', 'week', 'month', 'year']);
  for (const id of ['search-dates-bounded', 'search-dates-after', 'search-dates-before', 'search-dates-same-day']) {
    const rows = group(id).steps;
    assert.equal(rows[0].cached, false);
    assert.equal(rows[1].cached, true);
    assert.equal(rows[1].request, null);
    assert.deepEqual(rows[1].publicUnwrappedResult, { ...rows[0].publicUnwrappedResult, cached: true });
  }
});

test('Sonar uses actual direct namespace stripping, remote namespace retention and source routing', () => {
  const direct = first('chat-direct-default');
  assert.equal(direct.request.url, 'https://api.perplexity.ai/chat/completions');
  assert.deepEqual(direct.request.body, {
    model: 'sonar-pro', messages: [{ role: 'user', content: 'chat-direct-default' }],
  });
  assert.equal(direct.providerResult.model, 'perplexity/sonar-pro');
  assert.equal(direct.publicResult.model, undefined);
  assert.equal(direct.publicResult.kind, 'answer');
  assert.equal(direct.publicResult.results, undefined);
  assert.equal(direct.publicResult.count, undefined);
  assert.equal(first('chat-direct-model').request.body.model, 'sonar-reasoning-pro');
  assert.equal(first('chat-custom-model').request.body.model, 'perplexity/sonar-reasoning-pro');
  assert.equal(first('chat-custom-model').request.url, 'https://router.example/proxy/chat/completions');
  assert.equal(first('chat-openrouter').request.body.model, 'perplexity/sonar-pro');
  assert.equal(first('chat-openrouter').request.url, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(group('search-blank-overrides').metadata.perplexityTransport, 'search_api');
  assert.equal(first('chat-freshness').request.body.search_recency_filter, 'week');
});

test('Sonar preserves first-seen top-level citations and falls back across annotation choices', () => {
  const top = first('chat-top-citations');
  assert.deepEqual(top.providerResult.citations, ['https://citation.example/b', 'https://citation.example/a']);
  assert.deepEqual(top.publicUnwrappedResult.citations,
    [{ url: 'https://citation.example/b' }, { url: 'https://citation.example/a' }]);
  assert.equal(top.publicUnwrappedResult.content, 'Grounded answer 😀');
  assert.deepEqual(first('chat-annotations').providerResult.citations,
    ['https://citation.example/nested', 'https://citation.example/flat', 'https://citation.example/later']);
  assert.deepEqual(first('chat-empty-citations').publicUnwrappedResult.citations, []);
});

test('count keys Search API requests but does not split identical Sonar answers', () => {
  assert.deepEqual(group('search-cache-count').steps.map(row => row.cached), [false, false, true]);
  assert.deepEqual(group('chat-cache-count').steps.map(row => row.cached), [false, true, true]);
  assert.deepEqual(group('search-cache-count').steps.map(row => row.cumulativeRequests), [1, 2, 2]);
  assert.deepEqual(group('chat-cache-count').steps.map(row => row.cumulativeRequests), [1, 1, 1]);
  for (const id of ['search-cache-policy', 'chat-cache-policy']) {
    const rows = group(id).steps;
    assert.deepEqual(rows.map(row => row.cached), [false, true, false, false, true, false, true]);
    assert.equal(rows[2].request.timeoutSeconds, 7);
    assert.equal(rows[4].providerUnwrappedResult.tookMs, rows[0].providerUnwrappedResult.tookMs);
  }
  for (const id of ['search-query-whitespace-cache', 'chat-query-whitespace-cache']) {
    const rows = group(id).steps;
    assert.equal(rows[0].request.body.query ?? rows[0].request.body.messages[0].content, 'ordinary query');
    assert.equal(rows[1].request, null);
    assert.equal(rows[0].publicUnwrappedResult.query, ' ordinary query ');
    assert.equal(rows[1].publicUnwrappedResult.query, 'ordinary query');
  }
});

test('normalizer reserves ordered citation URLs before scalar-safe UTF16 answer content', () => {
  const emoji = normalized('answer-body-emoji');
  const budget = 20_000 - emoji.citations.reduce((sum, row) => sum + row.url.length, 0);
  assert.equal(emoji.content, '😀'.repeat(Math.floor(budget / 2)));
  assert.equal(emoji.content.isWellFormed(), true);
  assert.equal(emoji.truncated, true);
  assert.ok(answerUnits(emoji) <= 20_000);
  const combining = normalized('answer-body-combining');
  const available = 20_000 - combining.citations[0].url.length;
  assert.equal(combining.content, 'e\u0301'.repeat(12_000).slice(0, available));
  const zwj = normalized('answer-body-zwj');
  assert.equal(zwj.content.isWellFormed(), true);
  assert.ok(answerUnits(zwj) <= 20_000);
  assert.deepEqual(normalized('answer-ordered-citations').citations.map(row => row.url),
    ['https://citation.example/b', 'https://citation.example/a', 'https://citation.example/b']);
  const leftover = normalized('answer-body-emoji-leftover');
  assert.equal(leftover.citations[0].title, 'Z');
  assert.equal(answerUnits(leftover), 20_000);
});

test('normalizer caps ordinary citation lists and budgets titles after answer content in citation order', () => {
  const capped = normalized('answer-citation-limit');
  assert.equal(capped.citations.length, 20);
  assert.equal(capped.truncated, true);
  assert.deepEqual(capped.citations.map(row => row.url),
    Array.from({ length: 20 }, (_, index) => `https://citation.example/${index + 1}`));
  const titles = normalized('answer-title-budget');
  const remaining = 20_000 - titles.content.length - titles.citations.reduce((sum, row) => sum + row.url.length, 0);
  assert.equal(titles.content, 'Ordinary answer');
  assert.equal(titles.citations[0].title, '界'.repeat(remaining));
  assert.equal(titles.citations[1].title, '');
  assert.equal(answerUnits(titles), 20_000);
  assert.equal(normalized('answer-empty-citations').citations.length, 0);
  assert.equal(normalized('answer-short-unicode').content, '界😀e\u0301 👩‍💻');
  assert.deepEqual(normalized('answer-url-canonicalization').citations, [
    { url: 'https://citation.example/ordinary?q=hello%20world', title: 'Ordinary title' },
    { url: 'https://source.example/path#section' },
  ]);
  assert.deepEqual(normalized('answer-title-order').citations, [
    { url: 'https://citation.example/b', title: 'Title B' },
    { url: 'https://citation.example/a', title: 'Title A' },
  ]);
  const exhausted = normalized('answer-citations-exhaust-body');
  const original = capture.normalizerCases.find(row => row.id === 'answer-citations-exhaust-body');
  assert.equal(original.providerResult.content, 'Nonempty ordinary answer');
  assert.deepEqual(exhausted.citations.map(row => row.url), original.providerResult.citations);
  assert.equal(exhausted.citations.length, 20);
  assert.equal(exhausted.content, '');
  assert.equal(exhausted.truncated, true);
  assert.equal(answerUnits(exhausted), 20_000);
});

test('fresh capture equals the supplied frozen ordinary fixture', () => {
  if (fixture) assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
  else assert.ok(capture.groups.length >= 20);
});
