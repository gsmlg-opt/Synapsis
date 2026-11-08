// Independent positive literals, frozen before the Synapsis contract implementation.
// Runs the complete unchanged original executor, model, result and normalization
// modules. common.ts uses the exact contiguous complete numeric-reader declarations.
// ONLY storage calls are supplied capture boundaries: this is argument/result
// evidence, never SQLite, Concord, facade, native-tool or runtime evidence.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix } from 'node:path';
import test from 'node:test';
import { createContext, SourceTextModule, SyntheticModule } from 'node:vm';

const root = '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const reference = JSON.parse(readFileSync(new URL(
  '../../apps/synapsis_agent/test/fixtures/openclaw/488631c/standing-intents.json', import.meta.url,
), 'utf8'));
const now = 1800000000000;
const sha256 = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const hashes = {
  'extensions/memory-core/src/standing-intents-tool.ts': 'f9a301e73a98d217fb80c8bb403f6d4e359c4a9d6ebc943ccbb160c0560d1fbf',
  'extensions/memory-core/src/standing-intents-model.ts': 'd7f73450e2ca58cce718e0055ebc6ffa207276eeabdc9d97d94b8391ca7c9e47',
  'src/agents/tools/common.ts': 'a69d2c0915f658d621ccacc0e76b1f34417eb3a571a86b1ef32b87edeab74bb7',
  'src/agents/tools/tool-results.ts': '13d2e22b750609d8cc848a548a17324e99000f004e89730bf305b3960da2ce3b',
  'src/param-key.ts': '3393299148b9059e991f9d655e3e930bc507ed1d8d6985db21e4e42466df91ef',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'src/agents/tool-input-error.ts': '70582ae2f67d5d23ce514ee93f249e2c659ddf32e7bf70b1692dcadcf03af7bc',
};
const originals = new Map(Object.entries(hashes).map(([path, hash]) => {
  const bytes = readFileSync(`${root}/${path}`);
  assert.equal(sha256(bytes), hash, `complete pinned original ${path}`);
  return [path, bytes];
}));
const commonPath = 'src/agents/tools/common.ts';
const numericRegion = originals.get(commonPath).subarray(4742, 7413);
assert.equal(sha256(numericRegion), '2fba0bd58dbb8e09cc0d547b0b41c0634e3ea8b2f71398339aaa6e3750c256a9');
assert.ok(numericRegion.toString().startsWith('export function readNumberParam('));
assert.ok(numericRegion.toString().endsWith('  return value;\n}\n\n'));

let clockReads = 0;
class FixedDate extends Date {
  static now() { clockReads += 1; return now; }
}
const context = createContext({ Date: FixedDate });
const modules = new Map();
const sourceRecords = [];
function original(path) {
  if (modules.has(path)) return modules.get(path);
  const bytes = originals.get(path);
  assert.ok(bytes, `explicit original module: ${path}`);
  const selected = path === commonPath
    ? `import {asPositiveSafeInteger, asSafeIntegerInRange, parseStrictFiniteNumber} from '@openclaw/normalization-core/number-coercion';
import {readSnakeCaseParamRaw} from '../../param-key.js';
import {ToolInputError} from '../tool-input-error.js';
${numericRegion}`
    : bytes.toString();
  const executable = stripTypeScriptTypes(selected, { mode: 'transform', sourceMap: false });
  const module = new SourceTextModule(executable, { context, identifier: path });
  modules.set(path, module);
  sourceRecords.push({ path, wholeModule: path !== commonPath,
    sha256: sha256(bytes), executableSha256: sha256(executable),
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    ...(path === commonPath ? { startByte: 4742, endByte: 7413,
      regionSha256: sha256(numericRegion), authoredBodyPatches: false, importsSupplied: true } : {}) });
  return module;
}
const modelPath = 'extensions/memory-core/src/standing-intents-model.ts';
const model = original(modelPath);
await model.link(specifier => assert.fail(`model unexpectedly imports ${specifier}`));
await model.evaluate({ timeout: 5000 });

let observation;
const names = ['DEFAULT_INTENT_COOLDOWN_SECONDS', 'DEFAULT_INTENT_EXPIRY_MS',
  'DEFAULT_INTENT_MAX_FIRES', 'encodeStandingIntentChannelScope', 'encodeStandingIntentSenderScope'];
const storage = new SyntheticModule([...names, 'createStandingIntent', 'listStandingIntents', 'cancelStandingIntent'], function () {
  for (const name of names) this.setExport(name, model.namespace[name]);
  this.setExport('createStandingIntent', async input => {
    observation.calls.push({ action: 'create', input: plain(input) });
    return observation.response;
  });
  this.setExport('listStandingIntents', async input => {
    observation.calls.push({ action: 'list', input: plain(input) });
    return observation.response;
  });
  this.setExport('cancelStandingIntent', async () => assert.fail('cancel remains unexecuted'));
}, { context, identifier: 'supplied:argument-result-storage-capture-only' });

