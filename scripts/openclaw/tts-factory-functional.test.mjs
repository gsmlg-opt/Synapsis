// Ordinary positive construction and metadata only; never invoke the returned tool.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureTtsFactories, TTS_FACTORY_SOURCE } from './capture-tts-factories.mjs';
import { representativeContexts } from './capture-recipes.mjs';

const root = process.env.OPENCLAW_TTS_SOURCE ?? '/tmp/openclaw-488631c';
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
const rows = await captureTtsFactories(root, files);
const direct = rows.find(row => row.id === 'tts/factory/default');
let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);

// Independently enumerate all arguments, preserving no argument versus an empty object.
function expectedInputs() {
  const expected = new Map([
    ['tts/factory/default', []],
    ['tts/factory/empty-options', [{}]],
    ['tts/factory/agent-options', [{ config: { messages: { tts: { auto: 'always' } } },
      agentChannel: 'telegram', agentId: 'reference', agentAccountId: 'reference-account' }]],
  ]);
  for (const role of ['primary', 'child', 'scheduled']) for (const profile of ['minimal', 'coding', 'messaging', 'full']) for (const configured of [false, true]) {
    expected.set(`tts/factory/context/${role}/${profile}/${configured ? 'configured' : 'unconfigured'}`, [{
      config: { tools: { profile }, plugins: { enabled: configured }, browser: { enabled: configured } },
      agentSessionKey: role === 'child' ? 'agent:reference:subagent:fixture' : role === 'scheduled' ? 'agent:reference:cron:fixture' : 'agent:reference:main',
      sessionKey: 'agent:reference:main', agentId: 'reference', workspaceDir: '/reference/workspace',
      isSubagent: role === 'child', sandboxed: role === 'child', isScheduled: role === 'scheduled',
      modelSupportsVision: configured, hasConnectedClient: configured, allowDeviceTools: configured,
    }]);
  }
  return expected;
}

test('constructs all 27 complete TTS descriptors using the independent ordinary argument matrix', () => {
  assert.equal(rows.length, 27);
  assert.deepEqual(new Map(rows.map(row => [row.id, row.args])), expectedInputs());
  for (const row of rows) {
    assert.equal(row.status, 'captured', `${row.id}: ${row.reason}`);
    assert.equal(row.source, TTS_FACTORY_SOURCE);
    assert.equal(row.sourceSha256, tracked.get(TTS_FACTORY_SOURCE));
    assert.equal(row.export, 'createTtsTool');
    assert.equal(row.evidence, 'factory-return');
    assert.equal(row.context, `recipe/${row.id}`);
    assert.equal(row.descriptor.name, 'tts');
    assert.equal(row.descriptor.label, 'TTS');
    assert.equal(row.descriptor.executeObserved, true);
    assert.deepEqual(row.descriptor, direct.descriptor);
    assert.equal(row.eligibility.status, 'unresolved');
    assert.equal(row.registration.status, 'unresolved');
  }
  assert.deepEqual(rows.filter(row => row.representativeContext).map(row => row.representativeContext), representativeContexts());
});

test('fresh source regions reproduce every TTS metadata field and the complete input schema', () => {
  for (const row of rows) {
    const comparison = row.definitionComparison;
    assert.equal(row.descriptorMatch, true);
    assert.equal(comparison.freshVm, true);
    assert.equal(comparison.kind, 'source-metadata-region');
    assert.equal(comparison.syntheticExport, 'captureMetadata');
    assert.equal(comparison.sourceSha256, tracked.get(TTS_FACTORY_SOURCE));
    assert.deepEqual(comparison.args, row.args);
    const { executeObserved, ...metadata } = row.descriptor;
    assert.deepEqual(comparison.metadata, metadata);
    assert.deepEqual(Object.keys(metadata).sort(), ['description', 'displaySummary', 'label', 'name', 'parameters']);
    assert.equal(typeof metadata.displaySummary, 'string');
    assert.equal(typeof metadata.description, 'string');
    assert.deepEqual(Object.keys(metadata.parameters.properties).sort(), ['channel', 'text', 'timeoutMs']);
    assert.deepEqual(metadata.parameters.required, ['text']);
    assert.equal(metadata.parameters.properties.text.type, 'string');
    assert.equal(metadata.parameters.properties.channel.type, 'string');
    assert.equal(metadata.parameters.properties.timeoutMs.type, 'integer');
    assert.equal(metadata.parameters.properties.timeoutMs.minimum, 1);
    assert.deepEqual(row.schema.parameters, metadata.parameters);
    assert.deepEqual(JSON.parse(row.schema.schemaJson), metadata.parameters);
    assert.equal(row.schema.schemaSha256, hash(row.schema.schemaJson));
    assert.deepEqual(row.schema.actions, []);
    assert.equal(row.schema.actionlessBranches, 1);
    assert.deepEqual(comparison.projections.map(item => item.kind), ['tts-metadata-region']);
    assert.deepEqual(comparison.projections[0].selections.map(item => [item.startLine, item.endLine]), [[9, 18], [39, 44]]);
    assert.deepEqual(comparison.stubs, []);
  }
});

test('retains the explicit construction boundary and exact deferred execution imports', () => {
  const stubs = [
    ['../../config/config.js', ['getRuntimeConfig']],
    ['../../tts/tts.js', ['textToSpeech']],
    ['./common.js', ['readPositiveIntegerParam', 'readToolStringParam']],
    ['./tts-tool-result-provenance.js', ['markCoreTtsToolResult']],
  ].map(([specifier, exports]) => ({ importer: TTS_FACTORY_SOURCE, specifier, exports }));
  for (const row of rows) {
    assert.equal(row.executeInvoked, false);
    assert.deepEqual(row.executionBoundary, { toolExecuteInvoked: false, transcriptSanitizerInvoked: false,
      voiceProviderInvoked: false, configReadInvoked: false, dynamicImportsInvoked: false });
    assert.deepEqual(row.stubs, stubs);
    assert.deepEqual(row.projections, []);
    for (const evidence of [row, row.definitionComparison]) {
      assert.equal(evidence.executeInvoked, false);
      assert.deepEqual(evidence.attemptedCalls, []);
      assert.deepEqual(evidence.configBindings, []);
      assert.deepEqual(evidence.loadedFiles, [{ path: TTS_FACTORY_SOURCE, sha256: tracked.get(TTS_FACTORY_SOURCE) }]);
      assert.equal(evidence.typebox.version, '1.3.37');
    }
  }
});

test('records unchanged factory transformation and exact source-region and TypeBox digests', () => {
  const source = readFileSync(join(root, TTS_FACTORY_SOURCE), 'utf8');
  const executable = stripTypeScriptTypes(source, { mode: 'transform', sourceMap: false });
  for (const row of rows) {
    assert.deepEqual(row.factoryExecution, { kind: 'complete-source-module', sourceSha256: hash(source),
      transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', executableSha256: hash(executable) });
    for (const evidence of [row, row.definitionComparison]) {
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
  }
});

test('TTS constructor evidence is deterministic across fresh independent VM captures', async () => {
  assert.deepEqual(await captureTtsFactories(root, files), rows);
});

test('canonical pinned fixture retains the exact recaptured TTS constructor evidence', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/capture.json', import.meta.url), 'utf8'));
  assert.deepEqual(fixture.recipes.filter(row => row.source === TTS_FACTORY_SOURCE), rows);
});
