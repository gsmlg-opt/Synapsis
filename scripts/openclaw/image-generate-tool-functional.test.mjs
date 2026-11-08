// Independently handwritten ordinary factory/list/status expectations from pinned source.
// Supplied context, configuration, provider metadata and task snapshots are inert facades.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readdirSync, readlinkSync, realpathSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { captureImageGenerateTool, IMAGE_GENERATE_TOOL_PIN } from './capture-image-generate-tool.mjs';

const root = '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const tree = '47509a47273231ab15f57252960fe716d7379ffb';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const blobHash = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const typeboxRoot = realpathSync('/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox');

function packageSnapshot(directory, prefix = '') {
  return readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const relative = prefix + entry.name;
      if (entry.isDirectory()) return packageSnapshot(join(directory, entry.name), relative + '/');
      assert.equal(entry.isFile(), true, `ordinary TypeBox file: ${relative}`);
      return [{ path: relative, sha256: hash(readFileSync(join(directory, entry.name))) }];
    });
}

// Verify every tracked blob directly, including executable modes and symlink bytes.
// This independent receipt does not reuse the exporter tree-verification helper.
function pinnedTreeSnapshot() {
  const git = args => {
    const command = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    assert.equal(command.status, 0, command.stderr);
    return command.stdout;
  };
  assert.equal(git(['rev-parse', 'HEAD']).trim(), pin);
  assert.equal(git(['rev-parse', `${pin}^{tree}`]).trim(), tree);
  const records = git(['ls-tree', '-r', '-z', pin]).split('\0').filter(Boolean).map(record => {
    const match = record.match(/^(\d+) blob ([a-f0-9]{40})\t([\s\S]+)$/);
    assert.ok(match, record);
    const [, mode, gitBlob, path] = match;
    const fullPath = join(root, path);
    const stat = lstatSync(fullPath);
    const symlink = mode === '120000';
    assert.equal(stat.isSymbolicLink(), symlink, path);
    const bytes = symlink ? Buffer.from(readlinkSync(fullPath)) : readFileSync(fullPath);
    if (!symlink) {
      assert.equal(stat.isFile(), true, path);
      assert.equal(Boolean(stat.mode & 0o111), mode === '100755', path);
    }
    assert.equal(blobHash(bytes), gitBlob, path);
    return { path, mode, gitBlob, sha256: hash(bytes), symlink,
      ...(symlink ? { symlinkTarget: bytes.toString() } : {}) };
  });
  assert.equal(records.length, 58558);
  return records;
}

const sourceBefore = pinnedTreeSnapshot();
const dependencyBefore = packageSnapshot(typeboxRoot);
const capture = await captureImageGenerateTool(root);
const dependencyAfter = packageSnapshot(typeboxRoot);
const factories = new Map(capture.factories.map(row => [row.id, row]));
const actions = new Map(capture.actions.map(row => [row.id, row]));

