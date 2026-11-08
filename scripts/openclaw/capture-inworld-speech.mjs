// Complete pinned Inworld modules; ordinary buffered NDJSON synthesis only.
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

export const INWORLD_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const INWORLD_SPEECH_SOURCE = 'extensions/inworld/speech-provider.ts';
const sourcePaths = [INWORLD_SPEECH_SOURCE, 'extensions/inworld/tts.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/utf16-slice.ts',
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts'];
const manifestPath = 'extensions/inworld/openclaw.plugin.json';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const fixtureKey = 'fixture-inworld-speech';
const executionTimeoutMs = 2000;
const audioBytes = Buffer.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0xff]);

// Export wiring only. All normalization, provider, parser, base64 and constant
// implementations are the complete original modules, with TypeScript erased.
const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asFiniteNumberInRange } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord, filterStringRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  'openclaw/plugin-sdk/speech-provider':
    'export { createSpeechDirectiveParser } from "src/tts/directive-parser.ts";\n' +
    'export { resolveSpeechProviderApiKey } from "src/tts/tts-provider-helpers.ts";\n' +
    'export { truncateUtf16Safe } from "packages/normalization-core/src/utf16-slice.ts";\n',
  '@openclaw/normalization-core/string-coerce':
    'export { normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
  'openclaw/plugin-sdk/media-runtime':
    'export { canonicalizeBase64 } from "packages/media-core/src/base64.ts";\n' +
    'export { MAX_AUDIO_BYTES } from "packages/media-core/src/constants.ts";\n',
};

const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'returns explicit fixture value; production secret resolution unexecuted',
  },
  'node:fs': { rmSync: 'uninvoked throwing binding required by complete tts-provider-helpers; no cleanup callback executes' },
  'openclaw/plugin-sdk/response-limit-runtime': {
    readResponseWithLimit: 'records supplied limits and callback presence, returns successful synthetic Response bytes; production bounded/idle reader unexecuted',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'records complete original URL/init/body/timeout/policy/audit inputs; returns successful synthetic Response and counted release; original fetch/guard unexecuted',
  },
};

const record = audioContent => JSON.stringify({ result: { audioContent } });
function responseFixture(kind = 'single') {
  const single = record('UklGRgABAv8=');
  const chunks = [record('UklGRg=='), record('AAE='), record('Av8=')];
  const ndjson = {
    single: `${single}\n`,
    multiple: chunks.join('\n') + '\n',
    blank: `\n  \n\u00a0\ufeff  ${chunks[0]}  \ufeff\u00a0\n\t\n${chunks[1]}\n\n${chunks[2]}\n`,
    metadata: [JSON.stringify({ requestId: 'ordinary-request' }), chunks[0],
      JSON.stringify({ result: { requestId: 'ordinary-progress' } }), chunks[1], chunks[2]].join('\n') + '\n',
    normalized: [record(' UklG Rg==\t'), record('AAE'), record('Av8')].join('\n') + '\n',
  }[kind];
  assert.equal(typeof ndjson, 'string');
  return { status: 200, ndjson,
    audioChunksBase64: kind === 'single' ? ['UklGRgABAv8='] : ['UklGRg==', 'AAE=', 'Av8='],
    audioBase64: audioBytes.toString('base64') };
}

