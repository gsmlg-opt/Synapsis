// Ordinary positive reference behavior only; no Synapsis consumer is imported.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import { captureWebFetch, WEB_FETCH_PIN } from './capture-web-fetch.mjs';

const root = process.env.OPENCLAW_WEB_FETCH_SOURCE ?? '/tmp/openclaw-488631c';
const runtime = process.env.OPENCLAW_WEB_FETCH_DEPENDENCIES ?? '/tmp/synapsis-webfetch361-evidence/reference-runtime';
const capture = await captureWebFetch(root, runtime);
const group = id => { const row = capture.groups.find(row => row.id === id); assert.ok(row, id); return row; };
const details = id => group(id).results[0].details;
const digest = value => createHash('sha256').update(value).digest('hex');
// Ordinary source payload inside its original exact framing; no prose trimming.
const body = text => {
  const match = /<<<EXTERNAL_UNTRUSTED_CONTENT id="([a-f0-9]{16})">>>\nSource: Web Fetch\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match); return match[2];
};
const text = id => body(details(id).text);

test('whole pinned modules and actual extraction packages have exact byte provenance', () => {
  assert.equal(capture.pin, WEB_FETCH_PIN);
  assert.equal(capture.runtime, 'v24.22.1');
  for (const name of ['wholeFactory', 'actualReadability', 'actualCharsetDecoder', 'actualExactJsonBranch', 'actualSuccessCache'])
    assert.equal(capture.boundaries[name], true, name);
  assert.equal(capture.boundaries.syntheticAcquisition, true);
  for (const path of ['src/agents/tools/web-fetch.ts', 'src/agents/tools/web-shared.ts',
    'src/agents/tools/web-fetch-utils.ts', 'src/web-fetch/content-extractors.runtime.ts',
    'extensions/web-readability/web-content-extractor.ts', 'src/agents/tools/common.ts',
    'src/agents/tools/tool-results.ts', 'packages/normalization-core/src/response-bytes.ts',
    'packages/normalization-core/src/text-decoding.ts']) assert.ok(capture.sources.find(row => row.path === path), path);
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(digest(bytes), row.sourceSha256);
    assert.equal(digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256);
    assert.equal(row.wholeModule, true);
  }
  assert.deepEqual(Object.fromEntries(capture.packages.map(row => [row.name, row.version])),
    { entities: '8.1.0', typebox: '1.3.37', '@mozilla/readability': '0.6.0', linkedom: '0.18.13' });
  for (const row of capture.packages) {
    const packageRoot = row.name === 'typebox' ? '/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox'
      : join(runtime, 'node_modules', row.name);
    assert.ok(row.files.length > 10);
    for (const file of row.files) assert.equal(digest(readFileSync(join(packageRoot, file.path))), file.sha256);
  }
  for (const row of capture.facades) assert.equal(digest(row.code), row.sha256);
  for (const row of [capture.referenceManifest, capture.license]) assert.equal(digest(readFileSync(join(root, row.path))), row.sha256);
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-web-fetch.mjs', import.meta.url))));
});

test('actual factory declares extraction controls and returns exact JSON result content', () => {
  const row = group('plain'), schema = row.descriptor.parameters;
  assert.equal(row.descriptor.name, 'web_fetch');
  assert.deepEqual(Object.keys(schema.properties), ['url', 'extractMode', 'maxChars']);
  assert.deepEqual(schema.required, ['url']);
  assert.deepEqual(schema.properties.extractMode.enum, ['markdown', 'text']);
  assert.equal(schema.properties.extractMode.default, 'markdown');
  for (const row of capture.groups) for (const result of row.results)
    assert.deepEqual(result.content, [{ type: 'text', text: JSON.stringify(result.details, null, 2) }]);
  assert.equal(text('plain'), 'Ordinary café 😀.\n');
  assert.equal(details('plain').rawLength, 18);
  assert.equal(details('plain').extractor, 'raw');
});

test('Markdown passthrough and ordinary text conversion preserve intended content', () => {
  assert.equal(text('markdown'), '# A page\n\nAn ordinary [link](https://links.example/page) and `code`.\n\n- First\n- Second\n');
  assert.equal(text('markdown-text'), 'A page\n\nAn ordinary link and code.\n\nFirst\nSecond');
  assert.equal(details('markdown').extractor, 'cf-markdown');
  assert.equal(details('markdown-text').extractMode, 'text');
});

