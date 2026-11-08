#!/usr/bin/env node
// Schema construction only. The cron factory and every tool action remain deferred.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FactoryHarness, describeSchema } from './capture-recipes.mjs';

export const CRON_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const CRON_INPUT_SOURCE = 'src/agents/tools/cron-tool-schema.ts';
export const CRON_OUTPUT_SOURCE = 'src/agents/tools/cron-tool-output-schema.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const inside = (root, path) => path === root || path.startsWith(root + sep);
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const protocol = 'packages/gateway-protocol/src/schema/';
const projections = {
  'src/agents/schema/typebox.ts': { lines: [[50, 53], [69, 81]], exports: ['optionalPositiveIntegerSchema', 'optionalNonNegativeIntegerSchema', 'optionalStringEnum', 'stringEnum'],
    prefix: 'import {Type} from "typebox";\nexport {optionalStringEnum,stringEnum} from "./string-enum.js";\n' },
  'src/gateway/cron-creator-authority-grant.ts': { lines: [[29, 35]], exports: ['CRON_MANAGEMENT_METHODS'], prefix: '' },
  [protocol + 'primitives.ts']: { lines: [[26, 26]], exports: ['NonEmptyString'], prefix: 'import {Type} from "typebox";\n' },
  [protocol + 'logs-chat.ts']: { lines: [[128, 157]], exports: ['AgentActivityItemSchema', 'ChatHistoryActivitySchema'],
    prefix: 'import {Type,type Static} from "typebox";\nimport {closedObject} from "./closed-object.js";\nimport {NonEmptyString} from "./primitives.js";\nimport {stringLiteralUnion} from "./string-literal-union.js";\n' },
  'src/cron/stream-approval-outcome.ts': { lines: [[5, 19]], exports: ['CronStreamApprovalEndedSchema'], prefix: 'import {Type} from "typebox";\n' },
};
const wholeSources = [CRON_INPUT_SOURCE, CRON_OUTPUT_SOURCE,
  'src/agents/schema/cached-schema.ts', 'src/infra/map-size.ts', 'src/agents/schema/string-enum.ts',
  'src/agents/tools/automations-tool-name.ts', 'src/agents/tools/gateway-schema.ts',
  'src/agents/schema/tool-output-schema.ts',
  'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/record-coerce.ts',
  ...['cron.ts', 'cron-shared.ts', 'closed-object.ts', 'failover-reason.ts', 'string-literal-union.ts'].map(name => protocol + name),
  'packages/gateway-protocol/src/failover-reasons.ts'];
const aliases = {
  '@openclaw/normalization-core/number-coercion': 'packages/normalization-core/src/number-coercion.ts',
  '@openclaw/normalization-core/record-coerce': 'packages/normalization-core/src/record-coerce.ts',
};
const deferred = [
  ['../../cron/pacing.js', ['parseCronPacingBounds']],
  ['../../utils.js', ['isRecord']],
];
export const CRON_SCHEMA_BOUNDARY = {
  schemaConstructionOnly: true, factoryInvoked: false, actionsExecuted: false,
  inputValidationInvoked: false, servicesStarted: false, dynamicImportsInvoked: false,
  eligibilityEstablished: false, registrationInvoked: false, runtimeAssemblyInvoked: false,
};

class CronSchemaHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: [...wholeSources, ...Object.keys(projections)] });
    this.sourceAliases = [];
    this.moduleExecutions = [];
    this.dependencyExports = [];
  }
  checkedSource(path) {
    const source = readFileSync(join(this.root, path), 'utf8');
    if (!this.recipe.allowedSources.includes(path) || hash(source) !== this.tracked.get(path)) throw Error(`cron schema source hash mismatch: ${path}`);
    this.loadedFiles.set(path, { path, sha256: hash(source) });
    return source;
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const path = relative(this.root, file);
    if (this.typeboxRoot && inside(this.typeboxRoot, file)) return super.module(file);
    const original = this.checkedSource(path);
    const rule = projections[path];
    if (!rule) {
      this.moduleExecutions.push({ source: path, sourceSha256: hash(original), kind: 'complete-source-module',
        transformation, executableSha256: hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })) });
      return super.module(file);
    }
    const lines = original.split(/(?<=\n)/);
    const selections = rule.lines.map(([startLine, endLine]) => {
      const before = lines.slice(0, startLine - 1).join('');
      const selected = lines.slice(startLine - 1, endLine).join('');
      return { kind: 'source-lines', startLine, endLine, startByte: Buffer.byteLength(before),
        endByte: Buffer.byteLength(before + selected), sha256: hash(selected) };
    });
    const generatedCode = rule.prefix + selections.map(item => Buffer.from(original).subarray(item.startByte, item.endByte).toString()).join('\n');
    const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
    this.projections.push({ kind: 'cron-schema-source-regions', source: path, sourceSha256: hash(original),
      exports: rule.exports, selections, generatedCode, generatedSha256: hash(generatedCode), transformation,
      executableSha256: hash(executable) });
    return this.synthetic(file, executable);
  }
  import(specifier, importer) {
    const owner = relative(this.root, importer);
    const rule = owner === CRON_INPUT_SOURCE && deferred.find(([name]) => name === specifier);
    if (rule) {
      if (!this.stubs.some(item => item.specifier === specifier)) this.stubs.push({ importer: owner, specifier, exports: rule[1], kind: 'deferred-input-validation' });
      return this.synthetic(`capture:cron-validation:${specifier}`, rule[1].map(name => {
        const call = { kind: 'deferred-input-validation', importer: owner, specifier, export: name };
        return `export function ${name}(){globalThis.__captureAudit.push(${JSON.stringify(call)});throw Error(${JSON.stringify(`uninvoked cron input validation binding: ${specifier}:${name}`)});}`;
      }).join('\n'));
    }
    if (Object.hasOwn(aliases, specifier)) {
      const source = aliases[specifier];
      if (!this.sourceAliases.some(item => item.importer === owner && item.specifier === specifier)) this.sourceAliases.push({ importer: owner, specifier, source, sourceSha256: this.tracked.get(source), kind: 'whole-source-module' });
      return this.module(join(this.root, source));
    }
    if (specifier === 'typebox' || specifier === 'typebox/value') {
      // Initialize the real pinned package; Clone must come from its actual value export.
      const main = super.resolve('typebox', importer);
      const file = specifier === 'typebox' ? main : realpathSync(createRequire(join(this.root, 'package.json')).resolve(specifier));
      if (!inside(this.typeboxRoot, file)) throw Error('cron TypeBox exports resolve to different packages');
      if (!this.dependencyExports.some(item => item.specifier === specifier)) this.dependencyExports.push({ specifier,
        path: 'typebox/' + relative(this.typeboxRoot, file), sha256: hash(readFileSync(file)),
        packagePath: 'typebox/package.json', packageSha256: this.dependencies.get('typebox/package.json').sha256 });
      return this.module(file);
    }
    return this.module(super.resolve(specifier, importer));
  }
  evidence() {
    return { attemptedCalls: this.call('globalThis.__captureAudit'),
      loadedFiles: [...this.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
      moduleExecutions: this.moduleExecutions.sort((a, b) => a.source.localeCompare(b.source)),
      projections: this.projections.sort((a, b) => a.source.localeCompare(b.source)),
      sourceAliases: this.sourceAliases.sort((a, b) => a.specifier.localeCompare(b.specifier)), stubs: this.stubs,
      configBindings: this.configBindings,
      typebox: { version: this.typeboxVersion, exports: this.dependencyExports.sort((a, b) => a.specifier.localeCompare(b.specifier)),
        files: [...this.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) } };
  }
}

