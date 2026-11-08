// Batch392: independent ordinary tests frozen before consumer implementation.
// Source oracle: whole pinned callbacks captured by batch361. The provider-success
// vector is deliberately outside this pure direct-document consumer.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { webFetchVectors } from '../../../scripts/openclaw/capture-web-fetch.mjs';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
const fixtureBytes = readFileSync(join(repository,
  'apps/synapsis_agent/test/fixtures/openclaw/488631c/web-fetch.json'));
const oracle = JSON.parse(fixtureBytes);
const referenceCommit = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const dependencyVersions = { '@mozilla/readability': '0.6.0', linkedom: '0.18.13', entities: '8.1.0' };
const runtime = {
  node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
  icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch,
};
const directIds = ['plain', 'markdown', 'markdown-text', 'article', 'article-text', 'json',
  'json-subtype', 'declared-charset', 'bom', 'document-charset', 'final-url', 'repeat-cache'];
const row = id => oracle.groups.find(group => group.id === id);
const bytes = input => input.bytes ? Buffer.from(input.bytes)
  : Buffer.from(input.body, input.encoding ?? 'utf8');

function qualifiedNode() {
  assert.ok(isAbsolute(process.env.SYNAPSIS_FILESYSTEM_NODE), 'existing trusted absolute Node setting');
  assert.equal(realpathSync(process.execPath), realpathSync(process.env.SYNAPSIS_FILESYSTEM_NODE));
  assert.equal(process.versions.node, '24.21.0');
}

// Each independently generated wrapper must contain a consistent start/end ID.
// Replace IDs only; retain all warning prose, delimiters, whitespace and lengths.
function normalizeWrapped(value) {
  const markers = [...value.matchAll(/<<<(?:END_)?EXTERNAL_UNTRUSTED_CONTENT id="([a-f0-9]{16})">>>/g)];
  assert.equal(markers.length, 2);
  assert.ok(markers[0][0].startsWith('<<<EXTERNAL_'));
  assert.ok(markers[1][0].startsWith('<<<END_EXTERNAL_'));
  assert.equal(markers[0][1], markers[1][1]);
  return value.replace(/(<<<(?:END_)?EXTERNAL_UNTRUSTED_CONTENT id=")[a-f0-9]{16}(">>>)/g,
    (_match, opening, closing) => `${opening}3636363636363636${closing}`);
}

function normalizeDocument(document) {
  const normalized = { ...document };
  for (const key of ['text', 'title', 'warning']) {
    if (Object.hasOwn(normalized, key)) normalized[key] = normalizeWrapped(normalized[key]);
  }
  return normalized;
}

function expectedDocument(group) {
  const { fetchedAt: _fetchedAt, tookMs: _tookMs, ...document } = group.results[0].details;
  return document;
}

function request(group, maxChars) {
  return Object.freeze({ protocol: 1, id: `ordinary-${group.id}-${maxChars}`,
    operation: 'readable_document', input: Object.freeze({
      bytes: bytes(group.input).toString('base64'), url: group.args.url,
      finalUrl: group.input.finalUrl ?? group.args.url, status: 200,
      contentType: group.input.contentType, extractMode: group.args.extractMode ?? 'markdown', maxChars,
    }) });
}

async function checkDocument(group, maxChars) {
  qualifiedNode();
  const { prepareReadableDocument } = await import(pathToFileURL(join(repository,
    'apps/synapsis_core/priv/web_fetch/document.mjs')).href);
  assert.equal(typeof prepareReadableDocument, 'function');
  const req = request(group, maxChars);
  const original = JSON.stringify(req);
  const actual = await prepareReadableDocument(req);
  assert.equal(JSON.stringify(req), original, 'immutable request remains unchanged');
  assert.equal(actual.result.length, actual.result.text.length, 'source uses UTF16 code units');
  assert.equal(actual.result.rawLength, group.results[0].details.rawLength);
  assert.deepEqual({ ...actual, result: normalizeDocument(actual.result) }, {
    protocol: 1, id: req.id, referenceCommit, dependencyVersions, runtime,
    result: normalizeDocument(expectedDocument(group)),
  });
}

test('pinned complete source oracle and direct vectors remain unchanged', t => {
  qualifiedNode();
  assert.equal(createHash('sha256').update(fixtureBytes).digest('hex'),
    '2fc7a79709a6d23fe109f21958223dae40d9e7e3f17271bc217e45bab5c4fd08');
  assert.equal(oracle.pin, referenceCommit);
  assert.equal(oracle.groups.length, 13);
  assert.equal(oracle.groups.reduce((count, group) => count + group.results.length, 0), 14);
  assert.deepEqual(oracle.groups.map(group => group.input), webFetchVectors());
  assert.deepEqual(oracle.groups.filter(group => group.id !== 'provider-success').map(group => group.id), directIds);
  assert.equal(row('provider-success').results[0].details.extractor, 'fixture-provider');
  t.diagnostic(JSON.stringify({ nodeExecutable: realpathSync(process.execPath), runtime }));
});

for (const id of directIds) {
  test(`packaged immutable document matches the entire direct source vector: ${id}`, async () => {
    await checkDocument(row(id), 20_000);
  });
}

test('ordinary nondefault maxChars8192 retains complete HTML, title, Markdown and exact JSON', async () => {
  // Pinned web-fetch.ts:279-306,441-486: these short vectors fit in full,
  // including title and warning framing, so an 8192 budget changes no field.
  // This is ordinary control propagation, with no threshold/truncation claim.
  for (const id of ['plain', 'article', 'article-text', 'markdown-text', 'json'])
    await checkDocument(row(id), 8192);
});
