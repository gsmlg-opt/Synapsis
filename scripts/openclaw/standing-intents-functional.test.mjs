// Frozen ordinary reference vectors. Cancellation execution and native host parity remain open.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isAbsolute, join } from 'node:path';
import test from 'node:test';
import { captureStandingIntents, STANDING_INTENTS_PIN } from './capture-standing-intents.mjs';

const source = '/tmp/openclaw-488631c';
const observed = await captureStandingIntents(source);
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const jsonResult = payload => ({
  content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
  details: payload,
});

const firstArguments = {
  action: 'create',
  description: ' Review the deployment checklist. ',
  triggerKeywords: [' Deploy ', 'deploy', 'release check'],
};
const secondArguments = {
  action: 'create',
  description: 'Review the release notes.',
  triggerKeywords: ['RELEASE check'],
  scope: 'conversation',
  maxFires: 2,
  cooldownSeconds: 60,
  expiresAt: '2027-01-18T08:00:00.000Z',
};
const firstArmed = {
  id: 'intent-01',
  description: 'Review the deployment checklist.',
  triggerKeywords: ['deploy', 'release check'],
  triggerEmbedding: null,
  scope: 'channel',
  channelScope: 'webchat',
  senderScope: 'synapsis:operator',
  creatorSender: 'synapsis:operator',
  status: 'armed',
  expiresAt: 1807776000000,
  maxFires: 3,
  fireCount: 0,
  cooldownSeconds: 86400,
  lastFiredAt: null,
  createdAt: 1800000000000,
  sourceSessionId: 'source-session297',
};
const secondArmed = {
  id: 'intent-02',
  description: 'Review the release notes.',
  triggerKeywords: ['release check'],
  triggerEmbedding: null,
  scope: 'conversation',
  channelScope: 'conversation297',
  senderScope: 'synapsis:operator',
  creatorSender: 'synapsis:operator',
  status: 'armed',
  expiresAt: 1800259200000,
  maxFires: 2,
  fireCount: 0,
  cooldownSeconds: 60,
  lastFiredAt: null,
  createdAt: 1800000001000,
  sourceSessionId: 'source-session297',
};
const armed = [firstArmed, secondArmed];
const fired = [
  { ...firstArmed, status: 'fired', fireCount: 1, lastFiredAt: 1800000002000 },
  { ...secondArmed, status: 'fired', fireCount: 1, lastFiredAt: 1800000002000 },
];
const final = [
  { ...firstArmed, status: 'fired', fireCount: 2, lastFiredAt: 1800086402000 },
  { ...secondArmed, status: 'done', fireCount: 2, lastFiredAt: 1800086402000 },
];
const firstMessage = 'Intent is armed for this channel. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.';
const secondMessage = 'Intent is armed for this conversation. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.';
const hookContext = {
  trigger: 'user',
  sessionKey: 'agent:agent297:source',
  sessionId: 'source-session297',
  channel: 'webchat',
  messageProvider: 'webchat',
  channelId: 'conversation297',
  senderId: 'synapsis:operator',
};
const prependContext = '<standing_intents>\nStanding intent (created 2027-01-15): Review the deployment checklist.\nStanding intent (created 2027-01-15): Review the release notes.\n</standing_intents>';

// Independent SQL DTO literals preserve encoded matching identity separately from session provenance.
function expectedSqlRow(which, id, phase) {
  const first = which === 1;
  const count = phase === 'armed' ? 0 : 2;
  return {
    intent_key: which,
    id,
    description: first ? 'Review the deployment checklist.' : 'Review the release notes.',
    trigger_keywords: first ? '["deploy","release check"]' : '["release check"]',
    trigger_embedding: null,
    channel_scope: first
      ? '["v1","channel","webchat","default","webchat"]'
      : '["v1","conversation","webchat","default","conversation297"]',
    sender_scope: '["v1","webchat","default","synapsis:operator"]',
    creator_sender: 'synapsis:operator',
    status: phase === 'armed' ? 'armed' : first ? 'fired' : 'done',
    expires_at: first ? 1807776000000 : 1800259200000,
    max_fires: first ? 3 : 2,
    fire_count: count,
    cooldown_seconds: first ? 86400 : 60,
    last_fired_at: phase === 'armed' ? null : 1800086402000,
    created_at: first ? 1800000000000 : 1800000001000,
    source_session_id: 'source-session297',
  };
}

