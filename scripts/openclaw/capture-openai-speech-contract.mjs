// Complete pinned OpenAI Speech callbacks; successful fixture inputs only.
// Parent-owned Node 24 execution with --experimental-vm-modules; original TS erasure only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path, { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const OPENAI_SPEECH_CONTRACT_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const OPENAI_SPEECH_CONTRACT_SOURCE = 'extensions/openai/speech-provider.ts';
// Independently authored raw callback inputs only; no literal expected observations are read.
export const OPENAI_SPEECH_CONTRACT_CASES = {
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
};

const shared = 'extensions/openai/realtime-provider-shared.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const audio = 'src/media/audio.ts';
const mime = 'packages/media-core/src/mime.ts';
const mediaConstants = 'packages/media-core/src/constants.ts';
const fileName = 'packages/media-core/src/file-name.ts';
const sourcePaths = [OPENAI_SPEECH_CONTRACT_SOURCE, shared, strings, records, numbers,
  directiveParser, directiveNumber, audio, mime, mediaConstants, fileName];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;
const opaqueAudioBase64 = 'UklGRgABAv8=';
const lineRange = bytes => ({ startLine: 1,
  endLine: bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0) });

// Export wiring only: complete original normalization, parser and media modules execute.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    `export { createSpeechDirectiveParser } from '${directiveParser}';\nexport { parseSpeechDirectiveNumberOverride } from '${directiveNumber}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asOptionalRecord } from '${records}';\nexport { asFiniteNumber } from '${numbers}';\nexport { normalizeLowercaseStringOrEmpty, normalizeOptionalLowercaseString, normalizeOptionalString } from '${strings}';`,
  'openclaw/plugin-sdk/number-runtime': `export { resolveExpiresAtMsFromEpochSeconds } from '${numbers}';`,
  '@openclaw/normalization-core/number-coercion': `export * from '${numbers}';`,
  '@openclaw/normalization-core/string-coerce': `export * from '${strings}';`,
  'openclaw/plugin-sdk/media-runtime': `export { isVoiceMessageCompatibleAudio } from '${audio}';`,
  '@openclaw/media-core/mime': `export * from '${mime}';`,
};
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Named ordinary-success facade supports undefined or explicit fixture dummy strings only. It records path/value provenance and trims the dummy string; no credential/auth-store/environment lookup executes.',
  },
  'openclaw/plugin-sdk/provider-http': {
    resolveProviderRequestHeaders: 'Named successful passthrough facade returns undefined so original default-header assembly executes. Header inputs are provenance only; authentication, header policy and credential selection are unqualified.',
    assertOkOrThrowProviderError: 'Named synthetic successful status facade records response identity/label only. Original error/status handling is unexecuted.',
    readProviderBinaryResponse: 'Named synthetic successful reader returns eight opaque fixture bytes and records options. Original reader, media limits, codecs and deadlines are unexecuted.',
  },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'Named synthetic media-cap facade records cfg/kind and returns a fixed ordinary cap; no cap/budget/overflow semantics are qualified.',
  },
  'openclaw/plugin-sdk/proxy-capture': {
    isDebugProxyGlobalFetchPatchInstalled: 'Named synthetic facade always reports false. No global proxy patch, environment or capture installation is exercised.',
    captureHttpExchangeAsync: 'Named successful capture facade records source-produced provenance and returns a resolved promise; no network, persistence, capture failure or cancellation executes.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Records the source-produced base URL and returns an opaque policy token. No hostname/TLS/security/policy algorithm executes.',
    fetchWithSsrFGuard: 'Named synthetic successful HTTP facade records exact URL/method/body/raw timeout in order and returns a successful synthetic response plus counted release. No network or guard algorithm executes.',
  },
  'node:path': {
    default: 'Native Node path implementation used by complete original media filename helpers for ordinary speech.mp3/speech.opus/speech.wav names only; no path safety, URL decoding, traversal or negative qualification.',
  },
};
const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({ module, exports }));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), OPENAI_SPEECH_CONTRACT_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', OPENAI_SPEECH_CONTRACT_PIN])
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
  return { verified: true, commit: OPENAI_SPEECH_CONTRACT_PIN,
    tree: git(root, ['rev-parse', `${OPENAI_SPEECH_CONTRACT_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('OpenAI speech contract capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class OpenAISpeechContractCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.calls = [];
    this.responses = [];
    this.releaseCount = 0;
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetch = () => { throw Error('Ambient fetch excluded; use the named synthetic successful HTTP facade'); };
    this.context = vm.createContext({ Buffer, URL, Uint8Array, fetch: this.fetch, process: { env: {} } },
      { codeGeneration: { strings: false, wasm: false } });
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
  platformModule(identifier) {
    const called = (name, result, details = {}) => this.called(identifier, name, result, details);
    const bindings = {};
    if (identifier === 'openclaw/plugin-sdk/secret-input') {
      bindings.normalizeResolvedSecretInputString = ({ value, path: secretPath }) => {
        assert.ok(value === undefined || (typeof value === 'string' && value.trim() === 'fixture-openai-speech'),
          'secret facade supports undefined or the explicit fixture dummy only');
        return called('normalizeResolvedSecretInputString', value?.trim() || undefined,
          { provenanceOnly: true, path: secretPath, ...(value === undefined ? {} : { value }) });
      };
    } else if (identifier === 'openclaw/plugin-sdk/ssrf-runtime') {
      bindings.ssrfPolicyFromHttpBaseUrlAllowedHostname = url =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicy: 'openai-source-url' },
          { provenanceOnly: true, url });
      bindings.fetchWithSsrFGuard = async params => {
        const requestIndex = this.requests.length;
        this.requests.push({ url: params.url, method: params.init.method,
          body: JSON.parse(params.init.body), timeoutMs: params.timeoutMs });
        const response = { ok: true, status: 200, fixtureAudioBase64: opaqueAudioBase64 };
        this.responses.push(response);
        called('fetchWithSsrFGuard', undefined, { requestIndex, provenanceOnly: true,
          sourceArguments: { init: plain(params.init), policy: plain(params.policy),
            capture: params.capture, ...(params.pinDns === undefined ? {} : { pinDns: params.pinDns }),
            auditContext: params.auditContext } });
        return { response, release: async () => {
          this.releaseCount += 1;
          called('release', undefined, { requestIndex });
        } };
      };
    } else if (identifier === 'openclaw/plugin-sdk/provider-http') {
      bindings.resolveProviderRequestHeaders = params =>
        called('resolveProviderRequestHeaders', undefined, { provenanceOnly: true, input: plain(params) });
      bindings.assertOkOrThrowProviderError = async (response, label) =>
        called('assertOkOrThrowProviderError', undefined, this.responseFacts(response, label));
      bindings.readProviderBinaryResponse = async (response, label, kind, options) => {
        const output = Buffer.from(response.fixtureAudioBase64, 'base64');
        called('readProviderBinaryResponse', undefined, { ...this.responseFacts(response, label), kind,
          options: { maxBytes: options.maxBytes, onOverflow: typeof options.onOverflow },
          audioBase64: output.toString('base64'), byteLength: output.length });
        return output;
      };
    } else if (identifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      bindings.resolveGeneratedMediaMaxBytes = (cfg, kind) =>
        called('resolveGeneratedMediaMaxBytes', 1_048_576, { input: plain(cfg), kind });
    } else if (identifier === 'openclaw/plugin-sdk/proxy-capture') {
      bindings.isDebugProxyGlobalFetchPatchInstalled = () =>
        called('isDebugProxyGlobalFetchPatchInstalled', false);
      bindings.captureHttpExchangeAsync = async ({ response, ...input }) =>
        called('captureHttpExchangeAsync', undefined,
          { provenanceOnly: true, ...this.responseFacts(response), input: plain(input) });
    } else if (identifier === 'node:path') bindings.default = path;
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
      assert.equal(typeof executable, 'string', `declared original source or facade: ${identifier}`);
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
    const source = this.module(OPENAI_SPEECH_CONTRACT_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildOpenAISpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      metadata.callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      metadata.absentFields = ['aliases', 'defaultTimeoutMs', 'prepareSynthesis', 'streamSynthesize'].filter(key => !Object.hasOwn(provider, key));
      if (observationKind === 'config') return { metadata, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverrides') return { metadata, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, result: await provider.listVoices(speechInput) };
      let request = JSON.parse(JSON.stringify(speechInput));
      let resolvedConfig;
      if (speechInput.mode === 'normalizeThenSynthesize') {
        resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig });
        const { mode, rawConfig, ...rest } = request;
        request = { ...rest, providerConfig: resolvedConfig };
      } else if (speechInput.mode === 'resolveTalkThenSynthesize') {
        resolvedConfig = provider.resolveTalkConfig({ baseTtsConfig: speechInput.baseTtsConfig,
          talkProviderConfig: speechInput.talkProviderConfig });
        const { mode, baseTtsConfig, talkProviderConfig, ...rest } = request;
        request = { ...rest, providerConfig: resolvedConfig };
      }
      request = { cfg: {}, ...request };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      const callback = observationKind === 'telephony' ? 'synthesizeTelephony' : 'synthesize';
      const { audioBuffer, ...resultMetadata } = await provider[callback](request);
      return { metadata, result: { audioBase64: audioBuffer.toString('base64'), ...resultMetadata },
        ...(resolvedConfig === undefined ? {} : { resolvedConfig }),
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    const synthesizes = this.kind === 'synthesis' || this.kind === 'telephony';
    assert.equal(this.requests.length, synthesizes ? 1 : 0, 'ordinary callback request count');
    assert.equal(this.releaseCount, synthesizes ? 1 : 0, 'ordinary callback release count');
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      result: plain(execution.result),
      ...(Object.hasOwn(execution, 'resolvedConfig') ? { resolvedConfig: plain(execution.resolvedConfig) } : {}),
      ...(execution.synthesisRequest ? { synthesisRequest: plain(execution.synthesisRequest),
        synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls };
    return { observation, metadata: plain(execution.metadata),
      staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(sourcePath => this.modules.get(sourcePath)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureOpenAISpeechContract(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const sourceAudit = sourcePaths.map(sourcePath => {
    const bytes = readFileSync(join(root, sourcePath));
    const original = execFileSync('git', ['-C', root, 'show', `${OPENAI_SPEECH_CONTRACT_PIN}:${sourcePath}`], {
      timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete pinned source bytes: ${sourcePath}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(sourcePath, executable);
    return { path: sourcePath, gitBlob: git(root, ['rev-parse', `${OPENAI_SPEECH_CONTRACT_PIN}:${sourcePath}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, readRange: lineRange(bytes),
      executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  assert.deepEqual(Object.keys(OPENAI_SPEECH_CONTRACT_CASES), ['config', 'talkConfig', 'talkOverrides', 'synthesis', 'telephony', 'voices']);
  const groups = {};
  for (const [kind, recipes] of Object.entries(OPENAI_SPEECH_CONTRACT_CASES)) {
    assert.ok(recipes.length > 0, 'independent raw recipes are embedded before execution');
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new OpenAISpeechContractCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  assert.equal(evaluated.size, sourcePaths.length, 'all eleven complete original runtime modules evaluate');
  const metadata = runs[0].metadata;
  for (const run of runs) assert.deepEqual(run.metadata, metadata, 'stable provider metadata across isolated contexts');
  const after = verifyCheckout(root);
  assert.deepEqual(after, before, 'pinned checkout remains identical after source capture');
  return {
    schemaVersion: 1, sourcePin: OPENAI_SPEECH_CONTRACT_PIN,
    harness: { path: 'scripts/openclaw/capture-openai-speech-contract.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
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
      process: 'Isolated VM process.env={} only. No ambient environment, API-key fallback acceptance, auth store or credential lookup is exercised.',
      fetch: 'Throwing ambient binding. Only the named synthetic successful HTTP facade runs.',
      Buffer: 'Native Buffer carries eight opaque synthetic bytes. No audio codec, playback or actual media format is established.',
      clock: 'Source passes raw ordinary timeouts, including fractions, to the facade. Harness VM/asynchronous deadlines bound execution only; source timeout/cancellation behavior is unqualified.',
    },
    limits: [
      'All 58558 pinned tracked blobs, modes and symlinks are verified before and after; complete original runtime modules match pinned Git bytes before TypeScript erasure only.',
      'Eleven complete original modules evaluate: OpenAI provider/shared, string/record/number normalization, directive parser/number, media audio/MIME/constants/filename. Whole-module evaluation is not all-branch execution.',
      'Original factory, metadata, resolveConfig, resolveTalkConfig, resolveTalkOverrides, static listVoices, buffered synthesis and telephony callbacks execute ordinary positive recipes only.',
      'Original directive parser construction executes; directive dispatch, policy/readiness logic, isConfigured/isConfiguredAsync, realtime helpers, MIME sniffing and unrelated media operations are not invoked.',
      'Source-derived callback absence records aliases, defaultTimeoutMs, prepareSynthesis and streamSynthesize. No plugin installation, activation, production integration or stream support is established.',
      'Original normalization, Talk overlay, valid custom-base acceptance, instruction selection, extraBody merge, exact raw text/JSON requests, ordinary timeout passthrough and output metadata execute.',
      'Original voice-message helper executes for source-produced ordinary speech.mp3/speech.opus/speech.wav filenames. This is filename compatibility metadata, not codec or network evidence.',
      'Secret normalization, successful HTTP/status/reader/media-cap and proxy capture are named synthetic facades; headers, policy and dummy credential fields are provenance only, not authentication/header/security/TLS qualification.',
      'Eight opaque response bytes and counted release establish ordinary callback assembly and cleanup only. No real network, provider, codec, cap/budget/overflow or capture persistence behavior is qualified.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, directory suites, budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
  };
}
export async function writeOpenAISpeechContractCapture(root, output) {
  const capture = await captureOpenAISpeechContract(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-openai-speech-contract.mjs --source-root DIR [--output FILE]');
    if (args[index] === '--source-root') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) return writeOpenAISpeechContractCapture(root, output);
  const capture = await captureOpenAISpeechContract(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
