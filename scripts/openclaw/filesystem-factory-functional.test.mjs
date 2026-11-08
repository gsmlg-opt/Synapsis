// Source-derived ordinary constructor expectations frozen before capture implementation.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { captureFilesystemFactories } from './capture-filesystem-factories.mjs';

const root = process.env.OPENCLAW_FILESYSTEM_SOURCE ?? '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = x => createHash('sha256').update(x).digest('hex');
const string = description => ({ type: 'string', ...(description ? { description } : {}) });
const integer = extra => ({ type: 'integer', ...extra });
const literal = value => ({ type: typeof value, const: value });
const object = (properties, required, closed = false) => ({ type: 'object', properties, required, ...(closed ? { additionalProperties: false } : {}) });
const union = anyOf => ({ anyOf });
const boolean = { type: 'boolean' };
const path = string('File path; relative/absolute.');
const changed = literal(true);
const same = object({ changed: literal(false) }, ['changed'], true);
const patch = { diff: string(), patch: string(), firstChangedLine: integer({ minimum: 1 }) };
const bounds = { minimum: 1, maximum: 9007199254740991 };
const continuationFields = { offset: integer(bounds), limit: integer(bounds) };
const continuation = union([
  object({ kind: literal('line'), ...continuationFields }, ['kind', 'offset'], true),
  object({ kind: literal('cursor'), ...continuationFields, cursor: integer({ minimum: 0, maximum: 9007199254740991 }) }, ['kind', 'offset', 'cursor'], true),
]);
const truncation = object({
  truncated: changed, truncatedBy: union([literal('lines'), literal('bytes')]),
  totalLines: integer({ minimum: 0 }), totalBytes: integer({ minimum: 0 }),
  outputLines: integer({ minimum: 0 }), outputBytes: integer({ minimum: 0 }),
  lastLinePartial: boolean, firstLineExceedsLimit: boolean,
  maxLines: integer({ minimum: 1 }), maxBytes: integer({ minimum: 1 }),
}, ['truncated', 'truncatedBy', 'totalLines', 'totalBytes', 'outputLines', 'outputBytes', 'lastLinePartial', 'firstLineExceedsLimit', 'maxLines', 'maxBytes'], true);
const expected = {
  read: {
    name: 'read', label: 'read',
    description: 'Read text/image file (jpg/png/gif/webp/bmp); images attach to model context. Text caps 2000 lines or 50KB. Continue with offset/limit, or cursor within a long line.',
    parameters: object({ path, offset: integer({ minimum: 1, description: 'Start line; 1-based.' }),
      limit: { type: 'number', description: 'Max lines.' },
      cursor: integer({ minimum: 0, description: 'Character position within the start line; 0-based.' }),
      optional: { ...literal(true), description: 'Missing paths return structured not_found instead of failing.' },
    }, ['path']),
    outputSchema: union([
      object({ kind: literal('text'), content: string() }, ['kind', 'content'], true),
      object({ kind: literal('image'), content: string(), mimeType: string() }, ['kind', 'content', 'mimeType'], true),
      object({ kind: literal('truncated'), content: string(), truncation, continuation }, ['kind', 'content', 'truncation', 'continuation'], true),
      object({ kind: literal('not_found'), status: literal('not_found'), path: string(), optional: literal(true) }, ['kind', 'status', 'path', 'optional'], true),
    ]),
  },
  write: {
    name: 'write', label: 'write', description: 'Write/overwrite file; creates parent directories.',
    parameters: object({ path, content: string('File content.') }, ['path', 'content']),
    outputSchema: union([same,
      object({ changed, created: literal(true), ...patch }, ['changed', 'created', 'diff', 'patch'], true),
      object({ changed, created: literal(false), ...patch }, ['changed', 'created', 'diff', 'patch'], true),
      object({ changed, created: boolean }, ['changed'], true),
    ]),
  },
  edit: {
    name: 'edit', label: 'edit',
    description: 'Exact single-file replacements. oldText unique/non-overlapping against original. Merge nearby changes; omit large unchanged spans.',
    parameters: object({ path, edits: { type: 'array', items: object({
      oldText: string('Exact original text; unique and non-overlapping in this call.'), newText: string('Replacement text.'),
    }, ['oldText', 'newText']), description: 'Targeted replacements against original file; no overlap/nesting. Merge nearby changes.' } }, ['path', 'edits']),
    outputSchema: union([same, object({ changed, ...patch }, ['changed', 'diff', 'patch'], true)]),
  },
};
const cwd = '/reference/workspace';
const recipes = [
  ['read/default', 'read', [cwd]], ['read/empty-options', 'read', [cwd, {}]],
  ['read/prepared', 'read', [cwd, { autoResizeImages: true, maxBytes: 8192, modelHasVision: true }]],
  ['write/default', 'write', [cwd]], ['write/empty-options', 'write', [cwd, {}]],
  ['edit/default', 'edit', [cwd]], ['edit/empty-options', 'edit', [cwd, {}]],
];
const report = await captureFilesystemFactories(root);

