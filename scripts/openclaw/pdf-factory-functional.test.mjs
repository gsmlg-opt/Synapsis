// Ordinary positive construction/metadata only; no PDF execute or readiness calls.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { capturePdfFactories, PDF_FACTORY_SOURCE } from './capture-pdf-factories.mjs';
import { representativeContexts } from './capture-recipes.mjs';

const root = process.env.OPENCLAW_PDF_SOURCE ?? '/tmp/openclaw-488631c';
const hash = value => createHash('sha256').update(value).digest('hex');
const pinned = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const head = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
assert.equal(head.status, 0, head.stderr);
assert.equal(head.stdout.trim(), pinned);
const clean = spawnSync('git', ['-C', root, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' });
assert.equal(clean.status, 0, clean.stderr);
assert.equal(clean.stdout, '');
const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', pinned], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
assert.equal(listing.status, 0, listing.stderr);
const files = listing.stdout.trim().split('\n').filter(path => path.endsWith('.ts'))
  .map(path => ({ path, sha256: hash(readFileSync(join(root, path))) }));
const tracked = new Map(files.map(file => [file.path, file.sha256]));
const rows = await capturePdfFactories(root, files);
const direct = rows.find(row => row.id === 'pdf/factory/default');
let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);

// Independently enumerate the ordinary constructor inputs, without reusing recipes.
function expectedInputs() {
  const expected = new Map([
    ['pdf/factory/default', { agentDir: '/reference/agent' }],
    ['pdf/factory/configured-defaults', { agentDir: '/reference/agent', config: { agents: { defaults: { pdfMaxMb: 24, pdfMaxPages: 32 } } } }],
  ]);
  for (const role of ['primary', 'child', 'scheduled']) for (const profile of ['minimal', 'coding', 'messaging', 'full']) for (const configured of [false, true]) {
    expected.set(`pdf/factory/context/${role}/${profile}/${configured ? 'configured' : 'unconfigured'}`, {
      config: { tools: { profile }, plugins: { enabled: configured }, browser: { enabled: configured } },
      agentSessionKey: role === 'child' ? 'agent:reference:subagent:fixture' : role === 'scheduled' ? 'agent:reference:cron:fixture' : 'agent:reference:main',
      sessionKey: 'agent:reference:main', agentId: 'reference', workspaceDir: '/reference/workspace',
      isSubagent: role === 'child', sandboxed: role === 'child', isScheduled: role === 'scheduled',
      modelSupportsVision: configured, hasConnectedClient: configured, allowDeviceTools: configured, agentDir: '/reference/agent',
    });
  }
  return expected;
}

test('constructs all 26 actual PDF descriptors using the independent ordinary input matrix', () => {
  assert.equal(rows.length, 26);
  assert.deepEqual(new Map(rows.map(row => [row.id, row.args[0]])), expectedInputs());
  for (const row of rows) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.source, PDF_FACTORY_SOURCE);
    assert.equal(row.sourceSha256, tracked.get(PDF_FACTORY_SOURCE));
    assert.equal(row.export, 'createPdfTool');
    assert.equal(row.evidence, 'factory-return');
    assert.equal(row.context, `recipe/${row.id}`);
    assert.equal(row.descriptor.name, 'pdf');
    assert.equal(row.descriptor.label, 'PDF');
    assert.equal(row.descriptor.executeObserved, true);
    assert.deepEqual(row.descriptor, direct.descriptor);
    assert.equal(row.eligibility.status, 'unresolved');
    assert.equal(row.registration.status, 'unresolved');
  }
  assert.deepEqual(rows.filter(row => row.representativeContext).map(row => row.representativeContext), representativeContexts());
});

