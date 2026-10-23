// Bounded reference capture for trusted pinned code, not hostile-code isolation.
// Native TextEncoder is the sole added pure platform capability in recipe VMs.
// No tool execute function is invoked. Execution-service exports always throw.
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative, resolve, sep } from 'node:path';
import vm from 'node:vm';

const hash = value => createHash('sha256').update(value).digest('hex');
const inside = (root, path) => path === root || path.startsWith(root + sep);
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const schemaHelpers = 'src/agents/schema/typebox.ts';
const enumHelpers = 'src/agents/schema/string-enum.ts';
const channelHelpers = 'src/infra/outbound/channel-target.ts';
const canvasSchema = 'extensions/canvas/src/tool-schema.ts';
const canvasFactory = 'extensions/canvas/src/tool.ts';
const canvasEligibility = 'extensions/canvas/src/node-eligibility.ts';
const llmSchema = 'extensions/llm-task/src/llm-task-tool-definition.ts';
const llmFactory = 'extensions/llm-task/src/llm-task-tool.ts';
const sdk = name => `openclaw/plugin-sdk/${name}`;

// Importer + module + named-export allowlists are intentionally explicit.
const serviceRules = [
  [canvasFactory, 'node:crypto', ['randomUUID']],
  [canvasFactory, sdk('agent-harness-runtime'), ['callGatewayTool', 'listNodes']],
  [canvasFactory, sdk('channel-actions'), ['jsonResult', 'readStringParam']],
  [canvasFactory, sdk('number-runtime'), ['addTimerTimeoutGraceMs', 'clampPositiveTimerTimeoutMs']],
  [canvasFactory, sdk('param-readers'), ['readFiniteNumberParam', 'readPositiveIntegerParam']],
  [canvasEligibility, sdk('node-selection-runtime'), ['resolveEligibleNodeFromList']],
  [llmFactory, sdk('agent-runtime'), ['buildModelAliasIndex', 'resolveModelRefFromString']],
  [llmFactory, sdk('json-schema-runtime'), ['validateJsonSchemaValue']],
  [llmFactory, sdk('param-readers'), ['readFiniteNumberParam', 'readPositiveIntegerParam']],
  [llmFactory, sdk('string-coerce-runtime'), ['asPositiveSafeInteger', 'normalizeOptionalString', 'readNonBlankString']],
  [llmFactory, sdk('tool-results'), ['textResult']],
];

