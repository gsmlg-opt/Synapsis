// Independent literal Fish Audio oracle authored before original-module execution.
// Only ordinary successful callbacks; raw auth/policy/cap fields are provenance, not assertions.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureFishAudioSpeech, FISH_AUDIO_SPEECH_CASES, FISH_AUDIO_SPEECH_PIN,
  FISH_AUDIO_SPEECH_SOURCE } from './capture-fish-audio-speech.mjs';
const source = '/tmp/openclaw-488631c';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/fish-audio-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const inputs = {
  "config": [
    {
      "id": "config-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        }
      }
    },
    {
      "id": "config-model-drama-3",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " drama-3 "
            }
          }
        }
      }
    },
    {
      "id": "config-model-drama-3-preview",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " drama-3-preview "
            }
          }
        }
      }
    },
    {
      "id": "config-model-s2.1-pro-free",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " s2.1-pro-free "
            }
          }
        }
      }
    },
    {
      "id": "config-model-s2.1-pro",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " s2.1-pro "
            }
          }
        }
      }
    },
    {
      "id": "config-model-s2-pro",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " s2-pro "
            }
          }
        }
      }
    },
    {
      "id": "config-model-s1",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": " s1 "
            }
          }
        }
      }
    },
    {
      "id": "config-rich-precedence",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        }
      }
    },
    {
      "id": "config-modelid-voiceid",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "modelId": " s2-pro ",
              "voiceId": " voice-id ",
              "top_p": 0.3,
              "normalize": true
            }
          }
        }
      }
    },
    {
      "id": "config-reference-alias",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "referenceId": " reference-only ",
              "latency": " NORMAL "
            }
          }
        }
      }
    },
    {
      "id": "config-model-first",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s1",
              "modelId": "drama-3-preview"
            }
          }
        }
      }
    },
    {
      "id": "config-unicode-trim",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " ﻿https://fish.example/voice///﻿ ",
              "model": " ﻿s2.1-pro-free﻿ ",
              "voiceId": " ﻿Voice-声音﻿ "
            }
          }
        }
      }
    }
  ],
  "talkConfig": [
    {
      "id": "talk-defaults",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "talkProviderConfig": {}
      }
    },
    {
      "id": "talk-rich-overlay",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": " fixture-fish-talk ",
          "baseUrl": " https://talk.example/fish/// ",
          "modelId": " s1 ",
          "model": "drama-3-preview",
          "speakerVoiceId": " talk-speaker ",
          "voiceId": "talk-second",
          "referenceId": "talk-third",
          "latency": " NORMAL ",
          "speed": 1.4
        }
      }
    },
    {
      "id": "talk-retains-base-options",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "talkProviderConfig": {
          "model": "s2-pro",
          "voiceId": " next-voice "
        }
      }
    },
    {
      "id": "talk-reference-model-alias",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "talkProviderConfig": {
          "model": "drama-3-preview",
          "referenceId": "talk-ref",
          "speed": 1.1
        }
      }
    },
    {
      "id": "talk-explicit-base-key",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": "fixture-fish-speech",
          "baseUrl": "https://api.fish.audio"
        }
      }
    }
  ],
  "talkOverride": [
    {
      "id": "override-empty",
      "input": {
        "params": {}
      }
    },
    {
      "id": "override-modelid-first",
      "input": {
        "params": {
          "modelId": " drama-3 ",
          "model": "s1",
          "speakerVoiceId": " primary ",
          "voiceId": "second",
          "referenceId": "third",
          "speed": 1.25
        }
      }
    },
    {
      "id": "override-model-voice",
      "input": {
        "params": {
          "model": "s2.1-pro-free",
          "voiceId": " voice "
        }
      }
    },
    {
      "id": "override-reference",
      "input": {
        "params": {
          "referenceId": " ref ",
          "speed": 1.3
        }
      }
    },
    {
      "id": "override-talk-keeps-only-surface",
      "input": {
        "params": {
          "model": "s2-pro",
          "temperature": 0.5,
          "topP": 0.4,
          "latency": "low",
          "normalize": true
        }
      }
    }
  ],
  "synthesis": [
    {
      "id": "drama-3-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "drama-3"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "drama-3-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "drama-3"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "drama-3-preview-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "drama-3-preview"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "drama-3-preview-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "drama-3-preview"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2.1-pro-free-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2.1-pro-free"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2.1-pro-free-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2.1-pro-free"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2.1-pro-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2.1-pro"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2.1-pro-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2.1-pro"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2-pro-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2-pro"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s2-pro-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s2-pro"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s1-audio-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s1"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "s1-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "model": "s1"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "rich-config-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "rich-config-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "rich-override-model-first",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "model": " s1 ",
          "modelId": "drama-3",
          "speakerVoiceId": " override-primary ",
          "voiceId": "override-second",
          "referenceId": "override-third",
          "latency": " NORMAL ",
          "speed": 1.5,
          "temperature": 0.45,
          "topP": 0.35,
          "top_p": 0.65,
          "normalize": true
        }
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "override-modelid-voiceid",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "modelId": "drama-3-preview",
          "voiceId": " override-voice ",
          "top_p": 0.55
        }
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "override-reference-only",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "referenceId": " reference-only "
        }
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "exact-text",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "  Fish 🐟\n语音 é\tverbatim  ",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "configured-modelid-top-p",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "modelId": "s2-pro",
              "top_p": 0.25,
              "normalize": true
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "explicit-45s",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 45000,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "explicit-75s",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 75000,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "buffered-telephony-target",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "telephony",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    }
  ],
  "stream": [
    {
      "id": "stream-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    },
    {
      "id": "stream-rich-file",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 45000,
        "providerOverrides": {
          "model": " s1 ",
          "modelId": "drama-3",
          "speakerVoiceId": " override-primary ",
          "voiceId": "override-second",
          "referenceId": "override-third",
          "latency": " NORMAL ",
          "speed": 1.5,
          "temperature": 0.45,
          "topP": 0.35,
          "top_p": 0.65,
          "normalize": true
        }
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    },
    {
      "id": "stream-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    },
    {
      "id": "stream-rich-note",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 45000,
        "providerOverrides": {
          "model": " s1 ",
          "modelId": "drama-3",
          "speakerVoiceId": " override-primary ",
          "voiceId": "override-second",
          "referenceId": "override-third",
          "latency": " NORMAL ",
          "speed": 1.5,
          "temperature": 0.45,
          "topP": 0.35,
          "top_p": 0.65,
          "normalize": true
        }
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    },
    {
      "id": "stream-phone",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "telephony",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    },
    {
      "id": "stream-rich-phone",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "telephony",
        "timeoutMs": 45000,
        "providerOverrides": {
          "model": " s1 ",
          "modelId": "drama-3",
          "speakerVoiceId": " override-primary ",
          "voiceId": "override-second",
          "referenceId": "override-third",
          "latency": " NORMAL ",
          "speed": 1.5,
          "temperature": 0.45,
          "topP": 0.35,
          "top_p": 0.65,
          "normalize": true
        }
      },
      "response": {
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ]
      }
    }
  ],
  "telephony": [
    {
      "id": "phone-forces-file-target",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech"
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "phone-forces-note-target",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {}
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    },
    {
      "id": "phone-overrides",
      "input": {
        "rawConfig": {
          "providers": {
            "fish-audio": {
              "apiKey": "fixture-fish-speech",
              "baseUrl": " https://fish.example/custom/v2/// ",
              "model": " drama-3 ",
              "speakerVoiceId": " primary-voice ",
              "voiceId": "secondary-voice",
              "referenceId": "third-voice",
              "latency": " LOW ",
              "speed": 1.2,
              "temperature": 0.7,
              "topP": 0.6,
              "top_p": 0.4,
              "normalize": false
            }
          }
        },
        "cfg": {},
        "text": "Ordinary Fish speech.",
        "target": "audio-file",
        "timeoutMs": 75000,
        "providerOverrides": {
          "model": " s1 ",
          "modelId": "drama-3",
          "speakerVoiceId": " override-primary ",
          "voiceId": "override-second",
          "referenceId": "override-third",
          "latency": " NORMAL ",
          "speed": 1.5,
          "temperature": 0.45,
          "topP": 0.35,
          "top_p": 0.65,
          "normalize": true
        }
      },
      "response": {
        "audioBase64": "UklGRgABAv8="
      }
    }
  ],
  "voices": [
    {
      "id": "voices-own-public-order-dedup",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-fish-speech",
          "baseUrl": "https://api.fish.audio",
          "model": "s2.1-pro",
          "latency": "balanced"
        }
      },
      "response": {
        "pages": [
          {
            "total": 2,
            "items": [
              {
                "_id": "owned-a",
                "title": " Owned A ",
                "description": " Voice owned-a ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-b",
                "title": " Owned B ",
                "description": " Voice owned-b ",
                "visibility": " private ",
                "languages": [
                  " zh-CN ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          },
          {
            "total": 3,
            "items": [
              {
                "_id": "owned-b",
                "title": " Public duplicate ",
                "description": " Voice owned-b ",
                "visibility": " public ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "public-a",
                "title": " Public A ",
                "description": " Voice public-a ",
                "visibility": " public ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "public-b",
                "title": " Public B ",
                "description": " Voice public-b ",
                "visibility": " public ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          }
        ]
      }
    },
    {
      "id": "voices-two-owned-pages",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-fish-speech",
          "baseUrl": "https://api.fish.audio",
          "model": "s2.1-pro",
          "latency": "balanced"
        },
        "timeoutMs": 45000
      },
      "response": {
        "pages": [
          {
            "total": 102,
            "items": [
              {
                "_id": "owned-000",
                "title": " Own 0 ",
                "description": " Voice owned-000 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-001",
                "title": " Own 1 ",
                "description": " Voice owned-001 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-002",
                "title": " Own 2 ",
                "description": " Voice owned-002 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-003",
                "title": " Own 3 ",
                "description": " Voice owned-003 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-004",
                "title": " Own 4 ",
                "description": " Voice owned-004 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-005",
                "title": " Own 5 ",
                "description": " Voice owned-005 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-006",
                "title": " Own 6 ",
                "description": " Voice owned-006 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-007",
                "title": " Own 7 ",
                "description": " Voice owned-007 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-008",
                "title": " Own 8 ",
                "description": " Voice owned-008 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-009",
                "title": " Own 9 ",
                "description": " Voice owned-009 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-010",
                "title": " Own 10 ",
                "description": " Voice owned-010 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-011",
                "title": " Own 11 ",
                "description": " Voice owned-011 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-012",
                "title": " Own 12 ",
                "description": " Voice owned-012 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-013",
                "title": " Own 13 ",
                "description": " Voice owned-013 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-014",
                "title": " Own 14 ",
                "description": " Voice owned-014 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-015",
                "title": " Own 15 ",
                "description": " Voice owned-015 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-016",
                "title": " Own 16 ",
                "description": " Voice owned-016 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-017",
                "title": " Own 17 ",
                "description": " Voice owned-017 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-018",
                "title": " Own 18 ",
                "description": " Voice owned-018 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-019",
                "title": " Own 19 ",
                "description": " Voice owned-019 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-020",
                "title": " Own 20 ",
                "description": " Voice owned-020 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-021",
                "title": " Own 21 ",
                "description": " Voice owned-021 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-022",
                "title": " Own 22 ",
                "description": " Voice owned-022 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-023",
                "title": " Own 23 ",
                "description": " Voice owned-023 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-024",
                "title": " Own 24 ",
                "description": " Voice owned-024 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-025",
                "title": " Own 25 ",
                "description": " Voice owned-025 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-026",
                "title": " Own 26 ",
                "description": " Voice owned-026 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-027",
                "title": " Own 27 ",
                "description": " Voice owned-027 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-028",
                "title": " Own 28 ",
                "description": " Voice owned-028 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-029",
                "title": " Own 29 ",
                "description": " Voice owned-029 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-030",
                "title": " Own 30 ",
                "description": " Voice owned-030 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-031",
                "title": " Own 31 ",
                "description": " Voice owned-031 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-032",
                "title": " Own 32 ",
                "description": " Voice owned-032 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-033",
                "title": " Own 33 ",
                "description": " Voice owned-033 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-034",
                "title": " Own 34 ",
                "description": " Voice owned-034 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-035",
                "title": " Own 35 ",
                "description": " Voice owned-035 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-036",
                "title": " Own 36 ",
                "description": " Voice owned-036 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-037",
                "title": " Own 37 ",
                "description": " Voice owned-037 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-038",
                "title": " Own 38 ",
                "description": " Voice owned-038 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-039",
                "title": " Own 39 ",
                "description": " Voice owned-039 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-040",
                "title": " Own 40 ",
                "description": " Voice owned-040 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-041",
                "title": " Own 41 ",
                "description": " Voice owned-041 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-042",
                "title": " Own 42 ",
                "description": " Voice owned-042 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-043",
                "title": " Own 43 ",
                "description": " Voice owned-043 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-044",
                "title": " Own 44 ",
                "description": " Voice owned-044 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-045",
                "title": " Own 45 ",
                "description": " Voice owned-045 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-046",
                "title": " Own 46 ",
                "description": " Voice owned-046 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-047",
                "title": " Own 47 ",
                "description": " Voice owned-047 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-048",
                "title": " Own 48 ",
                "description": " Voice owned-048 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-049",
                "title": " Own 49 ",
                "description": " Voice owned-049 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-050",
                "title": " Own 50 ",
                "description": " Voice owned-050 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-051",
                "title": " Own 51 ",
                "description": " Voice owned-051 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-052",
                "title": " Own 52 ",
                "description": " Voice owned-052 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-053",
                "title": " Own 53 ",
                "description": " Voice owned-053 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-054",
                "title": " Own 54 ",
                "description": " Voice owned-054 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-055",
                "title": " Own 55 ",
                "description": " Voice owned-055 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-056",
                "title": " Own 56 ",
                "description": " Voice owned-056 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-057",
                "title": " Own 57 ",
                "description": " Voice owned-057 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-058",
                "title": " Own 58 ",
                "description": " Voice owned-058 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-059",
                "title": " Own 59 ",
                "description": " Voice owned-059 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-060",
                "title": " Own 60 ",
                "description": " Voice owned-060 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-061",
                "title": " Own 61 ",
                "description": " Voice owned-061 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-062",
                "title": " Own 62 ",
                "description": " Voice owned-062 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-063",
                "title": " Own 63 ",
                "description": " Voice owned-063 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-064",
                "title": " Own 64 ",
                "description": " Voice owned-064 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-065",
                "title": " Own 65 ",
                "description": " Voice owned-065 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-066",
                "title": " Own 66 ",
                "description": " Voice owned-066 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-067",
                "title": " Own 67 ",
                "description": " Voice owned-067 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-068",
                "title": " Own 68 ",
                "description": " Voice owned-068 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-069",
                "title": " Own 69 ",
                "description": " Voice owned-069 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-070",
                "title": " Own 70 ",
                "description": " Voice owned-070 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-071",
                "title": " Own 71 ",
                "description": " Voice owned-071 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-072",
                "title": " Own 72 ",
                "description": " Voice owned-072 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-073",
                "title": " Own 73 ",
                "description": " Voice owned-073 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-074",
                "title": " Own 74 ",
                "description": " Voice owned-074 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-075",
                "title": " Own 75 ",
                "description": " Voice owned-075 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-076",
                "title": " Own 76 ",
                "description": " Voice owned-076 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-077",
                "title": " Own 77 ",
                "description": " Voice owned-077 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-078",
                "title": " Own 78 ",
                "description": " Voice owned-078 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-079",
                "title": " Own 79 ",
                "description": " Voice owned-079 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-080",
                "title": " Own 80 ",
                "description": " Voice owned-080 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-081",
                "title": " Own 81 ",
                "description": " Voice owned-081 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-082",
                "title": " Own 82 ",
                "description": " Voice owned-082 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-083",
                "title": " Own 83 ",
                "description": " Voice owned-083 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-084",
                "title": " Own 84 ",
                "description": " Voice owned-084 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-085",
                "title": " Own 85 ",
                "description": " Voice owned-085 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-086",
                "title": " Own 86 ",
                "description": " Voice owned-086 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-087",
                "title": " Own 87 ",
                "description": " Voice owned-087 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-088",
                "title": " Own 88 ",
                "description": " Voice owned-088 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-089",
                "title": " Own 89 ",
                "description": " Voice owned-089 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-090",
                "title": " Own 90 ",
                "description": " Voice owned-090 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-091",
                "title": " Own 91 ",
                "description": " Voice owned-091 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-092",
                "title": " Own 92 ",
                "description": " Voice owned-092 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-093",
                "title": " Own 93 ",
                "description": " Voice owned-093 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-094",
                "title": " Own 94 ",
                "description": " Voice owned-094 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-095",
                "title": " Own 95 ",
                "description": " Voice owned-095 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-096",
                "title": " Own 96 ",
                "description": " Voice owned-096 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-097",
                "title": " Own 97 ",
                "description": " Voice owned-097 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-098",
                "title": " Own 98 ",
                "description": " Voice owned-098 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-099",
                "title": " Own 99 ",
                "description": " Voice owned-099 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          },
          {
            "total": 102,
            "items": [
              {
                "_id": "owned-100",
                "title": " Own 100 ",
                "description": " Voice owned-100 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "owned-101",
                "title": " Own 101 ",
                "description": " Voice owned-101 ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          },
          {
            "total": 2,
            "items": [
              {
                "_id": "owned-000",
                "title": " Duplicate public ",
                "description": " Voice owned-000 ",
                "visibility": " public ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              },
              {
                "_id": "public-next",
                "title": " Public next ",
                "description": " Voice public-next ",
                "visibility": " public ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          }
        ]
      }
    },
    {
      "id": "voices-explicit-connection",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-fish-speech",
          "baseUrl": "https://saved.example/fish",
          "model": "s2.1-pro",
          "latency": "balanced"
        },
        "apiKey": "fixture-fish-speech",
        "baseUrl": " https://voices.example/custom/v3/// ",
        "timeoutMs": 75000
      },
      "response": {
        "pages": [
          {
            "total": 1,
            "items": [
              {
                "_id": "saved-one",
                "title": " Saved One ",
                "description": " Voice saved-one ",
                "visibility": " private ",
                "languages": [
                  " en-US ",
                  "fr-FR"
                ],
                "tags": [
                  " warm ",
                  "clear"
                ]
              }
            ]
          },
          {
            "total": 1,
            "items": [
              {
                "_id": "public-one",
                "title": " Public One ",
                "description": " Voice public-one ",
                "visibility": " public ",
                "languages": [
                  " ja-JP ",
                  "fr-FR"
                ],
                "tags": [
                  " gentle "
                ]
              }
            ]
          }
        ]
      }
    }
  ]
};
const expected = {
  "config": [
    {
      "id": "config-defaults",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-drama-3",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-drama-3-preview",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3-preview",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-s2.1-pro-free",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro-free",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-s2.1-pro",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-s2-pro",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2-pro",
        "latency": "balanced"
      }
    },
    {
      "id": "config-model-s1",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s1",
        "latency": "balanced"
      }
    },
    {
      "id": "config-rich-precedence",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      }
    },
    {
      "id": "config-modelid-voiceid",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2-pro",
        "latency": "balanced",
        "referenceId": "voice-id",
        "topP": 0.3,
        "normalize": true
      }
    },
    {
      "id": "config-reference-alias",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "normal",
        "referenceId": "reference-only"
      }
    },
    {
      "id": "config-model-first",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s1",
        "latency": "balanced"
      }
    },
    {
      "id": "config-unicode-trim",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/voice",
        "model": "s2.1-pro-free",
        "latency": "balanced",
        "referenceId": "Voice-声音"
      }
    }
  ],
  "talkConfig": [
    {
      "id": "talk-defaults",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      }
    },
    {
      "id": "talk-rich-overlay",
      "result": {
        "apiKey": "fixture-fish-talk",
        "baseUrl": "https://talk.example/fish",
        "model": "s1",
        "latency": "normal",
        "referenceId": "talk-speaker",
        "speed": 1.4,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      }
    },
    {
      "id": "talk-retains-base-options",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "s2-pro",
        "latency": "low",
        "referenceId": "next-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      }
    },
    {
      "id": "talk-reference-model-alias",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3-preview",
        "latency": "balanced",
        "referenceId": "talk-ref",
        "speed": 1.1
      }
    },
    {
      "id": "talk-explicit-base-key",
      "result": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      }
    }
  ],
  "talkOverride": [
    {
      "id": "override-empty",
      "result": {}
    },
    {
      "id": "override-modelid-first",
      "result": {
        "model": "drama-3",
        "referenceId": "primary",
        "speed": 1.25
      }
    },
    {
      "id": "override-model-voice",
      "result": {
        "model": "s2.1-pro-free",
        "referenceId": "voice"
      }
    },
    {
      "id": "override-reference",
      "result": {
        "referenceId": "ref",
        "speed": 1.3
      }
    },
    {
      "id": "override-talk-keeps-only-surface",
      "result": {
        "model": "s2-pro"
      }
    }
  ],
  "synthesis": [
    {
      "id": "drama-3-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "drama-3",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "drama-3-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "drama-3",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "drama-3-preview-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3-preview",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "drama-3-preview",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "drama-3-preview-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "drama-3-preview",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "drama-3-preview",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "s2.1-pro-free-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro-free",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro-free",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "s2.1-pro-free-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro-free",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro-free",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "s2.1-pro-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "s2.1-pro-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "s2-pro-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "s2-pro-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "s1-audio-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s1",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "s1-voice-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s1",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
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
      "id": "rich-config-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "drama-3",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "low",
          "reference_id": "primary-voice",
          "prosody": {
            "speed": 1.2
          },
          "temperature": 0.7,
          "top_p": 0.6,
          "normalize": false
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
      "id": "rich-config-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "drama-3",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "low",
          "reference_id": "primary-voice",
          "prosody": {
            "speed": 1.2
          },
          "temperature": 0.7,
          "top_p": 0.6,
          "normalize": false
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
      "id": "rich-override-model-first",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "normal",
          "reference_id": "override-primary",
          "prosody": {
            "speed": 1.5
          },
          "temperature": 0.45,
          "top_p": 0.35,
          "normalize": true
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
      "id": "override-modelid-voiceid",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "drama-3-preview",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced",
          "reference_id": "override-voice",
          "top_p": 0.55
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
      "id": "override-reference-only",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced",
          "reference_id": "reference-only"
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
      "id": "exact-text",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "  Fish 🐟\n语音 é\tverbatim  ",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
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
      "id": "configured-modelid-top-p",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2-pro",
        "latency": "balanced",
        "topP": 0.25,
        "normalize": true
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced",
          "top_p": 0.25,
          "normalize": true
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
      "id": "explicit-45s",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
        },
        "timeoutMs": 45000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    {
      "id": "explicit-75s",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
        },
        "timeoutMs": 75000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    {
      "id": "buffered-telephony-target",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "balanced"
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false
      }
    }
  ],
  "stream": [
    {
      "id": "stream-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "balanced"
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    },
    {
      "id": "stream-rich-file",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "mp3",
          "sample_rate": 44100,
          "latency": "normal",
          "reference_id": "override-primary",
          "prosody": {
            "speed": 1.5
          },
          "temperature": 0.45,
          "top_p": 0.35,
          "normalize": true
        },
        "timeoutMs": 45000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    },
    {
      "id": "stream-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "balanced"
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    },
    {
      "id": "stream-rich-note",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "opus",
          "sample_rate": 48000,
          "latency": "normal",
          "reference_id": "override-primary",
          "prosody": {
            "speed": 1.5
          },
          "temperature": 0.45,
          "top_p": 0.35,
          "normalize": true
        },
        "timeoutMs": 45000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    },
    {
      "id": "stream-phone",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "balanced"
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    },
    {
      "id": "stream-rich-phone",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "normal",
          "reference_id": "override-primary",
          "prosody": {
            "speed": 1.5
          },
          "temperature": 0.45,
          "top_p": 0.35,
          "normalize": true
        },
        "timeoutMs": 45000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false,
        "chunksBase64": [
          "Ukk=",
          "RkYA",
          "AQL/"
        ],
        "cleanupBeforeRelease": 0,
        "cleanupAfterRelease": 1,
        "sourceLockedAfterEof": false
      }
    }
  ],
  "telephony": [
    {
      "id": "phone-forces-file-target",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://api.fish.audio",
        "model": "s2.1-pro",
        "latency": "balanced"
      },
      "request": {
        "url": "https://api.fish.audio/v1/tts",
        "modelHeader": "s2.1-pro",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "balanced"
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "sampleRate": 8000
      }
    },
    {
      "id": "phone-forces-note-target",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "drama-3",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "low",
          "reference_id": "primary-voice",
          "prosody": {
            "speed": 1.2
          },
          "temperature": 0.7,
          "top_p": 0.6,
          "normalize": false
        },
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "sampleRate": 8000
      }
    },
    {
      "id": "phone-overrides",
      "resolvedConfig": {
        "apiKey": "fixture-fish-speech",
        "baseUrl": "https://fish.example/custom/v2",
        "model": "drama-3",
        "latency": "low",
        "referenceId": "primary-voice",
        "speed": 1.2,
        "temperature": 0.7,
        "topP": 0.6,
        "normalize": false
      },
      "request": {
        "url": "https://fish.example/custom/v2/v1/tts",
        "modelHeader": "s1",
        "body": {
          "text": "Ordinary Fish speech.",
          "format": "pcm",
          "sample_rate": 8000,
          "latency": "normal",
          "reference_id": "override-primary",
          "prosody": {
            "speed": 1.5
          },
          "temperature": 0.45,
          "top_p": 0.35,
          "normalize": true
        },
        "timeoutMs": 75000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "pcm",
        "sampleRate": 8000
      }
    }
  ],
  "voices": [
    {
      "id": "voices-own-public-order-dedup",
      "requests": [
        {
          "url": "https://api.fish.audio/model?type=tts&page_size=100&page_number=1&self=true",
          "timeoutMs": 240000
        },
        {
          "url": "https://api.fish.audio/model?type=tts&page_size=100&page_number=1&sort_by=score",
          "timeoutMs": 240000
        }
      ],
      "result": [
        {
          "id": "owned-a",
          "name": "Owned A",
          "description": "Voice owned-a",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-b",
          "name": "Owned B",
          "description": "Voice owned-b",
          "category": "private",
          "locale": "zh-CN",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "public-a",
          "name": "Public A",
          "description": "Voice public-a",
          "category": "public",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "public-b",
          "name": "Public B",
          "description": "Voice public-b",
          "category": "public",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        }
      ]
    },
    {
      "id": "voices-two-owned-pages",
      "requests": [
        {
          "url": "https://api.fish.audio/model?type=tts&page_size=100&page_number=1&self=true",
          "timeoutMs": 45000
        },
        {
          "url": "https://api.fish.audio/model?type=tts&page_size=100&page_number=2&self=true",
          "timeoutMs": 45000
        },
        {
          "url": "https://api.fish.audio/model?type=tts&page_size=100&page_number=1&sort_by=score",
          "timeoutMs": 45000
        }
      ],
      "result": [
        {
          "id": "owned-000",
          "name": "Own 0",
          "description": "Voice owned-000",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-001",
          "name": "Own 1",
          "description": "Voice owned-001",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-002",
          "name": "Own 2",
          "description": "Voice owned-002",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-003",
          "name": "Own 3",
          "description": "Voice owned-003",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-004",
          "name": "Own 4",
          "description": "Voice owned-004",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-005",
          "name": "Own 5",
          "description": "Voice owned-005",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-006",
          "name": "Own 6",
          "description": "Voice owned-006",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-007",
          "name": "Own 7",
          "description": "Voice owned-007",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-008",
          "name": "Own 8",
          "description": "Voice owned-008",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-009",
          "name": "Own 9",
          "description": "Voice owned-009",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-010",
          "name": "Own 10",
          "description": "Voice owned-010",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-011",
          "name": "Own 11",
          "description": "Voice owned-011",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-012",
          "name": "Own 12",
          "description": "Voice owned-012",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-013",
          "name": "Own 13",
          "description": "Voice owned-013",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-014",
          "name": "Own 14",
          "description": "Voice owned-014",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-015",
          "name": "Own 15",
          "description": "Voice owned-015",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-016",
          "name": "Own 16",
          "description": "Voice owned-016",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-017",
          "name": "Own 17",
          "description": "Voice owned-017",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-018",
          "name": "Own 18",
          "description": "Voice owned-018",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-019",
          "name": "Own 19",
          "description": "Voice owned-019",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-020",
          "name": "Own 20",
          "description": "Voice owned-020",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-021",
          "name": "Own 21",
          "description": "Voice owned-021",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-022",
          "name": "Own 22",
          "description": "Voice owned-022",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-023",
          "name": "Own 23",
          "description": "Voice owned-023",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-024",
          "name": "Own 24",
          "description": "Voice owned-024",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-025",
          "name": "Own 25",
          "description": "Voice owned-025",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-026",
          "name": "Own 26",
          "description": "Voice owned-026",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-027",
          "name": "Own 27",
          "description": "Voice owned-027",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-028",
          "name": "Own 28",
          "description": "Voice owned-028",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-029",
          "name": "Own 29",
          "description": "Voice owned-029",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-030",
          "name": "Own 30",
          "description": "Voice owned-030",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-031",
          "name": "Own 31",
          "description": "Voice owned-031",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-032",
          "name": "Own 32",
          "description": "Voice owned-032",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-033",
          "name": "Own 33",
          "description": "Voice owned-033",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-034",
          "name": "Own 34",
          "description": "Voice owned-034",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-035",
          "name": "Own 35",
          "description": "Voice owned-035",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-036",
          "name": "Own 36",
          "description": "Voice owned-036",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-037",
          "name": "Own 37",
          "description": "Voice owned-037",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-038",
          "name": "Own 38",
          "description": "Voice owned-038",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-039",
          "name": "Own 39",
          "description": "Voice owned-039",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-040",
          "name": "Own 40",
          "description": "Voice owned-040",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-041",
          "name": "Own 41",
          "description": "Voice owned-041",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-042",
          "name": "Own 42",
          "description": "Voice owned-042",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-043",
          "name": "Own 43",
          "description": "Voice owned-043",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-044",
          "name": "Own 44",
          "description": "Voice owned-044",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-045",
          "name": "Own 45",
          "description": "Voice owned-045",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-046",
          "name": "Own 46",
          "description": "Voice owned-046",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-047",
          "name": "Own 47",
          "description": "Voice owned-047",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-048",
          "name": "Own 48",
          "description": "Voice owned-048",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-049",
          "name": "Own 49",
          "description": "Voice owned-049",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-050",
          "name": "Own 50",
          "description": "Voice owned-050",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-051",
          "name": "Own 51",
          "description": "Voice owned-051",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-052",
          "name": "Own 52",
          "description": "Voice owned-052",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-053",
          "name": "Own 53",
          "description": "Voice owned-053",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-054",
          "name": "Own 54",
          "description": "Voice owned-054",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-055",
          "name": "Own 55",
          "description": "Voice owned-055",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-056",
          "name": "Own 56",
          "description": "Voice owned-056",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-057",
          "name": "Own 57",
          "description": "Voice owned-057",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-058",
          "name": "Own 58",
          "description": "Voice owned-058",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-059",
          "name": "Own 59",
          "description": "Voice owned-059",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-060",
          "name": "Own 60",
          "description": "Voice owned-060",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-061",
          "name": "Own 61",
          "description": "Voice owned-061",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-062",
          "name": "Own 62",
          "description": "Voice owned-062",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-063",
          "name": "Own 63",
          "description": "Voice owned-063",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-064",
          "name": "Own 64",
          "description": "Voice owned-064",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-065",
          "name": "Own 65",
          "description": "Voice owned-065",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-066",
          "name": "Own 66",
          "description": "Voice owned-066",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-067",
          "name": "Own 67",
          "description": "Voice owned-067",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-068",
          "name": "Own 68",
          "description": "Voice owned-068",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-069",
          "name": "Own 69",
          "description": "Voice owned-069",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-070",
          "name": "Own 70",
          "description": "Voice owned-070",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-071",
          "name": "Own 71",
          "description": "Voice owned-071",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-072",
          "name": "Own 72",
          "description": "Voice owned-072",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-073",
          "name": "Own 73",
          "description": "Voice owned-073",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-074",
          "name": "Own 74",
          "description": "Voice owned-074",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-075",
          "name": "Own 75",
          "description": "Voice owned-075",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-076",
          "name": "Own 76",
          "description": "Voice owned-076",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-077",
          "name": "Own 77",
          "description": "Voice owned-077",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-078",
          "name": "Own 78",
          "description": "Voice owned-078",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-079",
          "name": "Own 79",
          "description": "Voice owned-079",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-080",
          "name": "Own 80",
          "description": "Voice owned-080",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-081",
          "name": "Own 81",
          "description": "Voice owned-081",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-082",
          "name": "Own 82",
          "description": "Voice owned-082",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-083",
          "name": "Own 83",
          "description": "Voice owned-083",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-084",
          "name": "Own 84",
          "description": "Voice owned-084",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-085",
          "name": "Own 85",
          "description": "Voice owned-085",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-086",
          "name": "Own 86",
          "description": "Voice owned-086",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-087",
          "name": "Own 87",
          "description": "Voice owned-087",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-088",
          "name": "Own 88",
          "description": "Voice owned-088",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-089",
          "name": "Own 89",
          "description": "Voice owned-089",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-090",
          "name": "Own 90",
          "description": "Voice owned-090",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-091",
          "name": "Own 91",
          "description": "Voice owned-091",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-092",
          "name": "Own 92",
          "description": "Voice owned-092",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-093",
          "name": "Own 93",
          "description": "Voice owned-093",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-094",
          "name": "Own 94",
          "description": "Voice owned-094",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-095",
          "name": "Own 95",
          "description": "Voice owned-095",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-096",
          "name": "Own 96",
          "description": "Voice owned-096",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-097",
          "name": "Own 97",
          "description": "Voice owned-097",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-098",
          "name": "Own 98",
          "description": "Voice owned-098",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-099",
          "name": "Own 99",
          "description": "Voice owned-099",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-100",
          "name": "Own 100",
          "description": "Voice owned-100",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "owned-101",
          "name": "Own 101",
          "description": "Voice owned-101",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "public-next",
          "name": "Public next",
          "description": "Voice public-next",
          "category": "public",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        }
      ]
    },
    {
      "id": "voices-explicit-connection",
      "requests": [
        {
          "url": "https://voices.example/custom/v3/model?type=tts&page_size=100&page_number=1&self=true",
          "timeoutMs": 75000
        },
        {
          "url": "https://voices.example/custom/v3/model?type=tts&page_size=100&page_number=1&sort_by=score",
          "timeoutMs": 75000
        }
      ],
      "result": [
        {
          "id": "saved-one",
          "name": "Saved One",
          "description": "Voice saved-one",
          "category": "private",
          "locale": "en-US",
          "personalities": [
            "warm",
            "clear"
          ]
        },
        {
          "id": "public-one",
          "name": "Public One",
          "description": "Voice public-one",
          "category": "public",
          "locale": "ja-JP",
          "personalities": [
            "gentle"
          ]
        }
      ]
    }
  ]
};

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const sha = value => createHash('sha256').update(value).digest('hex');
const groups = {
  config: fixture.configObservations,
  talkConfig: fixture.talkConfigObservations,
  talkOverride: fixture.talkOverrideObservations,
  synthesis: fixture.observations,
  stream: fixture.streamObservations,
  telephony: fixture.telephonyObservations,
  voices: fixture.voiceObservations,
};
const metadata = {id:'fish-audio',label:'Fish Audio',autoSelectOrder:28,defaultTimeoutMs:240000,
  defaultModel:'s2.1-pro',models:['drama-3','drama-3-preview','s2.1-pro-free','s2.1-pro','s2-pro','s1']};
