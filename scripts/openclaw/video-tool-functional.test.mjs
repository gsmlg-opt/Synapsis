// Ordinary pinned-source factory/list/status observations under explicit inert lower facades.
// No generate callback, provider access, readiness or lifecycle execution is exercised.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, realpathSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { captureVideoTool, VIDEO_TOOL_PIN } from './capture-video-tool.mjs';

const root = '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const typeboxRoot = realpathSync('/tmp/synapsis-openclaw-capture-runtime/node_modules/typebox');
function packageSnapshot(directory, prefix = '') {
  return readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const relative = prefix + entry.name;
      if (entry.isDirectory()) return packageSnapshot(join(directory, entry.name), relative + '/');
      assert.equal(entry.isFile(), true, `ordinary dependency file: ${relative}`);
      return [{ path: relative, sha256: hash(readFileSync(join(directory, entry.name))) }];
    });
}
const dependencyBefore = packageSnapshot(typeboxRoot);
const capture = await captureVideoTool(root);
const dependencyAfter = packageSnapshot(typeboxRoot);
const factories = new Map(capture.factoryCases.map(row => [row.id, row]));
const actions = new Map(capture.actionCases.map(row => [row.id, row]));

// Independently transcribed from the whole original video-generate-tool.ts schema,
// media-tool-shared.ts descriptions and installed TypeBox1.3.37 constructors.
function expectedParameters(audioReferences) {
  const properties = {
    action: { type: 'string', description: '"generate" default, "status" active task, "list" providers/models.' },
    prompt: { type: 'string', description: 'Video prompt.' },
    image: { type: 'string', description: 'One reference image path/URL.' },
    images: { type: 'array', items: { type: 'string' }, description: 'Reference images; max 9.' },
    imageRoles: { type: 'array', items: { type: 'string' }, description: '`image` + `images` roles by index. Values: first_frame, last_frame, reference_image; empty string leaves unset.' },
    video: { type: 'string', description: 'One reference video path/URL.' },
    videos: { type: 'array', items: { type: 'string' }, description: 'Reference videos; max 4.' },
    videoRoles: { type: 'array', items: { type: 'string' }, description: '`video` + `videos` roles by index. Value: reference_video; empty string leaves unset.' },
    ...(audioReferences ? {
      audioRef: { type: 'string', description: 'One reference audio path/URL, e.g. music.' },
      audioRefs: { type: 'array', items: { type: 'string' }, description: 'Reference audios; max 3.' },
      audioRoles: { type: 'array', items: { type: 'string' }, description: '`audioRef` + `audioRefs` roles by index. Value: reference_audio; empty string leaves unset.' },
    } : {}),
    model: { type: 'string', description: 'Provider/model override, e.g. qwen/wan2.6-t2v.' },
    filename: { type: 'string', description: 'Output filename hint; basename preserved in managed media dir.' },
    size: { type: 'string', description: 'Size hint, e.g. 1280x720, 1920x1080.' },
    aspectRatio: { type: 'string', description: 'Aspect ratio: 1:1, 16:9, 9:16, "adaptive", or provider value; unsupported normalized/ignored.' },
    resolution: { type: 'string', description: 'Resolution: 360P, 480P, 540P, 720P, 768P, 1080P, 4K, or provider value; unsupported normalized/ignored.' },
    durationSeconds: { type: 'integer', description: 'Target seconds; may round to nearest supported duration.', minimum: 1 },
    audio: { type: 'boolean', description: 'Generated-audio toggle.' },
    watermark: { type: 'boolean', description: 'Watermark toggle.' },
    providerOptions: { type: 'object', patternProperties: { '^.*$': {} }, description: 'Provider JSON options, e.g. {"seed":42}. Keys/types must match provider capabilities; mismatch skips candidate. Use action=list for accepted keys.' },
    timeoutMs: { type: 'integer', description: 'Provider timeout ms.', minimum: 1 },
  };
  return { type: 'object', properties };
}

function expectedDescriptor(audioReferences) {
  return {
    name: 'video_generate',
    label: 'Video Generation',
    displaySummary: 'Generate videos',
    description: 'Create video, incl. image-to-video: image refs take first_frame/last_frame/reference_image roles; video refs condition style' +
      (audioReferences ? '; audio refs condition sound' : '') +
      '. resolution up to 4K; audio/watermark toggles. action=list discovers providers/models. Session chat background: call once/request; result returns as a later turn that sends the media. This turn: short ack at most, then end; no poll/yield. status checks active task. Duration may round to provider value.',
    parameters: expectedParameters(audioReferences),
    executeObserved: true,
  };
}

