// Ordinary metadata checks only: no full plugin registration or tool execution.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = process.env.OPENCLAW_BROWSER_SOURCE ?? '/tmp/openclaw-488631c';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', 'HEAD'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
assert.equal(listing.status, 0, listing.stderr);
const commit = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
assert.equal(commit.status, 0, commit.stderr);
assert.equal(commit.stdout.trim(), '488631c18fae7cc541ba8fc8beff6cbb0438787b', 'source checkout is the pinned Browser version');
const files = listing.stdout.trim().split('\n').filter(path => /^(extensions\/browser\/|src\/agents\/schema\/|src\/infra\/outbound\/|packages\/normalization-core\/src\/)/.test(path) && path.endsWith('.ts'))
  .map(path => ({ path, sha256: hash(readFileSync(join(root, path))) }));
let first;
async function capture() {
  const module = await import('./capture-browser-registration.mjs').catch(error => {
    if (error.code === 'ERR_MODULE_NOT_FOUND' && error.url === new URL('./capture-browser-registration.mjs', import.meta.url).href) return {};
    throw error;
  });
  assert.equal(typeof module.captureBrowserRegistrations, 'function', 'ordinary Browser registration metadata capture API is available');
  first ??= module.captureBrowserRegistrations(root, files);
  return first;
}

test('captures the actual registerTool callback across 24 representative contexts', async () => {
  const rows = await capture();
  const contexts = rows.filter(row => row.representativeContext);
  assert.equal(contexts.length, 24);
  assert.equal(new Set(contexts.map(row => row.representativeContext.id)).size, 24);
  for (const row of rows) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.evidence, 'projected-registerTool-callback');
    assert.deepEqual(row.registration.options, { name: 'browser', workspaceAccess: false });
    assert.equal(row.registration.registerToolCalls, 1);
    assert.equal(row.registration.callbackInvoked, true);
    assert.equal(row.registration.fullPluginRegistrationInvoked, false);
    assert.equal(row.descriptorMatch, true);
    assert.equal(row.definitionComparison.freshVm, true);
    const { executeObserved, ...metadata } = row.descriptor;
    assert.equal(executeObserved, true);
    assert.deepEqual(row.definitionComparison.metadata, metadata);
    assert.equal(row.outputSchema.schemaSha256, hash(row.outputSchema.schemaJson));
    assert.deepEqual(JSON.parse(row.outputSchema.schemaJson), row.descriptor.outputSchema);
    assert.equal(row.executeInvoked, false);
    assert.deepEqual(row.attemptedCalls, []);
    assert.equal(row.definitionComparison.executeInvoked, false);
    assert.deepEqual(row.definitionComparison.attemptedCalls, []);
  }
});

test('ordinary config precedence selects the actual callback config and records calls', async () => {
  const rows = await capture();
  const cases = [
    ['getter-first', 'ctx.getRuntimeConfig()', 1, false],
    ['getter-undefined-runtime', 'ctx.runtimeConfig', 1, false],
    ['runtime-first', 'ctx.runtimeConfig', 0, false],
    ['config-fallback', 'ctx.config', 0, false],
    ['getter-empty-object', 'ctx.getRuntimeConfig()', 1, true],
  ];
  for (const [id, origin, calls, evaluate] of cases) {
    const row = rows.find(row => row.id === `browser/registration/config/${id}`);
    assert.ok(row, id);
    assert.equal(row.status, 'captured', row.reason);
    assert.equal(row.configSelection.origin, origin);
    assert.equal(row.configSelection.getterCalls, calls);
    assert.equal(row.configSelection.definitionReaderCalls, 1);
    assert.equal(row.schema.parameters.properties.kind.enum.includes('evaluate'), evaluate);
    assert.deepEqual(row.configSelection.input, row.definitionComparison.configInput.input);
    assert.equal(row.definitionComparison.configInput.calls, 1);
  }
});

test('unchanged options helpers project normal activeModel and media context values', async () => {
  const rows = await capture();
  for (const type of ['direct', 'group', 'channel', 'dm']) {
    const row = rows.find(row => row.id === `browser/registration/media/${type}`);
    assert.equal(row.status, 'captured', row.reason);
    assert.deepEqual(row.options.activeModel, { provider: 'reference-provider', model: 'reference-model' });
    assert.equal(row.options.workspaceDir, '/reference/workspace');
    assert.equal(row.options.agentDir, '/reference/agent');
    assert.equal(row.options.agentId, 'reference');
    assert.equal(row.options.mediaScope.channel, 'delivery-channel');
    assert.equal(row.options.mediaScope.chatType, type === 'dm' ? 'direct' : type);
    assert.equal(row.options.mediaScope.sessionKey, row.input.context.sessionKey);
  }
});

test('normal node-tab bindings reach the real definition and produce matching bound metadata', async () => {
  const rows = await capture();
  for (const variant of ['node-tab', 'node-tab-evaluate-disabled']) {
    const row = rows.find(row => row.id === `browser/registration/binding/${variant}`);
    assert.equal(row.status, 'captured', row.reason);
    assert.deepEqual(row.options.runToolBinding, row.input.context.toolBindings.browser);
    assert.equal(row.definitionComparison.capabilities.tabBound, true);
    assert.equal(row.definitionComparison.binding.target, 'node');
    assert.deepEqual(row.schema.parameters.properties.action.enum, row.definitionComparison.capabilities.actions);
    assert.equal(row.schema.parameters.properties.action.enum.includes('tabs'), true);
    assert.equal(row.descriptorMatch, true);
  }
});

