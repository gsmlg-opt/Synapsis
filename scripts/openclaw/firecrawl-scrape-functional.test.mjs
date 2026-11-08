// Positive ordinary source oracle. No Synapsis implementation is imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureFirecrawlScrape, unframeScrapeText, unframeScrapeResult,
  portableScrapeResult } from './capture-firecrawl-scrape.mjs';

const root = process.env.OPENCLAW_FIRECRAWL_SCRAPE_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_FIRECRAWL_SCRAPE_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/firecrawl-scrape.json', import.meta.url);
const capture = await captureFirecrawlScrape(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => { const row = capture.groups.find(row => row.id === id); assert.ok(row, id); return row; };
const first = id => group(id).steps[0];
const result = id => first(id).resultUnframed;
const url = 'https://source.example/article';

test('whole pinned plugin, standalone client, config, readers, markdown helper, wrappers and TypeBox have byte provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.deepEqual(capture.checkout.after, capture.checkout.before);
  assert.equal(capture.typebox.version, '1.3.37');
  for (const key of ['fullSourceModules', 'pluginRegistrationInvoked', 'factoryInvoked', 'publicCallbackInvoked',
    'actualJsonResult', 'actualMarkdownToText', 'actualPluginConfigReader']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'productionNetworkInvoked', 'localResultCache']) assert.equal(capture.boundaries[key], false, key);
  for (const path of ['extensions/firecrawl/index.ts', 'extensions/firecrawl/src/firecrawl-client.ts',
    'extensions/firecrawl/src/firecrawl-fetch-provider.ts', 'extensions/firecrawl/src/firecrawl-search-provider.ts',
    'src/plugin-sdk/plugin-entry.ts', 'src/plugin-sdk/lazy-value.ts', 'src/plugin-sdk/plugin-config-runtime.ts',
    'src/config/runtime-config-capture-state.ts', 'src/plugins/config-state.ts', 'src/plugins/config-normalization-shared.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tools/web-fetch-utils.ts',
    'src/security/external-content.ts', 'packages/normalization-core/src/utf16-slice.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(digest(bytes), row.sourceSha256, row.path);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
    assert.equal(row.wholeModule, true);
  }
  for (const row of capture.facades) assert.equal(digest(row.generatedCode), row.sha256);
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
  for (const row of [capture.manifest, capture.license]) assert.equal(digest(readFileSync(join(root, row.path))), row.sha256);
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.deepEqual(capture.manifest.content, JSON.parse(readFileSync(join(root, capture.manifest.path), 'utf8')));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-firecrawl-scrape.mjs', import.meta.url))));
  for (const row of capture.harnessDependencies) assert.equal(digest(readFileSync(new URL('../../' + row.path, import.meta.url))), row.sha256);
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))), row.sha256);
  assert.ok(capture.typebox.files.length > 300);
  for (const name of ['sanitizeHtml', 'decodeHtmlEntities', 'readHtmlAttribute', 'normalizeChatChannelId', 'cloneConfigWithResolutionFacts']) {
    assert.ok(capture.stubs.some(row => row.export === name && row.kind === 'unused-platform-service'), name);
  }
});