test('complete original factory returns exact literal metadata and both selected audio-reference schemas', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(VIDEO_TOOL_PIN, pin);
  assert.equal(capture.referenceCommit, pin);
  assert.deepEqual(capture.factoryCases.map(row => row.id), ['audio-disabled', 'audio-enabled']);
  for (const [id, audioReferences] of [['audio-disabled', false], ['audio-enabled', true]]) {
    assert.deepEqual(factories.get(id).descriptor, expectedDescriptor(audioReferences), id);
  }
});

const config = { agents: { defaults: { mediaModels: { video: { primary: 'fixture-video/video-main' } } } } };
function expectedSnapshot(audioReferences) {
  return { plugins: [{ id: 'fixture-video-plugin', contracts: { videoGenerationProviders: ['fixture-video'] },
    videoGenerationProviderMetadata: { 'fixture-video': { referenceAudioInputs: audioReferences } } }],
  index: { plugins: [] } };
}

function expectedInput(audioReferences = false, overrides = {}) {
  return {
    config, snapshot: expectedSnapshot(audioReferences), modelConfig: { primary: 'fixture-video/video-main' },
    options: { workspaceDir: '/fixture/workspace', agentDir: '/fixture/agent',
      agentSessionKey: 'agent:fixture-agent:main', requesterAgentId: 'fixture-agent' },
    configured: true, authEnvVars: [], providers: [], operations: [], ...overrides,
  };
}

// These are independently declared input fixtures, not data imported from the producer.
const capabilities = {
  generate: { maxVideos: 2, maxInputAudios: 0, maxDurationSeconds: 12, supportedDurationSeconds: [4, 8, 12],
    supportedDurationSecondsByModel: { 'video-main': [4, 8] }, supportsResolution: true, supportsAudio: true,
    providerOptions: { seed: 'number', shared: 'string' } },
  imageToVideo: { enabled: true, maxInputImages: 2, maxDurationSeconds: 8, supportsAspectRatio: true,
    providerOptions: { motion: 'string', shared: 'boolean' } },
  videoToVideo: { enabled: true, maxInputVideos: 1, supportsWatermark: true, providerOptions: { strength: 'number' } },
  providerOptions: { quality: 'string', shared: 'number' },
};
const fastCapabilities = {
  generate: { maxVideos: 1, maxDurationSeconds: 6, supportedDurationSeconds: [3, 6], supportsSize: true,
    providerOptions: { seed: 'number' } },
  providerOptions: { quality: 'string' },
};
const editCapabilities = { generate: { maxVideos: 1 }, videoToVideo: { enabled: true, maxInputVideos: 1,
  maxDurationSeconds: 5, supportsWatermark: true, providerOptions: { strength: 'number' } } };
const provider = {
  id: 'fixture-video', label: 'Fixture Video', defaultModel: ' video-main ',
  models: ['video-fast', 'video-main', ' video-fast ', 'video-edit', ''], capabilities,
  catalogByModel: {
    'video-fast': { modes: ['generate'], capabilities: fastCapabilities },
    'video-edit': { modes: ['videoToVideo'], capabilities: editCapabilities },
  },
};
const queued = {
  taskId: 'video-queued', runId: 'run-queued', taskKind: 'video_generation', status: 'queued',
  sourceId: 'video_generate:fixture-video', requesterSessionKey: 'agent:fixture-agent:main',
  requesterAgentId: 'fixture-agent', progressSummary: 'Waiting for fixture slot',
};
const running = { ...queued, taskId: 'video-running', runId: 'run-running', status: 'running',
  progressSummary: 'Rendering frame 3 of 8' };

test('audio-schema branch inputs are fixed metadata snapshots with supplied successful availability', () => {
  for (const [id, audioReferences] of [['audio-disabled', false], ['audio-enabled', true]]) {
    assert.deepEqual(factories.get(id).input, expectedInput(audioReferences), id);
  }
});

