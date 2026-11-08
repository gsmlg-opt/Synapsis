// Complete pinned ElevenLabs ordinary callbacks and completed streams only.
// Parent owns execution with Node 24 --experimental-vm-modules; no extracted source helpers.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { ReadableStream } from 'node:stream/web';

export const ELEVENLABS_SPEECH_CONTRACT_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const ELEVENLABS_SPEECH_CONTRACT_SOURCE = 'extensions/elevenlabs/speech-provider-factory.ts';
// Exact independently authored raw callback inputs; no expected observations are read.
export const ELEVENLABS_SPEECH_CONTRACT_CASES = {
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
};

const sourcePaths = [ELEVENLABS_SPEECH_CONTRACT_SOURCE, 'extensions/elevenlabs/shared.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'src/utils/boolean.ts', 'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/record-coerce.ts',
  'packages/media-core/src/constants.ts', 'src/plugin-sdk/provider-binary-stream.ts'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;
const fixtureKey = 'fixture-elevenlabs-speech-contract';
const audioBytes = Buffer.from([0, 1, 2, 3, 4, 5, 6, 7]);
const streamChunks = [[0, 1, 2], [3, 4], [5, 6, 7]];
const lineRange = bytes => ({ startLine: 1,
  endLine: bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0) });

// Export wiring only: each original implementation executes from its whole module.
const sdkFacades = {
  'openclaw/plugin-sdk/provider-binary-stream':
    'export { createBoundedProviderBinaryStream } from "src/plugin-sdk/provider-binary-stream.ts";\n',
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
    normalizeResolvedSecretInputString: 'Explicit undefined or fixture dummy string only, with recorded path/value. No production secret resolution executes.',
  },
  'extensions/elevenlabs/config-api.ts': {
    resolveElevenLabsApiKeyWithProfileFallback: 'Counted undefined fixture, including the eager source invocation with an explicit key. No profile/environment discovery executes.',
  },
  'node:fs': {
    rmSync: 'Throwing, uninvoked binding needed to evaluate the complete helper module. No cleanup or filesystem callback executes.',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'Successful synthetic status/response-identity facade only; production status/error behavior unexecuted.',
    readProviderBinaryResponse: 'Returns eight opaque fixture bytes; original buffered reader and MIME/limit behavior unexecuted.',
    readProviderJsonResponse: 'Returns the independently supplied successful voices fixture JSON; original HTTP JSON reader unexecuted.',
    assertProviderBinaryResponseContent: 'Successful synthetic response/body-identity facade; original content validation unexecuted.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'Records exact source HTTP arguments and returns successful synthetic audio/JSON or finite three-chunk stream with counted release. No sockets or guard algorithm.',
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Records source base URL and returns an opaque fixture token. Production policy unexecuted.',
  },
};
const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({
  module, originalSourceExecuted: false, exports,
}));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), ELEVENLABS_SPEECH_CONTRACT_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', ELEVENLABS_SPEECH_CONTRACT_PIN])
    .split('\0').filter(Boolean).map(entry => {
      const [header, source] = entry.split('\t');
      const [mode, type, blob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
      const file = join(root, source), stat = lstatSync(file), symlink = stat.isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', source + ' mode');
      assert.ok(realpathSync(file).startsWith(root + sep));
      const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
      return { path: source, mode, gitBlob: blob, sha256: hash(bytes) };
    });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: ELEVENLABS_SPEECH_CONTRACT_PIN,
    tree: git(root, ['rev-parse', `${ELEVENLABS_SPEECH_CONTRACT_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('ElevenLabs speech contract capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class ElevenLabsSpeechContractCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.responses = [];
    this.calls = [];
    this.releaseCount = 0;
    this.staticImports = [];
    this.dynamicImports = [];
    this.sourceReads = 0;
    this.sourceCancels = 0;
    this.sourceStream = undefined;
    this.fetch = () => { throw Error('Ambient fetch excluded; use the named successful HTTP facade'); };
    this.context = vm.createContext({ Buffer, URL, Uint8Array, ReadableStream,
      fetch: this.fetch, process: { env: {} } }, { codeGeneration: { strings: false, wasm: false } });
  }
  called(module, name, result, details = {}) {
    this.calls.push({ module, export: name, ...details });
    return result;
  }
  responseFacts(response, label) {
    assert.ok(this.responses.includes(response), 'synthetic response identity');
    return { responseIndex: this.responses.indexOf(response), status: response.status,
      ...(label === undefined ? {} : { label }) };
  }
  finiteSourceStream() {
    let index = 0;
    const stream = new ReadableStream({
      pull: controller => {
        this.sourceReads += 1;
        if (index < streamChunks.length) controller.enqueue(Uint8Array.from(streamChunks[index++]));
        else controller.close();
      },
      cancel: () => { this.sourceCancels += 1; },
    }, { highWaterMark: 0 });
    this.sourceStream = stream;
    return stream;
  }
  platformModule(identifier) {
    const called = (name, result, details = {}) => this.called(identifier, name, result, details);
    const bindings = {};
    if (identifier === 'openclaw/plugin-sdk/secret-input') {
      bindings.normalizeResolvedSecretInputString = ({ value, path: secretPath }) => {
        assert.ok(value === undefined || (typeof value === 'string' && value.trim() === fixtureKey),
          'secret facade supports undefined or explicit fixture dummy only');
        return called('normalizeResolvedSecretInputString', value?.trim() || undefined,
          { provenanceOnly: true, path: secretPath, ...(value === undefined ? {} : { value }) });
      };
    } else if (identifier === 'extensions/elevenlabs/config-api.ts') {
      bindings.resolveElevenLabsApiKeyWithProfileFallback = () =>
        called('resolveElevenLabsApiKeyWithProfileFallback', undefined);
    } else if (identifier === 'node:fs') {
      bindings.rmSync = () => { throw Error('Excluded filesystem cleanup binding invoked'); };
    } else if (identifier === 'openclaw/plugin-sdk/ssrf-runtime') {
      bindings.ssrfPolicyFromHttpBaseUrlAllowedHostname = url =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicy: 'elevenlabs-source-url' },
          { provenanceOnly: true, url });
      bindings.fetchWithSsrFGuard = async params => {
        const requestIndex = this.requests.length;
        this.requests.push({ url: params.url, method: params.init.method ?? 'GET',
          headers: plain(params.init.headers),
          ...(params.init.body === undefined ? {} : { body: JSON.parse(params.init.body) }),
          timeoutMs: params.timeoutMs, auditContext: params.auditContext });
        const response = { ok: true, status: 200,
          ...(this.kind === 'streaming' ? { body: this.finiteSourceStream() } : {}),
          ...(this.kind === 'voices' ? { fixtureJson: plain(this.recipe.input.response) }
            : { fixtureAudioBase64: audioBytes.toString('base64') }) };
        this.responses.push(response);
        called('fetchWithSsrFGuard', undefined, { requestIndex, provenanceOnly: true,
          sourceArguments: { init: plain(params.init), policy: plain(params.policy),
            auditContext: params.auditContext } });
        return { response, release: async () => {
          this.releaseCount += 1;
          called('release', undefined, { requestIndex });
        } };
      };
    } else if (identifier === 'openclaw/plugin-sdk/provider-http') {
      bindings.assertOkOrThrowProviderError = async (response, label) => {
        assert.equal(response.ok, true);
        return called('assertOkOrThrowProviderError', undefined, this.responseFacts(response, label));
      };
      bindings.readProviderBinaryResponse = async (response, label, kind, options) => {
        const bytes = Buffer.from(response.fixtureAudioBase64, 'base64');
        called('readProviderBinaryResponse', undefined, { ...this.responseFacts(response, label),
          kind, optionsProvided: options !== undefined, audioBase64: bytes.toString('base64'),
          byteLength: bytes.length });
        return bytes;
      };
      bindings.readProviderJsonResponse = async (response, label) => {
        called('readProviderJsonResponse', undefined, this.responseFacts(response, label));
        return plain(response.fixtureJson);
      };
      bindings.assertProviderBinaryResponseContent = (response, label, kind) => {
        assert.equal(response.body, this.sourceStream);
        return called('assertProviderBinaryResponseContent', undefined,
          { ...this.responseFacts(response, label), kind });
      };
    }
    const names = Object.keys(boundaries[identifier]);
    for (const name of names) assert.ok(Object.hasOwn(bindings, name), `named facade export: ${identifier} ${name}`);
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
      assert.equal(typeof executable, 'string', `declared complete original source or facade: ${identifier}`);
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
  async consumeCompletedStream(result) {
    const { audioStream, release, ...metadata } = result;
    const releaseBeforeConsumption = this.releaseCount;
    const reader = audioStream.getReader();
    const chunks = [];
    let completed = false;
    try {
      await withDeadline((async () => {
        while (true) {
          const next = await reader.read();
          if (next.done) { completed = true; break; }
          chunks.push(Array.from(next.value));
        }
      })());
    } finally { reader.releaseLock(); }
    const releaseAfterEof = this.releaseCount;
    const sourceLockedAfterEof = this.sourceStream.locked;
    await withDeadline(release());
    const streamLifecycle = { sourceReads: this.sourceReads, sourceCancels: this.sourceCancels,
      releaseBeforeConsumption, releaseAfterEof, releaseAfterExplicitRelease: this.releaseCount,
      sourceLockedAfterEof };
    const bytes = Buffer.concat(chunks.map(chunk => Buffer.from(chunk)));
    return { result: { audioBase64: bytes.toString('base64'), ...plain(metadata), chunks,
      byteLength: bytes.length, completed }, streamLifecycle };
  }
  async run() {
    const source = this.module(ELEVENLABS_SPEECH_CONTRACT_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildElevenLabsSpeechProvider({ formatErrorMessage: error => String(error) });
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      metadata.callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      metadata.absentFields = ['aliases', 'defaultTimeoutMs', 'prepareSynthesis'].filter(key => !Object.hasOwn(provider, key));
      if (observationKind === 'config') return { metadata, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverrides') return { metadata, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, result: await provider.listVoices(speechInput.request) };
      let request = JSON.parse(JSON.stringify(speechInput.request ?? speechInput));
      let resolvedConfig;
      if (Object.hasOwn(speechInput, 'rawConfig')) {
        resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig });
      } else if (Object.hasOwn(speechInput, 'baseTtsConfig')) {
        resolvedConfig = provider.resolveTalkConfig({ baseTtsConfig: speechInput.baseTtsConfig,
          talkProviderConfig: speechInput.talkProviderConfig });
      }
      if (resolvedConfig !== undefined) request.providerConfig = resolvedConfig;
      if (Object.hasOwn(speechInput, 'talkParams')) {
        request.providerOverrides = { ...(request.providerOverrides ?? {}),
          ...provider.resolveTalkOverrides({ params: speechInput.talkParams }) };
      }
      request = { cfg: {}, ...request };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      const callback = observationKind === 'telephony' ? 'synthesizeTelephony'
        : observationKind === 'streaming' ? 'streamSynthesize' : 'synthesize';
      const sourceResult = await provider[callback](request);
      let result = sourceResult;
      if (observationKind !== 'streaming') {
        const { audioBuffer, ...resultMetadata } = sourceResult;
        result = { audioBase64: audioBuffer.toString('base64'), ...resultMetadata };
      }
      return { metadata, result, ...(resolvedConfig === undefined ? {} : { resolvedConfig }),
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    const stream = this.kind === 'streaming' ? await this.consumeCompletedStream(execution.result) : undefined;
    const http = ['synthesis', 'telephony', 'streaming', 'voices'].includes(this.kind);
    assert.equal(this.requests.length, http ? 1 : 0, 'ordinary successful callback request count');
    assert.equal(this.releaseCount, http ? 1 : 0, 'ordinary successful callback release count');
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      ...(Object.hasOwn(execution, 'resolvedConfig') ? { resolvedConfig: plain(execution.resolvedConfig) } : {}),
      result: stream ? stream.result : plain(execution.result),
      ...(stream ? { streamLifecycle: stream.streamLifecycle } : {}),
      ...(execution.synthesisRequest ? { synthesisRequest: plain(execution.synthesisRequest),
        synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls };
    return { observation, metadata: plain(execution.metadata),
      staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(sourcePath => this.modules.get(sourcePath)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureElevenLabsSpeechContract(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const sourceAudit = sourcePaths.map(sourcePath => {
    const bytes = readFileSync(join(root, sourcePath));
    const original = execFileSync('git', ['-C', root, 'show', `${ELEVENLABS_SPEECH_CONTRACT_PIN}:${sourcePath}`], {
      timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete pinned source bytes: ${sourcePath}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(sourcePath, executable);
    return { path: sourcePath, gitBlob: git(root, ['rev-parse', `${ELEVENLABS_SPEECH_CONTRACT_PIN}:${sourcePath}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, readRange: lineRange(bytes),
      executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  assert.deepEqual(Object.keys(ELEVENLABS_SPEECH_CONTRACT_CASES),
    ['config', 'talkConfig', 'talkOverrides', 'synthesis', 'telephony', 'streaming', 'voices']);
  const groups = {};
  for (const [kind, recipes] of Object.entries(ELEVENLABS_SPEECH_CONTRACT_CASES)) {
    assert.ok(recipes.length > 0, 'independent raw recipes embedded before execution');
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new ElevenLabsSpeechContractCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  assert.equal(evaluated.size, sourcePaths.length, 'all eleven complete original runtime modules evaluate');
  const metadata = runs[0].metadata;
  for (const run of runs) assert.deepEqual(run.metadata, metadata, 'stable provider metadata across isolated contexts');
  const after = verifyCheckout(root);
  assert.deepEqual(after, before, 'pinned checkout remains identical after source capture');
  return { schemaVersion: 1, sourcePin: ELEVENLABS_SPEECH_CONTRACT_PIN,
    harness: { path: 'scripts/openclaw/capture-elevenlabs-speech-contract.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    sourceAudit, sourceIntegrity: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    metadata,
    observations: Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.map(run => run.observation)])),
    counts: { ...Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length])),
      totalObservations: runs.length, wholeModules: evaluated.size,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0) },
    platformBoundaries,
    globalBoundaries: {
      process: 'Fresh VM process.env={} only. No ambient environment, credential/profile/auth-store lookup or source readiness execution.',
      fetch: 'Throwing ambient binding. Only named synthetic successful HTTP facade executes.',
      Buffer: 'Native Buffer carries eight opaque fixture bytes; no codec, valid audio or playback evidence.',
      ReadableStream: 'Native node:stream/web implementation supplies finite three-chunk input. Entire original bounded-stream module owns its reader and normal EOF/release; no replacement wrapper.',
      clock: 'Raw source timeouts pass to synthetic HTTP only; 2000ms VM/asynchronous harness deadlines are execution bounds, not source timeout acceptance.',
    },
    limits: [
      'All58558 pinned tracked blobs, modes and symlinks verified before/after; eleven complete original modules equal pinned Git bytes before TypeScript erasure.',
      'Complete provider/shared/helpers/parser/number/boolean/string/record/media-constant modules and provider-binary-stream evaluate; evaluation does not invoke every export or branch.',
      'Original factory metadata, raw/resolved config, Talk config/overrides, successful buffered/phone/voice-list callbacks and completed streaming callbacks execute only ordinary successful inputs.',
      'Original stream wrapper consumes three finite chunks, reads normal EOF, releases source reader lock, then receives one explicit release. EOF itself does not run request cleanup; row lifecycle records actual counts.',
      'The real bounded-stream normal path executes, but cap/budget/overflow, interruption, cancellation, early release, error handling and failure cleanup remain unqualified.',
      'Secret/profile, successful HTTP/status/buffered reader/JSON reader/content validation/policy are named synthetic boundaries; original MIME, authentication, profile, network and policy algorithms are not executed.',
      'Original directive parser is constructed only; directive dispatch, isConfigured/isConfiguredAsync/readiness, plugin registration, transcription and native host integration remain unexecuted.',
      'Opaque bytes establish source assembly/metadata/ordinary EOF ownership only, not codecs, native publication, supplier acceptance or player behavior.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed/directory suites, budget/truncation/eviction/threshold/race, real supplier or remote MCP qualification.',
    ],
  };
}
export async function writeElevenLabsSpeechContractCapture(root, output) {
  const capture = await captureElevenLabsSpeechContract(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  if (args.length && !args[0].startsWith('--')) {
    assert.ok(args.length <= 2, 'Usage: capture-elevenlabs-speech-contract.mjs [ROOT [OUTPUT]]');
    [root, output] = args;
  } else {
    for (let index = 0; index < args.length; index += 2) {
      assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
        'Usage: capture-elevenlabs-speech-contract.mjs --source-root DIR [--output FILE]');
      if (args[index] === '--source-root') root = args[index + 1];
      else output = args[index + 1];
    }
  }
  if (output) return writeElevenLabsSpeechContractCapture(root, output);
  const capture = await captureElevenLabsSpeechContract(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
