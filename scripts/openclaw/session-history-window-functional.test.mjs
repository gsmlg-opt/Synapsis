import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { captureSessionHistoryWindow, SESSION_HISTORY_WINDOW_PIN } from './capture-session-history-window.mjs';

// Hand-authored expectations, independent of the source observations and all
// production code. No oracle output is used to manufacture its expected values.
const messages = [
  { role: 'user', content: 'First question.', timestamp: 1700000000001, __openclaw: { seq: 1, id: 'message-1' } },
  { role: 'assistant', content: [{ type: 'text', text: 'First answer.' }], timestamp: 1700000000002, __openclaw: { seq: 2, id: 'message-2' } },
  { role: 'user', content: 'Second question: café.', timestamp: 1700000000003, __openclaw: { seq: 3, id: 'message-3' } },
  { role: 'assistant', content: [{ type: 'text', text: 'Second answer: ready.' }], timestamp: 1700000000004, __openclaw: { seq: 4, id: 'message-4' } },
  { role: 'user', content: 'Third question.', timestamp: 1700000000005, __openclaw: { seq: 5, id: 'message-5' } },
  { role: 'assistant', content: [{ type: 'text', text: 'Third answer.' }], timestamp: 1700000000006, __openclaw: { seq: 6, id: 'message-6' } },
];
const toolCall = { role: 'assistant', content: [{ type: 'toolCall', id: 'call-1', name: 'lookup', arguments: { topic: 'ordinary' } }],
  timestamp: 1700000000010, __openclaw: { seq: 2, id: 'call-message-1' } };
const toolResult = { role: 'toolResult', toolCallId: 'call-1', toolName: 'lookup', content: [{ type: 'text', text: 'Found ordinary result.' }],
  timestamp: 1700000000011, __openclaw: { seq: 3, id: 'result-message-1' } };
const emptyPending = { items: [], total: 0 };
const queuedPending = { items: [{ id: 'pending-input-1', state: 'queued', acceptedAt: 1700000000100,
  message: { role: 'user', content: 'Next ordinary question.' } }], total: 2, nextBefore: 1700000000100 };
const linkRule = 'When pointing the user at a session, cite its Control UI URL: main session -> `https://history.example.test/chat/<agentId>`; any other display session key -> `https://history.example.test/chat/<agentId>/~key/` + key minus `agent:<agentId>:`, with `:` replaced by `/`.';
const expected = {
  'default-tail': { messages, bytes: 783 },
  'explicit-tail-limit': { messages: [messages[4], messages[5]], bytes: 271 },
  'offset-zero': { messages: [messages[4], messages[5]], bytes: 271,
    pagination: { offset: 0, nextOffset: 2, hasMore: true, totalMessages: 6 } },
  'older-offset': { messages: [messages[2], messages[3]], bytes: 287,
    pagination: { offset: 2, nextOffset: 4, hasMore: true, totalMessages: 6 } },
  'oldest-offset': { messages: [messages[0], messages[1]], bytes: 271,
    pagination: { offset: 4, hasMore: false, totalMessages: 6 } },
  'present-anchor-centered': { messages: [messages[1], messages[2], messages[3]], bytes: 425 },
  'present-anchor-limit-one': { messages: [messages[2]], bytes: 141 },
  'present-anchor-near-start': { messages: [messages[0], messages[1], messages[2]], bytes: 389 },
  'tools-default-absent': { messages: [messages[0], toolCall, messages[3]], bytes: 466,
    pagination: { offset: 0, nextOffset: 4, hasMore: true, totalMessages: 6 } },
  'tools-include-true': { messages: [messages[0], toolCall, toolResult, messages[3]], bytes: 663,
    pagination: { offset: 0, nextOffset: 4, hasMore: true, totalMessages: 6 } },
  'queued-pending-page': { messages: [messages[4], messages[5]], bytes: 428, pendingInputs: queuedPending },
  'session-link': { messages: [messages[4], messages[5]], bytes: 271, sessionLinkRule: linkRule },
};
const observed = await captureSessionHistoryWindow();
const byId = id => observed.observations.find(row => row.id === id);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

test('complete source factory has literal ordinary messages, byte counts and pagination metadata', () => {
  assert.deepEqual(observed.observations.map(row => row.id), Object.keys(expected));
  for (const row of observed.observations) {
    const expectation = expected[row.id];
    const details = { sessionKey: 'agent:main:history291', messages: expectation.messages,
      truncated: false, droppedMessages: false, contentTruncated: false, contentRedacted: false,
      bytes: expectation.bytes, pendingInputs: expectation.pendingInputs ?? emptyPending,
      ...(expectation.sessionLinkRule ? { sessionLinkRule: expectation.sessionLinkRule } : {}),
      ...expectation.pagination };
    assert.deepEqual(row.result, { content: [{ type: 'text', text: JSON.stringify(details, null, 2) }], details }, row.id);
    assert.deepEqual(row.argumentsAfter, row.args, row.id);
  }
});

