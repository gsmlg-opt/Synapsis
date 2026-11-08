// Ordinary buffered ElevenLabs synthesis from complete pinned source modules.
// Successful synthetic HTTP only; all platform substitutions are declared below.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const ELEVENLABS_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const ELEVENLABS_SPEECH_SOURCE = 'extensions/elevenlabs/speech-provider-factory.ts';
const sourcePaths = [ELEVENLABS_SPEECH_SOURCE, 'extensions/elevenlabs/shared.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'src/utils/boolean.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/record-coerce.ts',
  'packages/media-core/src/constants.ts'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const audioBytes = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]);
const executionTimeoutMs = 2000;
const fixtureKey = 'fixture-elevenlabs-speech';

// Wiring only: the functions and constants come from complete original modules.
const sdkFacades = {
  'openclaw/plugin-sdk/number-runtime':
    'export { parseStrictFiniteNumber, parseStrictInteger } from "packages/normalization-core/src/number-coercion.ts";\n',
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asFiniteNumberInRange, asSafeIntegerInRange } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString, normalizeLowercaseStringOrEmpty } from "packages/normalization-core/src/string-coerce.ts";\n' +
    'export { asBoolean, parseBooleanValue } from "src/utils/boolean.ts";\n',
  'openclaw/plugin-sdk/speech-provider':
    'export { createSpeechDirectiveParser } from "src/tts/directive-parser.ts";\n' +
    'export { normalizeApplyTextNormalization, normalizeLanguageCode, normalizeSeed, requireInRange, resolveSpeechProviderApiKey } from "src/tts/tts-provider-helpers.ts";\n' +
    'export { MAX_AUDIO_BYTES } from "packages/media-core/src/constants.ts";\n',
  '@openclaw/normalization-core/string-coerce':
    'export { normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
};

const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'returns only the explicit fixture string; production secret resolution unexecuted',
  },
  'extensions/elevenlabs/config-api.ts': {
    resolveElevenLabsApiKeyWithProfileFallback: 'counted undefined fixture; production environment/profile discovery unexecuted, including its eager call with an explicit key',
  },
  'node:fs': { rmSync: 'uninvoked binding for the complete helper module; no cleanup or filesystem callback executes' },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'asserts synthetic successful Response status; production error processing unexecuted',
    readProviderBinaryResponse: 'returns exact fixture Response bytes as Buffer; production MIME validation and default 16 MiB bounded reader unexecuted',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'records complete fixture request URL, headers, body, timeout and audit context; returns synthetic successful Response and counted release; no sockets',
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'counted undefined fixture; production network policy unexecuted',
  },
};