test('actual Readability and DOM extract the article with title in Markdown and text', () => {
  const paragraph = 'The observatory records the changing sky each evening. Its observers compare careful measurements with earlier records, discuss the results, and publish a clear account for other readers. ';
  assert.equal(text('article'), paragraph.repeat(4).trimEnd()
    + '\nThe next observation includes [published records](https://links.example/records).');
  assert.equal(text('article-text'), paragraph.repeat(4)
    + 'The next observation includes published records.');
  for (const id of ['article', 'article-text']) {
    assert.equal(details(id).extractor, 'readability');
    assert.equal(body(details(id).title), 'Observatory journal');
    assert.equal(details(id).rawLength, text(id).length);
  }
});

test('JSON and +json preserve original large integer, decimal, exponent and signed zero tokens', () => {
  assert.equal(text('json'), '{\n  "integer": 9007199254740993,\n  "decimal": 1.2300,\n  "exponent": 1e+30,\n  "zero": -0\n}');
  assert.equal(text('json-subtype'), '{\n  "n": 123456789012345678901234567890,\n  "items": [\n    1e-40,\n    2.00\n  ]\n}');
  assert.equal(details('json').extractor, 'json');
  assert.equal(details('json-subtype').contentType, 'application/ld+json');
});

test('whole response decoder handles declared Windows1252, UTF16 BOM and HTML meta charset', () => {
  assert.equal(text('declared-charset'), 'Café €');
  assert.equal(text('bom'), 'Café');
  assert.equal(body(details('document-charset').title), 'Café journal');
  assert.equal(details('document-charset').extractor, 'readability');
  const paragraph = 'The observatory records the changing sky each evening. Its observers compare careful measurements with earlier records, discuss the results, and publish a clear account for other readers. ';
  assert.equal(text('document-charset'), paragraph.repeat(4) + 'Café.');
});

test('guard-reported final URL and metadata survive full callback with ordinary release', () => {
  const row = group('final-url'), result = details(row.id);
  assert.equal(result.url, 'https://source.example/final-url');
  assert.equal(result.finalUrl, 'https://destination.example/final?q=page');
  assert.equal(text(row.id), 'Destination content.');
  assert.equal(result.status, 200);
  assert.equal(result.fetchedAt, '2026-11-08T04:00:00.187Z');
  assert.equal(result.tookMs, 7);
  assert.equal(result.length, result.text.length);
  assert.deepEqual(row.audit, [{ kind: 'release', id: 'final-url' }]);
  assert.equal(row.requests.length, 1);
  assert.equal(row.requests[0].init.headers.Accept, 'text/markdown, text/html;q=0.9, */*;q=0.1');
});

test('actual success cache returns original content and timing without a second acquisition', () => {
  const row = group('repeat-cache'), [first, second] = row.results.map(row => row.details);
  assert.equal(row.requests.length, 1);
  assert.equal(first.cached, undefined);
  assert.deepEqual(second, { ...first, cached: true });
  assert.equal(text(row.id), 'Cached original body.');
  assert.deepEqual(row.audit, [{ kind: 'release', id: 'repeat-cache' }]);
});

test('successful configured provider branch preserves provider result metadata', () => {
  const row = group('provider-success'), result = details(row.id);
  assert.equal(result.finalUrl, 'https://rendered.example/page');
  assert.equal(result.extractor, 'fixture-provider');
  assert.equal(body(result.title), 'Rendered page');
  assert.equal(text(row.id), 'Ordinary provider content.');
  assert.equal(result.fetchedAt, '2026-11-08T04:00:00.000Z');
  assert.equal(result.tookMs, 12);
  assert.deepEqual(row.audit, [{ kind: 'provider', args: { url: row.args.url, extractMode: 'markdown', maxChars: 20000 } },
    { kind: 'release', id: row.id }]);
});

test('committed source fixture matches the complete repeated ordinary capture', () => {
  const fixture = process.env.OPENCLAW_WEB_FETCH_FIXTURE
    ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/web-fetch.json', import.meta.url);
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});
