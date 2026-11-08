import { readChatHistoryPageKernel } from './vendor/openclaw/src/gateway/server-methods/chat-history-page-kernel.mjs';
import { prepareChatHistoryResponsePage } from './vendor/openclaw/src/gateway/server-methods/chat-history-response-page.mjs';
import { stripToolMessages } from './vendor/openclaw/src/agents/tools/chat-history-text.mjs';
import { sanitizeHistoryMessage, boundPendingInputs, enforceSessionsHistoryHardCap,
  capSessionsHistoryAroundMessage, resolveSessionsHistoryPaginationMetadata,
  SESSIONS_HISTORY_MAX_BYTES } from './vendor/openclaw/src/agents/tools/sessions-history-tool.mjs';
import { jsonResult } from './vendor/openclaw/src/agents/tools/tool-results.mjs';
import { capArrayByJsonBytes } from './vendor/openclaw/src/gateway/session-utils.fs.mjs';
import { jsonUtf8Bytes } from './vendor/openclaw/src/infra/json-utf8-bytes.mjs';
import { resolveHistoryAnchorPageRange } from './vendor/openclaw/src/sessions/transcript-anchor-page.mjs';
import { projectChatDisplayMessage } from './vendor/openclaw/src/gateway/chat-display-projection.core.mjs';
import { replaceOversizedChatHistoryMessages } from './vendor/openclaw/src/gateway/server-methods/chat-history-budget.mjs';
import { withUserPathBaseDirectory } from './vendor/openclaw/src/infra/home-dir.mjs';
import { beginHistoryTarget, endHistoryTarget, registerEventReplies, REFERENCE_COMMIT } from './host-history-services.mjs';

const PAGE_BYTES = 1024 * 1024;
const TRANSFER_BYTES = 8 * PAGE_BYTES;

