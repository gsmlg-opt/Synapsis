// Authored, source-derived adapter for OpenClaw 488631c's standing-intents-tool.
// This is not the original executor: Core owns time, identity, UUID and storage.
// See provenance.json and LICENSE for exact reference sources and scope.

const EXPIRY_MS = 90 * 24 * 60 * 60_000;
const GUIDANCE = 'The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.';
const SCOPES = ['conversation', 'channel', 'anywhere'];
const STATUSES = ['pending', 'armed', 'fired', 'done', 'cancelled', 'expired'];
// rowToIntent order is observable through JSON.stringify(payload, null, 2).
const PUBLIC_FIELDS = ['id', 'description', 'triggerKeywords', 'triggerEmbedding',
  'scope', 'channelScope', 'senderScope', 'creatorSender', 'status', 'expiresAt',
  'maxFires', 'fireCount', 'cooldownSeconds', 'lastFiredAt', 'createdAt', 'sourceSessionId'];

function requiredString(value, field, maxChars) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${field} is required`);
  const trimmed = value.trim();
  if (trimmed.length > maxChars) throw new Error(`${field} must be at most ${maxChars} characters`);
  return trimmed;
}

function choice(value, field, allowed, fallback) {
  if (value === undefined) return fallback;
  if (!allowed.includes(value)) throw new Error(`${field} must be one of: ${allowed.join(', ')}`);
  return value;
}

function keywords(value) {
  if (!Array.isArray(value) || value.length === 0)
    throw new Error('triggerKeywords must be a non-empty string array');
  const unique = [...new Set(value.map(entry =>
    requiredString(entry, 'triggerKeywords entry', 120).toLowerCase()))];
  if (unique.length > 24) throw new Error('triggerKeywords must contain at most 24 entries');
  return unique;
}

function expiry(value, nowMs) {
  if (value === undefined) return nowMs + EXPIRY_MS;
  if (typeof value !== 'string') throw new Error('expiresAt must be an ISO 8601 timestamp');
  // Deliberately retain native Date.parse, including formats beyond ISO.
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || parsed <= nowMs)
    throw new Error('expiresAt must be a future ISO 8601 timestamp');
  return parsed;
}

function integerParam(params, key, positive) {
  const snake = key.replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
  const raw = Object.hasOwn(params, key) ? params[key]
    : Object.hasOwn(params, snake) ? params[snake] : undefined;
  if (raw == null || (typeof raw === 'string' && raw.trim() === '')) return undefined;
  let number;
  if (typeof raw === 'number' && Number.isFinite(raw)) number = raw;
  else if (typeof raw === 'string' && /^[+-]?(?:(?:\d+\.?\d*)|(?:\.\d+))(?:e[+-]?\d+)?$/i.test(raw.trim()))
    number = Number(raw.trim());
  if (!Number.isSafeInteger(number) || number < 0 || (positive && number === 0))
    throw new Error(`${key} must be a ${positive ? 'positive' : 'non-negative'} integer`);
  return number;
}

function scopeIdentity(value, field, lowercase = false) {
  const normalized = value.trim();
  if (!normalized) throw new Error(`${field} is unavailable for this creating turn`);
  return lowercase ? normalized.toLowerCase() : normalized;
}

function prepare(request) {
  const params = request.params ?? {};
  const options = request.options;
  if (!options || typeof options !== 'object' || Array.isArray(options) || typeof options.agentId !== 'string')
    throw new Error('explicit host options required');
  if (params.action === 'create') {
    const provider = options.provider?.trim();
    const senderId = options.senderId?.trim();
    if (!provider || !senderId) throw new Error('creating identity is unavailable for this turn');
    const nowMs = request.nowMs;
    if (!Number.isSafeInteger(nowMs)) throw new Error('explicit observation time required');
    const scope = choice(params.scope, 'scope', SCOPES, 'channel');
    const senderScope = choice(params.senderScope, 'senderScope', ['sender', 'anyone'], 'sender');
    const description = requiredString(params.description, 'description', 500);
    const triggerKeywords = keywords(params.triggerKeywords);
    // Encoders normalize independently, just as the original model does.
    const channelScope = scope === 'anywhere' ? null : JSON.stringify([
      'v1', scope, scopeIdentity(options.provider ?? '', 'channel identity', true),
      options.accountId?.trim() || 'default', scope === 'channel'
        ? scopeIdentity(options.provider ?? '', 'channel identity', true)
        : scopeIdentity(options.conversationId ?? '', 'conversation identity'),
    ]);
    const storedSenderScope = senderScope === 'anyone' ? null : JSON.stringify([
      'v1', scopeIdentity(options.provider ?? '', 'channel identity', true),
      options.accountId?.trim() || 'default', scopeIdentity(options.senderId ?? '', 'sender identity'),
    ]);
    const prepared = { description, triggerKeywords, channelScope, senderScope: storedSenderScope,
      creatorSender: senderId, expiresAt: expiry(params.expiresAt, nowMs),
      maxFires: integerParam(params, 'maxFires', true) ?? 3,
      cooldownSeconds: integerParam(params, 'cooldownSeconds', false) ?? 86400 };
    if (Object.hasOwn(options, 'sourceSessionId')) prepared.sourceSessionId = options.sourceSessionId;
    return { action: 'create', agentId: options.agentId, prepared, nowMs, scope };
  }
  if (params.action === 'list') {
    const status = choice(params.status, 'status', STATUSES, undefined);
    return { action: 'list', agentId: options.agentId, ...(status === undefined ? {} : { status }) };
  }
  if (params.action === 'cancel')
    return { action: 'cancel', agentId: options.agentId, id: requiredString(params.id, 'id', 200) };
  throw new Error('action must be create, list, or cancel');
}

function publicIntent(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).length !== PUBLIC_FIELDS.length
    || !PUBLIC_FIELDS.every(key => Object.hasOwn(value, key)))
    throw new Error('complete public intent projection required');
  return Object.fromEntries(PUBLIC_FIELDS.map(key => [key, value[key]]));
}

function format(request) {
  let payload;
  if (request.action === 'create') {
    const scope = choice(request.scope, 'scope', SCOPES, undefined);
    if (scope === undefined) throw new Error('prepared scope required');
    const phrase = scope === 'channel' ? 'for this channel'
      : scope === 'conversation' ? 'for this conversation' : 'everywhere';
    payload = { intent: publicIntent(request.value), message: `Intent is armed ${phrase}. ${GUIDANCE}` };
  } else if (request.action === 'list') {
    if (!Array.isArray(request.value)) throw new Error('public intent list required');
    payload = { intents: request.value.map(publicIntent) };
  } else if (request.action === 'cancel') {
    const intent = request.value === null ? null : publicIntent(request.value);
    payload = { cancelled: intent !== null, intent };
  } else throw new Error('action must be create, list, or cancel');
  return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }], details: payload };
}

export function evaluate(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('request required');
  if (request.operation === 'prepare') return prepare(request);
  if (request.operation === 'format') return format(request);
  throw new Error('unknown operation');
}
