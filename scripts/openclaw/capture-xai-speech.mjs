// Complete pinned xAI modules; ordinary buffered synthesis with successful
// synthetic HTTP only. Run: node --experimental-vm-modules this-file --source DIR --output FILE
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const XAI_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const XAI_SPEECH_SOURCE = 'extensions/xai/speech-provider.ts';
const sourcePaths = [XAI_SPEECH_SOURCE, 'extensions/xai/speech-provider-metadata.ts',
  'extensions/xai/speech-provider-metadata-factory.ts', 'extensions/xai/tts.ts',
  'extensions/xai/model-definitions.ts', 'extensions/xai/model-id.ts',
  'extensions/xai/src/xai-user-agent.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/error-coercion.ts',
  'packages/normalization-core/src/utf16-slice.ts', 'packages/media-core/src/base64.ts',
  'src/infra/ws.ts', 'packages/gateway-client/src/websocket-data.ts'];
const manifestPath = 'extensions/xai/openclaw.plugin.json';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const audioBytes = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]);
const fixtureKey = 'fixture-xai-speech';
const maxAudioBytes = 16 * 1024 * 1024;
const executionTimeoutMs = 2000;

// Export wiring only; no normalization, directive or provider implementation is replaced.
const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asFiniteNumberInRange } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord, asOptionalObjectRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString, normalizeOptionalLowercaseString, normalizeLowercaseStringOrEmpty } from "packages/normalization-core/src/string-coerce.ts";\n',
  'openclaw/plugin-sdk/speech-provider':
    'export { createSpeechDirectiveParser } from "src/tts/directive-parser.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
  'openclaw/plugin-sdk/error-runtime':
    'export { toStringifiedError } from "packages/normalization-core/src/error-coercion.ts";\n',
  'openclaw/plugin-sdk/realtime-voice-provider':
    'export { canonicalizeBase64 } from "packages/media-core/src/base64.ts";\n' +
    'export { rawDataToString } from "src/infra/ws.ts";\n',
  '@openclaw/gateway-client/websocket-data':
    'export { rawDataToString } from "packages/gateway-client/src/websocket-data.ts";\n',
  'openclaw/plugin-sdk/text-utility-runtime':
    'export { sliceUtf16Safe } from "packages/normalization-core/src/utf16-slice.ts";\n',
};

const boundaries = {
  'openclaw/plugin-sdk/provider-auth': {
    isProviderAuthProfileConfigured: 'uninvoked profile-readiness binding; throws if called',
    isProviderAuthProfileConfiguredAsync: 'uninvoked asynchronous profile-readiness binding; throws if called',
  },
  'openclaw/plugin-sdk/provider-auth-runtime': {
    resolveApiKeyForProvider: 'uninvoked profile credential binding; explicit fixture secret short-circuits discovery',
  },
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'asserts explicit fixture value and path, then returns it; production secret resolution unexecuted',
  },
  'openclaw/plugin-sdk/agent-harness-registration': {
    OPENCLAW_VERSION: 'artifact-version fixture read from byte-verified pinned package.json; production build/filesystem/version discovery unexecuted',
  },
  'extensions/xai/ws-runtime.ts': {
    WebSocket: 'uninvoked throwing constructor; no socket or streaming callback executes',
  },
  'node:buffer': { Buffer: 'host Node Buffer primitive only; complete original WebSocket data helper evaluated but uncalled' },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'asserts cfg={} and kind=audio, returns explicit 16 MiB fixture; production limit resolver unexecuted',
  },
  'openclaw/plugin-sdk/provider-http': {
    postJsonRequest: 'records supplied URL, Headers, body and timeout; synthetic POST JSON serialization plus successful Response and counted release; original HTTP implementation unexecuted and no fetch invoked',
    assertOkOrThrowProviderError: 'asserts synthetic successful Response status and label; production error processing unexecuted',
    readProviderBinaryResponse: 'records maxBytes and overflow callback presence, returns exact Response bytes; production bounded reader unexecuted',
    readProviderJsonArrayFieldResponse: 'uninvoked voice-list reader; throws if called',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedOrigin: 'records normalized base URL, returns explicit synthetic policy token; original policy unexecuted',
    fetchWithSsrFGuard: 'uninvoked voice-list HTTP binding; throws if called',
  },
};

