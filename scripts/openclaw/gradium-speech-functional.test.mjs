// Independent expectations authored from the pinned Gradium source before execution.
// Synthetic ordinary speech only; opaque fixture bytes do not qualify codec decoding.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { GRADIUM_SPEECH_PIN, captureGradiumSpeech } from './capture-gradium-speech.mjs';

const root = process.env.OPENCLAW_GRADIUM_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_GRADIUM_SPEECH_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/gradium-speech.json', import.meta.url);
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const key = 'fixture-gradium-speech';
const baseUrl = 'https://api.gradium.ai';
const text = 'Plain speech fixture.';
const audioBase64 = 'UklGRgABAv8=';
const defaults = { apiKey: key, baseUrl, voiceId: 'YTpq7expH9539ERJ' };
const voices = [
  { id: 'YTpq7expH9539ERJ', name: 'Emma' },
  { id: 'LFZvm12tW_z0xfGo', name: 'Kent' },
  { id: 'Eu9iL_CYe8N-Gkx_', name: 'Tiffany' },
  { id: '2H4HY2CBNyJHBCrP', name: 'Christina' },
  { id: 'jtEKaLYNn6iif5PR', name: 'Sydney' },
  { id: 'KWJiFWu2O9nMPYcR', name: 'John' },
  { id: '3jUdJyOi9pgbxBTK', name: 'Arthur' },
];
const sourcePaths = [
  'extensions/gradium/speech-provider.ts', 'extensions/gradium/shared.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts',
];

// These recipe values and expected normalized values come from the original modules,
// never from the capture module or persisted capture.
const recipes = [
  { id: 'default-file' },
  { id: 'configured', raw: { baseUrl: 'https://api.gradium.ai/prefix///', voiceId: ' LFZvm12tW_z0xfGo ' },
    resolved: { baseUrl: 'https://api.gradium.ai/prefix', voiceId: 'LFZvm12tW_z0xfGo' },
    wireBase: 'https://api.gradium.ai/prefix', wireVoice: 'LFZvm12tW_z0xfGo' },
  { id: 'voice-override', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, overrides: { voiceId: ' Eu9iL_CYe8N-Gkx_ ' },
    wireVoice: 'Eu9iL_CYe8N-Gkx_' },
  { id: 'blank-override', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, overrides: { voiceId: ' ' }, wireVoice: 'LFZvm12tW_z0xfGo' },
  { id: 'unicode-trim', raw: { voiceId: '\u00a0\ufeff 2H4HY2CBNyJHBCrP \ufeff\u00a0' },
    resolved: { voiceId: '2H4HY2CBNyJHBCrP' }, wireVoice: '2H4HY2CBNyJHBCrP' },
  { id: 'default-note', target: 'voice-note' },
  { id: 'configured-note', target: 'voice-note', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, wireVoice: 'LFZvm12tW_z0xfGo' },
  { id: 'override-note', target: 'voice-note', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, overrides: { voiceId: 'Eu9iL_CYe8N-Gkx_' },
    wireVoice: 'Eu9iL_CYe8N-Gkx_' },
  { id: 'default-telephony', target: 'telephony' },
  { id: 'configured-telephony', target: 'telephony', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, wireVoice: 'LFZvm12tW_z0xfGo' },
  { id: 'override-telephony', target: 'telephony', raw: { voiceId: 'LFZvm12tW_z0xfGo' },
    resolved: { voiceId: 'LFZvm12tW_z0xfGo' }, overrides: { voiceId: 'Eu9iL_CYe8N-Gkx_' },
    wireVoice: 'Eu9iL_CYe8N-Gkx_' },
  { id: 'authored-text', text: '  Ordinary speech.\n你好 🌍 — café.\t ' },
];

