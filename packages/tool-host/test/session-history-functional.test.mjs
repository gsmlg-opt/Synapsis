// Ordinary positive internal-history contract at OpenClaw 488631c.
// Real packaged helper/worker and stdio; no reference checkout, TS loader or oracle.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const fixtureBytes = readFileSync(new URL('./fixtures/session-history-protocol.json', import.meta.url));
const fixture = JSON.parse(fixtureBytes);
const { referenceCommit: PIN, limits } = fixture;
const helperPath = fileURLToPath(new URL('../src/session-directory/helper.mjs', import.meta.url));
const runtime = fixture.runtime;
const historyEnvelope = type => ({ type, protocol: 1, historyProtocol: 1 });
const uuid = ordinal => `4b5d9494-8241-4f03-936c-${String(ordinal).padStart(12, '0')}`;
const message = (ordinal, role, content, extra = {}) => ({
  role,
  timestamp: `2026-11-06T00:${String(Math.floor(ordinal / 60)).padStart(2, '0')}:${String(ordinal % 60).padStart(2, '0')}.000Z`,
  content: typeof content === 'string' ? [{ type: 'text', text: content }] : content,
  ...extra,
  __openclaw: { seq: ordinal, id: uuid(ordinal) },
});
const rowsFor = messages => messages.map((value, index) => ({ index: index * 7, ordinal: index + 1, message: value }));
const rowFragment = row => JSON.stringify(row, null, 2).split('\n').map(line => '    ' + line).join('\n');

function launch(t) {
  const child = spawn(process.execPath, [helperPath, '--timeout-ms=20000'], { stdio: ['pipe', 'pipe', 'pipe'] });
  const frames = [], incoming = [], outgoing = [], receivedTransfers = [], sentTransfers = [];
  let waiter, ended, pending = Buffer.alloc(0), transfer, stderr = '';
  const stop = error => {
    ended ??= error;
    if (waiter) {
      const current = waiter;
      waiter = undefined;
      clearTimeout(current.timer);
      current.reject(error);
    }
  };
  const deliver = frame => {
    if (waiter) {
      const current = waiter;
      waiter = undefined;
      clearTimeout(current.timer);
      current.resolve(frame);
    } else frames.push(frame);
  };
  const write = frame => new Promise((resolve, reject) => {
    const line = JSON.stringify(frame) + '\n';
    assert.ok(Buffer.byteLength(line) <= limits.wireMaxBytes, 'every outgoing wire line includes LF in its bound');
    outgoing.push(frame);
    child.stdin.write(line, error => error ? reject(error) : resolve());
  });
  const acknowledge = frame => { void write(frame).catch(stop); };
  child.stdout.on('data', chunk => {
    try {
      pending = Buffer.concat([pending, chunk]);
      let newline;
      while ((newline = pending.indexOf(10)) !== -1) {
        const bytes = pending.subarray(0, newline);
        pending = pending.subarray(newline + 1);
        assert.ok(bytes.length + 1 <= limits.wireMaxBytes, 'every incoming wire line includes LF in its bound');
        const frame = JSON.parse(bytes.toString('utf8'));
        incoming.push(frame);
        if (frame.type === 'history_transfer_start') {
          assert.equal(transfer, undefined);
          assert.equal(frame.protocol, 1);
          assert.equal(frame.historyProtocol, 1);
          assert.equal(frame.logicalType, 'history_result');
          assert.ok(frame.bytes > limits.wireMaxBytes - 1 && frame.bytes <= limits.logicalTransferMaxBytes);
          transfer = { ...frame, chunks: [], sequence: 0 };
          acknowledge({ ...historyEnvelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: 0 });
        } else if (frame.type === 'history_transfer_chunk') {
          assert.equal(frame.transferId, transfer.transferId);
          assert.equal(frame.sequence, transfer.sequence);
          const bytes = Buffer.from(frame.data, 'base64');
          assert.ok(bytes.length > 0 && bytes.length <= limits.rawChunkMaxBytes);
          transfer.chunks.push(bytes);
          transfer.sequence += 1;
          acknowledge({ ...historyEnvelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: transfer.sequence });
        } else if (frame.type === 'history_transfer_end') {
          assert.equal(frame.transferId, transfer.transferId);
          const bytes = Buffer.concat(transfer.chunks);
          assert.equal(bytes.length, transfer.bytes);
          const logical = JSON.parse(bytes.toString('utf8'));
          assert.equal(logical.type, transfer.logicalType);
          receivedTransfers.push({ bytes: bytes.length, chunks: transfer.sequence, logicalType: logical.type });
          acknowledge({ ...historyEnvelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: transfer.sequence, complete: true });
          transfer = undefined;
          deliver(logical);
        } else deliver(frame);
      }
    } catch (error) { stop(error); }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.once('error', stop);
  child.stdin.on('error', stop);
  const exited = new Promise(resolve => child.once('close', (code, signal) => {
    stop(new Error(`History helper closed with code=${code}, signal=${signal}; ${stderr}`));
    resolve({ code, signal });
  }));
  const next = () => {
    if (frames.length) return Promise.resolve(frames.shift());
    if (ended) return Promise.reject(ended);
    assert.equal(waiter, undefined, 'one outstanding read in this sequential protocol driver');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => stop(new Error('Timed out waiting for an ordinary helper frame')), 10_000);
      waiter = { resolve, reject, timer };
    });
  };
  let transferNumber = 0;
  const send = async frame => {
    const bytes = Buffer.from(JSON.stringify(frame));
    if (bytes.length + 1 <= limits.wireMaxBytes) return write(frame);
    assert.ok(bytes.length <= limits.logicalTransferMaxBytes);
    const transferId = `host-transfer-${++transferNumber}`;
    const ack = async (nextSequence, complete = false) => {
      assert.deepEqual(await next(), {
        ...historyEnvelope('history_transfer_ack'), transferId, nextSequence, ...(complete ? { complete: true } : {}),
      });
    };
    await write({ ...historyEnvelope('history_transfer_start'), transferId, logicalType: frame.type, bytes: bytes.length });
    await ack(0);
    let sequence = 0;
    for (let offset = 0; offset < bytes.length; offset += limits.rawChunkMaxBytes) {
      await write({ ...historyEnvelope('history_transfer_chunk'), transferId, sequence,
        data: bytes.subarray(offset, offset + limits.rawChunkMaxBytes).toString('base64') });
      sequence += 1;
      await ack(sequence);
    }
    await write({ ...historyEnvelope('history_transfer_end'), transferId });
    await ack(sequence, true);
    sentTransfers.push({ bytes: bytes.length, chunks: sequence, logicalType: frame.type });
  };
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await exited;
  });
  return {
    next, send, incoming, outgoing, sentTransfers, receivedTransfers,
    async ready() {
      assert.deepEqual(await next(), { type: 'ready', protocol: 1, referenceCommit: PIN });
    },
    async close() {
      await send({ type: 'close', protocol: 1 });
      assert.deepEqual(await next(), { type: 'closed', protocol: 1, runtime: { ...runtime, workerExitObserved: true } });
      assert.deepEqual(await exited, { code: 0, signal: null });
      assert.equal(pending.length, 0);
      assert.equal(transfer, undefined);
      assert.equal(stderr, '');
    },
  };
}

