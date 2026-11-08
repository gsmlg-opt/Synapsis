// Complete pinned OpenRouter modules; ordinary successful speech callbacks only.
// Run with Node 24.21.0: node --experimental-vm-modules this-file --source DIR --output FILE
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const OPENROUTER_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const OPENROUTER_SPEECH_SOURCE = 'extensions/openrouter/speech-provider.ts';
const timeoutSource = 'src/tts/tts-provider-resolution.ts';
const sourcePaths = [OPENROUTER_SPEECH_SOURCE, 'extensions/openrouter/provider-defaults.ts',
  'src/tts/openai-compatible-speech-provider.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'src/shared/dot-path.ts', 'src/shared/path-array-index.ts', 'src/infra/prototype-keys.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', timeoutSource];
const manifestPath = 'extensions/openrouter/openclaw.plugin.json';
const licensePath = 'LICENSE';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const fixtureKey = 'fixture-openrouter-speech';
const executionTimeoutMs = 2000;
const audioBytes = Buffer.from([82, 73, 70, 70, 0, 1, 2, 255]);
const responseFixture = { status: 200, headers: { 'Content-Type': 'application/octet-stream' },
  audioBase64: audioBytes.toString('base64') };

// Export wiring only. Original complete module bytes receive TypeScript erasure only.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    'export { createOpenAiCompatibleSpeechProvider } from "src/tts/openai-compatible-speech-provider.ts";\n',
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n',
  '@openclaw/normalization-core/record-coerce':
    'export { asOptionalRecord, asOptionalObjectRecord } from "packages/normalization-core/src/record-coerce.ts";\n',
  '@openclaw/normalization-core/string-coerce':
    'export { normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumber, asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
};

const uninvoked = names => Object.fromEntries(names.map(name =>
  [name, 'uninvoked throwing binding for unrelated complete timeout-resolver exports; original module unexecuted']));
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'returns explicit fixture string or undefined; production secret resolution unexecuted',
  },
  'src/plugin-sdk/provider-http.ts': {
    resolveProviderHttpRequestConfig: 'records original arguments; returns Headers(defaultHeaders) and supplied policy fields without applying policy; original resolver unexecuted',
    postJsonRequest: 'records complete declared URL, headers, body, timeout, policy fields and fetch binding presence; returns synthetic opaque successful response and counted release; original HTTP unexecuted',
    assertOkOrThrowHttpError: 'records successful response status and label; original HTTP error handling unexecuted',
    readProviderBinaryResponse: 'records successful response/reader arguments and cap/callback presence; returns exact opaque fixture bytes; original reader unexecuted',
  },
  'src/plugins/sdk-deprecation.ts': uninvoked(['warnPluginSdkDeprecation']),
  'src/tts/provider-registry-core.ts': uninvoked(['compareSpeechProviderOrder']),
  'src/tts/provider-registry.ts': uninvoked(['canonicalizeSpeechProviderId', 'getSpeechProvider',
    'listSpeechProviders', 'normalizeSpeechProviderId']),
  'src/tts/speaker.ts': uninvoked(['withSpeakerSelectionCompat']),
  'src/tts/tts-settings.ts': {
    DEFAULT_TTS_TIMEOUT_MS: 'undefined binding; fallback branch unused by all four positive timeout inputs; original constant module unexecuted',
    ...uninvoked(['asProviderConfig', 'normalizeConfiguredSpeechProviderId', 'readTtsPrefs',
      'resolveTtsPersonaFromPrefs', 'resolveTtsRuntimeConfig']),
  },
  'src/tts/voice-models.ts': uninvoked(['resolvePrimaryVoiceProviderCandidate', 'resolveSupportedVoiceModelRefs',
    'resolveVoiceModelRefs', 'resolveVoiceProviderCandidates', 'voiceProviderSupportsModel']),
};
const globalBoundaries = { fetch: 'uninvoked throwing global binding passed through to synthetic postJsonRequest; no fetch executes' };

