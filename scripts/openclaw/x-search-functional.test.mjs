// Ordinary positive source oracle. No Synapsis product implementation is imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureXSearch, portableXSearchResult, unframeXSearchText } from './capture-x-search.mjs';

const root = process.env.OPENCLAW_X_SEARCH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_X_SEARCH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/x-search.json', import.meta.url);
const capture = await captureXSearch(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => { const value = capture.groups.find(row => row.id === id); assert.ok(value, id); return value; };
const first = id => group(id).steps[0];
const result = id => first(id).resultPortable;
const url = n => `https://x.example/status/${n}`;
const query = 'Find operational updates';

test('complete pinned factory, Responses builder/parser, model compat, cache, wrappers and TypeBox have byte provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.equal(capture.checkout.before.verified, true);
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.typebox.version, '1.3.37');
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked', 'actualJsonResult',
    'actualCache', 'actualResponsesBuilder', 'actualResponseProjection', 'actualModelCompat']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'pluginRegistrationInvoked', 'productionNetworkInvoked']) assert.equal(capture.boundaries[key], false, key);
  for (const path of ['extensions/xai/x-search.ts', 'extensions/xai/x-search-tool-shared.ts',
    'extensions/xai/src/x-search-shared.ts', 'extensions/xai/src/responses-tool-shared.ts',
    'extensions/xai/src/x-search-config.ts', 'extensions/xai/src/tool-config-shared.ts',
    'extensions/xai/model-definitions.ts', 'extensions/xai/model-id.ts', 'extensions/xai/model-compat.ts',
    'extensions/xai/runtime-model-compat.ts', 'src/plugins/provider-model-compat.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tools/web-shared.ts',
    'src/agents/tools/web-search-provider-common.ts', 'src/shared/global-singleton.ts',
    'src/security/external-content.ts', 'packages/normalization-core/src/utf16-slice.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.executableSha256, digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true);
  }
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
  for (const row of capture.facades) assert.equal(row.sha256, digest(row.generatedCode));
  for (const row of [capture.manifest, capture.license]) assert.equal(row.sha256, digest(readFileSync(join(root, row.path))));
  assert.deepEqual(capture.manifest.content, JSON.parse(readFileSync(join(root, capture.manifest.path), 'utf8')));
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-x-search.mjs', import.meta.url))));
  for (const row of capture.harnessDependencies) assert.equal(row.sha256, digest(readFileSync(new URL('../../' + row.path, import.meta.url))));
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256, digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))));
  assert.ok(capture.typebox.files.length > 300);
});

test('actual factory builds exact declared snake-case input schema', () => {
  const { descriptor } = group('basic-default');
  assert.equal(descriptor.name, 'x_search'); assert.equal(descriptor.label, 'X Search');
  assert.equal(descriptor.resultContentSource, 'network');
  assert.equal(descriptor.description, 'Search X (formerly Twitter) using xAI, including targeted post or thread lookups. For per-post stats like reposts, replies, bookmarks, or views, prefer the exact post URL or status ID.');
  const schema = descriptor.parameters;
  assert.equal(schema.type, 'object'); assert.deepEqual(schema.required, ['query']);
  assert.deepEqual(Object.keys(schema.properties), ['query', 'allowed_x_handles', 'excluded_x_handles', 'from_date',
    'to_date', 'enable_image_understanding', 'enable_video_understanding']);
  assert.equal(schema.properties.query.type, 'string');
  for (const key of ['allowed_x_handles', 'excluded_x_handles']) {
    assert.equal(schema.properties[key].type, 'array'); assert.equal(schema.properties[key].maxItems, 20);
    assert.deepEqual(schema.properties[key].items, { minLength: 1, type: 'string' });
  }
  for (const key of ['from_date', 'to_date']) assert.equal(schema.properties[key].type, 'string');
  for (const key of ['enable_image_understanding', 'enable_video_understanding']) assert.equal(schema.properties[key].type, 'boolean');
  for (const row of capture.groups) assert.deepEqual(row.descriptor, descriptor);
});