test('ordinary list dispatch returns the exact static catalog, models, ordered modes and unchanged capabilities', () => {
  assert.deepEqual(capture.actionCases.map(row => row.id), [
    'list-empty', 'list-catalog', 'status-idle', 'status-running', 'status-queued', 'status-running-preferred',
  ]);
  assert.deepEqual(actions.get('list-empty').input, expectedInput(false, { args: { action: 'list' } }));
  assert.deepEqual(actions.get('list-empty').result, {
    content: [{ type: 'text', text: 'No video-generation providers are registered.' }], details: { providers: [] },
  });
  assert.deepEqual(actions.get('list-catalog').input, expectedInput(false, { providers: [provider], args: { action: 'list' } }));
  assert.deepEqual(actions.get('list-catalog').result, {
    content: [{ type: 'text', text: [
      'fixture-video (default  video-main )',
      '  models: video-main, video-fast, video-edit',
      '  configured: yes',
      '  source: static',
      '  capabilities: modes=generate/imageToVideo/videoToVideo, maxVideos=2, maxInputImages=2, maxInputVideos=1, maxDurationSeconds=12, supportedDurationSeconds=4/8/12, supportedDurationSecondsByModel=video-main:4/8, resolution, aspectRatio, audio, watermark, providerOptions={quality:string, shared:boolean, seed:number, motion:string, strength:number}',
      '  model video-fast: modes=generate, maxVideos=1, maxDurationSeconds=6, supportedDurationSeconds=3/6, size, providerOptions={quality:string, seed:number}',
      '  model video-edit: modes=videoToVideo, maxVideos=1, maxInputVideos=1, maxDurationSeconds=5, watermark, providerOptions={strength:number}',
    ].join('\n') }],
    details: { kind: 'video_generation', providers: [{ id: 'fixture-video', label: 'Fixture Video',
      defaultModel: ' video-main ', models: ['video-main', 'video-fast', 'video-edit'],
      modes: ['generate', 'imageToVideo', 'videoToVideo'], configured: true, authEnvVars: [], capabilities,
      catalog: [
        { kind: 'video_generation', provider: 'fixture-video', model: 'video-main', source: 'static',
          capabilities, label: 'Fixture Video', default: true, modes: ['generate', 'imageToVideo', 'videoToVideo'] },
        { kind: 'video_generation', provider: 'fixture-video', model: 'video-fast', source: 'static',
          capabilities: fastCapabilities, label: 'Fixture Video', modes: ['generate'] },
        { kind: 'video_generation', provider: 'fixture-video', model: 'video-edit', source: 'static',
          capabilities: editCapabilities, label: 'Fixture Video', modes: ['videoToVideo'] },
      ] }] },
  });
});

function expectedActiveStatus(operation) {
  return {
    content: [{ type: 'text', text: [
      `Video generation task ${operation.taskId} is already ${operation.status} with fixture-video.`,
      `Progress: ${operation.progressSummary}.`,
      'Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished video here.',
    ].join('\n') }],
    details: { action: 'status', async: true, active: true, existingTask: true, status: operation.status,
      task: { taskId: operation.taskId, runId: operation.runId }, taskKind: 'video_generation',
      progressSummary: operation.progressSummary, sourceId: 'video_generate:fixture-video', provider: 'fixture-video' },
  };
}

test('ordinary idle, queued and running status retain exact original text/details with running preference', () => {
  assert.deepEqual(actions.get('status-idle').input, expectedInput(false, { args: { action: 'status' } }));
  assert.deepEqual(actions.get('status-idle').result, {
    content: [{ type: 'text', text: 'No active video generation task is currently running for this session.' }],
    details: { action: 'status', active: false },
  });
  for (const [id, operations, expected] of [
    ['status-running', [running], running], ['status-queued', [queued], queued],
    ['status-running-preferred', [queued, running], running],
  ]) {
    assert.deepEqual(actions.get(id).input, expectedInput(false, { operations, args: { action: 'status' } }), id);
    assert.deepEqual(actions.get(id).result, expectedActiveStatus(expected), id);
  }
});

