// Ordinary positive projection behavior from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b.
// Exercise the packaged implementation directly; no runtime source checkout or oracle.
import assert from 'node:assert/strict';
import test from 'node:test';
import {
  deriveSessionTitle,
  projectRows,
  projectSessionDisplayMessage,
} from '../src/session-directory/session-projection.mjs';

const entry = { sessionId: 'session-projection', updatedAt: 1 };
const signature = phase => JSON.stringify({ v: 1, phase });

test('metadata title precedence and goal titles retain original whitespace and UTF-16 rules', () => {
  const task = 'Hello there. build the session report. Thanks again.';
  assert.equal(deriveSessionTitle({ ...entry, label: '  Saved  label  ', displayName: 'Display', subject: 'Subject' }, task, 'External'), 'Saved  label');
  assert.equal(deriveSessionTitle({ ...entry, displayName: 'Display', subject: 'Subject' }, task, ' External '), 'External');
  assert.equal(deriveSessionTitle({ ...entry, displayName: ' Display ', subject: 'Subject' }, task), 'Display');
  assert.equal(deriveSessionTitle({ ...entry, subject: ' Subject ' }, task), 'Subject');
  assert.equal(deriveSessionTitle(entry, task), 'Build the session report.');
  assert.equal(deriveSessionTitle(entry, '😀'.repeat(30)), '😀'.repeat(30));
  const title = deriveSessionTitle(entry, 'A'.repeat(58) + '😀tail');
  assert.equal(title, 'A'.repeat(58) + '…');
  assert.equal(title.length, 59);
  assert.equal(title.isWellFormed(), true);
  assert.equal(deriveSessionTitle(entry, 'Build a reliable dashboard that presents clear session history and controls'),
    'Build a reliable dashboard that presents clear session…');
});

test('row flags expose requested metadata and stop probing after usable title and preview text', () => {
  assert.deepEqual(projectRows([{ entry: { ...entry, label: 'Saved label' } }]), [
    { needsHead: false, needsTail: false },
  ]);
  assert.deepEqual(projectRows([{ entry: { ...entry, label: 'Saved label' } }], { includeDerivedTitles: true }), [
    { derivedTitle: 'Saved label', needsHead: false, needsTail: false },
  ]);
  assert.deepEqual(projectRows([{ entry }], { includeDerivedTitles: true, includeLastMessage: true }), [
    { needsHead: true, needsTail: true },
  ]);
  assert.deepEqual(projectRows([{
    entry,
    head: [{ role: 'user', content: 'Hello there. build the session report. Thanks again.' }],
    tail: [
      { role: 'assistant', content: '**Report** ready.' },
      { role: 'tool', content: 'Tool receipt.' },
      { role: 'assistant', content: 'Internal note.', display: false },
      { role: 'assistant', content: 'NO_REPLY' },
    ],
  }], { includeDerivedTitles: true, includeLastMessage: true }), [
    { derivedTitle: 'Build the session report.', lastMessagePreview: 'Report ready.', needsHead: false, needsTail: false },
  ]);
  assert.deepEqual(projectRows([{
    entry: { ...entry, displayName: 'Local name' },
    externalDisplayName: 'External name',
    tail: [{ role: 'user', content: 'Latest user task.' }],
  }], { includeDerivedTitles: true, includeLastMessage: true }), [
    { derivedTitle: 'External name', lastMessagePreview: 'Latest user task.', needsHead: false, needsTail: false },
  ]);
});

test('nested Markdown labels and balanced destinations flatten before the 240 UTF-16 cut', () => {
  const markdown = '# **Session** report\n> Read `status` and [outer [inner](https://inner.test/a_(b))](https://outer.test/x_(y) "title").\n- ![chart](https://img.test/a_(b).png) with ~~old~~ _new_ data.\n```js\nignored();\n```\nDone.\u00a0Next.';
  const expected = 'Session report Read status and outer inner. chart with old new data. Done. Next.';
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: markdown }, { flattenMarkdown: true }),
    { role: 'assistant', text: expected });
  assert.deepEqual(projectRows([{ entry, tail: [{ role: 'assistant', content: markdown }] }], { includeLastMessage: true }), [
    { lastMessagePreview: expected, needsHead: false, needsTail: false },
  ]);
  const longUrl = 'https://example.com/' + 'x'.repeat(240);
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: `Read the [report](${longUrl}/report_(Q3)) and then deploy.` }, { flattenMarkdown: true }),
    { role: 'assistant', text: 'Read the report and then deploy.' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'user', content: '😀'.repeat(120) }),
    { role: 'user', text: '😀'.repeat(120) });
  const preview = projectSessionDisplayMessage({ role: 'user', content: 'A'.repeat(236) + '😀tail' });
  assert.equal(preview.text, 'A'.repeat(236) + '...');
  assert.equal(preview.text.length, 239);
  assert.equal(preview.text.isWellFormed(), true);
});

