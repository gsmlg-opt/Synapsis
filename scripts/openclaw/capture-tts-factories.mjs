// Construction-only TTS metadata from the complete unchanged pinned factory.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, relative, sep } from 'node:path';
import { FactoryHarness, describeSchema, representativeContexts } from './capture-recipes.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
export const TTS_FACTORY_SOURCE = 'src/agents/tools/tts-tool.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const serviceRules = [
  ['../../config/config.js', ['getRuntimeConfig']],
  ['../../tts/tts.js', ['textToSpeech']],
  ['./common.js', ['readPositiveIntegerParam', 'readToolStringParam']],
  ['./tts-tool-result-provenance.js', ['markCoreTtsToolResult']],
];

function selectionsFor(original) {
  const lines = original.split(/(?<=\n)/);
  return [[9, 18], [39, 44]].map(([startLine, endLine]) => {
    const before = lines.slice(0, startLine - 1).join('');
    const selected = lines.slice(startLine - 1, endLine).join('');
    return { selection: { kind: 'source-lines', startLine, endLine, startByte: Buffer.byteLength(before),
      endByte: Buffer.byteLength(before + selected), sha256: hash(selected) }, selected };
  });
}

class TtsFactoryHarness extends FactoryHarness {
  checkedSource() {
    const original = readFileSync(join(this.root, TTS_FACTORY_SOURCE), 'utf8');
    if (hash(original) !== this.tracked.get(TTS_FACTORY_SOURCE)) throw Error('TTS source hash mismatch');
    this.loadedFiles.set(TTS_FACTORY_SOURCE, { path: TTS_FACTORY_SOURCE, sha256: this.tracked.get(TTS_FACTORY_SOURCE) });
    return original;
  }
  module(file) {
    if (relative(this.root, file) === TTS_FACTORY_SOURCE) this.checkedSource();
    return super.module(file);
  }
  import(specifier, importer) {
    const owner = relative(this.root, importer);
    const rule = owner === TTS_FACTORY_SOURCE && serviceRules.find(([name]) => name === specifier);
    if (rule) {
      const exports = rule[1];
      if (!this.stubs.some(item => item.importer === owner && item.specifier === specifier)) this.stubs.push({ importer: owner, specifier, exports });
      return this.synthetic(`capture:tts-stub:${specifier}`, exports.map(name => {
        const entry = { kind: 'execution-service', importer: owner, specifier, export: name };
        return `export function ${name}(){globalThis.__captureAudit.push(${JSON.stringify(entry)});throw Error(${JSON.stringify(`deferred execution-only binding: ${specifier}:${name}`)});}`;
      }).join('\n'));
    }
    const dependencyPath = this.typeboxRoot && relative(this.typeboxRoot, importer);
    if (specifier === 'typebox' || (dependencyPath && dependencyPath !== '..' && !dependencyPath.startsWith('..' + sep))) return super.import(specifier, importer);
    throw Error(`TTS construction blocks import: ${specifier}`);
  }
  async metadata() {
    const selected = selectionsFor(this.checkedSource());
    const generatedCode = 'import {Type} from "typebox";\n' + selected[0].selected
      + '\nexport function captureMetadata(){\nreturn {\n' + selected[1].selected + '\n};}\n';
    const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
    this.projections.push({ importer: TTS_FACTORY_SOURCE, specifier: 'capture:tts-metadata', source: TTS_FACTORY_SOURCE,
      sourceSha256: this.tracked.get(TTS_FACTORY_SOURCE), exports: ['captureMetadata'], kind: 'tts-metadata-region',
      selections: selected.map(item => item.selection), generatedCode, generatedSha256: hash(generatedCode), executableSha256: hash(executable) });
    const mod = this.synthetic(join(this.root, TTS_FACTORY_SOURCE + '.capture-tts-metadata.ts'), executable);
    await mod.link((specifier, importer) => this.import(specifier, importer.identifier));
    await mod.evaluate({ timeout: 200 });
    this.context.__metadata = mod.namespace;
    return this.call('__metadata.captureMetadata()');
  }
}

