// Ordinary native Decisions success vectors, executed from complete pinned source.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureOpenAIDecisions } from './capture-openai-decisions.mjs';

const capture = await captureOpenAIDecisions();
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = value => createHash('sha256').update(value).digest('hex');

test('eleven ordinary source requests use native Decisions, preserve model, usage and release once', () => {
  assert.equal(rows.size, 11);
  for (const row of rows.values()) {
    assert.equal(row.request.method, 'POST');
    assert.equal(row.request.url, row.baseUrl + '/decisions');
    assert.equal(row.request.timeoutMs, 30000);
    assert.equal(row.request.body.model, 'gpt-6-luna');
    assert.deepEqual(row.request.body.questions.map(q => q.name), Object.keys(row.batch.questions));
    assert.equal(row.outcome.status, 'ok');
    assert.equal(row.outcome.result.model, 'returned-decision-model');
    assert.deepEqual(row.outcome.result.usage, { inputTokens: 42, outputTokens: 0 });
    assert.equal(row.releaseCount, 1);
    assert.equal(row.cleanupCount, 1);
    assert.deepEqual(row.readerCalls, [{ maxBytes: 1048576 }]);
  }
});

test('native boolean/choice/score mappings retain explicit values and unnormalized distributions', () => {
  const row = rows.get('explicit-choice-estimates');
  const [predicate, choice, score] = row.request.body.questions;
  assert.deepEqual(predicate, { type: 'predicate', name: 'damaged',
    instructions: 'Is the parcel damaged?\nTrue criterion: Damaged parcel\nFalse criterion: null' });
  assert.deepEqual(choice, { type: 'choice', name: 'route', instructions: '{"task":"Choose route"}',
    choices: [{ value: 'sales', description: '["New order"]' }, { value: 'support', description: '{"team":"support"}' }] });
  assert.deepEqual(score, { type: 'score', name: 'urgency', instructions: '', levels: [
    { label: '0', description: 'Low' }, { label: '1', description: '{"level":"Medium"}' }, { label: '2', description: 'null' }] });
  assert.deepEqual(row.outcome.result.answers, {
    damaged: { type: 'boolean', probabilityTrue: 0.95 },
    route: { type: 'choice', choice: 'support', confidence: 1.7, probabilities: { support: 0.2, sales: 0.7 } },
    urgency: { type: 'score', score: 1.25, confidence: -0.2, probabilities: [0.05, 0.65, 0.3] },
  });
});

test('text JSON legacy null/array image and missing/null instructions stay distinct', () => {
  assert.equal(rows.get('text-three').request.body.input, '  The parcel is damaged. 😀\n');
  assert.equal(rows.get('json-three').request.body.input, '{"count":2,"report":"The parcel is damaged"}');
  assert.deepEqual(rows.get('legacy-text').batch.state, { type: 'text', text: 'Legacy supplied evidence' });
  assert.deepEqual(rows.get('legacy-null').batch.state, { type: 'json', value: null });
  assert.equal(rows.get('legacy-null').request.body.input, 'null');
  assert.equal(rows.get('legacy-array').request.body.input, '[{"fact":"one"},null,"two"]');
  for (const id of ['image-text', 'image-only']) {
    const row = rows.get(id);
    const expected = [...(id === 'image-text' ? [{ type: 'input_text', text: 'Inspect supplied image only' }] : []),
      { type: 'input_image', image_url: row.arguments.state.dataUri }];
    assert.deepEqual(row.request.body.input, [{ role: 'user', content: expected }]);
  }
  assert.equal(rows.get('missing-instructions').request.body.questions[0].instructions, '');
  assert.equal(rows.get('null-instructions').request.body.questions[0].instructions, 'null');
});

test('whole modules and per-import generated facades have exact executable provenance', () => {
  const whole = capture.sourceRecords.filter(row => row.executed);
  assert.equal(whole.length, 9);
  for (const row of whole) {
    const bytes = readFileSync(join('/tmp/openclaw-488631c', row.path));
    assert.equal(row.wholeModule, true);
    assert.equal(row.sha256, hash(bytes));
    assert.equal(row.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })));
  }
  for (const binding of capture.importBindings) {
    if (binding.generatedCode) assert.equal(binding.generatedSha256, hash(binding.generatedCode));
    assert.ok(binding.importer && binding.specifier);
  }
  assert.equal(capture.exporter.sha256, hash(readFileSync(new URL('./capture-openai-decisions.mjs', import.meta.url))));
  assert.equal(capture.runtime.sha256, hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.runtime.version, '24.22.1');
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
});

test('fixture boundaries disclose source support, lower facades and host serialization differences', () => {
  for (const term of ['Whole unchanged', 'Synthetic successful HTTP', 'timeout/overflow/cancellation', 'Jason numeric', 'list/sort/tags/box']) {
    assert.ok(capture.limits.some(line => line.includes(term)), term);
  }
  assert.deepEqual(capture.deferredCalls, []);
});

test('fresh complete-source capture exactly reproduces the frozen fixture', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_provider/test/fixtures/openclaw/488631c/openai-decisions.json', import.meta.url)));
  assert.deepEqual(capture, fixture);
  assert.deepEqual(await captureOpenAIDecisions(), fixture);
});
