import { readChatHistoryPageKernel } from './vendor/openclaw/src/gateway/server-methods/chat-history-page-kernel.mjs';
import { prepareChatHistoryResponsePage } from './vendor/openclaw/src/gateway/server-methods/chat-history-response-page.mjs';
import { stripToolMessages } from './vendor/openclaw/src/agents/tools/chat-history-text.mjs';
import { withUserPathBaseDirectory } from './vendor/openclaw/src/infra/home-dir.mjs';
import { beginHistoryTarget, endHistoryTarget, registerEventReplies, REFERENCE_COMMIT } from './host-history-services.mjs';

const PAGE_BYTES = 1024 * 1024;
const FRAGMENT_BYTES = 65_536;

function fragment(row) {
  const json = JSON.stringify(row, null, 2).split('\n').map(line => '    ' + line).join('\n');
  const utf8Bytes = Buffer.byteLength(json);
  return utf8Bytes <= FRAGMENT_BYTES ? { kind: 'json', json, utf8Bytes } : { kind: 'oversize', utf8Bytes };
}

export async function projectHistory(start, requestReader, view) {
  const { id, target, snapshot, row, limit } = start;
  if (!target || typeof target.slot !== 'string' || !target.slot || typeof target.sessionId !== 'string' || !target.sessionId ||
      !snapshot || typeof snapshot.viewId !== 'string' || !snapshot.viewId || !Number.isSafeInteger(snapshot.totalTurns) || snapshot.totalTurns < 0 ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 20 || !row || typeof row !== 'object' || Array.isArray(row)) throw new Error('history_start');
  const readWindow = Object.freeze({ source: snapshot.viewId, latestResetRawSeq: null });
  // Virtual injected-reader scope, not a filesystem path or lifecycle fact.
  const storePath = 'synapsis:history-view:' + snapshot.viewId;
  let windowCaptured = false;
  const read = async (scope, operation, options) => {
    if (scope.storePath !== storePath || scope.sessionId !== target.sessionId || scope.agentId !== target.agentId) throw new Error('history_read_scope');
    if (options.expectedReadWindow && JSON.stringify(options.expectedReadWindow) !== JSON.stringify(readWindow)) throw new Error('history_read_window');
    const reply = await requestReader(operation, options);
    if (reply.id !== id || reply.slot !== target.slot || reply.viewId !== snapshot.viewId || reply.totalTurns !== snapshot.totalTurns ||
        !Array.isArray(reply.rows) || reply.rows.length > 401) throw new Error('history_reader_admission');
    const end = Math.max(0, Math.min(snapshot.totalTurns, options.beforeSeq === undefined ? snapshot.totalTurns : options.beforeSeq - 1) - (options.offset ?? 0));
    const first = Math.max(0, end - options.maxMessages) + 1;
    if (reply.rows.length !== end - first + 1) throw new Error('history_reader_admission');
    for (let index = 0; index < reply.rows.length; index++) {
      const value = reply.rows[index];
      if (value.ordinal !== first + index || !Number.isSafeInteger(value.index) || value.index < 0 ||
          value.message?.__openclaw?.seq !== value.ordinal || index > 0 && value.index <= reply.rows[index - 1].index) throw new Error('history_reader_admission');
    }
    // Account exact raw JSON before decorating any projection-only copy.
    const messages = reply.rows.map(value => value.message);
    if (Buffer.byteLength(JSON.stringify(messages)) > options.maxBytes || options.maxBytes > PAGE_BYTES) throw new Error('history_reader_admission');
    registerEventReplies(reply.rows);
    if (options.captureReadWindow) windowCaptured = true;
    if (!windowCaptured) throw new Error('history_read_window');
    return { messages, totalMessages: snapshot.totalTurns, displaySource: snapshot.viewId, readWindow };
  };
  const readers = {
    readRecentSessionMessagesWithStatsAsync: (scope, options) => read(scope, 'recent', options),
    readSessionMessagesPageWithStatsAsync: (scope, options) => read(scope, 'page', options),
  };
  const params = { sessionId: target.sessionId, sessionAgentId: target.agentId, storePath,
    max: limit, maxHistoryBytes: 6 * PAGE_BYTES, responseHistoryBytes: 512 * 1024, effectiveMaxChars: 8000 };
  beginHistoryTarget(id);
  try {
    return await withUserPathBaseDirectory(view.environment.cwd, async () => {
      const page = await readChatHistoryPageKernel(params, { readers, readOnly: true });
      const prepared = prepareChatHistoryResponsePage(page, params);
      const messages = stripToolMessages(prepared.messages).slice(-limit);
      const enriched = fragment({ ...row, messages });
      const metadataRow = { ...row };
      for (const field of ['messages', 'derived_title', 'last_message_preview']) delete metadataRow[field];
      return { type: 'history_result', protocol: 1, historyProtocol: 1, id, slot: target.slot,
        referenceCommit: REFERENCE_COMMIT,
        candidate: { ...(enriched.kind === 'json' ? { messages } : {}), enriched, metadata: fragment(metadataRow) } };
    });
  } finally {
    endHistoryTarget();
  }
}