const platformCalls = [
  { module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString',
    path: 'tts.providers.gradium.apiKey' },
  { module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString',
    path: 'tts.providers.gradium.apiKey' },
  { module: 'openclaw/plugin-sdk/media-generation-runtime', export: 'resolveGeneratedMediaMaxBytes', cfg: {}, kind: 'audio' },
  { module: 'openclaw/plugin-sdk/ssrf-runtime', export: 'fetchWithSsrFGuard' },
  { module: 'openclaw/plugin-sdk/provider-http', export: 'assertOkOrThrowProviderError', status: 200,
    label: 'Gradium API error', options: { requestHeaders: { 'x-api-key': key } } },
  { module: 'openclaw/plugin-sdk/provider-http', export: 'readProviderBinaryResponse',
    label: 'Gradium API error', kind: 'audio' },
  { module: 'openclaw/plugin-sdk/ssrf-runtime', export: 'release' },
];

const expectedRows = recipes.map(recipe => {
  const target = recipe.target ?? 'audio-file';
  const input = { text: recipe.text ?? text, target, timeoutMs: 12345,
    rawConfig: { providers: { gradium: { apiKey: key, ...recipe.raw } } },
    ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}) };
  const resolvedConfig = { ...defaults, ...recipe.resolved };
  const synthesisRequest = { text: recipe.text ?? text, target, timeoutMs: 12345,
    providerConfig: resolvedConfig, ...(recipe.overrides ? { providerOverrides: recipe.overrides } : {}), cfg: {} };
  const outputFormat = target === 'telephony' ? 'ulaw_8000' : target === 'voice-note' ? 'opus' : 'wav';
  const body = { text: recipe.text ?? text, voice_id: recipe.wireVoice ?? 'YTpq7expH9539ERJ',
    only_audio: true, output_format: outputFormat, json_config: '{"padding_bonus":0}' };
  const bodyText = JSON.stringify(body);
  // Fake-key header construction is a wire observation, not authentication validation.
  const headers = { 'x-api-key': key, 'Content-Type': 'application/json' };
  return { id: recipe.id, input, inputAfter: input, resolvedConfig,
    providerMetadata: { id: 'gradium', label: 'Gradium', autoSelectOrder: 30,
      voices: voices.map(voice => voice.id) }, listVoices: voices,
    synthesisRequest, synthesisRequestAfter: synthesisRequest,
    request: { url: `${recipe.wireBase ?? baseUrl}/api/post/speech/tts`,
      init: { method: 'POST', headers, body: bodyText }, method: 'POST',
      path: recipe.wireBase ? '/prefix/api/post/speech/tts' : '/api/post/speech/tts',
      query: {}, headers, body, bodyText, timeoutMs: 12345, auditContext: 'gradium.tts' },
    response: { status: 200, headers: { 'Content-Type': 'application/octet-stream' }, audioBase64 },
    result: target === 'telephony'
      ? { audioBase64, outputFormat: 'ulaw_8000', sampleRate: 8000 }
      : { audioBase64, outputFormat, fileExtension: target === 'voice-note' ? '.opus' : '.wav',
        voiceCompatible: target === 'voice-note' },
    releaseCount: 1, platformCalls };
});

// Policy flags and the fixed default media-size facade values remain provenance.
// Neither security behavior nor limits are part of this ordinary-success oracle.
function ordinaryObservation(row) {
  const { requireHttps, policy, ...request } = row.request;
  return { ...row, request, platformCalls: row.platformCalls.map(call => {
    const { maxBytes, resolvedMaxBytes, overflowCallbackProvided, ...ordinaryCall } = call;
    return ordinaryCall;
  }) };
}

const capture = await captureGradiumSpeech(root);

test('12 ordinary original callbacks match complete independent config, wire, bytes and result maps', () => {
  assert.deepEqual(capture.observations.map(ordinaryObservation), expectedRows);
  for (const row of capture.observations) {
    assert.deepEqual([...Buffer.from(row.result.audioBase64, 'base64')], [82, 73, 70, 70, 0, 1, 2, 255], row.id);
  }
});