// Full original schema, transcribed independently from image-generate-tool.ts,
// shared descriptions, optionalStringEnum and the actual TypeBox constructors.
const expectedParameters = {
  type: 'object', properties: {
    action: { type: 'string', description: '"generate" default, "status" active task, "list" providers/models.' },
    prompt: { type: 'string', description: 'Image prompt.' },
    image: { type: 'string', description: 'Reference image path/URL for edit.' },
    images: { type: 'array', items: { type: 'string' }, description: 'Reference images for edit or style reference; max 16.' },
    model: { type: 'string', description: 'Provider/model override, e.g. openai/gpt-image-2; transparent OpenAI: openai/gpt-image-1.5.' },
    filename: { type: 'string', description: 'Output filename hint; basename preserved in managed media dir.' },
    size: { type: 'string', description: 'Size hint: 1024x1024, 1536x1024, 1024x1536, 2048x2048, 3840x2160.' },
    aspectRatio: { type: 'string', description: 'Aspect ratio: 1:1, 2:1, 20:9, 19.5:9, 2:3, 3:2, 2.35:1, 3:4, 4:3, 4:5, 5:4, 9:16, 9:19.5, 9:20, 16:9, 21:9, 1:2, 4:1, 1:4, 8:1, 1:8.' },
    resolution: { type: 'string', description: 'Resolution: 1K, 2K, 4K; useful for Google.' },
    quality: { enum: ['low', 'medium', 'high', 'xhigh', 'max', 'auto'], type: 'string', description: 'Quality: low, medium, high, xhigh, max, auto; model-specific.' },
    outputFormat: { enum: ['png', 'jpeg', 'webp'], type: 'string', description: 'Output format: png, jpeg, webp.' },
    background: { enum: ['transparent', 'opaque', 'auto'], type: 'string', description: 'Background: transparent, opaque, auto. Transparent needs png/webp output.' },
    openai: { type: 'object', properties: {
      background: { enum: ['transparent', 'opaque', 'auto'], type: 'string', description: 'OpenAI background: transparent, opaque, auto. Transparent needs png/webp; default model routes to gpt-image-1.5.' },
      moderation: { enum: ['low', 'auto'], type: 'string', description: 'OpenAI moderation: low, auto.' },
      outputCompression: { type: 'integer', description: 'OpenAI jpeg/webp compression 0-100.', minimum: 0, maximum: 100 },
      user: { type: 'string', description: 'OpenAI stable end-user id.' },
    } },
    fal: { type: 'object', properties: {
      creativity: { enum: ['raw', 'low', 'medium', 'high'], type: 'string', description: 'fal Krea creativity: raw, low, medium, high.' },
    } },
    count: { type: 'integer', description: 'Image count 1-4.', minimum: 1, maximum: 4 },
    timeoutMs: { type: 'integer', description: 'Provider timeout ms (300000 tends to be a safe amount).', minimum: 1 },
  },
};
const expectedDefinition = {
  label: 'Image Generation', name: 'image_generate',
  description: 'Create/edit images. Batch via count; aspectRatio and resolution up to 4K. Session chat runs in background: call once/request; the result returns as a later turn that sends the media. This turn: short ack at most, then end; no poll/yield. Transparent: outputFormat png|webp + background="transparent"; OpenAI also openai.background, default gpt-image-1.5. action=list providers/models/readiness/auth; status active task.',
  parameters: expectedParameters,
};

const config = { agents: { defaults: { mediaModels: { image: { primary: 'fixture-image-edit/image-main' } } } } };
const options = { workspaceDir: '/fixture/workspace', agentDir: '/fixture/agent',
  agentSessionKey: 'agent:fixture-agent:main', requesterAgentId: 'fixture-agent' };