export class FactoryHarness {
  constructor(root, tracked, recipe) {
    this.root = root;
    this.tracked = tracked;
    this.recipe = recipe;
    this.context = vm.createContext(recipe ? { TextEncoder } : {}, { codeGeneration: { strings: false, wasm: false }, microtaskMode: 'afterEvaluate' });
    new vm.Script('globalThis.__captureAudit=[]').runInContext(this.context);
    this.modules = new Map();
    this.dependencies = new Map();
    this.loadedFiles = new Map();
    this.projections = [];
    this.stubs = [];
  }
  audit(entry) {
    new vm.Script(`globalThis.__captureAudit.push(${JSON.stringify(entry)})`).runInContext(this.context, { timeout: 200 });
  }
  synthetic(identifier, code) {
    if (!this.modules.has(identifier)) this.modules.set(identifier, new vm.SourceTextModule(code, { context: this.context, identifier }));
    return this.modules.get(identifier);
  }
  import(specifier, importer) {
    const owner = relative(this.root, importer);
    if (this.recipe) {
      const rule = serviceRules.find(([path, name]) => path === owner && name === specifier);
      if (rule) {
        const exports = rule[2];
        const record = { importer: owner, specifier, exports };
        if (!this.stubs.some(x => x.importer === owner && x.specifier === specifier)) this.stubs.push(record);
        const code = exports.map(name => `export function ${name}(){globalThis.__captureAudit.push(${JSON.stringify({ kind: 'execution-service', importer: owner, specifier, export: name })});throw Error(${JSON.stringify(`blocked execution-service: ${specifier}:${name}`)});}`).join('\n');
        return this.synthetic(`capture:stub:${owner}:${specifier}`, code);
      }
      if ([canvasSchema, llmSchema].includes(owner) && specifier === sdk('channel-actions')) {
        const helpers = ['optionalFiniteNumberSchema', 'optionalPositiveIntegerSchema'];
        const projections = [{ source: schemaHelpers, exports: helpers }, ...(owner === canvasSchema ? [{ source: enumHelpers, exports: ['stringEnum'] }] : [])];
        const code = projections.map(item => `export {${item.exports.join(',')}} from ${JSON.stringify(join(this.root, item.source))};`).join('\n');
        if (!this.projections.some(x => x.importer === owner)) this.projections.push(...projections.map(item => ({ importer: owner, specifier, ...item, sourceSha256: this.tracked.get(item.source) })));
        return this.synthetic(`capture:projection:${owner}:${specifier}`, code);
      }
    }
    return this.module(this.resolve(specifier, importer));
  }
  resolve(specifier, importer) {
    if (specifier.startsWith('.') || (importer.startsWith('capture:projection:') && specifier.startsWith(this.root + sep))) {
      const requested = resolve(dirname(importer), specifier);
      for (const candidate of [requested.replace(/\.js$/, '.ts'), requested, join(requested, 'index.ts')]) {
        const path = relative(this.root, candidate);
        if (inside(this.root, candidate) && this.tracked.has(path)) {
          if (this.recipe && !this.recipe.allowedSources.includes(path)) throw Error(`recipe blocks source import: ${path}`);
          return candidate;
        }
        if (this.typeboxRoot && inside(this.typeboxRoot, candidate) && existsSync(candidate) && lstatSync(candidate).isFile()) {
          const actual = realpathSync(candidate);
          if (!inside(this.typeboxRoot, actual)) throw Error('TypeBox import traversal');
          return actual;
        }
      }
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve('typebox'));
      let packageRoot = dirname(file);
      while (!existsSync(join(packageRoot, 'package.json')) && dirname(packageRoot) !== packageRoot) packageRoot = dirname(packageRoot);
      const pkg = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
      if (pkg.name !== 'typebox') throw Error('unexpected TypeBox dependency');
      if (pkg.version !== '1.3.37') throw Error(`TypeBox capture dependency must be 1.3.37; found ${pkg.version}`);
      this.typeboxRoot = packageRoot;
      this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: hash(readFileSync(join(packageRoot, 'package.json'))) });
      return file;
    }
    throw Error(`offline harness blocks import: ${specifier}`);
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    let source = readFileSync(file, 'utf8');
    if (this.typeboxRoot && inside(this.typeboxRoot, file)) this.dependencies.set(`typebox/${relative(this.typeboxRoot, file)}`, { path: `typebox/${relative(this.typeboxRoot, file)}`, sha256: hash(source) });
    else this.loadedFiles.set(relative(this.root, file), { path: relative(this.root, file), sha256: hash(source) });
    if (file.endsWith('.ts')) source = stripTypeScriptTypes(source, { mode: 'transform', sourceMap: false });
    const mod = new vm.SourceTextModule(source, {
      context: this.context, identifier: file,
      importModuleDynamically: (specifier) => {
        this.audit({ kind: 'dynamic-import', importer: relative(this.root, file), specifier });
        throw Error('offline harness blocks dynamic import');
      },
    });
    this.modules.set(file, mod);
    return mod;
  }
  async load(path) {
    if (this.recipe && !this.recipe.allowedSources.includes(path)) throw Error(`recipe blocks source: ${path}`);
    const mod = this.module(join(this.root, path));
    if (mod.status === 'unlinked') await mod.link((specifier, importer) => this.import(specifier, importer.identifier));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 200 });
    if (mod.status !== 'evaluated') throw Error(`module not evaluated: ${mod.status}`);
    this.context.__exports = mod.namespace;
  }
  call(expression) {
    return JSON.parse(new vm.Script(`JSON.stringify(${expression})`).runInContext(this.context, { timeout: 200 }));
  }
}

export function describeSchema(parameters) {
  const actions = new Set();
  let actionlessBranches = 0;
  function visit(schema, isBranch = false) {
    if (!schema || typeof schema !== 'object') return;
    if (isBranch && schema.type === 'object' && !schema.properties?.action) actionlessBranches++;
    const collect = value => {
      if (!value || typeof value !== 'object') return;
      if (typeof value.const === 'string') actions.add(value.const);
      for (const item of value.enum ?? []) if (typeof item === 'string') actions.add(item);
      for (const key of ['anyOf', 'oneOf', 'allOf']) for (const child of value[key] ?? []) collect(child);
    };
    collect(schema.properties?.action);
    for (const key of ['anyOf', 'oneOf', 'allOf']) for (const child of schema[key] ?? []) visit(child, true);
  }
  visit(parameters, true);
  const schemaJson = JSON.stringify(ordered(parameters));
  return { parameters, actions: [...actions].sort(), actionlessBranches, schemaJson, schemaSha256: hash(schemaJson) };
}