function evidence(harness) {
  return { attemptedCalls: harness.call('globalThis.__captureAudit'),
    loadedFiles: [...harness.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
    projections: harness.projections, stubs: harness.stubs, configBindings: harness.configBindings,
    typebox: { version: harness.typeboxVersion ?? null, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) } };
}

function recipes() {
  return [
    { id: 'tts/factory/default', args: [] },
    { id: 'tts/factory/empty-options', args: [{}] },
    { id: 'tts/factory/agent-options', args: [{ config: { messages: { tts: { auto: 'always' } } },
      agentChannel: 'telegram', agentId: 'reference', agentAccountId: 'reference-account' }] },
    ...representativeContexts().map(context => ({ id: `tts/factory/context/${context.id}`,
      args: [context.options], representativeContext: context })),
  ].map(recipe => ({ ...recipe, allowedSources: [TTS_FACTORY_SOURCE] }));
}

export async function captureTtsFactories(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(file => file.kind !== 'symlink').map(file => [file.path, file.sha256]));
  const rows = [];
  for (const recipe of recipes()) {
    const harness = new TtsFactoryHarness(root, tracked, recipe);
    const row = { id: recipe.id, referenceTool: 'tts', source: TTS_FACTORY_SOURCE, sourceSha256: tracked.get(TTS_FACTORY_SOURCE) ?? null,
      export: 'createTtsTool', args: recipe.args, context: `recipe/${recipe.id}`, evidence: 'factory-return',
      eligibility: { status: 'unresolved', reason: 'construction does not execute eligibility or runtime assembly' },
      registration: { status: 'unresolved' }, platformCapabilities: ['TextEncoder'], executeInvoked: false,
      executionBoundary: { toolExecuteInvoked: false, transcriptSanitizerInvoked: false,
        voiceProviderInvoked: false, configReadInvoked: false, dynamicImportsInvoked: false },
      limits: { constructorCases: 'no-args; empty-options; ordinary-agent-options; 24 representative contexts',
        unexecuted: ['tool-execute', 'transcript-sanitizer', 'voice-provider', 'tts-service', 'runtime-config-read',
          'readiness', 'eligibility', 'runtime-assembly', 'registration'] } };
    if (recipe.representativeContext) row.representativeContext = recipe.representativeContext;
    try {
      const original = harness.checkedSource();
      row.factoryExecution = { kind: 'complete-source-module', sourceSha256: hash(original), transformation,
        executableSha256: hash(stripTypeScriptTypes(original, { mode: 'transform', sourceMap: false })) };
      await harness.load(TTS_FACTORY_SOURCE);
      row.descriptor = harness.call(`(()=>{const t=__exports.createTtsTool(${recipe.args.map(arg => JSON.stringify(arg)).join(',')});const {execute,...metadata}=t;return {...metadata,executeObserved:typeof execute==='function'};})()`);
      if (row.descriptor.name !== 'tts' || !row.descriptor.executeObserved) throw Error('unexpected TTS factory descriptor');
      row.schema = describeSchema(row.descriptor.parameters);
      const comparison = new TtsFactoryHarness(root, tracked, recipe);
      const metadata = await comparison.metadata();
      row.definitionComparison = { kind: 'source-metadata-region', freshVm: true, source: TTS_FACTORY_SOURCE,
        sourceSha256: tracked.get(TTS_FACTORY_SOURCE), selector: 'metadata', syntheticExport: 'captureMetadata',
        args: recipe.args, metadata, executeInvoked: false, ...evidence(comparison) };
      const { executeObserved, ...actual } = row.descriptor;
      row.descriptorMatch = JSON.stringify(ordered(actual)) === JSON.stringify(ordered(metadata));
      if (!row.descriptorMatch) throw Error('actual TTS factory metadata differs from exact source metadata region');
      if (row.definitionComparison.attemptedCalls.length) throw Error('TTS metadata comparison called an execution-only binding');
      row.status = 'captured';
    } catch (error) {
      row.status = 'unresolved';
      row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
    }
    Object.assign(row, evidence(harness));
    if (row.attemptedCalls.length) { row.status = 'unresolved'; row.reason = 'TTS construction called an execution-only binding'; }
    rows.push(row);
  }
  return rows;
}
