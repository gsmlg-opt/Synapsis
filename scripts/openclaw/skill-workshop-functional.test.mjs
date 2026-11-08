import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureSkillWorkshop, SKILL_WORKSHOP_PIN } from './capture-skill-workshop.mjs';

// Independent literal expectations, authored before the first source capture.
const initial = '---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\n\n# Deploy\n\n1. Inspect the release.\n2. Record the result.\n';
const patched = '---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\n\n# Deploy\n\n1. Inspect the approved release.\n2. Record the result.\n';
const reference = 'Reference café.\nKeep the release record.\n';
const patchedReference = 'Reference café.\nKeep the approved release record.\n';
const template = 'Release: <version>\nResult: <result>\n';
const actionIds = ['list-empty', 'create', 'view-initial', 'write-reference', 'write-template',
  'patch-main', 'patch-reference', 'view-reference', 'view-saved', 'remove-reference',
  'write-extra', 'restore-explicit', 'view-restored', 'archive', 'list-archived',
  'restore-newest', 'list-restored'];
const mutations = [
  ['create', 'create', 'created: Deploy a reviewed release.', 'Created', null],
  ['write-reference', 'write_file', 'wrote references/notes.md', 'Updated', 'version-01-write_file'],
  ['write-template', 'write_file', 'wrote templates/check.txt', 'Updated', 'version-02-write_file'],
  ['patch-main', 'patch', 'clarify the approval check', 'Patched', 'version-03-patch'],
  ['patch-reference', 'patch', 'patched references/notes.md', 'Patched', 'version-04-patch'],
  ['remove-reference', 'remove_file', 'removed references/notes.md', 'Updated', 'version-05-remove_file'],
  ['write-extra', 'write_file', 'wrote examples/trial.txt', 'Updated', 'version-06-write_file'],
  ['restore-explicit', 'restore', 'restore the complete saved tree', 'Restored', 'version-07-restore'],
  ['archive', 'archive', 'archived: retain the reusable procedure', 'Archived', 'version-08-archive'],
  ['restore-newest', 'restore', 'restored from archive', 'Restored', null],
];
const observed = await captureSkillWorkshop();
const row = id => observed.observations.find(value => value.id === id);
const result = (text, details) => ({ content: [{ type: 'text', text }], details });
const fullFiles = ['SKILL.md', 'references/notes.md', 'templates/check.txt'];
const liveBytes = id => Object.fromEntries(row(id).tree.filter(file => file.path.startsWith('workshop-skills/deploy-guide/'))
  .map(file => [file.path.slice('workshop-skills/deploy-guide/'.length), file.content]));

test('all eight actions execute the unchanged factory with exact successful source results', () => {
  assert.deepEqual(observed.observations.map(value => value.id), actionIds);
  assert.deepEqual(row('list-empty').result,
    result('No learned skills yet. Add one with action=create.', { skills: [], archived: [] }));
  for (const [index, [id, action, summary, verb, versionId]] of mutations.entries()) {
    const change = { id: `change-${String(index + 1).padStart(2, '0')}`, agentId: 'agent292',
      skillName: 'deploy-guide', action, actor: 'agent', summary,
      ...(versionId ? { versionId } : {}), sessionKey: 'agent:agent292:source', runId: 'run292',
      createdAtMs: `change-${String(index + 1).padStart(2, '0')}::time` };
    const undo = versionId ? 'Saved previous version; undo with action=restore name=deploy-guide.'
      : 'Undo with action=archive name=deploy-guide.';
    assert.deepEqual(row(id).result, result(`${verb} "deploy-guide" (${summary}). ${undo}`, { change }), id);
  }
  assert.deepEqual(observed.changeLedger, mutations.map(([id]) => row(id).result.details.change));
  for (const entry of observed.observations)
    assert.deepEqual(entry.argumentsAfter, entry.argumentsBefore, entry.id);
});

