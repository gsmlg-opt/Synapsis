// Independent source-derived literals for successful ordinary Speech callbacks only.
// The parent freezes candidates before execution; no temp file is read by this test.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  captureOpenAISpeechContract, OPENAI_SPEECH_CONTRACT_CASES,
  OPENAI_SPEECH_CONTRACT_PIN, OPENAI_SPEECH_CONTRACT_SOURCE,
} from './capture-openai-speech-contract.mjs';

const root = process.env.OPENCLAW_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const fixtureUrl = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-speech-contract.json', import.meta.url);
const rawInputs = {
  "config": [
    {"id":"root-defaults","input":{"rawConfig":{"apiKey":"fixture-openai-speech"}}},
    {"id":"providers-openai-precedence","input":{"rawConfig":{"apiKey":"fixture-openai-speech","model":"tts-1","voice":"alloy","openai":{"apiKey":"fixture-openai-speech","model":"tts-1-hd","voice":"echo"},"providers":{"openai":{"apiKey":"fixture-openai-speech","model":"gpt-4o-mini-tts-2025-12-15","voice":"marin"}}}}},
    {"id":"openai-over-root","input":{"rawConfig":{"apiKey":"fixture-openai-speech","model":"tts-1","voice":"alloy","openai":{"apiKey":"fixture-openai-speech","model":"tts-1-hd","voice":"echo"}}}},
    {"id":"providers-empty-override","input":{"rawConfig":{"apiKey":"fixture-openai-speech","model":"tts-1","openai":{"apiKey":"fixture-openai-speech","voice":"alloy"},"providers":{"openai":{}}}}},
    {"id":"openai-empty-override","input":{"rawConfig":{"apiKey":"fixture-openai-speech","model":"tts-1","openai":{}}}},
    {"id":"providers-empty-container-falls-to-openai","input":{"rawConfig":{"apiKey":"fixture-openai-speech","providers":{},"openai":{"apiKey":"fixture-openai-speech","voice":"sage"}}}},
    {"id":"trim-fields-and-url-trails","input":{"rawConfig":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":" studio-tts ","voice":" Studio Voice ","speed":1.3,"instructions":" Speak clearly. ","responseFormat":" WAV "}}},
    {"id":"blank-optional-fields","input":{"rawConfig":{"apiKey":"fixture-openai-speech","baseUrl":"  ","model":"  ","voice":"  ","instructions":"  ","responseFormat":"  ","extraBody":{}}}},
    {"id":"camel-extra-body-precedence","input":{"rawConfig":{"apiKey":"fixture-openai-speech","extraBody":{"language":"ja","seed":17},"extra_body":{"language":"en","seed":23}}}},
    {"id":"empty-camel-extra-body-falls-to-snake","input":{"rawConfig":{"apiKey":"fixture-openai-speech","extraBody":{},"extra_body":{"language":"fr","seed":31}}}},
    {"id":"snake-extra-body","input":{"rawConfig":{"apiKey":"fixture-openai-speech","extra_body":{"language":"zh","metadata":{"project":"speech"}}}}},
    {"id":"optional-speed-and-instructions","input":{"rawConfig":{"apiKey":"fixture-openai-speech","speed":1.45,"instructions":"  Calm reading.  ","responseFormat":" OpUs "}}},
    {"id":"ecmascript-bom-nbsp-trimming","input":{"rawConfig":{"apiKey":"fixture-openai-speech","baseUrl":"﻿ https://speech.example.test/v1/// ﻿","model":"﻿ studio-tts ﻿","voice":"﻿ Studio Voice ﻿","instructions":"﻿ Speak clearly. ﻿"}}}
  ],
  "talkConfig": [
    {"id":"inherit-normalized-base","input":{"baseTtsConfig":{"providers":{"openai":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":" Base direction. ","responseFormat":" OPUS ","extra_body":{"language":"en","seed":9}}}},"talkProviderConfig":{}}},
    {"id":"explicit-talk-fields","input":{"baseTtsConfig":{"providers":{"openai":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":" Base direction. ","responseFormat":" OPUS ","extra_body":{"language":"en","seed":9}}}},"talkProviderConfig":{"apiKey":"fixture-openai-speech","baseUrl":" https://talk.example.test/v2/// ","modelId":" talk-tts ","voiceId":" Talk Voice ","speed":1.55,"instructions":" Talk direction. ","responseFormat":" WAV "}}},
    {"id":"blank-talk-fields-inherit","input":{"baseTtsConfig":{"providers":{"openai":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":" Base direction. ","responseFormat":" OPUS ","extra_body":{"language":"en","seed":9}}}},"talkProviderConfig":{"baseUrl":" ","modelId":" ","voiceId":" ","instructions":" ","responseFormat":" "}}},
    {"id":"talk-extra-body-is-inherited","input":{"baseTtsConfig":{"providers":{"openai":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":" Base direction. ","responseFormat":" OPUS ","extra_body":{"language":"en","seed":9}}}},"talkProviderConfig":{"extraBody":{"language":"de"},"extra_body":{"seed":42}}}},
    {"id":"talk-model-and-voice-ids-only","input":{"baseTtsConfig":{"apiKey":"fixture-openai-speech","model":"tts-1","voice":"alloy"},"talkProviderConfig":{"modelId":" tts-1-hd ","voiceId":" echo ","model":"gpt-4o-mini-tts","voice":"nova"}}},
    {"id":"explicit-format-speed-instructions","input":{"baseTtsConfig":{"apiKey":"fixture-openai-speech"},"talkProviderConfig":{"responseFormat":" MP3 ","speed":1.65,"instructions":"  Friendly voice. "}}}
  ],
  "talkOverrides": [
    {"id":"empty-params","input":{"params":{}}},
    {"id":"trim-model-voice-finite-speed","input":{"params":{"voiceId":" nova ","modelId":" tts-1-hd ","speed":1.35}}},
    {"id":"blank-ids-omit-fields","input":{"params":{"voiceId":"  ","modelId":"  "}}},
    {"id":"only-supported-id-fields","input":{"params":{"voice":"alloy","model":"tts-1","voiceId":" sage ","speed":1.4,"instructions":"not a Talk override"}}}
  ],
  "synthesis": [
    {"id":"model-mini","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"model-dated-mini","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts-2025-12-15","voice":"coral","instructions":"  Even pacing.  "},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"model-tts-1","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"tts-1","voice":"coral","instructions":"Even pacing."},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"model-tts-1-hd","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"tts-1-hd","voice":"coral","instructions":"Even pacing."},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-alloy","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"alloy"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-ash","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"ash"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-ballad","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"ballad"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-cedar","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"cedar"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-coral","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-echo","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"echo"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-fable","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"fable"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-juniper","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"juniper"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-marin","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"marin"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-onyx","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"onyx"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-nova","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"nova"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-sage","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"sage"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-shimmer","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"shimmer"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-verse","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"verse"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"voice-note-default-opus","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"file-configured-opus","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":" OpUs "},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"file-configured-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":" WAV "},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"note-configured-mp3","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":"mp3"},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"note-configured-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":"wav"},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"ordinary-telephony-target-default-mp3","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"text":"Ordinary speech.","target":"telephony","timeoutMs":12345}},
    {"id":"groq-file-default-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.groq.com/openai/v1","model":"playai-tts","voice":"Fritz-PlayAI"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"groq-note-default-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.groq.com/openai/v1","model":"playai-tts","voice":"Fritz-PlayAI"},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"groq-explicit-opus","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.groq.com/openai/v1","model":"playai-tts","voice":"Fritz-PlayAI","responseFormat":"opus"},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"groq-root-host-default-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://groq.com/openai/v1","model":"playai-tts","voice":"Fritz-PlayAI"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"custom-model-voice-instructions-speed","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.75,"instructions":"  Read warmly.  "},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"resolved-url-retains-trails","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"provider-overrides-model-voice-speed","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"tts-1","voice":"alloy","speed":1.1,"instructions":" Read evenly. "},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{"model":" gpt-4o-mini-tts ","voice":" nova ","speed":1.6}}},
    {"id":"blank-provider-overrides-inherit","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","speed":1.15},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{"model":"  ","voice":"  "}}},
    {"id":"resolved-snake-extra-body","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","extra_body":{"language":"ja","seed":5}},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"extra-body-final-wire-precedence","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","speed":1.1,"instructions":"Config instruction.","extraBody":{"model":"tts-1-hd","input":"Replacement speech.","voice":"echo","response_format":"wav","speed":1.7,"instructions":"Final instruction.","language":"en"}},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"raw-unicode-text-preserved","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"text":"  你好，世界 🌍\nCafé — é\tfin.  ","target":"audio-file","timeoutMs":23456}},
    {"id":"raw-normalize-then-synthesize","input":{"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345,"mode":"normalizeThenSynthesize","rawConfig":{"providers":{"openai":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":" studio-tts ","voice":" Studio Voice ","speed":1.25,"responseFormat":" WAV "}}}}},
    {"id":"talk-resolve-then-synthesize-retains-trails","input":{"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345,"mode":"resolveTalkThenSynthesize","baseTtsConfig":{"apiKey":"fixture-openai-speech","baseUrl":" https://speech.example.test/v1/// ","model":"studio-tts","voice":"Studio Voice","responseFormat":"wav"},"talkProviderConfig":{"baseUrl":" https://talk.example.test/v2/// ","voiceId":" Talk Voice ","speed":1.3,"instructions":" Talk direction. "}}},
    {"id":"resolved-official-url-retains-trails","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":" https://api.openai.com/v1/// ","model":"tts-1","voice":"alloy"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"custom-speed-and-fractional-timeout","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":4.5},"text":"Ordinary speech.","target":"audio-file","timeoutMs":23456.75}}
  ],
  "telephony": [
    {"id":"telephony-pcm-overrides-configured-wav","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":"wav"},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}},
    {"id":"telephony-custom-model-speed-instructions","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.4,"instructions":" Clear calls. "},"text":"Ordinary speech.","target":"voice-note","timeoutMs":12345}},
    {"id":"telephony-extra-body-final-precedence","input":{"providerConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":"opus","extraBody":{"response_format":"wav","voice":"echo","language":"en"}},"text":"Ordinary speech.","target":"audio-file","timeoutMs":12345}}
  ],
  "voices": [
    {"id":"all-fourteen-voices","input":{}}
  ]
};

const literalExpected = {
  "config": [
    {"id":"root-defaults","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"requests":[],"releaseCount":0}},
    {"id":"providers-openai-precedence","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts-2025-12-15","voice":"marin"},"requests":[],"releaseCount":0}},
    {"id":"openai-over-root","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"tts-1-hd","voice":"echo"},"requests":[],"releaseCount":0}},
    {"id":"providers-empty-override","expected":{"result":{"baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"requests":[],"releaseCount":0}},
    {"id":"openai-empty-override","expected":{"result":{"baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"requests":[],"releaseCount":0}},
    {"id":"providers-empty-container-falls-to-openai","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"sage"},"requests":[],"releaseCount":0}},
    {"id":"trim-fields-and-url-trails","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.3,"instructions":"Speak clearly.","responseFormat":"wav"},"requests":[],"releaseCount":0}},
    {"id":"blank-optional-fields","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral"},"requests":[],"releaseCount":0}},
    {"id":"camel-extra-body-precedence","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","extraBody":{"language":"ja","seed":17}},"requests":[],"releaseCount":0}},
    {"id":"empty-camel-extra-body-falls-to-snake","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","extraBody":{"language":"fr","seed":31}},"requests":[],"releaseCount":0}},
    {"id":"snake-extra-body","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","extraBody":{"language":"zh","metadata":{"project":"speech"}}},"requests":[],"releaseCount":0}},
    {"id":"optional-speed-and-instructions","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","speed":1.45,"instructions":"Calm reading.","responseFormat":"opus"},"requests":[],"releaseCount":0}},
    {"id":"ecmascript-bom-nbsp-trimming","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","instructions":"Speak clearly."},"requests":[],"releaseCount":0}}
  ],
  "talkConfig": [
    {"id":"inherit-normalized-base","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":"Base direction.","responseFormat":"opus","extraBody":{"language":"en","seed":9}},"requests":[],"releaseCount":0}},
    {"id":"explicit-talk-fields","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://talk.example.test/v2///","model":"talk-tts","voice":"Talk Voice","speed":1.55,"instructions":"Talk direction.","responseFormat":"wav","extraBody":{"language":"en","seed":9}},"requests":[],"releaseCount":0}},
    {"id":"blank-talk-fields-inherit","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":"Base direction.","responseFormat":"opus","extraBody":{"language":"en","seed":9}},"requests":[],"releaseCount":0}},
    {"id":"talk-extra-body-is-inherited","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.2,"instructions":"Base direction.","responseFormat":"opus","extraBody":{"language":"en","seed":9}},"requests":[],"releaseCount":0}},
    {"id":"talk-model-and-voice-ids-only","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"tts-1-hd","voice":"echo"},"requests":[],"releaseCount":0}},
    {"id":"explicit-format-speed-instructions","expected":{"result":{"apiKey":"fixture-openai-speech","baseUrl":"https://api.openai.com/v1","model":"gpt-4o-mini-tts","voice":"coral","responseFormat":"mp3","speed":1.65,"instructions":"Friendly voice."},"requests":[],"releaseCount":0}}
  ],
  "talkOverrides": [
    {"id":"empty-params","expected":{"result":{},"requests":[],"releaseCount":0}},
    {"id":"trim-model-voice-finite-speed","expected":{"result":{"voice":"nova","model":"tts-1-hd","speed":1.35},"requests":[],"releaseCount":0}},
    {"id":"blank-ids-omit-fields","expected":{"result":{},"requests":[],"releaseCount":0}},
    {"id":"only-supported-id-fields","expected":{"result":{"voice":"sage","speed":1.4},"requests":[],"releaseCount":0}}
  ],
  "synthesis": [
    {"id":"model-mini","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"model-dated-mini","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts-2025-12-15","input":"Ordinary speech.","voice":"coral","response_format":"mp3","instructions":"Even pacing."},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"model-tts-1","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"tts-1","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"model-tts-1-hd","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"tts-1-hd","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-alloy","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"alloy","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-ash","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"ash","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-ballad","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"ballad","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-cedar","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"cedar","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-coral","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-echo","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"echo","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-fable","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"fable","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-juniper","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"juniper","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-marin","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"marin","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-onyx","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"onyx","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-nova","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"nova","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-sage","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"sage","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-shimmer","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"shimmer","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-verse","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"verse","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"voice-note-default-opus","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"opus"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"file-configured-opus","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"opus"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"file-configured-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"wav"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"note-configured-mp3","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":true},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"note-configured-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"wav"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"ordinary-telephony-target-default-mp3","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"groq-file-default-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://api.groq.com/openai/v1/audio/speech","method":"POST","body":{"model":"playai-tts","input":"Ordinary speech.","voice":"Fritz-PlayAI","response_format":"wav"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"groq-note-default-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://api.groq.com/openai/v1/audio/speech","method":"POST","body":{"model":"playai-tts","input":"Ordinary speech.","voice":"Fritz-PlayAI","response_format":"wav"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"groq-explicit-opus","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"requests":[{"url":"https://api.groq.com/openai/v1/audio/speech","method":"POST","body":{"model":"playai-tts","input":"Ordinary speech.","voice":"Fritz-PlayAI","response_format":"opus"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"groq-root-host-default-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://groq.com/openai/v1/audio/speech","method":"POST","body":{"model":"playai-tts","input":"Ordinary speech.","voice":"Fritz-PlayAI","response_format":"wav"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"custom-model-voice-instructions-speed","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://speech.example.test/v1/audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Studio Voice","response_format":"mp3","speed":1.75,"instructions":"Read warmly."},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"resolved-url-retains-trails","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://speech.example.test/v1////audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Studio Voice","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"provider-overrides-model-voice-speed","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"nova","response_format":"mp3","speed":1.6,"instructions":"Read evenly."},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"blank-provider-overrides-inherit","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3","speed":1.15},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"resolved-snake-extra-body","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"mp3","language":"ja","seed":5},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"extra-body-final-wire-precedence","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"tts-1-hd","input":"Replacement speech.","voice":"echo","response_format":"wav","speed":1.7,"instructions":"Final instruction.","language":"en"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"raw-unicode-text-preserved","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"  你好，世界 🌍\nCafé — é\tfin.  ","voice":"coral","response_format":"mp3"},"timeoutMs":23456}],"releaseCount":1}},
    {"id":"raw-normalize-then-synthesize","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://speech.example.test/v1/audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Studio Voice","response_format":"wav","speed":1.25},"timeoutMs":12345}],"releaseCount":1,"resolvedConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://speech.example.test/v1","model":"studio-tts","voice":"Studio Voice","speed":1.25,"responseFormat":"wav"}}},
    {"id":"talk-resolve-then-synthesize-retains-trails","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"requests":[{"url":"https://talk.example.test/v2////audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Talk Voice","response_format":"wav","speed":1.3,"instructions":"Talk direction."},"timeoutMs":12345}],"releaseCount":1,"resolvedConfig":{"apiKey":"fixture-openai-speech","baseUrl":"https://talk.example.test/v2///","model":"studio-tts","voice":"Talk Voice","responseFormat":"wav","speed":1.3,"instructions":"Talk direction."}}},
    {"id":"resolved-official-url-retains-trails","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://api.openai.com/v1////audio/speech","method":"POST","body":{"model":"tts-1","input":"Ordinary speech.","voice":"alloy","response_format":"mp3"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"custom-speed-and-fractional-timeout","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"requests":[{"url":"https://speech.example.test/v1/audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Studio Voice","response_format":"mp3","speed":4.5},"timeoutMs":23456.75}],"releaseCount":1}}
  ],
  "telephony": [
    {"id":"telephony-pcm-overrides-configured-wav","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":24000},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"coral","response_format":"pcm"},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"telephony-custom-model-speed-instructions","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":24000},"requests":[{"url":"https://speech.example.test/v1/audio/speech","method":"POST","body":{"model":"studio-tts","input":"Ordinary speech.","voice":"Studio Voice","response_format":"pcm","speed":1.4,"instructions":"Clear calls."},"timeoutMs":12345}],"releaseCount":1}},
    {"id":"telephony-extra-body-final-precedence","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":24000},"requests":[{"url":"https://api.openai.com/v1/audio/speech","method":"POST","body":{"model":"gpt-4o-mini-tts","input":"Ordinary speech.","voice":"echo","response_format":"wav","language":"en"},"timeoutMs":12345}],"releaseCount":1}}
  ],
  "voices": [
    {"id":"all-fourteen-voices","expected":{"result":[{"id":"alloy","name":"alloy"},{"id":"ash","name":"ash"},{"id":"ballad","name":"ballad"},{"id":"cedar","name":"cedar"},{"id":"coral","name":"coral"},{"id":"echo","name":"echo"},{"id":"fable","name":"fable"},{"id":"juniper","name":"juniper"},{"id":"marin","name":"marin"},{"id":"onyx","name":"onyx"},{"id":"nova","name":"nova"},{"id":"sage","name":"sage"},{"id":"shimmer","name":"shimmer"},{"id":"verse","name":"verse"}],"requests":[],"releaseCount":0}}
  ]
};

