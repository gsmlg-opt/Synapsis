// Ordinary successful llm-task callbacks from complete unchanged pinned modules.
// Completion and empty runtime inventories are explicit fixtures, not host assembly.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isProxy } from 'node:util/types';
import vm from 'node:vm';
import { BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const factory = 'extensions/llm-task/src/llm-task-tool.ts';
const definition = 'extensions/llm-task/src/llm-task-tool-definition.ts';
const selection = 'src/agents/model-selection-shared.ts';
const readers = 'src/agents/tools/common.ts';
const results = 'src/agents/tools/tool-results.ts';
const normalization = 'packages/normalization-core/src/';
const catalog = 'packages/model-catalog-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const sources = new Set([
  factory, definition, selection, results, 'src/agents/model-selection-normalize.ts',
  'src/agents/model-selection-alias-scope.ts', 'src/agents/model-ref-shared.ts',
  'src/agents/model-ref-profile.ts', 'src/agents/configured-provider-model.ts', 'src/agents/defaults.ts',
  'src/plugins/manifest-model-id-normalization.ts', 'src/agents/provider-model-normalization.runtime.ts',
  'src/config/model-policy-ref.ts', 'src/shared/model-key.ts', 'src/shared/dedupe-by-key.ts',
  'src/plugins/schema-validator.ts', 'src/shared/json-schema-defaults.ts',
  'src/shared/path-array-index.ts', 'src/shared/immutable-data.ts', 'src/config/allowed-values.ts',
  'src/infra/lru-cache.ts', 'src/infra/prototype-keys.ts', 'src/auto-reply/thinking.shared.ts',
  'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts', 'src/infra/outbound/channel-target.ts',
  'packages/terminal-core/src/safe-text.ts', 'packages/terminal-core/src/ansi.ts',
  'packages/terminal-core/src/ansi-sequences.ts', normalization + 'json-schema.ts',
  ...['provider-id', 'model-catalog-refs', 'provider-model-id-normalization', 'provider-model-id-normalize'].map(name => catalog + name + '.ts'),
]);
const facades = {
  [sdk + 'agent-runtime']: from(['buildModelAliasIndex', 'resolveModelRefFromString'], selection),
  [sdk + 'json-schema-runtime']: from(['validateJsonSchemaValue'], 'src/plugins/schema-validator.ts'),
  [sdk + 'param-readers']: from(['readFiniteNumberParam', 'readPositiveIntegerParam'], readers),
  [sdk + 'string-coerce-runtime']: [
    from(['normalizeOptionalString', 'readNonBlankString'], normalization + 'string-coerce.ts'),
    from(['asPositiveSafeInteger'], normalization + 'number-coercion.ts'),
  ].join('\n'),
  [sdk + 'tool-results']: from(['textResult'], results),
  [sdk + 'channel-actions']: from(['optionalFiniteNumberSchema', 'optionalPositiveIntegerSchema'], 'src/agents/schema/typebox.ts'),
};
// Imports belonging to other exports of a complete module are never emulated.
const unusedImports = [
  [selection, '../config/model-input.js', ['resolveAgentModelPrimaryValue']],
  [selection, '../config/model-policy-allowlist-migration.js', ['computeModelPolicyAllowlist', 'hasExplicitModelPolicyAllow']],
  [selection, '../config/utility-model-separation-migration.js', ['hasUtilityModelSeparationMigrationMarker']],
  [selection, '../logging/subsystem.js', ['createSubsystemLogger']],
  [selection, './agent-scope-config.js', ['resolveAgentConfig', 'resolveAgentModelConfigForRuntime']],
  [selection, './configured-provider-fallback.js', ['resolveConfiguredProviderFallback']],
  [selection, './model-catalog-lookup.js', ['findModelCatalogEntry']],
  [selection, './model-catalog-metadata.js', ['overlayCatalogMetadata']],
  [selection, './model-compat-catalog.js', ['isVllmQwenThinkingCompat', 'modelTransportRoutesMatch']],
  [selection, './openai-model-routes.js', ['createModelCatalogIdentityKeyResolver']],
  [selection, './utility-model-setting.js', ['readUtilityModelSetting']],
  ['src/agents/provider-model-normalization.runtime.ts', '../plugins/provider-registry-selection.js', ['findProviderRuntimeRegistrationInRegistry']],
  ['packages/terminal-core/src/ansi.ts', 'string-width', ['default'], null],
];
const inventoryImports = [
  [selection, '../plugins/current-plugin-metadata-snapshot.js', ['getCurrentPluginMetadataSnapshot'], 'undefined'],
  [selection, '../plugins/manifest-contract-eligibility.js', ['loadManifestMetadataSnapshot'], 'empty-array'],
  [selection, '../plugins/runtime-state.js', ['getActivePluginRegistryWorkspaceDirFromState'], 'undefined'],
  ['src/plugins/manifest-model-id-normalization.ts', './plugin-metadata-snapshot.runtime.js', ['getCurrentPluginMetadataSnapshotRuntime', 'resolvePluginMetadataSnapshotRuntime'], 'undefined'],
  ['src/plugins/manifest-model-id-normalization.ts', './runtime-workspace-state.js', ['getActivePluginRegistryWorkspaceDirFromStateCore'], 'undefined'],
  ['src/agents/provider-model-normalization.runtime.ts', '../plugins/runtime/gateway-request-scope.js', ['getPluginRegistryForContext'], 'undefined'],
  ['src/agents/provider-model-normalization.runtime.ts', '../plugins/runtime/generation-state.js', ['getPluginRuntimeGenerationRegistry'], 'undefined'],
];