async function history(host, rows, { id = 'h1', row = fixture.historyStart.row, limit = 2, literal = false } = {}) {
  const start = { ...structuredClone(fixture.historyStart), id, row,
    snapshot: { viewId: fixture.historyStart.snapshot.viewId, totalTurns: rows.length }, limit };
  const before = structuredClone(rows);
  const requests = [], readIds = new Set();
  await host.send(start);
  for (;;) {
    const frame = await host.next();
    if (frame.type === 'history_result') {
      assert.equal(frame.protocol, fixture.protocol);
      assert.equal(frame.historyProtocol, fixture.historyProtocol);
      assert.equal(frame.id, id);
      assert.equal(frame.slot, start.target.slot);
      assert.equal(frame.referenceCommit, PIN);
      assert.deepEqual(frame.runtime, runtime);
      assert.deepEqual(rows, before, 'raw content, positions and EventReply sidecars remain caller-owned');
      return { candidate: frame.candidate, requests, start };
    }
    assert.equal(frame.type, 'history_read');
    assert.equal(frame.protocol, fixture.protocol);
    assert.equal(frame.historyProtocol, fixture.historyProtocol);
    assert.equal(frame.id, id);
    assert.equal(frame.slot, start.target.slot);
    assert.ok(typeof frame.readId === 'string' && frame.readId.length > 0 && !readIds.has(frame.readId));
    readIds.add(frame.readId);
    const options = frame.options;
    if (!requests.length) {
      assert.equal(frame.operation, 'recent');
      assert.deepEqual(options, { ...fixture.initialRead.options, maxMessages: 3 * limit + 1, maxLines: 3 * limit + 1 });
      if (literal) assert.deepEqual(frame, fixture.initialRead);
    } else {
      assert.equal(frame.operation, 'page');
      assert.deepEqual(options.expectedReadWindow, { source: start.snapshot.viewId, latestResetRawSeq: null });
      assert.equal(options.beforeSeq, rows.length + 1);
      assert.equal(options.readOnly, true);
      assert.equal(options.allowResetArchiveFallback, true);
      assert.equal(options.allowOversizedFirst, true);
      assert.equal(options.maxBytes, fixture.initialRead.options.maxBytes);
      assert.ok(options.maxMessages <= limits.sourceLogicalPageMaxRecords);
    }
    const end = Math.max(0, Math.min(rows.length, options.beforeSeq === undefined ? rows.length : options.beforeSeq - 1) - (options.offset ?? 0));
    const selected = rows.slice(Math.max(0, end - options.maxMessages), end);
    assert.ok(Buffer.byteLength(JSON.stringify(selected.map(value => value.message))) <= options.maxBytes);
    const reply = { ...historyEnvelope('history_read_result'), id, readId: frame.readId, slot: start.target.slot,
      viewId: start.snapshot.viewId, totalTurns: rows.length, rows: selected };
    if (literal) assert.deepEqual(reply, fixture.readResult);
    requests.push({ request: frame, ordinals: selected.map(value => value.ordinal), indexes: selected.map(value => value.index) });
    await host.send(reply);
  }
}

