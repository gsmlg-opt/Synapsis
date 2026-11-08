// Literal ordinary expectations fixed from the pinned source audit before execution.
// This is a pure-source oracle prerequisite, not full sessions_list acceptance.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createSessionEnrichmentReference, SESSION_ENRICHMENT_PIN } from './session-enrichment-reference.mjs';

const oracle = await createSessionEnrichmentReference();
const call = (entry, name, ...args) => oracle.call(entry, name, args);
const plain = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const project = (message, options) => plain(call('display', 'projectSessionDisplayMessage', message, options));
const goal = text => call('goal', 'deriveGoalSessionTitle', text);
const signature = phase => JSON.stringify({ v: 1, phase });

test('assistant final phases and persisted display sources select authored visible text', () => {
  assert.deepEqual(project({ role: 'assistant', content: [
    { type: 'text', text: 'Working on the report.', textSignature: signature('commentary') },
    { type: 'text', text: 'Report ready.', textSignature: signature('final_answer') },
    { type: 'text', text: 'Two sessions included.', textSignature: signature('final_answer') },
  ] }), { role: 'assistant', text: 'Report ready.\nTwo sessions included.' });
  assert.equal(project({ role: 'assistant', phase: 'commentary', content: 'Working on the report.' }), null);
  assert.deepEqual(project({ role: 'assistant', content: '  Legacy answer.  ' }), { role: 'assistant', text: 'Legacy answer.' });
  const persisted = { role: 'assistant', content: [{ type: 'text', text: 'Model source.' }],
    openclawDisplayContent: [{ type: 'text', text: 'Persisted visible answer.' }] };
  assert.deepEqual(project(persisted), { role: 'assistant', text: 'Persisted visible answer.' });
  assert.deepEqual(project(persisted, { view: 'model-context' }), { role: 'assistant', text: 'Model source.' });
  assert.equal(persisted.content[0].text, 'Model source.');
  assert.equal(persisted.openclawDisplayContent[0].text, 'Persisted visible answer.');
});

test('ordinary display disposition, silence and heartbeat selection preserve forwarded text', () => {
  assert.equal(project({ role: 'user', content: 'Internal turn.', display: false }), null);
  assert.equal(project({ role: 'assistant', content: 'Internal answer.', display: false }), null);
  assert.equal(project({ role: 'assistant', content: 'NO_REPLY' }), null);
  assert.deepEqual(project({ role: 'assistant', content: 'NO_REPLY', display: true }), { role: 'assistant', text: 'NO_REPLY' });
  assert.equal(project({ role: 'assistant', content: 'HEARTBEAT_OK' }), null);
  assert.deepEqual(project({ role: 'assistant', content: 'HEARTBEAT_OK',
    provenance: { kind: 'inter_session', sourceTool: 'sessions_send' } }), { role: 'assistant', text: 'HEARTBEAT_OK' });
});

test('ordinary user blocks and generated channel envelopes become display text', () => {
  assert.deepEqual(project({ role: 'user', content: [
    { type: 'text', text: '[WebChat Alex] Build the report.' },
    { type: 'input_text', text: 'Use current sessions.' },
  ] }), { role: 'user', text: 'Build the report.\nUse current sessions.' });
  assert.deepEqual(project({ role: 'user', content: '[2026-11-05 10:20] Review sessions.' }), { role: 'user', text: 'Review sessions.' });
  assert.deepEqual(project({ role: 'user', content: '[Planning] Review sessions.' }), { role: 'user', text: '[Planning] Review sessions.' });
});

test('actual Markdown parser flattens nested labels, balanced destinations and one-line prose', () => {
  const markdown = '# **Session** report\n> Read `status` and [outer [inner](https://inner.test/a_(b))](https://outer.test/x_(y) "title").\n- ![chart](https://img.test/a_(b).png) with ~~old~~ _new_ data.\n```js\nignored();\n```\nDone.\u00a0Next.';
  const expected = 'Session report Read status and outer inner. chart with old new data. Done. Next.';
  assert.equal(call('markdown', 'flattenMarkdownToPlainText', markdown), expected);
  assert.deepEqual(project({ role: 'assistant', content: markdown }, { flattenMarkdown: true }), { role: 'assistant', text: expected });
  assert.equal(project({ role: 'assistant', content: '```js\nconst status = 1;\n```' }, { flattenMarkdown: true }), null);
});

