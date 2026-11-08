// Bounded metadata capture from trusted pinned Browser source. This executes a
// projected registerTool statement and callback, never registerBrowserPlugin.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import vm from 'node:vm';
import { FactoryHarness, describeSchema, representativeContexts } from './capture-recipes.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const json = value => JSON.stringify(ordered(value));
const registrationSource = 'extensions/browser/plugin-registration.ts';
const definitionSource = 'extensions/browser/src/browser-tool-description.ts';
const projectionIdentifier = 'capture:browser-registration';
const definitionSpecifier = 'capture:browser-definition';
const allowedSources = [registrationSource, definitionSource,
  'extensions/browser/src/browser-tool-binding.ts',
  'extensions/browser/src/browser-tool.schema.ts',
  'extensions/browser/src/browser-tool-action-facts.ts',
  'extensions/browser/src/browser/act-kinds.ts',
  'extensions/browser/src/browser/act-policy.ts',
  'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts',
  'src/infra/outbound/channel-target.ts', 'packages/normalization-core/src/string-coerce.ts'];

// Harness-owned observation bindings delegate to the unchanged real definition.
// The only execution-runtime binding throws if called; lazy execute is untouched.
const projectionPrefix = `import {createBrowserToolDefinition as upstreamCreateBrowserToolDefinition} from "capture:browser-definition";
const registration={callback:undefined,options:undefined,calls:0};
const api={registerTool(callback,options){registration.callback=callback;registration.options=options;registration.calls++;}};
function createBrowserToolDefinition(opts,getConfig){
  globalThis.__captureDefinitionOptions=opts;
  return upstreamCreateBrowserToolDefinition(opts,()=>{
    const config=getConfig();
    globalThis.__captureDefinitionConfig=config;
    globalThis.__captureDefinitionConfigReads++;
    return config;
  });
}
function loadBrowserRegistrationRuntimeModule(){
  globalThis.__captureAudit.push({kind:"execution-service",export:"loadBrowserRegistrationRuntimeModule"});
  throw Error("blocked Browser registration runtime");
}
`;
const projectionSuffix = '\nexport {registration};\n';

