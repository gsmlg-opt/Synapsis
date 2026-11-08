// Independent ordinary source oracle authored before the first target execution.
// This file embeds literals; it never reads temporary oracle files at runtime.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import {
  captureElevenLabsSpeechContract, ELEVENLABS_SPEECH_CONTRACT_CASES,
  ELEVENLABS_SPEECH_CONTRACT_PIN, ELEVENLABS_SPEECH_CONTRACT_SOURCE,
} from './capture-elevenlabs-speech-contract.mjs';

const root = process.env.OPENCLAW_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const fixtureUrl = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/elevenlabs-speech-contract.json', import.meta.url);
const rawInputs = {
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

const literalExpected = {
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
};

const metadataExpected = {
  "id": "elevenlabs",
  "label": "ElevenLabs",
  "autoSelectOrder": 20,
  "defaultModel": "eleven_multilingual_v2",
  "models": [
    "eleven_v3",
    "eleven_multilingual_v2",
    "eleven_flash_v2_5",
    "eleven_flash_v2",
    "eleven_turbo_v2_5",
    "eleven_monolingual_v1"
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
    "streamSynthesize",
    "synthesizeTelephony"
  ],
  "absentFields": [
    "aliases",
    "defaultTimeoutMs",
    "prepareSynthesis"
  ]
};

const prior31 = [
  {
    "path": "scripts/openclaw/capture-elevenlabs-speech.mjs",
    "sha256": "663338acc6a9f90970712cbb00b0934bd54a9b8c5b5547ceb02b85411d6a3581",
    "bytes": 20457
  },
  {
    "path": "scripts/openclaw/elevenlabs-speech-functional.test.mjs",
    "sha256": "ad86926e1da341baea118c863e1cdff740e1e2268a4caf42d8335109143ec4dc",
    "bytes": 14087
  },
  {
    "path": "apps/synapsis_agent/test/fixtures/openclaw/488631c/elevenlabs-speech.json",
    "sha256": "bef8bfe4059bd2ae52c5b5612ef910316325cd1fcac8d1b20657380bf5dbe0de",
    "bytes": 143161
  }
];

// Read-only independent full checkout integrity: all original tracked source,
// including unexecuted modules, must match the pinned Git objects and modes.
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
const capture = await captureElevenLabsSpeechContract(root);
const sourceAfter = trackedSourceSnapshot();
const sourcePaths = [
  'extensions/elevenlabs/speech-provider-factory.ts',
  'extensions/elevenlabs/shared.ts',
  'src/tts/tts-provider-helpers.ts',
  'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts',
  'src/utils/boolean.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts',
  'packages/media-core/src/constants.ts',
  'src/plugin-sdk/provider-binary-stream.ts',
];

test('complete ordinary ElevenLabs factory metadata is source-derived', () => {
  assert.equal(ELEVENLABS_SPEECH_CONTRACT_PIN, pin);
  assert.equal(ELEVENLABS_SPEECH_CONTRACT_SOURCE, sourcePaths[0]);
  assert.equal(capture.schemaVersion, 1);
  assert.equal(capture.sourcePin, pin);
  assert.deepEqual(capture.metadata, metadataExpected);
});

test('all49 independent raw inputs and literal ordinary outcomes match', () => {
  assert.deepEqual(ELEVENLABS_SPEECH_CONTRACT_CASES, rawInputs);
  assert.deepEqual(Object.keys(capture.observations), Object.keys(rawInputs));
  assert.deepEqual(Object.fromEntries(Object.entries(rawInputs).map(([name, rows]) => [name, rows.length])),
    { config:9, talkConfig:5, talkOverrides:4, synthesis:21, telephony:3, streaming:4, voices:3 });
  for (const [group, inputs] of Object.entries(rawInputs)) {
    const actual = capture.observations[group], expected = literalExpected[group];
    assert.deepEqual(actual.map(row => row.id), inputs.map(row => row.id), group);
    assert.deepEqual(expected.map(row => row.id), inputs.map(row => row.id), group);
    for (let index = 0; index < inputs.length; index += 1) {
      const row = actual[index], input = inputs[index].input, want = expected[index].expected;
      assert.deepEqual(row.input, input, row.id);
      assert.deepEqual(row.inputAfter, input, row.id + ': unchanged raw input');
      for (const [field, value] of Object.entries(want)) assert.deepEqual(row[field], value, row.id + ': ' + field);
      assert.equal(Object.hasOwn(row, 'resolvedConfig'), Object.hasOwn(want, 'resolvedConfig'), row.id);
      if (['synthesis','telephony','streaming'].includes(group)) {
        assert.deepEqual(row.synthesisRequestAfter, row.synthesisRequest, row.id + ': unchanged synthesis request');
        assert.equal(row.requests.length, 1, row.id);
      }
      if (['synthesis','telephony','streaming','voices'].includes(group)) {
        for (const name of ['fetchWithSsrFGuard','release']) {
          assert.equal(row.platformCalls.filter(call => call.export === name).length, 1, row.id + ': ' + name);
        }
      } else assert.equal(row.requests.length, 0, row.id);
    }
  }
});

test('whole pinned modules, import graph and original stream helper stay intact', () => {
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
  assert.equal(capture.harness.path, 'scripts/openclaw/capture-elevenlabs-speech-contract.mjs');
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-elevenlabs-speech-contract.mjs', import.meta.url))));
  assert.equal(capture.transformation.api, 'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options, { mode:'transform', sourceMap:false });
  assert.deepEqual(capture.transformation.sdkFacades.map(item => item.module), [
    'openclaw/plugin-sdk/provider-binary-stream',
    'openclaw/plugin-sdk/number-runtime',
    'openclaw/plugin-sdk/string-coerce-runtime',
    'openclaw/plugin-sdk/speech-provider',
    '@openclaw/normalization-core/string-coerce',
    '@openclaw/normalization-core/number-coercion',
  ]);
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256, hash(facade.source), facade.module);
    assert.ok(facade.source.split('\n').filter(Boolean).every(line => /^export (?:\*|\{[^}]+\}) from (['"])[^'"]+\1;$/.test(line)), facade.module);
  }
  const streamFacade = capture.transformation.sdkFacades.find(item => item.module === 'openclaw/plugin-sdk/provider-binary-stream');
  assert.ok(streamFacade.source.includes('src/plugin-sdk/provider-binary-stream.ts'));
  const expectedStaticEdges = [
    ['extensions/elevenlabs/speech-provider-factory.ts','openclaw/plugin-sdk/number-runtime'],
    ['extensions/elevenlabs/speech-provider-factory.ts','openclaw/plugin-sdk/secret-input'],
    ['extensions/elevenlabs/speech-provider-factory.ts','openclaw/plugin-sdk/speech-provider'],
    ['extensions/elevenlabs/speech-provider-factory.ts','openclaw/plugin-sdk/string-coerce-runtime'],
    ['extensions/elevenlabs/speech-provider-factory.ts','extensions/elevenlabs/config-api.ts'],
    ['extensions/elevenlabs/speech-provider-factory.ts','extensions/elevenlabs/shared.ts'],
    ['openclaw/plugin-sdk/provider-binary-stream','src/plugin-sdk/provider-binary-stream.ts'],
    ['openclaw/plugin-sdk/number-runtime','packages/normalization-core/src/number-coercion.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/number-coercion.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/record-coerce.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/string-coerce.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','src/utils/boolean.ts'],
    ['openclaw/plugin-sdk/speech-provider','src/tts/directive-parser.ts'],
    ['openclaw/plugin-sdk/speech-provider','src/tts/tts-provider-helpers.ts'],
    ['openclaw/plugin-sdk/speech-provider','packages/media-core/src/constants.ts'],
    ['@openclaw/normalization-core/string-coerce','packages/normalization-core/src/string-coerce.ts'],
    ['@openclaw/normalization-core/number-coercion','packages/normalization-core/src/number-coercion.ts'],
    ['src/tts/tts-provider-helpers.ts','node:fs'],
    ['src/tts/tts-provider-helpers.ts','@openclaw/normalization-core/string-coerce'],
    ['src/tts/directive-parser.ts','src/tts/directive-number.ts'],
    ['src/tts/directive-number.ts','@openclaw/normalization-core/number-coercion'],
    ['src/utils/boolean.ts','@openclaw/normalization-core/string-coerce'],
    ['packages/normalization-core/src/number-coercion.ts','packages/normalization-core/src/string-coerce.ts'],
  ];
  const edges = values => values.map(value => JSON.stringify(value)).sort();
  assert.deepEqual(edges(capture.transformation.staticImports.map(item => [item.importer, item.resolved])), edges(expectedStaticEdges));
  assert.deepEqual(new Set(capture.transformation.dynamicImports.map(item => item.specifier)), new Set([
    'openclaw/plugin-sdk/provider-http', 'openclaw/plugin-sdk/ssrf-runtime',
    'openclaw/plugin-sdk/provider-binary-stream',
  ]));
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

test('only completed ordinary streams drain every original chunk then release once', () => {
  for (const row of capture.observations.streaming) {
    assert.deepEqual(row.result.chunks, [[0,1,2],[3,4],[5,6,7]], row.id);
    assert.equal(row.result.audioBase64, 'AAECAwQFBgc=', row.id);
    assert.equal(row.result.byteLength, 8, row.id);
    assert.equal(row.result.completed, true, row.id);
    assert.deepEqual(row.streamLifecycle, {
      sourceReads:4, sourceCancels:0, releaseBeforeConsumption:0,
      releaseAfterEof:0, releaseAfterExplicitRelease:1, sourceLockedAfterEof:false,
    }, row.id);
    assert.equal(row.platformCalls.filter(call => call.export === 'readProviderBinaryResponse').length, 0, row.id);
    assert.equal(row.platformCalls.filter(call => call.export === 'assertProviderBinaryResponseContent').length, 1, row.id);
  }
  assert.ok(capture.sourceAudit.some(item => item.path === 'src/plugin-sdk/provider-binary-stream.ts' && item.executed));
  const boundaries = JSON.stringify(capture.platformBoundaries).toLowerCase();
  assert.ok(boundaries.includes('synthetic'));
  assert.ok(boundaries.includes('no sockets'));
  assert.ok(boundaries.includes('no profile/environment discovery'));
  const limits = (capture.limits.join('\n') + JSON.stringify(capture.globalBoundaries)).toLowerCase();
  for (const phrase of ['codec','directive','environment','readiness','synthetic']) assert.ok(limits.includes(phrase), phrase);
});

test('fresh API and CLI captures equal the frozen fixture and preserve old31', async () => {
  const frozen = JSON.parse(readFileSync(fixtureUrl));
  assert.deepEqual(capture, frozen);
  assert.deepEqual(await captureElevenLabsSpeechContract(root), frozen);
  const cli = execFileSync(process.execPath, [
    '--experimental-vm-modules',
    fileURLToPath(new URL('./capture-elevenlabs-speech-contract.mjs', import.meta.url)),
    '--source-root', root,
  ], { encoding:'utf8', maxBuffer:32 * 1024 * 1024, timeout:300000,
    env:{ ...process.env, NODE_NO_WARNINGS:'1' } });
  assert.deepEqual(JSON.parse(cli), frozen);
  assert.deepEqual(trackedSourceSnapshot(), sourceBefore);
  for (const prior of prior31) {
    const bytes = readFileSync(new URL('../../' + prior.path, import.meta.url));
    assert.equal(bytes.length, prior.bytes, prior.path);
    assert.equal(hash(bytes), prior.sha256, prior.path);
  }
});
