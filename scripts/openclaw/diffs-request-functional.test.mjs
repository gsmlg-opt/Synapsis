// Literal expectations are independent of the generated JSON fixture.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { captureDiffsRequest, DIFFS_REQUEST_PIN } from './capture-diffs-request.mjs';

const root = process.env.OPENCLAW_REFERENCE_ROOT ?? '/tmp/openclaw-488631c';
const report = await captureDiffsRequest(root);
const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/diffs-request.json', import.meta.url), 'utf8'));
const sha = value => createHash('sha256').update(value).digest('hex');
const byId = id => {
  const row = report.vectors.find(row => row.id === id);
  assert.ok(row, id);
  return row.result;
};
const defaults = {
  fontFamily: 'Fira Code', fontSize: 15, lineSpacing: 1.6, layout: 'unified',
  showLineNumbers: true, diffIndicators: 'bars', wordWrap: true, background: true,
  theme: 'dark', fileFormat: 'png', fileQuality: 'standard', fileScale: 2,
  fileMaxWidth: 960, mode: 'both', ttlSeconds: 1800,
};
const standard = { format: 'png', qualityPreset: 'standard', scale: 2, maxWidth: 960, maxPixels: 8000000 };

test('unchanged shortcut preserves the SDK text result and normalized context', () => {
  const content = [{ type: 'text', text: 'Before and after are identical — no changes to render.' }];
  assert.deepEqual(byId('equal-empty'), { content, details: { changed: false } });
  assert.deepEqual(byId('equal-unicode-context'), {
    content, details: { changed: false, context: { agentId: 'agent-1', sessionId: 'session-1' } },
  });
});

test('ordinary before/after and patch plans preserve exact input normalization', () => {
  assert.deepEqual(byId('before-after-defaults'), {
    input: { kind: 'before_after', before: 'old\n', after: 'new\n' },
    options: { presentation: defaults, image: standard, expandUnchanged: false },
    renderTarget: 'both', mode: 'both', ttlMs: 1800000,
  });
  assert.deepEqual(byId('empty-optionals'), byId('before-after-defaults'));
  assert.deepEqual(byId('patch-title-empty').input, {
    kind: 'patch', patch: '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b', title: '',
  });
  assert.deepEqual(byId('patch-title-omitted').input, { kind: 'patch', patch: '@@ -1 +1 @@\n-旧\n+新' });
  assert.deepEqual(byId('unicode-trim-labels').input, {
    kind: 'before_after', before: '😀 e\u0301\r\n', after: '鍵 é\n', path: 'src/鍵.ts',
    lang: 'typescript', title: '\u0085Title\u0085',
  });
  assert.deepEqual(byId('unicode-trim-labels').context, {
    agentId: 'agent', sessionId: 'session', messageChannel: 'web', agentAccountId: 'account',
  });
  assert.equal(byId('unicode-trim-labels').options.languagePackAvailable, false);
});

test('render targets and presentation use explicit resolved inputs without URL processing', () => {
  const view = byId('view-overrides');
  assert.equal(view.renderTarget, 'viewer');
  assert.equal(view.mode, 'view');
  assert.deepEqual(view.options.presentation, { ...defaults, layout: 'split', theme: 'light' });
  assert.equal(view.options.expandUnchanged, true);
  assert.equal(view.options.languagePackAvailable, true);
  assert.equal(byId('image-alias').renderTarget, 'image');
  assert.equal(byId('image-alias').mode, 'image');
  assert.equal(byId('file-pdf').renderTarget, 'image');
  assert.equal(byId('file-pdf').options.image.format, 'pdf');
  assert.equal(byId('file-pdf').ttlMs, 21600000);
  const custom = byId('resolved-custom-defaults');
  assert.equal(custom.renderTarget, 'viewer');
  assert.deepEqual(custom.options.presentation, {
    fontFamily: 'Custom Mono', fontSize: 17, lineSpacing: 1.75, layout: 'split',
    showLineNumbers: false, diffIndicators: 'classic', wordWrap: false, background: false,
    theme: 'light', fileFormat: 'pdf', fileQuality: 'hq', fileScale: 3.25,
    fileMaxWidth: 1700, mode: 'view', ttlSeconds: 2.3459,
  });
  assert.equal(custom.ttlMs, 2345);
  assert.equal(Object.hasOwn(byId('standard-explicit-overrides'), 'baseUrl'), false);
});

