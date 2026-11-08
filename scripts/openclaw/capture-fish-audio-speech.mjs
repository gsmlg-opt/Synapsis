// Complete pinned Fish Audio source callbacks; ordinary successful fixture inputs only.
// Node 24.21.0 with --experimental-vm-modules; original algorithms receive TS erasure only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const FISH_AUDIO_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const FISH_AUDIO_SPEECH_SOURCE = 'extensions/fish-audio-speech/speech-provider.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const lists = 'packages/normalization-core/src/string-normalization.ts';
const booleans = 'src/utils/boolean.ts';
const keyHelper = 'src/tts/tts-provider-helpers.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const constants = 'packages/media-core/src/constants.ts';
const streamHelper = 'src/plugin-sdk/provider-binary-stream.ts';
const sourcePaths = [FISH_AUDIO_SPEECH_SOURCE, strings, records, numbers, lists, booleans,
  keyHelper, directiveParser, directiveNumber, constants, streamHelper];
const manifestPath = 'extensions/fish-audio-speech/openclaw.plugin.json';
const licensePath = 'LICENSE';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;

// Independently authored raw input/response recipes; no expected output values.
export const FISH_AUDIO_SPEECH_CASES = {
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

// Export wiring only; original complete executable modules remain unchanged after TS erasure.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    `export { MAX_AUDIO_BYTES } from '${constants}';
export { createSpeechDirectiveParser } from '${directiveParser}';
export { resolveSpeechProviderApiKey } from '${keyHelper}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asBoolean, parseBooleanValue } from '${booleans}';
export { asFiniteNumberInRange } from '${numbers}';
export { asOptionalRecord, filterStringRecord } from '${records}';
export { normalizeOptionalString } from '${strings}';
export { normalizeTrimmedStringList } from '${lists}';`,
  '@openclaw/normalization-core/string-coerce':
    `export { normalizeOptionalLowercaseString, normalizeOptionalString } from '${strings}';`,
  '@openclaw/normalization-core/number-coercion':
    `export { asFiniteNumberInRange, parseStrictFiniteNumber } from '${numbers}';`,
  'openclaw/plugin-sdk/provider-binary-stream':
    `export { createBoundedProviderBinaryStream } from '${streamHelper}';`,
};
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Trims only explicit positive fixture strings, records raw value/path; production secret module and credential authority unexecuted.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Returns opaque tagged base URL provenance without evaluating a policy.',
    fetchWithSsrFGuard: 'Records original caller URL/init/raw headers/body/timeout/policy/auditContext; returns synthetic successful response and counted release. Original guarded HTTP unexecuted.',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'Records synthetic successful status call; original status/error/header-transfer validation unexecuted.',
    readProviderBinaryResponse: 'Records original reader arguments as provenance; returns opaque fixture bytes; original reader/cap logic unexecuted.',
    readProviderJsonResponse: 'Records original reader arguments as provenance; returns fixture JSON; original reader/cap logic unexecuted.',
    assertProviderBinaryResponseContent: 'Records synthetic successful call; original response-content validation unexecuted.',
  },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'Returns positive fixture byte limit and records cfg/kind; no cap/threshold behavior qualification.',
  },
  'node:fs': { rmSync: 'Uninvoked throwing binding for unrelated original scheduleCleanup export.' },
};
const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({ module, exports }));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), FISH_AUDIO_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', FISH_AUDIO_SPEECH_PIN])
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
  return { verified: true, commit: FISH_AUDIO_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${FISH_AUDIO_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Fish Audio speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class FishAudioSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.calls = [];
    this.responses = [];
    this.releaseCount = 0;
    this.sourceEvents = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.context = vm.createContext({ Buffer, URL, Headers, ReadableStream, Uint8Array,
      process: { env: {} }, captureStreamState: () => ({
        cleanupCount: this.releaseCount,
        sourceLocked: this.sourceBody?.locked ?? null,
      }) }, { codeGeneration: { strings: false, wasm: false } });
  }

  makeResponse() {
    const response = { status: 200, ok: true,
      headers: new Headers({ 'Content-Type': this.kind === 'voices' ? 'application/json' : 'audio/mpeg' }) };
    if (this.kind === 'voices') response.fixtureJson = plain(this.recipe.response.pages[this.responses.length]);
    else if (this.kind === 'stream') {
      const chunks = this.recipe.response.chunksBase64.map(value => Uint8Array.from(Buffer.from(value, 'base64')));
      let index = 0;
      this.sourceBody = new ReadableStream({
        pull: controller => {
          if (index < chunks.length) {
            this.sourceEvents.push({ type: 'chunk', index, audioBase64: Buffer.from(chunks[index]).toString('base64') });
            controller.enqueue(chunks[index++]);
          } else {
            this.sourceEvents.push({ type: 'eof' });
            controller.close();
          }
        },
        cancel: () => { this.sourceEvents.push({ type: 'cancel' }); },
      });
      response.body = this.sourceBody;
    }
    this.responses.push(response);
    return response;
  }

  platformModule(identifier) {
    const called = (name, result, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return result;
    };
    const bindings = {
      normalizeResolvedSecretInputString: ({ value, path }) =>
        called('normalizeResolvedSecretInputString', typeof value === 'string' ? value.trim() : undefined,
          { path, ...(value === undefined ? {} : { value }) }),
      ssrfPolicyFromHttpBaseUrlAllowedHostname: baseUrl =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicyBaseUrl: baseUrl }, { baseUrl }),
      fetchWithSsrFGuard: async params => {
        this.requests.push(plain(params));
        const response = this.makeResponse();
        called('fetchWithSsrFGuard', undefined, { requestIndex: this.requests.length - 1 });
        return { response, release: async () => {
          this.releaseCount += 1;
          called('release', undefined, { requestIndex: this.responses.indexOf(response) });
        } };
      },
      assertOkOrThrowProviderError: async (response, label, options) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        called('assertOkOrThrowProviderError', undefined, { status: response.status, label, options: plain(options) });
      },
      readProviderBinaryResponse: async (response, label, kind, options) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        called('readProviderBinaryResponse', undefined, { status: response.status, label, kind, options: plain(options) });
        return Buffer.from(this.recipe.response.audioBase64, 'base64');
      },
      readProviderJsonResponse: async (response, label, options) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        called('readProviderJsonResponse', undefined, { status: response.status, label, options: plain(options) });
        return plain(response.fixtureJson);
      },
      assertProviderBinaryResponseContent: (response, label, kind) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        called('assertProviderBinaryResponseContent', undefined, { status: response.status, label, kind });
      },
      resolveGeneratedMediaMaxBytes: (cfg, kind) =>
        called('resolveGeneratedMediaMaxBytes', 16 * 1024 * 1024, { cfg: plain(cfg), kind }),
      rmSync: () => { throw Error('Uninvoked synthetic rmSync binding called'); },
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
    const source = this.module(FISH_AUDIO_SPEECH_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildFishAudioSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      if (observationKind === 'config') return { metadata, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverride') return { metadata, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, result: await provider.listVoices(speechInput) };
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig });
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: speechInput.cfg };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      let result;
      if (observationKind === 'stream') {
        const streamed = await provider.streamSynthesize(request);
        const reader = streamed.audioStream.getReader();
        const chunksBase64 = [];
        let doneCount = 0;
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) { doneCount += 1; break; }
          chunksBase64.push(Buffer.from(chunk.value).toString('base64'));
        }
        reader.releaseLock();
        const afterEof = captureStreamState();
        await streamed.release();
        const afterRelease = captureStreamState();
        result = { chunksBase64, audioBase64: Buffer.concat(chunksBase64.map(chunk => Buffer.from(chunk, 'base64'))).toString('base64'),
          outputFormat: streamed.outputFormat, fileExtension: streamed.fileExtension, voiceCompatible: streamed.voiceCompatible,
          cleanupBeforeRelease: afterEof.cleanupCount, cleanupAfterRelease: afterRelease.cleanupCount,
          sourceLockedAfterEof: afterEof.sourceLocked };
        return { metadata, result, resolvedConfig, synthesisRequest,
          synthesisRequestAfter: JSON.parse(JSON.stringify(request)),
          streamLifecycle: { doneCount, releaseCalls: 1, sourceLockedAfterRelease: afterRelease.sourceLocked } };
      }
      const buffered = observationKind === 'telephony'
        ? await provider.synthesizeTelephony(request) : await provider.synthesize(request);
      const { audioBuffer, ...resultMetadata } = buffered;
      result = { audioBase64: audioBuffer.toString('base64'), ...resultMetadata };
      return { metadata, result, resolvedConfig, synthesisRequest,
        synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      result: plain(execution.result), providerMetadata: plain(execution.metadata),
      ...(execution.resolvedConfig ? { resolvedConfig: plain(execution.resolvedConfig),
        synthesisRequest: plain(execution.synthesisRequest), synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      ...(this.recipe.response ? { response: plain(this.recipe.response) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls,
      ...(this.kind === 'stream' ? { streamLifecycle: { ...plain(execution.streamLifecycle), sourceEvents: this.sourceEvents } } : {}),
    };
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureFishAudioSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${FISH_AUDIO_SPEECH_PIN}:${path}`], {
      timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete pinned source bytes: ${path}`);
    return bytes;
  };
  const sourceAudit = sourcePaths.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${FISH_AUDIO_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const manifestBytes = readOriginal(manifestPath), licenseBytes = readOriginal(licensePath);
  const groups = {};
  for (const [kind, recipes] of Object.entries(FISH_AUDIO_SPEECH_CASES)) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new FishAudioSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  const groupCounts = Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length]));
  return {
    schemaVersion: 1, referencePin: FISH_AUDIO_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-fish-audio-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [
      { path: manifestPath, gitBlob: git(root, ['rev-parse', `${FISH_AUDIO_SPEECH_PIN}:${manifestPath}`]), sourceSha256: hash(manifestBytes),
        usage: 'Complete original manifest data provenance; no JSON import or plugin registration executes.', evaluated: false },
      { path: licensePath, gitBlob: git(root, ['rev-parse', `${FISH_AUDIO_SPEECH_PIN}:${licensePath}`]), sourceSha256: hash(licenseBytes),
        usage: 'Complete original source license provenance.', evaluated: false },
    ],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries,
    globalBoundaries: { process: 'Recipe VM env={} only, no ambient credentials.',
      ReadableStream: 'Node native Web Stream primitive; positive synthetic underlying source, original bounded stream algorithm.',
      clock: 'No invoked original algorithm uses clock APIs; unused date helpers are retained in whole module.' },
    providerMetadata: runs[0].observation.providerMetadata,
    counts: { ...groupCounts, totalObservations: runs.length,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0),
      wholeModules: evaluated.size, trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverride.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    streamObservations: groups.stream.map(run => run.observation),
    telephonyObservations: groups.telephony.map(run => run.observation),
    voiceObservations: groups.voices.map(run => run.observation),
    limits: [
      'All 58558 pinned tracked blobs/modes verified before and after; each complete executable source module additionally matches pinned Git bytes before TS erasure only.',
      'Whole-module evaluation does not imply all exports/branches execute. Original provider config/Talk/synthesis/stream/telephony/listVoices and helpers execute only ordinary positive recipes.',
      'Original directive parser construction executes; directive dispatch, alias policy flags and isConfigured/isConfiguredAsync are uninvoked and excluded.',
      'Original bounded stream reads ordered positive chunks through normal EOF and unlocks its source reader; caller then invokes original release once, running request cleanup once. No cancel, overflow, error, pending-read or race scenario executes.',
      'Original caller builds URL/declared headers/body/timeout. HTTP/status/JSON/buffered binary/content/secret/config boundaries are explicitly synthetic; raw header/policy/cap fields are provenance, not authentication/security/budget qualification.',
      'Fixed fixture keys pass the synthetic secret boundary then original direct-key helper; production secret/environment authority and real provider HTTP are unexecuted.',
      'Original listVoices executes own pagination then public catalog, maps valid metadata, and retains first-seen ids/order. Positive two-page pagination is ordinary, not a maximum-page or limit-threshold test.',
      'Opaque audio fixture bytes do not prove codec encoding/transcoding/playback or actual voice-note/channel delivery.',
      'Manifest and LICENSE are exact data provenance only; plugin discovery, activation and registration are not executed.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real-provider or remote-MCP test executes. Host architecture is not installed by this source-only capture.',
    ],
  };
}

export async function writeFishAudioSpeechCapture(root, output) {
  const capture = await captureFishAudioSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-fish-audio-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeFishAudioSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureFishAudioSpeech(root), null, 2) + '\n');
}
