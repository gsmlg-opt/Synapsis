// Complete pinned OpenAI speech provider and normalization sources, isolated from
// platform services. Successful synthetic HTTP only; no provider connection.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, join, posix, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const OPENAI_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const OPENAI_SPEECH_SOURCE = 'extensions/openai/speech-provider.ts';
const sources = [OPENAI_SPEECH_SOURCE, 'extensions/openai/realtime-provider-shared.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const audioBytes = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]);
const maxAudioBytes = 16 * 1024 * 1024;
const executionTimeoutMs = 2000;

// These facades contain export wiring only; every normalization implementation
// comes from a complete byte-verified original source module.
const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeLowercaseStringOrEmpty, normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  'openclaw/plugin-sdk/number-runtime':
    'export { resolveExpiresAtMsFromEpochSeconds } from "packages/normalization-core/src/number-coercion.ts";\n',
};

function inputs() {
  const providerConfig = { apiKey: 'fixture-openai-speech' };
  const groq = { baseUrl: 'https://api.groq.com/openai/v1', model: 'playai-tts', voice: 'Fritz-PlayAI' };
  const rows = [
    { id: 'default-file', target: 'audio-file' },
    { id: 'default-note', target: 'voice-note' },
    { id: 'file-opus', target: 'audio-file', config: { responseFormat: 'opus' } },
    { id: 'note-wav', target: 'voice-note', config: { responseFormat: ' WAV ' } },
    { id: 'file-wav', target: 'audio-file', config: { responseFormat: 'wav' } },
    { id: 'groq-file', target: 'audio-file', config: groq },
    { id: 'groq-note', target: 'voice-note', config: groq },
    { id: 'configured-openai', target: 'audio-file', config: {
      model: ' gpt-4o-mini-tts-2025-12-15 ', voice: ' nova ', speed: 1.25, instructions: ' Speak evenly. ',
    } },
    { id: 'legacy-model', target: 'audio-file', config: { model: 'tts-1', instructions: ' Speak evenly. ' } },
    { id: 'custom-voice-model', target: 'audio-file', config: {
      baseUrl: ' https://speech.example.test/v1/// ', model: 'local-voice-model', voice: 'speaker-7',
      speed: 4.5, instructions: ' Speak warmly. ',
    } },
    { id: 'provider-overrides', target: 'audio-file', config: { model: 'tts-1', voice: 'alloy', speed: 1.1 },
      providerOverrides: { model: 'tts-1-hd', voice: 'echo', speed: 1.5 } },
    { id: 'extra-body-fields', target: 'audio-file', config: { extraBody: { language: 'en', seed: 7 } } },
    { id: 'extra-body-final-wins', target: 'audio-file', config: {
      speed: 1.1, extra_body: { model: 'tts-1-hd', input: 'Replacement plain speech.', speed: 0.8 },
    } },
    { id: 'telephony', target: 'telephony', config: { responseFormat: 'wav' } },
  ];
  return rows.map(({ id, target, config, providerOverrides }) => ({ id, input: {
    text: 'Plain speech fixture.', target, timeoutMs: 12345,
    providerConfig: { ...providerConfig, ...config },
    ...(providerOverrides ? { providerOverrides } : {}),
  } }));
}

const boundaryDescriptions = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'returns only the explicit synthetic fixture string; production secret resolution unexecuted',
  },
  'openclaw/plugin-sdk/speech-provider': {
    createSpeechDirectiveParser: 'records construction and returns an unused callback; directive parsing unexecuted',
    parseSpeechDirectiveNumberOverride: 'unused directive numeric parser; throws if called',
  },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'explicit 16 MiB audio limit fixture; production configuration resolver unexecuted',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'asserts the synthetic successful Response is OK; production error handling unexecuted',
    readProviderBinaryResponse: 'records maxBytes and returns exact synthetic Response bytes as Buffer; production bounded reader unexecuted',
    resolveProviderRequestHeaders: 'returns supplied fixture headers; values are not recorded; production header resolution unexecuted',
  },
  'openclaw/plugin-sdk/proxy-capture': {
    isDebugProxyGlobalFetchPatchInstalled: 'fixed false fixture; no global proxy patch',
    captureHttpExchangeAsync: 'counted resolved no-op; no exchange persistence or network',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'records URL, method, parsed JSON body and timeout; returns synthetic successful HTTP Response and counted release; no sockets',
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'counted undefined fixture; production network policy unexecuted',
  },
  'openclaw/plugin-sdk/media-runtime': {
    isVoiceMessageCompatibleAudio: 'explicit extension fixture accepts .opus only for the exercised formats; original media detection unexecuted',
  },
};

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