function dependency(specifier, owner) {
  if (specifier === 'openclaw/plugin-sdk/memory-core-host-runtime-core')
    return original('src/agents/tools/tool-results.ts');
  if (specifier === 'openclaw/plugin-sdk/param-readers') return original(commonPath);
  if (specifier === './standing-intents.js') return storage;
  if (specifier.startsWith('@openclaw/normalization-core/'))
    return original('packages/normalization-core/src/' + specifier.slice('@openclaw/normalization-core/'.length) + '.ts');
  assert.ok(specifier.startsWith('.'), `closed original import ${owner.identifier}: ${specifier}`);
  return original(posix.normalize(posix.join(posix.dirname(owner.identifier), specifier)).replace(/\.js$/, '.ts'));
}
const tool = original('extensions/memory-core/src/standing-intents-tool.ts');
await tool.link(dependency);
await tool.evaluate({ timeout: 5000 });

const options = {
  agentId: '10000000-0000-4000-8000-000000000302',
  provider: ' Slack ', senderId: ' ÁLICE:雪 😀 ', sourceSessionId: '  source:302  ',
};
const fixture = {
  id: '00000000-0000-4000-8000-000000000302',
  description: 'Review <b>café 雪 😀</b>.',
  triggerKeywords: ['release notes', 'ος'], triggerEmbedding: null,
  scope: 'channel', channelScope: 'slack', senderScope: 'ÁLICE:雪 😀',
  creatorSender: 'ÁLICE:雪 😀', status: 'armed', expiresAt: 1807776000000,
  maxFires: 3, fireCount: 0, cooldownSeconds: 86400, lastFiredAt: null,
  createdAt: now, sourceSessionId: '  source:302  ',
};
const baseParams = () => ({ action: 'create', description: ' Review <b>café 雪 😀</b>. ',
  triggerKeywords: [' Release Notes ', ' ΟΣ '] });
const prepared = () => ({
  agentId: options.agentId,
  description: 'Review <b>café 雪 😀</b>.', triggerKeywords: ['release notes', 'ος'],
  channelScope: '["v1","channel","slack","default","slack"]',
  senderScope: '["v1","slack","default","ÁLICE:雪 😀"]', creatorSender: 'ÁLICE:雪 😀',
  expiresAt: 1807776000000, maxFires: 3, cooldownSeconds: 86400,
  sourceSessionId: '  source:302  ', nowMs: now,
});
async function invoke(params, host = options, response = fixture) {
  observation = { calls: [], response };
  clockReads = 0;
  const result = await tool.namespace.createStandingIntentExecutor(host)('literal-302', params);
  return { calls: observation.calls, result: plain(result), clockReads };
}
const createText = `{
  "intent": {
    "id": "00000000-0000-4000-8000-000000000302",
    "description": "Review <b>café 雪 😀</b>.",
    "triggerKeywords": [
      "release notes",
      "ος"
    ],
    "triggerEmbedding": null,
    "scope": "channel",
    "channelScope": "slack",
    "senderScope": "ÁLICE:雪 😀",
    "creatorSender": "ÁLICE:雪 😀",
    "status": "armed",
    "expiresAt": 1807776000000,
    "maxFires": 3,
    "fireCount": 0,
    "cooldownSeconds": 86400,
    "lastFiredAt": null,
    "createdAt": 1800000000000,
    "sourceSessionId": "  source:302  "
  },
  "message": "Intent is armed for this channel. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks."
}`;
const listText = `{
  "intents": [
    {
      "id": "00000000-0000-4000-8000-000000000302",
      "description": "Review <b>café 雪 😀</b>.",
      "triggerKeywords": [
        "release notes",
        "ος"
      ],
      "triggerEmbedding": null,
      "scope": "channel",
      "channelScope": "slack",
      "senderScope": "ÁLICE:雪 😀",
      "creatorSender": "ÁLICE:雪 😀",
      "status": "armed",
      "expiresAt": 1807776000000,
      "maxFires": 3,
      "fireCount": 0,
      "cooldownSeconds": 86400,
      "lastFiredAt": null,
      "createdAt": 1800000000000,
      "sourceSessionId": "  source:302  "
    }
  ]
}`;