test('preview keeps the latest visible items in transcript order without consuming hidden rows', () => {
  const messages = [
    { role: 'user', content: 'Earlier task.' },
    { role: 'assistant', content: 'Ready.' },
    { role: 'tool', content: 'Tool receipt.' },
    { role: 'assistant', display: false, content: 'Internal note.' },
    { role: 'assistant', content: 'NO_REPLY' },
    { role: 'user', content: 'Next task.' },
  ];
  assert.deepEqual(plain(call('display', 'buildSessionPreviewItems', messages, 2, 240)), [
    { role: 'assistant', text: 'Ready.' }, { role: 'user', text: 'Next task.' },
  ]);
});

test('valid Unicode preview and title cuts use separate UTF-16 limits and markers', () => {
  assert.deepEqual(project({ role: 'user', content: '😀'.repeat(120) }), { role: 'user', text: '😀'.repeat(120) });
  const preview = project({ role: 'user', content: 'A'.repeat(236) + '😀tail' });
  assert.equal(preview.text, 'A'.repeat(236) + '...');
  assert.equal(preview.text.length, 239);
  assert.equal(preview.text.isWellFormed(), true);
  assert.equal(goal('😀'.repeat(30)), '😀'.repeat(30));
  const title = goal('A'.repeat(58) + '😀tail');
  assert.equal(title, 'A'.repeat(58) + '…');
  assert.equal(title.length, 59);
  assert.equal(title.isWellFormed(), true);
  assert.equal(goal('Build a reliable dashboard that presents clear session history and controls'),
    'Build a reliable dashboard that presents clear session…');
});

test('titles prefer metadata and task-bearing sentences; title-only metadata avoids transcript work', () => {
  const derive = (entry, firstUser, external) => call('title', 'deriveSessionTitle', entry, firstUser, external);
  const task = 'Hello there. build the session report. Thanks again.';
  assert.equal(goal(task), 'Build the session report.');
  assert.equal(derive({ sessionId: 'session-a', label: '  Saved  label  ', displayName: 'Display', subject: 'Subject' }, task, 'External'), 'Saved  label');
  assert.equal(derive({ sessionId: 'session-a', displayName: 'Display', subject: 'Subject' }, task, ' External '), 'External');
  assert.equal(derive({ sessionId: 'session-a', displayName: ' Display ', subject: 'Subject' }, task), 'Display');
  assert.equal(derive({ sessionId: 'session-a', subject: ' Subject ' }, task), 'Subject');
  assert.equal(derive({ sessionId: 'session-a' }, task), 'Build the session report.');
  assert.equal(derive({ sessionId: 'session-a', label: 'Saved '.repeat(15) }, task), 'Saved '.repeat(14) + 'Saved');
  const prepare = (entry, flags) => plain(call('title', 'prepareSessionTitleRead', entry, undefined, flags));
  assert.deepEqual(prepare({ sessionId: 'session-a', label: 'Saved label' }, { includeDerivedTitles: true }), { derivedTitle: 'Saved label', needsTranscript: false });
  assert.deepEqual(prepare({ sessionId: 'session-a', label: 'Saved label' }, { includeDerivedTitles: true, includeLastMessage: true }), { derivedTitle: 'Saved label', needsTranscript: true });
  assert.deepEqual(prepare({ sessionId: 'session-a' }, { includeDerivedTitles: true }), { needsTranscript: true });
  assert.deepEqual(prepare({ sessionId: 'session-a', label: 'Saved label' }, { includeLastMessage: true }), { needsTranscript: true });
});