const wire = request => ({url:request.url,modelHeader:request.init.headers.model,
  body:JSON.parse(request.init.body),timeoutMs:request.timeoutMs});
const synthesis = row => ({id:row.id,resolvedConfig:row.resolvedConfig,
  request:wire(row.requests[0]),result:row.result});

test('all56 independently frozen raw recipes and factory metadata match the original callback surface', () => {
  assert.equal(FISH_AUDIO_SPEECH_PIN,pin);
  assert.equal(FISH_AUDIO_SPEECH_SOURCE,'extensions/fish-audio-speech/speech-provider.ts');
  assert.equal(fixture.referencePin,pin);
  assert.deepEqual(FISH_AUDIO_SPEECH_CASES,inputs);
  assert.deepEqual(fixture.providerMetadata,metadata);
  assert.deepEqual(Object.fromEntries(Object.entries(groups).map(([key,rows])=>[key,rows.length])),
    {config:12,talkConfig:5,talkOverride:5,synthesis:22,stream:6,telephony:3,voices:3});
  assert.deepEqual(fixture.counts,{config:12,talkConfig:5,talkOverride:5,synthesis:22,stream:6,
    telephony:3,voices:3,totalObservations:56,httpRequests:38,releases:38,wholeModules:11,
    trackedFilesBefore:58558,trackedFilesAfter:58558});
  for(const rows of Object.values(groups)) for(const row of rows) assert.deepEqual(row.providerMetadata,metadata);
});