class SpeechCapture {
  constructor(executables, recipe) {
    this.executables = executables;
    this.recipe = recipe;
    this.modules = new Map();
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.staticImports = [];
    this.dynamicImports = [];
    // No host process, environment, filesystem, fetch or configuration is exposed.
    this.context = vm.createContext({ Buffer, URL, process: { env: {} } }, {
      codeGeneration: { strings: false, wasm: false },
    });
  }

  platformModule(specifier) {
    const called = (name, value, detail = {}) => {
      this.calls.push({ module: specifier, export: name, ...detail });
      return value;
    };
    const unused = () => { throw Error('Unused speech platform callback invoked'); };
    const bindings = {
      normalizeResolvedSecretInputString: ({ value }) => {
        assert.equal(value, 'fixture-openai-speech');
        return called('normalizeResolvedSecretInputString', value);
      },
      createSpeechDirectiveParser: () => called('createSpeechDirectiveParser', unused),
      parseSpeechDirectiveNumberOverride: unused,
      resolveGeneratedMediaMaxBytes: (cfg, kind) => {
        assert.deepEqual(plain(cfg), {});
        assert.equal(kind, 'audio');
        return called('resolveGeneratedMediaMaxBytes', maxAudioBytes);
      },
      assertOkOrThrowProviderError: async response => {
        called('assertOkOrThrowProviderError');
        assert.equal(response.ok, true);
      },
      readProviderBinaryResponse: async (response, _label, kind, options) => {
        called('readProviderBinaryResponse', undefined, { maxBytes: options.maxBytes });
        assert.equal(kind, 'audio');
        assert.equal(options.maxBytes, maxAudioBytes);
        return Buffer.from(await response.arrayBuffer());
      },
      resolveProviderRequestHeaders: ({ defaultHeaders }) => called('resolveProviderRequestHeaders', defaultHeaders),
      isDebugProxyGlobalFetchPatchInstalled: () => called('isDebugProxyGlobalFetchPatchInstalled', false),
      captureHttpExchangeAsync: async () => { called('captureHttpExchangeAsync'); },
      ssrfPolicyFromHttpBaseUrlAllowedHostname: () => called('ssrfPolicyFromHttpBaseUrlAllowedHostname', undefined),
      fetchWithSsrFGuard: async params => {
        called('fetchWithSsrFGuard');
        this.requests.push({ url: params.url, method: params.init.method,
          body: JSON.parse(params.init.body), timeoutMs: params.timeoutMs });
        return { response: new Response(audioBytes, { status: 200, headers: { 'Content-Type': 'application/octet-stream' } }),
          release: async () => { this.releaseCount += 1; called('release'); } };
      },
      isVoiceMessageCompatibleAudio: ({ fileName }) => called('isVoiceMessageCompatibleAudio', fileName.endsWith('.opus')),
    };
    const names = Object.keys(boundaryDescriptions[specifier]);
    return new vm.SyntheticModule(names, function () {
      for (const name of names) this.setExport(name, bindings[name]);
    }, { context: this.context, identifier: specifier });
  }