test('successful facades and unexecuted generation, readiness and lifecycle boundaries stay explicit', () => {
  for (const key of ['factorySourceUnchanged', 'freshVmPerCase', 'factoryExecuted', 'listExecuted',
    'statusExecuted', 'catalogSourceExecuted', 'capabilitiesSourceExecuted', 'statusOwnerSourceExecuted',
    'generateUnexecuted']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['generateExecuted', 'providerGenerationExecuted', 'taskRegistryExecuted', 'lifecycleExecuted',
    'claimExecuted', 'recoveryExecuted', 'authExecuted', 'permissionExecuted', 'environmentLookupExecuted',
    'networkExecuted', 'storageExecuted', 'workspaceReadinessExecuted', 'modelConfigNormalizationExecuted',
    'availabilityResolutionExecuted', 'fullToolParity']) assert.equal(capture.boundaries[key], false, key);
  assert.equal(capture.boundaries.context, 'supplied successful tool context');
  assert.equal(capture.boundaries.providerRegistry, 'supplied provider metadata with inert configured-success callbacks');
  assert.equal(capture.boundaries.taskSnapshot,
    'supplied same-session/same-agent video operation arrays; original owner filtering and status builders');
  assert.equal(capture.boundaries.authentication, 'inert supplied literals and success facades; no credential lookup');
  assert.deepEqual(capture.provenance.deferredCalls, []);
  for (const row of [...capture.factoryCases, ...capture.actionCases]) {
    assert.equal(row.freshVm, true, row.id);
    assert.deepEqual(row.deferredCalls, [], row.id);
  }
});

test('complete original modules and exact transformer bytes retain independently verified source provenance', () => {
  const provenance = capture.provenance;
  assert.equal(provenance.transformation, 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
  assert.deepEqual(provenance.sourceTreeBefore, {
    verified: true, commit: pin, tree: '47509a47273231ab15f57252960fe716d7379ffb',
    verifiedTrackedFiles: 58558, filesSha256: 'fb299c6a234f52cfcf20e3618cd11582d07e47a7773cba1334064ebdaf9fddec',
  });
  assert.deepEqual(provenance.sourceTreeAfter, provenance.sourceTreeBefore);
  const executed = provenance.sources.filter(source => source.executed);
  for (const required of [
    'src/agents/tools/video-generate-tool.ts', 'src/agents/tools/video-generate-tool.actions.ts',
    'src/agents/tools/media-generate-tool-actions-shared.ts', 'src/agents/tools/media-tool-shared.ts',
    'src/agents/tools/common.ts', 'src/agents/media-generation-task-status.ts',
    'src/agents/media-generation-task-status-shared.ts', 'src/agents/session-async-task-status.ts',
    'packages/media-generation-core/src/catalog.ts', 'src/video-generation/capabilities.ts',
  ]) assert.ok(executed.some(source => source.path === required), required);
  const edges = new Set(provenance.importBindings.map(binding => binding.importer + '\0' + binding.specifier));
  for (const source of provenance.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(hash(bytes), source.sha256, source.path);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), source.gitBlob, source.path);
    if (!source.executed) continue;
    assert.equal(source.wholeModule, true, source.path);
    assert.equal(source.transformation, provenance.transformation, source.path);
    assert.equal(Object.hasOwn(source, 'projection'), false, source.path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    assert.equal(hash(executable), source.executableSha256, source.path);
    // Parse the entire transformed module without linking/evaluating it; every
    // static source dependency must have an auditable exact importer edge.
    const parsed = new vm.SourceTextModule(executable, { identifier: source.path });
    for (const specifier of parsed.dependencySpecifiers) {
      assert.ok(edges.has(source.path + '\0' + specifier), `${source.path} -> ${specifier}`);
    }
  }
  for (const record of [provenance.exporter, provenance.sharedHarness, provenance.captureRecipes]) {
    assert.equal(record.sha256, hash(readFileSync(new URL('../../' + record.path, import.meta.url))), record.path);
  }
  assert.equal(provenance.node.version, '24.22.1');
  assert.equal(provenance.node.executable, '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node');
  assert.equal(provenance.node.sha256, hash(readFileSync(provenance.node.executable)));
  assert.equal(provenance.node.platform, process.platform);
  assert.equal(provenance.host.sha256, hash(provenance.host.generatedCode));
});

test('actual TypeBox files, pinned dependency declaration and lock integrity remain unchanged across capture', () => {
  assert.deepEqual(dependencyAfter, dependencyBefore);
  assert.deepEqual(capture.provenance.packages.map(pkg => pkg.name), ['typebox']);
  const pkg = capture.provenance.packages[0];
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
  const independentlyHashed = new Map(dependencyBefore.map(file => [file.path, file.sha256]));
  assert.ok(pkg.files.some(file => file.path === 'package.json'));
  assert.ok(pkg.files.some(file => file.path === 'build/type/types/object.mjs'));
  assert.ok(pkg.files.some(file => file.path === 'build/type/types/record.mjs'));
  for (const file of pkg.files) assert.equal(file.sha256, independentlyHashed.get(file.path), file.path);
});