test('all12 configs retain six models defaults whitespace alias precedence and explicit ordinary options', () => {
  assert.deepEqual(groups.config.map(({id,result})=>({id,result})),expected.config);
});

test('all five Talk configs retain base options with the distinct modelId-first Talk overlay', () => {
  assert.deepEqual(groups.talkConfig.map(({id,result})=>({id,result})),expected.talkConfig);
});

test('all five Talk override callbacks emit the exact model reference and speed result shape', () => {
  assert.deepEqual(groups.talkOverride.map(({id,result})=>({id,result})),expected.talkOverride);
});

test('all22 buffered callbacks retain literal wire model header exact text and opaque output metadata', () => {
  assert.deepEqual(groups.synthesis.map(synthesis),expected.synthesis);
  for(const row of groups.synthesis) assert.equal(row.requests[0].init.method,'POST');
});

test('each of the six models produces distinct MP3 file and Opus voice-note contracts', () => {
  for(const model of metadata.models) {
    const file=groups.synthesis.find(row=>row.id===model+'-audio-file');
    const note=groups.synthesis.find(row=>row.id===model+'-voice-note');
    assert.deepEqual(file.result,{audioBase64:'UklGRgABAv8=',outputFormat:'mp3',fileExtension:'.mp3',voiceCompatible:false});
    assert.deepEqual(note.result,{audioBase64:'UklGRgABAv8=',outputFormat:'opus',fileExtension:'.opus',voiceCompatible:true});
    assert.equal(wire(file.requests[0]).body.sample_rate,44100);
    assert.equal(wire(note.requests[0]).body.sample_rate,48000);
  }
});

