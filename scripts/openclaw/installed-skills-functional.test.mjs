import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureInstalledSkills, INSTALLED_SKILLS_PIN } from './capture-installed-skills.mjs';

// Literal order expectations are written independently of captured observations.
const expectedOrders = {
  'body-only-inline': [[0]],
  'metadata-weight-two': [[0, 1]],
  'separate-populations': [[1, 0, 3, 4, 2]],
  'exact-name': [[1, 0]],
  'duplicate-source-names': [[0, 1]],
  'repeated-bounded-owner': [[0], [0], [0]],
  'opaque-owner-metadata-and-read': [[0]],
  'location-note-whole-inert-read': [[0]],
  'ordinary-local-prefix-and-whole-read': [[0]],
};
const coverage = {
  'separate-populations': { bodyIndexed: 2, metadataOnly: 3, truncatedBodies: 0 },
  'opaque-owner-metadata-and-read': { bodyIndexed: 0, metadataOnly: 1, truncatedBodies: 0 },
};
const expectedReadIndexes = {
  'body-only-inline': [0], 'duplicate-source-names': [0],
  'repeated-bounded-owner': [0], 'opaque-owner-metadata-and-read': [0],
  'location-note-whole-inert-read': [0],
  'ordinary-local-prefix-and-whole-read': [0],
};
const expectedWholeSources = [
  'src/agents/tools/installed-skill-tools.ts', 'src/agents/agent-tool-availability.ts',
  'src/agents/installed-skill-catalog.ts', 'src/agents/tool-search-ranking.ts',
  'src/agents/tool-search-index.ts', 'src/agents/code-mode-skills.ts',
  'src/agents/skill-instruction-result.ts', 'src/agents/tools/common.ts',
  'src/agents/tools/tool-results.ts', 'src/agents/tool-input-error.ts', 'src/param-key.ts',
  'src/infra/lru-cache.ts', 'src/infra/abort-signal.ts', 'src/infra/fs-safe.ts', 'packages/retry/src/index.ts',
  ...['record-coerce', 'number-coercion', 'string-coerce', 'string-normalization']
    .map(name => 'packages/normalization-core/src/' + name + '.ts'),
].sort();
const observed = await captureInstalledSkills();

test('whole source factory search has independent ordinary body, population and weighted orders', () => {
  assert.deepEqual(observed.observations.map(row => row.id), Object.keys(expectedOrders));
  for (const row of observed.observations) {
    assert.deepEqual(row.argumentsAfter, {
      id: row.id, entries: row.entries, searches: row.searches.map(search => search.argumentsBefore),
      ...(row.reads.length ? { reads: row.reads.map(read => read.argumentsBefore) } : {}),
    }, row.id);
    assert.equal(row.searches.length, expectedOrders[row.id].length, row.id);
    for (const [index, search] of row.searches.entries()) {
      const details = {
        skills: expectedOrders[row.id][index].map(position => {
          const entry = row.entries[position];
          return { name: entry.name, description: entry.description, location: entry.location };
        }),
        hasMore: false,
        ...(coverage[row.id] ? { coverage: coverage[row.id] } : {}),
      };
      assert.deepEqual(search.result, {
        content: [{ type: 'text', text: JSON.stringify(details, null, 2) }], details,
      }, row.id + '/' + index);
      assert.deepEqual(search.argumentsAfter, search.argumentsBefore, row.id);
    }
  }
  const duplicate = observed.observations.find(row => row.id === 'duplicate-source-names');
  assert.deepEqual(duplicate.searches[0].result.details.skills.map(skill => skill.location),
    ['supplied://first/same', 'supplied://second/same']);
});

test('actual CodeMode whole reads preserve inert instructions, notes and public location formatting', () => {
  for (const row of observed.observations) {
    assert.equal(row.reads.length, expectedReadIndexes[row.id]?.length ?? 0, row.id);
    for (const [index, read] of row.reads.entries()) {
      const entry = row.entries[expectedReadIndexes[row.id][index]];
      const details = { name: entry.name, location: entry.location,
        ...(entry.locationNote === undefined ? {} : { locationNote: entry.locationNote }), content: entry.content };
      const prefix = `Skill location: ${entry.location}\nResolve relative resource paths from the directory containing this SKILL.md.`;
      const text = prefix + (entry.locationNote === undefined ? '' : '\n' + entry.locationNote) + '\n\n' + entry.content;
      assert.deepEqual(read.result, { content: [{ type: 'text', text }], details }, row.id);
      assert.deepEqual(read.argumentsAfter, read.argumentsBefore, row.id);
    }
  }
  const duplicate = observed.observations.find(row => row.id === 'duplicate-source-names');
  assert.equal(duplicate.reads[0].result.details.content, 'First complete instructions');
  const inert = observed.observations.find(row => row.id === 'location-note-whole-inert-read');
  assert.equal(inert.reads[0].result.details.content,
    '# Guide\n\nLiteral $(touch /tmp/installed-skills-source-oracle) stays inert.\nFinal instruction.\n');
});