test('registration projection preserves four exact source regions and records dependencies', async () => {
  const rows = await capture();
  const original = readFileSync(join(root, 'extensions/browser/plugin-registration.ts'));
  for (const row of rows) {
    const projection = row.projections.find(item => item.kind === 'browser-registration-regions');
    assert.equal(projection.sourceSha256, hash(original));
    assert.deepEqual(projection.selections.map(item => item.name), ['deriveChatTypeFromSessionKey', 'createLazyBrowserTool', 'createBrowserToolOptions', 'api.registerTool']);
    for (const selection of projection.selections) {
      const bytes = original.subarray(selection.startByte, selection.endByte);
      assert.equal(bytes.toString(), selection.selectedCode);
      assert.equal(hash(bytes), selection.sha256);
      assert.ok(projection.generatedCode.includes(selection.selectedCode));
    }
    assert.equal(hash(projection.generatedCode), projection.generatedSha256);
    assert.equal(hash(stripTypeScriptTypes(projection.generatedCode, { mode: 'transform', sourceMap: false })), projection.executableSha256);
    assert.equal(row.typebox.version, '1.3.37');
    for (const evidence of [row, row.definitionComparison]) for (const file of evidence.loadedFiles) assert.equal(file.sha256, hash(readFileSync(join(root, file.path))));
  }
});

test('ordinary callback capture is deterministic and writes a reviewable source snapshot artifact', async () => {
  const rows = await capture();
  const { captureBrowserRegistrations } = await import('./capture-browser-registration.mjs');
  assert.deepEqual(await captureBrowserRegistrations(root, files), rows);
  const out = mkdtempSync(join(tmpdir(), 'browser-registration-capture-'));
  const copied = new Set(['LICENSE']);
  for (const row of rows) for (const evidence of [row, row.definitionComparison]) for (const file of evidence.loadedFiles) copied.add(file.path);
  for (const path of copied) {
    mkdirSync(dirname(join(out, 'sources', path)), { recursive: true });
    writeFileSync(join(out, 'sources', path), readFileSync(join(root, path)));
  }
  writeFileSync(join(out, 'browser-registrations.json'), JSON.stringify({
    referenceCommit: '488631c18fae7cc541ba8fc8beff6cbb0438787b',
    method: 'bounded callback projection only; full plugin registration and runtime admission unexecuted',
    browserRegistrations: rows, sources: [...copied].sort().map(path => ({ path, sha256: hash(readFileSync(join(root, path))) })),
  }, null, 2) + '\n');
  console.log(`Browser registration artifact: ${out}`);
});

test('full pinned capture preserves recipes and verifies ordinary registration provenance', async () => {
  const out = join(mkdtempSync(join(tmpdir(), 'browser-registration-full-')), 'capture');
  const script = fileURLToPath(new URL('./capture-contracts.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [script, '--source', root, '--pin', '488631c18fae7cc541ba8fc8beff6cbb0438787b', '--out', out, '--offline'],
    { encoding: 'utf8', timeout: 240000, maxBuffer: 64 * 1024 * 1024 });
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(out, 'capture.json'), 'utf8'));
  assert.equal(report.browserRegistrations.length, 35);
  assert.deepEqual(report.browserRegistrations, await capture());
  const canonical = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/capture.json', import.meta.url), 'utf8'));
  assert.equal(report.recipes.length, 154);
  assert.equal(report.recipes.filter(row => row.id.startsWith('session/')).length, 79);
  assert.equal(report.recipes.filter(row => row.id.startsWith('pdf/')).length, 26);
  assert.equal(report.recipes.filter(row => !row.id.startsWith('session/') && !row.id.startsWith('pdf/')).length, 49);
  assert.deepEqual(report.recipes, canonical.recipes);
  for (const row of report.browserRegistrations) {
    assert.equal(row.status, 'captured', row.reason);
    assert.equal(row.configSelection.inputSha256, hash(row.configSelection.inputJson));
    for (const evidence of [row, row.definitionComparison]) for (const file of evidence.loadedFiles) {
      assert.equal(hash(readFileSync(join(out, 'sources', file.path))), file.sha256);
      assert.ok(report.source.files.some(source => source.path === file.path && source.sha256 === file.sha256));
    }
  }
  const verifier = fileURLToPath(new URL('./verify-baseline.py', import.meta.url));
  const manifest = fileURLToPath(new URL('../../docs/superpowers/specs/2026-10-23-openclaw-tool-alignment-baseline.json', import.meta.url));
  const verification = spawnSync('python3', [verifier, '--manifest', manifest, '--fixtures', out],
    { encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024 });
  assert.equal(verification.status, 2, verification.stderr);
  const verified = JSON.parse(verification.stdout);
  assert.equal(verified.inventoryVerified, true);
  assert.equal(verified.complete, false);
  assert.ok(verified.gaps.some(gap => gap.kind === 'unresolved-assembly-context'));
  assert.ok(verified.gaps.some(gap => gap.kind === 'unresolved-registration' && gap.source === 'extensions/browser/plugin-registration.ts'));
  console.log(`Browser registration full artifact: ${out}`);
});