test('all six original streams preserve ordered chunks through EOF then explicit request release', () => {
  assert.deepEqual(groups.stream.map(synthesis),expected.stream);
  for(const row of groups.stream) {
    assert.equal(row.requests[0].init.method,'POST');
    assert.deepEqual(row.streamLifecycle,{doneCount:1,releaseCalls:1,sourceLockedAfterRelease:false,
      sourceEvents:[{type:'chunk',index:0,audioBase64:'Ukk='},
        {type:'chunk',index:1,audioBase64:'RkYA'},{type:'chunk',index:2,audioBase64:'AQL/'},{type:'eof'}]});
  }
});

test('all three telephony callbacks force PCM8000 independent of the supplied file or note target', () => {
  assert.deepEqual(groups.telephony.map(synthesis),expected.telephony);
  for(const row of groups.telephony) assert.equal(row.requests[0].init.method,'POST');
});

test('owned voice pagination precedes the public catalog and retains literal first-id metadata and order', () => {
  assert.deepEqual(groups.voices.map(row=>({id:row.id,
    requests:row.requests.map(request=>({url:request.url,timeoutMs:request.timeoutMs})),result:row.result})),expected.voices);
  const paged=groups.voices.find(row=>row.id==='voices-two-owned-pages');
  assert.equal(paged.requests.length,3);
  assert.equal(paged.result.length,103);
  assert.equal(paged.result[0].name,'Own 0');
  assert.equal(paged.result[102].id,'public-next');
});

