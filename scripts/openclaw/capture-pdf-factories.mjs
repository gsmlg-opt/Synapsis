// Construction-only PDF metadata from the complete unchanged pinned factory.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, relative } from 'node:path';
import { FactoryHarness, describeSchema, representativeContexts } from './capture-recipes.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const tools = 'src/agents/tools/';
const normalization = 'packages/normalization-core/src/';
export const PDF_FACTORY_SOURCE = tools + 'pdf-tool.ts';
const pdfHelpers = tools + 'pdf-tool.helpers.ts';
const imageHelpers = tools + 'image-tool.helpers.ts';
const modelHelpers = tools + 'model-config.helpers.ts';
const modelInput = 'src/config/model-input.ts';
const allowedSources = [PDF_FACTORY_SOURCE, pdfHelpers, imageHelpers, modelHelpers, modelInput,
  'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts', 'src/infra/outbound/channel-target.ts',
  ...['number-coercion', 'record-coerce', 'string-coerce'].map(name => normalization + name + '.ts')];
// Audited per-importer execution imports. They never run during construction.
const serviceRules = [
  ['@openclaw/media-core/mime', ['normalizeMimeType']],
  ['../../gateway/operator-invocation-authority.js', ['captureAmbientGatewayOperatorAuthority']],
  ['../../media-understanding/defaults.js', ['providerSupportsNativePdfDocument']],
  ['../../media/document-extraction-metadata.js', ['renderDocumentTruncationNotice']],
  ['../../media/media-reference.js', ['classifyMediaReferenceSource', 'normalizeMediaReferenceSource']],
  ['../../media/pdf-extract.js', ['extractPdfContent']],
  ['../../media/web-media.js', ['loadWebMediaRaw']],
  ['../../shared/async-work-resources.js', ['runWithAsyncWorkResources']],
  ['../../shared/async-work-scope.js', ['trackAsyncWork']],
  ['../admitted-run-context.js', ['assertOperatorModelAllowed', 'bindOperatorModelExecution']],
  ['../embedded-agent-runner/model.js', ['resolveModelAsync']],
  ['../embedded-agent-runner/run/abortable.js', ['abortable']],
  ['../model-auth.js', ['requireApiKey']],
  ['../model-fallback-image.js', ['resolveAllowedImageFallbackCandidates', 'runWithImageModelFallback']],
  ['../prepared-model-runtime.js', ['acquireAgentRunPreparedModelRuntime']],
  ['../prepared-model-runtime.resources.js', ['retainPreparedModelRuntimeSnapshotResources']],
  ['../provider-request-config.js', ['getModelProviderRequestTransport']],
  ['../sandbox-media-paths.js', ['createSandboxBridgeReadFile']],
  ['../simple-completion-execution.js', ['completeWithPreparedSimpleCompletionModel']],
  ['../simple-completion-runtime.js', ['prepareSimpleCompletionModel']],
  ['./common.js', ['textResult', 'ToolInputError']],
  ['./media-tool-shared.js', ['buildMediaReferenceDetails', 'buildTextToolResult', 'REMOTE_MEDIA_READ_IDLE_TIMEOUT_MS', 'resolveMediaToolSandboxConfig', 'resolveMediaToolReferenceAccess', 'resolveMediaAnalysisParams']],
  ['./pdf-native-providers.js', ['anthropicAnalyzePdf', 'geminiAnalyzePdf']],
  ['./pdf-tool.model-config.js', ['resolvePdfModelConfigForTool']],
];
const aliases = [
  [PDF_FACTORY_SOURCE, 'number-coercion', ['asFiniteNumber']],
  [PDF_FACTORY_SOURCE, 'record-coerce', ['asRecord']],
  [PDF_FACTORY_SOURCE, 'string-coerce', ['normalizeOptionalString']],
  [modelInput, 'number-coercion', ['asPositiveFiniteNumber']],
  [modelInput, 'string-coerce', ['resolvePrimaryStringValue']],
];
const helperRules = [
  [PDF_FACTORY_SOURCE, './pdf-tool.helpers.js', pdfHelpers, ['coercePdfModelConfig'], [[84, 95]],
    'import {resolveAgentModelFallbackValues,resolveAgentModelPrimaryValue} from "../../config/model-input.js";\n',
    ['buildPdfExtractionContext', 'coercePdfAssistantText', 'parsePageRange', 'resolvePdfInputs', 'resolvePdfToolMaxTokens']],
  [PDF_FACTORY_SOURCE, './image-tool.helpers.js', imageHelpers, ['coerceImageModelConfig'], [[108, 110]],
    'import {coerceToolModelConfig} from "./model-config.helpers.js";\n', []],
  [PDF_FACTORY_SOURCE, './model-config.helpers.js', modelHelpers, ['hasToolModelConfig', 'coerceToolModelConfig'], [[62, 66], [403, 412]],
    'import {resolveAgentModelFallbackValues,resolveAgentModelPrimaryValue,resolveAgentModelTimeoutMsValue} from "../../config/model-input.js";\n',
    ['applyAgentDefaultModelConfig', 'prepareToolAuthProfileStore']],
  [imageHelpers, './model-config.helpers.js', modelHelpers, ['hasToolModelConfig', 'coerceToolModelConfig'], [[62, 66], [403, 412]],
    'import {resolveAgentModelFallbackValues,resolveAgentModelPrimaryValue,resolveAgentModelTimeoutMsValue} from "../../config/model-input.js";\n', []],
  ...[pdfHelpers, modelHelpers].map(owner => [owner, '../../config/model-input.js', modelInput,
    ['resolveAgentModelPrimaryValue', 'resolveAgentModelFallbackValues', 'resolveAgentModelTimeoutMsValue'], [[23, 33], [53, 59]],
    'import {asPositiveFiniteNumber} from "@openclaw/normalization-core/number-coercion";\nimport {resolvePrimaryStringValue} from "@openclaw/normalization-core/string-coerce";\n', []]),
];