function synthesisInputs() {
  const rows = [
    { id: 'default-file' },
    { id: 'configured', config: { baseUrl: 'https://openrouter.ai/v1/', modelId: 'google/gemini-3.1-flash-tts-preview',
      voiceId: 'Kore', speed: 1.1, responseFormat: ' MP3 ', provider: { options: { openai: { instructions: 'Speak warmly.' } } } } },
    { id: 'custom-prefix', config: { baseUrl: 'https://speech.example/router/v7///', model: 'mistralai/voxtral-mini-tts-2603',
      voice: 'ordinary-voice', speed: 0.9, provider: { order: ['ordinary-route'] } } },
    { id: 'overrides', config: { modelId: 'elevenlabs/eleven-turbo-v2', voiceId: 'configured-voice', speed: 0.8 },
      overrides: { model: ' google/gemini-3.1-flash-tts-preview ', voice: ' Kore ', speed: 1.2 } },
    { id: 'id-alias-overrides', overrides: { modelId: ' mistralai/voxtral-mini-tts-2603 ', voiceId: ' ordinary-id ', speed: 1.1 } },
    { id: 'override-key-precedence', overrides: { model: ' google/gemini-3.1-flash-tts-preview ', modelId: 'ignored-model',
      voice: ' Kore ', voiceId: 'ignored-voice' } },
    { id: 'blank-overrides', config: { model: 'elevenlabs/eleven-turbo-v2', voice: 'configured-voice', speed: 0.9 },
      overrides: { model: ' ', voice: ' ' } },
    { id: 'speaker-precedence', config: { speakerVoice: ' speaker-v ', speakerVoiceId: 'unused-id', voice: 'unused-voice', voiceId: 'unused' } },
    { id: 'speaker-id', config: { speakerVoiceId: ' speaker-id ', voice: 'unused-voice' } },
    { id: 'unicode-trim', config: { modelId: '\u00a0\ufeff hexgrad/kokoro-82m \ufeff\u00a0',
      voiceId: '\u00a0\ufeff af_alloy \ufeff\u00a0', speed: 1.25 } },
    { id: 'pcm-file', config: { responseFormat: ' PCM ', provider: { order: [] } } },
    { id: 'default-note', target: 'voice-note' },
    { id: 'pcm-note', target: 'voice-note', config: { responseFormat: 'pcm' } },
    { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
    { id: 'legacy-config', legacy: { modelId: 'elevenlabs/eleven-turbo-v2', voiceId: 'legacy-voice' } },
    { id: 'nested-precedence', config: { model: 'google/gemini-3.1-flash-tts-preview', voice: 'nested-voice' },
      legacy: { model: 'elevenlabs/eleven-turbo-v2', voice: 'legacy-voice' } },
  ];
  return rows.map(({ id, config, legacy, overrides, target = 'audio-file', text = 'Plain speech fixture.' }) => ({
    id, input: { text, target, timeoutMs: 12345, cfg: {}, rawConfig: {
      ...(id === 'legacy-config' ? {} : { providers: { openrouter: { apiKey: fixtureKey, ...config } } }),
      ...(legacy ? { openrouter: { apiKey: fixtureKey, ...legacy } } : {}),
    }, ...(overrides ? { providerOverrides: overrides } : {}) }, response: plain(responseFixture),
  }));
}

function talkConfigInputs() {
  return [
    { id: 'talk-defaults', input: { baseTtsConfig: { providers: { openrouter: { apiKey: fixtureKey } } }, talkProviderConfig: {} } },
    { id: 'talk-configured', input: { baseTtsConfig: { providers: { openrouter: { apiKey: fixtureKey,
      model: 'hexgrad/kokoro-82m', voice: 'af_alloy', speed: 0.9, provider: { order: ['ordinary-route'] } } } },
    talkProviderConfig: { apiKey: 'fixture-talk-speech', baseUrl: 'https://talk.example/router/v2///',
      modelId: 'mistralai/voxtral-mini-tts-2603', voiceId: 'talk-voice', speed: 1.2, responseFormat: ' PCM ', provider: { ignored: true } } } },
    { id: 'talk-speaker', input: { baseTtsConfig: { providers: { openrouter: { apiKey: fixtureKey,
      model: 'elevenlabs/eleven-turbo-v2', voice: 'baseline-voice' } } },
    talkProviderConfig: { baseUrl: 'https://openrouter.ai/v1/', speakerVoice: ' talk-speaker ',
      speakerVoiceId: 'unused', voice: 'unused', voiceId: 'unused', responseFormat: ' MP3 ' } } },
  ];
}

function talkOverrideInputs() {
  return [
    { id: 'talk-id-overrides', input: { params: { voiceId: ' vf ', voice: 'ignored', modelId: ' model-id ', model: 'ignored', speed: 1.25 } } },
    { id: 'talk-alias-overrides', input: { params: { voice: ' v ', model: ' m ', speed: 0.9 } } },
    { id: 'talk-blank-overrides', input: { params: { voice: ' ', model: ' ' } } },
    { id: 'talk-blank-id-overrides', input: { params: { voiceId: ' ', voice: 'ignored-fallback',
      modelId: ' ', model: 'ignored-fallback', speed: 1.1 } } },
  ];
}

function timeoutInputs() {
  return [
    { id: 'provider-default', input: { config: { timeoutMs: 30000, timeoutMsSource: 'default' } } },
    { id: 'configured-default', input: { config: { timeoutMs: 45000, timeoutMsSource: 'config' } } },
    { id: 'configured-standard', input: { config: { timeoutMs: 30000, timeoutMsSource: 'config' } } },
    { id: 'per-call', input: { config: { timeoutMs: 30000, timeoutMsSource: 'default' }, timeoutMs: 75000 } },
  ];
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENROUTER_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENROUTER_SPEECH_PIN])
    .split('\0').filter(Boolean).map(entry => {
      const [header, path] = entry.split('\t');
      const [mode, type, blob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
      const file = join(root, path);
      const symlink = lstatSync(file).isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      assert.ok(realpathSync(file).startsWith(root + sep));
      const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
      return { path, gitBlob: blob, sha256: hash(bytes) };
    });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: OPENROUTER_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${OPENROUTER_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('OpenRouter capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class OpenRouterSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetchBinding = () => { throw Error('Uninvoked fixture global fetch binding called'); };
    this.context = vm.createContext({ Buffer, URL, Headers, fetch: this.fetchBinding, process: { env: {} } }, {
      codeGeneration: { strings: false, wasm: false },
    });
    this.opaqueResponse = { status: responseFixture.status, ok: true, headers: new Headers(responseFixture.headers) };
  }

  platformModule(identifier) {
    const called = (name, value, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return value;
    };
    const bindings = {
      normalizeResolvedSecretInputString: ({ value, path }) => {
        assert.ok(value === undefined || value === fixtureKey || value === 'fixture-talk-speech');
        return called('normalizeResolvedSecretInputString', value, { path, ...(value === undefined ? {} : { value }) });
      },
      resolveProviderHttpRequestConfig: params => called('resolveProviderHttpRequestConfig', {
        headers: new Headers(params.defaultHeaders), allowPrivateNetwork: params.allowPrivateNetwork,
        dispatcherPolicy: params.dispatcherPolicy,
      }, { input: plain(params) }),
      postJsonRequest: async params => {
        called('postJsonRequest');
        assert.equal(params.fetchFn, this.fetchBinding);
        this.requests.push(plain({ url: params.url, headers: Object.fromEntries(params.headers.entries()),
          body: params.body, timeoutMs: params.timeoutMs, fetchFnProvided: typeof params.fetchFn === 'function',
          allowPrivateNetwork: params.allowPrivateNetwork, dispatcherPolicy: params.dispatcherPolicy }));
        return { response: this.opaqueResponse,
          release: async () => { this.releaseCount += 1; called('release'); } };
      },
      assertOkOrThrowHttpError: async (response, label) => {
        assert.equal(response, this.opaqueResponse);
        called('assertOkOrThrowHttpError', undefined, { status: response.status, label });
      },
      readProviderBinaryResponse: async (response, label, kind, options) => {
        assert.equal(response, this.opaqueResponse);
        called('readProviderBinaryResponse', undefined, { status: response.status, label, kind,
          optionsProvided: options !== undefined, maxBytesProvided: options?.maxBytes !== undefined,
          overflowCallbackProvided: typeof options?.onOverflow === 'function' });
        return Buffer.from(audioBytes);
      },
    };
    const names = Object.keys(boundaries[identifier]);
    return new vm.SyntheticModule(names, function () {
      for (const name of names) this.setExport(name, Object.hasOwn(bindings, name) ? bindings[name]
        : name === 'DEFAULT_TTS_TIMEOUT_MS' ? undefined
          : () => { throw Error(`Uninvoked fixture binding called: ${identifier}:${name}`); });
    }, { context: this.context, identifier });
  }

  module(identifier) {
    if (this.modules.has(identifier)) return this.modules.get(identifier);
    let module;
    if (Object.hasOwn(boundaries, identifier)) module = this.platformModule(identifier);
    else {
      const executable = this.executables.get(identifier) ?? sdkFacades[identifier];
      assert.equal(typeof executable, 'string', `declared complete source or export facade: ${identifier}`);
      module = new vm.SourceTextModule(executable, { context: this.context, identifier,
        importModuleDynamically: async (specifier, importer) => {
          const dependency = this.resolveImport(specifier, importer, this.dynamicImports);
          if (dependency.status === 'unlinked') await dependency.link((name, from) => this.resolveImport(name, from, this.staticImports));
          if (dependency.status === 'linked') await dependency.evaluate({ timeout: executionTimeoutMs });
          return dependency;
        },
      });
    }
    this.modules.set(identifier, module);
    return module;
  }

  resolveImport(specifier, importer, provenance) {
    const resolved = specifier.startsWith('.')
      ? posix.normalize(posix.join(dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts') : specifier;
    assert.ok(this.executables.has(resolved) || Object.hasOwn(sdkFacades, resolved) || Object.hasOwn(boundaries, resolved),
      `declared source import: ${importer.identifier} -> ${specifier}`);
    provenance.push({ importer: importer.identifier, specifier, resolved });
    return this.module(resolved);
  }

  async run() {
    for (const path of [OPENROUTER_SPEECH_SOURCE, timeoutSource]) {
      const module = this.module(path);
      await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
      await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    }
    this.context.speechSource = this.modules.get(OPENROUTER_SPEECH_SOURCE).namespace;
    this.context.timeoutSource = this.modules.get(timeoutSource).namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildOpenRouterSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      if (observationKind === 'talkConfig') return { result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverride') return { result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'timeout') {
        const request = { ...speechInput, provider };
        const input = JSON.parse(JSON.stringify(request));
        const result = timeoutSource.resolveSpeechProviderTimeoutMs(request);
        return { result, input, inputAfter: JSON.parse(JSON.stringify(request)) };
      }
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig, cfg: speechInput.cfg, timeoutMs: speechInput.timeoutMs });
      const listVoices = await provider.listVoices();
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: speechInput.cfg };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      const result = await provider.synthesize(request);
      return { resolvedConfig, result, metadata, listVoices, synthesisRequest,
        synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    for (const path of sourcePaths) assert.equal(this.modules.get(path)?.status, 'evaluated', path);
    let observation;
    if (this.kind === 'synthesis') {
      assert.equal(this.requests.length, 1);
      assert.equal(this.releaseCount, 1);
      assert.deepEqual(execution.result.audioBuffer, audioBytes);
      const { audioBuffer, ...resultMetadata } = execution.result;
      observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter: plain(this.context.speechInput),
        resolvedConfig: plain(execution.resolvedConfig), providerMetadata: plain(execution.metadata), listVoices: plain(execution.listVoices),
        synthesisRequest: plain(execution.synthesisRequest), synthesisRequestAfter: plain(execution.synthesisRequestAfter),
        request: this.requests[0], response: plain(this.recipe.response),
        result: { audioBase64: audioBuffer.toString('base64'), ...plain(resultMetadata) },
        releaseCount: this.releaseCount, platformCalls: this.calls };
    } else {
      assert.equal(this.requests.length, 0);
      assert.equal(this.releaseCount, 0);
      observation = { id: this.recipe.id, input: plain(execution.input ?? this.recipe.input),
        inputAfter: plain(execution.inputAfter ?? this.context.speechInput), result: plain(execution.result), platformCalls: this.calls };
    }
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureOpenRouterSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${OPENROUTER_SPEECH_PIN}:${path}`], {
      timeout: 30_000, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      git(root, ['rev-parse', `${OPENROUTER_SPEECH_PIN}:${path}`]), path);
    return bytes;
  };
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${OPENROUTER_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const manifestBytes = readOriginal(manifestPath);
  const licenseBytes = readOriginal(licensePath);
  const groups = {};
  for (const [kind, recipes] of Object.entries({ synthesis: synthesisInputs(), talkConfig: talkConfigInputs(),
    talkOverride: talkOverrideInputs(), timeout: timeoutInputs() })) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new OpenRouterSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluatedSourcePaths = unique(runs.flatMap(run => run.evaluatedSourcePaths));
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: OPENROUTER_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-openrouter-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [{ path: manifestPath, gitBlob: git(root, ['rev-parse', `${OPENROUTER_SPEECH_PIN}:${manifestPath}`]),
      sourceSha256: hash(manifestBytes), usage: 'complete original plugin manifest provenance; plugin registration unexecuted' },
    { path: licensePath, gitBlob: git(root, ['rev-parse', `${OPENROUTER_SPEECH_PIN}:${licensePath}`]),
      sourceSha256: hash(licenseBytes), usage: 'complete original source license provenance' }],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries: [...Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
      { module: 'globalThis', originalSourceExecuted: false, exports: globalBoundaries }],
    environmentFixture: { env: {}, cfg: {} },
    hostAdaptation: { config: 'Original raw nested/legacy config and overrides are oracle inputs; host implementation is unqualified.',
      response: 'Eight opaque bytes with MP3/PCM source metadata; no audio decoding, codec validation, transcoding or native publication.',
      headers: 'Original header and policy arguments are provenance only; authentication and transport/security parity are untested.',
      talk: 'Ordinary provider resolveTalkConfig/resolveTalkOverrides callbacks only; actual Talk/channel pipeline unexecuted.' },
    counts: { observations: groups.synthesis.length, synthesisCallbacks: groups.synthesis.length, telephonyCallbacks: 0,
      httpRequests: groups.synthesis.length, releases: groups.synthesis.length, listVoicesCallbacks: groups.synthesis.length,
      talkConfigObservations: groups.talkConfig.length, talkOverrideObservations: groups.talkOverride.length,
      timeoutObservations: groups.timeout.length, totalObservations: runs.length, wholeModules: evaluatedSourcePaths.length,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; complete source modules, plugin manifest and LICENSE additionally checked against pinned Git bytes and hashes.',
      'Whole-module execution means evaluation, not all exports; original factory, resolveConfig, listVoices, synthesize, resolveTalkConfig and resolveTalkOverrides execute.',
      'Pure SDK facades contain export wiring only; actual normalization, config-path helper and directive-parser construction execute. Directive dispatch and isConfigured are unexecuted.',
      'Original complete timeout resolver receives the actual provider object; resolvePositiveTimeoutMs and original clampTimerTimeoutMs execute for ordinary positive default/config/per-call inputs.',
      'Unrelated timeout-resolver registry/settings/speaker/voice helpers are explicit uninvoked throwing bindings; DEFAULT_TTS_TIMEOUT_MS is undefined and its fallback branch is unused.',
      'Fresh per-vector VM process.env={} and cfg={}; only explicit fixture keys cross a synthetic secret boundary. Production secrets, ambient credentials and plugin loading are unexecuted.',
      'Original synthesis constructs URL, Headers inputs, JSON body and timeout; synthetic provider HTTP returns an opaque successful response and counted release. Global fetch is a passed-through uninvoked throwing binding.',
      'Provider HTTP configuration, status handling and binary reader originals are unexecuted; policy flags, fetchFn, supplied cap and callback presence are provenance only, with no security or budget claim.',
      '12345 ms is the synthesis request timeout; the separate original timeout resolver observes provider/config/per-call choices. 2000 ms bounds VM/capture execution only.',
      'Talk configuration callbacks preserve ordinary inputs/results; actual Talk/channel pipeline and telephony are unexecuted. Voice-note target does not establish native publication.',
      'No security/permission/authentication/TLS, negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
    observations: groups.synthesis.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverride.map(run => run.observation),
    timeoutObservations: groups.timeout.map(run => run.observation) };
}

export async function writeOpenRouterSpeechCapture(root, output) {
  const capture = await captureOpenRouterSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c';
  let output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-openrouter-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeOpenRouterSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureOpenRouterSpeech(root), null, 2) + '\n');
}