test('original body cache reuses its same-owner view and opaque readers retain whole-read ownership', () => {
  const bounded = observed.observations.find(row => row.id === 'repeated-bounded-owner');
  const prefixCall = { kind: 'bounded-search-reader', index: 0, maxBytes: 16384, signalPresent: false };
  for (const search of bounded.searches) assert.deepEqual(search.ownerCallsAfter, [prefixCall]);
  assert.deepEqual(bounded.ownerCalls, [prefixCall,
    { kind: 'whole-reader', index: 0, location: 'supplied://owner/guide', signalPresent: false }]);
  assert.deepEqual(bounded.searches[0].result, bounded.searches[2].result);
  const opaque = observed.observations.find(row => row.id === 'opaque-owner-metadata-and-read');
  assert.deepEqual(opaque.searches[0].ownerCallsAfter, []);
  assert.deepEqual(opaque.ownerCalls,
    [{ kind: 'whole-reader', index: 0, location: 'supplied://remote/remote-guide', signalPresent: false }]);
  assert.deepEqual(observed.observations.find(row => row.id === 'separate-populations').ownerCalls, []);
});

test('complete factory definitions and schema presence reproduce the pinned TypeBox source contract', () => {
  const parameters = {
    skills_search: { type: 'object', properties: {
      query: { type: 'string', minLength: 1, maxLength: 1000 },
      limit: { type: 'integer', minimum: 1, maximum: 20 },
    }, required: ['query'] },
    skills_read: { type: 'object', properties: { name: { type: 'string', minLength: 1 } }, required: ['name'] },
  };
  const definitions = [
    { name: 'skills_search', label: 'Search Installed Skills',
      description: 'Find relevant installed, eligible skills by task or exact name, including skills omitted from the prompt directory. Searches names and descriptions, plus bounded instruction text when skill reads are allowed. Returns metadata only; coverage reports any incomplete body indexing. Read the selected skill\'s whole instructions before applying it. Does not search ClawHub or install anything.' },
    { name: 'skills_read', label: 'Read Installed Skill',
      description: 'Load complete SKILL.md instructions for an exact installed skill name. Use a known name directly; search is not required first. Does not execute the skill or grant additional tool permissions.' },
  ].map(tool => ({ ...tool, parameters: parameters[tool.name], outputSchemaDeclared: false,
    outputSchema: null, executePresent: true, availabilityBindingPresent: true }));
  for (const row of observed.observations) assert.deepEqual(row.definitions, definitions, row.id);
});

test('every frozen source observation and provenance field reproduces exactly', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/installed-skills.json', import.meta.url), 'utf8'));
  assert.deepEqual(observed, frozen);
});