function inputs() {
  const rows = [
    { id: 'default-file' },
    { id: 'configured', config: { baseUrl: ' https://speech.example.test/prefix/// ',
      voiceId: ' ara ', language: ' PT-BR ', speed: 1.15, responseFormat: ' WAV ' } },
    { id: 'raw-aliases', config: { voice: ' leo ', languageCode: ' ZH-CN ', speed: 0.95 } },
    { id: 'primary-config-fields', config: { voiceId: 'rex', voice: 'sal', language: 'FR', languageCode: 'DE' } },
    { id: 'provider-overrides', config: { voiceId: 'ara', language: 'de', speed: 0.9, responseFormat: 'wav' },
      overrides: { voiceId: ' sal ', language: ' JA ', speed: 1.2 } },
    { id: 'partial-overrides', config: { voiceId: 'leo', language: 'fr', speed: 1.1 }, overrides: { voiceId: 'rex' } },
    { id: 'language-auto', config: { language: ' AUTO ' } },
    { id: 'language-bcp', config: { language: ' ES-MX ' } },
    { id: 'file-mp3', config: { responseFormat: ' MP3 ' } },
    { id: 'file-wav', config: { responseFormat: 'wav' } },
    { id: 'file-pcm', config: { responseFormat: 'pcm' } },
    { id: 'file-mulaw', config: { responseFormat: 'mulaw' } },
    { id: 'file-alaw', config: { responseFormat: 'alaw' } },
    { id: 'default-note', target: 'voice-note' },
    { id: 'note-configured-wav', target: 'voice-note', config: { responseFormat: 'wav', voiceId: 'ara', language: 'de', speed: 1.1 } },
    { id: 'telephony', target: 'telephony', config: { responseFormat: 'mp3', voiceId: 'leo', language: 'pt-br', speed: 1.15 } },
    { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  ];
  return rows.map(({ id, target = 'audio-file', config, overrides, text = 'Plain speech fixture.' }) => ({
    id, input: { text, target, timeoutMs: 12345,
      rawConfig: { providers: { xai: { apiKey: fixtureKey, ...config } } },
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), XAI_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', XAI_SPEECH_PIN])
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
  return { verified: true, commit: XAI_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${XAI_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('xAI capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class XaiSpeechCapture {
  constructor(executables, manifest, fixtureVersion, recipe) {
    Object.assign(this, { executables, manifest, fixtureVersion, recipe });
    this.modules = new Map();
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.noFetch = () => { throw Error('Uninvoked fixture fetch called'); };
    this.context = vm.createContext({ Buffer, URL, Headers, fetch: this.noFetch, process: { env: {} } }, {
      codeGeneration: { strings: false, wasm: false },
    });
  }

  platformModule(identifier) {
    const called = (name, value, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return value;
    };
    const unused = () => { throw Error('Uninvoked xAI platform binding called'); };
    const bindings = {
      isProviderAuthProfileConfigured: unused,
      isProviderAuthProfileConfiguredAsync: unused,
      resolveApiKeyForProvider: unused,
      normalizeResolvedSecretInputString: ({ value, path }) => {
        assert.equal(value, fixtureKey);
        assert.equal(path, 'tts.providers.xai.apiKey');
        return called('normalizeResolvedSecretInputString', value, { path });
      },
      OPENCLAW_VERSION: this.fixtureVersion,
      WebSocket: class { constructor() { unused(); } },
      Buffer,
      resolveGeneratedMediaMaxBytes: (cfg, kind) => {
        assert.deepEqual(plain(cfg), {});
        assert.equal(kind, 'audio');
        return called('resolveGeneratedMediaMaxBytes', maxAudioBytes, { kind });
      },
      postJsonRequest: async params => {
        called('postJsonRequest');
        assert.equal(params.fetchFn, this.noFetch);
        const url = new URL(params.url);
        // bodyText belongs to this declared synthetic serialization boundary.
        this.requests.push({ url: params.url, method: 'POST', path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: Object.fromEntries(params.headers),
          body: plain(params.body), bodyText: JSON.stringify(params.body), timeoutMs: params.timeoutMs,
          policy: plain(params.ssrfPolicy), auditContext: params.auditContext, fetchInvoked: false });
        return { response: new Response(audioBytes, { status: 200, headers: { 'Content-Type': 'application/octet-stream' } }),
          release: async () => { this.releaseCount += 1; called('release'); } };
      },
      assertOkOrThrowProviderError: async (response, label) => {
        called('assertOkOrThrowProviderError', undefined, { label });
        assert.equal(response.ok, true);
        assert.equal(label, 'xAI TTS API error');
      },
      readProviderBinaryResponse: async (response, label, kind, options) => {
        assert.equal(label, 'xAI TTS API error');
        assert.equal(kind, 'audio');
        assert.equal(options.maxBytes, maxAudioBytes);
        assert.equal(typeof options.onOverflow, 'function');
        called('readProviderBinaryResponse', undefined, { label, kind, maxBytes: options.maxBytes,
          overflowCallbackProvided: true, overflowCallbackInvoked: false });
        return Buffer.from(await response.arrayBuffer());
      },
      readProviderJsonArrayFieldResponse: unused,
      ssrfPolicyFromHttpBaseUrlAllowedOrigin: baseUrl => called('ssrfPolicyFromHttpBaseUrlAllowedOrigin',
        { fixture: 'xai-origin-policy', baseUrl }, { baseUrl }),
      fetchWithSsrFGuard: unused,
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
    else if (identifier === manifestPath) {
      const manifest = plain(this.manifest);
      module = new vm.SyntheticModule(['default'], function () { this.setExport('default', manifest); },
        { context: this.context, identifier });
    } else {
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
    assert.ok(this.executables.has(resolved) || resolved === manifestPath ||
      Object.hasOwn(sdkFacades, resolved) || Object.hasOwn(boundaries, resolved),
    `declared source import: ${importer.identifier} -> ${specifier}`);
    provenance.push({ importer: importer.identifier, specifier, resolved });
    return this.module(resolved);
  }

  async run() {
    const module = this.module(XAI_SPEECH_SOURCE);
    await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = module.namespace;
    this.context.speechInput = plain(this.recipe.input);
    const { resolvedConfig, result, metadata } = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildXaiSpeechProvider();
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig, cfg: {}, timeoutMs: speechInput.timeoutMs });
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: {} };
      const result = await (speechInput.target === 'telephony'
        ? provider.synthesizeTelephony(request) : provider.synthesize(request));
      return { resolvedConfig, result, metadata: { id: provider.id, label: provider.label,
        autoSelectOrder: provider.autoSelectOrder, models: provider.models, voices: provider.voices } };
    })()`, this.context, { timeout: executionTimeoutMs }));
    assert.equal(this.requests.length, 1);
    assert.equal(this.releaseCount, 1);
    assert.deepEqual(result.audioBuffer, audioBytes);
    for (const path of [...sourcePaths, manifestPath]) assert.equal(this.modules.get(path)?.status, 'evaluated', path);
    const { audioBuffer, ...resultMetadata } = result;
    return { observation: { id: this.recipe.id, input: plain(this.recipe.input), inputAfter: plain(this.context.speechInput),
      resolvedConfig: plain(resolvedConfig), providerMetadata: plain(metadata), request: this.requests[0],
      result: { audioBase64: audioBuffer.toString('base64'), ...plain(resultMetadata) },
      releaseCount: this.releaseCount, platformCalls: this.calls },
    staticImports: this.staticImports, dynamicImports: this.dynamicImports };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function runXaiSpeechCapture(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${XAI_SPEECH_PIN}:${path}`], {
      timeout: 30_000, env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      git(root, ['rev-parse', `${XAI_SPEECH_PIN}:${path}`]), path);
    return bytes;
  };
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${XAI_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const dataBytes = new Map([manifestPath, 'package.json'].map(path => [path, readOriginal(path)]));
  const manifest = JSON.parse(dataBytes.get(manifestPath));
  const fixtureVersion = JSON.parse(dataBytes.get('package.json')).version;
  const runs = [];
  for (const recipe of inputs()) runs.push(await new XaiSpeechCapture(executables, manifest, fixtureVersion, recipe).run());
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: XAI_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-xai-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [...dataBytes].map(([path, bytes]) => ({ path, gitBlob: git(root, ['rev-parse', `${XAI_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), usage: path === manifestPath ? 'complete parsed original JSON module default export' : 'explicit artifact-version fixture only' })),
    platformBoundaries: Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    environmentFixture: { env: {}, cfg: {}, artifactVersion: fixtureVersion },
    hostAdaptation: { config: 'Explicit atom snake API: voice_id/language/speed/response_format/base_url; raw reference voice/languageCode aliases stay oracle inputs only.',
      headers: 'Source native-origin OpenClaw User-Agent is captured; host retains its Req identity and makes no full-header parity claim.' },
    counts: { observations: runs.length, synthesisCallbacks: runs.length - 1, telephonyCallbacks: 1,
      httpRequests: runs.length, releases: runs.length, wholeModules: sourcePaths.length,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; 17 complete TypeScript modules and two original JSON inputs additionally checked against pinned Git blobs.',
      'Whole-module execution means evaluation, not all exports; only buildXaiSpeechProvider, nested raw resolveConfig and ordinary successful synthesize/synthesizeTelephony callbacks execute.',
      'Pure SDK facades contain export wiring only; original normalization, directive-parser construction, model manifest loading and xaiUserAgentHeaderFor execute. Directive parsing is unexecuted.',
      'Fresh per-vector VM process.env={} and cfg={}; explicit fixture secret avoids environment/profile credential discovery; artifact version is a declared package.json fixture.',
      'postJsonRequest records complete supplied request inputs. method=POST and bodyText are synthetic helper serialization, not executed production HTTP serialization or wire evidence; no real network or fetch call.',
      'Successful synthetic HTTP returns eight opaque fixture bytes and counts one release; production bounded reader, policy, resource lifetime, MIME validation and audio decoding are unexecuted.',
      '16 MiB maxBytes is a forwarded fixture, without boundary or overflow execution; 12345 ms is the forwarded request timeout and 2000 ms bounds VM/capture execution, not production timeout proof.',
      'No streaming, listVoices, directives, Talk, auth, plugin registration, negative/error/failure/cancel/crash/race/threshold or real provider execution.',
      'MP3/WAV/PCM/mulaw/alaw describe source file metadata only; native publication remains MP3/WAV in this batch. No codec conversion or new channel behavior.',
      'Ordinary file/note results have voiceCompatible=false and no MIME/sample rate. Telephony forces pcm and returns sampleRate=24000 without fileExtension or voiceCompatible.',
      'The native-origin source OpenClaw User-Agent is observable here; host Req identity differs and full header parity is excluded.',
    ],
    observations: runs.map(run => run.observation) };
}

export async function writeXaiSpeechCapture(root, output) {
  const capture = await runXaiSpeechCapture(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c';
  let output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-xai-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeXaiSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await runXaiSpeechCapture(root), null, 2) + '\n');
}