  module(identifier) {
    if (this.modules.has(identifier)) return this.modules.get(identifier);
    let module;
    if (Object.hasOwn(boundaryDescriptions, identifier)) {
      module = this.platformModule(identifier);
    } else {
      const executable = this.executables.get(identifier) ?? sdkFacades[identifier];
      assert.equal(typeof executable, 'string', `declared source or SDK facade: ${identifier}`);
      module = new vm.SourceTextModule(executable, {
        context: this.context, identifier,
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
      ? posix.normalize(posix.join(dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts')
      : specifier;
    assert.ok(this.executables.has(resolved) || Object.hasOwn(sdkFacades, resolved) || Object.hasOwn(boundaryDescriptions, resolved),
      `declared speech import: ${importer.identifier} -> ${specifier}`);
    provenance.push({ importer: importer.identifier, specifier, resolved });
    return this.module(resolved);
  }

  async run() {
    const module = this.module(OPENAI_SPEECH_SOURCE);
    await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = module.namespace;
    this.context.speechInput = plain(this.recipe.input);
    const resultPromise = vm.runInContext(`(async () => {
      const provider = speechSource.buildOpenAISpeechProvider();
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.providerConfig, cfg: {}, timeoutMs: speechInput.timeoutMs });
      const request = { ...speechInput, providerConfig: resolvedConfig, cfg: {} };
      const result = await (speechInput.target === 'telephony'
        ? provider.synthesizeTelephony(request) : provider.synthesize(request));
      return { resolvedConfig, result };
    })()`, this.context, { timeout: executionTimeoutMs });
    const { resolvedConfig, result } = await withDeadline(resultPromise);
    assert.equal(this.requests.length, 1);
    assert.equal(this.releaseCount, 1);
    const { audioBuffer, ...metadata } = result;
    assert.deepEqual(audioBuffer, audioBytes);
    return { observation: { id: this.recipe.id, input: plain(this.recipe.input),
      resolvedConfig: plain(resolvedConfig), request: this.requests[0],
      result: { audioBase64: audioBuffer.toString('base64'), ...plain(metadata) },
      releaseCount: this.releaseCount, platformCalls: this.calls },
    staticImports: this.staticImports, dynamicImports: this.dynamicImports };
  }
}

function uniqueImports(rows) {
  return [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];
}

export async function runOpenAISpeechCapture(root = '/tmp/openclaw-488631c') {
  assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), OPENAI_SPEECH_PIN);
  const executables = new Map();
  const sourceAudit = sources.map(path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['show', `${OPENAI_SPEECH_PIN}:${path}`], { cwd: root });
    assert.deepEqual(bytes, original, `complete source bytes match pinned git object: ${path}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: execFileSync('git', ['rev-parse', `${OPENAI_SPEECH_PIN}:${path}`], { cwd: root, encoding: 'utf8' }).trim(),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const runs = [];
  for (const recipe of inputs()) runs.push(await new SpeechCapture(executables, recipe).run());
  return {
    schemaVersion: 1, referencePin: OPENAI_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-openai-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: uniqueImports(runs.flatMap(run => run.staticImports)),
      dynamicImports: uniqueImports(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    platformBoundaries: Object.entries(boundaryDescriptions).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    limits: [
      'Complete speech-provider.ts, realtime-provider-shared.ts and all three normalization modules execute unchanged apart from TypeScript erasure; SDK facades only re-export originals.',
      'Only buildOpenAISpeechProvider, resolveConfig and successful synthesize/synthesizeTelephony callbacks are exercised; other shared/provider exports are provenance, not behavior coverage.',
      'Each vector has a fresh isolated VM with process.env={} and cfg={}; no live environment, configuration files, provider connection or network is read.',
      'The synthetic successful HTTP boundary returns eight fixed byte tokens, records request content and timeout, and counts release; it does not validate real audio or production resource lifetime.',
      'The explicit 16 MiB media limit and binary response reader are fixtures; production limit resolution and bounded response streaming are unexecuted.',
      'The voice compatibility fixture recognizes .opus among the exercised .mp3/.opus/.wav formats; original media detection and audio decoding are unexecuted.',
      'Speech directive parser construction returns an unused callback; no directive parsing or numeric directive behavior is exercised.',
      'Secret strings, request headers, proxy capture and network policy are explicit platform fixtures; imported production implementations are unexecuted and header values are omitted from the artifact.',
      '12345 ms is the observed request timeout argument. The harness applies a 2000 ms synchronous VM and asynchronous deadline; production request deadline behavior is unverified.',
      'Ordinary extra body fields and their final spread precedence are observed; no sanitizer-specific branch is exercised.',
      'This oracle makes no registration, readiness, eligibility, full runtime or real provider claim.',
    ],
    observations: runs.map(run => run.observation),
  };
}

export async function writeOpenAISpeechCapture(root, output) {
  const capture = await runOpenAISpeechCapture(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', output] = process.argv.slice(2);
  if (output) await writeOpenAISpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await runOpenAISpeechCapture(root), null, 2) + '\n');
}