function selectionsFor(original, regions) {
  const lines = original.split(/(?<=\n)/);
  return regions.map(([startLine, endLine]) => {
    const before = lines.slice(0, startLine - 1).join('');
    const selected = lines.slice(startLine - 1, endLine).join('');
    return { selection: { kind: 'source-lines', startLine, endLine, startByte: Buffer.byteLength(before),
      endByte: Buffer.byteLength(before + selected), sha256: hash(selected) }, selected };
  });
}

class PdfFactoryHarness extends FactoryHarness {
  checkedSource(source) {
    if (!allowedSources.includes(source) || !this.tracked.has(source)) throw Error(`missing allowed PDF source: ${source}`);
    const original = readFileSync(join(this.root, source), 'utf8');
    if (hash(original) !== this.tracked.get(source)) throw Error(`PDF source hash mismatch: ${source}`);
    this.loadedFiles.set(source, { path: source, sha256: this.tracked.get(source) });
    return original;
  }
  module(file) {
    const source = relative(this.root, file);
    if (allowedSources.includes(source)) this.checkedSource(source);
    return super.module(file);
  }
  throwing(importer, specifier, name) {
    const entry = { kind: 'execution-service', importer, specifier, export: name };
    return `function(){globalThis.__captureAudit.push(${JSON.stringify(entry)});throw Error(${JSON.stringify(`deferred execution-only binding: ${specifier}:${name}`)});}`;
  }
  stub(importer, specifier, exports) {
    if (!this.stubs.some(item => item.importer === importer && item.specifier === specifier)) this.stubs.push({ importer, specifier, exports });
    return this.synthetic(`capture:pdf-stub:${importer}:${specifier}`,
      exports.map(name => `export const ${name}=${this.throwing(importer, specifier, name)};`).join('\n'));
  }
  projection(importer, specifier, source, exports, kind, regions, wrap, extra = {}) {
    const selected = selectionsFor(this.checkedSource(source), regions);
    const generatedCode = wrap(selected.map(item => item.selected));
    const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
    if (!this.projections.some(item => item.importer === importer && item.specifier === specifier)) this.projections.push({
      importer, specifier, source, sourceSha256: this.tracked.get(source), exports, kind,
      selections: selected.map(item => item.selection), generatedCode, generatedSha256: hash(generatedCode), executableSha256: hash(executable), ...extra,
    });
    return this.synthetic(join(this.root, `${source}.capture-${kind}-${importer.replaceAll('/', '_')}.ts`), executable);
  }
  import(specifier, importer) {
    const rawOwner = relative(this.root, importer);
    const owner = rawOwner.includes('.capture-') ? rawOwner.slice(0, rawOwner.indexOf('.capture-')) : rawOwner;
    const alias = aliases.find(([path, name]) => path === owner && specifier === `@openclaw/normalization-core/${name}`);
    if (alias) {
      const source = normalization + alias[1] + '.ts';
      const mod = this.projection(owner, specifier, source, alias[2], 'pdf-normalization-export', [], () =>
        `export {${alias[2].join(',')}} from ${JSON.stringify(`capture:pdf-source:${source}`)};`);
      this.normalizationTargets ??= new Map();
      this.normalizationTargets.set(mod.identifier, source);
      return mod;
    }
    const target = this.normalizationTargets?.get(importer);
    if (target && specifier === `capture:pdf-source:${target}`) return this.module(join(this.root, target));
    const helper = helperRules.find(([path, name]) => path === owner && name === specifier);
    if (helper) {
      const [, , source, pureExports, regions, prelude, deferred] = helper;
      return this.projection(owner, specifier, source, [...pureExports, ...deferred], 'pdf-pure-helper', regions,
        parts => prelude + parts.join('\n') + '\n' + deferred.map(name => `export const ${name}=${this.throwing(owner, specifier, name)};`).join('\n'),
        { pureExports, executionOnlyExports: deferred });
    }
    const rule = owner === PDF_FACTORY_SOURCE && serviceRules.find(([name]) => name === specifier);
    if (rule) return this.stub(owner, specifier, rule[1]);
    return super.import(specifier, importer);
  }
  async metadata() {
    const mod = this.projection(PDF_FACTORY_SOURCE, 'capture:pdf-metadata', PDF_FACTORY_SOURCE, ['captureMetadata'],
      'pdf-metadata-region', [[78, 94], [145, 146], [557, 560]], parts =>
        'import {Type} from "typebox";\nimport {optionalFiniteNumberSchema} from "../schema/typebox.js";\n'
        + parts[0] + '\nexport function captureMetadata(options={}){\n' + parts[1] + '\nreturn {\n' + parts[2] + '\n};}\n');
    await mod.link((specifier, importer) => this.import(specifier, importer.identifier));
    await mod.evaluate({ timeout: 200 });
    this.context.__metadata = mod.namespace;
    return this.call(`__metadata.captureMetadata(${JSON.stringify(this.recipe.args[0])})`);
  }
}

