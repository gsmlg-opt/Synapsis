// Independent ordinary literals from OpenClaw 488631c, frozen before implementation.
// Only the complete original model executes; the private kernel predicate is source-reviewed.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { SourceTextModule } from 'node:vm';

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const path = 'extensions/memory-core/src/standing-intents-model.ts';
const source = readFileSync(`/tmp/openclaw-488631c/${path}`);
const fixture = JSON.parse(readFileSync(new URL(
  '../../apps/synapsis_agent/test/fixtures/openclaw/488631c/standing-intents.json', import.meta.url,
), 'utf8'));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const sourceSha256 = 'd7f73450e2ca58cce718e0055ebc6ffa207276eeabdc9d97d94b8391ca7c9e47';

assert.equal(sha256(source), sourceSha256);
const executable = stripTypeScriptTypes(source.toString('utf8'), { mode: 'transform', sourceMap: false });
const original = new SourceTextModule(executable, { identifier: `/tmp/openclaw-488631c/${path}` });
assert.deepEqual(original.dependencySpecifiers, []);
await original.link(specifier => assert.fail(`unexpected model runtime import: ${specifier}`));
await original.evaluate({ timeout: 5000 });
const model = original.namespace;

const first = {
  id: '00000000-0000-4000-8000-000000000301',
  description: '  Review <b>café 雪 😀</b>.\nKeep **release** notes.  ',
  triggerKeywords: ['release notes'],
  triggerEmbedding: null,
  scope: 'conversation',
  channelScope: 'Room:CAFÉ 雪 😀',
  senderScope: 'ÁLICE:雪 😀',
  creatorSender: 'Alice',
  status: 'armed',
  expiresAt: 1800086400000,
  maxFires: 3,
  fireCount: 0,
  cooldownSeconds: 86400,
  lastFiredAt: null,
  createdAt: 1800000000000,
  sourceSessionId: 'provenance-301-a',
};
const second = {
  id: '00000000-0000-4000-8000-000000000302',
  description: 'Send the next update 🚀.\nUse <em>plain source text</em>.',
  triggerKeywords: ['next update'],
  triggerEmbedding: null,
  scope: 'channel',
  channelScope: 'slack',
  senderScope: 'Alice',
  creatorSender: 'Alice',
  status: 'armed',
  expiresAt: 1800172800000,
  maxFires: 3,
  fireCount: 0,
  cooldownSeconds: 86400,
  lastFiredAt: null,
  createdAt: 1800086400000,
  sourceSessionId: 'provenance-301-b',
};

test('the complete unchanged model matches the saved pinned source identity', () => {
  assert.equal(fixture.referencePin, pin);
  assert.equal(fixture.sourceTree.before.pin, pin);
  assert.equal(fixture.sourceTree.after.pin, pin);
  assert.deepEqual(fixture.sourceRecords.find(record => record.path === path), {
    path,
    gitBlob: '49ee21f9fa0d3e76b63828f5ea7a542fffb2fedc',
    sha256: sourceSha256,
    wholeModule: true,
    executed: true,
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    executableSha256: '600cf314fb24eff2841a87c2ee1ff867c96d53069ece2404ec039d33cc68d057',
  });
  assert.equal(createHash('sha1').update(`blob ${source.length}\0`).update(source).digest('hex'),
    '49ee21f9fa0d3e76b63828f5ea7a542fffb2fedc');
  assert.equal(sha256(executable), '600cf314fb24eff2841a87c2ee1ff867c96d53069ece2404ec039d33cc68d057');
});

test('tokenization retains multilingual letters numbers underscore hyphen and duplicate tokens', () => {
  assert.deepEqual(model.tokenizeIntentText('RELEASE release Café 雪 １２3 user_name phase-2 ΟΣ ΟΣΑ'),
    ['release', 'release', 'café', '雪', '１２3', 'user_name', 'phase-2', 'ος', 'οσα']);
});