test('actual plugin registration constructs both generic providers and standalone tools with exact scrape schema', () => {
  const { descriptor, registration } = group('basic-default');
  assert.equal(registration.pluginId, 'firecrawl');
  assert.deepEqual(registration.fetchProviders, [{ id: 'firecrawl', label: 'Firecrawl' }]);
  assert.deepEqual(registration.providers, [{ id: 'firecrawl', label: 'Firecrawl Search' },
    { id: 'firecrawl-free', label: 'Firecrawl Search (Free)' }]);
  assert.deepEqual(registration.tools, [{ name: 'firecrawl_search' }, { name: 'firecrawl_scrape' }]);
  assert.equal(descriptor.name, 'firecrawl_scrape');
  assert.equal(descriptor.label, 'Firecrawl Scrape');
  assert.equal(descriptor.resultContentSource, 'network');
  assert.equal(descriptor.description, 'Scrape a page using Firecrawl v2/scrape. Useful for JS-heavy or bot-protected pages where a plain URL fetch is weak.');
  const schema = descriptor.parameters;
  assert.deepEqual(Object.keys(schema.properties), ['url', 'extractMode', 'maxChars', 'onlyMainContent',
    'maxAgeMs', 'proxy', 'storeInCache', 'timeoutSeconds']);
  assert.deepEqual(schema.required, ['url']);
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.url.type, 'string');
  assert.deepEqual(schema.properties.extractMode.enum, ['markdown', 'text']);
  assert.deepEqual(schema.properties.proxy.enum, ['auto', 'basic', 'stealth']);
  for (const [key, minimum] of [['maxChars', 100], ['maxAgeMs', 0], ['timeoutSeconds', 1]]) {
    assert.equal(schema.properties[key].type, 'integer'); assert.equal(schema.properties[key].minimum, minimum);
  }
  for (const key of ['onlyMainContent', 'storeInCache']) assert.equal(schema.properties[key].type, 'boolean');
  for (const row of capture.groups) assert.deepEqual(row.descriptor, descriptor);
});

test('actual client emits exact defaults, configured values, false/zero and full explicit option overrides', () => {
  const defaults = { url, formats: ['markdown'], onlyMainContent: true, timeout: 60_000,
    maxAge: 172_800_000, proxy: 'auto', storeInCache: true };
  assert.deepEqual(first('basic-default').request.body, defaults);
  assert.deepEqual(first('configured-defaults').request.body, { ...defaults, onlyMainContent: false, maxAge: 0, timeout: 17_000 });
  assert.deepEqual(first('full-options-false-zero').request.body, { ...defaults, onlyMainContent: false,
    maxAge: 0, timeout: 3_000, proxy: 'stealth', storeInCache: false });
  assert.deepEqual(first('full-options-true').request.body, { ...defaults,
    maxAge: 12_345, timeout: 9_000, proxy: 'basic' });
  assert.equal(result('full-options-false-zero').extractMode, 'text');
  assert.equal(result('full-options-true').extractMode, 'markdown');
  assert.equal(first('endpoint-replacement').request.url, 'https://api.firecrawl.dev/v2/scrape');
  for (const row of capture.groups) {
    assert.deepEqual(row.configAfter, row.config);
    assert.equal(row.audit.some(item => item.kind === 'unused-service-invoked'), false);
    const http = row.audit.filter(item => item.kind === 'successful-http-fixture');
    const parsers = row.audit.filter(item => item.kind === 'successful-json-fixture');
    assert.equal(http.length, row.steps.length); assert.equal(parsers.length, row.steps.length);
    for (const parser of parsers) assert.deepEqual(parser,
      { kind: 'successful-json-fixture', errorLabel: 'Firecrawl fetch failed', options: { maxBytes: 67_108_864 } });
    for (const step of row.steps) {
      assert.deepEqual(step.argumentsAfter, step.arguments);
      const request = step.request;
      assert.equal(request.url, 'https://api.firecrawl.dev/v2/scrape');
      assert.equal(request.method, 'POST'); assert.equal(request.path, '/v2/scrape');
      assert.deepEqual(request.query, {});
      assert.deepEqual(request.headers, { 'Content-Type': 'application/json', Authorization: 'Bearer fixture-firecrawl-key' });
      assert.equal(request.bodyText, JSON.stringify(request.body));
      assert.equal(request.timeoutSeconds * 1_000, request.body.timeout);
      assert.deepEqual(request.body.formats, ['markdown']);
    }
  }
});

