// Complete pinned Gradium modules; ordinary successful binary synthesis only.
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

export const GRADIUM_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const GRADIUM_SPEECH_SOURCE = 'extensions/gradium/speech-provider.ts';
const sourcePaths = [GRADIUM_SPEECH_SOURCE, 'extensions/gradium/shared.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts'];
const manifestPath = 'extensions/gradium/openclaw.plugin.json';
const licensePath = 'LICENSE';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const fixtureKey = 'fixture-gradium-speech';
const executionTimeoutMs = 2000;
const audioBytes = Buffer.from([82, 73, 70, 70, 0, 1, 2, 255]);

// These facades only wire exports to the complete original helper modules.
// TypeScript erasure is the only transformation applied to source modules.
const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  'openclaw/plugin-sdk/speech-provider':
    'export { createSpeechDirectiveParser } from "src/tts/directive-parser.ts";\n' +
    'export { resolveSpeechProviderApiKey } from "src/tts/tts-provider-helpers.ts";\n',
  '@openclaw/normalization-core/string-coerce':
    'export { normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
};

const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'returns explicit fixture value; production secret resolution unexecuted',
  },
  'node:fs': { rmSync: 'uninvoked throwing binding required by complete tts-provider-helpers; no cleanup callback executes' },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'records cfg/audio and returns the fixed default 16 MiB audio fixture cap; production resolver and budget qualification unexecuted',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'records successful response status, label and supplied options; production error/authentication handling unexecuted',
    readProviderBinaryResponse: 'records label, kind, supplied maxBytes and callback presence, returns exact synthetic Response bytes; production bounded reader and overflow callback unexecuted',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'records complete original URL/init/body/timeout/requireHttps/policy/audit inputs; returns successful synthetic Response and counted release; original fetch/guard unexecuted',
  },
};