test('signed final answers outrank unphased text and persisted display content supplies the preview', () => {
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: [
    { type: 'text', text: 'Working on the report.', textSignature: signature('commentary') },
    { type: 'text', text: 'Legacy text.' },
    { type: 'text', text: 'Report ready.', textSignature: signature('final_answer') },
    { type: 'text', text: 'Two sessions included.', textSignature: signature('final_answer') },
  ] }), { role: 'assistant', text: 'Report ready.\nTwo sessions included.' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: '  Legacy answer.  ' }),
    { role: 'assistant', text: 'Legacy answer.' });
  const message = {
    role: 'assistant',
    content: [{ type: 'text', text: 'Model source.' }],
    openclawDisplayContent: [{ type: 'text', text: 'Persisted visible answer.' }],
  };
  const before = structuredClone(message);
  assert.deepEqual(projectRows([{ entry, tail: [message, { role: 'assistant', phase: 'commentary', content: 'Working.' }] }], { includeLastMessage: true }), [
    { lastMessagePreview: 'Persisted visible answer.', needsHead: false, needsTail: false },
  ]);
  assert.deepEqual(projectSessionDisplayMessage(message, { view: 'model-context' }),
    { role: 'assistant', text: 'Model source.' });
  assert.deepEqual(message, before);
});

test('silent and heartbeat controls preserve explicit visible text and forwarded acknowledgements', () => {
  assert.deepEqual(projectRows([{ entry, tail: [
    { role: 'assistant', content: 'Disk usage crossed 95 percent.' },
    { role: 'assistant', content: 'NO_REPLY' },
    { role: 'assistant', content: 'HEARTBEAT_OK' },
  ] }], { includeLastMessage: true }), [
    { lastMessagePreview: 'Disk usage crossed 95 percent.', needsHead: false, needsTail: false },
  ]);
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'NO_REPLY', display: true }),
    { role: 'assistant', text: 'NO_REPLY' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'NO_REPLY', openclawDeliveryMirror: {
    kind: 'message-tool-source-reply', final: true, sourceTurnId: 'source-run',
  } }), { role: 'assistant', text: 'NO_REPLY' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'HEARTBEAT_OK', provenance: {
    kind: 'inter_session', sourceTool: 'sessions_send',
  } }), { role: 'assistant', text: 'HEARTBEAT_OK' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'NO_REPLY.' }),
    { role: 'assistant', text: 'NO_REPLY.' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'NO_REPLY\nREADY' }),
    { role: 'assistant', text: 'READY' });
});

test('managed relative MEDIA directives disappear while remote directives and literal code remain', () => {
  const message = {
    role: 'assistant',
    content: 'Artifacts ready\nMEDIA:https://cdn.example.com/legacy.jpg\nMEDIA:./proof.png\nUse `MEDIA:./proof.png` literally.\nMEDIA:./hook-added.png',
    openclawDelivery: { mediaUrls: ['./proof.png'] },
  };
  const before = structuredClone(message);
  assert.deepEqual(projectSessionDisplayMessage(message), {
    role: 'assistant',
    text: 'Artifacts ready\nMEDIA:https://cdn.example.com/legacy.jpg\nUse `MEDIA:./proof.png` literally.\nMEDIA:./hook-added.png',
  });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'assistant', content: 'Ordinary remote link: https://example.com/report.png' }),
    { role: 'assistant', text: 'Ordinary remote link: https://example.com/report.png' });
  assert.deepEqual(message, before);
});

test('generated user envelopes strip while authored brackets and actual task text survive', () => {
  assert.deepEqual(projectSessionDisplayMessage({ role: 'user', content: [
    { type: 'text', text: '[WebChat Alex] Build the report.' },
    { type: 'input_text', text: 'Use current sessions.' },
  ] }), { role: 'user', text: 'Build the report.\nUse current sessions.' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'user', content: '[2026-11-05 10:20] Review sessions.' }),
    { role: 'user', text: 'Review sessions.' });
  assert.deepEqual(projectSessionDisplayMessage({ role: 'user', content: '[Planning] Review sessions.' }),
    { role: 'user', text: '[Planning] Review sessions.' });
  assert.deepEqual(projectRows([{ entry, head: [
    { role: 'user', content: 'Build forwarded report.', provenance: { kind: 'inter_session', sourceTool: 'sessions_send' } },
    { role: 'user', content: '/status' },
    { role: 'user', content: '[OpenClaw heartbeat poll]' },
    { role: 'user', content: '[OpenClaw exec completion]' },
    { role: 'user', content: '[WebChat Alex] Hello there. build the session report. Thanks again.' },
    { role: 'user', content: 'Build a different report.' },
  ] }], { includeDerivedTitles: true }), [
    { derivedTitle: 'Build the session report.', needsHead: false, needsTail: false },
  ]);
});

test('accepted host title sources stop head probing even when no human goal title is derived', () => {
  assert.deepEqual(projectRows([{ entry, head: [
    { role: 'user', content: '# AGENTS.md instructions for /workspace' },
    { role: 'user', content: 'Build a later task.' },
  ] }], { includeDerivedTitles: true }), [
    { needsHead: false, needsTail: false },
  ]);
});
