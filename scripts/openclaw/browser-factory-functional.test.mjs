// Ordinary construction/metadata checks against the locally available pinned source.
// No tool execution, registration, transport, or runtime admission is exercised.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = process.env.OPENCLAW_BROWSER_SOURCE ?? '/tmp/openclaw-488631c';
const moduleUrl = process.env.OPENCLAW_CAPTURE_RECIPES
  ? pathToFileURL(process.env.OPENCLAW_CAPTURE_RECIPES)
  : new URL('./capture-recipes.mjs', import.meta.url);
const { captureRecipes } = await import(moduleUrl.href);
const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', 'HEAD'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
assert.equal(listing.status, 0, listing.stderr);
const files = listing.stdout.trim().split('\n').filter(path => /^(extensions\/(browser|canvas|llm-task|voice-call)\/src\/|src\/agents\/schema\/|src\/infra\/outbound\/|packages\/normalization-core\/src\/)/.test(path) && path.endsWith('.ts'))
  .map(path => ({ path, sha256: createHash('sha256').update(readFileSync(join(root, path))).digest('hex') }));
const rows = await captureRecipes(root, files);
const browserFactoryRows = rows.filter(row => row.referenceTool === 'browser' && row.evidence === 'factory-return');
const byId = id => rows.find(row => row.id === id);

test('captures the actual pinned Browser factory and independently invoked definition metadata', () => {
  const row = byId('browser/factory');
  assert.equal(row.status, 'captured', row.reason);
  assert.equal(row.export, 'createBrowserTool');
  assert.equal(row.descriptorMatch, true);
  assert.equal(row.definitionComparison.freshVm, true);
  assert.equal(row.definitionComparison.export, 'createBrowserToolDefinition');
  assert.equal(row.definitionComparison.selector, 'metadata');
  assert.equal(row.definitionComparison.configReaderCalls, 1);
  assert.equal(row.descriptor.name, 'browser');
  assert.equal(row.descriptor.executeObserved, true);
  const { executeObserved, ...metadata } = row.descriptor;
  assert.deepEqual(row.definitionComparison.metadata, metadata);
  assert.equal(row.descriptor.outputSchema.type, 'object');
  assert.equal(row.descriptor.outputSchema.properties.ok.type, 'boolean');
  assert.equal(row.descriptor.outputSchema.properties.snapshot.type, 'string');
  assert.equal(row.descriptor.outputSchema.properties.targetId.type, 'string');
  assert.deepEqual(JSON.parse(row.outputSchema.schemaJson), row.descriptor.outputSchema);
  assert.equal(row.outputSchema.schemaSha256, createHash('sha256').update(row.outputSchema.schemaJson).digest('hex'));
});

test('actual factory descriptors agree with all eight independently captured schema variants', () => {
  const schemaRows = rows.filter(row => row.id.startsWith('browser/schema/'));
  const factoryRows = browserFactoryRows.filter(row => row.schemaRecipe);
  assert.equal(schemaRows.length, 8);
  assert.equal(factoryRows.length, 8);
  for (const row of factoryRows) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.descriptorMatch, true);
    assert.deepEqual(row.schema.parameters, byId(row.schemaRecipe).schema.parameters);
    assert.deepEqual(row.capabilities, byId(row.schemaRecipe).capabilities);
    assert.deepEqual(row.schema.actions, row.capabilities.actions.toSorted());
    assert.deepEqual(row.schema.parameters.properties.kind.enum, row.capabilities.actKinds);
    assert.equal(row.capabilityInput.evidence, 'supplied-capabilities; no host config/profile resolution');
    assert.equal(row.configBindings[0].calls, 1);
  }
});

test('constructs default metadata across all 24 representative contexts with the SDK config bound to context input', () => {
  const contextual = browserFactoryRows.filter(row => row.representativeContext);
  assert.equal(contextual.length, 24);
  assert.equal(new Set(contextual.map(row => row.representativeContext.id)).size, 24);
  const descriptor = byId('browser/factory').descriptor;
  for (const row of contextual) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.descriptorMatch, true);
    assert.deepEqual(row.descriptor, descriptor);
    assert.deepEqual(row.configBindings[0].input, row.args[0].config);
    assert.equal(row.configBindings[0].inputSource, 'representativeContext.options.config');
    assert.equal(row.configBindings[0].sourceImplementation, 'not-executed');
    assert.equal(row.configBindings[0].calls, 1);
    assert.equal(row.eligibility.status, 'unresolved');
    assert.equal(row.registration.status, 'unresolved');
  }
});

test('preserves source-backed normalization and engine capability provenance for actual factory construction', () => {
  const row = byId('browser/factory/tab-bound');
  assert.ok(row, 'tab-bound factory recipe is present');
  assert.equal(row.status, 'captured', row.reason);
  const projection = row.projections.find(item => item.source === 'packages/normalization-core/src/string-coerce.ts');
  assert.deepEqual(projection.exports, ['normalizeOptionalString']);
  assert.equal(projection.kind, 'whole-module-export');
  assert.equal(projection.generatedSha256, createHash('sha256').update(projection.generatedCode).digest('hex'));
  assert.ok(row.loadedFiles.some(item => item.path === projection.source && item.sha256 === projection.sourceSha256));
  for (const variant of ['existing-session', 'existing-session-tab-bound', 'lightpanda', 'lightpanda-tab-bound']) {
    const factory = byId(`browser/factory/${variant}`);
    assert.equal(factory.status, 'captured', factory.reason);
    assert.ok(factory.projections.some(item => item.selection?.kind === 'complete-object-method'));
  }
  for (const factory of browserFactoryRows) {
    assert.equal(factory.executeInvoked, false);
    assert.deepEqual(factory.attemptedCalls, []);
    assert.equal(factory.typebox.version, '1.3.37');
    assert.equal(factory.definitionComparison.executeInvoked, false);
    assert.deepEqual(factory.definitionComparison.attemptedCalls, []);
  }
});

test('pinned Browser recipe capture is deterministic across fresh VMs', async () => {
  const second = await captureRecipes(root, files);
  assert.deepEqual(second.filter(row => row.referenceTool === 'browser'), rows.filter(row => row.referenceTool === 'browser'));
});

test('full pinned capture verifies source/config provenance while retaining unresolved assembly gaps', () => {
  const out = join(mkdtempSync(join(tmpdir(), 'browser-actual-factory-')), 'capture');
  const script = fileURLToPath(new URL('./capture-contracts.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [script, '--source', root, '--pin', '488631c18fae7cc541ba8fc8beff6cbb0438787b', '--out', out, '--offline'],
    { encoding: 'utf8', timeout: 240000, maxBuffer: 64 * 1024 * 1024 });
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(out, 'capture.json'), 'utf8'));
  assert.equal(report.recipes.filter(row => row.referenceTool === 'browser' && row.evidence === 'factory-return' && row.status === 'captured').length, 36);
  const verifier = fileURLToPath(new URL('./verify-baseline.py', import.meta.url));
  const manifest = fileURLToPath(new URL('../../docs/superpowers/specs/2026-10-23-openclaw-tool-alignment-baseline.json', import.meta.url));
  const verification = spawnSync('python3', [verifier, '--manifest', manifest, '--fixtures', out], { encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024 });
  assert.equal(verification.status, 2, verification.stderr);
  const verified = JSON.parse(verification.stdout);
  assert.equal(verified.inventoryVerified, true);
  assert.equal(verified.complete, false);
  assert.ok(verified.gaps.some(gap => gap.kind === 'unresolved-assembly-context'));
  console.log(`Browser actual factory artifact: ${out}`);
});