test('whole unchanged source modules, actual package bytes and explicit uncalled boundaries have provenance', () => {
  assert.equal(observed.referencePin, INSTALLED_SKILLS_PIN);
  assert.equal(observed.runtime.version, '24.22.1');
  assert.equal(observed.sourceTree.before.tree, '47509a47273231ab15f57252960fe716d7379ffb');
  assert.equal(observed.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(observed.sourceTree.before, observed.sourceTree.after);
  assert.equal(observed.sourceTree.after.trackedClean, true);
  assert.deepEqual(observed.deferredCalls, []);
  assert.deepEqual(observed.sourceRecords.filter(row => row.executed).map(row => row.path).sort(), expectedWholeSources);
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
  for (const edge of edges)
    assert.equal(createHash('sha256').update(edge.generatedCode).digest('hex'), edge.generatedSha256);
  assert.equal(observed.typebox.version, '1.3.37');
  assert.ok(observed.typebox.files.length > 1);
  for (const file of observed.typebox.files) {
    const path = observed.typebox.root + '/' + file.path.slice('typebox/'.length);
    assert.equal(createHash('sha256').update(readFileSync(path)).digest('hex'), file.sha256, file.path);
  }
  assert.equal(observed.boundaries.actualFactory, true);
  assert.equal(observed.boundaries.actualAvailabilityFinalization, true);
  assert.equal(observed.boundaries.actualParameterHelpers, true);
  assert.equal(observed.boundaries.actualResultHelpers, true);
  assert.equal(observed.boundaries.actualCodeModeRead, true);
  assert.equal(observed.boundaries.actualInstructionFormatter, true);
  assert.equal(observed.boundaries.actualLocalFileRead, true);
  assert.equal(observed.boundaries.networkExecuted, false);
  assert.equal(observed.suppliedOwnerCode.sha256,
    createHash('sha256').update(observed.suppliedOwnerCode.code).digest('hex'));
  assert.equal(observed.exporter.sha256,
    createHash('sha256').update(readFileSync(new URL('./capture-installed-skills.mjs', import.meta.url))).digest('hex'));
});

test('ordinary actual local prefix search and full read use original fs-safe source and pinned package bytes', () => {
  const local = observed.observations.find(row => row.id === 'ordinary-local-prefix-and-whole-read');
  const content = '---\nname: local-guide\ndescription: Operations\n---\n\nUse kestrel deployment. Keep the entire rollback procedure.\n';
  const location = '/tmp/synapsis-skills290-source-local-fixture/SKILL.md';
  assert.deepEqual(local.entries, [{ name: 'local-guide', description: 'Operations',
    content, mode: 'local-file', location }]);
  assert.deepEqual(local.searches[0].argumentsBefore, { query: 'kestrel' });
  assert.deepEqual(local.searches[0].result.details,
    { skills: [{ name: 'local-guide', description: 'Operations', location }], hasMore: false });
  assert.deepEqual(local.reads[0].result.details, { name: 'local-guide', location, content });
  assert.deepEqual(local.ownerCalls, []);
  assert.deepEqual(observed.localFixture, { path: location, bytes: Buffer.byteLength(content),
    sha256: createHash('sha256').update(content).digest('hex'), removedAfterCapture: true });
  assert.deepEqual(observed.deferredVectors, []);
  assert.equal(observed.boundaries.actualLocalFileWrapper, true);
  assert.equal(observed.boundaries.actualPinnedFsSafeExports, true);
  assert.equal(observed.boundaries.commonFileReadHelperCalled, false);
  const originalWrapper = observed.sourceRecords.find(row => row.path === 'src/infra/fs-safe.ts');
  assert.equal(originalWrapper.wholeModule, true);
  assert.equal(originalWrapper.originalSourceExecuted, true);
  for (const [importer, specifier] of [
    ['src/agents/installed-skill-catalog.ts', '../infra/fs-safe.js'],
    ['src/agents/tools/common.ts', '../../infra/fs-safe.js'],
  ]) assert.deepEqual(observed.importBindings.find(edge => edge.importer === importer && edge.specifier === specifier),
    { importer, specifier, kind: 'whole-unchanged-source-module', target: 'src/infra/fs-safe.ts' });
  assert.deepEqual(observed.fsSafe.packages.map(pkg => [pkg.package, pkg.version, pkg.files.length]),
    [['@openclaw/fs-safe', '0.26.8', 701], ['@openclaw/fs-safe-linux-x64-gnu', '0.26.8', 2]]);
  assert.deepEqual(observed.fsSafe.packages.map(pkg => pkg.tarSha256), [
    '842ef410fc59283909574a09343bf98ee5fbe2fe6d8cb743b5b409113f939ecb',
    '4af6d18c459a06722afbff6f62efaa667de247114eeddf03e4c82f1cf28898ae',
  ]);
  for (const pkg of observed.fsSafe.packages) for (const file of pkg.files) {
    const bytes = readFileSync(pkg.root + '/' + file.path);
    assert.equal(bytes.length, file.bytes, file.path);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), file.sha256, file.path);
  }
  const packageEdges = observed.importBindings.filter(edge => edge.kind === 'actual-pinned-package-export-namespace');
  assert.deepEqual(packageEdges.map(edge => edge.specifier).sort(),
    ['advanced', 'errors', 'output', 'path', 'root', 'secure-file', 'walk'].map(name => '@openclaw/fs-safe/' + name).sort());
  assert.ok(packageEdges.every(edge => edge.package === '@openclaw/fs-safe' && edge.version === '0.26.8'));
  assert.equal(typeof observed.fsSafe.nativeBindingLoaded, 'boolean');
  assert.equal(observed.fsSafe.artifactReceipt.sha256,
    createHash('sha256').update(readFileSync(observed.fsSafe.artifactReceipt.path)).digest('hex'));
});