test('source kernel limits tail, removes an ordinary offset context row and prepares complete pages', () => {
  const kernelExpected = {
    'default-tail': { ids: ['message-1', 'message-2', 'message-3', 'message-4', 'message-5', 'message-6'], bytes: 761,
      raw: 6, offset: 0, hasMore: false, activeLeaf: true },
    'explicit-tail-limit': { ids: ['message-5', 'message-6'], bytes: 249,
      raw: 6, offset: 0, nextOffset: 2, hasMore: true, activeLeaf: true },
    'offset-zero': { ids: ['message-5', 'message-6'], bytes: 249,
      raw: 6, offset: 0, nextOffset: 2, hasMore: true, activeLeaf: true, responseOffset: 0 },
    'older-offset': { ids: ['message-3', 'message-4'], bytes: 265,
      raw: 2, offset: 2, nextOffset: 4, hasMore: true, responseOffset: 2 },
    'oldest-offset': { ids: ['message-1', 'message-2'], bytes: 249,
      raw: 2, offset: 4, hasMore: false, responseOffset: 4 },
    'queued-pending-page': { ids: ['message-5', 'message-6'], bytes: 249,
      raw: 6, offset: 0, nextOffset: 2, hasMore: true, activeLeaf: true },
    'session-link': { ids: ['message-5', 'message-6'], bytes: 249,
      raw: 6, offset: 0, nextOffset: 2, hasMore: true, activeLeaf: true },
  };
  for (const [id, expectation] of Object.entries(kernelExpected)) {
    const row = byId(id);
    const selected = expectation.ids.map(messageId => messages.find(message => message.__openclaw.id === messageId));
    assert.deepEqual(row.kernelPage, {
      ...(expectation.activeLeaf ? { activeLeafEntryId: null } : {}), messages: selected,
      ...(expectation.responseOffset === undefined ? {} : { responseOffset: expectation.responseOffset }),
      pagination: { offset: expectation.offset, totalMessages: 6, rawPageMessages: expectation.raw },
    }, id);
    assert.deepEqual(row.preparedPage, { messages: selected, messagesBytes: expectation.bytes, responseHistoryBytes: 1048576,
      ...(expectation.nextOffset === undefined ? {} : { nextOffset: expectation.nextOffset }),
      hasMore: expectation.hasMore, totalMessages: 6 }, id);
  }
});

test('present anchors preserve source-centered reader pages and suppress redundant offset dispatch', () => {
  const vectors = [
    ['present-anchor-centered', 'message-3', 3, [messages[1], messages[2], messages[3]], 403],
    ['present-anchor-limit-one', 'message-3', 1, [messages[2]], 119],
    ['present-anchor-near-start', 'message-1', 3, [messages[0], messages[1], messages[2]], 367],
  ];
  const source = createHash('sha256').update('["supplied-history291"]').digest('base64url');
  for (const [id, messageId, max, selected, bytes] of vectors) {
    const row = byId(id);
    assert.deepEqual(row.gatewayCalls, [{ method: 'chat.history', params: {
      sessionKey: 'agent:main:history291', agentId: 'main', limit: max, messageId,
      ...(id === 'present-anchor-centered' ? { sessionId: 'transcript-history291' } : {}),
    } }]);
    assert.deepEqual(row.readerCalls, [{ operation: 'around', scope: { agentId: 'main', sessionId: 'transcript-history291',
      sessionKey: 'agent:main:history291', storePath: 'supplied:history291' },
    options: { messageId, maxMessages: max, allowResetArchiveFallback: true, readOnly: true } }]);
    assert.deepEqual(row.kernelPage, { messages: selected, anchor: { sessionId: 'transcript-history291', source,
      hasOlder: id !== 'present-anchor-near-start', hasNewer: true,
      oldestMessageId: selected[0].__openclaw.id, newestMessageId: selected.at(-1).__openclaw.id } }, id);
    const cursor = (anchor, direction) => 'history-page:' + Buffer.from(JSON.stringify({
      sessionId: 'transcript-history291', source, messageId: anchor, direction,
    })).toString('base64url');
    assert.deepEqual(row.preparedPage, { messages: selected, messagesBytes: bytes, responseHistoryBytes: 1048576,
      ...(id === 'present-anchor-near-start' ? {} : { olderCursor: cursor(selected[0].__openclaw.id, 'older') }),
      newerCursor: cursor(selected.at(-1).__openclaw.id, 'newer') }, id);
  }
});

