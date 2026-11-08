// Ordinary pinned source construction and metadata checks; never invoke execute.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureSessionFactories } from './capture-session-factories.mjs';
import { representativeContexts } from './capture-recipes.mjs';

const root = process.env.OPENCLAW_SESSION_SOURCE ?? '/tmp/openclaw-488631c';
const hash = value => createHash('sha256').update(value).digest('hex');
const pinned = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const head = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
assert.equal(head.status, 0, head.stderr);
assert.equal(head.stdout.trim(), pinned);
const clean = spawnSync('git', ['-C', root, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' });
assert.equal(clean.status, 0, clean.stderr);
assert.equal(clean.stdout, '');
const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', '488631c18fae7cc541ba8fc8beff6cbb0438787b'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
assert.equal(listing.status, 0, listing.stderr);
const files = listing.stdout.trim().split('\n').filter(path => path.endsWith('.ts'))
  .map(path => ({ path, sha256: hash(readFileSync(join(root, path))) }));
const tracked = new Map(files.map(file => [file.path, file.sha256]));
const rows = await captureSessionFactories(root, files);
const direct = tool => rows.find(row => row.id === `session/${tool}/default`);
let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);

test('constructs all 79 actual session descriptors with exact metadata comparison in fresh VMs', () => {
  assert.equal(rows.length, 79);
  assert.equal(new Set(rows.map(row => row.id)).size, 79);
  for (const row of rows) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.evidence, 'factory-return');
    assert.equal(row.sourceSha256, tracked.get(row.source));
    assert.equal(row.descriptor.name, row.referenceTool);
    assert.equal(row.descriptor.executeObserved, true);
    assert.equal(typeof row.descriptor.displaySummary, 'string');
    assert.equal(row.descriptorMatch, true);
    const { executeObserved, ...metadata } = row.descriptor;
    assert.deepEqual(row.definitionComparison.metadata, metadata);
    assert.equal(row.definitionComparison.kind, 'source-metadata-region');
    assert.equal(row.definitionComparison.freshVm, true);
    assert.equal(row.executeInvoked, false);
    assert.equal(row.definitionComparison.executeInvoked, false);
    assert.deepEqual(row.attemptedCalls, []);
    assert.deepEqual(row.definitionComparison.attemptedCalls, []);
    assert.deepEqual(row.configBindings, []);
    assert.equal(row.typebox.version, '1.3.37');
    assert.equal(row.eligibility.status, 'unresolved');
    assert.equal(row.registration.status, 'unresolved');
    for (const [field, schema] of [['schema', row.descriptor.parameters], ['outputSchema', row.descriptor.outputSchema]]) {
      assert.deepEqual(row[field].parameters, schema);
      assert.deepEqual(JSON.parse(row[field].schemaJson), schema);
      assert.equal(row[field].schemaSha256, hash(row[field].schemaJson));
    }
  }
});

test('ordinary constructor variants preserve source-backed activeOnly and session-link metadata', () => {
  assert.equal(rows.filter(row => !row.representativeContext).length, 7);
  const list = direct('sessions_list');
  assert.ok(list.descriptor.parameters.properties.activeOnly);
  for (const row of rows.filter(row => row.referenceTool === 'sessions_list' && row.args[0].supportsActiveOnly === false)) {
    assert.equal(row.descriptor.parameters.properties.activeOnly, undefined);
    assert.deepEqual(row.descriptor.outputSchema, list.descriptor.outputSchema);
  }
  for (const tool of ['sessions_list', 'sessions_history']) {
    const linked = rows.find(row => row.referenceTool === tool && row.args[0].sessionLinkBase);
    assert.ok(linked.descriptor.description.includes(linked.args[0].sessionLinkBase));
    assert.deepEqual(linked.descriptor.outputSchema, direct(tool).descriptor.outputSchema);
  }
});

test('each session factory receives all 24 recorded representative option contexts', () => {
  for (const tool of ['sessions_list', 'sessions_history', 'session_status']) {
    const contextual = rows.filter(row => row.referenceTool === tool && row.representativeContext);
    assert.equal(contextual.length, 24);
    assert.deepEqual(contextual.map(row => row.representativeContext), representativeContexts());
    for (const row of contextual) {
      assert.deepEqual(row.args, [row.representativeContext.options]);
      assert.deepEqual(row.descriptor, direct(tool).descriptor);
      assert.equal(row.context, `recipe/${row.id}`);
    }
  }
});

test('preserves exact projection source bytes, generated wrappers and transformed executable hashes', () => {
  for (const row of rows) {
    for (const evidence of [row, row.definitionComparison]) {
      for (const file of evidence.loadedFiles) assert.equal(file.sha256, tracked.get(file.path));
      for (const file of evidence.typebox.files) {
        assert.equal(file.sha256, hash(readFileSync(join(typeboxRoot, file.path.slice('typebox/'.length)))));
      }
      for (const projection of evidence.projections) {
        assert.ok(projection.kind.startsWith('session-'));
        assert.equal(projection.sourceSha256, tracked.get(projection.source));
        assert.equal(projection.generatedSha256, hash(projection.generatedCode));
        assert.equal(projection.executableSha256, hash(stripTypeScriptTypes(projection.generatedCode, { mode: 'transform', sourceMap: false })));
        const bytes = readFileSync(join(root, projection.source));
        for (const selection of projection.selections) {
          assert.equal(selection.sha256, hash(bytes.subarray(selection.startByte, selection.endByte)));
        }
      }
    }
    const wrapper = row.projections.find(item => item.kind === 'session-execution-wrapper');
    assert.ok(wrapper.generatedCode.includes('return async (...args) =>'));
    assert.deepEqual(wrapper.deferredBindings, ['withGatewayPersonalToolUser', 'readToolStringParam', 'asNonArrayRecord', 'getGatewayToolCallerIdentity', 'resolveGatewayToolOperatorSelection']);
  }
  const status = direct('session_status');
  assert.ok(status.loadedFiles.some(item => item.path === 'src/shared/lazy-promise.ts'));
  assert.equal(status.executionBoundary.lazyLoaderInvoked, false);
});

test('session metadata capture is deterministic across fresh independent VM runs', async () => {
  assert.deepEqual(await captureSessionFactories(root, files), rows);
});