test('registered lazy factory preserves all three action schemas and exact ordinary source result bytes', () => {
  assert.deepEqual(observed.registration, {
    contextVersion: 2, names: ['intent'], workspaceAccess: 'execute', hook: 'before_prompt_build',
  });
  assert.deepEqual(observed.definition, {
    label: 'Standing Intent',
    name: 'intent',
    description: 'Create, list, or explicitly cancel event-conditioned standing intents. A created intent is armed; the system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks. Use scheduled tasks for time-based reminders.',
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['create', 'list', 'cancel'] },
        id: { type: 'string' },
        description: { type: 'string' },
        triggerKeywords: { type: 'array', items: { type: 'string' } },
        scope: { type: 'string', enum: ['conversation', 'channel', 'anywhere'], default: 'channel' },
        senderScope: { type: 'string', enum: ['sender', 'anyone'], default: 'sender' },
        expiresAt: { type: 'string' },
        maxFires: { type: 'integer', minimum: 1 },
        cooldownSeconds: { type: 'integer', minimum: 0 },
        status: { type: 'string', enum: ['pending', 'armed', 'fired', 'done', 'cancelled', 'expired'] },
      },
      required: ['action'],
      additionalProperties: false,
    },
    prepareArgumentsPresent: true,
    executePresent: true,
  });
  const expected = [
    ['create-default', firstArguments, { intent: firstArmed, message: firstMessage }],
    ['create-conversation', secondArguments, { intent: secondArmed, message: secondMessage }],
    ['list-armed', { action: 'list' }, { intents: armed }],
    ['list-fired', { action: 'list' }, { intents: fired }],
    ['list-final', { action: 'list' }, { intents: final }],
    ['reopen-list', { action: 'list' }, { intents: final }],
  ];
  assert.deepEqual(observed.observations, expected.map(([id, args, payload]) => ({
    id, argumentsBefore: args, argumentsAfter: args, prepared: args, result: jsonResult(payload),
  })));
});

test('actual registered user hook injects exact dated context and durable lifecycle advances through rearming', () => {
  assert.deepEqual(observed.hooks, [
    { id: 'first', prompt: 'Let us deploy, then do the release check.', context: hookContext,
      result: { prependContext } },
    { id: 'rearmed', prompt: 'The check for the release follows deploy today.', context: hookContext,
      result: { prependContext } },
  ]);
  assert.deepEqual(observed.states, [
    { id: 'armed', intents: armed },
    { id: 'fired', intents: fired },
    { id: 'final', intents: final },
    { id: 'reopened', intents: final },
  ]);
  assert.equal(observed.maintenance.started, true);
  assert.equal(observed.maintenance.stopped, true);
  assert.equal(observed.maintenance.pendingAfterStop, 0);
  for (const atMs of [1800000062000, 1800172802000]) {
    assert.ok(observed.maintenance.scheduled.some(job =>
      job.id === observed.persistence.databasePath && job.atMs === atMs), String(atMs));
  }
  assert.ok(observed.maintenance.executed.some(job =>
    job.id === observed.persistence.databasePath && job.atMs === 1800000062000 && job.nowMs === 1800086402000));
  for (const job of observed.maintenance.executed) {
    assert.ok(observed.maintenance.scheduled.some(scheduled => scheduled.id === job.id && scheduled.atMs === job.atMs));
    assert.ok(job.nowMs >= job.atMs);
  }
});