function assertCandidate(candidate, row, expectedMessages) {
  assert.deepEqual(candidate.messages, expectedMessages);
  for (const [name, value] of [['enriched', { ...row, messages: expectedMessages }], ['metadata', row]]) {
    const expected = rowFragment(value);
    assert.deepEqual(candidate[name], { kind: 'json', json: expected, utf8Bytes: Buffer.byteLength(expected) });
    assert.ok(candidate[name].utf8Bytes <= limits.enrichedFragmentMaxBytes);
    assert.equal(candidate[name].json.endsWith('\n'), false);
  }
}

test('literal history protocol preserves UUIDs and source row bytes between two legacy projection waves', { timeout: 30_000 }, async t => {
  assert.equal(createHash('sha256').update(fixtureBytes).digest('hex'), '5e1c5da14c3fc5c1f7c03a6cbc8ce9119ee71e7bbe834c5dfe04f69bbf247631');
  const host = launch(t);
  await host.ready();
  const project = async id => {
    await host.send({ type: 'project', protocol: 1, id, rows: [{ entry: { sessionId: fixture.historyStart.target.sessionId, label: 'Saved report' } }], options: { includeDerivedTitles: true } });
    assert.deepEqual(await host.next(), { type: 'result', protocol: 1, id, referenceCommit: PIN,
      result: [{ derivedTitle: 'Saved report', needsHead: false, needsTail: false }], runtime });
  };
  await project('legacy-before');
  const result = await history(host, structuredClone(fixture.readResult.rows), { literal: true });
  assertCandidate(result.candidate, fixture.historyStart.row, fixture.readResult.rows.map(value => value.message));
  assert.equal(result.requests.length, 1);
  await project('legacy-after');
  await host.close();
});

test('successful tool-role history retains call arguments and source activity before exact postfilter without backfill', { timeout: 30_000 }, async t => {
  const args = { path: 'reports/会議.md', range: { start: 2, end: 8 }, tags: ['current', 'published'] };
  const call = message(2, 'assistant', [{ type: 'text', text: 'Reading the published report.' },
    { type: 'toolCall', id: 'call-report', name: 'read_file', arguments: args }]);
  const receipt = message(3, 'toolResult', [{ type: 'text', text: 'Report body: 完了\nsecond line' }], {
    toolCallId: 'call-report', toolName: 'read_file', isError: false, details: { status: 'completed' },
  });
  const messages = [message(1, 'user', 'Read the published report.'), call, receipt, message(4, 'assistant', 'The report is current.')];
  const host = launch(t);
  await host.ready();
  const result = await history(host, rowsFor(messages), { limit: 3 });
  assertCandidate(result.candidate, fixture.historyStart.row, [call, messages[3]]);
  assert.deepEqual(result.candidate.messages[0].content[1].arguments, args);
  assert.equal(result.candidate.messages.length, 2, 'postfilter removes the result after the source three-row suffix; no older user backfill');

  // Observe activity on the actual packaged source APIs. The private wire result
  // deliberately contains messages and row fragments, not this source-only field.
  const { projectChatDisplayMessagesWithState } = await import('../src/session-directory/vendor/openclaw/src/gateway/chat-display-projection.core.mjs');
  const { prepareChatHistoryResponsePage } = await import('../src/session-directory/vendor/openclaw/src/gateway/server-methods/chat-history-response-page.mjs');
  const projection = projectChatDisplayMessagesWithState(messages, { includeCommentaryFallbacks: true, maxChars: 8000 });
  const prepared = prepareChatHistoryResponsePage(projection, { maxHistoryBytes: 1048576 });
  assert.ok(prepared.activity.length >= 2);
  for (const id of [call.__openclaw.id, receipt.__openclaw.id]) {
    const activity = prepared.activity.find(value => value.messageId === id);
    assert.ok(activity, 'activity retains the actual durable message UUID');
    assert.equal(activity.items.length, 1);
    assert.equal(activity.items[0].toolCallId, 'call-report');
    assert.equal(activity.items[0].name, 'read_file');
    assert.equal(activity.items[0].status, 'completed');
  }
  assert.equal(prepared.messages.find(value => value.__openclaw.id === receipt.__openclaw.id).content[0].text, receipt.content[0].text);
  await host.close();
});