test('whole live/support/version reads retain complete exact bytes and original formatting', () => {
  assert.deepEqual(row('view-initial').result,
    result(initial, { name: 'deploy-guide', filePath: 'SKILL.md', files: ['SKILL.md'] }));
  assert.deepEqual(row('view-reference').result,
    result(patchedReference + '\n\n[Other files: SKILL.md, templates/check.txt]',
      { name: 'deploy-guide', filePath: 'references/notes.md', files: fullFiles }));
  assert.deepEqual(row('view-saved').result,
    result(initial, { name: 'deploy-guide', filePath: 'SKILL.md', files: ['SKILL.md'], version: 'version-01-write_file' }));
  assert.deepEqual(row('view-restored').result,
    result(patchedReference + '\n\n[Other files: SKILL.md, templates/check.txt]',
      { name: 'deploy-guide', filePath: 'references/notes.md', files: fullFiles }));
  assert.deepEqual(liveBytes('write-reference'), { 'SKILL.md': initial, 'references/notes.md': reference });
  assert.deepEqual(liveBytes('patch-reference'),
    { 'SKILL.md': patched, 'references/notes.md': patchedReference, 'templates/check.txt': template });
  assert.deepEqual(liveBytes('remove-reference'), { 'SKILL.md': patched, 'templates/check.txt': template });
  assert.deepEqual(liveBytes('write-extra'),
    { 'SKILL.md': patched, 'templates/check.txt': template, 'examples/trial.txt': 'Trial procedure.\n' });
  assert.deepEqual(liveBytes('restore-explicit'),
    { 'SKILL.md': patched, 'references/notes.md': patchedReference, 'templates/check.txt': template });
  assert.deepEqual(liveBytes('archive'), {});
  assert.deepEqual(liveBytes('restore-newest'), liveBytes('restore-explicit'));
  for (const entry of observed.observations) for (const file of entry.tree) {
    assert.equal(file.bytes, Buffer.byteLength(file.content), entry.id + '/' + file.path);
    assert.equal(file.sha256, createHash('sha256').update(file.content).digest('hex'));
  }
});

test('full-tree snapshots preserve historical bytes and newest archive restoration stays undoable', () => {
  const versions = mutations.filter(value => value[4]).map(value => value[4]);
  assert.deepEqual(observed.normalization.versionSymbols, versions);
  const archived = row('list-archived');
  const expectedVersions = [...versions].reverse().map(id => ({ id,
    action: id.slice('version-00-'.length), createdAtMs: `${id}::time` }));
  assert.deepEqual(archived.result, result('Archived (restore with action=restore):\n- deploy-guide',
    { skills: [], archived: [{ name: 'deploy-guide', live: false, versions: expectedVersions }] }));
  const saved = Object.fromEntries(row('archive').tree
    .filter(file => file.path.startsWith('workshop-skills/.archive/deploy-guide/version-05-remove_file/'))
    .map(file => [file.path.split('/').slice(4).join('/'), file.content]));
  assert.deepEqual(saved,
    { 'SKILL.md': patched, 'references/notes.md': patchedReference, 'templates/check.txt': template });
  const final = row('list-restored').result;
  assert.equal(final.content[0].text, '- deploy-guide: Deploy a reviewed release.');
  assert.deepEqual(final.details, { skills: [{ name: 'deploy-guide', description: 'Deploy a reviewed release.',
    updatedAtMs: '$LIVE_TREE_MTIME', sizeBytes: Buffer.byteLength(patched + patchedReference + template),
    files: fullFiles }], archived: [] });
  assert.equal(observed.normalization.actualRelationshipsChecked, true);
  assert.equal(observed.normalization.rawReceipt, '/tmp/synapsis-workshop292-source-raw.json');
});

test('whole factory schema, default/custom config and foreground constructor metadata are source facts', () => {
  const properties = {
    action: { type: 'string', enum: ['list', 'view', 'create', 'patch', 'write_file', 'remove_file', 'archive', 'restore'] },
    name: { type: 'string', description: 'Skill name (lowercase-hyphenated).' },
    file_path: { type: 'string', description: 'SKILL.md (default) or a file under references/, templates/, scripts/, assets/.' },
    content: { type: 'string', description: 'create: full SKILL.md. write_file: full file content.' },
    old_text: { type: 'string', description: 'patch: exact text to replace once.' },
    new_text: { type: 'string', description: 'patch: replacement text.' },
    absorbed_into: { type: 'string', description: 'archive: live skill that now covers this one.' },
    reason: { type: 'string', description: 'One short line saying what changed and why; shown to the user.' },
    version: { type: 'string', description: 'view/restore: version id; restore defaults to the newest.' },
  };
  for (const constructor of observed.constructors) {
    assert.equal(constructor.definition.name, 'skill_workshop');
    assert.equal(constructor.definition.label, 'Skill Workshop');
    assert.equal(constructor.definition.displaySummary, 'Save, improve, archive, and restore your learned skills.');
    assert.deepEqual(constructor.definition.parameters,
      { type: 'object', properties, required: ['action'], additionalProperties: false });
    assert.equal(constructor.definition.outputSchemaDeclared, false);
    assert.equal(constructor.definition.executePresent, true);
    assert.match(constructor.definition.description, /^Your learned skills: reusable procedures/);
    assert.match(constructor.definition.description, /Skill authoring standard:/);
    assert.match(constructor.definition.description, /restore without version undoes the last change/);
  }
  assert.deepEqual(observed.configurations, [
    { id: 'default', result: { autonomous: { mode: 'auto', channelNotices: false }, maxSkillBytes: 40000 } },
    { id: 'custom', result: { autonomous: { mode: 'off', channelNotices: true }, maxSkillBytes: 8192 } },
  ]);
  assert.equal(observed.constructors.length, 3);
});