const metadataExpected = {
  "id": "openai",
  "label": "OpenAI",
  "autoSelectOrder": 10,
  "defaultModel": "gpt-4o-mini-tts",
  "models": [
    "gpt-4o-mini-tts",
    "gpt-4o-mini-tts-2025-12-15",
    "tts-1",
    "tts-1-hd"
  ],
  "voices": [
    "alloy",
    "ash",
    "ballad",
    "cedar",
    "coral",
    "echo",
    "fable",
    "juniper",
    "marin",
    "onyx",
    "nova",
    "sage",
    "shimmer",
    "verse"
  ],
  "callbacks": [
    "resolveConfig",
    "parseDirectiveToken",
    "resolveTalkConfig",
    "resolveTalkOverrides",
    "listVoices",
    "isConfigured",
    "isConfiguredAsync",
    "synthesize",
    "synthesizeTelephony"
  ],
  "absentFields": [
    "aliases",
    "defaultTimeoutMs",
    "prepareSynthesis",
    "streamSynthesize"
  ]
};

// Full tracked pinned checkout bytes, symlink targets and executable modes are
// checked independently before/after capture, including unexecuted source files.
function trackedSourceSnapshot() {
  const entries = execFileSync('git', ['ls-tree', '-rz', '--full-tree', pin], {
    cwd: root, maxBuffer: 64 * 1024 * 1024, timeout: 30000,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  }).toString().split('\0').filter(Boolean);
  return entries.map(entry => {
    const [header, path] = entry.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob', path);
    const file = join(root, path), stat = lstatSync(file);
    assert.equal(stat.isSymbolicLink(), mode === '120000', path);
    if (!stat.isSymbolicLink()) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', path);
    const bytes = stat.isSymbolicLink() ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, mode, gitBlob: blob, sha256: hash(bytes) };
  });
}
const sourceBefore = trackedSourceSnapshot();
const capture = await captureOpenAISpeechContract(root);
const sourceAfter = trackedSourceSnapshot();
const sourcePaths = [
  'extensions/openai/speech-provider.ts', 'extensions/openai/realtime-provider-shared.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/record-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts', 'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts', 'src/media/audio.ts', 'packages/media-core/src/mime.ts',
  'packages/media-core/src/constants.ts', 'packages/media-core/src/file-name.ts',
];