test('every source import is explicitly bound to original bytes, the actual package or a labeled inert facade', () => {
  const provenance = capture.provenance;
  const sources = new Map(provenance.sources.map(source => [source.path, source]));
  const packages = new Map(provenance.packages.map(pkg => [pkg.name, pkg]));
  const kinds = new Set(['actual-whole-source-module', 'actual-whole-package-module', 'actual-platform-builtin',
    'explicit-inert-supplied-fixture-facade', 'uninvoked-throwing-binding', 'uninvoked-external-package-binding']);
  assert.ok(provenance.importBindings.length > 0);
  for (const binding of provenance.importBindings) {
    assert.ok(kinds.has(binding.kind), binding.key);
    assert.equal(typeof binding.importer, 'string', binding.key);
    assert.equal(typeof binding.specifier, 'string', binding.key);
    if (binding.kind === 'actual-platform-builtin') {
      assert.equal(binding.specifier, 'node:path');
      assert.ok(binding.exports.includes('default'));
      continue;
    }
    if (binding.source?.startsWith('package:')) {
      const [, name, relative] = binding.source.match(/^package:([^/]+)\/(.*)$/);
      const pkg = packages.get(name);
      assert.equal(binding.sourceSha256, hash(readFileSync(join(pkg.root, relative))), binding.key);
    } else if (binding.source) {
      assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.source))), binding.key);
    } else {
      assert.equal(binding.referenceManifest, 'package.json', binding.key);
      assert.equal(binding.sourceSha256, hash(readFileSync(join(root, binding.referenceManifest))), binding.key);
    }
    if (binding.originalSourceExecuted) {
      if (binding.kind === 'actual-whole-source-module') assert.equal(sources.get(binding.source).executed, true);
      else assert.equal(binding.kind, 'actual-whole-package-module');
      continue;
    }
    assert.equal(binding.originalSourceExecuted, false, binding.key);
    assert.equal(binding.generatedSha256, hash(binding.generatedCode), binding.key);
    assert.ok(binding.exports.length > 0, binding.key);
    for (const name of binding.exports) {
      assert.match(binding.generatedCode, new RegExp(`export (?:async )?(?:function|class) ${name}\\b`), binding.key);
    }
    if (binding.kind.startsWith('uninvoked-')) assert.ok(binding.generatedCode.includes('__defer('), binding.key);
  }
  // Positive provenance assertions: these owners are supplied data, not executed
  // authentication/config/registry implementations or a generated task lifecycle.
  for (const source of ['src/agents/tools/media-generate-background.ts', 'src/agents/tools/model-config.helpers.ts',
    'src/agents/tools/manifest-capability-availability.ts', 'src/agents/model-auth.ts',
    'src/video-generation/runtime.ts', 'src/agents/media-generation-activity.ts']) {
    assert.equal(sources.get(source).executed, false, source);
    assert.ok(provenance.importBindings.some(binding => binding.source === source &&
      binding.kind === 'explicit-inert-supplied-fixture-facade' && binding.originalSourceExecuted === false), source);
  }
});

test('original descriptor and action JSON bytes round-trip without excluding fields or changing order', () => {
  for (const row of capture.factoryCases) {
    assert.equal(JSON.stringify(row.descriptor), row.descriptorJson, row.id);
    assert.equal(JSON.stringify(row.descriptor.parameters), row.schemaJson, row.id);
  }
  for (const row of capture.actionCases) assert.equal(JSON.stringify(row.result), row.resultJson, row.id);
});

test('fresh complete-source captures reproduce the entire frozen fixture deterministically', async () => {
  const file = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/video-tool.json', import.meta.url);
  assert.equal(existsSync(file), true, 'parent-generated frozen fixture must be available for final acceptance');
  const frozen = JSON.parse(readFileSync(file));
  assert.deepEqual(capture, frozen);
  const fresh = await captureVideoTool(root);
  assert.deepEqual(fresh, capture);
  assert.deepEqual(fresh, frozen);
  assert.deepEqual(packageSnapshot(typeboxRoot), dependencyBefore);
});
