import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureSkillSearchRanking, SKILL_SEARCH_PIN } from './capture-skill-search-ranking.mjs';

// These fixed expected orders are authored independently of the VM observations.
const expected = {
  multiword: ['workflow', 'alpha'], reordered: ['workflow', 'alpha'],
  'doubled-stem': ['runner'], 'repeated-suffix': ['calendar'],
  'ies-policy': ['handbook'], 'ies-cookie': ['recipe'],
  'identifier-parts': ['HTTPServer42_reader'], 'non-latin': ['知识整理'],
  'exact-case': ['review', 'Review'], 'first-folded-name': ['REVIEW', 'Review'],
  'padded-name': ['Review', 'review'], 'punctuation-name': ['.'],
  frequency: ['beta', 'alpha'], length: ['beta', 'alpha'], 'name-tie': ['alpha', 'zeta'],
  'duplicate-query': ['beta', 'alpha'], 'stable-duplicates': ['same', 'same'],
  'utf16-name-tie': ['😀', '\uE000'], 'greek-final-sigma': ['greek-guide'],
  'dotted-i': ['İSTANBUL'], 'literal-skill-query': ['lookup'], 'kept-double-stem': ['pipeline'],
};
const observed = await captureSkillSearchRanking();

test('ordinary metadata searches satisfy independent lexical, exact-name and UTF16 orders', () => {
  assert.equal(observed.observations.length, Object.keys(expected).length);
  for (const row of observed.observations) {
    assert.deepEqual(row.result.skills.map(skill => skill.name), expected[row.id], row.id);
    assert.equal(row.result.hasMore, false, row.id);
    assert.deepEqual(row.result.coverage, { bodyIndexed: 0, metadataOnly: row.entries.length, truncatedBodies: 0 }, row.id);
    assert.deepEqual(row.argumentsAfter, { id: row.id, query: row.query, entries: row.entries }, row.id);
    for (const skill of row.result.skills) {
      const original = row.entries.find(entry => entry.location === skill.location);
      assert.deepEqual(skill, { name: original.name, description: original.description, location: original.location }, row.id);
    }
  }
  const duplicates = observed.observations.find(row => row.id === 'stable-duplicates');
  assert.deepEqual(duplicates.result.skills.map(skill => skill.location), ['supplied://skills/first', 'supplied://skills/second']);
  assert.deepEqual(observed.observations.find(row => row.id === 'multiword').result,
    observed.observations.find(row => row.id === 'reordered').result);
  assert.deepEqual(observed.observations.find(row => row.id === 'frequency').result,
    observed.observations.find(row => row.id === 'duplicate-query').result);
});

test('all fields of frozen source observations and provenance reproduce exactly', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/skill-search-ranking.json', import.meta.url), 'utf8'));
  assert.deepEqual(observed, frozen);
});

test('whole unchanged ranking modules and declared uncalled edges retain genuine provenance', () => {
  assert.equal(observed.referencePin, SKILL_SEARCH_PIN);
  assert.equal(observed.runtime.version, '24.22.1');
  assert.equal(observed.sourceTree.before.tree, '47509a47273231ab15f57252960fe716d7379ffb');
  assert.equal(observed.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(observed.sourceTree.before, observed.sourceTree.after);
  assert.equal(observed.sourceTree.after.trackedClean, true);
  assert.deepEqual(observed.deferredCalls, []);
  const whole = observed.sourceRecords.filter(row => row.executed);
  assert.deepEqual(whole.map(row => row.path).sort(), [
    'packages/normalization-core/src/record-coerce.ts', 'src/agents/installed-skill-catalog.ts',
    'src/agents/tool-search-index.ts', 'src/agents/tool-search-ranking.ts', 'src/infra/lru-cache.ts',
  ]);
  for (const row of observed.sourceRecords) {
    const bytes = readFileSync('/tmp/openclaw-488631c/' + row.path);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), row.sha256, row.path);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), row.gitBlob, row.path);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(row.originalSourceExecuted, true);
      assert.match(row.executableSha256, /^[a-f0-9]{64}$/);
    }
  }
  const edges = observed.importBindings.filter(edge => edge.kind === 'throwing-uncalled-import-edge');
  assert.equal(edges.length, 4);
  for (const edge of edges) assert.equal(createHash('sha256').update(edge.generatedCode).digest('hex'), edge.generatedSha256);
  assert.equal(observed.boundaries.metadataOnly, true);
  assert.equal(observed.boundaries.eligibilityExecuted, false);
  assert.equal(observed.boundaries.bodyReadExecuted, false);
  assert.equal(observed.exporter.sha256, createHash('sha256').update(readFileSync(new URL('./capture-skill-search-ranking.mjs', import.meta.url))).digest('hex'));
});