test('complete ordinary factory metadata remains source-derived', () => {
  assert.equal(OPENAI_SPEECH_CONTRACT_PIN, pin);
  assert.equal(OPENAI_SPEECH_CONTRACT_SOURCE, sourcePaths[0]);
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.sourcePin, pin);
  assert.deepEqual(capture.metadata, metadataExpected);
});

test('all66 independent ordinary callback inputs and literal expectations match', () => {
  assert.deepEqual(OPENAI_SPEECH_CONTRACT_CASES, rawInputs);
  assert.deepEqual(Object.keys(capture.observations), Object.keys(rawInputs));
  assert.deepEqual(Object.fromEntries(Object.entries(rawInputs).map(([name, rows]) => [name, rows.length])),
    { config:13, talkConfig:6, talkOverrides:4, synthesis:39, telephony:3, voices:1 });
  for (const [group, rows] of Object.entries(rawInputs)) {
    const actual = capture.observations[group], expected = literalExpected[group];
    assert.deepEqual(actual.map(row => row.id), rows.map(row => row.id), group);
    assert.deepEqual(expected.map(row => row.id), rows.map(row => row.id), group);
    for (let index = 0; index < rows.length; index += 1) {
      const row = actual[index], input = rows[index].input, want = expected[index].expected;
      assert.deepEqual(row.input, input, row.id);
      assert.deepEqual(row.inputAfter, input, row.id + ': unchanged input');
      for (const [field, value] of Object.entries(want)) assert.deepEqual(row[field], value, row.id + ': ' + field);
      if (!Object.hasOwn(want, 'resolvedConfig')) assert.equal(Object.hasOwn(row, 'resolvedConfig'), false, row.id);
      if (group === 'synthesis' || group === 'telephony') {
        assert.deepEqual(row.synthesisRequestAfter, row.synthesisRequest, row.id + ': unchanged request');
        assert.equal(row.requests.length, 1, row.id);
        for (const name of ['resolveGeneratedMediaMaxBytes','fetchWithSsrFGuard','readProviderBinaryResponse','captureHttpExchangeAsync','release']) {
          assert.equal(row.platformCalls.filter(call => call.export === name).length, 1, row.id + ': ' + name);
        }
      } else assert.equal(row.requests.length, 0, row.id);
    }
  }
});

