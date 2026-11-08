import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { captureDiffsDelivery } from './capture-diffs-delivery.mjs';

const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/diffs-delivery.json', import.meta.url)));
const observed = await captureDiffsDelivery();
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

test('pinned source retains configuration aliases, prefixed viewer URLs and ordered receipts', () => {
  const configs = Object.fromEntries(observed.configs.map(row => [row.id, row.result]));
  assert.equal(configs['source-defaults'].defaults.mode, 'both');
  assert.equal(configs['source-defaults'].defaults.fileFormat, 'png');
  assert.equal(configs['source-defaults'].defaults.ttlSeconds, 1800);
  assert.deepEqual(configs['source-defaults'].security, { allowRemoteViewer: false });
  assert.equal(configs['legacy-aliases'].defaults.fileFormat, 'pdf');
  assert.equal(configs['legacy-aliases'].defaults.fileScale, 2.75);
  assert.equal(configs['file-precedence'].defaults.fileFormat, 'png');
  assert.equal(configs['file-precedence'].defaults.fileQuality, 'print');
  assert.equal(configs['file-precedence'].defaults.fileMaxWidth, 1500);
  assert.equal(configs['presentation-and-url'].viewerBaseUrl, 'https://diff.example.test/prefix');
  assert.ok(observed.urls[0].result.startsWith('https://request.example.test/base/plugins/diffs/view/'));
  assert.ok(observed.urls[1].result.startsWith('https://configured.example.test/other/plugins/diffs/view/'));
  for (const { id, input, result } of observed.receipts) {
    assert.equal(result.details.mode, id);
    assert.equal(result.details.changed, true);
    assert.equal(result.content.length, 1);
    assert.equal(result.content[0].type, 'text');
    if (id === 'view') {
      assert.equal(result.content[0].text, 'Diff viewer ready.\n' + input.viewerUrl);
    } else {
      assert.equal(result.details.path, result.details.filePath);
      assert.equal(result.details.fileFormat, input.image.format);
      assert.equal(result.details.fileBytes, 12345);
      assert.equal(result.content[0].text, [
        ...(id === 'both' ? ['Diff viewer: ' + input.viewerUrl] : []),
        `Diff ${input.image.format.toUpperCase()} generated at: ${input.artifactFile.filePath}`,
        'To send this file, use an available file-sending tool to send it as an attachment.',
      ].join('\n'));
    }
  }
});

test('source slices and executable packaging reproduce the frozen ordinary observations', () => {
  const sources = new Map(observed.sourceRecords.map(row => [row.path, row]));
  for (const source of sources.values()) {
    assert.equal(sha(source.content), source.sha256);
    assert.equal(Buffer.byteLength(source.content), source.bytes);
  }
  for (const row of observed.projections) {
    const bytes = Buffer.from(sources.get(row.path).content).subarray(row.startByte, row.endByte);
    assert.equal(bytes.toString(), row.selectedSource);
    assert.equal(sha(bytes), row.sha256);
  }
  for (const row of observed.executables) {
    assert.equal(sha(row.generatedSource), row.sha256);
    assert.equal(stripTypeScriptTypes(row.generatedSource, { mode: 'strip', sourceMap: false }), row.executable);
  }
  assert.deepEqual(observed.boundaries, {
    sourceProjectionsOnly: true, completeFactory: false, renderExecuted: false,
    storageExecuted: false, gatewayFallbackExecuted: false, failuresExecuted: false,
  });
  assert.deepEqual(observed, fixture);
});
