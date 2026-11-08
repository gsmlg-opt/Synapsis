defmodule Synapsis.Provider.Speech.OpenAIContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.OpenAI

  @moduletag timeout: 90_000

  # Independent frozen341 raw inputs and literal oracle are embedded unchanged.
  # No production output, source capture, or /tmp runtime dependency supplies expectations.
  # UklGRgABAv8= is eight opaque transport bytes, not a valid codec fixture.
  @raw Jason.decode!(~S"""
       {
       "config": [
         {
           "id": "root-defaults",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech"
             }
           }
         },
         {
           "id": "providers-openai-precedence",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "voice": "alloy",
               "openai": {
                 "apiKey": "fixture-openai-speech",
                 "model": "tts-1-hd",
                 "voice": "echo"
               },
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "model": "gpt-4o-mini-tts-2025-12-15",
                   "voice": "marin"
                 }
               }
             }
           }
         },
         {
           "id": "openai-over-root",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "voice": "alloy",
               "openai": {
                 "apiKey": "fixture-openai-speech",
                 "model": "tts-1-hd",
                 "voice": "echo"
               }
             }
           }
         },
         {
           "id": "providers-empty-override",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "openai": {
                 "apiKey": "fixture-openai-speech",
                 "voice": "alloy"
               },
               "providers": {
                 "openai": {}
               }
             }
           }
         },
         {
           "id": "openai-empty-override",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "openai": {}
             }
           }
         },
         {
           "id": "providers-empty-container-falls-to-openai",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "providers": {},
               "openai": {
                 "apiKey": "fixture-openai-speech",
                 "voice": "sage"
               }
             }
           }
         },
         {
           "id": "trim-fields-and-url-trails",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://speech.example.test/v1/// ",
               "model": " studio-tts ",
               "voice": " Studio Voice ",
               "speed": 1.3,
               "instructions": " Speak clearly. ",
               "responseFormat": " WAV "
             }
           }
         },
         {
           "id": "blank-optional-fields",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "  ",
               "model": "  ",
               "voice": "  ",
               "instructions": "  ",
               "responseFormat": "  ",
               "extraBody": {}
             }
           }
         },
         {
           "id": "camel-extra-body-precedence",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "extraBody": {
                 "language": "ja",
                 "seed": 17
               },
               "extra_body": {
                 "language": "en",
                 "seed": 23
               }
             }
           }
         },
         {
           "id": "empty-camel-extra-body-falls-to-snake",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "extraBody": {},
               "extra_body": {
                 "language": "fr",
                 "seed": 31
               }
             }
           }
         },
         {
           "id": "snake-extra-body",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "extra_body": {
                 "language": "zh",
                 "metadata": {
                   "project": "speech"
                 }
               }
             }
           }
         },
         {
           "id": "optional-speed-and-instructions",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "speed": 1.45,
               "instructions": "  Calm reading.  ",
               "responseFormat": " OpUs "
             }
           }
         },
         {
           "id": "ecmascript-bom-nbsp-trimming",
           "input": {
             "rawConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "﻿ https://speech.example.test/v1/// ﻿",
               "model": "﻿ studio-tts ﻿",
               "voice": "﻿ Studio Voice ﻿",
               "instructions": "﻿ Speak clearly. ﻿"
             }
           }
         }
       ],
       "talkConfig": [
         {
           "id": "inherit-normalized-base",
           "input": {
             "baseTtsConfig": {
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "baseUrl": " https://speech.example.test/v1/// ",
                   "model": "studio-tts",
                   "voice": "Studio Voice",
                   "speed": 1.2,
                   "instructions": " Base direction. ",
                   "responseFormat": " OPUS ",
                   "extra_body": {
                     "language": "en",
                     "seed": 9
                   }
                 }
               }
             },
             "talkProviderConfig": {}
           }
         },
         {
           "id": "explicit-talk-fields",
           "input": {
             "baseTtsConfig": {
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "baseUrl": " https://speech.example.test/v1/// ",
                   "model": "studio-tts",
                   "voice": "Studio Voice",
                   "speed": 1.2,
                   "instructions": " Base direction. ",
                   "responseFormat": " OPUS ",
                   "extra_body": {
                     "language": "en",
                     "seed": 9
                   }
                 }
               }
             },
             "talkProviderConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://talk.example.test/v2/// ",
               "modelId": " talk-tts ",
               "voiceId": " Talk Voice ",
               "speed": 1.55,
               "instructions": " Talk direction. ",
               "responseFormat": " WAV "
             }
           }
         },
         {
           "id": "blank-talk-fields-inherit",
           "input": {
             "baseTtsConfig": {
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "baseUrl": " https://speech.example.test/v1/// ",
                   "model": "studio-tts",
                   "voice": "Studio Voice",
                   "speed": 1.2,
                   "instructions": " Base direction. ",
                   "responseFormat": " OPUS ",
                   "extra_body": {
                     "language": "en",
                     "seed": 9
                   }
                 }
               }
             },
             "talkProviderConfig": {
               "baseUrl": " ",
               "modelId": " ",
               "voiceId": " ",
               "instructions": " ",
               "responseFormat": " "
             }
           }
         },
         {
           "id": "talk-extra-body-is-inherited",
           "input": {
             "baseTtsConfig": {
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "baseUrl": " https://speech.example.test/v1/// ",
                   "model": "studio-tts",
                   "voice": "Studio Voice",
                   "speed": 1.2,
                   "instructions": " Base direction. ",
                   "responseFormat": " OPUS ",
                   "extra_body": {
                     "language": "en",
                     "seed": 9
                   }
                 }
               }
             },
             "talkProviderConfig": {
               "extraBody": {
                 "language": "de"
               },
               "extra_body": {
                 "seed": 42
               }
             }
           }
         },
         {
           "id": "talk-model-and-voice-ids-only",
           "input": {
             "baseTtsConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "voice": "alloy"
             },
             "talkProviderConfig": {
               "modelId": " tts-1-hd ",
               "voiceId": " echo ",
               "model": "gpt-4o-mini-tts",
               "voice": "nova"
             }
           }
         },
         {
           "id": "explicit-format-speed-instructions",
           "input": {
             "baseTtsConfig": {
               "apiKey": "fixture-openai-speech"
             },
             "talkProviderConfig": {
               "responseFormat": " MP3 ",
               "speed": 1.65,
               "instructions": "  Friendly voice. "
             }
           }
         }
       ],
       "talkOverrides": [
         {
           "id": "empty-params",
           "input": {
             "params": {}
           }
         },
         {
           "id": "trim-model-voice-finite-speed",
           "input": {
             "params": {
               "voiceId": " nova ",
               "modelId": " tts-1-hd ",
               "speed": 1.35
             }
           }
         },
         {
           "id": "blank-ids-omit-fields",
           "input": {
             "params": {
               "voiceId": "  ",
               "modelId": "  "
             }
           }
         },
         {
           "id": "only-supported-id-fields",
           "input": {
             "params": {
               "voice": "alloy",
               "model": "tts-1",
               "voiceId": " sage ",
               "speed": 1.4,
               "instructions": "not a Talk override"
             }
           }
         }
       ],
       "synthesis": [
         {
           "id": "model-mini",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "model-dated-mini",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts-2025-12-15",
               "voice": "coral",
               "instructions": "  Even pacing.  "
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "model-tts-1",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "tts-1",
               "voice": "coral",
               "instructions": "Even pacing."
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "model-tts-1-hd",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "tts-1-hd",
               "voice": "coral",
               "instructions": "Even pacing."
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-alloy",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "alloy"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-ash",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "ash"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-ballad",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "ballad"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-cedar",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "cedar"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-coral",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-echo",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "echo"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-fable",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "fable"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-juniper",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "juniper"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-marin",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "marin"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-onyx",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "onyx"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-nova",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "nova"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-sage",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "sage"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-shimmer",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "shimmer"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-verse",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "verse"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "voice-note-default-opus",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral"
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "file-configured-opus",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": " OpUs "
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "file-configured-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": " WAV "
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "note-configured-mp3",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": "mp3"
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "note-configured-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": "wav"
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "ordinary-telephony-target-default-mp3",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral"
             },
             "text": "Ordinary speech.",
             "target": "telephony",
             "timeoutMs": 12345
           }
         },
         {
           "id": "groq-file-default-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "groq-note-default-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI"
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "groq-explicit-opus",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI",
               "responseFormat": "opus"
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "groq-root-host-default-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "custom-model-voice-instructions-speed",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://speech.example.test/v1",
               "model": "studio-tts",
               "voice": "Studio Voice",
               "speed": 1.75,
               "instructions": "  Read warmly.  "
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "resolved-url-retains-trails",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://speech.example.test/v1/// ",
               "model": "studio-tts",
               "voice": "Studio Voice"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "provider-overrides-model-voice-speed",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "tts-1",
               "voice": "alloy",
               "speed": 1.1,
               "instructions": " Read evenly. "
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerOverrides": {
               "model": " gpt-4o-mini-tts ",
               "voice": " nova ",
               "speed": 1.6
             }
           }
         },
         {
           "id": "blank-provider-overrides-inherit",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "speed": 1.15
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerOverrides": {
               "model": "  ",
               "voice": "  "
             }
           }
         },
         {
           "id": "resolved-snake-extra-body",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "extra_body": {
                 "language": "ja",
                 "seed": 5
               }
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "extra-body-final-wire-precedence",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "speed": 1.1,
               "instructions": "Config instruction.",
               "extraBody": {
                 "model": "tts-1-hd",
                 "input": "Replacement speech.",
                 "voice": "echo",
                 "response_format": "wav",
                 "speed": 1.7,
                 "instructions": "Final instruction.",
                 "language": "en"
               }
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "raw-unicode-text-preserved",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral"
             },
             "text": "  你好，世界 🌍\nCafé — é\tfin.  ",
             "target": "audio-file",
             "timeoutMs": 23456
           }
         },
         {
           "id": "raw-normalize-then-synthesize",
           "input": {
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "mode": "normalizeThenSynthesize",
             "rawConfig": {
               "providers": {
                 "openai": {
                   "apiKey": "fixture-openai-speech",
                   "baseUrl": " https://speech.example.test/v1/// ",
                   "model": " studio-tts ",
                   "voice": " Studio Voice ",
                   "speed": 1.25,
                   "responseFormat": " WAV "
                 }
               }
             }
           }
         },
         {
           "id": "talk-resolve-then-synthesize-retains-trails",
           "input": {
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "mode": "resolveTalkThenSynthesize",
             "baseTtsConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://speech.example.test/v1/// ",
               "model": "studio-tts",
               "voice": "Studio Voice",
               "responseFormat": "wav"
             },
             "talkProviderConfig": {
               "baseUrl": " https://talk.example.test/v2/// ",
               "voiceId": " Talk Voice ",
               "speed": 1.3,
               "instructions": " Talk direction. "
             }
           }
         },
         {
           "id": "resolved-official-url-retains-trails",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://api.openai.com/v1/// ",
               "model": "tts-1",
               "voice": "alloy"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "custom-speed-and-fractional-timeout",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://speech.example.test/v1",
               "model": "studio-tts",
               "voice": "Studio Voice",
               "speed": 4.5
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 23456.75
           }
         }
       ],
       "telephony": [
         {
           "id": "telephony-pcm-overrides-configured-wav",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": "wav"
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         },
         {
           "id": "telephony-custom-model-speed-instructions",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://speech.example.test/v1",
               "model": "studio-tts",
               "voice": "Studio Voice",
               "speed": 1.4,
               "instructions": " Clear calls. "
             },
             "text": "Ordinary speech.",
             "target": "voice-note",
             "timeoutMs": 12345
           }
         },
         {
           "id": "telephony-extra-body-final-precedence",
           "input": {
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.openai.com/v1",
               "model": "gpt-4o-mini-tts",
               "voice": "coral",
               "responseFormat": "opus",
               "extraBody": {
                 "response_format": "wav",
                 "voice": "echo",
                 "language": "en"
               }
             },
             "text": "Ordinary speech.",
             "target": "audio-file",
             "timeoutMs": 12345
           }
         }
       ],
       "voices": [
         {
           "id": "all-fourteen-voices",
           "input": {}
         }
       ]
       }
       """)

  @expected Jason.decode!(~S"""
            {
            "config": [
              {
                "id": "root-defaults",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "providers-openai-precedence",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts-2025-12-15",
                    "voice": "marin"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "openai-over-root",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "tts-1-hd",
                    "voice": "echo"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "providers-empty-override",
                "expected": {
                  "result": {
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "openai-empty-override",
                "expected": {
                  "result": {
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "providers-empty-container-falls-to-openai",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "sage"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "trim-fields-and-url-trails",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "speed": 1.3,
                    "instructions": "Speak clearly.",
                    "responseFormat": "wav"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "blank-optional-fields",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "camel-extra-body-precedence",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral",
                    "extraBody": {
                      "language": "ja",
                      "seed": 17
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "empty-camel-extra-body-falls-to-snake",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral",
                    "extraBody": {
                      "language": "fr",
                      "seed": 31
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "snake-extra-body",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral",
                    "extraBody": {
                      "language": "zh",
                      "metadata": {
                        "project": "speech"
                      }
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "optional-speed-and-instructions",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral",
                    "speed": 1.45,
                    "instructions": "Calm reading.",
                    "responseFormat": "opus"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "ecmascript-bom-nbsp-trimming",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "instructions": "Speak clearly."
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              }
            ],
            "talkConfig": [
              {
                "id": "inherit-normalized-base",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "speed": 1.2,
                    "instructions": "Base direction.",
                    "responseFormat": "opus",
                    "extraBody": {
                      "language": "en",
                      "seed": 9
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "explicit-talk-fields",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://talk.example.test/v2///",
                    "model": "talk-tts",
                    "voice": "Talk Voice",
                    "speed": 1.55,
                    "instructions": "Talk direction.",
                    "responseFormat": "wav",
                    "extraBody": {
                      "language": "en",
                      "seed": 9
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "blank-talk-fields-inherit",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "speed": 1.2,
                    "instructions": "Base direction.",
                    "responseFormat": "opus",
                    "extraBody": {
                      "language": "en",
                      "seed": 9
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "talk-extra-body-is-inherited",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "speed": 1.2,
                    "instructions": "Base direction.",
                    "responseFormat": "opus",
                    "extraBody": {
                      "language": "en",
                      "seed": 9
                    }
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "talk-model-and-voice-ids-only",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "tts-1-hd",
                    "voice": "echo"
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "explicit-format-speed-instructions",
                "expected": {
                  "result": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-4o-mini-tts",
                    "voice": "coral",
                    "responseFormat": "mp3",
                    "speed": 1.65,
                    "instructions": "Friendly voice."
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              }
            ],
            "talkOverrides": [
              {
                "id": "empty-params",
                "expected": {
                  "result": {},
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "trim-model-voice-finite-speed",
                "expected": {
                  "result": {
                    "voice": "nova",
                    "model": "tts-1-hd",
                    "speed": 1.35
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "blank-ids-omit-fields",
                "expected": {
                  "result": {},
                  "requests": [],
                  "releaseCount": 0
                }
              },
              {
                "id": "only-supported-id-fields",
                "expected": {
                  "result": {
                    "voice": "sage",
                    "speed": 1.4
                  },
                  "requests": [],
                  "releaseCount": 0
                }
              }
            ],
            "synthesis": [
              {
                "id": "model-mini",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "model-dated-mini",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts-2025-12-15",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3",
                        "instructions": "Even pacing."
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "model-tts-1",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "tts-1",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "model-tts-1-hd",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "tts-1-hd",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-alloy",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "alloy",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-ash",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "ash",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-ballad",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "ballad",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-cedar",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "cedar",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-coral",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-echo",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "echo",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-fable",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "fable",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-juniper",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "juniper",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-marin",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "marin",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-onyx",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "onyx",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-nova",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "nova",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-sage",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "sage",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-shimmer",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "shimmer",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-verse",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "verse",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "voice-note-default-opus",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "opus",
                    "fileExtension": ".opus",
                    "voiceCompatible": true
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "opus"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "file-configured-opus",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "opus",
                    "fileExtension": ".opus",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "opus"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "file-configured-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "wav"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "note-configured-mp3",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": true
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "note-configured-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "wav"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "ordinary-telephony-target-default-mp3",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "groq-file-default-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.groq.com/openai/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "playai-tts",
                        "input": "Ordinary speech.",
                        "voice": "Fritz-PlayAI",
                        "response_format": "wav"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "groq-note-default-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.groq.com/openai/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "playai-tts",
                        "input": "Ordinary speech.",
                        "voice": "Fritz-PlayAI",
                        "response_format": "wav"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "groq-explicit-opus",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "opus",
                    "fileExtension": ".opus",
                    "voiceCompatible": true
                  },
                  "requests": [
                    {
                      "url": "https://api.groq.com/openai/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "playai-tts",
                        "input": "Ordinary speech.",
                        "voice": "Fritz-PlayAI",
                        "response_format": "opus"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "groq-root-host-default-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://groq.com/openai/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "playai-tts",
                        "input": "Ordinary speech.",
                        "voice": "Fritz-PlayAI",
                        "response_format": "wav"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "custom-model-voice-instructions-speed",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://speech.example.test/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Studio Voice",
                        "response_format": "mp3",
                        "speed": 1.75,
                        "instructions": "Read warmly."
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "resolved-url-retains-trails",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://speech.example.test/v1////audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Studio Voice",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "provider-overrides-model-voice-speed",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "nova",
                        "response_format": "mp3",
                        "speed": 1.6,
                        "instructions": "Read evenly."
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "blank-provider-overrides-inherit",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3",
                        "speed": 1.15
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "resolved-snake-extra-body",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "mp3",
                        "language": "ja",
                        "seed": 5
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "extra-body-final-wire-precedence",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "tts-1-hd",
                        "input": "Replacement speech.",
                        "voice": "echo",
                        "response_format": "wav",
                        "speed": 1.7,
                        "instructions": "Final instruction.",
                        "language": "en"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "raw-unicode-text-preserved",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "  你好，世界 🌍\nCafé — é\tfin.  ",
                        "voice": "coral",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 23456
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "raw-normalize-then-synthesize",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://speech.example.test/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Studio Voice",
                        "response_format": "wav",
                        "speed": 1.25
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1,
                  "resolvedConfig": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://speech.example.test/v1",
                    "model": "studio-tts",
                    "voice": "Studio Voice",
                    "speed": 1.25,
                    "responseFormat": "wav"
                  }
                }
              },
              {
                "id": "talk-resolve-then-synthesize-retains-trails",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "wav",
                    "fileExtension": ".wav",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://talk.example.test/v2////audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Talk Voice",
                        "response_format": "wav",
                        "speed": 1.3,
                        "instructions": "Talk direction."
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1,
                  "resolvedConfig": {
                    "apiKey": "fixture-openai-speech",
                    "baseUrl": "https://talk.example.test/v2///",
                    "model": "studio-tts",
                    "voice": "Talk Voice",
                    "responseFormat": "wav",
                    "speed": 1.3,
                    "instructions": "Talk direction."
                  }
                }
              },
              {
                "id": "resolved-official-url-retains-trails",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1////audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "tts-1",
                        "input": "Ordinary speech.",
                        "voice": "alloy",
                        "response_format": "mp3"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "custom-speed-and-fractional-timeout",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "mp3",
                    "fileExtension": ".mp3",
                    "voiceCompatible": false
                  },
                  "requests": [
                    {
                      "url": "https://speech.example.test/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Studio Voice",
                        "response_format": "mp3",
                        "speed": 4.5
                      },
                      "timeoutMs": 23456.75
                    }
                  ],
                  "releaseCount": 1
                }
              }
            ],
            "telephony": [
              {
                "id": "telephony-pcm-overrides-configured-wav",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "pcm",
                    "sampleRate": 24000
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "coral",
                        "response_format": "pcm"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "telephony-custom-model-speed-instructions",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "pcm",
                    "sampleRate": 24000
                  },
                  "requests": [
                    {
                      "url": "https://speech.example.test/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "studio-tts",
                        "input": "Ordinary speech.",
                        "voice": "Studio Voice",
                        "response_format": "pcm",
                        "speed": 1.4,
                        "instructions": "Clear calls."
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              },
              {
                "id": "telephony-extra-body-final-precedence",
                "expected": {
                  "result": {
                    "audioBase64": "UklGRgABAv8=",
                    "outputFormat": "pcm",
                    "sampleRate": 24000
                  },
                  "requests": [
                    {
                      "url": "https://api.openai.com/v1/audio/speech",
                      "method": "POST",
                      "body": {
                        "model": "gpt-4o-mini-tts",
                        "input": "Ordinary speech.",
                        "voice": "echo",
                        "response_format": "wav",
                        "language": "en"
                      },
                      "timeoutMs": 12345
                    }
                  ],
                  "releaseCount": 1
                }
              }
            ],
            "voices": [
              {
                "id": "all-fourteen-voices",
                "expected": {
                  "result": [
                    {
                      "id": "alloy",
                      "name": "alloy"
                    },
                    {
                      "id": "ash",
                      "name": "ash"
                    },
                    {
                      "id": "ballad",
                      "name": "ballad"
                    },
                    {
                      "id": "cedar",
                      "name": "cedar"
                    },
                    {
                      "id": "coral",
                      "name": "coral"
                    },
                    {
                      "id": "echo",
                      "name": "echo"
                    },
                    {
                      "id": "fable",
                      "name": "fable"
                    },
                    {
                      "id": "juniper",
                      "name": "juniper"
                    },
                    {
                      "id": "marin",
                      "name": "marin"
                    },
                    {
                      "id": "onyx",
                      "name": "onyx"
                    },
                    {
                      "id": "nova",
                      "name": "nova"
                    },
                    {
                      "id": "sage",
                      "name": "sage"
                    },
                    {
                      "id": "shimmer",
                      "name": "shimmer"
                    },
                    {
                      "id": "verse",
                      "name": "verse"
                    }
                  ],
                  "requests": [],
                  "releaseCount": 0
                }
              }
            ]
            }
            """)

  @prior Jason.decode!(~S"""
         [
         {
           "id": "default-file",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "mp3"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "default-note",
           "input": {
             "text": "Plain speech fixture.",
             "target": "voice-note",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "opus"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "opus",
             "fileExtension": ".opus",
             "voiceCompatible": true
           }
         },
         {
           "id": "file-opus",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "responseFormat": "opus"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "responseFormat": "opus"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "opus"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "opus",
             "fileExtension": ".opus",
             "voiceCompatible": false
           }
         },
         {
           "id": "note-wav",
           "input": {
             "text": "Plain speech fixture.",
             "target": "voice-note",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "responseFormat": " WAV "
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "responseFormat": "wav"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "wav"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "wav",
             "fileExtension": ".wav",
             "voiceCompatible": false
           }
         },
         {
           "id": "file-wav",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "responseFormat": "wav"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "responseFormat": "wav"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "wav"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "wav",
             "fileExtension": ".wav",
             "voiceCompatible": false
           }
         },
         {
           "id": "groq-file",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.groq.com/openai/v1",
             "model": "playai-tts",
             "voice": "Fritz-PlayAI"
           },
           "request": {
             "url": "https://api.groq.com/openai/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "playai-tts",
               "input": "Plain speech fixture.",
               "voice": "Fritz-PlayAI",
               "response_format": "wav"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "wav",
             "fileExtension": ".wav",
             "voiceCompatible": false
           }
         },
         {
           "id": "groq-note",
           "input": {
             "text": "Plain speech fixture.",
             "target": "voice-note",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": "https://api.groq.com/openai/v1",
               "model": "playai-tts",
               "voice": "Fritz-PlayAI"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.groq.com/openai/v1",
             "model": "playai-tts",
             "voice": "Fritz-PlayAI"
           },
           "request": {
             "url": "https://api.groq.com/openai/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "playai-tts",
               "input": "Plain speech fixture.",
               "voice": "Fritz-PlayAI",
               "response_format": "wav"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "wav",
             "fileExtension": ".wav",
             "voiceCompatible": false
           }
         },
         {
           "id": "configured-openai",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "model": " gpt-4o-mini-tts-2025-12-15 ",
               "voice": " nova ",
               "speed": 1.25,
               "instructions": " Speak evenly. "
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts-2025-12-15",
             "voice": "nova",
             "speed": 1.25,
             "instructions": "Speak evenly."
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts-2025-12-15",
               "input": "Plain speech fixture.",
               "voice": "nova",
               "response_format": "mp3",
               "speed": 1.25,
               "instructions": "Speak evenly."
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "legacy-model",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "instructions": " Speak evenly. "
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "tts-1",
             "voice": "coral",
             "instructions": "Speak evenly."
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "tts-1",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "mp3"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "custom-voice-model",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "baseUrl": " https://speech.example.test/v1/// ",
               "model": "local-voice-model",
               "voice": "speaker-7",
               "speed": 4.5,
               "instructions": " Speak warmly. "
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://speech.example.test/v1",
             "model": "local-voice-model",
             "voice": "speaker-7",
             "speed": 4.5,
             "instructions": "Speak warmly."
           },
           "request": {
             "url": "https://speech.example.test/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "local-voice-model",
               "input": "Plain speech fixture.",
               "voice": "speaker-7",
               "response_format": "mp3",
               "speed": 4.5,
               "instructions": "Speak warmly."
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "provider-overrides",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "model": "tts-1",
               "voice": "alloy",
               "speed": 1.1
             },
             "providerOverrides": {
               "model": "tts-1-hd",
               "voice": "echo",
               "speed": 1.5
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "tts-1",
             "voice": "alloy",
             "speed": 1.1
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "tts-1-hd",
               "input": "Plain speech fixture.",
               "voice": "echo",
               "response_format": "mp3",
               "speed": 1.5
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "extra-body-fields",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "extraBody": {
                 "language": "en",
                 "seed": 7
               }
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "extraBody": {
               "language": "en",
               "seed": 7
             }
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "mp3",
               "language": "en",
               "seed": 7
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "extra-body-final-wins",
           "input": {
             "text": "Plain speech fixture.",
             "target": "audio-file",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "speed": 1.1,
               "extra_body": {
                 "model": "tts-1-hd",
                 "input": "Replacement plain speech.",
                 "speed": 0.8
               }
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "speed": 1.1,
             "extraBody": {
               "model": "tts-1-hd",
               "input": "Replacement plain speech.",
               "speed": 0.8
             }
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "tts-1-hd",
               "input": "Replacement plain speech.",
               "voice": "coral",
               "response_format": "mp3",
               "speed": 0.8
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "mp3",
             "fileExtension": ".mp3",
             "voiceCompatible": false
           }
         },
         {
           "id": "telephony",
           "input": {
             "text": "Plain speech fixture.",
             "target": "telephony",
             "timeoutMs": 12345,
             "providerConfig": {
               "apiKey": "fixture-openai-speech",
               "responseFormat": "wav"
             }
           },
           "resolvedConfig": {
             "apiKey": "fixture-openai-speech",
             "baseUrl": "https://api.openai.com/v1",
             "model": "gpt-4o-mini-tts",
             "voice": "coral",
             "responseFormat": "wav"
           },
           "request": {
             "url": "https://api.openai.com/v1/audio/speech",
             "method": "POST",
             "body": {
               "model": "gpt-4o-mini-tts",
               "input": "Plain speech fixture.",
               "voice": "coral",
               "response_format": "pcm"
             },
             "timeoutMs": 12345
           },
           "result": {
             "audioBase64": "UklGRgABAv8=",
             "outputFormat": "pcm",
             "sampleRate": 24000
           }
         }
         ]
         """)

  @models ~w(gpt-4o-mini-tts gpt-4o-mini-tts-2025-12-15 tts-1 tts-1-hd)
  @voices ~w(alloy ash ballad cedar coral echo fable juniper marin onyx nova sage shimmer verse)

  test "static source metadata and complete frozen dictionaries" do
    assert OpenAI.metadata() == %{
             id: "openai",
             label: "OpenAI",
             auto_select_order: 10,
             default_model: "gpt-4o-mini-tts",
             models: @models,
             voices: @voices
           }

    assert OpenAI.models() == @models
    assert OpenAI.voices() == @voices

    assert Map.new(@raw, fn {category, rows} -> {category, length(rows)} end) == %{
             "config" => 13,
             "talkConfig" => 6,
             "talkOverrides" => 4,
             "synthesis" => 39,
             "telephony" => 3,
             "voices" => 1
           }

    assert Enum.sort(Map.keys(@raw)) == Enum.sort(Map.keys(@expected))

    for {category, rows} <- @raw do
      assert Enum.map(rows, & &1["id"]) == Enum.map(@expected[category], & &1["id"])
    end

    assert length(@prior) == 14
  end

  for row <- @raw["config"] do
    @row row
    @literal Enum.find(@expected["config"], &(&1["id"] == row["id"]))["expected"]
    test "source raw namespace resolution #{@row["id"]}" do
      assert OpenAI.resolve_config(@row["input"]["rawConfig"]) ==
               source_fields(@literal["result"])
    end
  end

  for row <- @raw["talkConfig"] do
    @row row
    @literal Enum.find(@expected["talkConfig"], &(&1["id"] == row["id"]))["expected"]
    test "source Talk config #{@row["id"]}" do
      input = @row["input"]

      assert OpenAI.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"]) ==
               source_fields(@literal["result"])
    end
  end

  for row <- @raw["talkOverrides"] do
    @row row
    @literal Enum.find(@expected["talkOverrides"], &(&1["id"] == row["id"]))["expected"]
    test "source Talk overrides preserve omission #{@row["id"]}" do
      assert OpenAI.resolve_talk_overrides(@row["input"]["params"]) ==
               source_fields(@literal["result"])
    end
  end

  for row <- @raw["voices"] do
    @row row
    @literal Enum.find(@expected["voices"], &(&1["id"] == row["id"]))["expected"]
    test "source static voices #{@row["id"]}" do
      assert OpenAI.list_voices() == {:ok, Enum.map(@literal["result"], &source_fields/1)}
    end
  end

  for category <- ["synthesis", "telephony"], row <- @raw[category] do
    @category category
    @row row
    @literal Enum.find(@expected[category], &(&1["id"] == row["id"]))["expected"]
    test "source builder then actual local HTTP #{@category} #{@row["id"]}" do
      input = @row["input"]
      config = explicit_source_config(input)
      request = source_request(input)
      assert [literal_request] = @literal["requests"]
      assert {:ok, built} = build(@category, request, config)
      assert_built(built, literal_request, @literal["result"], request)
      assert_http(@category, request, config, literal_request, @literal["result"])
    end
  end

  for row <- @prior do
    @row row
    test "preserved prior literal recipe after explicit raw phase #{@row["id"]}" do
      config = OpenAI.resolve_config(@row["input"]["providerConfig"])
      assert config == source_fields(@row["resolvedConfig"])
      request = source_request(@row["input"])
      # The prior telephone recipe always exercised the distinct phone callback.
      category = if @row["id"] == "telephony", do: "telephony", else: "synthesis"
      assert {:ok, built} = build(category, request, config)
      assert_built(built, @row["request"], @row["result"], request)
      assert_http(category, request, config, @row["request"], @row["result"])
    end
  end

  # These complete positive compositions are independently authored literal bodies.
  # They bind every Talk config and override row to actual HTTP rather than just
  # comparing two normalization functions.
  for {id, body, format} <- [
        {"inherit-normalized-base",
         %{
           "model" => "studio-tts",
           "voice" => "Studio Voice",
           "response_format" => "opus",
           "speed" => 1.2,
           "instructions" => "Base direction.",
           "language" => "en",
           "seed" => 9
         }, "opus"},
        {"explicit-talk-fields",
         %{
           "model" => "talk-tts",
           "voice" => "Talk Voice",
           "response_format" => "wav",
           "speed" => 1.55,
           "instructions" => "Talk direction.",
           "language" => "en",
           "seed" => 9
         }, "wav"},
        {"blank-talk-fields-inherit",
         %{
           "model" => "studio-tts",
           "voice" => "Studio Voice",
           "response_format" => "opus",
           "speed" => 1.2,
           "instructions" => "Base direction.",
           "language" => "en",
           "seed" => 9
         }, "opus"},
        {"talk-extra-body-is-inherited",
         %{
           "model" => "studio-tts",
           "voice" => "Studio Voice",
           "response_format" => "opus",
           "speed" => 1.2,
           "instructions" => "Base direction.",
           "language" => "en",
           "seed" => 9
         }, "opus"},
        {"talk-model-and-voice-ids-only",
         %{"model" => "tts-1-hd", "voice" => "echo", "response_format" => "opus"}, "opus"},
        {"explicit-format-speed-instructions",
         %{
           "model" => "gpt-4o-mini-tts",
           "voice" => "coral",
           "response_format" => "mp3",
           "speed" => 1.65,
           "instructions" => "Friendly voice."
         }, "mp3"}
      ] do
    @row Enum.find(@raw["talkConfig"], &(&1["id"] == id))
    @body Map.put(body, "input", "  Talk line.\n世界  ")
    @format format
    test "complete positive Talk config to HTTP #{id}" do
      input = @row["input"]
      config = OpenAI.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])
      assert_talk_http(config, %{}, @body, @format)
    end
  end

  for {id, body} <- [
        {"empty-params", %{"model" => "tts-1", "voice" => "alloy", "response_format" => "mp3"}},
        {"trim-model-voice-finite-speed",
         %{"model" => "tts-1-hd", "voice" => "nova", "response_format" => "mp3", "speed" => 1.35}},
        {"blank-ids-omit-fields",
         %{"model" => "tts-1", "voice" => "alloy", "response_format" => "mp3"}},
        {"only-supported-id-fields",
         %{"model" => "tts-1", "voice" => "sage", "response_format" => "mp3", "speed" => 1.4}}
      ] do
    @row Enum.find(@raw["talkOverrides"], &(&1["id"] == id))
    @body Map.put(body, "input", "  Talk line.\n世界  ")
    test "complete positive Talk overrides to HTTP #{id}" do
      config =
        OpenAI.resolve_config(%{
          "apiKey" => "fixture-openai-speech",
          "model" => "tts-1",
          "voice" => "alloy",
          "responseFormat" => "mp3"
        })

      overrides = OpenAI.resolve_talk_overrides(@row["input"]["params"])
      assert_talk_http(config, overrides, @body, "mp3")
    end
  end

  defp source_request(input) do
    %{
      text: input["text"],
      target: target(input["target"]),
      timeout_ms: input["timeoutMs"],
      provider_overrides: source_fields(input["providerOverrides"] || %{}),
      deadline_ms: System.monotonic_time(:millisecond) + 60_000
    }
  end

  defp explicit_source_config(%{"mode" => "normalizeThenSynthesize"} = input),
    do: OpenAI.resolve_config(input["rawConfig"])

  defp explicit_source_config(%{"mode" => "resolveTalkThenSynthesize"} = input),
    do: OpenAI.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])

  # These source synthesis inputs are already resolved. Do not raw-normalize them:
  # their base URL trailing slashes are part of the captured request contract.
  defp explicit_source_config(input), do: source_fields(input["providerConfig"])

  defp target("audio-file"), do: :audio_file
  defp target("voice-note"), do: :voice_note
  defp target("telephony"), do: :telephony
  defp build("synthesis", request, config), do: OpenAI.build_request(request, config)
  defp build("telephony", request, config), do: OpenAI.build_telephony_request(request, config)
  defp synthesize("synthesis", request, config), do: OpenAI.synthesize(request, config)
  defp synthesize("telephony", request, config), do: OpenAI.synthesize_telephony(request, config)

  defp assert_built(built, literal_request, literal_result, request) do
    assert built.url == literal_request["url"]
    assert built.body == literal_request["body"]
    assert built.timeout_ms === literal_request["timeoutMs"]
    assert built.timeout_ms === request.timeout_ms
    assert built.deadline_ms === request.deadline_ms

    assert Map.take(built, [:output_format, :file_extension, :voice_compatible, :sample_rate])
           |> Map.reject(fn {_key, value} -> is_nil(value) end) ==
             source_fields(Map.delete(literal_result, "audioBase64"))
  end

  defp assert_http(category, request, config, literal_request, literal_result) do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()
    path = URI.parse(literal_request["url"]).path
    local_url = Gaoxy.Test.url(fixture, path)
    bytes = Base.decode64!(literal_result["audioBase64"])
    assert byte_size(bytes) == 8

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == path
      assert Jason.decode!(raw) == literal_request["body"]
      send(owner, {:openai_contract_http, conn.method, conn.request_path, raw})
      Plug.Conn.resp(conn, 200, bytes)
    end)

    # Standard Req plugin changes only scheme/host/port after the semantic
    # builder. Original official/Groq configuration and exact source path remain.
    original_env = Application.fetch_env(:req, :default_options)
    defaults = Req.default_options()
    source_uri = URI.parse(literal_request["url"])
    local_uri = URI.parse(local_url)

    plugin = fn req ->
      Req.Request.prepend_request_steps(req,
        openai342_origin: fn outgoing ->
          assert outgoing.url == source_uri
          assert outgoing.method == :post
          assert Jason.decode!(IO.iodata_to_binary(outgoing.body)) == literal_request["body"]

          routed = %{
            outgoing.url
            | scheme: local_uri.scheme,
              host: local_uri.host,
              port: local_uri.port
          }

          assert URI.to_string(routed) == local_url
          assert routed.path == source_uri.path
          assert routed.query == source_uri.query

          send(
            owner,
            {:openai_contract_route, URI.to_string(outgoing.url), URI.to_string(routed)}
          )

          %{outgoing | url: routed}
        end
      )
    end

    Req.default_options(Keyword.update(defaults, :plugins, [plugin], &(&1 ++ [plugin])))

    on_exit(fn ->
      case original_env do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    assert synthesize(category, request, config) == {:ok, source_result(literal_result)}
    source_url = literal_request["url"]
    assert_receive {:openai_contract_route, ^source_url, ^local_url}, 5_000
    assert_receive {:openai_contract_http, "POST", ^path, raw}, 5_000
    assert Jason.decode!(raw) == literal_request["body"]
  end

  defp assert_talk_http(config, overrides, body, format) do
    request = %{
      text: "  Talk line.\n世界  ",
      target: :voice_note,
      timeout_ms: 26_001.25,
      provider_overrides: overrides,
      deadline_ms: System.monotonic_time(:millisecond) + 60_000
    }

    literal_request = %{
      "url" => config.base_url <> "/audio/speech",
      "body" => body,
      "timeoutMs" => 26_001.25
    }

    literal_result = %{
      "audioBase64" => "UklGRgABAv8=",
      "outputFormat" => format,
      "fileExtension" => "." <> format,
      "voiceCompatible" => format in ["mp3", "opus"]
    }

    assert {:ok, built} = OpenAI.build_request(request, config)
    assert_built(built, literal_request, literal_result, request)
    assert_http("synthesis", request, config, literal_request, literal_result)
  end

  defp source_result(raw) do
    raw
    |> Map.delete("audioBase64")
    |> source_fields()
    |> Map.put(:audio, Base.decode64!(raw["audioBase64"]))
  end

  defp source_fields(map) do
    fields = %{
      "apiKey" => :api_key,
      "baseUrl" => :base_url,
      "model" => :model,
      "voice" => :voice,
      "speed" => :speed,
      "instructions" => :instructions,
      "responseFormat" => :response_format,
      "extraBody" => :extra_body,
      "extra_body" => :extra_body,
      "outputFormat" => :output_format,
      "fileExtension" => :file_extension,
      "voiceCompatible" => :voice_compatible,
      "sampleRate" => :sample_rate,
      "id" => :id,
      "name" => :name
    }

    Map.new(map, fn {key, value} -> {Map.fetch!(fields, key), value} end)
  end
end