const recipes = [
  { id: 'voice-call/schema', tool: 'voice_call', source: 'extensions/voice-call/src/tool-schema.ts', export: 'VoiceCallToolSchema', kind: 'schema', args: [], allowedSources: ['extensions/voice-call/src/tool-schema.ts'] },
  { id: 'canvas/schema', tool: 'canvas', source: canvasSchema, export: 'canvasToolDefinition', kind: 'definition', args: [], allowedSources: [canvasSchema, schemaHelpers, enumHelpers, channelHelpers] },
  { id: 'canvas/factory', tool: 'canvas', source: canvasFactory, export: 'createCanvasTool', definitionSource: canvasSchema, definitionExport: 'canvasToolDefinition', kind: 'factory', args: [{ agentSessionKey: 'agent:reference:main' }], allowedSources: [canvasFactory, canvasSchema, canvasEligibility, schemaHelpers, enumHelpers, channelHelpers] },
  { id: 'llm-task/schema', tool: 'llm-task', source: llmSchema, export: 'llmTaskToolDefinition', kind: 'definition', args: [], allowedSources: [llmSchema, schemaHelpers, enumHelpers, channelHelpers] },
  { id: 'llm-task/factory', tool: 'llm-task', source: llmFactory, export: 'createLlmTaskTool', definitionSource: llmSchema, definitionExport: 'llmTaskToolDefinition', kind: 'factory', args: [{ kind: 'throwing-api-proxy' }], allowedSources: [llmFactory, llmSchema, schemaHelpers, enumHelpers, channelHelpers] },
];

export async function captureRecipes(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(x => x.kind !== 'symlink').map(x => [x.path, x.sha256]));
  const rows = [];
  for (const recipe of recipes) {
    // Every recipe case has a fresh VM, including schema/factory comparison cases.
    const harness = new FactoryHarness(root, tracked, recipe);
    const row = { id: recipe.id, referenceTool: recipe.tool, source: recipe.source, sourceSha256: tracked.get(recipe.source) ?? null, export: recipe.export,
      args: recipe.args, context: 'recipe/default', evidence: recipe.kind === 'factory' ? 'factory-return' : 'schema-export',
      eligibility: { status: 'unresolved', reason: 'runtime assembly and config/policy admission not executed' }, registration: { status: 'unresolved' },
      platformCapabilities: ['TextEncoder'], executeInvoked: false };
    try {
      if (!tracked.has(recipe.source)) throw Error(`missing recipe source: ${recipe.source}`);
      await harness.load(recipe.source);
      if (recipe.kind === 'schema') row.schema = describeSchema(harness.call(`__exports[${JSON.stringify(recipe.export)}]`));
      else {
        let expression = `__exports[${JSON.stringify(recipe.export)}]`;
        if (recipe.kind === 'factory') {
          const argument = recipe.id === 'llm-task/factory'
            ? `new Proxy(Object.create(null),{get(_target,key){globalThis.__captureAudit.push({kind:'api-access',property:String(key)});throw Error('unexpected API property access: '+String(key));}})`
            : JSON.stringify(recipe.args[0]);
          expression += `(${argument})`;
        }
        const descriptor = harness.call(`(()=>{const t=${expression};return {name:t.name,label:t.label,description:t.description,resultContentSource:t.resultContentSource,parameters:t.parameters,executeObserved:typeof t.execute==='function'};})()`);
        if (descriptor.name !== recipe.tool || !descriptor.parameters) throw Error('unexpected recipe descriptor');
        row.descriptor = descriptor;
        row.schema = describeSchema(descriptor.parameters);
        if (recipe.kind === 'factory') {
          if (!descriptor.executeObserved) throw Error('factory did not return an execute function');
          await harness.load(recipe.definitionSource);
          const expected = harness.call(`__exports[${JSON.stringify(recipe.definitionExport)}]`);
          const actual = { ...descriptor };
          delete actual.executeObserved;
          row.descriptorMatch = JSON.stringify(ordered(actual)) === JSON.stringify(ordered(expected));
          if (!row.descriptorMatch) throw Error('factory descriptor differs from schema definition');
        }
      }
      row.status = 'captured';
    } catch (error) {
      row.status = 'unresolved';
      row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
    }
    row.attemptedCalls = harness.call('globalThis.__captureAudit');
    if (row.attemptedCalls.length) { row.status = 'unresolved'; row.reason = 'blocked execution-service, API or dynamic-import attempt'; }
    row.loadedFiles = [...harness.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path));
    row.projections = harness.projections;
    row.stubs = harness.stubs;
    row.typebox = { version: harness.typeboxVersion ?? null, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) };
    rows.push(row);
  }
  return rows;
}
