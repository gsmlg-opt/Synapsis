import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureWorkboard } from './capture-workboard.mjs';

const capture = await captureWorkboard('/tmp/openclaw-488631c');
const rows = new Map(capture.observations.map(row => [row.id, row]));
const details = id => rows.get(id).result.details;
const hash = value => createHash('sha256').update(value).digest('hex');

test('all 38 original factory descriptors preserve schemas and actual registration metadata', () => {
  assert.equal(Object.keys(capture.tools).length, 38);
  const [cards, sessions] = capture.registrations;
  assert.equal(cards.options.optional, true);
  assert.equal(cards.factoryKind, 'function');
  assert.equal(cards.options.names.length, 35);
  assert.equal(sessions.factoryKind, 'context-factory');
  assert.equal(sessions.contextVersion, 2);
  assert.deepEqual(sessions.options.names, ['workboard_sessions_board_read', 'workboard_sessions_board_update', 'workboard_sessions_board_move']);
  assert.equal('optional' in sessions.options, false);
  assert.deepEqual([...cards.options.names, ...sessions.options.names].sort(), Object.keys(capture.tools).sort());
  assert.equal(capture.factoryGroups.base.length, 16);
  assert.equal(capture.factoryGroups.orchestration.length, 19);
  assert.equal(capture.factoryGroups.sessions.length, 3);
  for (const [name, tool] of Object.entries(capture.tools)) {
    assert.equal(tool.name, name);
    assert.equal(typeof tool.label, 'string');
    assert.equal(typeof tool.description, 'string');
    assert.equal(tool.parameters.type, 'object');
    assert.equal(tool.parameters.additionalProperties, false);
  }
  assert.deepEqual(capture.tools.workboard_create.parameters.required, ['title']);
  assert.deepEqual(capture.tools.workboard_comment.parameters.required, ['id', 'body']);
  assert.deepEqual(capture.tools.workboard_board_create.parameters.required, ['id']);
  assert.equal(capture.tools.workboard_create.parameters.properties.maxRetries.type, 'number');
  assert.equal(capture.tools.workboard_list.parameters.properties.limit.type, 'number');
  assert.deepEqual(capture.tools.workboard_sessions_board_read.parameters.required ?? [], []);
  const update = capture.tools.workboard_sessions_board_update.parameters.properties;
  assert.equal(update.columns.minItems, 2);
  assert.equal(update.columns.maxItems, 12);
  assert.deepEqual(update.columns.items.required, ['id', 'label', 'description']);
  assert.equal(update.scope.additionalProperties, false);
  assert.equal(update.scope.properties.maxAgeHours.exclusiveMinimum, 0);
  assert.match(capture.tools.workboard_sessions_board_update.description, /first matching column wins/);
});

test('actual source board upsert preserves creation and lists metadata with source summaries', () => {
  const first = details('board-create').board;
  const updated = details('board-update').board;
  assert.equal(first.id, 'research');
  assert.equal(first.name, 'Research 雪😀');
  assert.equal(first.description, 'Ordinary board');
  assert.equal(updated.createdAt, first.createdAt);
  assert.equal(updated.name, 'Research reviewed');
  assert.equal(updated.description, first.description);
  assert.ok(updated.updatedAt >= first.updatedAt);
  const boards = details('boards-after').boards;
  assert.deepEqual(boards.map(board => board.id), ['default', 'other', 'research']);
  const research = boards.find(board => board.id === 'research');
  assert.equal(research.total, 3);
  assert.equal(research.active, 3);
  assert.equal(research.archived, 0);
  assert.deepEqual(research.byStatus, {todo: 2, done: 1});
  assert.equal('createdAt' in research, false);
});

test('real create factory and source store preserve defaults rich fields positions and ordinary repeated key', () => {
  const minimal = details('create-minimal').card;
  assert.equal(minimal.title, 'Minimal 雪😀');
  assert.equal(minimal.status, 'todo');
  assert.equal(minimal.priority, 'normal');
  assert.deepEqual(minimal.labels, []);
  assert.equal(minimal.position, 1000);
  assert.equal(minimal.createdAt, minimal.updatedAt);
  assert.deepEqual(minimal.events.map(event => [event.kind, event.toStatus, event.at]), [['created', 'todo', minimal.createdAt]]);
  const rich = details('create-rich').card;
  assert.equal(rich.title, 'Rich supplied item');
  assert.equal(rich.notes, 'Acceptance 雪😀');
  assert.deepEqual(rich.labels, ['review', '雪😀']);
  assert.equal(rich.priority, 'high');
  assert.equal(rich.agentId, 'fixture-agent');
  assert.equal(rich.position, 2000);
  assert.deepEqual(rich.metadata.automation, {
    tenant: 'fixture-tenant', boardId: 'research', idempotencyKey: 'ordinary-repeat',
    skills: ['inspect', 'review'], workspace: {kind: 'dir', path: '/supplied/workspace'},
    maxRuntimeSeconds: 120, maxRetries: 2,
  });
  assert.deepEqual(details('create-repeat').card, rich);
  assert.equal(details('create-other').card.position, 1000);
  assert.equal(details('create-done').card.completedAt, details('create-done').card.createdAt);
  assert.equal(capture.recordReceipts.distinctCreatedCards, 4);
  assert.equal(capture.recordReceipts.sameKeySameCard, true);
});