export async function captureCronSchemas(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(file => file.kind !== 'symlink').map(file => [file.path, file.sha256]));
  const rows = [];
  for (const [id, source, name, evidence, expression] of [
    ['cron/schema/default-input', CRON_INPUT_SOURCE, 'createCronToolSchema', 'schema-builder', '__exports.createCronToolSchema()'],
    ['cron/schema/complete-output', CRON_OUTPUT_SOURCE, 'CronToolOutputSchema', 'schema-export', '__exports.CronToolOutputSchema'],
  ]) {
    const harness = new CronSchemaHarness(root, tracked);
    await harness.load(source);
    const schema = describeSchema(harness.call(expression));
    const captured = harness.evidence();
    if (captured.attemptedCalls.length) throw Error('cron schema construction invoked a deferred binding');
    rows.push({ id, referenceTool: 'automations', source, sourceSha256: tracked.get(source), export: name,
      args: [], evidence, context: 'schema/default', status: 'captured', captureRuntime: { node: process.version },
      boundaries: { ...CRON_SCHEMA_BOUNDARY }, executeInvoked: false, schema, ...captured });
  }
  return rows;
}

function git(root, args) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } });
  if (result.status !== 0) throw Error(`verified Git checkout required: ${result.stderr}`);
  return result.stdout.trimEnd();
}
function checkout(root) {
  if (realpathSync(git(root, ['rev-parse', '--show-toplevel'])) !== root || git(root, ['rev-parse', 'HEAD']) !== CRON_PIN
      || git(root, ['status', '--porcelain', '--untracked-files=no'])) throw Error('complete clean pinned checkout required');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', CRON_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t');
    const [mode, type, oid] = header.split(' ');
    if (type !== 'blob' || !['100644', '100755', '120000'].includes(mode) || isAbsolute(path)
        || path.split('/').includes('..') || !inside(root, resolve(root, path))) throw Error('unsupported tracked source');
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    if (symlink !== (mode === '120000') || !inside(root, realpathSync(file))) throw Error('unsupported source link');
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    if (createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex') !== oid) throw Error(`pinned blob mismatch: ${path}`);
    return { path, sha256: hash(bytes), ...(symlink ? { kind: 'symlink' } : {}) };
  });
  return { verified: true, commit: CRON_PIN, tree: git(root, ['rev-parse', `${CRON_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, files };
}
export async function exportCronSchemas(root, out) {
  root = realpathSync(root);
  out = resolve(out);
  let ancestor = out;
  while (!existsSync(ancestor)) ancestor = dirname(ancestor);
  if (inside(root, resolve(realpathSync(ancestor), relative(ancestor, out))) || existsSync(out)) throw Error('choose a new output directory outside the source checkout');
  const source = checkout(root);
  const schemaCaptures = await captureCronSchemas(root, source.files);
  checkout(root);
  const paths = new Set(schemaCaptures.flatMap(row => row.loadedFiles.map(file => file.path)));
  const licenses = source.files.filter(file => /^(?:LICEN[CS]E|NOTICE)(?:\.[^/]+)?$/i.test(file.path.split('/').at(-1))
    && [...paths].some(path => dirname(file.path) === '.' || path.startsWith(dirname(file.path) + '/')));
  for (const file of licenses) paths.add(file.path);
  source.hashScope = 'cron schema evidence only; full checkout blobs verified against pinned tree';
  source.files = source.files.filter(file => paths.has(file.path));
  const dependencies = new Map(schemaCaptures.flatMap(row => row.typebox.files).map(file => [file.path, file]));
  const report = { schemaVersion: 1, referenceRole: 'capability_reference', runtimeContractAuthority: 'backplane_agent_runtime',
    source, schemaCaptures, licenses, dependencies: [...dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) };
  mkdirSync(out, { recursive: true });
  for (const file of source.files) {
    const target = join(out, 'sources', file.path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, readFileSync(join(root, file.path)));
  }
  writeFileSync(join(out, 'capture.json'), JSON.stringify(ordered(report), null, 2) + '\n');
  return report;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [root, out] = process.argv.slice(2);
  if (!root || !out || process.argv.length !== 4) throw Error('usage: capture-cron-schemas.mjs PINNED_SOURCE NEW_OUTPUT_DIRECTORY');
  exportCronSchemas(root, out).then(report => process.stdout.write(JSON.stringify({ output: join(resolve(out), 'capture.json'), schemaCaptures: report.schemaCaptures.length }) + '\n'))
    .catch(error => { process.stderr.write(`cron-schema-capture: ${error.message}\n`); process.exitCode = 1; });
}