test('actual builder emits exact defaults and full configured request and echo fields', () => {
  const body = { model: 'grok-4.7', input: [{ role: 'user', content: query }], tools: [{ type: 'x_search' }],
    store: false, reasoning: { effort: 'low' } };
  assert.deepEqual(first('basic-default').request.body, body);
  assert.equal(first('basic-default').request.url, 'https://api.x.ai/v1/responses');
  assert.equal(first('basic-default').request.timeoutSeconds, 30);
  const full = first('full-allowed-options');
  assert.deepEqual(full.request.body, { ...body, max_turns: 4, tools: [{ type: 'x_search',
    allowed_x_handles: ['@Alpha', 'Beta'], from_date: '2024-02-29', to_date: '2026-10-28',
    enable_image_understanding: true, enable_video_understanding: true }] });
  assert.equal(full.request.timeoutSeconds, 17);
  assert.deepEqual(full.resultPortable, { query, provider: 'xai', model: 'grok-4.7', tookMs: 7,
    content: ' Ordinary answer 😀 \n', citations: [url(1)], inlineCitations: [{ start_index: 1, end_index: 9, url: url(1) }],
    allowedXHandles: ['@Alpha', 'Beta'], fromDate: '2024-02-29', toDate: '2026-10-28',
    enableImageUnderstanding: true, enableVideoUnderstanding: true });
  assert.deepEqual(first('excluded-options').request.body, { ...body,
    tools: [{ type: 'x_search', excluded_x_handles: ['@Alpha', 'Beta'] }] });
  assert.deepEqual(first('empty-optional-values').request.body, body);
  assert.deepEqual(first('ordered-duplicate-handles').request.body.tools[0].allowed_x_handles, ['Beta', 'Alpha', 'Beta']);
  assert.deepEqual(first('twenty-handles').request.body.tools[0].allowed_x_handles,
    Array.from({ length: 20 }, (_, n) => 'author' + n));
  for (const row of capture.groups) for (const step of row.steps) if (step.request) {
    assert.equal(step.request.method, 'POST'); assert.deepEqual(step.request.headers, {
      accept: 'application/json', authorization: 'Bearer ' + step.config.plugins.entries.xai.config.webSearch.apiKey,
      'content-type': 'application/json' });
    assert.deepEqual(JSON.parse(step.request.bodyText), step.request.body);
  }
});

test('actual endpoint config appends responses after trim and trailing slash removal', () => {
  assert.equal(first('fallback-endpoint').request.url, 'https://proxy.example/v1/responses');
  assert.equal(first('owned-endpoint').request.url, 'https://owned.example/custom/responses');
});

test('actual catalog aliases and per-model reasoning compatibility produce exact provider bodies', () => {
  const expected = {
    'grok-4.3': ['grok-4.3', 'none'], 'grok-4.3-latest': ['grok-4.3', 'none'],
    'grok-latest': ['grok-latest', undefined], 'grok-4.5': ['grok-4.5', undefined],
    'grok-4.6': ['grok-4.6', 'low'], 'grok-4.7': ['grok-4.7', 'low'],
    'grok-4.20': ['grok-4.20', undefined], 'grok-4-fast': ['grok-4-fast', undefined],
    'grok-5': ['grok-5', 'low'], 'grok-4.8-0115': ['grok-4.8-0115', 'low'],
    'grok-code-fast-1': ['grok-build-0.1', undefined],
  };
  for (const [name, [model, effort]] of Object.entries(expected)) {
    const step = first('model-' + name);
    assert.equal(step.request.body.model, model); assert.equal(step.resultPortable.model, model);
    assert.deepEqual(step.request.body.reasoning, effort ? { effort } : undefined);
  }
});

test('actual response projection concatenates adjacent messages and direct blocks before fallback without trimming', () => {
  assert.equal(result('adjacent-blocks').content, 'First Second😀 Third');
  assert.equal(result('direct-output-text').content, 'Direct answer');
  assert.equal(result('output-text-fallback').content, ' Fallback answer 😀 ');
  assert.equal(result('message-before-fallback').content, 'Block answer');
  assert.deepEqual(result('basic-default'), { query, provider: 'xai', model: 'grok-4.7', tookMs: 7,
    content: ' Ordinary answer 😀 \n', citations: [url(1)] });
});

test('actual citation collector preserves top-level precedence, canonical URL order and positive scan/count bounds', () => {
  assert.deepEqual(result('top-citation-precedence').citations, [url(1), url(3)]);
  assert.deepEqual(result('annotation-citation-order').citations, [url(2), url(1)]);
  assert.deepEqual(result('citation-canonical-url').citations,
    ['https://x.example/path%20with%20space?q=ordinary%20text#section', 'https://bare.example']);
  assert.deepEqual(result('twenty-citations').citations, Array.from({ length: 20 }, (_, n) => url(n)));
  assert.deepEqual(result('citation-thousand-scan').citations, [url(1)]);
  assert.deepEqual(result('annotation-thousand-scan').citations, [url(1)]);
});