// Host orchestration is explicit: genuine captured UUID/ordinal and pending
// custody facts replace source gateway identity/storage services. All selected
// source computation declarations execute unchanged in their original order.
export async function projectStandaloneHistory(start, requestReader, view) {
  const { id, target, snapshot, input, pendingInputs } = start;
  const max = input?.limit ?? 200;
  if (start.mode !== 'standalone' || !target || typeof target.slot !== 'string' || !target.slot ||
      typeof target.sessionId !== 'string' || !target.sessionId || !snapshot ||
      typeof snapshot.viewId !== 'string' || !snapshot.viewId ||
      !Number.isSafeInteger(snapshot.totalTurns) || snapshot.totalTurns < 0 ||
      !Number.isInteger(max) || max < 1 || max > 1000 || !pendingInputs ||
      !Array.isArray(pendingInputs.items)) throw new Error('history_start');
  const readWindow = Object.freeze({ source: snapshot.viewId, latestResetRawSeq: null });
  const storePath = 'synapsis:history-view:' + snapshot.viewId;
  const scopeValid = scope => {
    if (scope.storePath !== storePath || scope.sessionId !== target.sessionId ||
        scope.agentId !== target.agentId) throw new Error('history_read_scope');
  };
  const request = async (operation, options) => {
    if (options.expectedReadWindow &&
        JSON.stringify(options.expectedReadWindow) !== JSON.stringify(readWindow)) throw new Error('history_read_window');
    const reply = await requestReader(operation, options);
    if (reply.id !== id || reply.slot !== target.slot || reply.viewId !== snapshot.viewId ||
        reply.totalTurns !== snapshot.totalTurns || !Array.isArray(reply.rows)) throw new Error('history_reader_admission');
    for (let index = 0; index < reply.rows.length; index++) {
      const row = reply.rows[index];
      if (!Number.isSafeInteger(row.index) || row.index < 0 || !Number.isSafeInteger(row.ordinal) ||
          row.ordinal < 1 || row.ordinal > snapshot.totalTurns || row.message?.__openclaw?.seq !== row.ordinal ||
          index > 0 && (row.ordinal !== reply.rows[index - 1].ordinal + 1 || row.index <= reply.rows[index - 1].index)) {
        throw new Error('history_reader_admission');
      }
    }
    registerEventReplies(reply.rows);
    return reply;
  };
  const range = async (first, end) => {
    if (end === first) return [];
    const reply = await request('range', { start: first, endExclusive: end });
    if (reply.rows.length !== end - first || reply.rows[0]?.ordinal !== first + 1 ||
        reply.rows.at(-1)?.ordinal !== end) throw new Error('history_reader_admission');
    return reply.rows;
  };
  const result = rows => ({ messages: rows.map(row => row.message), totalMessages: snapshot.totalTurns,
    displaySource: snapshot.viewId, readWindow });
  const read = async (scope, operation, options) => {
    scopeValid(scope);
    // Preserve the source-visible Number offset; only the private physical
    // reader request is clamped to an exact, bounded integer index.
    const effective = { ...options,
      ...(options.offset === undefined ? {} : { offset: Math.min(snapshot.totalTurns, options.offset) }),
      ...(options.beforeSeq === undefined ? {} : { beforeSeq: Math.min(snapshot.totalTurns + 1, options.beforeSeq) }) };
    const reply = await request(operation, effective);
    const end = Math.max(0, Math.min(snapshot.totalTurns,
      effective.beforeSeq === undefined ? snapshot.totalTurns : effective.beforeSeq - 1) - (effective.offset ?? 0));
    const first = Math.max(0, end - options.maxMessages);
    if (reply.rows.length !== end - first || reply.rows.length && reply.rows[0].ordinal !== first + 1) {
      throw new Error('history_reader_admission');
    }
    const page = result(reply.rows);
    if (jsonUtf8Bytes(page.messages) > options.maxBytes || options.maxBytes > TRANSFER_BYTES) throw new Error('history_reader_admission');
    return page;
  };
  const lookup = async (scope, operation, messageId, options) => {
    scopeValid(scope);
    const reply = await request(operation, { ...options, messageId });
    if (typeof reply.found !== 'boolean' || reply.rows.length > 2 ||
        reply.found !== (reply.rows.length > 0) ||
        reply.found && reply.rows.at(-1).message.__openclaw.id !== messageId) throw new Error('history_reader_admission');
    return reply;
  };
  const readers = {
    readRecentSessionMessagesWithStatsAsync: (scope, options) => read(scope, 'recent', options),
    readSessionMessagesPageWithStatsAsync: (scope, options) => read(scope, 'page', options),
    readSessionMessagesAroundIdWithStatsAsync: async (scope, options) => {
      const found = await lookup(scope, 'around-id', options.messageId, options);
      if (!found.found) return { ...result([]), found: false, hasOverreadContext: false, offset: 0 };
      // The original source owns centered/edge/directional range arithmetic.
      const selected = resolveHistoryAnchorPageRange(snapshot.totalTurns, found.rows.at(-1).ordinal - 1, options);
      const rows = await range(selected.readStart, selected.endExclusive);
      const page = result(rows);
      if (jsonUtf8Bytes(page.messages) > (options.maxBytes ?? TRANSFER_BYTES)) throw new Error('history_reader_admission');
      return { ...page, found: true, hasOverreadContext: selected.hasOverreadContext, offset: selected.offset };
    },
    readSessionMessageByIdAsync: async (scope, messageId, options = {}) => {
      const found = await lookup(scope, 'by-id', messageId, options);
      if (!found.found) return { found: false, oversized: false };
      const row = found.rows.at(-1);
      const preceding = found.rows.length > 1 ? found.rows[0].message : undefined;
      return { found: true, oversized: false, message: row.message, seq: row.ordinal,
        serializedBytes: jsonUtf8Bytes(row.message), historyContext: {
          ...(preceding ? { precedingMessage: preceding } : {}), displaySource: snapshot.viewId } };
    },
  };
  const messageId = input.message_id;
  const params = { sessionId: target.sessionId, sessionAgentId: target.agentId, storePath,
    max, maxHistoryBytes: 6 * PAGE_BYTES, responseHistoryBytes: 512 * 1024, effectiveMaxChars: 8000,
    ...(messageId ? { messageId } : input.offset === undefined ? {} : { offset: input.offset }) };
  beginHistoryTarget(id);
  try {
    return await withUserPathBaseDirectory(view.environment.cwd, async () => {
      const kernel = await readChatHistoryPageKernel(params, { readers, readOnly: true });
      const prepared = prepareChatHistoryResponsePage(kernel, params);
      // Pending is display context, with honest host ISO time/state/kind. No
      // source RPC/profile/cron/custody identity or transcript seq is invented.
      const visiblePending = pendingInputs.items.flatMap(item => {
        const message = projectChatDisplayMessage(item.message, { maxChars: 8000 });
        return message ? [{ ...item, message }] : [];
      });
      const pendingMessages = replaceOversizedChatHistoryMessages({
        messages: visiblePending.map(item => item.message),
        maxSingleMessageBytes: Math.floor(128 * 1024 / Math.max(pendingInputs.items.length, 1)),
      }).messages;
      const pending = boundPendingInputs({ ...pendingInputs,
        items: visiblePending.map((item, index) => ({ ...item, message: pendingMessages[index] })) });
      const kinds = new Map(visiblePending.map(item => [item.id, item.kind]));
      pending.pendingInputs.items = pending.pendingInputs.items.map(item => ({ ...item, kind: kinds.get(item.id) }));
      // The source's 4096-byte pending stage precedes the host kind extension.
      pending.bytes = jsonUtf8Bytes(pending.pendingInputs);
      const transcriptBudget = SESSIONS_HISTORY_MAX_BYTES - pending.bytes;
      const rawMessages = prepared.messages;
      const selectedMessages = input.include_tools ? rawMessages : stripToolMessages(rawMessages);
      const sanitizedMessages = selectedMessages.map(message => sanitizeHistoryMessage(message));
      const contentTruncated = sanitizedMessages.some(entry => entry.truncated) || pending.truncated === true;
      const sanitizedItems = sanitizedMessages.map(entry => entry.message);
      const capped = messageId ? capSessionsHistoryAroundMessage(sanitizedItems, messageId, transcriptBudget)
        : capArrayByJsonBytes(sanitizedItems, transcriptBudget);
      const droppedMessages = capped.items.length < selectedMessages.length;
      const hardened = enforceSessionsHistoryHardCap({ items: capped.items, bytes: capped.bytes, maxBytes: transcriptBudget });
      const gateway = { messages: prepared.messages,
        ...(kernel.responseOffset === undefined ? {} : { offset: kernel.responseOffset }),
        ...(prepared.nextOffset === undefined ? {} : { nextOffset: prepared.nextOffset }),
        ...(prepared.hasMore === undefined ? {} : { hasMore: prepared.hasMore }),
        ...(prepared.totalMessages === undefined ? {} : { totalMessages: prepared.totalMessages }) };
      const pagination = resolveSessionsHistoryPaginationMetadata({ messages: hardened.items, result: gateway,
        requestedOffset: input.offset, requestedMessageId: messageId });
      const output = jsonResult({ session_id: target.sessionId, messages: hardened.items,
        truncated: droppedMessages || contentTruncated || hardened.hardCapped,
        droppedMessages: droppedMessages || hardened.hardCapped, contentTruncated, contentRedacted: false,
        bytes: hardened.bytes + pending.bytes, ...(kernel.windowReset ? { windowReset: true } : {}),
        pendingInputs: pending.pendingInputs, ...pagination });
      return { type: 'history_result', protocol: 1, historyProtocol: 1, id, slot: target.slot,
        referenceCommit: REFERENCE_COMMIT,
        candidate: { mode: 'standalone', text: output.content[0].text, page: output.details } };
    });
  } finally {
    endHistoryTarget();
  }
}