function inputs() {
  const rows = [
    { id: 'default-file' }, { id: 'default-note', target: 'voice-note' },
    { id: 'file-opus', overrides: { outputFormat: 'opus_48000_64' } },
    { id: 'note-mp3', target: 'voice-note', overrides: { outputFormat: 'mp3_22050_32' } },
    { id: 'file-wav', overrides: { outputFormat: 'wav_44100' } },
    { id: 'file-pcm', overrides: { outputFormat: 'pcm_22050' } },
    { id: 'file-ulaw', overrides: { outputFormat: 'ulaw_8000' } },
    { id: 'file-alaw', overrides: { outputFormat: 'alaw_8000' } },
    { id: 'other-format', overrides: { outputFormat: 'flac_44100' } },
    { id: 'format-spelling', overrides: { outputFormat: '  OpUs_48000_64  ' } },
    { id: 'configured', config: { baseUrl: ' https://speech.example.test/prefix/// ',
      voiceId: ' ABCDEFGHIJ0123456789 ', modelId: ' eleven_v3 ', seed: 17,
      applyTextNormalization: ' ON ', languageCode: ' EN ',
      voiceSettings: { stability: 0.3, similarityBoost: 0.6, style: 0.4, useSpeakerBoost: false, speed: 1.2 } } },
    { id: 'settings-lower', config: { voiceSettings: { stability: 0, similarityBoost: 0, style: 0, useSpeakerBoost: false, speed: 0.5 } } },
    { id: 'settings-upper', config: { voiceSettings: { stability: 1, similarityBoost: 1, style: 1, useSpeakerBoost: true, speed: 2 } } },
    { id: 'settings-partial', config: { voiceSettings: { stability: 0.2, speed: 1.3 } } },
    { id: 'seed-zero', config: { seed: 0 } },
    { id: 'seed-upper', config: { seed: 4294967295 } },
    { id: 'config-alias-turbo25', config: { modelId: ' eleven_turbo_v2_5 ' } },
    { id: 'config-alias-turbo2', config: { modelId: 'eleven_turbo_v2' } },
    { id: 'override-alias-turbo25', overrides: { modelId: ' eleven_turbo_v2_5 ' } },
    { id: 'override-alias-turbo2', overrides: { modelId: 'eleven_turbo_v2' } },
    { id: 'custom-model', config: { modelId: ' custom-speech-model ' } },
    { id: 'normalization-auto', config: { applyTextNormalization: ' AUTO ', languageCode: ' DE ' } },
    { id: 'normalization-on', config: { applyTextNormalization: 'on', languageCode: 'fr' } },
    { id: 'normalization-off', config: { applyTextNormalization: ' Off ', languageCode: ' ZH ' } },
    { id: 'overrides', config: { voiceId: 'ABCDEFGHIJ0123456789', modelId: 'eleven_v3', seed: 17,
      applyTextNormalization: 'on', languageCode: 'de', voiceSettings: { stability: 0.2, speed: 1.2 } },
      overrides: { voiceId: ' 0123456789ABCDEFGHIJ ', modelId: ' eleven_flash_v2_5 ', seed: 0,
        applyTextNormalization: ' OFF ', languageCode: ' EN ', latencyTier: 4, outputFormat: 'wav_44100',
        voiceSettings: { similarityBoost: 0, style: 1, useSpeakerBoost: false, speed: 0.5 } } },
    { id: 'override-settings-upper', overrides: { seed: 4294967295,
      voiceSettings: { stability: 1, similarityBoost: 1, style: 1, useSpeakerBoost: true, speed: 2 } } },
    { id: 'latency-zero', overrides: { latencyTier: 0 } },
    { id: 'latency-upper', overrides: { latencyTier: 4 } },
    { id: 'v3-latency', config: { modelId: 'eleven_v3' }, overrides: { latencyTier: 4 } },
    { id: 'v3-override-latency', overrides: { modelId: ' ELEVEN_V3 ', latencyTier: 0 } },
    { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  ];
  return rows.map(({ id, target = 'audio-file', config, overrides, text = 'Plain speech fixture.' }) => ({
    id, input: { text, target, timeoutMs: 12345,
      rawConfig: { providers: { elevenlabs: { apiKey: fixtureKey, ...config } } },
      ...(overrides ? { providerOverrides: overrides } : {}) },
  }));
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), ELEVENLABS_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', ELEVENLABS_SPEECH_PIN])
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
  return { verified: true, commit: ELEVENLABS_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${ELEVENLABS_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('ElevenLabs capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class ElevenLabsCapture {
  constructor(executables, recipe) {
    this.executables = executables;
    this.recipe = recipe;
    this.modules = new Map();
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.context = vm.createContext({ Buffer, URL, process: { env: {} } }, {
      codeGeneration: { strings: false, wasm: false },
    });
  }

  platformModule(identifier) {
    const called = (name, value, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return value;
    };
    const bindings = {
      normalizeResolvedSecretInputString: ({ value }) => {
        assert.equal(value, fixtureKey);
        return called('normalizeResolvedSecretInputString', value);
      },
      resolveElevenLabsApiKeyWithProfileFallback: () => called('resolveElevenLabsApiKeyWithProfileFallback', undefined),
      rmSync: () => { throw Error('Unexercised cleanup binding invoked'); },
      assertOkOrThrowProviderError: async response => {
        called('assertOkOrThrowProviderError');
        assert.equal(response.ok, true);
      },
      readProviderBinaryResponse: async (response, label, kind, options) => {
        called('readProviderBinaryResponse', undefined, { label, kind, optionsProvided: options !== undefined });
        assert.equal(kind, 'audio');
        assert.equal(options, undefined);
        return Buffer.from(await response.arrayBuffer());
      },
      ssrfPolicyFromHttpBaseUrlAllowedHostname: () => called('ssrfPolicyFromHttpBaseUrlAllowedHostname', undefined),
      fetchWithSsrFGuard: async params => {
        called('fetchWithSsrFGuard');
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: plain(params.init.headers),
          body: JSON.parse(params.init.body), bodyText: params.init.body,
          timeoutMs: params.timeoutMs, auditContext: params.auditContext });
        return { response: new Response(audioBytes, { status: 200, headers: { 'Content-Type': 'application/octet-stream' } }),
          release: async () => { this.releaseCount += 1; called('release'); } };
      },
    };
    const names = Object.keys(boundaries[identifier]);
    return new vm.SyntheticModule(names, function () {
      for (const name of names) this.setExport(name, bindings[name]);
    }, { context: this.context, identifier });
  }

  module(identifier) {
    if (this.modules.has(identifier)) return this.modules.get(identifier);
    let module;
    if (Object.hasOwn(boundaries, identifier)) module = this.platformModule(identifier);
    else {
      const executable = this.executables.get(identifier) ?? sdkFacades[identifier];
      assert.equal(typeof executable, 'string', `declared source or facade: ${identifier}`);
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
    const module = this.module(ELEVENLABS_SPEECH_SOURCE);
    await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = module.namespace;
    this.context.speechInput = plain(this.recipe.input);
    const { resolvedConfig, result, metadata } = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildElevenLabsSpeechProvider({ formatErrorMessage: error => String(error) });
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig, cfg: {}, timeoutMs: speechInput.timeoutMs });
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: {} };
      const result = await provider.synthesize(request);
      return { resolvedConfig, result, metadata: { id: provider.id, label: provider.label,
        autoSelectOrder: provider.autoSelectOrder, defaultModel: provider.defaultModel, models: provider.models } };
    })()`, this.context, { timeout: executionTimeoutMs }));
    assert.equal(this.requests.length, 1);
    assert.equal(this.releaseCount, 1);
    assert.deepEqual(result.audioBuffer, audioBytes);
    for (const path of sourcePaths) assert.equal(this.modules.get(path)?.status, 'evaluated', path);
    const { audioBuffer, ...resultMetadata } = result;
    return { observation: { id: this.recipe.id, input: plain(this.recipe.input), inputAfter: plain(this.context.speechInput),
      resolvedConfig: plain(resolvedConfig), providerMetadata: plain(metadata), request: this.requests[0],
      result: { audioBase64: audioBuffer.toString('base64'), ...plain(resultMetadata) },
      releaseCount: this.releaseCount, platformCalls: this.calls },
    staticImports: this.staticImports, dynamicImports: this.dynamicImports };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function runElevenLabsSpeechCapture(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['show', `${ELEVENLABS_SPEECH_PIN}:${path}`], { cwd: root, timeout: 30_000 });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${ELEVENLABS_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const runs = [];
  for (const recipe of inputs()) runs.push(await new ElevenLabsCapture(executables, recipe).run());
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: ELEVENLABS_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-elevenlabs-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    platformBoundaries: Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    counts: { observations: runs.length, synthesisCallbacks: runs.length, httpRequests: runs.length,
      releases: runs.length, wholeModules: sourcePaths.length, trackedFilesBefore: before.verifiedTrackedFiles,
      trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; each of ten complete modules also compared directly with its pinned Git object before TypeScript erasure.',
      'Whole-module execution means module evaluation, not every export or callback; only factory construction, nested raw resolveConfig and successful ordinary synthesize run.',
      'SDK facades contain export wiring only; actual number/string/record/boolean normalization, directive-parser construction, output planning and request serialization execute from complete originals.',
      'Fresh per-vector VM process.env={} and cfg={}; explicit fixture secret and eagerly invoked undefined profile-discovery boundary; no live config, environment, profile or provider connection.',
      'Successful synthetic HTTP returns eight fixed byte tokens and counts release; no real audio decoding, MIME validation, production resource lifetime or transport behavior is established.',
      'Production binary reader defaults to 16 MiB but remains a platform fixture here; no per-request maxBytes options are passed by this provider, and the bounded reader itself is unexecuted.',
      '12345 ms is the forwarded request timeout; synchronous VM and asynchronous capture deadline are 2000 ms. Production request deadlines and outer runtime default limits are unexecuted.',
      'No streamSynthesize, synthesizeTelephony, listVoices, directive parsing, Talk resolution, transcription, plugin registration, readiness or full-runtime callback is executed.',
      'Format-family metadata and opaque fixture bytes are source observations, not codec or native publication claims. Native scope supports MP3/Opus/WAV; PCM/ulaw/alaw/other formats are source-only evidence.',
      'Result contains outputFormat/fileExtension/voiceCompatible and no MIME or sample rate; the source uses family metadata without decoding fixture bytes.',
    ],
    observations: runs.map(run => run.observation) };
}

export async function writeElevenLabsSpeechCapture(root, output) {
  const capture = await runElevenLabsSpeechCapture(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', output] = process.argv.slice(2);
  if (output) await writeElevenLabsSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await runElevenLabsSpeechCapture(root), null, 2) + '\n');
}