function evidence(harness) {
  return { attemptedCalls: harness.call('globalThis.__captureAudit'),
    loadedFiles: [...harness.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
    projections: harness.projections, stubs: harness.stubs, configBindings: [],
    typebox: { version: harness.typeboxVersion ?? null, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) } };
}
function recipes() {
  const agentDir = '/reference/agent';
  return [
    { id: 'pdf/factory/default', args: [{ agentDir }] },
    { id: 'pdf/factory/configured-defaults', args: [{ agentDir, config: { agents: { defaults: { pdfMaxMb: 24, pdfMaxPages: 32 } } } }] },
    ...representativeContexts().map(context => ({ id: `pdf/factory/context/${context.id}`,
      args: [{ ...context.options, agentDir }], representativeContext: context })),
  ].map(recipe => ({ ...recipe, allowedSources }));
}

export async function capturePdfFactories(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(file => file.kind !== 'symlink').map(file => [file.path, file.sha256]));
  const rows = [];
  for (const recipe of recipes()) {
    const harness = new PdfFactoryHarness(root, tracked, recipe);
    const row = { id: recipe.id, referenceTool: 'pdf', source: PDF_FACTORY_SOURCE, sourceSha256: tracked.get(PDF_FACTORY_SOURCE) ?? null,
      export: 'createPdfTool', args: recipe.args, context: `recipe/${recipe.id}`, evidence: 'factory-return',
      eligibility: { status: 'unresolved', reason: 'agentDir permits construction; model readiness and runtime assembly are unexecuted' }, registration: { status: 'unresolved' },
      platformCapabilities: ['TextEncoder'], executeInvoked: false,
      executionBoundary: { toolExecuteInvoked: false, pdfExecutionInvoked: false, resourceAcquisitionInvoked: false,
        modelReadinessInvoked: false, authInvoked: false, dynamicImportsInvoked: false },
      limits: { constructorCases: 'agentDir-present; no explicit pdfModel/imageModel',
        excluded: ['absent-agentDir', 'null-return', 'throwing-constructor', 'explicit-model-config', 'auth-readiness'],
        unexecuted: ['pdf-loading', 'extraction', 'native-provider', 'model-fallback', 'resource-lifecycle', 'tool-execute', 'runtime-assembly', 'registration'] } };
    if (recipe.representativeContext) row.representativeContext = recipe.representativeContext;
    try {
      await harness.load(PDF_FACTORY_SOURCE);
      row.descriptor = harness.call(`(()=>{const t=__exports.createPdfTool(${JSON.stringify(recipe.args[0])});return {name:t.name,label:t.label,description:t.description,parameters:t.parameters,executeObserved:typeof t.execute==='function'};})()`);
      if (row.descriptor.name !== 'pdf' || !row.descriptor.executeObserved) throw Error('unexpected PDF factory descriptor');
      row.schema = describeSchema(row.descriptor.parameters);
      const comparison = new PdfFactoryHarness(root, tracked, recipe);
      const metadata = await comparison.metadata();
      row.definitionComparison = { kind: 'source-metadata-region', freshVm: true, source: PDF_FACTORY_SOURCE, sourceSha256: tracked.get(PDF_FACTORY_SOURCE),
        selector: 'metadata', syntheticExport: 'captureMetadata', args: recipe.args, metadata, executeInvoked: false, ...evidence(comparison) };
      const { executeObserved, ...actual } = row.descriptor;
      row.descriptorMatch = JSON.stringify(ordered(actual)) === JSON.stringify(ordered(metadata));
      if (!row.descriptorMatch) throw Error('actual PDF factory metadata differs from exact source metadata region');
      if (row.definitionComparison.attemptedCalls.length) throw Error('PDF metadata comparison called an execution-only binding');
      row.status = 'captured';
    } catch (error) {
      row.status = 'unresolved';
      row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
    }
    Object.assign(row, evidence(harness));
    if (row.attemptedCalls.length) { row.status = 'unresolved'; row.reason = 'PDF construction called an execution-only binding'; }
    rows.push(row);
  }
  return rows;
}