class LlmTaskCapture extends BraveCapture {
  constructor(root) {
    super(root);
    this.dependencies = new Map();
    this.generatedFacades = new Map();
    this.context.structuredClone = structuredClone;
  }
  source(path) {
    if (!sources.has(path)) return super.source(path);
    if (!this.modules.has(path)) this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
      context: this.context, identifier: path,
      importModuleDynamically: async specifier => {
        this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
        const target = this.import(specifier, path); await this.evaluate(target); return target;
      },
    }));
    return this.modules.get(path);
  }
  typeboxModule(file) {
    assert.ok(file.startsWith(this.typeboxRoot + sep));
    const id = 'llm-task:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file), path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'typebox' || specifier.startsWith('typebox/')) {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve(specifier));
      let root = dirname(file); while (!existsSync(join(root, 'package.json'))) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json')), pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox'); assert.equal(pkg.version, '1.3.37');
      if (this.typeboxRoot) assert.equal(root, this.typeboxRoot);
      this.typeboxRoot = root; this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file)); return this.typeboxModule(file);
    }
    if (importer.startsWith('llm-task:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('llm-task:typebox:'.length)), specifier)));
    }
    if (specifier === 'node:util/types') {
      link('native-platform', specifier);
      return this.synthetic(specifier, { isProxy }, { isProxy: { kind: 'native-platform', behavior: 'actual node:util/types:isProxy' } });
    }
    if (facades[specifier]) {
      const provenance = 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts'; this.verifiedSource(provenance, false);
      if (specifier === sdk + 'agent-runtime') this.verifiedSource('src/agents/model-selection.ts', false);
      const generatedCode = facades[specifier], id = 'llm-task:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    const inventory = inventoryImports.find(([owner, name]) => owner === importer && name === specifier);
    if (inventory) {
      const path = relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false); link('explicit-empty-runtime-inventory', path);
      const bindings = Object.fromEntries(inventory[2].map(name => [name, () => {
        this.audit.push({ kind: 'empty-runtime-inventory', importer, specifier, export: name, fixture: inventory[3] });
        return inventory[3] === 'empty-array' ? [] : undefined;
      }]));
      return this.synthetic('llm-task:inventory:' + importer + ':' + specifier, bindings,
        Object.fromEntries(inventory[2].map(name => [name, { kind: 'explicit-empty-runtime-inventory',
          behavior: `supplied ${inventory[3]}; no plugin discovery, activation, registry or workspace IO` }])));
    }
    const deferred = unusedImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = specifier.startsWith('.') ? relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts') : undefined;
      if (path) this.verifiedSource(path, false);
      link('explicit-unused-import', path ?? specifier); return this.deferred(importer, specifier, deferred[2]);
    }
    if (importer === readers && specifier === './tool-results.js') {
      link('executed-whole-module', results); return this.source(results);
    }
    if (specifier.startsWith('@openclaw/model-catalog-core/')) {
      const path = catalog + specifier.split('/').at(-1) + '.ts';
      link('whole-module-alias', path); return this.source(path);
    }
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t'), [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path), stat = lstatSync(file), symlink = stat.isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', path + ' executable mode');
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, mode, gitBlob: blob, sha256: digest(bytes) };
  });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN, tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, modesAndSymlinksVerified: true, filesSha256: digest(JSON.stringify(files)) };
}
function recipes() {
  const primary = { agents: { defaults: { model: 'openai/default-model' } } };
  const aliases = { agents: { defaults: { model: 'openai/default-model', models: { 'anthropic/claude-alias': { alias: 'short' } } } } };
  const plugin = { defaultProvider: ' anthropic ', defaultModel: ' claude-fixture ', defaultAuthProfileId: ' profile-default ', timeoutMs: 45000, maxTokens: 123 };
  const row = (id, arguments_, text, extra = {}) => ({ id, arguments: arguments_, config: primary, pluginConfig: {},
    runtimeDefaults: { provider: 'openai' }, completion: { text, provider: 'actual-provider', model: 'actual-model' }, ...extra });
  return [
    row('primary-string', { prompt: ' classify 雪😀 ', input: { z: 2, a: ['one', null] } }, ' {"ok":true,"text":"雪😀"} '),
    row('primary-object', { prompt: 'task' }, 'null', { config: { agents: { defaults: { model: { primary: 'openai/default-model' } } } } }),
    row('plugin-defaults', { prompt: 'task' }, 'true', { pluginConfig: plugin }),
    row('request-overrides', { provider: ' openrouter ', model: ' openrouter/vendor/model ', authProfileId: ' chosen-profile ', timeoutMs: 12345, maxTokens: 17, temperature: 0,
      thinking: ' medium ', prompt: ' task ', input: [false, 0, ' padded '] }, '0', { pluginConfig: plugin }),
    row('explicit-provider-nested', { provider: 'openrouter', model: 'vendor/nested/model', prompt: 'task' }, '" padded value "'),
    row('configured-alias', { prompt: 'task' }, '[1,null,"雪😀"]', { config: aliases, pluginConfig: { defaultModel: ' short ' } }),
    row('configured-provider-alias', { model: 'short', prompt: 'task' }, 'false', { config: aliases, pluginConfig: { defaultProvider: 'openrouter' } }),
    row('fenced-object', { prompt: 'task', input: null }, ' \n```JSON\n{"nested":[1,false,null]}\n```\t'),
    row('fenced-array', { prompt: 'task' }, '```\n["a",2]\n```'),
    row('valid-schema', { prompt: 'task', schema: { type: 'object', properties: { kind: { enum: ['ok'] }, count: { type: 'integer' }, optional: { type: 'string', default: 'unused' } },
      required: ['kind', 'count'], additionalProperties: false } }, '{"kind":"ok","count":2}'),
    row('local-ref-schema', { prompt: 'task', schema: { $defs: { entry: { type: 'string' } }, type: 'array', items: { $ref: '#/$defs/entry' } } }, '["one","雪😀"]'),
    row('plugin-timeout-token-only', { prompt: 'task', input: false }, '"done"', { pluginConfig: { timeoutMs: 61000, maxTokens: 256 } }),
  ];
}