const editCapabilities = {
  generate: { maxCount: 4, supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
  edit: { enabled: true, maxCount: 2, maxInputImages: 5,
    maxInputImagesByModel: { 'image-main': 8, 'image-fast': 3 }, maxInputImagesByModelPrefix: { 'image-': 6 },
    supportsSize: true, supportsAspectRatio: true },
};
const generateCapabilities = { generate: { maxCount: 1, supportsSize: true }, edit: { enabled: false } };
const geometryCapabilities = {
  generate: { maxCount: 3, supportsSize: true, supportsAspectRatio: true, supportsResolution: true },
  edit: { enabled: true, maxInputImages: 1, supportsResolution: true },
  geometry: { resolutions: ['1K', '2K', '4K'], resolutionsByModel: { 'image-hd': ['2K', '4K'] },
    sizes: ['1024x1024', '1536x1024'], sizesByModel: { 'image-wide': ['1536x1024'] },
    aspectRatios: ['1:1', '3:2'], aspectRatiosByModel: { 'image-wide': ['3:2'] } },
  output: { qualities: ['medium', 'high'], qualitiesByModel: { 'image-hd': ['high'] },
    formats: ['png', 'jpeg', 'webp'], formatsByModel: { 'image-wide': ['jpeg'] },
    backgrounds: ['opaque', 'transparent'], backgroundsByModel: { 'image-hd': ['opaque'] } },
};
const editProvider = { id: 'fixture-image-edit', label: 'Fixture Image Edit', defaultModel: 'image-main',
  models: ['image-main', 'image-fast'], capabilities: editCapabilities };
const generateProvider = { id: 'fixture-image-generate', label: 'Fixture Image Generate', defaultModel: 'image-basic',
  models: ['image-basic'], capabilities: generateCapabilities };
const geometryProvider = { id: 'fixture-image-geometry', label: 'Fixture Image Geometry', defaultModel: 'image-hd',
  models: ['image-hd', 'image-wide'], capabilities: geometryCapabilities };
const queued = { taskId: 'image-queued', runId: 'run-queued', taskKind: 'image_generation', status: 'queued',
  sourceId: 'image_generate:fixture-image-edit', requesterSessionKey: 'agent:fixture-agent:main',
  requesterAgentId: 'fixture-agent', progressSummary: 'Waiting for fixture slot' };
const running = { taskId: 'image-running', runId: 'run-running', taskKind: 'image_generation', status: 'running',
  sourceId: 'image_generate:fixture-image-edit', requesterSessionKey: 'agent:fixture-agent:main',
  requesterAgentId: 'fixture-agent', progressSummary: 'Rendering image 2 of 3' };

function expectedInput(overrides = {}) {
  return { config, preparedAvailability: true, configured: true, authEnvVars: [], providers: [], operations: [], ...overrides };
}
const expectedFactoryInputs = new Map([
  ['default-positive-context', expectedInput()],
  ['explicit-session-agent-context', expectedInput({ options })],
]);
const expectedActionInputs = new Map([
  ['list-edit-and-generate', expectedInput({ providers: [editProvider, generateProvider], options, args: { action: 'list' } })],
  ['list-geometry-output', expectedInput({ providers: [geometryProvider], options, args: { action: 'list' } })],
  ['status-idle', expectedInput({ options, args: { action: 'status' } })],
  ['status-queued', expectedInput({ operations: [queued], options, args: { action: 'status' } })],
  ['status-running', expectedInput({ operations: [running], options, args: { action: 'status' } })],
  ['status-plural', expectedInput({ operations: [queued, running], options, args: { action: 'status' } })],
]);

test('both positive factory contexts return the complete original metadata and full literal JSON schema', () => {
  assert.equal(IMAGE_GENERATE_TOOL_PIN, pin);
  assert.equal(capture.referenceCommit, pin);
  assert.equal(capture.schemaVersion, 1);
  assert.deepEqual(Object.keys(capture).sort(), ['schemaVersion', 'referenceCommit', 'sourceTree', 'sourceRecords',
    'importBindings', 'externalDependencies', 'runtime', 'exporter', 'limits', 'factories', 'actions'].sort());
  assert.deepEqual(capture.factories.map(row => row.id), [...expectedFactoryInputs.keys()]);
  for (const [id, input] of expectedFactoryInputs) {
    const row = factories.get(id);
    assert.deepEqual(Object.keys(row).sort(), ['id', 'input', 'definition', 'calls', 'deferredCalls'].sort(), id);
    assert.deepEqual(row.input, input, id);
    assert.deepEqual(row.definition, expectedDefinition, id);
    assert.equal(JSON.stringify(row.definition), JSON.stringify(expectedDefinition), id);
  }
  assert.deepEqual(capture.actions.map(row => row.id), [...expectedActionInputs.keys()]);
  for (const [id, input] of expectedActionInputs) {
    assert.deepEqual(Object.keys(actions.get(id)).sort(), ['id', 'input', 'result', 'calls', 'deferredCalls'].sort(), id);
    assert.deepEqual(actions.get(id).input, input, id);
  }
});

const expectedEditAndGenerateList = {
  content: [{ type: 'text', text: [
    'fixture-image-edit (default image-main)',
    '  models: image-main, image-fast',
    '  configured: yes',
    '  source: static',
    '  capabilities: editing up to 8 refs depending on model',
    'fixture-image-generate (default image-basic)',
    '  models: image-basic',
    '  configured: yes',
    '  source: static',
  ].join('\n') }],
  details: { kind: 'image_generation', providers: [
    { id: 'fixture-image-edit', label: 'Fixture Image Edit', defaultModel: 'image-main',
      models: ['image-main', 'image-fast'], modes: ['generate', 'edit'], configured: true, authEnvVars: [],
      capabilities: editCapabilities, catalog: [
        { kind: 'image_generation', provider: 'fixture-image-edit', model: 'image-main', source: 'static',
          capabilities: editCapabilities, label: 'Fixture Image Edit', default: true, modes: ['generate', 'edit'] },
        { kind: 'image_generation', provider: 'fixture-image-edit', model: 'image-fast', source: 'static',
          capabilities: editCapabilities, label: 'Fixture Image Edit', modes: ['generate', 'edit'] },
      ] },
    { id: 'fixture-image-generate', label: 'Fixture Image Generate', defaultModel: 'image-basic',
      models: ['image-basic'], modes: ['generate'], configured: true, authEnvVars: [], capabilities: generateCapabilities,
      catalog: [{ kind: 'image_generation', provider: 'fixture-image-generate', model: 'image-basic', source: 'static',
        capabilities: generateCapabilities, label: 'Fixture Image Generate', default: true, modes: ['generate'] }] },
  ] },
};
const expectedGeometryList = {
  content: [{ type: 'text', text: [
    'fixture-image-geometry (default image-hd)',
    '  models: image-hd, image-wide',
    '  configured: yes',
    '  source: static',
    '  capabilities: editing up to 1 ref; resolutions 1K/2K/4K; sizes 1024x1024, 1536x1024; aspect ratios 1:1, 3:2; formats png/jpeg/webp; backgrounds opaque/transparent',
  ].join('\n') }],
  details: { kind: 'image_generation', providers: [
    { id: 'fixture-image-geometry', label: 'Fixture Image Geometry', defaultModel: 'image-hd',
      models: ['image-hd', 'image-wide'], modes: ['generate', 'edit'], configured: true, authEnvVars: [],
      capabilities: geometryCapabilities, catalog: [
        { kind: 'image_generation', provider: 'fixture-image-geometry', model: 'image-hd', source: 'static',
          capabilities: geometryCapabilities, label: 'Fixture Image Geometry', default: true, modes: ['generate', 'edit'] },
        { kind: 'image_generation', provider: 'fixture-image-geometry', model: 'image-wide', source: 'static',
          capabilities: geometryCapabilities, label: 'Fixture Image Geometry', modes: ['generate', 'edit'] },
      ] },
  ] },
};

test('ordinary nonempty lists retain literal summaries and every original provider/catalog metadata field', () => {
  assert.deepEqual(actions.get('list-edit-and-generate').result, expectedEditAndGenerateList);
  assert.deepEqual(actions.get('list-geometry-output').result, expectedGeometryList);
});

const queuedDetails = { async: true, active: true, existingTask: true, status: 'queued',
  task: { taskId: 'image-queued', runId: 'run-queued' }, taskKind: 'image_generation',
  progressSummary: 'Waiting for fixture slot', sourceId: 'image_generate:fixture-image-edit', provider: 'fixture-image-edit' };
const runningDetails = { async: true, active: true, existingTask: true, status: 'running',
  task: { taskId: 'image-running', runId: 'run-running' }, taskKind: 'image_generation',
  progressSummary: 'Rendering image 2 of 3', sourceId: 'image_generate:fixture-image-edit', provider: 'fixture-image-edit' };
const expectedStatuses = new Map([
  ['status-idle', { content: [{ type: 'text', text: 'No active image generation task is currently running for this session.' }],
    details: { action: 'status', active: false } }],
  ['status-queued', { content: [{ type: 'text', text: [
    'Image generation task image-queued is already queued with fixture-image-edit.',
    'Progress: Waiting for fixture slot.',
    'Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished image here.',
  ].join('\n') }], details: { action: 'status', ...queuedDetails } }],
  ['status-running', { content: [{ type: 'text', text: [
    'Image generation task image-running is already running with fixture-image-edit.',
    'Progress: Rendering image 2 of 3.',
    'Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished image here.',
  ].join('\n') }], details: { action: 'status', ...runningDetails } }],
  ['status-plural', { content: [{ type: 'text', text: [
    '2 active image generation tasks are queued or running for this session.',
    '- Task image-running (run run-running) is running with fixture-image-edit. Progress: Rendering image 2 of 3.',
    '- Task image-queued (run run-queued) is queued with fixture-image-edit. Progress: Waiting for fixture slot.',
    'Do not wait, poll, or yield for them: end this turn; each completion arrives as a later turn and sends the finished images here.',
    'Only start a new image_generate call if the user clearly asks for different/new images.',
  ].join('\n') }], details: { action: 'status', async: true, active: true, existingTask: true,
    taskCount: 2, tasks: [runningDetails, queuedDetails] } }],
]);

test('idle queued running and plural status preserve complete text/details and running-first order', () => {
  for (const [id, expected] of expectedStatuses) assert.deepEqual(actions.get(id).result, expected, id);
});

function expectedFactoryCalls(input) {
  return [
    { callback: 'createSubsystemLogger', name: 'agents/tools/image-generate' },
    { callback: 'resolveMediaGenerateToolContext', key: 'imageGenerationProviders',
      ...(input.options ? { options: input.options } : {}), preparedAvailability: true },
  ];
}

test('full ordered facade ledgers match original dispatch and supplied successful metadata callbacks', () => {
  for (const [id, input] of expectedFactoryInputs) {
    assert.deepEqual(factories.get(id).calls, expectedFactoryCalls(input), id);
    assert.deepEqual(factories.get(id).deferredCalls, [], id);
  }
  for (const [id, input] of expectedActionInputs) {
    const calls = expectedFactoryCalls(input);
    if (input.args.action === 'list') {
      calls.push({ callback: 'prepareToolAuthProfileStore', options, source: 'inert supplied success' },
        { callback: 'withImageGenerationProviders', config });
      for (const provider of input.providers) calls.push({ callback: 'isConfiguredAsync', provider: provider.id,
        context: { cfg: config, agentDir: '/fixture/agent' }, value: true });
      for (const provider of input.providers) calls.push({ callback: 'getProviderEnvVarsCore', providerId: provider.id });
    } else {
      calls.push({ callback: 'listMediaGenerationOperations', sessionKey: 'agent:fixture-agent:main', agentId: 'fixture-agent' });
    }
    assert.deepEqual(actions.get(id).calls, calls, id);
    assert.deepEqual(actions.get(id).deferredCalls, [], id);
  }
});

test('all original source modules and their complete transformed imports have independently verified provenance', () => {
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.sourceTree.before.verified, true);
  assert.equal(capture.sourceTree.before.commit, pin);
  assert.equal(capture.sourceTree.before.tree, tree);
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.match(capture.sourceTree.before.filesSha256, /^[a-f0-9]{64}$/);
  const tracked = new Map(sourceBefore.map(row => [row.path, row]));
  const sources = new Map(capture.sourceRecords.map(row => [row.path, row]));
  assert.equal(sources.size, capture.sourceRecords.length);
  for (const required of [
    'src/agents/tools/image-generate-tool.ts', 'src/agents/tools/image-generate-tool.actions.ts',
    'src/agents/tools/media-generate-tool-actions-shared.ts', 'src/agents/tools/media-tool-shared.ts',
    'src/agents/schema/string-enum.ts', 'src/agents/tools/common.ts',
    'src/agents/media-generation-task-status.ts', 'src/agents/media-generation-task-status-shared.ts',
    'src/agents/session-async-task-status.ts', 'packages/media-generation-core/src/catalog.ts',
  ]) assert.equal(sources.get(required)?.executed, true, required);
  const edges = new Set(capture.importBindings.map(binding => binding.importer + '\0' + binding.specifier));
  for (const source of sources.values()) {
    const original = tracked.get(source.path);
    assert.ok(original, source.path);
    for (const key of ['mode', 'gitBlob', 'sha256', 'symlink']) assert.equal(source[key], original[key], source.path + ':' + key);
    if (original.symlink) assert.equal(source.symlinkTarget, original.symlinkTarget, source.path);
    assert.equal(source.originalSourceExecuted, source.executed, source.path);
    if (!source.executed) continue;
    assert.equal(source.wholeModule, true, source.path);
    assert.equal(source.transformation, transformation, source.path);
    assert.equal(Object.hasOwn(source, 'projection'), false, source.path);
    const executable = stripTypeScriptTypes(readFileSync(join(root, source.path), 'utf8'), { mode: 'transform', sourceMap: false });
    assert.equal(hash(executable), source.executableSha256, source.path);
    const parsed = new vm.SourceTextModule(executable, { identifier: source.path });
    for (const specifier of parsed.dependencySpecifiers) assert.ok(edges.has(source.path + '\0' + specifier), `${source.path} -> ${specifier}`);
  }
  assert.equal(capture.runtime.transformation, transformation);
  assert.deepEqual(capture.runtime.entry, { path: 'src/agents/tools/image-generate-tool.ts',
    export: 'createImageGenerateTool', sha256: hash(readFileSync(join(root, 'src/agents/tools/image-generate-tool.ts'))) });
  const kinds = new Set(['actual-whole-source-module', 'actual-whole-package-module', 'actual-platform-builtin',
    'uninvoked-external-package-binding', 'explicit-inert-supplied-fixture-facade', 'uninvoked-throwing-binding']);
  for (const binding of capture.importBindings) {
    assert.ok(kinds.has(binding.kind), binding.key);
    if (binding.generatedCode !== undefined) {
      assert.equal(binding.generatedSha256, hash(binding.generatedCode), binding.key);
      assert.equal(binding.originalSourceExecuted, false, binding.key);
    }
    if (binding.source?.startsWith('package:')) {
      const match = binding.source.match(/^package:typebox\/(.+)$/);
      assert.ok(match, binding.key);
      assert.equal(binding.sourceSha256, hash(readFileSync(join(typeboxRoot, match[1]))), binding.key);
    } else if (binding.source) {
      assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))), binding.key);
    } else if (binding.referenceManifest) {
      assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.referenceManifest))), binding.key);
    }
    if (binding.kind === 'actual-whole-source-module') assert.equal(sources.get(binding.source)?.executed, true, binding.key);
    if (binding.kind.startsWith('uninvoked-')) assert.ok(binding.generatedCode.includes('__defer('), binding.key);
  }
  for (const source of ['src/agents/tools/media-generate-background.ts', 'src/agents/tools/model-config.helpers.ts',
    'src/agents/tools/manifest-capability-availability.ts', 'src/image-generation/runtime.ts', 'src/agents/media-generation-activity.ts']) {
    assert.equal(sources.get(source)?.executed, false, source);
    assert.ok(capture.importBindings.some(binding => binding.source === source && binding.originalSourceExecuted === false), source);
  }
  // Authentication is cut at the directly imported model-config helper facade.
  // Its model-auth dependency is never linked because that helper is unexecuted.
  for (const [importer, exports] of [
    ['src/agents/tools/media-generate-tool-actions-shared.ts', ['prepareToolAuthProfileStore']],
    ['src/agents/tools/media-tool-shared.ts', ['buildToolModelConfigFromCandidates', 'coerceToolModelConfig',
      'hasProviderAuthForTool', 'hasToolModelConfig', 'resolveDefaultModelRef']],
  ]) {
    const binding = capture.importBindings.find(row => row.importer === importer && row.specifier === './model-config.helpers.js');
    assert.ok(binding, importer);
    assert.equal(binding.source, 'src/agents/tools/model-config.helpers.ts', importer);
    assert.equal(binding.kind, 'explicit-inert-supplied-fixture-facade', importer);
    assert.equal(binding.originalSourceExecuted, false, importer);
    assert.deepEqual(binding.exports, exports, importer);
  }
  assert.match(readFileSync(join(root, 'src/agents/tools/model-config.helpers.ts'), 'utf8'), /from "\.\.\/model-auth\.js"/);
  assert.equal(sources.has('src/agents/model-auth.ts'), false);
  assert.equal(capture.importBindings.some(binding => binding.source === 'src/agents/model-auth.ts'), false);
});