test('full result is preserved and exact reference-only unframing retains prose whitespace and original lengths', () => {
  for (const row of capture.groups) for (const step of row.steps) {
    const framed = step.result, unframed = step.resultUnframed;
    assert.deepEqual(step.toolResult.details, framed);
    assert.deepEqual(step.toolResult.content, [{ type: 'text', text: JSON.stringify(framed, null, 2) }]);
    assert.deepEqual(framed.externalContent, { untrusted: true, source: 'web_fetch', wrapped: true });
    assert.deepEqual(unframeScrapeResult(framed), unframed);
    assert.deepEqual(Object.keys(unframed), Object.keys(framed));
    assert.equal(unframed.length, framed.length);
    assert.equal(framed.length, framed.text.length);
    for (const key of ['text', 'title', 'warning']) if (key in framed) {
      assert.equal(unframeScrapeText(framed[key]), unframed[key]);
    }
    assert.deepEqual(step.resultPortable, portableScrapeResult(unframed));
    const expected = { ...unframed, length: unframed.text.length }; delete expected.externalContent;
    assert.deepEqual(step.resultPortable, expected);
    assert.equal(step.resultPortable.rawLength, framed.rawLength);
  }
  const original = first('basic-default').resultUnframed;
  assert.deepEqual(portableScrapeResult({ ...original, ordinaryExtra: 'retained' }),
    { ...first('basic-default').resultPortable, ordinaryExtra: 'retained' });
  assert.equal(result('unicode-whitespace').text, ' \t界😀e\u0301 👩‍💻 \n');
  assert.equal(result('unicode-whitespace').title, ' \t標題😀 \n');
  assert.equal(result('unicode-whitespace').warning, '\n Notice 😀 \t');
  assert.deepEqual(Object.keys(result('basic-default')), ['url', 'finalUrl', 'status', 'title', 'extractor',
    'extractMode', 'externalContent', 'truncated', 'rawLength', 'length', 'text', 'warning']);
});

test('whole markdown helper handles prose, links, lists, inline code and closed/adjacent/unclosed ordinary fences', () => {
  const expected = {
    prose: 'Heading\n\nA linked page and inline code.\n\nfirst\nsecond\nthird\nfourth\n\nEnd.',
    'fenced-code': 'Before\n# literal heading\n- literal list\n[code](https://code.example) `kept`\n\nAfter',
    'adjacent-fences': 'first\nsecond\n\nAfter',
    'unclosed-fence': 'Before\n# literal heading\n- literal list',
    'unclosed-inline-fence': 'Before ```inline ordinary prose',
    whitespace: 'Heading text\n\n Next\tline',
  };
  for (const [name, text] of Object.entries(expected)) {
    const markdown = group(`markdown-${name}`), converted = result(`text-${name}`);
    assert.equal(result(`markdown-${name}`).text, markdown.httpPayload.data.markdown);
    assert.equal(converted.text, text, name);
    assert.equal(converted.rawLength, text.length);
    assert.equal(converted.truncated, false);
    assert.equal(first(`text-${name}`).request.body.formats[0], 'markdown');
  }
});

test('ordinary CR/LS/PS boundaries strip heading/unordered/ordered prefixes before CR removal and preserve complete results', () => {
  const source = 'Start\r# CR heading\r- CR unordered\r1. CR ordered\u2028## LS heading\u2028* LS unordered\u20282. LS ordered\u2029### PS heading\u2029+ PS unordered\u20293. PS ordered\nEnd';
  const converted = 'StartCR headingCR unorderedCR ordered\u2028LS heading\u2028LS unordered\u2028LS ordered\u2029PS heading\u2029PS unordered\u2029PS ordered\nEnd';
  for (const [mode, expected] of [['markdown', source], ['text', converted]]) {
    const step = first(`${mode}-line-boundaries`);
    assert.equal(group(`${mode}-line-boundaries`).httpPayload.data.markdown, source);
    const text = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Fetch\n---\n'
      + expected + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
    const full = { url, finalUrl: url, extractor: 'firecrawl', extractMode: mode,
      externalContent: { untrusted: true, source: 'web_fetch', wrapped: true },
      truncated: false, rawLength: expected.length, length: text.length, text };
    assert.deepEqual(step.result, full);
    assert.deepEqual(step.resultUnframed, { ...full, text: expected });
    assert.deepEqual(step.toolResult, { content: [{ type: 'text', text: JSON.stringify(full, null, 2) }], details: full });
    const portable = { ...full, length: expected.length, text: expected }; delete portable.externalContent;
    assert.deepEqual(step.resultPortable, portable);
  }
});

