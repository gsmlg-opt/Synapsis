// Ordinary schema metadata/provenance only; no factory or action invocation.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative } from 'node:path';
import { test } from 'node:test';
import { captureCronSchemas } from './capture-cron-schemas.mjs';

const root = process.env.OPENCLAW_CRON_SOURCE ?? '/tmp/openclaw-488631c';
const hash = value => createHash('sha256').update(value).digest('hex');
const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', '488631c18fae7cc541ba8fc8beff6cbb0438787b'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
assert.equal(listing.status, 0, listing.stderr);
for (const [args, expected] of [[['rev-parse', 'HEAD'], '488631c18fae7cc541ba8fc8beff6cbb0438787b\n'], [['status', '--porcelain', '--untracked-files=no'], '']]) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, expected);
}
const files = listing.stdout.trim().split('\n').filter(path => path.endsWith('.ts'))
  .map(path => ({ path, sha256: hash(readFileSync(join(root, path))) }));
const rows = await captureCronSchemas(root, files);

test('captures the real no-argument cron input builder and complete output export', () => {
  assert.deepEqual(rows.map(row => [row.id, row.export, row.args, row.evidence]), [
    ['cron/schema/default-input', 'createCronToolSchema', [], 'schema-builder'],
    ['cron/schema/complete-output', 'CronToolOutputSchema', [], 'schema-export'],
  ]);
  const [input, output] = rows;
  assert.equal(input.schema.parameters.type, 'object');
  assert.deepEqual(input.schema.parameters.required, ['action']);
  assert.deepEqual(input.schema.actions, ['add', 'get', 'list', 'remove', 'run', 'runs', 'status', 'update', 'wake']);
  assert.equal(input.schema.parameters.properties.job.properties.schedule.properties.everyMs.type, 'integer');
  const annotation = output.schema.parameters['x-openclaw-input-discriminator'];
  assert.equal(annotation.version, 1);
  assert.equal(annotation.inputProperty, 'action');
  assert.deepEqual(Object.keys(annotation.mapping).sort(), ['add', 'get', 'list', 'next_check', 'record_result', 'remove', 'run', 'runs', 'scratch_get', 'scratch_set', 'status', 'update', 'wake']);
  assert.equal(output.schema.parameters.anyOf.length, 13);
});

test('fresh VMs deterministically reproduce full input and output schema evidence', async () => {
  assert.deepEqual(await captureCronSchemas(root, files), rows);
  for (const row of rows) {
    assert.deepEqual(JSON.parse(row.schema.schemaJson), row.schema.parameters);
    assert.equal(row.schema.schemaSha256, hash(row.schema.schemaJson));
  }
});

const expectedBoundary = { schemaConstructionOnly: true, factoryInvoked: false, actionsExecuted: false,
  inputValidationInvoked: false, servicesStarted: false, dynamicImportsInvoked: false,
  eligibilityEstablished: false, registrationInvoked: false, runtimeAssemblyInvoked: false };
const protocol = 'packages/gateway-protocol/src/schema/';
const expectedRegions = {
  'src/agents/schema/typebox.ts': { lines: [[50, 53], [69, 81]], exports: ['optionalPositiveIntegerSchema', 'optionalNonNegativeIntegerSchema', 'optionalStringEnum', 'stringEnum'],
    prefix: 'import {Type} from "typebox";\nexport {optionalStringEnum,stringEnum} from "./string-enum.js";\n' },
  'src/gateway/cron-creator-authority-grant.ts': { lines: [[29, 35]], exports: ['CRON_MANAGEMENT_METHODS'], prefix: '' },
  [protocol + 'primitives.ts']: { lines: [[26, 26]], exports: ['NonEmptyString'], prefix: 'import {Type} from "typebox";\n' },
  [protocol + 'logs-chat.ts']: { lines: [[128, 157]], exports: ['AgentActivityItemSchema', 'ChatHistoryActivitySchema'],
    prefix: 'import {Type,type Static} from "typebox";\nimport {closedObject} from "./closed-object.js";\nimport {NonEmptyString} from "./primitives.js";\nimport {stringLiteralUnion} from "./string-literal-union.js";\n' },
  'src/cron/stream-approval-outcome.ts': { lines: [[5, 19]], exports: ['CronStreamApprovalEndedSchema'], prefix: 'import {Type} from "typebox";\n' },
};
const expectedFiles = [
  ['packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
    'src/agents/schema/cached-schema.ts', 'src/agents/schema/string-enum.ts', 'src/agents/schema/typebox.ts',
    'src/agents/tools/automations-tool-name.ts', 'src/agents/tools/cron-tool-schema.ts', 'src/agents/tools/gateway-schema.ts',
    'src/gateway/cron-creator-authority-grant.ts', 'src/infra/map-size.ts'],
  ['packages/gateway-protocol/src/failover-reasons.ts',
    ...['closed-object.ts', 'cron-shared.ts', 'cron.ts', 'failover-reason.ts', 'logs-chat.ts', 'primitives.ts', 'string-literal-union.ts'].map(name => protocol + name),
    'packages/normalization-core/src/record-coerce.ts', 'src/agents/schema/tool-output-schema.ts',
    'src/agents/tools/cron-tool-output-schema.ts', 'src/cron/stream-approval-outcome.ts'],
];