test('complete pinned source modules use only TypeScript erasure and remain unchanged', () => {
  assert.deepEqual(sourceAfter, sourceBefore);
  assert.equal(sourceBefore.length, 58558);
  assert.deepEqual(capture.sourceIntegrity.after, capture.sourceIntegrity.before);
  for (const side of ['before','after']) {
    const integrity = capture.sourceIntegrity[side];
    assert.equal(integrity.verified, true);
    assert.equal(integrity.commit, pin);
    assert.equal(integrity.verifiedTrackedFiles, sourceBefore.length);
    assert.equal(integrity.filesSha256, hash(JSON.stringify(sourceBefore)));
    assert.equal(integrity.tree, execFileSync('git', ['rev-parse', `${pin}^{tree}`], { cwd:root, encoding:'utf8', timeout:30000 }).trim());
  }
  assert.equal(capture.harness.path, 'scripts/openclaw/capture-openai-speech-contract.mjs');
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-openai-speech-contract.mjs', import.meta.url))));
  assert.equal(capture.transformation.api, 'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options, { mode:'transform', sourceMap:false });
  assert.deepEqual(capture.transformation.sdkFacades.map(item => item.module), [
    'openclaw/plugin-sdk/speech-provider','openclaw/plugin-sdk/string-coerce-runtime',
    'openclaw/plugin-sdk/number-runtime','@openclaw/normalization-core/number-coercion',
    '@openclaw/normalization-core/string-coerce','openclaw/plugin-sdk/media-runtime','@openclaw/media-core/mime',
  ]);
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source), facade.module);
    assert.ok(facade.source.split('\n').every(line => /^export (?:\*|\{[^}]+\}) from '[^']+';$/.test(line)), facade.module);
  }
  assert.ok(capture.transformation.staticImports.some(item => item.importer === 'packages/normalization-core/src/number-coercion.ts' && item.resolved === 'packages/normalization-core/src/string-coerce.ts'));
  assert.deepEqual(capture.transformation.dynamicImports.map(item => item.specifier), [
    'openclaw/plugin-sdk/media-generation-runtime','openclaw/plugin-sdk/provider-http',
    'openclaw/plugin-sdk/proxy-capture','openclaw/plugin-sdk/ssrf-runtime','openclaw/plugin-sdk/media-runtime',
  ]);
  assert.deepEqual(capture.sourceAudit.map(item => item.path), sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root, audit.path));
    const tracked = sourceBefore.find(file => file.path === audit.path);
    assert.equal(audit.gitBlob, tracked.gitBlob, audit.path);
    assert.equal(audit.sourceSha256, hash(bytes), audit.path);
    assert.equal(audit.sourceBytes, bytes.length, audit.path);
    assert.deepEqual(audit.readRange, { startLine:1, endLine:bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0) }, audit.path);
    assert.equal(audit.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode:'transform', sourceMap:false })), audit.path);
    assert.equal(audit.wholeModule, true, audit.path);
    assert.equal(audit.executed, true, audit.path);
  }
});

