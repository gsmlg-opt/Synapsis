// Complete pinned DeepInfra modules; ordinary successful speech callbacks only.
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

export const DEEPINFRA_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const DEEPINFRA_SPEECH_SOURCE = 'extensions/deepinfra/speech-provider.ts';
const timeoutSource = 'src/tts/tts-provider-resolution.ts';
const sourcePaths = [DEEPINFRA_SPEECH_SOURCE, 'extensions/deepinfra/media-models.ts',
  'src/tts/openai-compatible-speech-provider.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'src/shared/dot-path.ts', 'src/shared/path-array-index.ts', 'src/infra/prototype-keys.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', timeoutSource];
const manifestPath = 'extensions/deepinfra/openclaw.plugin.json';
const licensePath = 'LICENSE';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;
const audioBytes = Buffer.from([82, 73, 70, 70, 0, 1, 2, 255]);
const responseFixture = { status: 200, headers: { 'Content-Type': 'application/octet-stream' },
  audioBase64: audioBytes.toString('base64') };

// Export wiring only. Original complete module bytes receive TypeScript erasure only.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    'export { createOpenAiCompatibleSpeechProvider } from "src/tts/openai-compatible-speech-provider.ts";\n',
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asOptionalRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
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

// Frozen before first source execution; independent literal oracle authors use the same raw recipes.
const recipeGroups = {
  synthesis: [
    {"id": "default-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "default-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-mp3-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " MP3 "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-mp3-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " MP3 "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-opus-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " OPUS "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-opus-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " OPUS "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-flac-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " FLAC "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-flac-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " FLAC "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-wav-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " WAV "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-wav-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " WAV "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-pcm-file","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " PCM "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "format-pcm-note","input": {"text": "Plain speech fixture.","target": "voice-note","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","responseFormat": " PCM "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "configured","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","baseUrl": "https://api.deepinfra.com/v1/openai/","modelId": "Qwen/Qwen3-TTS","voiceId": "configured-voice","speed": 1.1,"responseFormat": " OPUS ","extraBody": {"temperature": 0.6}}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "custom-prefix","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","baseUrl": "https://speech.example/deepinfra/v7///","model": "ResembleAI/chatterbox-turbo","voice": "ordinary-voice","speed": 0.9}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "configured-namespace","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": " deepinfra/Qwen/Qwen3-TTS "}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "overrides","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","modelId": "Qwen/Qwen3-TTS","voiceId": "configured-voice","speed": 0.8}}},"providerOverrides": {"model": " deepinfra/ResembleAI/chatterbox-turbo ","voice": " override-voice ","speed": 1.2}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "id-alias-overrides","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}},"providerOverrides": {"modelId": " deepinfra/sesame/csm-1b ","voiceId": " ordinary-id ","speed": 1.1}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "override-key-precedence","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}},"providerOverrides": {"model": " deepinfra/Qwen/Qwen3-TTS ","modelId": "ignored-model","voice": " primary-voice ","voiceId": "ignored-voice"}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "blank-selected-overrides","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "Qwen/Qwen3-TTS","voice": "configured-voice","speed": 0.9}}},"providerOverrides": {"model": " ","modelId": "ignored-model","voice": " ","voiceId": "ignored-voice"}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "config-key-precedence","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": " deepinfra/Qwen/Qwen3-TTS ","modelId": "ignored-model","voice": " primary-voice ","voiceId": "ignored-voice"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "blank-selected-config-model","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": " ","modelId": "ignored-model"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "speaker-precedence","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","speakerVoice": " speaker-v ","speakerVoiceId": "unused-id","voice": "unused-voice","voiceId": "unused"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "speaker-id","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","speakerVoice": " ","speakerVoiceId": " speaker-id ","voice": "unused-voice"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "blank-speaker-fallback","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","speakerVoice": " ","speakerVoiceId": " ","voice": " ordinary-voice ","voiceId": "unused-id"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "unicode-trim","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","modelId": " ﻿ deepinfra/hexgrad/Kokoro-82M ﻿ ","voiceId": " ﻿ af_bella ﻿ ","speed": 1.25}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "zero-speed","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","speed": 0}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "nested-extra-body","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","extraBody": {"model": "nested-model","voice": "nested-voice","input": "nested-input","response_format": "nested-format","speed": 1.7,"extra_body": {"nested": true},"options": {"seeds": [7,11],"style": {"language": "中文","enabled": true}},"tags": ["one",{"two": 2}]}}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "authored-text","input": {"text": "  Ordinary speech.\n你好 🌍 — café.\t ","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "legacy-config","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","modelId": "sesame/csm-1b","voiceId": "legacy-voice","extraBody": {"legacy": true}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "nested-precedence","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "Qwen/Qwen3-TTS","voice": "nested-voice","extraBody": {"nested": true}}},"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "sesame/csm-1b","voice": "legacy-voice","extraBody": {"legacy": true}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "case-sensitive-model-prefix","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "DeepInfra/Qwen/Qwen3-TTS"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "single-model-prefix-strip","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}},"providerOverrides": {"model": "deepinfra/deepinfra/Qwen/Qwen3-TTS"}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "factory-custom-catalog","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}}},"factoryOptions": {"ttsModels": [{"id": "ordinary/custom-first","name": "Custom First","tags": ["tts"],"pricing": {"input_characters": 0.02}},{"id": "ordinary/custom-second","name": "Custom Second","tags": ["tts","multilingual"],"pricing": {"output_seconds": 0.03}}]},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "factory-empty-catalog","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}}},"factoryOptions": {"ttsModels": []},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
    {"id": "configured-repeated-namespace","input": {"text": "Plain speech fixture.","target": "audio-file","timeoutMs": 12345,"cfg": {},"rawConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "deepinfra/deepinfra/deepinfra/Qwen/Qwen3-TTS"}}}},"factoryOptions": {},"response": {"status": 200,"headers": {"Content-Type": "application/octet-stream"},"audioBase64": "UklGRgABAv8="}},
  ],
  talkConfig: [
    {"id": "talk-defaults","input": {"baseTtsConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech"}}},"talkProviderConfig": {}},"factoryOptions": {}},
    {"id": "talk-configured","input": {"baseTtsConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "hexgrad/Kokoro-82M","voice": "af_bella","speed": 0.9,"extraBody": {"base": true,"options": {"seed": 7}}}}},"talkProviderConfig": {"apiKey": "fixture-talk-speech","baseUrl": "https://talk.example/deepinfra/v2///","modelId": " deepinfra/Qwen/Qwen3-TTS ","voiceId": "talk-voice","speed": 1.2,"responseFormat": " FLAC ","extraBody": {"ignored": true}}},"factoryOptions": {}},
    {"id": "talk-speaker","input": {"baseTtsConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "ResembleAI/chatterbox-turbo","voice": "baseline-voice","extraBody": {"retained": true}}}},"talkProviderConfig": {"baseUrl": "https://api.deepinfra.com/v1/openai/","speakerVoice": " talk-speaker ","speakerVoiceId": "unused","voice": "unused","voiceId": "unused","responseFormat": " OPUS "}},"factoryOptions": {}},
    {"id": "talk-model-alias-unselected","input": {"baseTtsConfig": {"providers": {"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "sesame/csm-1b","speed": 0.9}}},"talkProviderConfig": {"model": "deepinfra/Qwen/Qwen3-TTS","speed": 0,"voiceId": " voice-id "}},"factoryOptions": {}},
    {"id": "talk-empty-nested-precedence","input": {"baseTtsConfig": {"providers": {"deepinfra": {}},"deepinfra": {"apiKey": "fixture-deepinfra-speech","model": "sesame/csm-1b","voice": "legacy-voice","extraBody": {"legacy": true}}},"talkProviderConfig": {}},"factoryOptions": {}},
  ],
  talkOverride: [
    {"id": "talk-id-overrides","input": {"params": {"voiceId": " vf ","voice": "ignored","modelId": " deepinfra/Qwen/Qwen3-TTS ","model": "ignored","speed": 1.25}},"factoryOptions": {}},
    {"id": "talk-alias-overrides","input": {"params": {"voice": " v ","model": " deepinfra/sesame/csm-1b ","speed": 0.9}},"factoryOptions": {}},
    {"id": "talk-blank-overrides","input": {"params": {"voice": " ","model": " "}},"factoryOptions": {}},
    {"id": "talk-blank-id-overrides","input": {"params": {"voiceId": " ","voice": "ignored-fallback","modelId": " ","model": "ignored-fallback","speed": 1.1}},"factoryOptions": {}},
  ],
  timeout: [
    {"id": "provider-default","input": {"config": {"timeoutMs": 30000,"timeoutMsSource": "default"}},"factoryOptions": {}},
    {"id": "configured-default","input": {"config": {"timeoutMs": 45000,"timeoutMsSource": "config"}},"factoryOptions": {}},
    {"id": "configured-standard","input": {"config": {"timeoutMs": 30000,"timeoutMsSource": "config"}},"factoryOptions": {}},
    {"id": "per-call","input": {"config": {"timeoutMs": 30000,"timeoutMsSource": "default"},"timeoutMs": 75000},"factoryOptions": {}},
  ],
};

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), DEEPINFRA_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', DEEPINFRA_SPEECH_PIN])
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
  return { verified: true, commit: DEEPINFRA_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${DEEPINFRA_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('DeepInfra capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class DeepInfraSpeechCapture {
  constructor(executables, originalData, recipe, kind) {
    Object.assign(this, { executables, originalData, recipe, kind });
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
        return called('normalizeResolvedSecretInputString', value, { path, ...(value === undefined ? {} : { value }) });
      },
      resolveProviderHttpRequestConfig: params => called('resolveProviderHttpRequestConfig', {
        headers: new Headers(params.defaultHeaders), allowPrivateNetwork: params.allowPrivateNetwork,
        dispatcherPolicy: params.dispatcherPolicy,
      }, { input: plain(params) }),
      postJsonRequest: async params => {
        called('postJsonRequest');
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
    else if (this.originalData.has(identifier)) {
      const data = JSON.parse(this.originalData.get(identifier));
      module = new vm.SyntheticModule(['default'], function () {
        this.setExport('default', data);
      }, { context: this.context, identifier });
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
    assert.ok(this.executables.has(resolved) || this.originalData.has(resolved) || Object.hasOwn(sdkFacades, resolved) || Object.hasOwn(boundaries, resolved),
      `declared source import: ${importer.identifier} -> ${specifier}`);
    provenance.push({ importer: importer.identifier, specifier, resolved });
    return this.module(resolved);
  }

  async run() {
    for (const path of [DEEPINFRA_SPEECH_SOURCE, timeoutSource]) {
      const module = this.module(path);
      await withDeadline(module.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
      await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    }
    this.context.speechSource = this.modules.get(DEEPINFRA_SPEECH_SOURCE).namespace;
    this.context.timeoutSource = this.modules.get(timeoutSource).namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    this.context.factoryOptions = plain(this.recipe.factoryOptions);
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildDeepInfraSpeechProvider(factoryOptions);
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
    for (const path of [...sourcePaths, manifestPath]) assert.equal(this.modules.get(path)?.status, 'evaluated', path);
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
    observation.factoryOptions = plain(this.recipe.factoryOptions);
    observation.factoryOptionsAfter = plain(this.context.factoryOptions);
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated'),
      evaluatedDataPaths: [manifestPath].filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureDeepInfraSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${DEEPINFRA_SPEECH_PIN}:${path}`], {
      timeout: 30_000, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete source bytes match pinned object: ${path}`);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
      git(root, ['rev-parse', `${DEEPINFRA_SPEECH_PIN}:${path}`]), path);
    return bytes;
  };
  const executables = new Map();
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${DEEPINFRA_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true };
  });
  const manifestBytes = readOriginal(manifestPath);
  const licenseBytes = readOriginal(licensePath);
  const originalData = new Map([[manifestPath, manifestBytes.toString()]]);
  const groups = {};
  for (const [kind, recipes] of Object.entries(recipeGroups)) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new DeepInfraSpeechCapture(executables, originalData, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluatedSourcePaths = unique(runs.flatMap(run => run.evaluatedSourcePaths));
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return { schemaVersion: 1, referencePin: DEEPINFRA_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-deepinfra-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [{ path: manifestPath, gitBlob: git(root, ['rev-parse', `${DEEPINFRA_SPEECH_PIN}:${manifestPath}`]),
      sourceSha256: hash(manifestBytes), usage: 'complete original JSON data module imported by original media-models.ts; exact default export supplies DeepInfra base URL; plugin registration unexecuted',
      loadedAs: 'vm.SyntheticModule default JSON.parse of complete pinned original bytes',
      evaluated: runs.every(run => run.evaluatedDataPaths.includes(manifestPath)) },
    { path: licensePath, gitBlob: git(root, ['rev-parse', `${DEEPINFRA_SPEECH_PIN}:${licensePath}`]),
      sourceSha256: hash(licenseBytes), usage: 'complete original source license provenance' }],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries: [...Object.entries(boundaries).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
      { module: 'globalThis', originalSourceExecuted: false, exports: globalBoundaries }],
    environmentFixture: { env: {}, cfg: {} },
    hostAdaptation: { config: 'Original raw nested/legacy config and overrides are oracle inputs; host implementation is unqualified.',
      response: 'Eight opaque bytes with MP3/Opus/FLAC/WAV/PCM source metadata; no audio decoding, codec validation, transcoding or native publication.',
      headers: 'Original header and policy arguments are provenance only; authentication and transport/security parity are untested.',
      talk: 'Ordinary provider resolveTalkConfig/resolveTalkOverrides callbacks only; actual Talk/channel pipeline unexecuted.' },
    counts: { observations: groups.synthesis.length, synthesisCallbacks: groups.synthesis.length, telephonyCallbacks: 0,
      httpRequests: groups.synthesis.length, releases: groups.synthesis.length, listVoicesCallbacks: groups.synthesis.length,
      talkConfigObservations: groups.talkConfig.length, talkOverrideObservations: groups.talkOverride.length,
      timeoutObservations: groups.timeout.length, totalObservations: runs.length, wholeModules: evaluatedSourcePaths.length,
      originalDataModules: originalData.size,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    limits: [
      'All 58,558 pinned tracked blobs verified before and after; complete source modules, plugin manifest and LICENSE additionally checked against pinned Git bytes and hashes.',
      'Whole-module execution means evaluation, not all exports; original factory, resolveConfig, listVoices, synthesize, resolveTalkConfig and resolveTalkOverrides execute.',
      'Original DeepInfra media-models.ts imports the complete original manifest as a JSON data module; only the TypeScript modules receive type erasure. No source algorithms are sliced or substituted.',
      'Default, explicit empty and nondefault ttsModels factory options are retained before/after; all five declared formats execute for both audio-file and voice-note targets.',
      'Pure SDK facades contain export wiring only; actual normalization, config-path helper and directive-parser construction execute. Directive dispatch and isConfigured are unexecuted.',
      'Original complete timeout resolver receives the actual provider object; resolvePositiveTimeoutMs and original clampTimerTimeoutMs execute for ordinary positive default/config/per-call inputs.',
      'Unrelated timeout-resolver registry/settings/speaker/voice helpers are explicit uninvoked throwing bindings; DEFAULT_TTS_TIMEOUT_MS is undefined and its fallback branch is unused.',
      'Fresh per-vector VM process.env={} and cfg={}; only explicit fixture keys cross a synthetic secret boundary. Production secrets, ambient credentials and plugin loading are unexecuted.',
      'Original synthesis constructs URL, Headers inputs, JSON body and timeout; synthetic provider HTTP returns an opaque successful response and counted release. Global fetch is a passed-through uninvoked throwing binding.',
      'Provider HTTP configuration, status handling and binary reader originals are unexecuted; policy flags, fetchFn, supplied cap and callback presence are provenance only, with no security or budget claim.',
      '12345 ms is the synthesis request timeout; the separate original timeout resolver observes the 120000 ms provider default, explicit configured 45000/30000 ms, and per-call 75000 ms. 2000 ms bounds VM/capture execution only.',
      'Talk configuration callbacks preserve ordinary inputs/results; actual Talk/channel pipeline and telephony are unexecuted. Voice-note target does not establish native publication.',
      'No security/permission/authentication/TLS, negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
    observations: groups.synthesis.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverride.map(run => run.observation),
    timeoutObservations: groups.timeout.map(run => run.observation) };
}

export async function writeDeepInfraSpeechCapture(root, output) {
  const capture = await captureDeepInfraSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c';
  let output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-deepinfra-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeDeepInfraSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureDeepInfraSpeech(root), null, 2) + '\n');
}