test('actual random UUID results correlate with file-backed SQL rows before normalization and fresh reopen', () => {
  assert.deepEqual(observed.normalization.ids.map(row => row.normalized), ['intent-01', 'intent-02']);
  const actualIds = observed.normalization.ids.map(row => row.actual);
  for (const id of actualIds) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  assert.notEqual(actualIds[0], actualIds[1]);
  assert.deepEqual(observed.normalization.rawCreates, [
    { id: 'create-default', result: jsonResult({ intent: { ...firstArmed, id: actualIds[0] }, message: firstMessage }),
      storedRow: expectedSqlRow(1, actualIds[0], 'armed') },
    { id: 'create-conversation', result: jsonResult({ intent: { ...secondArmed, id: actualIds[1] }, message: secondMessage }),
      storedRow: expectedSqlRow(2, actualIds[1], 'armed') },
  ]);
  assert.deepEqual(observed.normalization.rawReopenedRows, [
    expectedSqlRow(1, actualIds[0], 'final'), expectedSqlRow(2, actualIds[1], 'final'),
  ]);
  const db = observed.persistence;
  assert.equal(db.fileBacked, true);
  assert.equal(isAbsolute(db.databasePath), true);
  assert.notEqual(db.databasePath, ':memory:');
  assert.equal(db.closedBeforeReopen, true);
  assert.equal(db.reopenedWithFreshBackend, true);
  assert.ok(Number.isInteger(db.connectionsOpened) && db.connectionsOpened >= 2);
  assert.equal(db.connectionsClosed, db.connectionsOpened);
  assert.equal(db.removedAfterCapture, true);
  const expectedFinalRows = [expectedSqlRow(1, 'intent-01', 'final'), expectedSqlRow(2, 'intent-02', 'final')];
  assert.deepEqual(db.rowsBeforeClose, expectedFinalRows);
  assert.deepEqual(db.rowsAfterReopen, expectedFinalRows);
  for (const [name, type] of [
    ['standing_intents', 'table'], ['standing_intents_fts', 'table'],
    ['idx_standing_intents_lifecycle', 'index'], ['idx_standing_intents_scope', 'index'],
    ['standing_intents_fts_after_insert', 'trigger'], ['standing_intents_fts_after_delete', 'trigger'],
    ['standing_intents_fts_after_update', 'trigger'],
  ]) assert.ok(db.schema.some(row => row.name === name && row.type === type && typeof row.sql === 'string'), name);
  assert.match(db.schema.find(row => row.name === 'standing_intents_fts').sql, /fts5[\s\S]*content\s*=\s*'standing_intents'[\s\S]*content_rowid\s*=\s*'intent_key'/i);
  assert.ok(db.sql.some(row => /\bbegin\s+immediate\b/i.test(row.sql)));
  assert.ok(db.sql.some(row => /\bcommit\b/i.test(row.sql)));
  assert.ok(db.sql.some(row => /\bmatch\b/i.test(row.sql) && /standing_intents_fts/i.test(row.sql)));
  for (const id of actualIds) {
    assert.ok(db.sql.some(row => /insert\s+into\s+"?standing_intents"?/i.test(row.sql) && row.parameters.includes(id)), id);
  }
});