test('actual inline citation projection preserves UTF16 positions and explicit empty arrays with twenty entry cap', () => {
  assert.equal(result('inline-utf16-offsets').content, 'A😀BC');
  assert.deepEqual(result('inline-utf16-offsets').inlineCitations, [
    { start_index: 1, end_index: 3, url: url(1) }, { start_index: 3, end_index: 5, url: url(2) },
    { start_index: 5, end_index: 5, url: url(3) }]);
  assert.deepEqual(result('inline-empty-array').inlineCitations, []);
  assert.deepEqual(result('inline-twenty-cap').inlineCitations,
    Array.from({ length: 20 }, (_, n) => ({ start_index: 0, end_index: 6, url: url(n) })));
});

test('actual20000 UTF16 prefix remains contiguous across scalar boundaries and block annotations', () => {
  assert.equal(result('text-below').content, 'A'.repeat(19_999)); assert.equal('truncated' in result('text-below'), false);
  assert.equal(result('text-exact').content, 'A'.repeat(20_000)); assert.equal('truncated' in result('text-exact'), false);
  assert.equal(result('text-over').content, 'A'.repeat(20_000)); assert.equal(result('text-over').truncated, true);
  assert.equal(result('text-emoji').content, 'A'.repeat(19_999));
  assert.equal(result('text-combining').content, 'e\u0301'.repeat(10_000));
  assert.equal(result('text-zwj').content, 'A'.repeat(19_996) + '👩‍');
  const contiguous = result('contiguous-truncation');
  assert.equal(contiguous.content, 'A'.repeat(19_999)); assert.equal(contiguous.truncated, true);
  assert.deepEqual(contiguous.citations, [url(1)]);
  assert.deepEqual(contiguous.inlineCitations, [{ start_index: 19_998, end_index: 19_999, url: url(1) }]);
  for (const name of ['text-emoji', 'text-combining', 'text-zwj', 'contiguous-truncation']) {
    assert.equal(result(name).content.isWellFormed(), true); assert.equal(result(name).truncated, true);
  }
});

test('actual cache preserves full first payload, expiration, zero TTL and current caller TTL', () => {
  const repeat = group('repeat-cache-hit').steps;
  assert.deepEqual(repeat.map(step => step.cumulativeRequests), [1, 1]);
  assert.equal(repeat[1].request, null); assert.deepEqual(repeat[1].result, { ...repeat[0].result, cached: true });
  assert.deepEqual(group('cache-disabled').steps.map(step => step.cumulativeRequests), [1, 2]);
  assert.deepEqual(group('cache-expiration').steps.map(step => step.cumulativeRequests), [1, 1, 2]);
  assert.deepEqual(group('cache-shortened-read').steps.map(step => step.cumulativeRequests), [1, 2, 2]);
  assert.deepEqual(group('cache-timeout-independent').steps.map(step => step.cumulativeRequests), [1, 1]);
});

test('actual cache identity includes ordered filters, model/endpoint/flags/turns/query and fixture-key digest', () => {
  assert.deepEqual(group('cache-key-filter-order').steps.map(step => step.cumulativeRequests), [1, 2, 2]);
  assert.deepEqual(group('cache-key-variants').steps.map(step => step.cumulativeRequests), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10]);
  assert.deepEqual(group('cache-credential-key').steps.map(step => step.cumulativeRequests), [1, 2, 2]);
  const cap = group('cache-hundred-entry-cap').steps;
  assert.equal(cap.length, 102); assert.deepEqual(cap.map(step => step.cumulativeRequests), Array.from({ length: 102 }, (_, n) => n + 1));
  assert.deepEqual(cap[0].arguments, cap[101].arguments);
});

test('original tool JSON/frame/stamp remain intact and portable result deletes only declared frame/stamp', () => {
  for (const row of capture.groups) for (const step of row.steps) {
    assert.deepEqual(step.arguments, step.argumentsAfter); assert.deepEqual(step.config, step.configAfter);
    assert.deepEqual(step.toolResult, { content: [{ type: 'text', text: JSON.stringify(step.result, null, 2) }], details: step.result });
    assert.deepEqual(step.result.externalContent, { untrusted: true, source: 'x_search', provider: 'xai', wrapped: true });
    const portable = { ...step.result, content: unframeXSearchText(step.result.content) }; delete portable.externalContent;
    assert.deepEqual(step.resultPortable, portable); assert.deepEqual(portableXSearchResult(step.result), portable);
    assert.equal(step.resultPortable.tookMs, 7);
  }
});

test('fresh complete capture equals frozen fixture', () => {
  assert.equal(capture.counts.groups, 48); assert.equal(capture.counts.callbacks, 170);
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});