test('pinned whole originals and exact numeric-reader region retain their source identity', () => {
  assert.equal(reference.referencePin, pin);
  assert.equal(reference.sourceTree.before.pin, pin);
  assert.equal(reference.sourceTree.after.pin, pin);
  for (const path of [modelPath, 'extensions/memory-core/src/standing-intents-tool.ts'])
    assert.equal(reference.sourceRecords.find(row => row.path === path).sha256, hashes[path]);
  assert.equal(sourceRecords.length, 8);
  assert.equal(sourceRecords.filter(row => row.wholeModule).length, 7);
  const { executableSha256, ...regionRecord } = sourceRecords.find(row => row.path === commonPath);
  assert.match(executableSha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(regionRecord, {
    path: commonPath, wholeModule: false, sha256: hashes[commonPath],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    startByte: 4742, endByte: 7413,
    regionSha256: '2fba0bd58dbb8e09cc0d547b0b41c0634e3ea8b2f71398339aaa6e3750c256a9',
    authoredBodyPatches: false, importsSupplied: true,
  });
});

test('default create normalizes ECMAScript whitespace and stable lowercase keyword duplicates', async () => {
  const observed = await invoke({ action: 'create', description: '\uFEFF Review <b>café 雪 😀</b>. \u3000',
    triggerKeywords: [' Release Notes ', 'RELEASE NOTES', ' ΟΣ ', 'ος'] });
  assert.deepEqual(observed.calls, [{ action: 'create', input: prepared() }]);
  assert.equal(observed.clockReads, 1);
  assert.deepEqual(observed.result, { content: [{ type: 'text', text: createText }],
    details: { intent: fixture, message: 'Intent is armed for this channel. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.' } });
});

test('conversation RFC expiry and scientific snake numbers retain literal host scopes', async () => {
  const observed = await invoke({ action: 'create', description: '  Review café.\nKeep notes.  ',
    triggerKeywords: [' ΟΣ ', 'ΟΣΑ', 'ΟΣ'], scope: 'conversation', senderScope: 'sender',
    expiresAt: 'Tue, 01 Jan 2030 00:00:00 GMT', max_fires: ' +2e0 ', cooldown_seconds: ' +6.0e1 ' },
  { agentId: options.agentId, provider: ' TÉLÉGRAM ', accountId: ' 账户-雪 ',
    conversationId: ' Room:CAFÉ 雪 😀 ', senderId: ' ÁLICE:雪 😀 ', sourceSessionId: '  provenance:302  ' });
  assert.deepEqual(observed.calls, [{ action: 'create', input: {
    agentId: options.agentId, description: 'Review café.\nKeep notes.', triggerKeywords: ['ος', 'οσα'],
    channelScope: '["v1","conversation","télégram","账户-雪","Room:CAFÉ 雪 😀"]',
    senderScope: '["v1","télégram","账户-雪","ÁLICE:雪 😀"]', creatorSender: 'ÁLICE:雪 😀',
    expiresAt: 1893456000000, maxFires: 2, cooldownSeconds: 60,
    sourceSessionId: '  provenance:302  ', nowMs: now,
  } }]);
  assert.equal(observed.result.details.message, 'Intent is armed for this conversation. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.');
  assert.equal(observed.clockReads, 1);
});

test('offset ISO expiry uses the same native Date.parse instant', async () => {
  const observed = await invoke({ ...baseParams(), expiresAt: '2030-01-01T08:30:00+08:30' });
  assert.deepEqual(observed.calls, [{ action: 'create', input: { ...prepared(), expiresAt: 1893456000000 } }]);
});

test('anywhere and anyone produce independent null scopes while retaining the host creator', async () => {
  const observed = await invoke({ ...baseParams(), scope: 'anywhere', senderScope: 'anyone' });
  assert.deepEqual(observed.calls, [{ action: 'create', input: { ...prepared(), channelScope: null, senderScope: null } }]);
  assert.equal(observed.result.details.message, 'Intent is armed everywhere. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks.');
});

test('blank and null optional numeric values use the source defaults', async () => {
  const observed = await invoke({ ...baseParams(), maxFires: ' \t ', cooldownSeconds: null });
  assert.deepEqual(observed.calls, [{ action: 'create', input: prepared() }]);
});

test('camel numeric keys win over snake aliases including an explicit camel null', async () => {
  const observed = await invoke({ ...baseParams(), maxFires: null, max_fires: 8,
    cooldownSeconds: '60.0', cooldown_seconds: 120 });
  assert.deepEqual(observed.calls, [{ action: 'create', input: { ...prepared(), cooldownSeconds: 60 } }]);
});

test('ordinary numeric camel values preserve omitted sourceSessionId in JSON custody', async () => {
  const host = { agentId: options.agentId, provider: options.provider, senderId: options.senderId };
  const observed = await invoke({ ...baseParams(), maxFires: 4, cooldownSeconds: 90 }, host);
  const expected = prepared();
  delete expected.sourceSessionId;
  assert.deepEqual(observed.calls, [{ action: 'create', input: { ...expected, maxFires: 4, cooldownSeconds: 90 } }]);
});

test('list without a status has exact structured and textual public output without reading a clock', async () => {
  const observed = await invoke({ action: 'list' }, options, [fixture]);
  assert.deepEqual(observed.calls, [{ action: 'list', input: { agentId: options.agentId } }]);
  assert.deepEqual(observed.result, { content: [{ type: 'text', text: listText }], details: { intents: [fixture] } });
  assert.equal(observed.clockReads, 0);
});

test('list forwards an exact selected status without preparing a creation clock', async () => {
  const observed = await invoke({ action: 'list', status: 'armed' }, options, [fixture]);
  assert.deepEqual(observed.calls, [{ action: 'list', input: { agentId: options.agentId, status: 'armed' } }]);
  assert.deepEqual(observed.result, { content: [{ type: 'text', text: listText }], details: { intents: [fixture] } });
  assert.equal(observed.clockReads, 0);
});