test('whole unchanged source closure official Kysely runtime and supplied boundaries are explicit', () => {
  assert.equal(observed.schemaVersion, 1);
  assert.equal(STANDING_INTENTS_PIN, pin);
  assert.equal(observed.referencePin, pin);
  const tree = { pin, tree: '47509a47273231ab15f57252960fe716d7379ffb', clean: true, verifiedTrackedFiles: 58558 };
  assert.deepEqual(observed.sourceTree, { before: tree, after: tree });
  for (const path of [
    'extensions/memory-core/index.ts',
    'extensions/memory-core/src/standing-intents-tool.ts',
    'extensions/memory-core/src/standing-intents.ts',
    'extensions/memory-core/src/standing-intents-model.ts',
    'extensions/memory-core/src/standing-intents-kernel.ts',
    'extensions/memory-core/src/standing-intents-search.ts',
    'extensions/memory-core/src/standing-intents.worker.ts',
    'src/state/openclaw-agent-standing-intents-schema.ts',
    'src/state/openclaw-agent-schema.ts',
    'src/infra/kysely-sync.ts',
    'src/infra/sqlite-transaction.ts',
    'src/infra/sqlite-worker-binding.ts',
    'src/infra/sqlite-post-commit.ts',
    'src/infra/database-engine/search-admission.ts',
    'src/infra/database-engine/search.ts',
    'src/infra/database-engine/sqlite-full-text.ts',
    'src/agents/tools/tool-results.ts',
  ]) assert.ok(observed.sourceRecords.some(row => row.path === path && row.executed && row.wholeModule), path);
  assert.ok(observed.sourceRecords.some(row => row.path === 'src/state/openclaw-agent-schema.sql' && row.wholeModule));
  for (const row of observed.sourceRecords) {
    const bytes = readFileSync(join(source, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), row.gitBlob, row.path);
    if (row.executed) {
      assert.equal(row.wholeModule, true, row.path);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256, row.path);
    }
  }
  const kysely = observed.dependencies.kysely;
  assert.equal(kysely.name, 'kysely');
  assert.equal(kysely.version, '0.29.6');
  assert.equal(kysely.integrity, 'sha512-hHaB8C/rfzDDtr/t8YZwxAuPJTT0zHyaPoVzcXwDYhYNAgH/4sIfVhi/XLLIY+bL/FqaIJnjATDbi8ObSELmxg==');
  assert.equal(kysely.archiveSha256, '02c79d44103b2ea05effce404448ca3b749f2daabff2343397b44ea2cdf328a3');
  for (const [path, sha256] of [
    ['package.json', '3fa76780c11b61ec03c8f6c3a2d3556ecbdf373d0a946280e0b9cb459138c861'],
    ['dist/index.js', '449794fb878e379b309602b04a0d8d9557333f469f6b6e1c63ff5cf33d19b542'],
    ['dist/dialect/sqlite/sqlite-query-compiler.js', '152db722fa8e753ff491211389ca3829599f422e2a5e0243f3497e210f6ea515'],
  ]) assert.ok(kysely.files.some(row => row.path === path && row.sha256 === sha256), path);
  for (const row of kysely.files) assert.equal(hash(readFileSync(join(kysely.root, row.path))), row.sha256, row.path);
  assert.ok(observed.dependencies.externalPorts.length > 0);
  for (const port of observed.dependencies.externalPorts) {
    assert.equal(typeof port.name, 'string');
    assert.ok(Array.isArray(port.exports));
    assert.equal(typeof port.generatedCode, 'string');
    assert.equal(hash(port.generatedCode), port.sha256, port.name);
  }
  assert.equal(observed.runtime.version, '24.22.1');
  assert.equal(hash(readFileSync(observed.runtime.executable)), observed.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-standing-intents.mjs', import.meta.url))), observed.exporter.sha256);
  assert.deepEqual(observed.boundaries, {
    sourceDatabaseExecuted: true,
    sourceKernelExecuted: true,
    sourceFactoryExecuted: true,
    sourcePromptHookExecuted: true,
    suppliedWorkerTransport: true,
    sourceCanonicalWorkerExecuted: false,
    hostProductExecuted: false,
  });
  const exclusions = observed.exclusions.join('\n');
  for (const pattern of [/cancel/i, /security/i, /permission/i, /auth.*TLS/i, /negative/i, /error/i,
    /failure/i, /crash/i, /mixed/i, /budget/i, /size/i, /race/i, /real.*provider/i, /production/i]) {
    assert.match(exclusions, pattern);
  }
});