test('ordered list conversion removes ASCII decimal prefixes and retains Arabic/fullwidth numeral prose', () => {
  const step = first('text-ascii-ordered-prefix');
  const original = '١. Arabic\n１. Fullwidth\n1. ASCII\n١٢. Kept';
  const converted = '١. Arabic\n１. Fullwidth\nASCII\n١٢. Kept';
  assert.equal(group('text-ascii-ordered-prefix').httpPayload.data.markdown, original);
  assert.deepEqual(step.arguments, { url, extractMode: 'text' });
  const text = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Fetch\n---\n'
    + converted + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
  const full = { url, finalUrl: url, extractor: 'firecrawl', extractMode: 'text',
    externalContent: { untrusted: true, source: 'web_fetch', wrapped: true },
    truncated: false, rawLength: converted.length, length: text.length, text };
  assert.deepEqual(step.result, full);
  assert.deepEqual(step.resultUnframed, { ...full, text: converted });
  assert.deepEqual(step.toolResult, { content: [{ type: 'text', text: JSON.stringify(full, null, 2) }], details: full });
  const portable = { ...full, length: converted.length, text: converted }; delete portable.externalContent;
  assert.deepEqual(step.resultPortable, portable);
});

test('body caps default to50000, honor lower limits and require both option/config to exceed default', () => {
  for (const [name, length, truncated] of [['default-full', 49_999, false], ['default-exact', 50_000, false],
    ['default-overflow', 50_000, true], ['explicit-default-cap', 50_000, true],
    ['raised-cap-default', 50_000, true], ['raised-both', 50_001, false],
    ['lower-cap', 200, true], ['explicit-lower', 100, true]]) {
    const row = result(`body-${name}`);
    assert.equal(row.text.length, length, name); assert.equal(row.truncated, truncated, name);
    assert.equal(row.rawLength, group(`body-${name}`).httpPayload.data.markdown.length);
  }
  assert.equal(result('body-emoji').text, '😀'.repeat(50));
  assert.equal(result('body-combining').text, 'e\u0301'.repeat(50) + 'e');
  assert.equal(result('body-zwj').text, 'x'.repeat(97) + '👩‍');
  for (const name of ['emoji', 'combining', 'zwj']) {
    assert.equal(result(`body-${name}`).text.isWellFormed(), true);
    assert.equal(result(`body-${name}`).truncated, true);
  }
});

test('title then warning share4000 UTF16 units independently from body and aggregate truncation', () => {
  const full = result('metadata-full');
  assert.equal(full.title, 'T'.repeat(2_000)); assert.equal(full.warning, 'W'.repeat(1_999));
  assert.equal(full.truncated, false);
  for (const name of ['exact', 'overflow']) {
    const row = result(`metadata-${name}`);
    assert.equal(row.title, 'T'.repeat(2_500)); assert.equal(row.warning, 'W'.repeat(1_500));
    assert.equal(row.truncated, name === 'overflow');
  }
  assert.equal(result('metadata-title-overflow').title, 'T'.repeat(4_000));
  assert.equal(result('metadata-title-overflow').warning, '');
  assert.equal(result('metadata-emoji').title, '😀'.repeat(2_000));
  assert.equal(result('metadata-emoji').warning, '');
  assert.equal(result('metadata-emoji-leftover').title, '界'.repeat(3_999));
  assert.equal(result('metadata-emoji-leftover').warning, 'Z');
  assert.equal(result('metadata-combining').title, 'e\u0301'.repeat(2_000));
  assert.equal(result('metadata-zwj').title, 'x'.repeat(3_996) + '👩‍');
  assert.equal(result('metadata-zwj').warning, 'Q');
  for (const name of ['title-overflow', 'emoji', 'emoji-leftover', 'combining', 'zwj']) {
    const row = result(`metadata-${name}`);
    assert.equal(row.title.length + row.warning.length, 4_000);
    assert.equal(row.title.isWellFormed(), true); assert.equal(row.warning.isWellFormed(), true);
    assert.equal(row.text, 'Body'); assert.equal(row.rawLength, 4); assert.equal(row.truncated, true);
  }
});

