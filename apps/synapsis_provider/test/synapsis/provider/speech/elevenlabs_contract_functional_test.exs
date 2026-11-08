defmodule Synapsis.Provider.Speech.ElevenLabsContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.ElevenLabs
  alias Synapsis.Provider.Speech.ElevenLabs.Stream, as: ElevenLabsStream

  @moduletag timeout: 90_000

  # Independently authored frozen343 inputs and literal expectations, embedded
  # unchanged before target execution. No /tmp or production-derived oracle.
  # AAECAwQFBgc= is eight opaque transport bytes, not codec qualification.
  @raw Jason.decode!(~S"""
       {
         "config": [
           {
             "id": "empty-defaults",
             "input": {
               "rawConfig": {}
             }
           },
           {
             "id": "root-and-legacy-fields-not-selected",
             "input": {
               "rawConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": "https://root.example.test",
                 "voiceId": "RootVoice123456",
                 "modelId": "eleven_v3",
                 "elevenlabs": {
                   "apiKey": "fixture-elevenlabs-speech-contract",
                   "voiceId": "LegacyVoice12345"
                 }
               }
             }
           },
           {
             "id": "nested-provider-selected",
             "input": {
               "rawConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "voiceId": "RootVoice123456",
                 "elevenlabs": {
                   "voiceId": "LegacyVoice12345"
                 },
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               }
             }
           },
           {
             "id": "empty-nested-masks-legacy",
             "input": {
               "rawConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "voiceId": "RootVoice123456",
                 "elevenlabs": {
                   "apiKey": "fixture-elevenlabs-speech-contract",
                   "voiceId": "LegacyVoice12345"
                 },
                 "providers": {
                   "elevenlabs": {}
                 }
               }
             }
           },
           {
             "id": "blank-optionals-use-defaults",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "  ",
                     "voiceId": "  ",
                     "modelId": "  ",
                     "applyTextNormalization": "  ",
                     "languageCode": "  ",
                     "voiceSettings": {}
                   }
                 }
               }
             }
           },
           {
             "id": "ecmascript-bom-nbsp-trim",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "\ufeff\u00a0https://trim.example.test/v2///\u00a0\ufeff",
                     "voiceId": "\ufeff\u00a0pMsXgVXv3BLzUgSXRplE\u00a0\ufeff",
                     "modelId": "\ufeff\u00a0eleven_turbo_v2_5\u00a0\ufeff",
                     "applyTextNormalization": "\ufeff\u00a0On\u00a0\ufeff",
                     "languageCode": "\ufeff\u00a0DE\u00a0\ufeff"
                   }
                 }
               }
             }
           },
           {
             "id": "turbo-v2-config-alias",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "modelId": " eleven_turbo_v2 "
                   }
                 }
               }
             }
           },
           {
             "id": "partial-voice-settings",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "voiceSettings": {
                       "stability": 0.35,
                       "speed": 1.25
                     }
                   }
                 }
               }
             }
           },
           {
             "id": "custom-model-is-preserved",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "modelId": " studio_voice_model ",
                     "voiceSettings": {
                       "similarityBoost": 0.8,
                       "style": 0.3,
                       "useSpeakerBoost": false
                     }
                   }
                 }
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
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
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
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": " https://talk.example.test/v2/// ",
                 "voiceId": " TalkVoice1234567 ",
                 "modelId": " eleven_turbo_v2_5 ",
                 "seed": 73,
                 "applyTextNormalization": " ON ",
                 "languageCode": " FR ",
                 "voiceSettings": {
                   "stability": 0.6,
                   "speed": 1.4
                 }
               }
             }
           },
           {
             "id": "blank-talk-optionals-inherit",
             "input": {
               "baseTtsConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "baseUrl": " ",
                 "voiceId": " ",
                 "modelId": " ",
                 "applyTextNormalization": " ",
                 "languageCode": " ",
                 "voiceSettings": {}
               }
             }
           },
           {
             "id": "talk-model-alias-and-partial-settings",
             "input": {
               "baseTtsConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_turbo_v2",
                 "voiceSettings": {
                   "similarityBoost": 0.85,
                   "useSpeakerBoost": true
                 }
               }
             }
           },
           {
             "id": "talk-ecmascript-trim",
             "input": {
               "baseTtsConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "voiceId": "\ufeff\u00a0TalkVoice1234567\u00a0\ufeff",
                 "languageCode": "\ufeff\u00a0JA\u00a0\ufeff",
                 "applyTextNormalization": " Off "
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
             "id": "flat-all-supported",
             "input": {
               "params": {
                 "voiceId": " TalkVoice1234567 ",
                 "modelId": " eleven_turbo_v2_5 ",
                 "outputFormat": " opus_48000_64 ",
                 "seed": 83,
                 "normalize": " ON ",
                 "language": " DE ",
                 "latencyTier": 2,
                 "speed": 1.35,
                 "stability": 0.45,
                 "similarity": 0.8,
                 "style": 0.25,
                 "speakerBoost": false
               }
             }
           },
           {
             "id": "partial-flat-settings",
             "input": {
               "params": {
                 "modelId": "eleven_turbo_v2",
                 "language": " FR ",
                 "similarity": 0.7,
                 "speakerBoost": true
               }
             }
           },
           {
             "id": "blank-optional-strings",
             "input": {
               "params": {
                 "voiceId": " ",
                 "modelId": " ",
                 "outputFormat": " ",
                 "normalize": " ",
                 "language": " "
               }
             }
           }
         ],
         "synthesis": [
           {
             "id": "model-eleven_v3",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_v3"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_multilingual_v2",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_multilingual_v2"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_flash_v2_5",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_flash_v2_5"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_flash_v2",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_flash_v2"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_turbo_v2_5",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_turbo_v2_5"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_monolingual_v1",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_monolingual_v1"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "model-eleven_turbo_v2",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_turbo_v2"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "voice-note-default-opus",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "voice-note",
               "timeoutMs": 12345
             }
           },
           {
             "id": "output-mp3",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "mp3_44100_128"
               }
             }
           },
           {
             "id": "output-opus",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "opus_48000_64"
               }
             }
           },
           {
             "id": "output-pcm",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "pcm_24000"
               }
             }
           },
           {
             "id": "output-ulaw",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "ulaw_8000"
               }
             }
           },
           {
             "id": "output-alaw",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "alaw_8000"
               }
             }
           },
           {
             "id": "output-wav",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "wav_44100"
               }
             }
           },
           {
             "id": "output-opaque",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "studio_24000"
               }
             }
           },
           {
             "id": "voice-note-explicit-mp3",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "voice-note",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "mp3_44100_128"
               }
             }
           },
           {
             "id": "all-config-fields",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": "https://speech.example.test/api///",
                 "voiceId": "pMsXgVXv3BLzUgSXRplE",
                 "modelId": "eleven_multilingual_v2",
                 "seed": 37,
                 "applyTextNormalization": " AUTO ",
                 "languageCode": " EN ",
                 "voiceSettings": {
                   "stability": 0.4,
                   "similarityBoost": 0.65,
                   "style": 0.2,
                   "useSpeakerBoost": false,
                   "speed": 1.15
                 }
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "all-overrides-compose-settings",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": "https://speech.example.test/api///",
                 "voiceId": "pMsXgVXv3BLzUgSXRplE",
                 "modelId": "eleven_multilingual_v2",
                 "seed": 37,
                 "applyTextNormalization": " AUTO ",
                 "languageCode": " EN ",
                 "voiceSettings": {
                   "stability": 0.4,
                   "similarityBoost": 0.65,
                   "style": 0.2,
                   "useSpeakerBoost": false,
                   "speed": 1.15
                 }
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "voiceId": " OverrideVoice12345 ",
                 "modelId": " eleven_turbo_v2 ",
                 "outputFormat": " WAV_44100 ",
                 "seed": 91,
                 "applyTextNormalization": " OFF ",
                 "languageCode": " ES ",
                 "latencyTier": 2,
                 "voiceSettings": {
                   "stability": 0.6,
                   "similarityBoost": 0.85,
                   "style": 0.3,
                   "useSpeakerBoost": true,
                   "speed": 1.4
                 }
               }
             }
           },
           {
             "id": "v3-ordinary-latency-not-emitted",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "modelId": "eleven_v3"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "latencyTier": 2
               }
             }
           },
           {
             "id": "raw-config-to-synthesis",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "request": {
                 "text": "Raw configuration composition.",
                 "target": "audio-file",
                 "timeoutMs": 12345
               }
             }
           },
           {
             "id": "talk-config-and-flat-params-to-synthesis",
             "input": {
               "baseTtsConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "voiceId": "TalkVoice1234567",
                 "modelId": "eleven_turbo_v2_5",
                 "languageCode": "FR",
                 "voiceSettings": {
                   "speed": 1.3
                 }
               },
               "talkParams": {
                 "outputFormat": "opus_48000_64",
                 "modelId": "eleven_turbo_v2",
                 "seed": 83,
                 "normalize": "on",
                 "language": "DE",
                 "latencyTier": 2,
                 "stability": 0.55,
                 "similarity": 0.8,
                 "speakerBoost": true
               },
               "request": {
                 "text": "Talk composition.",
                 "target": "voice-note",
                 "timeoutMs": 12345
               }
             }
           }
         ],
         "telephony": [
           {
             "id": "phone-default-pcm22050",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "telephony",
               "timeoutMs": 12345
             }
           },
           {
             "id": "phone-overrides-retain-fixed-format",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": "https://speech.example.test/api///",
                 "voiceId": "pMsXgVXv3BLzUgSXRplE",
                 "modelId": "eleven_multilingual_v2",
                 "seed": 37,
                 "applyTextNormalization": " AUTO ",
                 "languageCode": " EN ",
                 "voiceSettings": {
                   "stability": 0.4,
                   "similarityBoost": 0.65,
                   "style": 0.2,
                   "useSpeakerBoost": false,
                   "speed": 1.15
                 }
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "opus_48000_64",
                 "latencyTier": 2,
                 "voiceId": "PhoneVoice123456",
                 "modelId": "eleven_turbo_v2",
                 "seed": 67,
                 "languageCode": "IT"
               }
             }
           },
           {
             "id": "phone-raw-composition",
             "input": {
               "rawConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "request": {
                 "text": "Phone composition.",
                 "target": "telephony",
                 "timeoutMs": 12345
               }
             }
           }
         ],
         "streaming": [
           {
             "id": "stream-default-completed",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345
             }
           },
           {
             "id": "stream-note-completed",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract"
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "voice-note",
               "timeoutMs": 12345
             }
           },
           {
             "id": "stream-config-overrides-completed",
             "input": {
               "providerConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": "https://speech.example.test/api///",
                 "voiceId": "pMsXgVXv3BLzUgSXRplE",
                 "modelId": "eleven_multilingual_v2",
                 "seed": 37,
                 "applyTextNormalization": " AUTO ",
                 "languageCode": " EN ",
                 "voiceSettings": {
                   "stability": 0.4,
                   "similarityBoost": 0.65,
                   "style": 0.2,
                   "useSpeakerBoost": false,
                   "speed": 1.15
                 }
               },
               "text": "Ordinary ElevenLabs speech.",
               "target": "audio-file",
               "timeoutMs": 12345,
               "providerOverrides": {
                 "outputFormat": "pcm_24000",
                 "modelId": "eleven_v3",
                 "latencyTier": 2,
                 "voiceSettings": {
                   "speed": 1.4
                 }
               }
             }
           },
           {
             "id": "stream-talk-composition-completed",
             "input": {
               "baseTtsConfig": {
                 "providers": {
                   "elevenlabs": {
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "baseUrl": "https://speech.example.test/api///",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "seed": 37,
                     "applyTextNormalization": " AUTO ",
                     "languageCode": " EN ",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     }
                   }
                 }
               },
               "talkProviderConfig": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "voiceId": "TalkVoice1234567",
                 "languageCode": "FR"
               },
               "talkParams": {
                 "outputFormat": "wav_44100",
                 "latencyTier": 2,
                 "style": 0.3
               },
               "request": {
                 "text": "Streaming Talk composition.",
                 "target": "audio-file",
                 "timeoutMs": 12345
               }
             }
           }
         ],
         "voices": [
           {
             "id": "voices-configured-root",
             "input": {
               "request": {
                 "providerConfig": {
                   "apiKey": "fixture-elevenlabs-speech-contract",
                   "baseUrl": "https://speech.example.test/api///",
                   "voiceId": "pMsXgVXv3BLzUgSXRplE",
                   "modelId": "eleven_multilingual_v2",
                   "seed": 37,
                   "applyTextNormalization": " AUTO ",
                   "languageCode": " EN ",
                   "voiceSettings": {
                     "stability": 0.4,
                     "similarityBoost": 0.65,
                     "style": 0.2,
                     "useSpeakerBoost": false,
                     "speed": 1.15
                   }
                 },
                 "timeoutMs": 12345
               },
               "response": {
                 "voices": [
                   {
                     "voice_id": " VoiceCatalog12345 ",
                     "name": " Studio One ",
                     "category": " professional ",
                     "description": " Calm narration. "
                   },
                   {
                     "voice_id": "VoiceCatalog67890",
                     "name": " ",
                     "category": "\ufeff\u00a0",
                     "description": "  "
                   },
                   {
                     "voice_id": "VoiceCatalog24680",
                     "name": "Studio Three"
                   }
                 ]
               }
             }
           },
           {
             "id": "voices-explicit-root",
             "input": {
               "request": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "baseUrl": " https://catalog.example.test/v3/// ",
                 "timeoutMs": 12345
               },
               "response": {
                 "voices": [
                   {
                     "voice_id": " VoiceCatalog12345 ",
                     "name": " Studio One ",
                     "category": " professional ",
                     "description": " Calm narration. "
                   },
                   {
                     "voice_id": "VoiceCatalog67890",
                     "name": " ",
                     "category": "\ufeff\u00a0",
                     "description": "  "
                   },
                   {
                     "voice_id": "VoiceCatalog24680",
                     "name": "Studio Three"
                   }
                 ]
               }
             }
           },
           {
             "id": "voices-default-root",
             "input": {
               "request": {
                 "apiKey": "fixture-elevenlabs-speech-contract",
                 "timeoutMs": 12345
               },
               "response": {
                 "voices": [
                   {
                     "voice_id": " VoiceCatalog12345 ",
                     "name": " Studio One ",
                     "category": " professional ",
                     "description": " Calm narration. "
                   },
                   {
                     "voice_id": "VoiceCatalog67890",
                     "name": " ",
                     "category": "\ufeff\u00a0",
                     "description": "  "
                   },
                   {
                     "voice_id": "VoiceCatalog24680",
                     "name": "Studio Three"
                   }
                 ]
               }
             }
           }
         ]
       }
       """)
  @literal Jason.decode!(~S"""
           {
             "config": [
               {
                 "id": "empty-defaults",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     }
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "root-and-legacy-fields-not-selected",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     }
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "nested-provider-selected",
                 "expected": {
                   "result": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "empty-nested-masks-legacy",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     }
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "blank-optionals-use-defaults",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "ecmascript-bom-nbsp-trim",
                 "expected": {
                   "result": {
                     "baseUrl": "https://trim.example.test/v2",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_flash_v2_5",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "applyTextNormalization": "On",
                     "languageCode": "DE"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "turbo-v2-config-alias",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_flash_v2",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "partial-voice-settings",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.35,
                       "similarityBoost": 0.75,
                       "style": 0,
                       "useSpeakerBoost": true,
                       "speed": 1.25
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "custom-model-is-preserved",
                 "expected": {
                   "result": {
                     "baseUrl": "https://api.elevenlabs.io",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "studio_voice_model",
                     "voiceSettings": {
                       "stability": 0.5,
                       "similarityBoost": 0.8,
                       "style": 0.3,
                       "useSpeakerBoost": false,
                       "speed": 1
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract"
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
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "explicit-talk-fields",
                 "expected": {
                   "result": {
                     "baseUrl": "https://talk.example.test/v2",
                     "voiceId": "TalkVoice1234567",
                     "modelId": "eleven_flash_v2_5",
                     "voiceSettings": {
                       "stability": 0.6,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.4
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 73,
                     "applyTextNormalization": "on",
                     "languageCode": "fr"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "blank-talk-optionals-inherit",
                 "expected": {
                   "result": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "talk-model-alias-and-partial-settings",
                 "expected": {
                   "result": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_flash_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.85,
                       "style": 0.2,
                       "useSpeakerBoost": true,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "talk-ecmascript-trim",
                 "expected": {
                   "result": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "TalkVoice1234567",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "off",
                     "languageCode": "ja"
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
                 "id": "flat-all-supported",
                 "expected": {
                   "result": {
                     "voiceId": "TalkVoice1234567",
                     "modelId": "eleven_flash_v2_5",
                     "outputFormat": "opus_48000_64",
                     "seed": 83,
                     "applyTextNormalization": "on",
                     "languageCode": "de",
                     "latencyTier": 2,
                     "voiceSettings": {
                       "stability": 0.45,
                       "similarityBoost": 0.8,
                       "style": 0.25,
                       "useSpeakerBoost": false,
                       "speed": 1.35
                     }
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "partial-flat-settings",
                 "expected": {
                   "result": {
                     "modelId": "eleven_flash_v2",
                     "languageCode": "fr",
                     "voiceSettings": {
                       "similarityBoost": 0.7,
                       "useSpeakerBoost": true
                     }
                   },
                   "requests": [],
                   "releaseCount": 0
                 }
               },
               {
                 "id": "blank-optional-strings",
                 "expected": {
                   "result": {},
                   "requests": [],
                   "releaseCount": 0
                 }
               }
             ],
             "synthesis": [
               {
                 "id": "model-eleven_v3",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_v3",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_multilingual_v2",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_flash_v2_5",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2_5",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_flash_v2",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_turbo_v2_5",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2_5",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_monolingual_v1",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_monolingual_v1",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "model-eleven_turbo_v2",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "voice-note-default-opus",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "opus_48000_64",
                     "fileExtension": ".opus",
                     "voiceCompatible": true
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=opus_48000_64",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-mp3",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-opus",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "opus_48000_64",
                     "fileExtension": ".opus",
                     "voiceCompatible": true
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=opus_48000_64",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-pcm",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "pcm_24000",
                     "fileExtension": ".pcm",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=pcm_24000",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-ulaw",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "ulaw_8000",
                     "fileExtension": ".ulaw",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=ulaw_8000",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-alaw",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "alaw_8000",
                     "fileExtension": ".alaw",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=alaw_8000",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-wav",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "wav_44100",
                     "fileExtension": ".wav",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=wav_44100",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "output-opaque",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "studio_24000",
                     "fileExtension": ".bin",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=studio_24000",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "voice-note-explicit-mp3",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "all-config-fields",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.2,
                           "use_speaker_boost": false,
                           "speed": 1.15
                         },
                         "seed": 37,
                         "apply_text_normalization": "auto",
                         "language_code": "en"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "all-overrides-compose-settings",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "WAV_44100",
                     "fileExtension": ".wav",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/OverrideVoice12345?output_format=WAV_44100&optimize_streaming_latency=2",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2",
                         "voice_settings": {
                           "stability": 0.6,
                           "similarity_boost": 0.85,
                           "style": 0.3,
                           "use_speaker_boost": true,
                           "speed": 1.4
                         },
                         "seed": 91,
                         "apply_text_normalization": "off",
                         "language_code": "es"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "v3-ordinary-latency-not-emitted",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_v3",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "raw-config-to-synthesis",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Raw configuration composition.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.2,
                           "use_speaker_boost": false,
                           "speed": 1.15
                         },
                         "seed": 37,
                         "apply_text_normalization": "auto",
                         "language_code": "en"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1,
                   "resolvedConfig": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   }
                 }
               },
               {
                 "id": "talk-config-and-flat-params-to-synthesis",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "opus_48000_64",
                     "fileExtension": ".opus",
                     "voiceCompatible": true
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/TalkVoice1234567?output_format=opus_48000_64&optimize_streaming_latency=2",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Talk composition.",
                         "model_id": "eleven_flash_v2",
                         "voice_settings": {
                           "stability": 0.55,
                           "similarity_boost": 0.8,
                           "style": 0.2,
                           "use_speaker_boost": true,
                           "speed": 1.3
                         },
                         "seed": 83,
                         "apply_text_normalization": "on",
                         "language_code": "de"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1,
                   "resolvedConfig": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "TalkVoice1234567",
                     "modelId": "eleven_flash_v2_5",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.3
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "fr"
                   }
                 }
               }
             ],
             "telephony": [
               {
                 "id": "phone-default-pcm22050",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "pcm_22050",
                     "sampleRate": 22050
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=pcm_22050",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "phone-overrides-retain-fixed-format",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "pcm_22050",
                     "sampleRate": 22050
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/PhoneVoice123456?output_format=pcm_22050",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_flash_v2",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.2,
                           "use_speaker_boost": false,
                           "speed": 1.15
                         },
                         "seed": 67,
                         "apply_text_normalization": "auto",
                         "language_code": "it"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "phone-raw-composition",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "pcm_22050",
                     "sampleRate": 22050
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE?output_format=pcm_22050",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Phone composition.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.2,
                           "use_speaker_boost": false,
                           "speed": 1.15
                         },
                         "seed": 37,
                         "apply_text_normalization": "auto",
                         "language_code": "en"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts"
                     }
                   ],
                   "releaseCount": 1,
                   "resolvedConfig": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "pMsXgVXv3BLzUgSXRplE",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "EN"
                   }
                 }
               }
             ],
             "streaming": [
               {
                 "id": "stream-default-completed",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "mp3_44100_128",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false,
                     "chunks": [
                       [
                         0,
                         1,
                         2
                       ],
                       [
                         3,
                         4
                       ],
                       [
                         5,
                         6,
                         7
                       ]
                     ],
                     "byteLength": 8,
                     "completed": true
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE/stream?output_format=mp3_44100_128",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json",
                         "Accept": "audio/mpeg"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts.stream"
                     }
                   ],
                   "releaseCount": 1,
                   "streamLifecycle": {
                     "sourceReads": 4,
                     "sourceCancels": 0,
                     "releaseBeforeConsumption": 0,
                     "releaseAfterEof": 0,
                     "releaseAfterExplicitRelease": 1,
                     "sourceLockedAfterEof": false
                   }
                 }
               },
               {
                 "id": "stream-note-completed",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "opus_48000_64",
                     "fileExtension": ".opus",
                     "voiceCompatible": true,
                     "chunks": [
                       [
                         0,
                         1,
                         2
                       ],
                       [
                         3,
                         4
                       ],
                       [
                         5,
                         6,
                         7
                       ]
                     ],
                     "byteLength": 8,
                     "completed": true
                   },
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE/stream?output_format=opus_48000_64",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.5,
                           "similarity_boost": 0.75,
                           "style": 0,
                           "use_speaker_boost": true,
                           "speed": 1
                         }
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts.stream"
                     }
                   ],
                   "releaseCount": 1,
                   "streamLifecycle": {
                     "sourceReads": 4,
                     "sourceCancels": 0,
                     "releaseBeforeConsumption": 0,
                     "releaseAfterEof": 0,
                     "releaseAfterExplicitRelease": 1,
                     "sourceLockedAfterEof": false
                   }
                 }
               },
               {
                 "id": "stream-config-overrides-completed",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "pcm_24000",
                     "fileExtension": ".pcm",
                     "voiceCompatible": false,
                     "chunks": [
                       [
                         0,
                         1,
                         2
                       ],
                       [
                         3,
                         4
                       ],
                       [
                         5,
                         6,
                         7
                       ]
                     ],
                     "byteLength": 8,
                     "completed": true
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/pMsXgVXv3BLzUgSXRplE/stream?output_format=pcm_24000",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Ordinary ElevenLabs speech.",
                         "model_id": "eleven_v3",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.2,
                           "use_speaker_boost": false,
                           "speed": 1.4
                         },
                         "seed": 37,
                         "apply_text_normalization": "auto",
                         "language_code": "en"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts.stream"
                     }
                   ],
                   "releaseCount": 1,
                   "streamLifecycle": {
                     "sourceReads": 4,
                     "sourceCancels": 0,
                     "releaseBeforeConsumption": 0,
                     "releaseAfterEof": 0,
                     "releaseAfterExplicitRelease": 1,
                     "sourceLockedAfterEof": false
                   }
                 }
               },
               {
                 "id": "stream-talk-composition-completed",
                 "expected": {
                   "result": {
                     "audioBase64": "AAECAwQFBgc=",
                     "outputFormat": "wav_44100",
                     "fileExtension": ".wav",
                     "voiceCompatible": false,
                     "chunks": [
                       [
                         0,
                         1,
                         2
                       ],
                       [
                         3,
                         4
                       ],
                       [
                         5,
                         6,
                         7
                       ]
                     ],
                     "byteLength": 8,
                     "completed": true
                   },
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/text-to-speech/TalkVoice1234567/stream?output_format=wav_44100&optimize_streaming_latency=2",
                       "method": "POST",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract",
                         "Content-Type": "application/json"
                       },
                       "body": {
                         "text": "Streaming Talk composition.",
                         "model_id": "eleven_multilingual_v2",
                         "voice_settings": {
                           "stability": 0.4,
                           "similarity_boost": 0.65,
                           "style": 0.3,
                           "use_speaker_boost": false,
                           "speed": 1.15
                         },
                         "seed": 37,
                         "apply_text_normalization": "auto",
                         "language_code": "fr"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.tts.stream"
                     }
                   ],
                   "releaseCount": 1,
                   "resolvedConfig": {
                     "baseUrl": "https://speech.example.test/api",
                     "voiceId": "TalkVoice1234567",
                     "modelId": "eleven_multilingual_v2",
                     "voiceSettings": {
                       "stability": 0.4,
                       "similarityBoost": 0.65,
                       "style": 0.2,
                       "useSpeakerBoost": false,
                       "speed": 1.15
                     },
                     "apiKey": "fixture-elevenlabs-speech-contract",
                     "seed": 37,
                     "applyTextNormalization": "AUTO",
                     "languageCode": "fr"
                   },
                   "streamLifecycle": {
                     "sourceReads": 4,
                     "sourceCancels": 0,
                     "releaseBeforeConsumption": 0,
                     "releaseAfterEof": 0,
                     "releaseAfterExplicitRelease": 1,
                     "sourceLockedAfterEof": false
                   }
                 }
               }
             ],
             "voices": [
               {
                 "id": "voices-configured-root",
                 "expected": {
                   "result": [
                     {
                       "id": "VoiceCatalog12345",
                       "name": "Studio One",
                       "category": "professional",
                       "description": "Calm narration."
                     },
                     {
                       "id": "VoiceCatalog67890"
                     },
                     {
                       "id": "VoiceCatalog24680",
                       "name": "Studio Three"
                     }
                   ],
                   "requests": [
                     {
                       "url": "https://speech.example.test/api/v1/voices",
                       "method": "GET",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.voices"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "voices-explicit-root",
                 "expected": {
                   "result": [
                     {
                       "id": "VoiceCatalog12345",
                       "name": "Studio One",
                       "category": "professional",
                       "description": "Calm narration."
                     },
                     {
                       "id": "VoiceCatalog67890"
                     },
                     {
                       "id": "VoiceCatalog24680",
                       "name": "Studio Three"
                     }
                   ],
                   "requests": [
                     {
                       "url": "https://catalog.example.test/v3/v1/voices",
                       "method": "GET",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.voices"
                     }
                   ],
                   "releaseCount": 1
                 }
               },
               {
                 "id": "voices-default-root",
                 "expected": {
                   "result": [
                     {
                       "id": "VoiceCatalog12345",
                       "name": "Studio One",
                       "category": "professional",
                       "description": "Calm narration."
                     },
                     {
                       "id": "VoiceCatalog67890"
                     },
                     {
                       "id": "VoiceCatalog24680",
                       "name": "Studio Three"
                     }
                   ],
                   "requests": [
                     {
                       "url": "https://api.elevenlabs.io/v1/voices",
                       "method": "GET",
                       "headers": {
                         "xi-api-key": "fixture-elevenlabs-speech-contract"
                       },
                       "timeoutMs": 12345,
                       "auditContext": "elevenlabs.voices"
                     }
                   ],
                   "releaseCount": 1
                 }
               }
             ]
           }
           """)

  test "metadata preserves six advertised models in source order" do
    models = [
      "eleven_v3",
      "eleven_multilingual_v2",
      "eleven_flash_v2_5",
      "eleven_flash_v2",
      "eleven_turbo_v2_5",
      "eleven_monolingual_v1"
    ]

    counts = %{
      "config" => 9,
      "talkConfig" => 5,
      "talkOverrides" => 4,
      "synthesis" => 21,
      "telephony" => 3,
      "streaming" => 4,
      "voices" => 3
    }

    assert Map.new(@raw, fn {group, rows} -> {group, length(rows)} end) == counts
    assert Map.new(@literal, fn {group, rows} -> {group, length(rows)} end) == counts
    assert ElevenLabs.models() == models

    assert Map.take(ElevenLabs.metadata(), [
             :id,
             :label,
             :auto_select_order,
             :default_model,
             :models
           ]) == %{
             id: "elevenlabs",
             label: "ElevenLabs",
             auto_select_order: 20,
             default_model: "eleven_multilingual_v2",
             models: models
           }
  end

  for group <- ["config", "talkConfig", "talkOverrides"],
      {raw, literal} <- Enum.zip(@raw[group], @literal[group]) do
    @group group
    @row raw
    @expected literal
    test "ordinary #{@group}: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]

      actual =
        case @group do
          "config" ->
            ElevenLabs.resolve_config(input["rawConfig"])

          "talkConfig" ->
            ElevenLabs.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])

          "talkOverrides" ->
            ElevenLabs.resolve_talk_overrides(input["params"])
        end

      assert actual == fields(@expected["expected"]["result"])
    end
  end

  for group <- ["synthesis", "telephony"],
      {raw, literal} <- Enum.zip(@raw[group], @literal[group]) do
    @group group
    @row raw
    @expected literal
    test "ordinary exact builder and local HTTP #{@group}: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]
      expected = @expected["expected"]
      [wire] = expected["requests"]
      config = source_config(input)
      request = source_request(input)
      assert {:ok, built} = build(@group, request, config)
      assert_built(built, request, wire, expected["result"])
      assert_buffered_http(@group, request, config, wire, expected["result"])
    end
  end

  for {raw, literal} <- Enum.zip(@raw["streaming"], @literal["streaming"]) do
    @row raw
    @expected literal
    test "true incremental chunks normal EOF then explicit release: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      assert Code.ensure_loaded?(ElevenLabsStream)
      input = @row["input"]
      expected = @expected["expected"]
      [wire] = expected["requests"]
      config = source_config(input)
      request = source_request(input)
      assert {:ok, built} = ElevenLabs.build_stream_request(request, config)
      assert_built(built, request, wire, expected["result"])
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      token = make_ref()
      owner = self()
      path = URI.parse(wire["url"]).path
      chunks = Enum.map(expected["result"]["chunks"], &:erlang.list_to_binary/1)
      assert chunks == [<<0, 1, 2>>, <<3, 4>>, <<5, 6, 7>>]

      Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
        assert_wire(conn, wire)

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_chunked(200)

        conn =
          Enum.reduce(Enum.with_index(chunks), conn, fn {chunk, index}, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            send(owner, {:eleven_chunk_sent, token, index, self()})

            receive do
              {:eleven_continue, ^token, ^index} -> :ok
            after
              10_000 -> raise "consumer did not read original chunk before server continued"
            end

            conn
          end)

        send(owner, {:eleven_server_completed, token})
        conn
      end)

      before = Task.Supervisor.children(Synapsis.Provider.TaskSupervisor)
      local = local_config(config, fixture, wire)
      assert {:ok, opened} = ElevenLabs.stream_synthesize(request, local)
      assert_output(Map.delete(opened, :stream), expected["result"])
      handle = opened.stream
      task = handle.task
      assert is_pid(task.pid)
      assert is_reference(task.ref)
      assert handle.deadline_ms == request.deadline_ms
      assert Process.alive?(task.pid)
      monitor = Process.monitor(task.pid)
      ports = task_ports(task.pid)

      # Each server gate is still closed while that source chunk is read. This
      # proves incrementality without requiring TCP to preserve chunk framing.
      actual =
        Enum.map(Enum.with_index(chunks), fn {chunk, index} ->
          assert_receive {:eleven_chunk_sent, ^token, ^index, server}, 5_000
          actual = read_prefix(handle, byte_size(chunk), <<>>)
          assert actual == chunk
          send(server, {:eleven_continue, token, index})
          actual
        end)

      assert IO.iodata_to_binary(actual) == Base.decode64!(expected["result"]["audioBase64"])
      assert_receive {:eleven_server_completed, ^token}, 5_000
      assert ElevenLabsStream.read(handle) == :eof
      assert ElevenLabsStream.read(handle) == :eof
      assert Process.alive?(task.pid)
      assert task.pid in Task.Supervisor.children(Synapsis.Provider.TaskSupervisor)
      assert {:monitors, monitors} = Process.info(self(), :monitors)
      assert {:process, task.pid} in monitors
      assert ElevenLabsStream.release(handle) == :ok
      assert_receive {:DOWN, ^monitor, :process, pid, :normal} when pid == task.pid, 5_000
      refute Process.alive?(task.pid)
      assert ElevenLabsStream.release(handle) == :ok
      assert Task.Supervisor.children(Synapsis.Provider.TaskSupervisor) -- before == []
      assert {:monitors, monitors} = Process.info(self(), :monitors)
      refute {:process, task.pid} in monitors
      task_ref = task.ref
      refute_receive {^task_ref, _}
      refute_receive {:DOWN, ^task_ref, :process, _, _}
      for port <- ports, do: assert(Port.info(port) == nil)
      Gaoxy.Test.verify!(fixture)
    end
  end

  for {raw, literal} <- Enum.zip(@raw["voices"], @literal["voices"]) do
    @row raw
    @expected literal
    test "explicit successful voice catalog local HTTP: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]
      [wire] = @expected["expected"]["requests"]
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      path = URI.parse(wire["url"]).path
      owner = self()
      token = make_ref()

      Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string == ""
        assert Plug.Conn.get_req_header(conn, "xi-api-key") == [wire["headers"]["xi-api-key"]]
        send(owner, {:eleven_voice_http, token})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(input["response"]))
      end)

      route_req_origin(fixture, wire, token)
      raw_request = input["request"]
      config = fields(raw_request["providerConfig"] || %{})

      request =
        raw_request
        |> Map.delete("providerConfig")
        |> fields()
        |> Map.put(:deadline_ms, System.monotonic_time(:millisecond) + 60_000)

      assert {:ok, actual} = ElevenLabs.list_voices(request, config)
      assert actual == Enum.map(@expected["expected"]["result"], &fields/1)
      assert_receive {:eleven_voice_route, ^token, source_url}, 5_000
      assert source_url == wire["url"]
      assert_receive {:eleven_voice_http, ^token}, 5_000
      Gaoxy.Test.verify!(fixture)
    end
  end

  defp source_config(%{"rawConfig" => raw}), do: ElevenLabs.resolve_config(raw)

  defp source_config(%{"baseTtsConfig" => raw, "talkProviderConfig" => talk}),
    do: ElevenLabs.resolve_talk_config(raw, talk)

  defp source_config(input), do: fields(input["providerConfig"])

  defp source_request(input) do
    raw = input["request"] || input

    overrides =
      if input["talkParams"],
        do: ElevenLabs.resolve_talk_overrides(input["talkParams"]),
        else: fields(raw["providerOverrides"] || %{})

    %{
      text: raw["text"],
      target: target(raw["target"]),
      timeout_ms: raw["timeoutMs"],
      provider_overrides: overrides,
      deadline_ms: System.monotonic_time(:millisecond) + 60_000
    }
  end

  defp target("voice-note"), do: :voice_note
  defp target("telephony"), do: :telephony
  defp target("audio-file"), do: :audio_file
  defp build("synthesis", request, config), do: ElevenLabs.build_request(request, config)

  defp build("telephony", request, config),
    do: ElevenLabs.build_telephony_request(request, config)

  defp synthesize("synthesis", request, config), do: ElevenLabs.synthesize(request, config)

  defp synthesize("telephony", request, config),
    do: ElevenLabs.synthesize_telephony(request, config)

  defp assert_built(built, request, wire, result) do
    assert built.url == wire["url"]
    assert built.body == wire["body"]
    assert built.timeout_ms === wire["timeoutMs"]
    assert built.timeout_ms === request.timeout_ms
    assert built.deadline_ms === request.deadline_ms
    assert_headers(built.headers, wire["headers"])
    assert_output(built, result)
  end

  defp assert_output(actual, result) do
    keys = [:output_format, :file_extension, :voice_compatible, :sample_rate]

    expected =
      result |> Map.take(~w(outputFormat fileExtension voiceCompatible sampleRate)) |> fields()

    assert Map.take(actual, keys) |> Map.reject(fn {_, value} -> is_nil(value) end) == expected

    case expected[:file_extension] do
      ".mp3" -> assert actual[:media_format] == "mp3"
      ".opus" -> assert actual[:media_format] == "opus"
      ".wav" -> assert actual[:media_format] == "wav"
      _ -> refute actual[:media_format]
    end
  end

  defp assert_headers(actual, expected) do
    actual = Map.new(actual, fn {key, value} -> {String.downcase(key), value} end)
    for {key, value} <- expected, do: assert(actual[String.downcase(key)] == value)
    unless Map.has_key?(expected, "Accept"), do: refute(actual["accept"])
  end

  defp assert_wire(conn, wire) do
    assert conn.method == wire["method"]
    assert conn.request_path == URI.parse(wire["url"]).path

    assert URI.decode_query(conn.query_string) ==
             URI.decode_query(URI.parse(wire["url"]).query || "")

    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    assert Jason.decode!(body) == wire["body"]
    assert_headers(conn.req_headers, wire["headers"])
  end

  defp local_config(config, fixture, wire) do
    path = URI.parse(wire["url"]).path
    [prefix, _] = String.split(path, "/v1/text-to-speech/", parts: 2)

    Map.put(
      config,
      :base_url,
      Gaoxy.Test.url(fixture, if(prefix == "", do: "/", else: prefix))
      |> String.trim_trailing("/")
    )
  end

  defp assert_buffered_http(group, request, config, wire, result) do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    path = URI.parse(wire["url"]).path
    audio = Base.decode64!(result["audioBase64"])
    assert audio == <<0, 1, 2, 3, 4, 5, 6, 7>>

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      assert_wire(conn, wire)

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.resp(200, audio)
    end)

    assert {:ok, actual} = synthesize(group, request, local_config(config, fixture, wire))
    assert actual.audio == audio
    assert_output(actual, result)
    Gaoxy.Test.verify!(fixture)
  end

  defp read_prefix(_handle, size, bytes) when byte_size(bytes) == size, do: bytes

  defp read_prefix(handle, size, bytes) do
    assert {:ok, chunk} = ElevenLabsStream.read(handle)
    assert byte_size(chunk) > 0
    assert byte_size(bytes) + byte_size(chunk) <= size
    read_prefix(handle, size, bytes <> chunk)
  end

  defp task_ports(pid) do
    {:links, links} = Process.info(pid, :links)
    Enum.filter(links, &is_port/1)
  end

  defp route_req_origin(fixture, wire, token) do
    original = Application.fetch_env(:req, :default_options)
    defaults = Req.default_options()
    owner = self()
    source_uri = URI.parse(wire["url"])
    local_uri = URI.parse(Gaoxy.Test.url(fixture))

    plugin = fn req ->
      Req.Request.prepend_request_steps(req,
        eleven344_voice_origin: fn outgoing ->
          assert outgoing.url == source_uri
          assert outgoing.method == :get

          routed = %{
            outgoing.url
            | scheme: local_uri.scheme,
              host: local_uri.host,
              port: local_uri.port
          }

          send(owner, {:eleven_voice_route, token, URI.to_string(outgoing.url)})
          %{outgoing | url: routed}
        end
      )
    end

    Req.default_options(Keyword.update(defaults, :plugins, [plugin], &(&1 ++ [plugin])))

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)
  end

  defp fields(map) do
    names = %{
      "apiKey" => :api_key,
      "baseUrl" => :base_url,
      "voiceId" => :voice_id,
      "modelId" => :model_id,
      "seed" => :seed,
      "applyTextNormalization" => :apply_text_normalization,
      "languageCode" => :language_code,
      "voiceSettings" => :voice_settings,
      "stability" => :stability,
      "similarityBoost" => :similarity_boost,
      "style" => :style,
      "useSpeakerBoost" => :use_speaker_boost,
      "speed" => :speed,
      "outputFormat" => :output_format,
      "latencyTier" => :latency_tier,
      "timeoutMs" => :timeout_ms,
      "id" => :id,
      "name" => :name,
      "category" => :category,
      "description" => :description,
      "fileExtension" => :file_extension,
      "voiceCompatible" => :voice_compatible,
      "sampleRate" => :sample_rate
    }

    Map.new(map, fn {key, value} ->
      {Map.fetch!(names, key), if(key == "voiceSettings", do: fields(value), else: value)}
    end)
  end
end