test('synthetic successful HTTP and original media compatibility boundaries are explicit', () => {
  assert.deepEqual(capture.platformBoundaries.map(item => item.module), [
    'openclaw/plugin-sdk/secret-input', 'openclaw/plugin-sdk/provider-http',
    'openclaw/plugin-sdk/media-generation-runtime', 'openclaw/plugin-sdk/proxy-capture',
    'openclaw/plugin-sdk/ssrf-runtime', 'node:path',
  ]);
  const descriptions = capture.platformBoundaries.map(item => JSON.stringify(item)).join('\n');
  for (const phrase of ['synthetic','eight','no network','unexecuted']) assert.ok(descriptions.toLowerCase().includes(phrase), phrase);
  const limits = (capture.limits.join('\n') + JSON.stringify(capture.globalBoundaries)).toLowerCase();
  for (const phrase of ['codec','directive','environment','readiness','synthetic']) assert.ok(limits.includes(phrase), phrase);
  const synthesis = Object.fromEntries(capture.observations.synthesis.map(row => [row.id, row]));
  assert.equal(synthesis['note-configured-mp3'].result.voiceCompatible, true);
  assert.equal(synthesis['voice-note-default-opus'].result.voiceCompatible, true);
  assert.equal(synthesis['note-configured-wav'].result.voiceCompatible, false);
  assert.equal(synthesis['file-configured-opus'].result.voiceCompatible, false);
  assert.equal(synthesis['model-mini'].result.voiceCompatible, false);
});

test('full fresh captures equal the frozen independent contract fixture', async () => {
  const frozen = JSON.parse(readFileSync(fixtureUrl));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureOpenAISpeechContract(root), frozen);
  assert.deepEqual(trackedSourceSnapshot(), sourceBefore);
});