function inputs() {
  const rows = [
    { id: 'default-file' },
    { id: 'configured', config: { baseUrl: ' https://speech.example.test/prefix/// ',
      voiceId: '\u00a0\ufeff Ashley \ufeff\u00a0', modelId: '\ufeff\u00a0 inworld-tts-1.5-mini \u00a0\ufeff', temperature: 0.8 } },
    { id: 'provider-overrides', config: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-max', temperature: 0.8 },
      overrides: { voiceId: ' Wendy ', modelId: ' inworld-tts-1.5-mini ', temperature: 1.1 } },
    { id: 'partial-overrides', config: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.1 },
      overrides: { temperature: 1.5 } },
    { id: 'override-aliases', config: { voiceId: 'Sarah', modelId: 'inworld-tts-1.5-max', temperature: 0.8 },
      overrides: { voice: ' Olivia ', model: ' inworld-tts-1 ', temperature: 1.5 } },
    { id: 'override-primary-fields', overrides: { voiceId: ' Dennis ', voice: 'Sarah',
      modelId: ' inworld-tts-1.5-mini ', model: 'inworld-tts-1.5-max', temperature: 0.8 } },
    { id: 'default-note', target: 'voice-note' },
    { id: 'configured-note', target: 'voice-note', config: { voiceId: 'Ashley', modelId: 'inworld-tts-1-max', temperature: 1.1 } },
    { id: 'telephony', target: 'telephony', config: { voiceId: 'Dennis', modelId: 'inworld-tts-1.5-mini', temperature: 1.5 } },
    { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
    { id: 'multiple-audio-lines', response: 'multiple' },
    { id: 'blank-lines', response: 'blank' },
    { id: 'metadata-lines', response: 'metadata' },
    { id: 'base64-normalization', response: 'normalized' },
  ];
  return rows.map(({ id, target = 'audio-file', config, overrides, response, text = 'Plain speech fixture.' }) => ({
    id, input: { text, target, timeoutMs: 12345,
      rawConfig: { providers: { inworld: { apiKey: fixtureKey, ...config } } },
      ...(overrides ? { providerOverrides: overrides } : {}) }, response: responseFixture(response),
  }));
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), INWORLD_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', INWORLD_SPEECH_PIN])
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
  return { verified: true, commit: INWORLD_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${INWORLD_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Inworld capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class InworldSpeechCapture {
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
      normalizeResolvedSecretInputString: ({ value, path }) => {
        assert.equal(value, fixtureKey);
        assert.equal(path, 'tts.providers.inworld.apiKey');
        return called('normalizeResolvedSecretInputString', value, { path });
      },
      rmSync: () => { throw Error('Uninvoked fixture cleanup binding called'); },
      readResponseWithLimit: async (response, maxBytes, options) => {
        assert.equal(response.ok, true);
        called('readResponseWithLimit', undefined, { maxBytes, chunkTimeoutMs: options.chunkTimeoutMs,
          overflowCallbackProvided: typeof options.onOverflow === 'function',
          idleCallbackProvided: typeof options.onIdleTimeout === 'function' });
        return Buffer.from(await response.arrayBuffer());
      },
      fetchWithSsrFGuard: async params => {
        called('fetchWithSsrFGuard');
        const url = new URL(params.url);
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: plain(params.init.headers),
          body: JSON.parse(params.init.body), bodyText: params.init.body, timeoutMs: params.timeoutMs,
          policy: plain(params.policy), auditContext: params.auditContext });
        return { response: new Response(this.recipe.response.ndjson, { status: this.recipe.response.status,
          headers: { 'Content-Type': 'application/x-ndjson' } }),
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
    const module = this.module(INWORLD_SPEECH_SOURCE);
    await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = module.namespace;
    this.context.speechInput = plain(this.recipe.input);
    const { resolvedConfig, result, metadata } = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildInworldSpeechProvider();
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig, cfg: {}, timeoutMs: speechInput.timeoutMs });
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: {} };
      const result = await (speechInput.target === 'telephony'
        ? provider.synthesizeTelephony(request) : provider.synthesize(request));
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
      response: plain(this.recipe.response), result: { audioBase64: audioBuffer.toString('base64'), ...plain(resultMetadata) },
      releaseCount: this.releaseCount, platformCalls: this.calls },
    staticImports: this.staticImports, dynamicImports: this.dynamicImports };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function runInworldSpeechCapture(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${INWORLD_SPEECH_PIN}:${path}`], {
      timeout: 30_000, env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      git(root, ['rev-parse', `${INWORLD_SPEECH_PIN}:${path}`]), path);
    return bytes;
  };
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${INWORLD_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const manifestBytes = readOriginal(manifestPath);
  const runs = [];
  for (const recipe of inputs()) runs.push(await new InworldSpeechCapture(executables, recipe).run());
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: INWORLD_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-inworld-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [{ path: manifestPath, gitBlob: git(root, ['rev-parse', `${INWORLD_SPEECH_PIN}:${manifestPath}`]),
      sourceSha256: hash(manifestBytes), usage: 'complete original plugin manifest provenance; plugin registration unexecuted' }],
    pluginManifest: JSON.parse(manifestBytes),
    platformBoundaries: Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    environmentFixture: { env: {}, cfg: {} },
    hostAdaptation: { config: 'Explicit atom snake API: voice_id/model_id/temperature/base_url; raw override voice/model aliases stay oracle inputs only.',
      response: 'Buffered NDJSON parsing and exact opaque decoded audio order; native publication remains MP3 only in this batch.',
      headers: 'Original supplied headers are provenance only; authentication validity and full host header parity are untested.' },
    counts: { observations: runs.length, synthesisCallbacks: runs.length - 1, telephonyCallbacks: 1,
      httpRequests: runs.length, releases: runs.length, wholeModules: sourcePaths.length,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; 11 complete TypeScript modules and complete original plugin manifest additionally checked against pinned Git blobs.',
      'Whole-module execution means evaluation, not all exports; buildInworldSpeechProvider, nested raw resolveConfig and ordinary successful synthesize/synthesizeTelephony callbacks execute.',
      'Pure SDK facades contain export wiring only; original normalization, directive-parser construction, NDJSON parser, canonicalizeBase64 and fixed MAX_AUDIO_BYTES=16 MiB execute. Directive parsing is unexecuted.',
      'Fresh per-vector VM process.env={} and cfg={}; explicit fixture secret is supplied through a declared synthetic secret binding.',
      'Original code builds the URL, JSON request body and request init; fetchWithSsrFGuard records those inputs and returns a synthetic successful Response. No production HTTP/guard or real provider executes.',
      'readResponseWithLimit records 32 MiB maxBytes, 30000 ms idle setting and callback presence, then reads exact Response bytes; production bounded/idle reader and callbacks are unexecuted.',
      '12345 ms is the forwarded request timeout; 2000 ms bounds VM/capture execution. No timeout, size/count threshold, overflow or production resource-lifetime qualification.',
      'Multiple NDJSON audio records, blank lines, metadata-only JSON records, whitespace and unpadded canonical base64 execute with ordinary eight-byte opaque fixtures; no audio decoding or codec validation.',
      'Source file MP3/.mp3/false, note OGG_OPUS/.ogg/true and telephony PCM/22050 are metadata observations; no native voice-note/telephony or transcode claim.',
      'No listVoices, Talk, directives, fallback, authentication/security/permission, negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/race or real provider execution.',
    ],
    observations: runs.map(run => run.observation) };
}

export async function writeInworldSpeechCapture(root, output) {
  const capture = await runInworldSpeechCapture(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c';
  let output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-inworld-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeInworldSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await runInworldSpeechCapture(root), null, 2) + '\n');
}