function registrationProjection(root, tracked) {
  const original = readFileSync(join(root, registrationSource), 'utf8');
  if (hash(original) !== tracked.get(registrationSource)) throw Error('Browser registration source hash mismatch');
  const patterns = [
    ['deriveChatTypeFromSessionKey', 'complete-function', /^function deriveChatTypeFromSessionKey\([\s\S]*?^\}/gm],
    ['createLazyBrowserTool', 'complete-function', /^function createLazyBrowserTool\([\s\S]*?^\}/gm],
    ['createBrowserToolOptions', 'complete-function', /^function createBrowserToolOptions\([\s\S]*?^\}/gm],
    ['api.registerTool', 'complete-statement', /^  api\.registerTool\([\s\S]*?^  \);$/gm],
  ];
  const selections = patterns.map(([name, kind, pattern]) => {
    const matches = [...original.matchAll(pattern)];
    if (matches.length !== 1) throw Error(`Browser projection requires one complete region: ${name}`);
    const selectedCode = matches[0][0];
    const startByte = Buffer.byteLength(original.slice(0, matches[0].index));
    return { name, kind, startByte, endByte: startByte + Buffer.byteLength(selectedCode), sha256: hash(selectedCode), selectedCode };
  });
  const generatedCode = projectionPrefix + selections.map(selection => selection.selectedCode).join('\n\n') + projectionSuffix;
  const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
  return { kind: 'browser-registration-regions', wrapperVersion: 'browser-registration-v1', source: registrationSource,
    sourceSha256: tracked.get(registrationSource), importer: projectionIdentifier, specifier: 'capture:registration-callback',
    exports: ['registration'], selections, generatedCode, generatedSha256: hash(generatedCode),
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', executableSha256: hash(executable) };
}

// A single additional synthetic module/link edge; inherited source loading,
// TypeBox pinning, exact import rules and throwing execution bindings are reused.
class RegistrationHarness extends FactoryHarness {
  async loadRegistration(projection) {
    const executable = stripTypeScriptTypes(projection.generatedCode, { mode: 'transform', sourceMap: false });
    if (hash(executable) !== projection.executableSha256) throw Error('Browser projection executable hash mismatch');
    const module = new vm.SourceTextModule(executable, { context: this.context, identifier: projectionIdentifier,
      importModuleDynamically: () => { this.audit({ kind: 'dynamic-import', importer: projectionIdentifier }); throw Error('offline registration capture blocks dynamic import'); } });
    this.loadedFiles.set(registrationSource, { path: registrationSource, sha256: projection.sourceSha256 });
    this.projections.push(projection);
    await module.link((specifier, importer) => {
      if (importer.identifier === projectionIdentifier && specifier === definitionSpecifier) return this.module(join(this.root, definitionSource));
      return this.import(specifier, importer.identifier);
    });
    await module.evaluate({ timeout: 200 });
    this.context.__exports = module.namespace;
  }
}

const enabled = { browser: { evaluateEnabled: true } };
const disabled = { browser: { evaluateEnabled: false } };
const baseContext = { sessionKey: 'agent:reference:main', agentId: 'reference', workspaceDir: '/reference/workspace' };
const nodeBinding = { kind: 'tab', tabId: 1, target: 'node', node: 'reference-node', profile: 'reference', targetId: 'reference-tab' };

function cases() {
  return [
    ...representativeContexts().map(context => ({ id: `browser/registration/context/${context.id}`, context: context.id, representativeContext: context,
      input: { context: { ...baseContext, sessionKey: context.options.agentSessionKey, config: context.options.config } } })),
    ...[
      { name: 'getter-first', context: { runtimeConfig: enabled, config: enabled }, getter: { returnKind: 'value', value: disabled } },
      { name: 'getter-undefined-runtime', context: { runtimeConfig: disabled, config: enabled }, getter: { returnKind: 'undefined' } },
      { name: 'runtime-first', context: { runtimeConfig: disabled, config: enabled } },
      { name: 'config-fallback', context: { config: disabled } },
      { name: 'getter-empty-object', context: { runtimeConfig: disabled, config: disabled }, getter: { returnKind: 'value', value: {} } },
    ].map(item => ({ id: `browser/registration/config/${item.name}`, context: `ordinary/config/${item.name}`,
      input: { context: { ...baseContext, ...item.context }, ...(item.getter ? { getRuntimeConfig: item.getter } : {}) } })),
    ...['direct', 'group', 'channel', 'dm'].map(type => ({ id: `browser/registration/media/${type}`, context: `ordinary/media/${type}`,
      input: { context: { ...baseContext, config: enabled, sessionKey: `agent:reference:${type}:fixture`,
        deliveryContext: { channel: 'delivery-channel' }, messageChannel: 'message-channel', agentDir: '/reference/agent',
        activeModel: { provider: 'reference-provider', modelId: 'reference-model' } } } })),
    ...[false, true].map(evaluateDisabled => ({ id: `browser/registration/binding/node-tab${evaluateDisabled ? '-evaluate-disabled' : ''}`,
      context: `ordinary/binding/node-tab${evaluateDisabled ? '-evaluate-disabled' : ''}`,
      input: { context: { ...baseContext, config: evaluateDisabled ? disabled : enabled, toolBindings: { browser: nodeBinding } } } })),
  ];
}

function provenance(harness) {
  return { loadedFiles: [...harness.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
    projections: harness.projections, stubs: harness.stubs,
    typebox: { version: harness.typeboxVersion ?? null, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) },
    attemptedCalls: harness.call('globalThis.__captureAudit'), executeInvoked: false };
}

function verifyLoadedSources(root, tracked, evidence) {
  for (const file of evidence.loadedFiles) if (file.sha256 !== tracked.get(file.path) || hash(readFileSync(join(root, file.path))) !== file.sha256) {
    throw Error(`Browser registration loaded source hash mismatch: ${file.path}`);
  }
}

export async function captureBrowserRegistrations(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(file => file.kind !== 'symlink').map(file => [file.path, file.sha256]));
  const rows = [];
  for (const item of cases()) {
    const recipe = { source: registrationSource, allowedSources };
    const harness = new RegistrationHarness(root, tracked, recipe);
    const row = { id: item.id, source: registrationSource, sourceSha256: tracked.get(registrationSource) ?? null,
      context: item.context, input: item.input, evidence: 'projected-registerTool-callback',
      ...(item.representativeContext ? { representativeContext: item.representativeContext } : {}),
      boundaries: { fullPluginRegistrationInvoked: false, pluginLoaderInvoked: false, runtimeAdmissionExecuted: false,
        servicesStarted: false, runtimeModuleLoaded: false, actionsExecuted: false }, executeInvoked: false };
    try {
      const projection = registrationProjection(root, tracked);
      await harness.loadRegistration(projection);
      const getter = item.input.getRuntimeConfig;
      const getterInput = getter?.returnKind === 'value' ? json(getter.value) : 'undefined';
      const getterCode = getter ? `()=>{globalThis.__captureContextConfigReads++;return ${getterInput};}` : null;
      const setupCode = `globalThis.__captureContext=${json(item.input.context)};globalThis.__captureContextConfigReads=0;globalThis.__captureDefinitionConfigReads=0;${getterCode ? `globalThis.__captureContext.getRuntimeConfig=${getterCode};` : ''}`;
      new vm.Script(setupCode).runInContext(harness.context, { timeout: 200 });
      row.contextBinding = { kind: 'synthetic-context-input', sourceImplementation: 'not-executed', generatedCode: setupCode, generatedSha256: hash(setupCode) };
      const result = harness.call(`(()=>{
        const tool=__exports.registration.callback(globalThis.__captureContext);
        return {registration:{options:__exports.registration.options,registerToolCalls:__exports.registration.calls,callbackInvoked:true,fullPluginRegistrationInvoked:false},
          options:globalThis.__captureDefinitionOptions,config:globalThis.__captureDefinitionConfig,
          getterCalls:globalThis.__captureContextConfigReads,definitionReaderCalls:globalThis.__captureDefinitionConfigReads,
          descriptor:{name:tool.name,label:tool.label,description:tool.description,resultContentSource:tool.resultContentSource,
            parameters:tool.parameters,outputSchema:tool.outputSchema,executeObserved:typeof tool.execute==='function'}};
      })()`);
      row.registration = result.registration;
      row.options = result.options;
      row.descriptor = result.descriptor;
      row.schema = describeSchema(result.descriptor.parameters);
      row.outputSchema = describeSchema(result.descriptor.outputSchema);
      const origin = getter?.returnKind === 'value' ? 'ctx.getRuntimeConfig()'
        : item.input.context.runtimeConfig !== undefined ? 'ctx.runtimeConfig' : 'ctx.config';
      row.configSelection = { origin, input: result.config, inputJson: json(result.config), inputSha256: hash(json(result.config)),
        getterCalls: result.getterCalls, definitionReaderCalls: result.definitionReaderCalls,
        evidence: 'observed config value and getter calls; precedence follows projected source statement' };
      const comparison = new FactoryHarness(root, tracked, recipe);
      await comparison.load(definitionSource);
      const generatedCode = `()=>{globalThis.__captureConfigReads++;return ${json(result.config)};}`;
      const expected = comparison.call(`__exports.createBrowserToolDefinition(${json(result.options)},${generatedCode})`);
      row.definitionComparison = { freshVm: true, source: definitionSource, sourceSha256: tracked.get(definitionSource),
        export: 'createBrowserToolDefinition', selector: 'metadata', args: [result.options], metadata: expected.metadata,
        capabilities: expected.capabilities, ...(expected.binding ? { binding: expected.binding } : {}),
        configInput: { kind: 'synthetic-config-input', sourceImplementation: 'not-executed', origin, input: result.config,
          inputJson: json(result.config), inputSha256: hash(json(result.config)), generatedCode, generatedSha256: hash(generatedCode),
          calls: comparison.call('globalThis.__captureConfigReads') }, ...provenance(comparison) };
      const { executeObserved, ...metadata } = row.descriptor;
      row.descriptorMatch = json(metadata) === json(expected.metadata);
      if (!executeObserved || !row.descriptorMatch) throw Error('Browser callback descriptor differs from independent real definition');
      if (row.definitionComparison.attemptedCalls.length) throw Error('Browser definition comparison attempted an execution service');
      verifyLoadedSources(root, tracked, row.definitionComparison);
      row.status = 'captured';
    } catch (error) {
      row.status = 'unresolved';
      row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
    }
    Object.assign(row, provenance(harness));
    if (row.attemptedCalls.length) { row.status = 'unresolved'; row.reason = 'Browser callback attempted an execution service or dynamic import'; }
    try { verifyLoadedSources(root, tracked, row); } catch (error) { row.status = 'unresolved'; row.reason = error.message; }
    rows.push(row);
  }
  return rows;
}
