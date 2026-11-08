import os from 'node:os';

export const REFERENCE_COMMIT = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const HISTORY_ENVIRONMENT_KEYS = Object.freeze([
  'OPENCLAW_HOME', 'OPENCLAW_STATE_DIR', 'OPENCLAW_CONFIG_PATH', 'OPENCLAW_PROFILE',
  'HOME', 'USERPROFILE', 'PREFIX', 'ANDROID_DATA', 'NODE_ENV', 'VITEST',
]);

// Actual startup observations, captured before the worker imports source code.
const startupEnvironment = Object.freeze({
  pathEnv: Object.freeze(Object.fromEntries(HISTORY_ENVIRONMENT_KEYS
    .filter(key => Object.hasOwn(process.env, key)).map(key => [key, process.env[key]]))),
  cwd: process.cwd(), osHome: os.homedir(), platform: process.platform,
});
let invocationView, sourceProjector, displayContentField, activeTarget;
const eventReplies = new Map();

export async function initializeInvocationServices(policy) {
  const expected = { version: 1, referenceCommit: REFERENCE_COMMIT,
    logging: { kind: 'pinned-default', mappedOverride: 'absent' } };
  if (!policy || Object.keys(policy).length !== 3 || policy.version !== expected.version ||
      policy.referenceCommit !== REFERENCE_COMMIT || !policy.logging || Object.keys(policy.logging).length !== 2 ||
      policy.logging.kind !== 'pinned-default' || policy.logging.mappedOverride !== 'absent') throw new Error('history_service_policy');
  if (!invocationView) {
    invocationView = Object.freeze({ ...expected, logging: Object.freeze(expected.logging), environment: startupEnvironment });
    // Checked policy and actual environment precede source evaluation. These
    // are local packaged modules, never a reference checkout or a TS loader.
    const [projection, content] = await Promise.all([
      import('./vendor/openclaw/src/gateway/chat-display-projection.core.mjs'),
      import('./vendor/openclaw/src/shared/assistant-display-content.mjs'),
    ]);
    sourceProjector = projection.projectChatDisplayMessagesWithState;
    displayContentField = content.ASSISTANT_DISPLAY_CONTENT_FIELD;
  }
  return invocationView;
}

// The single named logging service cut. Complete original redaction/default
// selection and the genuinely fresh source registry remain unchanged.
export function readInvocationLoggingConfig() {
  if (!invocationView) throw new Error('history_services_uninitialized');
  return undefined;
}

export function beginHistoryTarget(target) {
  if (!invocationView || activeTarget !== undefined) throw new Error('history_target_state');
  activeTarget = target;
  eventReplies.clear();
}

export function registerEventReplies(rows) {
  if (activeTarget === undefined) throw new Error('history_target_state');
  for (const row of rows) {
    if (row.eventReply === undefined) continue;
    const sidecar = row.eventReply;
    if (sidecar.version !== 1 || sidecar.policy !== 'manual_event_message' || typeof sidecar.hidden !== 'boolean' ||
        !Array.isArray(sidecar.textOverrides) || row.message?.role !== 'assistant' || row.message.__openclaw?.seq !== row.ordinal) {
      throw new Error('history_event_reply');
    }
    const previous = eventReplies.get(row.ordinal);
    if (previous && JSON.stringify(previous) !== JSON.stringify(sidecar)) throw new Error('history_event_reply');
    eventReplies.set(row.ordinal, structuredClone(sidecar));
  }
}

export function projectHostHistoryMessagesWithState(messages, options) {
  if (!sourceProjector || activeTarget === undefined) throw new Error('history_services_uninitialized');
  const display = messages.map(message => {
    const copy = structuredClone(message);
    const sidecar = eventReplies.get(message?.__openclaw?.seq);
    if (!sidecar) return copy;
    const content = structuredClone(copy.content);
    if (!Array.isArray(content)) throw new Error('history_event_reply');
    for (const override of sidecar.textOverrides) {
      if (!Number.isSafeInteger(override.blockIndex) || override.blockIndex < 0 ||
          typeof override.text !== 'string' || content[override.blockIndex]?.type !== 'text') throw new Error('history_event_reply');
      content[override.blockIndex] = { ...content[override.blockIndex], text: override.text };
    }
    copy[displayContentField] = content;
    if (sidecar.hidden) copy.display = false;
    return copy;
  });
  return sourceProjector(display, options);
}

export function endHistoryTarget() {
  eventReplies.clear();
  activeTarget = undefined;
}