test('actual TypeBox dependency runtime and exporter hashes are independently checked without package mutation', () => {
  assert.deepEqual(dependencyAfter, dependencyBefore);
  assert.deepEqual(capture.externalDependencies.map(pkg => pkg.name), ['typebox']);
  const pkg = capture.externalDependencies[0];
  assert.equal(pkg.version, '1.3.37');
  assert.equal(pkg.root, typeboxRoot);
  assert.equal(pkg.referenceManifest, 'package.json');
  assert.equal(pkg.referenceLock, 'pnpm-lock.yaml');
  assert.equal(pkg.entryResolution, 'actual package exports import condition');
  const manifest = JSON.parse(readFileSync(join(root, pkg.referenceManifest)));
  const installed = JSON.parse(readFileSync(join(typeboxRoot, 'package.json')));
  assert.equal(manifest.dependencies.typebox, '1.3.37');
  assert.equal(installed.name, 'typebox');
  assert.equal(installed.version, '1.3.37');
  const lock = readFileSync(join(root, pkg.referenceLock), 'utf8');
  const lockRow = lock.match(/^  typebox@1\.3\.37:[\s\S]*?resolution: \{integrity: ([^}]+)\}/m);
  assert.ok(lockRow);
  assert.equal(pkg.lockIntegrity, lockRow[1]);
  const files = new Map(dependencyBefore.map(file => [file.path, file.sha256]));
  assert.ok(pkg.files.length > 1);
  for (const file of pkg.files) assert.equal(file.sha256, files.get(file.path.replace(/^typebox\//, '')), file.path);
  assert.equal(capture.runtime.node.version, '24.22.1');
  assert.equal(capture.runtime.node.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(capture.runtime.node.sha256, hash(readFileSync(capture.runtime.node.executable)));
  assert.equal(capture.runtime.node.platform, process.platform);
  for (const record of [capture.runtime.host, capture.runtime.vectorSetup]) assert.equal(record.sha256, hash(record.generatedCode));
  assert.equal(capture.exporter.path, 'scripts/openclaw/capture-image-generate-tool.mjs');
  for (const record of [capture.exporter, capture.exporter.adaptedHarness]) {
    assert.equal(record.sha256, hash(readFileSync(new URL('../../' + record.path, import.meta.url))), record.path);
  }
  assert.equal(typeof capture.exporter.adaptedHarness.relationship, 'string');
  assert.equal(typeof capture.runtime.importPolicy, 'object');
});

test('bounded ordinary observations preserve explicit inert and unexecuted boundaries', () => {
  for (const key of ['factorySourceUnchanged', 'wholeOriginalModules', 'freshVmPerCase', 'factoryExecuted',
    'listExecuted', 'statusExecuted', 'catalogSourceExecuted', 'statusOwnerSourceExecuted']) assert.equal(capture.limits[key], true, key);
  for (const key of ['generateExecuted', 'duplicateGuardExecuted', 'providerGenerationExecuted', 'providerIOExecuted',
    'taskRegistryExecuted', 'lifecycleExecuted', 'jobExecuted', 'completionExecuted', 'pluginLoaderExecuted',
    'authExecuted', 'permissionExecuted', 'policyAcceptanceExecuted', 'availabilityResolutionExecuted',
    'modelConfigNormalizationExecuted', 'networkExecuted', 'storageExecuted', 'canonicalFactoryComplete',
    'runtimeAssemblyComplete', 'fullToolParity']) assert.equal(capture.limits[key], false, key);
  for (const key of ['schema', 'metadata', 'context', 'providerRegistry', 'taskSnapshot', 'authentication']) {
    assert.equal(typeof capture.limits[key], 'string', key);
    assert.ok(capture.limits[key].length > 0, key);
  }
  assert.ok(Array.isArray(capture.limits.unexecutedBranches));
  assert.ok(capture.limits.unexecutedBranches.length > 0);
});

test('two fresh whole-source captures exactly reproduce the complete frozen JSON', async () => {
  const file = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/image-generate-tool.json', import.meta.url);
  assert.equal(existsSync(file), true, 'parent-generated frozen fixture must be available');
  const frozen = JSON.parse(readFileSync(file));
  assert.deepEqual(capture, frozen);
  const fresh = await captureImageGenerateTool(root);
  assert.deepEqual(fresh, capture);
  assert.deepEqual(fresh, frozen);
  assert.deepEqual(packageSnapshot(typeboxRoot), dependencyBefore);
  assert.deepEqual(pinnedTreeSnapshot(), sourceBefore);
});