test('all callback inputs and prepared synthesis requests remain unchanged with one release per request', () => {
  for(const [kind,rows] of Object.entries(groups)) for(const row of rows) {
    const raw=inputs[kind].find(input=>input.id===row.id);
    assert.deepEqual(row.input,raw.input);
    assert.deepEqual(row.inputAfter,raw.input);
    if(raw.response) assert.deepEqual(row.response,raw.response);
    assert.equal(row.releaseCount,row.requests.length);
    if(['config','talkConfig','talkOverride'].includes(kind)) assert.equal(row.requests.length,0);
    if(['synthesis','stream','telephony'].includes(kind)) {
      assert.equal(row.requests.length,1);
      assert.deepEqual(row.synthesisRequestAfter,row.synthesisRequest);
      assert.deepEqual(row.synthesisRequest,{text:raw.input.text,target:raw.input.target,
        timeoutMs:raw.input.timeoutMs,providerConfig:row.resolvedConfig,
        providerOverrides:raw.input.providerOverrides,cfg:raw.input.cfg});
    }
  }
});

test('all11 whole original modules retain exact pinned source TS-erasure executable and data provenance', () => {
  const required=['extensions/fish-audio-speech/speech-provider.ts',
    'packages/normalization-core/src/string-coerce.ts','packages/normalization-core/src/record-coerce.ts',
    'packages/normalization-core/src/number-coercion.ts','packages/normalization-core/src/string-normalization.ts',
    'src/utils/boolean.ts','src/tts/tts-provider-helpers.ts','src/tts/directive-parser.ts',
    'src/tts/directive-number.ts','packages/media-core/src/constants.ts','src/plugin-sdk/provider-binary-stream.ts'];
  assert.deepEqual(fixture.sourceAudit.map(row=>row.path),required);
  assert.equal(fixture.checkout.before.verified,true);
  assert.equal(fixture.checkout.before.commit,pin);
  assert.equal(fixture.checkout.before.verifiedTrackedFiles,58558);
  assert.deepEqual(fixture.checkout.after,fixture.checkout.before);
  for(const row of fixture.sourceAudit) {
    assert.equal(row.wholeModule,true);
    assert.equal(row.executed,true);
    const bytes=readFileSync(join(source,row.path));
    assert.equal(row.sourceSha256,sha(bytes));
    assert.equal(row.executableSha256,sha(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})));
    const blob=execFileSync('git',['-C',source,'rev-parse',pin+':'+row.path],{encoding:'utf8',timeout:30000}).trim();
    assert.equal(row.gitBlob,blob);
  }
  assert.deepEqual(fixture.dataAudit.map(row=>row.path),['extensions/fish-audio-speech/openclaw.plugin.json','LICENSE']);
  for(const row of fixture.dataAudit) {
    assert.equal(row.evaluated,false);
    assert.equal(row.sourceSha256,sha(readFileSync(join(source,row.path))));
    assert.equal(row.gitBlob,execFileSync('git',['-C',source,'rev-parse',pin+':'+row.path],
      {encoding:'utf8',timeout:30000}).trim());
  }
  assert.deepEqual(fixture.pluginManifest,JSON.parse(readFileSync(join(source,'extensions/fish-audio-speech/openclaw.plugin.json'))));
  assert.equal(fixture.license.text,readFileSync(join(source,'LICENSE'),'utf8'));
  assert.deepEqual(fixture.transformation.options,{mode:'transform',sourceMap:false});
  assert.equal(fixture.transformation.api,'node:module.stripTypeScriptTypes');
  for(const row of fixture.transformation.sdkFacades) assert.equal(row.sha256,sha(row.source));
  assert.equal(fixture.harness.sha256,sha(readFileSync(fixture.harness.path)));
});