test('exact inline postfilter preserves opaque retained items and never refills after tool removal', () => {
  const assistant = { role: 'assistant', display: false, content: [{ type: 'toolCall', id: 'call-a', name: 'read', arguments: {} }] };
  const custom = { role: 'custom', customType: 'ordinary.notice', details: { opaque: ['kept'] } };
  const functionMessage = { role: 'function', content: 'Kept function result.' };
  const underscoreTool = { role: 'tool_result', content: 'Kept exact role spelling.' };
  const opaque = { opaque: { nested: 'receipt' } };
  const input = [{ role: 'tool' }, assistant, { role: 'toolResult' }, custom,
    { role: 'custom', customType: 'openclaw.nested-tool.v1' }, functionMessage, underscoreTool, opaque, null, 'opaque value'];
  const stripped = call('inline', 'stripToolMessages', input);
  assert.equal(stripped.length, 7);
  for (const [index, item] of [assistant, custom, functionMessage, underscoreTool, opaque, null, 'opaque value'].entries()) assert.equal(stripped[index], item);
  assert.equal(input.length, 10);
  const noRefill = call('inlinePostfilter', 'postfilterInline', { messages: [{ role: 'tool' }, assistant] }, 2);
  assert.equal(noRefill.length, 1);
  assert.equal(noRefill[0], assistant);
  const suffix = call('inlinePostfilter', 'postfilterInline', { messages: input }, 3);
  assert.equal(suffix.length, 3);
  assert.equal(suffix[0], opaque);
  assert.equal(suffix[1], null);
  assert.equal(suffix[2], 'opaque value');
});

test('all loaded original blobs, complete regions and executable hashes retain explicit provenance', () => {
  const evidence = oracle.evidence();
  assert.equal(evidence.reference.commit, SESSION_ENRICHMENT_PIN);
  assert.equal(evidence.reference.tree, '47509a47273231ab15f57252960fe716d7379ffb');
  assert.equal(evidence.reference.trackedClean, true);
  assert.deepEqual(evidence.facadeCalls, []);
  assert.equal(evidence.facadeEdges.length, 3);
  const expected = {
    'src/gateway/session-display-projection.ts': 'e02871211dc4ef2ce8be5d999c15f661f34441d6cb8c505b58e6eec593661f17',
    'packages/normalization-core/src/markdown-plain-text.ts': 'b2670a0d8ee00ae0a9289ac0d418ac84aee90ee688fce5c57183d7ce55f94aed',
    'src/gateway/derive-goal-session-title.ts': '408b00d78fc2bd3730854f137ae96cb19a0e9b47aaffe41a48cac6446324867b',
    'src/gateway/session-utils-core.ts': '228c473714ebea8e61ce453ec34b5e5845a843a7894045950da2583efb841829',
    'src/agents/tools/chat-history-text.ts': '3a2bca85d08f288312fc46efb67a57db36f3d153890c30be51d37b23814b00ed',
  };
  for (const [path, sha256] of Object.entries(expected)) assert.equal(evidence.sources.find(row => row.path === path)?.sha256, sha256, path);
  const root = process.env.OPENCLAW_SESSION_SOURCE ?? '/tmp/openclaw-488631c';
  for (const row of evidence.sources) {
    const bytes = readFileSync(root + '/' + row.path);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), row.sha256);
    assert.equal(row.gitBlob.length, 40);
  }
  for (const row of evidence.regions) {
    const bytes = readFileSync(root + '/' + row.path).subarray(row.startByte, row.endByte);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), row.sha256, row.label);
  }
  assert.equal(evidence.transforms.filter(row => row.kind === 'exact-source-regions').length, 5);
  assert.equal(evidence.regions.length, 7);
  assert.equal(evidence.transforms.filter(row => row.kind === 'exact-statement-sequence').length, 1);
  for (const row of evidence.transforms) assert.match(row.executableSha256, /^[a-f0-9]{64}$/);
  assert.equal(evidence.harness.sha256, createHash('sha256').update(readFileSync(new URL('./session-enrichment-reference.mjs', import.meta.url))).digest('hex'));
});