test('retains the exact schema-only source, alias and deferred-validation boundary', () => {
  rows.forEach((row, index) => {
    assert.equal(row.status, 'captured');
    assert.equal(row.context, 'schema/default');
    assert.equal(row.referenceTool, 'automations');
    assert.deepEqual(row.captureRuntime, { node: process.version });
    assert.deepEqual(row.boundaries, expectedBoundary);
    assert.equal(row.executeInvoked, false);
    assert.deepEqual(row.attemptedCalls, []);
    assert.deepEqual(row.configBindings, []);
    assert.deepEqual(row.loadedFiles.map(file => file.path), expectedFiles[index]);
    const source = index === 0 ? 'packages/normalization-core/src/number-coercion.ts' : 'packages/normalization-core/src/record-coerce.ts';
    assert.deepEqual(row.sourceAliases, [{ importer: index === 0 ? row.source : 'src/agents/schema/tool-output-schema.ts',
      specifier: '@openclaw/normalization-core/' + (index === 0 ? 'number-coercion' : 'record-coerce'),
      source, sourceSha256: hash(readFileSync(join(root, source))), kind: 'whole-source-module' }]);
    assert.deepEqual(row.stubs, index === 0 ? [
      { importer: row.source, specifier: '../../cron/pacing.js', exports: ['parseCronPacingBounds'], kind: 'deferred-input-validation' },
      { importer: row.source, specifier: '../../utils.js', exports: ['isRecord'], kind: 'deferred-input-validation' },
    ] : []);
  });
});

test('independently reconstructs original byte selections, wrappers and every transformed module digest', () => {
  const tree = spawnSync('git', ['-C', root, 'ls-tree', '-r', '488631c18fae7cc541ba8fc8beff6cbb0438787b'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.equal(tree.status, 0, tree.stderr);
  const blobs = new Map(tree.stdout.trim().split('\n').map(line => {
    const [header, path] = line.split('\t');
    return [path, header.split(' ')[2]];
  }));
  for (const row of rows) {
    const projected = expectedFiles[rows.indexOf(row)].filter(path => Object.hasOwn(expectedRegions, path));
    assert.deepEqual(row.projections.map(item => item.source), projected);
    assert.deepEqual(row.moduleExecutions.map(item => item.source), expectedFiles[rows.indexOf(row)].filter(path => !projected.includes(path)));
    for (const file of row.loadedFiles) {
      const bytes = readFileSync(join(root, file.path));
      assert.equal(file.sha256, hash(bytes));
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blobs.get(file.path));
    }
    assert.equal(row.sourceSha256, hash(readFileSync(join(root, row.source))));
    for (const item of row.moduleExecutions) {
      const source = readFileSync(join(root, item.source), 'utf8');
      assert.deepEqual(item, { source: item.source, sourceSha256: hash(source), kind: 'complete-source-module',
        transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
        executableSha256: hash(stripTypeScriptTypes(source, { mode: 'transform', sourceMap: false })) });
    }
    for (const item of row.projections) {
      const bytes = readFileSync(join(root, item.source));
      const lines = bytes.toString().split(/(?<=\n)/);
      const rule = expectedRegions[item.source];
      const selections = rule.lines.map(([startLine, endLine]) => {
        const before = lines.slice(0, startLine - 1).join('');
        const selected = lines.slice(startLine - 1, endLine).join('');
        return { kind: 'source-lines', startLine, endLine, startByte: Buffer.byteLength(before),
          endByte: Buffer.byteLength(before + selected), sha256: hash(selected) };
      });
      const generatedCode = rule.prefix + selections.map(selection => bytes.subarray(selection.startByte, selection.endByte).toString()).join('\n');
      assert.deepEqual(item, { kind: 'cron-schema-source-regions', source: item.source, sourceSha256: hash(bytes),
        exports: rule.exports, selections, generatedCode, generatedSha256: hash(generatedCode),
        transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
        executableSha256: hash(stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false })) });
    }
  }
});

test('uses the actual TypeBox package exports and complete dependency file digests, including real Clone', () => {
  const require = createRequire(join(root, 'package.json'));
  let packageRoot = dirname(realpathSync(require.resolve('typebox')));
  while (!existsSync(join(packageRoot, 'package.json'))) packageRoot = dirname(packageRoot);
  const metadata = readFileSync(join(packageRoot, 'package.json'));
  const pkg = JSON.parse(metadata);
  assert.equal(pkg.name, 'typebox');
  assert.equal(pkg.version, '1.3.37');
  for (const row of rows) {
    assert.equal(row.typebox.version, pkg.version);
    const files = new Map(row.typebox.files.map(file => [file.path, file.sha256]));
    for (const [path, digest] of files) assert.equal(digest, hash(readFileSync(join(packageRoot, path.slice('typebox/'.length)))));
    const specifiers = row.id.endsWith('default-input') ? ['typebox', 'typebox/value'] : ['typebox'];
    assert.deepEqual(row.typebox.exports.map(item => item.specifier), specifiers);
    for (const item of row.typebox.exports) {
      const file = realpathSync(require.resolve(item.specifier));
      const entry = pkg.exports[item.specifier === 'typebox' ? '.' : './value'].import;
      assert.equal(file, join(packageRoot, entry));
      assert.deepEqual(item, { specifier: item.specifier, path: 'typebox/' + relative(packageRoot, file),
        sha256: hash(readFileSync(file)), packagePath: 'typebox/package.json', packageSha256: hash(metadata) });
      assert.equal(files.get(item.path), item.sha256);
      assert.equal(files.get(item.packagePath), item.packageSha256);
    }
  }
  assert.equal(rows[0].typebox.files.length, 677);
  assert.equal(rows[1].typebox.files.length, 372);
});

test('canonical fixture retains both complete schemas and their exact source/dependency evidence', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/capture.json', import.meta.url), 'utf8'));
  assert.deepEqual(fixture.schemaCaptures, rows);
});