test('real list read and comment callbacks retain ordering filtering fields and worker context', () => {
  const minimal = details('create-minimal').card;
  const rich = details('create-rich').card;
  const done = details('create-done').card;
  const list = details('list-research').cards;
  assert.deepEqual(list.map(card => card.id), [minimal.id, rich.id, done.id]);
  assert.deepEqual(list.map(card => card.boardId), ['research', 'research', 'research']);
  assert.equal('notes' in list[1], false);
  assert.equal('labels' in list[1], false);
  assert.deepEqual(details('list-filtered').cards.map(card => card.id), [rich.id]);
  assert.deepEqual(details('list-limited').cards.map(card => card.id), [minimal.id]);
  assert.deepEqual(details('read-before').card, rich);
  const commented = details('comment').card;
  assert.deepEqual(commented.metadata.comments.map(comment => comment.body), ['Reviewed ordinary evidence 雪😀']);
  assert.equal('author' in commented.metadata.comments[0], false);
  assert.ok(commented.updatedAt >= commented.metadata.comments[0].createdAt);
  assert.equal(commented.events.at(-1).kind, 'comment_added');
  assert.deepEqual(details('read-after').card, commented);
  assert.equal(typeof details('read-after').workerContext, 'string');
  assert.match(details('read-after').workerContext, /Reviewed ordinary evidence 雪😀/);
  assert.match(details('read-after').workerContext, /Acceptance 雪😀/);
  for (const row of capture.observations) {
    assert.deepEqual(row.argumentsAfter, row.arguments);
    assert.deepEqual(row.result.content, [{type: 'text', text: JSON.stringify(row.result.details, null, 2)}]);
    assert.equal(row.execution, 'actual unchanged factory callback and original source domain/store algorithms');
  }
});

test('whole-source package runtime receipts and explicit supplied boundaries are reproducible', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  for (const path of ['extensions/workboard/index.ts', 'extensions/workboard/src/tools.ts',
    'extensions/workboard/src/tools-orchestration.ts', 'extensions/workboard/src/tools-card-mutations.ts',
    'extensions/workboard/src/store.ts', 'extensions/workboard/src/store-core.ts',
    'extensions/workboard/src/store-boards.ts', 'extensions/workboard/src/store-runtime.ts',
    'extensions/workboard/src/store-normalizers.ts', 'extensions/workboard/src/store-board-normalizers.ts',
    'extensions/workboard/src/store-read.ts', 'extensions/workboard/src/store-card-helpers.ts']) {
    assert.equal(capture.sourceRecords.find(row => row.path === path)?.executed, true, path);
  }
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join('/tmp/openclaw-488631c', row.path));
    assert.equal(hash(bytes), row.sha256);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), {mode: 'transform', sourceMap: false})), row.executableSha256);
    }
  }
  for (const row of capture.importBindings) if (row.generatedCode) assert.equal(hash(row.generatedCode), row.generatedSha256);
  assert.equal(capture.typebox.version, '1.3.37');
  for (const row of capture.typebox.files) assert.equal(hash(readFileSync(join(capture.typebox.root, row.path.slice('typebox/'.length)))), row.sha256);
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(hash(readFileSync(capture.runtime.executable)), capture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-workboard.mjs', import.meta.url))), capture.exporter.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))), capture.harness.sha256);
  assert.equal(hash(capture.host.generatedCode), capture.host.sha256);
  assert.deepEqual(capture.deferredCalls, []);
  assert.equal(capture.boundaries.all38FactoriesInvoked, true);
  assert.equal(capture.boundaries.originalPluginRegistrationExecuted, true);
  assert.equal(capture.boundaries.originalRecordAlgorithmsExecuted, true);
  for (const key of ['sqliteExecuted', 'productionPersistenceExecuted', 'workspaceGuardExecuted',
    'sessionsBoardServiceExecuted', 'pluginServiceLifecycleExecuted', 'permissionQualification', 'networkExecuted', 'hostImplementation']) {
    assert.equal(capture.boundaries[key], false, key);
  }
  assert.match(capture.persistenceBoundary, /explicit supplied in-memory/);
  assert.match(capture.limits.join('\n'), /discussion.*separate.*pending/);
  assert.match(capture.limits.join('\n'), /host scope.*default.*pending/);
});

test('fresh whole-source VM repeat equals standalone frozen fixture', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/workboard.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureWorkboard('/tmp/openclaw-488631c'), fixture);
});