test('synthetic platform exports are inventoried separately from the executed original modules', () => {
  assert.deepEqual(fixture.platformBoundaries.map(row=>[row.module,Object.keys(row.exports)]),[
    ['openclaw/plugin-sdk/secret-input',['normalizeResolvedSecretInputString']],
    ['openclaw/plugin-sdk/ssrf-runtime',['ssrfPolicyFromHttpBaseUrlAllowedHostname','fetchWithSsrFGuard']],
    ['openclaw/plugin-sdk/provider-http',['assertOkOrThrowProviderError','readProviderBinaryResponse',
      'readProviderJsonResponse','assertProviderBinaryResponseContent']],
    ['openclaw/plugin-sdk/media-generation-runtime',['resolveGeneratedMediaMaxBytes']],
    ['node:fs',['rmSync']],
  ]);
  assert.equal(fixture.transformation.sdkFacades.length,5);
});

test('fresh isolated original-module capture equals the entire saved fixture', async () => {
  assert.deepEqual(await captureFishAudioSpeech(source),fixture);
});

test('fresh CLI capture equals the saved full JSON without replacing the fixture', () => {
  const temp=mkdtempSync(join(tmpdir(),'synapsis-fish-audio-speech-oracle-'));
  try {
    const output=join(temp,'capture.json');
    execFileSync(process.execPath,['--experimental-vm-modules',
      fileURLToPath(new URL('./capture-fish-audio-speech.mjs',import.meta.url)),
      '--source',source,'--output',output],{cwd:resolve('.'),timeout:90000,stdio:['ignore','pipe','pipe']});
    assert.deepEqual(JSON.parse(readFileSync(output,'utf8')),fixture);
  } finally { rmSync(temp,{recursive:true,force:true}); }
});