test('actual ordered voices and provider metadata have no invented model or timeout defaults', () => {
  for (const row of capture.observations) {
    assert.deepEqual(row.listVoices, voices, row.id);
    assert.deepEqual(row.providerMetadata, { id: 'gradium', label: 'Gradium', autoSelectOrder: 30,
      voices: ['YTpq7expH9539ERJ', 'LFZvm12tW_z0xfGo', 'Eu9iL_CYe8N-Gkx_',
        '2H4HY2CBNyJHBCrP', 'jtEKaLYNn6iif5PR', 'KWJiFWu2O9nMPYcR', '3jUdJyOi9pgbxBTK'] }, row.id);
  }
  assert.deepEqual(capture.counts, { observations: 12, synthesisCallbacks: 9, telephonyCallbacks: 3,
    httpRequests: 12, releases: 12, listVoicesCallbacks: 12, wholeModules: 8,
    trackedFilesBefore: 58558, trackedFilesAfter: 58558 });
});

test('whole original modules, manifest, license and full tracked checkout have pinned provenance', () => {
  assert.equal(capture.schemaVersion, 1);
  assert.equal(GRADIUM_SPEECH_PIN, pin);
  assert.equal(capture.referencePin, pin);
  assert.deepEqual(capture.sourceAudit.map(audit => audit.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root }));
    assert.deepEqual(audit, { path: audit.path,
      gitBlob: createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      sourceSha256: hash(bytes),
      executableSha256: hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
      wholeModule: true, executed: true });
  }
  assert.deepEqual(capture.dataAudit.map(audit => audit.path), ['extensions/gradium/openclaw.plugin.json', 'LICENSE']);
  for (const audit of capture.dataAudit) {
    const bytes = readFileSync(join(root, audit.path));
    assert.deepEqual(bytes, execFileSync('git', ['show', `${pin}:${audit.path}`], { cwd: root }));
    assert.equal(audit.sourceSha256, hash(bytes));
    assert.equal(audit.gitBlob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
  }
  assert.deepEqual(capture.pluginManifest, {
    id: 'gradium', categories: ['voice'], capabilityCatalogEntry: './capability-catalog.ts',
    activation: { onStartup: false }, setup: { providers: [{ id: 'gradium', envVars: ['GRADIUM_API_KEY'] }] },
    contracts: { speechProviders: ['gradium'] },
    configSchema: { type: 'object', additionalProperties: false, properties: {} },
  });
  assert.deepEqual(capture.license, { path: 'LICENSE', text: readFileSync(join(root, 'LICENSE'), 'utf8') });
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.checkout.before.verified, true);
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(capture.checkout.before.commit, pin);
  assert.equal(capture.checkout.before.tree,
    execFileSync('git', ['rev-parse', `${pin}^{tree}`], { cwd: root, encoding: 'utf8' }).trim());
  assert.equal(capture.harness.path, 'scripts/openclaw/capture-gradium-speech.mjs');
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-gradium-speech.mjs', import.meta.url))));
  assert.equal(capture.transformation.api, 'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options, { mode: 'transform', sourceMap: false });
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source));
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export \{ .* \} from ".*";$/.test(line)));
  }
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier), [
    'openclaw/plugin-sdk/media-generation-runtime', 'openclaw/plugin-sdk/provider-http',
    'openclaw/plugin-sdk/ssrf-runtime',
  ]);
});

test('platform fixtures remain explicit and isolated from original source qualification', () => {
  assert.deepEqual(capture.environmentFixture, { env: {}, cfg: {} });
  assert.deepEqual(capture.platformBoundaries.map(boundary => boundary.module), [
    'openclaw/plugin-sdk/secret-input', 'node:fs', 'openclaw/plugin-sdk/media-generation-runtime',
    'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
  ]);
  for (const boundary of capture.platformBoundaries) assert.equal(boundary.originalSourceExecuted, false);
});

test('fresh module capture equals the entire parent-generated persisted fixture', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture)));
});

test('fresh CLI capture equals the entire parent-generated persisted fixture', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-gradium-speech-'));
  try {
    const output = join(temporary, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-gradium-speech.mjs', import.meta.url)), '--source', root, '--output', output],
    { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(readFileSync(output)), JSON.parse(readFileSync(fixture)));
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