export async function captureLlmTask(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root); const before = checkout(root);
  const records = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map();
  const vectors = []; let descriptor, typeboxVersion;
  for (const recipe of recipes()) {
    const capture = new LlmTaskCapture(root);
    const module = capture.source(factory); await capture.evaluate(module);
    const thinking = capture.source('src/auto-reply/thinking.shared.ts'); await capture.evaluate(thinking);
    const args = plain(recipe.arguments), argumentsBefore = plain(args), config = plain(recipe.config), pluginConfig = plain(recipe.pluginConfig), runtimeDefaults = plain(recipe.runtimeDefaults);
    const completeCalls = [], completeSignalProvided = [];
    const api = { config, pluginConfig, runtime: { agent: { defaults: runtimeDefaults,
      normalizeThinkingLevel: raw => {
        capture.audit.push({ kind: 'actual-thinking-normalizer', source: 'src/auto-reply/thinking.shared.ts', export: 'normalizeThinkLevel', argument: raw });
        return thinking.namespace.normalizeThinkLevel(raw);
      } }, llm: { complete: async request => {
        completeSignalProvided.push(request.signal !== undefined);
        completeCalls.push(plain(request));
        capture.audit.push({ kind: 'successful-completion-fixture', call: completeCalls.length, signalProvided: request.signal !== undefined });
        return plain(recipe.completion);
      } } } };
    const tool = module.namespace.createLlmTaskTool(api);
    const currentDescriptor = plain({ name: tool.name, label: tool.label, description: tool.description, parameters: tool.parameters });
    descriptor ??= currentDescriptor; assert.deepEqual(currentDescriptor, descriptor);
    const result = plain(await tool.execute('llm-task-' + recipe.id, args));
    assert.deepEqual(args, argumentsBefore); assert.deepEqual(config, recipe.config); assert.deepEqual(pluginConfig, recipe.pluginConfig); assert.deepEqual(runtimeDefaults, recipe.runtimeDefaults);
    assert.equal(completeCalls.length, 1); assert.equal(completeSignalProvided[0], false);
    assert.equal(capture.audit.filter(row => row.kind === 'unused-service-invoked').length, 0);
    vectors.push({ ...plain(recipe), completeCalls, completeSignalProvided, result, argumentsUnchanged: true,
      configUnchanged: true, pluginConfigUnchanged: true, runtimeDefaultsUnchanged: true, audit: capture.audit });
    typeboxVersion = capture.typeboxVersion;
    for (const [key, value] of capture.sources) records.set(key, { ...value, sha256: value.sourceSha256, executed: value.executed || records.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
  }
  const after = checkout(root); assert.deepEqual(after, before);
  return { version: 1, referencePin: BRAVE_REFERENCE_PIN, runtime: process.version,
    harness: { path: 'scripts/openclaw/capture-llm-task.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs', sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'unchanged verified whole-module loader, deterministic clock and explicit import provenance; no body projections' }],
    source: factory, invocation: 'actual createLlmTaskTool(api) -> execute(callId, rawArguments); fresh VM per vector', descriptor,
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, factoryInvoked: true, publicCallbackInvoked: true,
      actualModelAliasResolution: true, actualSchemaValidation: true, actualThinkingNormalization: true, actualTextResult: true,
      pluginRegistrationInvoked: false, productionCompletionInvoked: false, fixtureEnvironment: {},
      limits: [
        '58558 tracked blobs, executable modes and symlinks checked before/after; executed means whole module evaluated, not every export invoked',
        'Full unchanged factory/definition, model alias/default and provider/model normalization helpers, readers, JSON/schema/default/ref helpers and textResult execute',
        'Actual TypeBox1.3.37 root/schema/format/guard module graph executes in each VM; dynamic evaluation disabled, actual TypeBox interpreter fallback is used',
        'runtime.llm.complete records the full JSON request with undefined omitted and signal presence separately, then returns explicit successful text/provider/model fixtures',
        'Request execution.mode is source output only; isolated-agent-runtime, real model/provider, credential selection, timeout/cancellation and loader/host assembly do not execute',
        'Empty manifest/workspace/plugin metadata and runtime registry inventories are explicit audited inert fixtures; production discovery, hooks and activation do not execute',
        'Unrelated model catalog/config/agent/logger/registry lookup and terminal-width imports throw if invoked; no unused import service calls permitted',
        'Raw callback JSON/schema/result content is preserved; no output defaults are injected; no host implementation or native runtime parity is claimed',
        'No negative/security/permission/auth/TLS/mixed/failure/cancel/crash/forced-expiry/real-provider scenarios',
      ] },
    counts: { vectors: vectors.length, callbacks: vectors.length, executedWholeModules: [...records.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...records.values()].filter(row => !row.executed).length },
    license: { path: 'LICENSE', sha256: digest(readFileSync(join(root, 'LICENSE'))), text: readFileSync(join(root, 'LICENSE'), 'utf8') },
    sourceRecords: sorted(records.values()), aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: typeboxVersion, files: sorted(dependencies.values()) }, vectors };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2); let root = '/tmp/openclaw-488631c', output;
  for (let n = 0; n < args.length; n++) {
    if (args[n] === '--write') output = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/llm-task.json';
    else {
      assert.ok(['--source', '--output'].includes(args[n]) && args[n + 1], 'use --source ROOT --output FILE or --write');
      if (args[n] === '--source') root = args[++n]; else output = args[++n];
    }
  }
  const json = JSON.stringify(await captureLlmTask(root), null, 2) + '\n';
  if (output) writeFileSync(output, json); else process.stdout.write(json);
}