test('successful content/status/sourceURL parsing preserves precedence and canonical bare origins', () => {
  assert.equal(result('fallback-content').text, ' Fallback content 😀 \n');
  assert.equal(result('fallback-content').status, 202);
  assert.equal(result('fallback-content').finalUrl, 'https://fallback.example/path%20with%20space');
  assert.equal(result('status-metadata-precedence').status, 201);
  assert.equal(result('status-absent-url-input').status, undefined);
  assert.equal(result('status-absent-url-input').finalUrl, url);
  assert.equal(result('status-absent-url-input').title, undefined);
  assert.equal(result('status-absent-url-input').warning, undefined);
  assert.equal(result('canonical-source-url').finalUrl, 'https://source.example/ordinary%20path?q=hello%20world#section');
  assert.equal(result('bare-origin-source-url').finalUrl, 'https://bare.example');
  for (const row of capture.groups) for (const step of row.steps) {
    assert.equal(step.resultUnframed.url, url);
    assert.equal(step.resultUnframed.extractor, 'firecrawl');
  }
});

test('direct factory readers accept complete scientific numeric strings independently of the integer model schema', () => {
  const step = first('direct-factory-scientific-numbers');
  const schema = group('direct-factory-scientific-numbers').descriptor.parameters;
  assert.equal(schema.properties.maxChars.type, 'integer');
  assert.equal(schema.properties.timeoutSeconds.type, 'integer');
  assert.deepEqual(step.arguments, { url, maxChars: '1.e2', timeoutSeconds: '3.e0' });
  assert.deepEqual(step.argumentsAfter, step.arguments);
  assert.equal(step.request.timeoutSeconds, 3);
  assert.deepEqual(step.request.body, { url, formats: ['markdown'], onlyMainContent: true,
    timeout: 3_000, maxAge: 172_800_000, proxy: 'auto', storeInCache: true });
  const content = 'N'.repeat(100);
  const text = '\n<<<EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>\nSource: Web Fetch\n---\n'
    + content + '\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="4242424242424242">>>';
  const full = { url, finalUrl: url, status: 200, extractor: 'firecrawl', extractMode: 'markdown',
    externalContent: { untrusted: true, source: 'web_fetch', wrapped: true },
    truncated: true, rawLength: 101, length: text.length, text };
  assert.deepEqual(step.result, full);
  assert.deepEqual(step.resultUnframed, { ...full, text: content });
  assert.deepEqual(step.toolResult, { content: [{ type: 'text', text: JSON.stringify(full, null, 2) }], details: full });
  const portable = { ...full, length: content.length, text: content }; delete portable.externalContent;
  assert.deepEqual(step.resultPortable, portable);
});

test('identical repeated calls each emit a new request and retain full identical success results', () => {
  const steps = group('repeat-no-local-cache').steps;
  assert.deepEqual(steps.map(step => step.cumulativeRequests), [1, 2, 3]);
  for (const step of steps) {
    assert.deepEqual(step.arguments, steps[0].arguments);
    assert.deepEqual(step.request, steps[0].request);
    assert.deepEqual(step.result, steps[0].result);
    assert.equal('cached' in step.result, false);
  }
});

test('fresh capture equals complete frozen source fixture', () => {
  assert.equal(capture.counts.groups, 47); assert.equal(capture.counts.callbacks, 49);
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});