test('complete source factories receive the real cwd/options signature and retain exact literal input/output metadata', () => {
  assert.equal(report.referenceCommit, pin);
  assert.equal(report.rows.length, recipes.length);
  for (const [id, tool, args] of recipes) {
    const row = report.rows.find(x => x.id === id);
    assert.ok(row, id);
    assert.equal(row.source, `src/agents/sessions/tools/${tool}.ts`);
    assert.equal(row.export, `create${tool[0].toUpperCase() + tool.slice(1)}Tool`);
    assert.deepEqual(row.args, args);
    assert.deepEqual(row.metadata, expected[tool]);
    assert.equal(row.executeObserved, true);
    assert.equal(row.prepareArgumentsObserved, tool === 'edit');
    assert.equal(row.executeInvoked, false);
    assert.deepEqual(row.attemptedCalls, []);
    assert.equal(row.assemblyVerified, false);
    assert.equal(row.actionVerified, false);
  }
});

test('captures unchanged complete factories and real constructor helper provenance with applicable license and dependency hashes', () => {
  assert.equal(report.typebox.version, '1.3.37');
  assert.ok(report.typebox.files.length > 0);
  assert.ok(report.sourceFiles.some(x => x.path === 'LICENSE'));
  for (const tool of ['read', 'write', 'edit']) {
    const source = report.sourceFiles.find(x => x.path === `src/agents/sessions/tools/${tool}.ts`);
    assert.ok(source);
    assert.equal(source.execution, 'whole-module');
  }
  assert.ok(report.sourceFiles.some(x => x.path === 'src/agents/sessions/tools/tool-definition-wrapper.ts' && x.execution === 'whole-module'));
  assert.ok(report.sourceFiles.some(x => x.path === 'src/agents/sessions/tools/tool-schemas.ts' && x.execution === 'whole-module'));
  for (const file of report.sourceFiles) {
    assert.equal(file.sha256, hash(file.content));
    assert.equal(file.content, readFileSync(join(root, file.path), 'utf8'));
  }
  for (const row of report.rows) {
    assert.ok(row.stubs.length > 0);
    for (const source of row.loadedFiles) assert.equal(source.sha256, hash(readFileSync(join(root, source.path))));
    for (const projection of row.projections) {
      const bytes = readFileSync(join(root, projection.source));
      assert.equal(projection.sourceSha256, hash(bytes));
      assert.equal(projection.generatedSha256, hash(projection.generatedCode));
      for (const selection of projection.selections) assert.equal(selection.sha256, hash(bytes.subarray(selection.startByte, selection.endByte)));
    }
  }
});

test('fresh capture equals the entire frozen report and independently repeated constructors', async () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/filesystem-factories.json', import.meta.url), 'utf8'));
  assert.deepEqual(report, frozen);
  assert.deepEqual(await captureFilesystemFactories(root), report);
});