function inputs() {
  const kent = 'LFZvm12tW_z0xfGo';
  const tiffany = 'Eu9iL_CYe8N-Gkx_';
  const rows = [
    { id: 'default-file' },
    { id: 'configured', config: { baseUrl: 'https://api.gradium.ai/prefix///', voiceId: ' LFZvm12tW_z0xfGo ' } },
    { id: 'voice-override', config: { voiceId: kent }, overrides: { voiceId: ' Eu9iL_CYe8N-Gkx_ ' } },
    { id: 'blank-override', config: { voiceId: kent }, overrides: { voiceId: ' ' } },
    { id: 'unicode-trim', config: { voiceId: '\u00a0\ufeff 2H4HY2CBNyJHBCrP \ufeff\u00a0' } },
    { id: 'default-note', target: 'voice-note' },
    { id: 'configured-note', target: 'voice-note', config: { voiceId: kent } },
    { id: 'override-note', target: 'voice-note', config: { voiceId: kent }, overrides: { voiceId: tiffany } },
    { id: 'default-telephony', target: 'telephony' },
    { id: 'configured-telephony', target: 'telephony', config: { voiceId: kent } },
    { id: 'override-telephony', target: 'telephony', config: { voiceId: kent }, overrides: { voiceId: tiffany } },
    { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
  ];
  return rows.map(({ id, target = 'audio-file', config, overrides, text = 'Plain speech fixture.' }) => ({
    id, input: { text, target, timeoutMs: 12345,
      rawConfig: { providers: { gradium: { apiKey: fixtureKey, ...config } } },
      ...(overrides ? { providerOverrides: overrides } : {}) },
    response: { status: 200, headers: { 'Content-Type': 'application/octet-stream' }, audioBase64: audioBytes.toString('base64') },
  }));
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), GRADIUM_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', GRADIUM_SPEECH_PIN])
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
  return { verified: true, commit: GRADIUM_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${GRADIUM_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Gradium capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class GradiumSpeechCapture {
  constructor(executables, recipe) {
    Object.assign(this, { executables, recipe });
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
      normalizeResolvedSecretInputString: ({ value, path }) =>
        called('normalizeResolvedSecretInputString', value, { path }),
      rmSync: () => { throw Error('Uninvoked fixture cleanup binding called'); },
      resolveGeneratedMediaMaxBytes: (cfg, kind) =>
        called('resolveGeneratedMediaMaxBytes', 16 * 1024 * 1024, { cfg: plain(cfg), kind, resolvedMaxBytes: 16 * 1024 * 1024 }),
      assertOkOrThrowProviderError: async (response, label, options) => {
        called('assertOkOrThrowProviderError', undefined, { status: response.status, label, options: plain(options) });
      },
      readProviderBinaryResponse: async (response, label, kind, options) => {
        called('readProviderBinaryResponse', undefined, { label, kind, maxBytes: options.maxBytes,
          overflowCallbackProvided: typeof options.onOverflow === 'function' });
        return Buffer.from(await response.arrayBuffer());
      },
      fetchWithSsrFGuard: async params => {
        called('fetchWithSsrFGuard');
        const url = new URL(params.url);
        this.requests.push({ url: params.url, init: plain(params.init), method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: plain(params.init.headers),
          body: JSON.parse(params.init.body), bodyText: params.init.body, timeoutMs: params.timeoutMs,
          requireHttps: params.requireHttps, policy: plain(params.policy), auditContext: params.auditContext });
        return { response: new Response(Buffer.from(this.recipe.response.audioBase64, 'base64'), {
          status: this.recipe.response.status, headers: this.recipe.response.headers }),
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
    const module = this.module(GRADIUM_SPEECH_SOURCE);
    await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = module.namespace;
    this.context.speechInput = plain(this.recipe.input);
    const { resolvedConfig, result, metadata, listVoices, synthesisRequest, synthesisRequestAfter } =
      await withDeadline(vm.runInContext(`(async () => {
        const provider = speechSource.buildGradiumSpeechProvider();
        const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig, cfg: {}, timeoutMs: speechInput.timeoutMs });
        const listVoices = await provider.listVoices();
        const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
          providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: {} };
        const synthesisRequest = JSON.parse(JSON.stringify(request));
        const result = await (speechInput.target === 'telephony'
          ? provider.synthesizeTelephony(request) : provider.synthesize(request));
        return { resolvedConfig, result, listVoices, synthesisRequest,
          synthesisRequestAfter: JSON.parse(JSON.stringify(request)),
          metadata: Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function')) };
      })()`, this.context, { timeout: executionTimeoutMs }));
    assert.equal(this.requests.length, 1);
    assert.equal(this.releaseCount, 1);
    assert.deepEqual(result.audioBuffer, audioBytes);
    for (const path of sourcePaths) assert.equal(this.modules.get(path)?.status, 'evaluated', path);
    const { audioBuffer, ...resultMetadata } = result;
    return { observation: { id: this.recipe.id, input: plain(this.recipe.input), inputAfter: plain(this.context.speechInput),
      resolvedConfig: plain(resolvedConfig), providerMetadata: plain(metadata), listVoices: plain(listVoices),
      synthesisRequest: plain(synthesisRequest), synthesisRequestAfter: plain(synthesisRequestAfter), request: this.requests[0],
      response: plain(this.recipe.response), result: { audioBase64: audioBuffer.toString('base64'), ...plain(resultMetadata) },
      releaseCount: this.releaseCount, platformCalls: this.calls },
    staticImports: this.staticImports, dynamicImports: this.dynamicImports };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureGradiumSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${GRADIUM_SPEECH_PIN}:${path}`], {
      timeout: 30_000, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      git(root, ['rev-parse', `${GRADIUM_SPEECH_PIN}:${path}`]), path);
    return bytes;
  };
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${GRADIUM_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const manifestBytes = readOriginal(manifestPath);
  const licenseBytes = readOriginal(licensePath);
  const runs = [];
  for (const recipe of inputs()) runs.push(await new GradiumSpeechCapture(executables, recipe).run());
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: GRADIUM_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-gradium-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [{ path: manifestPath, gitBlob: git(root, ['rev-parse', `${GRADIUM_SPEECH_PIN}:${manifestPath}`]),
      sourceSha256: hash(manifestBytes), usage: 'complete original plugin manifest provenance; plugin registration unexecuted' },
    { path: licensePath, gitBlob: git(root, ['rev-parse', `${GRADIUM_SPEECH_PIN}:${licensePath}`]),
      sourceSha256: hash(licenseBytes), usage: 'complete original source license provenance' }],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries: Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    environmentFixture: { env: {}, cfg: {} },
    hostAdaptation: { config: 'Source nested providers.gradium config and providerOverrides.voiceId remain unmodified oracle inputs; no host implementation is qualified in this batch.',
      response: 'Exact opaque binary bytes returned for WAV, Opus and ulaw_8000; no audio decoding, codec validation, transcoding or native publication.',
      headers: 'Original supplied headers and policy arguments are provenance only; authentication validity and full host transport/security parity are untested.' },
    counts: { observations: runs.length, synthesisCallbacks: 9, telephonyCallbacks: 3,
      httpRequests: runs.length, releases: runs.length, listVoicesCallbacks: runs.length, wholeModules: sourcePaths.length,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; eight complete TypeScript modules, complete original plugin manifest and LICENSE additionally checked against pinned Git blobs.',
      'Whole-module execution means evaluation, not all exports; buildGradiumSpeechProvider, nested raw resolveConfig, listVoices and ordinary successful synthesize/synthesizeTelephony callbacks execute.',
      'Pure SDK facades contain export wiring only; original config/helper/normalization modules and directive-parser construction execute. No directive dispatch or isConfigured/isConfiguredAsync call executes.',
      'Fresh per-vector VM process.env={} and cfg={}; explicit fixture secret is supplied through a declared synthetic secret binding. Ambient environment, OAuth, SecretRef and plugin loader are unexecuted.',
      'Original code builds the URL, JSON-string json_config body and request init; fetchWithSsrFGuard records complete inputs and returns a synthetic successful binary Response. No production HTTP, SSRF guard or real provider executes.',
      'resolveGeneratedMediaMaxBytes is an explicit fixed default 16 MiB audio fixture facade; no production cap resolver, size/budget/threshold variation or resource-budget qualification.',
      'Provider HTTP facades record ordinary successful response/reader arguments and callback presence, then return exact Response bytes; production reader, error/authentication handling and overflow callback are unexecuted.',
      '12345 ms is the forwarded request timeout; 2000 ms bounds VM/capture execution. No timeout/failure/cancellation or production resource-lifetime qualification.',
      'WAV/.wav/false, Opus/.opus/true and telephony ulaw_8000/8000 are observed source metadata on identical ordinary eight-byte opaque fixtures; no audio decoding or codec validity claim.',
      'No directive policy, Talk, fallback, authentication/security/permission, negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/size/count threshold/race, real provider or remote MCP execution.',
    ],
    observations: runs.map(run => run.observation) };
}

export async function writeGradiumSpeechCapture(root, output) {
  const capture = await captureGradiumSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c';
  let output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-gradium-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeGradiumSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureGradiumSpeech(root), null, 2) + '\n');
}