test('match preparation preserves first token order and complete encoded scope identities', () => {
  assert.deepEqual(model.prepareStandingIntentMatch({
    prompt: 'RELEASE release Café 雪 １２3 user_name phase-2 ΟΣ ΟΣΑ',
    channel: '  Room:CAFÉ 雪 😀  ',
    provider: '  TÉLÉGRAM  ',
    accountId: '  账户-雪  ',
    senderId: '  ÁLICE:雪 😀  ',
    nowMs: 1800000000000,
  }), {
    promptTokens: ['release', 'café', '雪', '１２3', 'user_name', 'phase-2', 'ος', 'οσα'],
    ftsQuery: {
      kind: 'any',
      clauses: [
        { kind: 'phrase', text: 'release' },
        { kind: 'phrase', text: 'café' },
        { kind: 'phrase', text: '雪' },
        { kind: 'phrase', text: '１２3' },
        { kind: 'phrase', text: 'user_name' },
        { kind: 'phrase', text: 'phase-2' },
        { kind: 'phrase', text: 'ος' },
        { kind: 'phrase', text: 'οσα' },
      ],
    },
    channelScopes: [
      '["v1","channel","télégram","账户-雪","télégram"]',
      '["v1","conversation","télégram","账户-雪","Room:CAFÉ 雪 😀"]',
    ],
    senderScope: '["v1","télégram","账户-雪","ÁLICE:雪 😀"]',
    nowMs: 1800000000000,
  });
});

test('ordinary prompt preparation preserves omitted optional identities and clock', () => {
  assert.deepEqual(model.prepareStandingIntentMatch({ prompt: 'Daily notes' }), {
    promptTokens: ['daily', 'notes'],
    ftsQuery: {
      kind: 'any',
      clauses: [{ kind: 'phrase', text: 'daily' }, { kind: 'phrase', text: 'notes' }],
    },
    channelScopes: [],
    senderScope: undefined,
    nowMs: undefined,
  });
});

test('provider preparation uses the default account for an ordinary channel scope', () => {
  assert.deepEqual(model.prepareStandingIntentMatch({ prompt: 'Daily notes', provider: ' Slack ' }), {
    promptTokens: ['daily', 'notes'],
    ftsQuery: {
      kind: 'any',
      clauses: [{ kind: 'phrase', text: 'daily' }, { kind: 'phrase', text: 'notes' }],
    },
    channelScopes: ['["v1","channel","slack","default","slack"]'],
    senderScope: undefined,
    nowMs: undefined,
  });
});

test('one ordinary public intent fits and renders exact raw multiline context', () => {
  assert.equal(model.standingIntentsFitContext([first]), true);
  assert.equal(model.buildStandingIntentContext([first]),
    '<standing_intents>\nStanding intent (created 2027-01-15):   Review <b>café 雪 😀</b>.\nKeep **release** notes.  \n</standing_intents>');
});

test('two ordinary public intents retain order and UTC creation dates in exact context', () => {
  assert.equal(model.standingIntentsFitContext([first, second]), true);
  assert.equal(model.buildStandingIntentContext([first, second]),
    '<standing_intents>\nStanding intent (created 2027-01-15):   Review <b>café 雪 😀</b>.\nKeep **release** notes.  \nStanding intent (created 2027-01-16): Send the next update 🚀.\nUse <em>plain source text</em>.\n</standing_intents>');
});

test('a user webchat turn is eligible with a session id', () => {
  assert.equal(model.isEligibleStandingIntentTurn({
    trigger: 'user', sessionId: 'session-301-webchat', messageProvider: ' WebChat ',
  }), true);
});

test('a provider user turn is eligible with a session key and channel id', () => {
  assert.equal(model.isEligibleStandingIntentTurn({
    trigger: 'user', sessionKey: 'agent:301:channel', messageProvider: ' Slack ', channelId: ' channel-301 ',
  }), true);
});

test('a provider user turn is eligible with a session id and chat id', () => {
  assert.equal(model.isEligibleStandingIntentTurn({
    trigger: 'user', sessionId: 'session-301-chat', messageProvider: ' Telegram ', chatId: ' chat-301 ',
  }), true);
});