test('called ownership adapters and uncalled boundaries stay explicit without persistence equivalence', () => {
  assert.deepEqual(observed.deferredCalls, []);
  assert.equal(observed.services.filter(call => call.kind === 'recordWorkshopChange').length, 10);
  assert.equal(observed.services.filter(call => call.kind === 'refreshSkillsDiscovery').length, 10);
  const usage = observed.services.filter(call => call.kind === 'recordSkillUsed');
  assert.equal(usage.length, 3); // initial, support-file, restored live views; historical view is not use.
  for (const call of usage) {
    assert.equal(call.params.toolName, 'skill_workshop');
    assert.equal(call.params.match.skillSource, 'workspace');
    assert.equal(call.params.match.activation, 'read');
    assert.equal(call.params.match.skillFile, '$FIXTURE/workshop-skills/deploy-guide/SKILL.md');
  }
  assert.ok(observed.services.some(call => call.kind === 'assertAdmittedSource'));
  assert.equal(observed.boundaries.sourceDatabaseExecuted, false);
  assert.equal(observed.boundaries.hostProductExecuted, false);
  assert.equal(observed.boundaries.actualFileAlgorithms, true);
  assert.equal(observed.boundaries.actualValidationAndLint, true);
  assert.equal(observed.boundaries.actualPinnedFsSafeExports, true);
  assert.equal(observed.boundaries.actualYamlParser, true);
});

test('whole unchanged originals, package/license provenance and full tracked checkout remain reproducible', () => {
  assert.equal(observed.referencePin, SKILL_WORKSHOP_PIN);
  assert.equal(observed.runtime.version, '24.22.1');
  assert.equal(observed.sourceTree.before.tree, '47509a47273231ab15f57252960fe716d7379ffb');
  assert.equal(observed.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(observed.sourceTree.before, observed.sourceTree.after);
  const executed = observed.sourceRecords.filter(record => record.executed);
  for (const path of ['src/agents/tools/skill-workshop-tool-factory.ts',
    'src/agents/tools/skill-workshop-tool.ts', 'src/agents/tools/skill-workshop-tool-schema.ts',
    'src/skills/workshop/library.ts', 'src/skills/workshop/skill-versions.ts',
    'src/skills/lifecycle/workspace-skill-write.ts', 'src/infra/fs-safe-remove.ts',
    'src/skills/loading/frontmatter.ts', 'packages/markdown-core/src/frontmatter.ts',
    'src/skills/workshop/skill-lint.ts', 'src/skills/security/scanner.ts'])
    assert.ok(executed.some(record => record.path === path), path);
  for (const record of observed.sourceRecords) {
    const bytes = readFileSync('/tmp/openclaw-488631c/' + record.path);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), record.sha256, record.path);
    if (record.executed) assert.equal(record.wholeModule, true);
  }
  assert.equal(observed.yaml.version, '2.9.1');
  assert.equal(observed.yaml.tarballSHA256, '4ef6c54cf559b8a207b7b518378230805a1c84af239b14960e8c67c7d59de5d3');
  assert.equal(observed.typebox.version, '1.3.37');
  assert.deepEqual(observed.fsSafe.packages.map(pkg => [pkg.package, pkg.version]),
    [['@openclaw/fs-safe', '0.26.8'], ['@openclaw/fs-safe-linux-x64-gnu', '0.26.8']]);
  assert.equal(typeof observed.fsSafe.nativeBindingLoaded, 'boolean');
  assert.equal(observed.fixtureRemoved, true);
  assert.equal(observed.exporter.sha256,
    createHash('sha256').update(readFileSync(new URL('./capture-skill-workshop.mjs', import.meta.url))).digest('hex'));
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/skill-workshop.json', import.meta.url)));
  assert.deepEqual(observed, frozen);
});