test('fresh independent metadata regions reproduce the complete PDF input schema and descriptor', () => {
  for (const row of rows) {
    const comparison = row.definitionComparison;
    assert.equal(row.descriptorMatch, true);
    assert.equal(comparison.freshVm, true);
    assert.equal(comparison.kind, 'source-metadata-region');
    assert.equal(comparison.syntheticExport, 'captureMetadata');
    assert.equal(comparison.sourceSha256, tracked.get(PDF_FACTORY_SOURCE));
    assert.deepEqual(comparison.args, row.args);
    const { executeObserved, ...metadata } = row.descriptor;
    assert.deepEqual(comparison.metadata, metadata);
    assert.deepEqual(Object.keys(metadata).sort(), ['description', 'label', 'name', 'parameters']);
    assert.deepEqual(Object.keys(metadata.parameters.properties).sort(), ['maxBytesMb', 'model', 'pages', 'password', 'pdf', 'pdfs', 'prompt']);
    assert.deepEqual(row.schema.parameters, metadata.parameters);
    assert.deepEqual(JSON.parse(row.schema.schemaJson), metadata.parameters);
    assert.equal(row.schema.schemaSha256, hash(row.schema.schemaJson));
    assert.deepEqual(row.schema.actions, []);
    assert.equal(row.schema.actionlessBranches, 1);
    assert.deepEqual(comparison.projections.map(item => item.kind), ['pdf-metadata-region']);
    assert.deepEqual(comparison.projections[0].selections.map(item => [item.startLine, item.endLine]), [[78, 94], [145, 146], [557, 560]]);
    assert.deepEqual(comparison.stubs, []);
  }
});

test('uses actual pure configuration helpers while retaining deferred execution and readiness boundaries', () => {
  for (const row of rows) {
    assert.equal(row.executeInvoked, false);
    assert.deepEqual(row.executionBoundary, { toolExecuteInvoked: false, pdfExecutionInvoked: false,
      resourceAcquisitionInvoked: false, modelReadinessInvoked: false, authInvoked: false, dynamicImportsInvoked: false });
    assert.equal(row.limits.constructorCases, 'agentDir-present; no explicit pdfModel/imageModel');
    const helpers = row.projections.filter(item => item.kind === 'pdf-pure-helper');
    assert.equal(helpers.length, 6);
    const pdf = helpers.find(item => item.specifier === './pdf-tool.helpers.js');
    assert.deepEqual(pdf.pureExports, ['coercePdfModelConfig']);
    assert.deepEqual(pdf.selections.map(item => [item.startLine, item.endLine]), [[84, 95]]);
    const image = helpers.find(item => item.specifier === './image-tool.helpers.js');
    assert.deepEqual(image.pureExports, ['coerceImageModelConfig']);
    assert.deepEqual(image.selections.map(item => [item.startLine, item.endLine]), [[108, 110]]);
    const model = helpers.find(item => item.importer === PDF_FACTORY_SOURCE && item.specifier === './model-config.helpers.js');
    assert.deepEqual(model.pureExports, ['hasToolModelConfig', 'coerceToolModelConfig']);
    assert.deepEqual(model.selections.map(item => [item.startLine, item.endLine]), [[62, 66], [403, 412]]);
    assert.equal(row.stubs.length, 24);
    for (const evidence of [row, row.definitionComparison]) {
      assert.equal(evidence.executeInvoked ?? false, false);
      assert.deepEqual(evidence.attemptedCalls, []);
      assert.deepEqual(evidence.configBindings, []);
      assert.equal(evidence.typebox.version, '1.3.37');
    }
  }
});

test('records exact source byte selections, generated wrappers, transformed executables and TypeBox provenance', () => {
  for (const row of rows) for (const evidence of [row, row.definitionComparison]) {
    for (const file of evidence.loadedFiles) assert.equal(file.sha256, tracked.get(file.path));
    for (const file of evidence.typebox.files) assert.equal(file.sha256, hash(readFileSync(join(typeboxRoot, file.path.slice('typebox/'.length)))));
    for (const projection of evidence.projections) {
      const bytes = readFileSync(join(root, projection.source));
      assert.equal(projection.sourceSha256, hash(bytes));
      assert.equal(projection.generatedSha256, hash(projection.generatedCode));
      assert.equal(projection.executableSha256, hash(stripTypeScriptTypes(projection.generatedCode, { mode: 'transform', sourceMap: false })));
      for (const selection of projection.selections) {
        const selected = bytes.subarray(selection.startByte, selection.endByte);
        const lines = bytes.toString().split(/(?<=\n)/);
        assert.equal(selection.startByte, Buffer.byteLength(lines.slice(0, selection.startLine - 1).join('')));
        assert.equal(selected.toString(), lines.slice(selection.startLine - 1, selection.endLine).join(''));
        assert.equal(selection.sha256, hash(selected));
        assert.ok(projection.generatedCode.includes(selected.toString()));
      }
    }
  }
});

test('PDF constructor metadata is deterministic across fresh independent VM captures', async () => {
  assert.deepEqual(await capturePdfFactories(root, files), rows);
});