test('legacy user tool-result blocks preserve their actual user role and public result details', { timeout: 30_000 }, async t => {
  const output = { type: 'tool_result', tool_use_id: 'legacy-report', is_error: false,
    content: [{ type: 'text', text: 'Published: reports/会議.md' }], details: { exitCode: 0, durationMs: 18, ok: true } };
  const messages = [message(1, 'user', 'Publish the report.'),
    message(2, 'assistant', [{ type: 'text', text: 'Publishing the report.' },
      { type: 'tool_use', id: 'legacy-report', name: 'publish_report', input: { title: '会議', format: 'markdown' } }]),
    message(3, 'user', [output]), message(4, 'assistant', 'Published.')];
  const host = launch(t);
  await host.ready();
  const result = await history(host, rowsFor(messages));
  assertCandidate(result.candidate, fixture.historyStart.row, messages.slice(-2));
  assert.equal(result.candidate.messages[0].role, 'user');
  assert.deepEqual(result.candidate.messages[0].content[0], output);
  await host.close();
});

test('genuine EventReply display sidecars affect visibility before fullness while raw text and ordinal windows remain intact', { timeout: 30_000 }, async t => {
  const messages = [message(1, 'user', 'Show the ordinary event report.'),
    message(2, 'assistant', 'HEARTBEAT_OK\nEvent report ready.'),
    ...Array.from({ length: 8 }, (_, index) => message(index + 3, 'assistant', 'HEARTBEAT_OK'))];
  const rows = rowsFor(messages);
  rows[1].eventReply = { version: 1, policy: 'manual_event_message', hidden: false,
    textOverrides: [{ blockIndex: 0, text: 'Event report ready.' }] };
  for (const row of rows.slice(2)) row.eventReply = { version: 1, policy: 'manual_event_message', hidden: true,
    textOverrides: [{ blockIndex: 0, text: '' }] };
  const host = launch(t);
  await host.ready();
  const result = await history(host, rows);
  const displayed = { ...messages[1], content: [{ type: 'text', text: 'Event report ready.' }] };
  assertCandidate(result.candidate, fixture.historyStart.row, [messages[0], displayed]);
  assert.ok(result.requests.length > 1, 'hidden genuine replies do not prematurely satisfy N');
  assert.equal(rows[1].message.content[0].text, 'HEARTBEAT_OK\nEvent report ready.');
  assert.equal(Object.hasOwn(result.candidate.messages[1], 'phase'), false);
  assert.equal(Object.hasOwn(result.candidate.messages[1], 'openclawDisplayContent'), false);
  await host.close();
});

test('sparse visible history uses repeated complete older windows and acknowledged large transfers in both directions', { timeout: 30_000 }, async t => {
  const messages = [message(1, 'user', 'Review the complete report.'), message(2, 'assistant', 'The report is ready.'),
    ...Array.from({ length: 180 }, (_, index) => message(index + 3, 'assistant', 'NO_REPLY', { providerMetadata: { trace: 'ordinary trace '.repeat(70) } }))];
  const rows = rowsFor(messages);
  const row = { ...fixture.historyStart.row, title: '会議'.repeat(9500) };
  const host = launch(t);
  await host.ready();
  for (const id of ['large-history-one', 'large-history-two']) {
    const result = await history(host, rows, { id, row });
    assertCandidate(result.candidate, row, messages.slice(0, 2));
    assert.deepEqual(result.requests.map(value => value.request.operation), ['recent', 'page', 'page']);
    assert.deepEqual(result.requests.map(value => value.request.options.offset ?? 0), [0, 6, 60]);
    assert.deepEqual(result.requests.map(value => value.request.options.maxMessages), [7, 55, 201]);
    for (const value of result.requests) assert.deepEqual(value.indexes, value.ordinals.map(ordinal => (ordinal - 1) * 7));
    assert.equal(result.requests[0].ordinals[0], result.requests[1].ordinals.at(-1), 'older reader pages retain the real overlapping context ordinal');
  }
  assert.ok(host.sentTransfers.some(value => value.logicalType === 'history_read_result' && value.chunks > 1));
  assert.equal(host.receivedTransfers.filter(value => value.logicalType === 'history_result').length, 2);
  assert.ok(host.receivedTransfers.every(value => value.chunks > 1));
  await host.close();
});