test('actual common parameters and gateway requests retain only the ordinary requested fields', () => {
  const requests = {
    'default-tail': {}, 'explicit-tail-limit': { limit: 2 }, 'offset-zero': { limit: 2, offset: 0 },
    'older-offset': { limit: 2, offset: 2 }, 'oldest-offset': { limit: 2, offset: 4 },
    'tools-default-absent': { limit: 4, offset: 0 }, 'tools-include-true': { limit: 4, offset: 0 },
    'queued-pending-page': { limit: 2, pendingBefore: 1700000000101 }, 'session-link': { limit: 2 },
  };
  for (const [id, params] of Object.entries(requests)) assert.deepEqual(byId(id).gatewayCalls,
    [{ method: 'chat.history', params: { sessionKey: 'agent:main:history291', agentId: 'main', ...params } }], id);
  const scope = { agentId: 'main', sessionId: 'transcript-history291', sessionKey: 'agent:main:history291', storePath: 'supplied:history291' };
  assert.deepEqual(byId('offset-zero').readerCalls, [{ operation: 'recent', scope, options: {
    maxMessages: 7, maxLines: 7, maxBytes: 1048576, allowResetArchiveFallback: true, captureReadWindow: true, readOnly: true,
  } }]);
  assert.deepEqual(byId('older-offset').readerCalls, [{ operation: 'page', scope, options: {
    offset: 2, maxMessages: 3, maxBytes: 1048576, allowOversizedFirst: true,
    allowResetArchiveFallback: true, captureReadWindow: true, readOnly: true,
  } }]);
  assert.deepEqual(byId('tools-default-absent').readerCalls, []);
  assert.deepEqual(byId('tools-include-true').readerCalls, []);
});

test('the real TypeBox factory declares the complete original parameters and output contract', () => {
  const pendingSchema = { type: 'object', properties: { items: { type: 'array', items: { type: 'object', properties: {
    id: { type: 'string', minLength: 1 }, runId: { type: 'string', minLength: 1, maxLength: 256 }, message: {},
    acceptedAt: { type: 'number' }, state: { type: 'string', enum: ['queued', 'cancelled', 'interrupted'] },
    queued: { const: true, type: 'boolean' },
  }, required: ['id', 'message', 'acceptedAt', 'state'], additionalProperties: false }, maxItems: 20 },
  total: { type: 'integer', minimum: 0 }, queuedCount: { type: 'integer', minimum: 0 }, nextBefore: { type: 'integer', minimum: 1 } },
  required: ['items', 'total'], additionalProperties: false };
  const parameters = { type: 'object', properties: {
    user: { type: 'string', description: "An admitted participant's requester_profile.id. Omit to use the turn's original requester; selection does not establish human intent or approval." },
    sessionKey: { type: 'string', minLength: 1 }, limit: { type: 'integer', minimum: 1, maximum: 1000 },
    offset: { type: 'integer', minimum: 0, description: 'Plain-pagination offset. Ignored when messageId is set; limit still bounds anchored history.' },
    pendingBefore: { type: 'integer', minimum: 1 }, messageId: { type: 'string', minLength: 1,
      description: 'Return history around this message id. Ignores offset; limit bounds the window.' },
    sessionId: { type: 'string', minLength: 1,
      description: 'Transcript session id that owns messageId. Requires messageId; omit for the latest tail.' },
    includeTools: { type: 'boolean' },
  }, required: ['sessionKey'] };
  const outputSchema = { anyOf: [
    { type: 'object', properties: { sessionKey: { type: 'string' }, messages: { type: 'array', items: {} },
      truncated: { type: 'boolean' }, droppedMessages: { type: 'boolean' }, contentTruncated: { type: 'boolean' },
      contentRedacted: { type: 'boolean' }, bytes: { type: 'number' },
      sessionLinkRule: { type: 'string', description: 'How to build Control UI URLs for sessionKey values in this result.' },
      offset: { type: 'number' }, nextOffset: { type: 'number' }, hasMore: { type: 'boolean' }, totalMessages: { type: 'number' },
      windowReset: { type: 'boolean' }, pendingInputs: pendingSchema },
    required: ['sessionKey', 'messages', 'truncated', 'droppedMessages', 'contentTruncated', 'contentRedacted', 'bytes'], additionalProperties: false },
    { type: 'object', properties: { status: { anyOf: [{ const: 'error', type: 'string' }, { const: 'forbidden', type: 'string' }] },
      error: { type: 'string' } }, required: ['status', 'error'], additionalProperties: false },
  ] };
  const description = 'Read sanitized visible-session history. Before reply/debug/resume. Use messageId for anchored history; sessionId selects its transcript and requires messageId. Omit both for the latest tail. offset pages unanchored history and is ignored with messageId. limit bounds either mode. Include tool messages with includeTools. pendingInputs are accepted inputs outside model history; page with pendingBefore=nextBefore. Cancelled inputs never replay; interrupted means saved without an active retry. Eligible durable peer sends can regain queued custody on startup. Lower limit for richer pending previews.';
  for (const row of observed.observations) assert.deepEqual(row.definition, {
    name: 'sessions_history', label: 'Session History', displaySummary: 'Read sanitized session history.',
    description: description + (row.id === 'session-link' ? ' ' + linkRule : ''),
    parameters, outputSchema, executePresent: true,
  }, row.id);
});