test('quality precedence, binary64 rounding and decimal TTL match independent literals', () => {
  assert.deepEqual(byId('resolved-custom-defaults').options.image, {
    format: 'pdf', qualityPreset: 'hq', scale: 3.25, maxWidth: 1700, maxPixels: 14000000,
  });
  assert.deepEqual(byId('explicit-same-quality-resets').options.image, {
    format: 'png', qualityPreset: 'hq', scale: 2.5, maxWidth: 1200, maxPixels: 14000000,
  });
  assert.deepEqual(byId('print-decimal-overrides').options.image, {
    format: 'png', qualityPreset: 'print', scale: 1, maxWidth: 1201, maxPixels: 24000000,
  });
  assert.equal(byId('print-decimal-overrides').ttlMs, 1234);
  assert.deepEqual(byId('hq-scale-rounding').options.image, {
    format: 'png', qualityPreset: 'hq', scale: 2.35, maxWidth: 999, maxPixels: 14000000,
  });
  assert.equal(byId('hq-scale-rounding').ttlMs, 1001);
  assert.deepEqual(byId('print-profile').options.image, {
    format: 'png', qualityPreset: 'print', scale: 3, maxWidth: 1400, maxPixels: 24000000,
  });
  assert.deepEqual(byId('standard-explicit-overrides').options.image, { ...standard, scale: 4, maxWidth: 2400 });
  assert.equal(byId('standard-explicit-overrides').ttlMs, 1000);
});

test('exact original source slices, executables and allowed bindings retain reproducible provenance', () => {
  assert.equal(report.referenceCommit, DIFFS_REQUEST_PIN);
  assert.equal(report.reference.usedSourceBlobsVerifiedBeforeAndAfter, true);
  assert.equal(report.sourceRecords.length, 16);
  assert.equal(report.projections.length, 12);
  const sources = new Map(report.sourceRecords.map(row => [row.path, row]));
  for (const row of report.sourceRecords) {
    assert.equal(sha(row.content), row.sha256, row.path);
    assert.equal(row.content, readFileSync(root + '/' + row.path, 'utf8'), row.path);
    assert.equal(Buffer.byteLength(row.content), row.bytes);
  }
  for (const row of report.projections) {
    const original = sources.get(row.path);
    assert.equal(row.sourceSha256, original.sha256);
    const bytes = Buffer.from(original.content).subarray(row.startByte, row.endByte);
    assert.equal(bytes.toString(), row.selectedSource, row.id);
    assert.equal(sha(bytes), row.selectedSha256, row.id);
  }
  for (const row of report.executables) {
    assert.equal(sha(row.generatedSource), row.generatedSourceSha256, row.path);
    assert.equal(stripTypeScriptTypes(row.generatedSource, { mode: 'strip', sourceMap: false }), row.executable, row.path);
    assert.equal(sha(row.executable), row.executableSha256, row.path);
    if (row.kind === 'whole-original-module') assert.equal(row.generatedSource, sources.get(row.path).content);
    for (const id of row.projectionIds) assert.ok(report.projections.some(projection => projection.id === id));
  }
  const allowed = new Set(report.executables.map(row => row.path));
  assert.equal(allowed.size, 11);
  for (const row of report.importBindings) {
    assert.ok(allowed.has(row.importer), row.importer);
    assert.ok(allowed.has(row.target), row.target);
    assert.ok(row.specifier === row.target || row.specifier.startsWith('.') || row.specifier === '@openclaw/normalization-core/string-coerce');
  }
  assert.deepEqual(report.nativeBindings, ['Buffer=node:buffer.Buffer']);
  assert.equal(report.unknownImports, 'throw');
  assert.deepEqual(report.boundaries.effects, []);
  assert.deepEqual(report.boundaries.serviceBindings, []);
  assert.equal(report.boundaries.completeFactory, false);
  assert.equal(report.boundaries.fullExecuteCallback, false);
  assert.equal(report.boundaries.renderExecuted, false);
  assert.equal(report.boundaries.sourceProjectionsOnly, true);
  assert.equal(report.exporter.sha256, sha(readFileSync(new URL('./capture-diffs-request.mjs', import.meta.url))));
});

test('regenerated source observations and provenance equal the frozen fixture', () => {
  assert.equal(report.vectors.length, 16);
  assert.deepEqual(report, fixture);
});