test('supplied host services and reader ownership are explicit and never reported as native admission', () => {
  assert.deepEqual(observed.boundaries, { actualFactory: true, actualTypeBox: true, actualProtocolSchemas: true,
    actualCommonParameterHelpers: true, actualJsonResult: true, actualKernel: true, actualPrepareResponse: true,
    actualStripToolMessages: true, actualDisplayProjection: true, actualHistorySanitizer: true,
    originalReaderExecuted: false, originalGatewayRouterExecuted: false, originalPersonalCallerWrapperExecuted: false,
    assemblyExecuted: false, eligibilityExecuted: false, authorityExecuted: false, persistenceExecuted: false,
    liveReaderExecuted: false, networkExecuted: false, productionModulesExecuted: false });
  for (const row of observed.observations) {
    const scoped = row.serviceCalls.filter(call => call.name === 'runWithScopedSessionAccess');
    assert.deepEqual(scoped, [{ name: 'runWithScopedSessionAccess', args: { cfg: {}, agentId: 'main',
      expectedSessionId: 'transcript-history291', targetSessionKey: 'agent:main:history291' } }], row.id);
    assert.equal(row.serviceCalls.filter(call => call.name === 'wrapped.execute').length, 1);
    assert.equal(row.serviceCalls.filter(call => call.name === 'visibility.check').length, 1);
  }
  assert.deepEqual(observed.deferredCalls, []);
  assert.equal(observed.suppliedHostServices.sha256, sha256(observed.suppliedHostServices.code));
  assert.equal(observed.suppliedReaderCode.sha256, sha256(observed.suppliedReaderCode.code));
});

test('the complete pinned checkout, exact original regions and actual package bytes have reproducible provenance', () => {
  assert.equal(observed.referencePin, SESSION_HISTORY_WINDOW_PIN);
  assert.deepEqual(observed.sourceTree.before, observed.sourceTree.after);
  assert.equal(observed.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.equal(observed.sourceTree.before.tree, '47509a47273231ab15f57252960fe716d7379ffb');
  assert.equal(observed.sourceTree.before.trackedClean, true);
  for (const file of [
    'src/agents/tools/sessions-history-tool.ts', 'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts',
    'packages/gateway-protocol/src/schema/logs-chat.ts', 'src/agents/schema/typebox.ts',
  ]) {
    const row = observed.sourceRecords.find(row => row.path === file);
    assert.equal(row.wholeModule, true, file);
    assert.equal(row.originalSourceExecuted, true, file);
  }
  for (const file of [
    'src/gateway/server-methods/chat-history-page-kernel.ts', 'src/gateway/server-methods/chat-history-response-page.ts',
    'src/agents/tools/chat-history-text.ts', 'src/gateway/session-utils.fs.ts',
  ]) {
    const row = observed.sourceRecords.find(row => row.path === file);
    assert.equal(row.kind, 'exact-source-regions', file);
    assert.ok(row.regions.length > 0, file);
  }
  for (const row of observed.sourceRecords) {
    const bytes = readFileSync('/tmp/openclaw-488631c/' + row.path);
    assert.equal(sha256(bytes), row.sha256, row.path);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), row.gitBlob, row.path);
    for (const region of row.regions ?? []) assert.equal(sha256(bytes.subarray(region.startByte, region.endByte)), region.sha256, row.path);
  }
  assert.equal(observed.typebox.version, '1.3.37');
  assert.ok(observed.typebox.files.length > 1);
  for (const row of observed.typebox.files) assert.equal(sha256(readFileSync(join(observed.typebox.root, row.path.slice('typebox/'.length)))), row.sha256);
  for (const pkg of observed.npm.packages) for (const row of pkg.files) {
    const bytes = readFileSync(new URL('../../packages/tool-host/src/session-directory/vendor/node_modules/' + pkg.packageName + '/' + row.path, import.meta.url));
    assert.equal(bytes.length, row.bytes, row.path);
    assert.equal(sha256(bytes), row.sha256, row.path);
  }
  for (const row of observed.importBindings) if (row.generatedCode) assert.equal(sha256(row.generatedCode), row.generatedSha256);
  assert.equal(observed.exporter.sha256, sha256(readFileSync(new URL('./capture-session-history-window.mjs', import.meta.url))));
});

test('offline ordinary capture equals the checked-in golden without rewriting it', () => {
  const golden = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/session-history-window.json', import.meta.url)));
  assert.deepEqual(observed, golden);
});
