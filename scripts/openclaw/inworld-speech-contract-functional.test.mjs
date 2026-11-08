// Independent ordinary Inworld oracle authored from pinned original source before capture execution.
// Literal vectors and outcomes are embedded here; no temporary oracle or capture supplies expectations.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import {
  captureInworldSpeechContract, writeInworldSpeechContract,
  INWORLD_SPEECH_CONTRACT_CASES, INWORLD_SPEECH_CONTRACT_PIN, INWORLD_SPEECH_CONTRACT_SOURCE,
} from './capture-inworld-speech-contract.mjs';

const root = process.env.OPENCLAW_SPEECH_SOURCE ?? '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const hash = value => createHash('sha256').update(value).digest('hex');
const fixtureUrl = new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/inworld-speech-contract.json', import.meta.url);
const rawInputs = {
  "config": [
    {
      "id": "empty-defaults",
      "input": {
        "rawConfig": {}
      }
    },
    {
      "id": "root-and-legacy-not-selected",
      "input": {
        "rawConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "voiceId": "RootVoice",
          "modelId": "RootModel",
          "inworld": {
            "voiceId": "LegacyVoice",
            "modelId": "LegacyModel"
          }
        }
      }
    },
    {
      "id": "nested-all-fields",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://speech.example.test/v2/// ",
              "voiceId": " Ashley ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.75
            }
          }
        }
      }
    },
    {
      "id": "empty-nested-masks-legacy",
      "input": {
        "rawConfig": {
          "voiceId": "RootVoice",
          "inworld": {
            "voiceId": "LegacyVoice"
          },
          "providers": {
            "inworld": {}
          }
        }
      }
    },
    {
      "id": "blank-optionals-use-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " \t ",
              "voiceId": " ",
              "modelId": "\n "
            }
          }
        }
      }
    },
    {
      "id": "ecmascript-trim",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": " fixture-inworld-speech-contract ",
              "baseUrl": "﻿ https://trim.example.test/api/// ﻿",
              "voiceId": "﻿  Olivia  ﻿",
              "modelId": "﻿  inworld-tts-1  ﻿",
              "temperature": 1.1
            }
          }
        }
      }
    },
    {
      "id": "custom-values-preserved",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://studio.example.test/prefix/",
              "voiceId": " Studio / Voice ",
              "modelId": " custom-studio-model ",
              "temperature": 1.25
            }
          }
        }
      }
    }
  ],
  "talkConfig": [
    {
      "id": "defaults-from-empty-base",
      "input": {
        "baseTtsConfig": {},
        "talkProviderConfig": {}
      }
    },
    {
      "id": "inherit-normalized-base",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://base.example.test/api/// ",
              "voiceId": " Dennis ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.8
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
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": " fixture-inworld-speech-contract ",
          "baseUrl": " https://talk.example.test/v1/// ",
          "voiceId": "﻿  Wendy  ﻿",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "partial-talk-composition",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley ",
          "temperature": 0.9
        }
      }
    },
    {
      "id": "blank-talk-optionals-inherit",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " \t ",
          "voiceId": "﻿ ",
          "modelId": " "
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
      "id": "canonical-fields",
      "input": {
        "params": {
          "voiceId": "﻿  Olivia  ﻿",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "partial-temperature",
      "input": {
        "params": {
          "temperature": 0.6
        }
      }
    },
    {
      "id": "aliases-not-projected",
      "input": {
        "params": {
          "voice": "AliasVoice",
          "model": "AliasModel",
          "voice_id": "SnakeVoice",
          "model_id": "SnakeModel",
          "outputFormat": "mp3",
          "language": "en-US"
        }
      }
    },
    {
      "id": "blank-canonical-optionals",
      "input": {
        "params": {
          "voiceId": " \t ",
          "modelId": "﻿ ",
          "voice": "AliasVoice",
          "model": "AliasModel"
        }
      }
    }
  ],
  "synthesis": [
    {
      "id": "file-default-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract"
            }
          }
        }
      }
    },
    {
      "id": "file-configured-from-raw",
      "input": {
        "request": {
          "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://speech.example.test/v2/// ",
              "voiceId": " Ashley ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.75
            }
          }
        }
      }
    },
    {
      "id": "file-pre-resolved-config",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://resolved.example.test/api",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1-max",
            "temperature": 0.9
          }
        }
      }
    },
    {
      "id": "file-talk-config-and-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk.example.test/v1/// ",
          "voiceId": "Ashley"
        },
        "talkParams": {
          "voiceId": " Olivia ",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "note-default-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract"
            }
          }
        }
      }
    },
    {
      "id": "note-talk-config-and-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "voiceId": "Dennis",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley ",
          "modelId": " inworld-tts-1-max "
        },
        "talkParams": {
          "temperature": 0.7
        }
      }
    },
    {
      "id": "file-direct-alias-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voice": " Olivia ",
            "model": " inworld-tts-1 ",
            "temperature": 1.2
          }
        }
      }
    },
    {
      "id": "file-primary-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "providerOverrides": {
            "voiceId": " Ashley ",
            "voice": "Olivia",
            "modelId": " inworld-tts-1-max ",
            "model": "inworld-tts-1",
            "temperature": 0.9
          }
        }
      }
    },
    {
      "id": "file-blank-primary-uses-config",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voiceId": " ",
            "voice": "Olivia",
            "modelId": "\t",
            "model": "inworld-tts-1"
          }
        }
      }
    },
    {
      "id": "file-multiple-audio-lines",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "{\"result\":{\"audioContent\":\"UklGRg==\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"
        }
      }
    },
    {
      "id": "file-metadata-and-blank-lines",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "\n \t\n{\"requestId\":\"ordinary-request\"}\n﻿  {\"result\":{\"audioContent\":\"UklGRg==\"}}  ﻿\n{\"result\":{\"requestId\":\"ordinary-progress\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"
        }
      }
    },
    {
      "id": "file-canonical-base64-variants",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "{\"result\":{\"audioContent\":\" UklG Rg==\\t\"}}\n{\"result\":{\"audioContent\":\"AAE\"}}\n{\"result\":{\"audioContent\":\"Av8\"}}\n"
        }
      }
    }
  ],
  "telephony": [
    {
      "id": "phone-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        }
      }
    },
    {
      "id": "phone-pre-resolved-and-aliases",
      "input": {
        "request": {
          "text": "  Phone speech.\n你好 📞\t ",
          "target": "telephony",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": " https://phone.example.test/api/// ",
            "voiceId": "Sarah",
            "modelId": "inworld-tts-1.5-max"
          },
          "providerOverrides": {
            "voice": " Wendy ",
            "model": " inworld-tts-1 ",
            "temperature": 1.1
          }
        }
      }
    },
    {
      "id": "phone-talk-composition",
      "input": {
        "request": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley "
        },
        "talkParams": {
          "modelId": " inworld-tts-1-max ",
          "temperature": 0.7
        }
      }
    }
  ],
  "voices": [
    {
      "id": "explicit-get-projection",
      "input": {
        "request": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": " https://voices.example.test/api/// ",
          "timeoutMs": 12345
        },
        "response": {
          "voices": [
            {
              "voiceId": " Sarah ",
              "displayName": " Sarah Voice ",
              "description": " A calm narrator. ",
              "langCode": " en-US ",
              "tags": [
                "warm",
                "female",
                "male"
              ],
              "source": "curated"
            },
            {
              "voiceId": "Dennis",
              "displayName": " Dennis ",
              "langCode": "en-GB",
              "tags": [
                "male",
                "female"
              ]
            },
            {
              "voiceId": "Sarah",
              "displayName": " Second Sarah ",
              "description": "   ",
              "langCode": "fr-CA",
              "tags": [
                "neutral",
                "female"
              ]
            },
            {
              "voiceId": "Minimal",
              "tags": [
                "Male",
                "FEMALE",
                "character"
              ]
            }
          ]
        }
      }
    },
    {
      "id": "provider-config-default-timeout",
      "input": {
        "request": {
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": " https://catalog.example.test/v2/// "
          }
        },
        "response": {
          "voices": [
            {
              "voiceId": "Locale",
              "displayName": " Locale Voice ",
              "description": " Description ",
              "langCode": "\tpt-BR ",
              "tags": [
                "other",
                "male"
              ]
            },
            {
              "voiceId": "Optional",
              "displayName": "  ",
              "description": "\t",
              "langCode": "",
              "tags": []
            }
          ]
        }
      }
    },
    {
      "id": "raw-config-voice-list",
      "input": {
        "request": {
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://rawvoices.example.test/api/// "
            }
          }
        },
        "response": {
          "voices": [
            {
              "voiceId": " RawVoice "
            }
          ]
        }
      }
    },
    {
      "id": "talk-config-explicit-url",
      "input": {
        "request": {
          "baseUrl": " https://explicit.example.test/list/// ",
          "timeoutMs": 4567
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk.example.test/v1/// ",
          "modelId": " inworld-tts-1 "
        },
        "response": {
          "voices": [
            {
              "voiceId": "TalkVoice",
              "displayName": " Talk Voice ",
              "description": " Talk catalog ",
              "langCode": "ja-JP",
              "tags": [
                "female",
                "male"
              ]
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
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "root-and-legacy-not-selected",
      "expected": {
        "result": {
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "nested-all-fields",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://speech.example.test/v2",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.75
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "empty-nested-masks-legacy",
      "expected": {
        "result": {
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "blank-optionals-use-defaults",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "ecmascript-trim",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://trim.example.test/api",
          "voiceId": "Olivia",
          "modelId": "inworld-tts-1",
          "temperature": 1.1
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "custom-values-preserved",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://studio.example.test/prefix",
          "voiceId": "Studio / Voice",
          "modelId": "custom-studio-model",
          "temperature": 1.25
        },
        "requests": [],
        "releaseCount": 0
      }
    }
  ],
  "talkConfig": [
    {
      "id": "defaults-from-empty-base",
      "expected": {
        "result": {
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "inherit-normalized-base",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://base.example.test/api",
          "voiceId": "Dennis",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.8
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "explicit-talk-fields",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://talk.example.test/v1",
          "voiceId": "Wendy",
          "modelId": "inworld-tts-1",
          "temperature": 1.1
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "partial-talk-composition",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://base.example.test/api",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.9
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "blank-talk-optionals-inherit",
      "expected": {
        "result": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://base.example.test/api",
          "voiceId": "Dennis",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.8
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
      "id": "canonical-fields",
      "expected": {
        "result": {
          "voiceId": "Olivia",
          "modelId": "inworld-tts-1",
          "temperature": 1.1
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "partial-temperature",
      "expected": {
        "result": {
          "temperature": 0.6
        },
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "aliases-not-projected",
      "expected": {
        "result": {},
        "requests": [],
        "releaseCount": 0
      }
    },
    {
      "id": "blank-canonical-optionals",
      "expected": {
        "result": {},
        "requests": [],
        "releaseCount": 0
      }
    }
  ],
  "synthesis": [
    {
      "id": "file-default-from-raw",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://api.inworld.ai",
            "voiceId": "Sarah",
            "modelId": "inworld-tts-1.5-max"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Sarah",
              "modelId": "inworld-tts-1.5-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              }
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-configured-from-raw",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://speech.example.test/v2",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.75
        },
        "synthesisRequest": {
          "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://speech.example.test/v2",
            "voiceId": "Ashley",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.75
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://speech.example.test/v2/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
              "voiceId": "Ashley",
              "modelId": "inworld-tts-1.5-mini",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 0.75
            },
            "bodyText": "{\"text\":\"  Ordinary speech.\\n你好 🌍 — café.\\t \",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.75}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-pre-resolved-config",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://resolved.example.test/api",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1-max",
            "temperature": 0.9
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://resolved.example.test/api/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 0.9
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.9}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-talk-config-and-overrides",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://talk.example.test/v1",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.8
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://talk.example.test/v1",
            "voiceId": "Ashley",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voiceId": "Olivia",
            "modelId": "inworld-tts-1",
            "temperature": 1.1
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://talk.example.test/v1/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Olivia",
              "modelId": "inworld-tts-1",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 1.1
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Olivia\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":1.1}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "note-default-from-raw",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "ogg_opus",
          "fileExtension": ".ogg",
          "voiceCompatible": true
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://api.inworld.ai",
            "voiceId": "Sarah",
            "modelId": "inworld-tts-1.5-max"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Sarah",
              "modelId": "inworld-tts-1.5-max",
              "audioConfig": {
                "audioEncoding": "OGG_OPUS"
              }
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"OGG_OPUS\"}}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "note-talk-config-and-overrides",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "ogg_opus",
          "fileExtension": ".ogg",
          "voiceCompatible": true
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1-max",
          "temperature": 0.8
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://api.inworld.ai",
            "voiceId": "Ashley",
            "modelId": "inworld-tts-1-max",
            "temperature": 0.8
          },
          "providerOverrides": {
            "temperature": 0.7
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Ashley",
              "modelId": "inworld-tts-1-max",
              "audioConfig": {
                "audioEncoding": "OGG_OPUS"
              },
              "temperature": 0.7
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"OGG_OPUS\"},\"temperature\":0.7}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-direct-alias-overrides",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voice": " Olivia ",
            "model": " inworld-tts-1 ",
            "temperature": 1.2
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Olivia",
              "modelId": "inworld-tts-1",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 1.2
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Olivia\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":1.2}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-primary-overrides",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "providerOverrides": {
            "voiceId": " Ashley ",
            "voice": "Olivia",
            "modelId": " inworld-tts-1-max ",
            "model": "inworld-tts-1",
            "temperature": 0.9
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Ashley",
              "modelId": "inworld-tts-1-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 0.9
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.9}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-blank-primary-uses-config",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voiceId": " ",
            "voice": "Olivia",
            "modelId": "\t",
            "model": "inworld-tts-1"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "audioConfig": {
                "audioEncoding": "MP3"
              },
              "temperature": 0.8
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.8}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-multiple-audio-lines",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Sarah",
              "modelId": "inworld-tts-1.5-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              }
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-metadata-and-blank-lines",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Sarah",
              "modelId": "inworld-tts-1.5-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              }
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "file-canonical-base64-variants",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "mp3",
          "fileExtension": ".mp3",
          "voiceCompatible": false
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld speech.",
              "voiceId": "Sarah",
              "modelId": "inworld-tts-1.5-max",
              "audioConfig": {
                "audioEncoding": "MP3"
              }
            },
            "bodyText": "{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    }
  ],
  "telephony": [
    {
      "id": "phone-from-raw",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "pcm",
          "sampleRate": 22050
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://api.inworld.ai",
          "voiceId": "Dennis",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.8
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://api.inworld.ai",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://api.inworld.ai/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld phone speech.",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "audioConfig": {
                "audioEncoding": "PCM",
                "sampleRateHertz": 22050
              },
              "temperature": 0.8
            },
            "bodyText": "{\"text\":\"Ordinary Inworld phone speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":0.8}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "phone-pre-resolved-and-aliases",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "pcm",
          "sampleRate": 22050
        },
        "synthesisRequest": {
          "text": "  Phone speech.\n你好 📞\t ",
          "target": "telephony",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": " https://phone.example.test/api/// ",
            "voiceId": "Sarah",
            "modelId": "inworld-tts-1.5-max"
          },
          "providerOverrides": {
            "voice": " Wendy ",
            "model": " inworld-tts-1 ",
            "temperature": 1.1
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://phone.example.test/api/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "  Phone speech.\n你好 📞\t ",
              "voiceId": "Wendy",
              "modelId": "inworld-tts-1",
              "audioConfig": {
                "audioEncoding": "PCM",
                "sampleRateHertz": 22050
              },
              "temperature": 1.1
            },
            "bodyText": "{\"text\":\"  Phone speech.\\n你好 📞\\t \",\"voiceId\":\"Wendy\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":1.1}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "phone-talk-composition",
      "expected": {
        "result": {
          "audioBase64": "UklGRgABAv8=",
          "outputFormat": "pcm",
          "sampleRate": 22050
        },
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://base.example.test/api",
          "voiceId": "Ashley",
          "modelId": "inworld-tts-1.5-mini",
          "temperature": 0.8
        },
        "synthesisRequest": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://base.example.test/api",
            "voiceId": "Ashley",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "modelId": "inworld-tts-1-max",
            "temperature": 0.7
          },
          "cfg": {}
        },
        "requests": [
          {
            "url": "https://base.example.test/api/tts/v1/voice:stream",
            "method": "POST",
            "body": {
              "text": "Ordinary Inworld phone speech.",
              "voiceId": "Ashley",
              "modelId": "inworld-tts-1-max",
              "audioConfig": {
                "audioEncoding": "PCM",
                "sampleRateHertz": 22050
              },
              "temperature": 0.7
            },
            "bodyText": "{\"text\":\"Ordinary Inworld phone speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":0.7}",
            "timeoutMs": 12345,
            "auditContext": "inworld-tts"
          }
        ],
        "releaseCount": 1
      }
    }
  ],
  "voices": [
    {
      "id": "explicit-get-projection",
      "expected": {
        "result": [
          {
            "id": "Sarah",
            "name": "Sarah Voice",
            "description": "A calm narrator.",
            "locale": " en-US ",
            "gender": "female"
          },
          {
            "id": "Dennis",
            "name": "Dennis",
            "locale": "en-GB",
            "gender": "male"
          },
          {
            "id": "Sarah",
            "name": "Second Sarah",
            "locale": "fr-CA",
            "gender": "female"
          },
          {
            "id": "Minimal"
          }
        ],
        "requests": [
          {
            "url": "https://voices.example.test/api/voices/v1/voices",
            "method": "GET",
            "timeoutMs": 12345,
            "auditContext": "inworld-voices"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "provider-config-default-timeout",
      "expected": {
        "result": [
          {
            "id": "Locale",
            "name": "Locale Voice",
            "description": "Description",
            "locale": "\tpt-BR ",
            "gender": "male"
          },
          {
            "id": "Optional"
          }
        ],
        "requests": [
          {
            "url": "https://catalog.example.test/v2/voices/v1/voices",
            "method": "GET",
            "timeoutMs": 30000,
            "auditContext": "inworld-voices"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "raw-config-voice-list",
      "expected": {
        "result": [
          {
            "id": "RawVoice"
          }
        ],
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://rawvoices.example.test/api",
          "voiceId": "Sarah",
          "modelId": "inworld-tts-1.5-max"
        },
        "requests": [
          {
            "url": "https://rawvoices.example.test/api/voices/v1/voices",
            "method": "GET",
            "timeoutMs": 12345,
            "auditContext": "inworld-voices"
          }
        ],
        "releaseCount": 1
      }
    },
    {
      "id": "talk-config-explicit-url",
      "expected": {
        "result": [
          {
            "id": "TalkVoice",
            "name": "Talk Voice",
            "description": "Talk catalog",
            "locale": "ja-JP",
            "gender": "female"
          }
        ],
        "resolvedConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": "https://talk.example.test/v1",
          "voiceId": "Dennis",
          "modelId": "inworld-tts-1",
          "temperature": 0.8
        },
        "requests": [
          {
            "url": "https://explicit.example.test/list/voices/v1/voices",
            "method": "GET",
            "timeoutMs": 4567,
            "auditContext": "inworld-voices"
          }
        ],
        "releaseCount": 1
      }
    }
  ]
};

const metadataExpected = {
  id:'inworld', label:'Inworld', autoSelectOrder:30, defaultModel:'inworld-tts-1.5-max',
  models:['inworld-tts-1.5-max','inworld-tts-1.5-mini','inworld-tts-1-max','inworld-tts-1'],
  callbacks:['resolveConfig','parseDirectiveToken','resolveTalkConfig','resolveTalkOverrides',
    'listVoices','isConfigured','isConfiguredAsync','synthesize','synthesizeTelephony'],
};
const sourcePaths = [
  'extensions/inworld/speech-provider.ts',
  'extensions/inworld/tts.ts',
  'src/tts/tts-provider-helpers.ts',
  'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts',
  'packages/normalization-core/src/utf16-slice.ts',
  'packages/media-core/src/base64.ts',
  'packages/media-core/src/constants.ts',
];
const old14 = [
  {path:'scripts/openclaw/capture-inworld-speech.mjs',sha256:'45485f31d96c2600295e5838fc41465ecb3b5e9ea87e60939674cd4183da909a'},
  {path:'scripts/openclaw/inworld-speech-functional.test.mjs',sha256:'0134e7f91c7535d7646c8d3d1f2507e2803708d4cac091447cfffeb8c79f6d96'},
  {path:'apps/synapsis_agent/test/fixtures/openclaw/488631c/inworld-speech.json',sha256:'6dd6fca71a2ccd5a723bbf3f6d83b0b9d94a072e248592f7ac0b04301bb71d6e'},
];

// This independent read-only snapshot checks every tracked blob and executable/symlink mode.
function trackedSourceSnapshot() {
  const entries = execFileSync('git', ['ls-tree','-rz','--full-tree',pin], {
    cwd:root, maxBuffer:64 * 1024 * 1024, timeout:30000,
    env:{...process.env,GIT_OPTIONAL_LOCKS:'0',GIT_NO_REPLACE_OBJECTS:'1'},
  }).toString().split('\0').filter(Boolean);
  return entries.map(entry => {
    const [header,path] = entry.split('\t');
    const [mode,type,gitBlob] = header.split(' ');
    assert.equal(type,'blob',path);
    const file = join(root,path), stat = lstatSync(file);
    assert.equal(stat.isSymbolicLink(),mode === '120000',path);
    if (!stat.isSymbolicLink()) assert.equal(Boolean(stat.mode & 0o111),mode === '100755',path);
    const bytes = stat.isSymbolicLink() ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update('blob ' + bytes.length + '\0').update(bytes).digest('hex'),gitBlob,path);
    return {path,mode,gitBlob,sha256:hash(bytes)};
  });
}
function requestSemantics(request) {
  const {headers,...semantics} = request;
  assert.equal(typeof headers,'object','original supplied headers retained as provenance');
  return semantics;
}
const sourceBefore = trackedSourceSnapshot();
const capture = await captureInworldSpeechContract(root);
const sourceAfter = trackedSourceSnapshot();

test('complete Inworld factory metadata and exact ordinary callback inventory', () => {
  assert.equal(INWORLD_SPEECH_CONTRACT_PIN,pin);
  assert.equal(INWORLD_SPEECH_CONTRACT_SOURCE,sourcePaths[0]);
  assert.equal(typeof writeInworldSpeechContract,'function');
  assert.equal(capture.schemaVersion,1);
  assert.equal(capture.sourcePin,pin);
  assert.deepEqual(capture.metadata,metadataExpected);
  assert.deepEqual(capture.counts,{
    config:7,talkConfig:5,talkOverrides:5,synthesis:12,telephony:3,voices:4,
    totalObservations:36,observations:36,httpRequests:19,releases:19,
    wholeModules:11,trackedFilesBefore:58558,trackedFilesAfter:58558,
  });
});

test('36 independently authored raw inputs and literal successful outcomes', () => {
  assert.deepEqual(INWORLD_SPEECH_CONTRACT_CASES,rawInputs);
  assert.deepEqual(Object.keys(capture.observations),Object.keys(rawInputs));
  assert.deepEqual(Object.fromEntries(Object.entries(rawInputs).map(([group,rows]) => [group,rows.length])),
    {config:7,talkConfig:5,talkOverrides:5,synthesis:12,telephony:3,voices:4});
  for (const [group,inputs] of Object.entries(rawInputs)) {
    const actual = capture.observations[group], expected = literalExpected[group];
    assert.deepEqual(actual.map(row => row.id),inputs.map(row => row.id),group);
    assert.deepEqual(expected.map(row => row.id),inputs.map(row => row.id),group);
    for (let index = 0; index < inputs.length; index += 1) {
      const row = actual[index], input = inputs[index].input, want = expected[index].expected;
      assert.deepEqual(row.input,input,row.id + ': full raw input');
      assert.deepEqual(row.inputAfter,input,row.id + ': unchanged raw input');
      assert.deepEqual(row.result,want.result,row.id + ': exact source result');
      assert.equal(Object.hasOwn(row,'resolvedConfig'),Object.hasOwn(want,'resolvedConfig'),row.id);
      if (Object.hasOwn(want,'resolvedConfig')) assert.deepEqual(row.resolvedConfig,want.resolvedConfig,row.id);
      assert.equal(Object.hasOwn(row,'synthesisRequest'),Object.hasOwn(want,'synthesisRequest'),row.id);
      assert.equal(Object.hasOwn(row,'synthesisRequestAfter'),Object.hasOwn(want,'synthesisRequest'),row.id);
      if (Object.hasOwn(want,'synthesisRequest')) {
        assert.deepEqual(row.synthesisRequest,want.synthesisRequest,row.id + ': composed request');
        assert.deepEqual(row.synthesisRequestAfter,want.synthesisRequest,row.id + ': unchanged composed request');
      }
      assert.deepEqual(row.requests.map(requestSemantics),want.requests,row.id + ': ordinary HTTP semantics');
      assert.equal(row.releaseCount,want.releaseCount,row.id);
      const http = ['synthesis','telephony','voices'].includes(group);
      for (const name of ['fetchWithSsrFGuard','readResponseWithLimit','release']) {
        assert.equal(row.platformCalls.filter(call => call.export === name).length,http ? 1 : 0,row.id + ': ' + name);
      }
      if (http) {
        assert.equal(row.requests.length,1,row.id);
        const supplied = row.platformCalls.find(call => call.export === 'fetchWithSsrFGuard');
        assert.equal(supplied.provenanceOnly,true,row.id);
        const args = supplied.args, request = row.requests[0];
        assert.equal(request.url,args.url,row.id);
        assert.equal(request.method,args.init.method,row.id);
        assert.deepEqual(request.headers,args.init.headers,row.id + ': supplied header provenance only');
        assert.equal(request.timeoutMs,args.timeoutMs,row.id);
        assert.equal(request.auditContext,args.auditContext,row.id);
        assert.equal(Object.hasOwn(request,'bodyText'),Object.hasOwn(args.init,'body'),row.id);
        if (Object.hasOwn(request,'bodyText')) {
          assert.equal(request.bodyText,args.init.body,row.id);
          assert.deepEqual(request.body,JSON.parse(args.init.body),row.id);
          assert.equal(request.headers['Content-Type'],'application/json',row.id);
        }
      } else assert.deepEqual(row.requests,[],row.id);
    }
  }
});

test('eleven original modules, exact source hashes and wiring-only SDK facades', () => {
  assert.deepEqual(sourceAfter,sourceBefore);
  assert.equal(sourceBefore.length,58558);
  assert.deepEqual(capture.sourceIntegrity.after,capture.sourceIntegrity.before);
  for (const side of ['before','after']) {
    const integrity = capture.sourceIntegrity[side];
    assert.equal(integrity.verified,true);
    assert.equal(integrity.commit,pin);
    assert.equal(integrity.verifiedTrackedFiles,58558);
    assert.equal(integrity.filesSha256,hash(JSON.stringify(sourceBefore)));
    assert.equal(integrity.tree,execFileSync('git',['rev-parse',pin + '^{tree}'],{
      cwd:root,encoding:'utf8',timeout:30000,
      env:{...process.env,GIT_OPTIONAL_LOCKS:'0',GIT_NO_REPLACE_OBJECTS:'1'},
    }).trim());
  }
  assert.equal(capture.harness.path,'scripts/openclaw/capture-inworld-speech-contract.mjs');
  assert.equal(capture.harness.sha256,hash(readFileSync(new URL('./capture-inworld-speech-contract.mjs',import.meta.url))));
  assert.equal(capture.transformation.api,'node:module.stripTypeScriptTypes');
  assert.deepEqual(capture.transformation.options,{mode:'transform',sourceMap:false});
  assert.deepEqual(capture.transformation.sdkFacades.map(item => item.module),[
    'openclaw/plugin-sdk/string-coerce-runtime',
    'openclaw/plugin-sdk/speech-provider',
    '@openclaw/normalization-core/string-coerce',
    '@openclaw/normalization-core/number-coercion',
    'openclaw/plugin-sdk/media-runtime',
  ]);
  for (const facade of capture.transformation.sdkFacades) {
    assert.equal(facade.sha256,hash(facade.source),facade.module);
    assert.ok(facade.source.split('\n').filter(Boolean).every(line =>
      /^export (?:\*|\{[^}]+\}) from (['"])[^'"]+\1;$/.test(line)),facade.module);
  }
  const expectedStaticEdges = [
    ['extensions/inworld/speech-provider.ts','openclaw/plugin-sdk/secret-input'],
    ['extensions/inworld/speech-provider.ts','openclaw/plugin-sdk/speech-provider'],
    ['extensions/inworld/speech-provider.ts','openclaw/plugin-sdk/string-coerce-runtime'],
    ['extensions/inworld/speech-provider.ts','extensions/inworld/tts.ts'],
    ['extensions/inworld/tts.ts','openclaw/plugin-sdk/response-limit-runtime'],
    ['extensions/inworld/tts.ts','openclaw/plugin-sdk/speech-provider'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/number-coercion.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/record-coerce.ts'],
    ['openclaw/plugin-sdk/string-coerce-runtime','packages/normalization-core/src/string-coerce.ts'],
    ['openclaw/plugin-sdk/speech-provider','src/tts/directive-parser.ts'],
    ['openclaw/plugin-sdk/speech-provider','src/tts/tts-provider-helpers.ts'],
    ['openclaw/plugin-sdk/speech-provider','packages/normalization-core/src/utf16-slice.ts'],
    ['@openclaw/normalization-core/string-coerce','packages/normalization-core/src/string-coerce.ts'],
    ['@openclaw/normalization-core/number-coercion','packages/normalization-core/src/number-coercion.ts'],
    ['src/tts/tts-provider-helpers.ts','node:fs'],
    ['src/tts/tts-provider-helpers.ts','@openclaw/normalization-core/string-coerce'],
    ['src/tts/directive-parser.ts','src/tts/directive-number.ts'],
    ['src/tts/directive-number.ts','@openclaw/normalization-core/number-coercion'],
    ['packages/normalization-core/src/number-coercion.ts','packages/normalization-core/src/string-coerce.ts'],
    ['openclaw/plugin-sdk/media-runtime','packages/media-core/src/base64.ts'],
    ['openclaw/plugin-sdk/media-runtime','packages/media-core/src/constants.ts'],
  ];
  const edges = rows => [...new Set(rows.map(row => JSON.stringify(row)))].sort();
  assert.deepEqual(edges(capture.transformation.staticImports.map(item => [item.importer,item.resolved])),edges(expectedStaticEdges));
  assert.deepEqual(edges(capture.transformation.dynamicImports.map(item => [item.importer,item.resolved])),edges([
    ['extensions/inworld/tts.ts','openclaw/plugin-sdk/media-runtime'],
    ['extensions/inworld/tts.ts','openclaw/plugin-sdk/ssrf-runtime'],
  ]));
  assert.deepEqual(capture.sourceAudit.map(item => item.path),sourcePaths);
  for (const audit of capture.sourceAudit) {
    const bytes = readFileSync(join(root,audit.path));
    const tracked = sourceBefore.find(file => file.path === audit.path);
    assert.equal(audit.gitBlob,tracked.gitBlob,audit.path);
    assert.equal(audit.sourceSha256,hash(bytes),audit.path);
    assert.equal(audit.sourceBytes,bytes.length,audit.path);
    assert.deepEqual(audit.readRange,{start:1,end:bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0)},audit.path);
    assert.equal(audit.executableSha256,hash(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})),audit.path);
    assert.equal(audit.wholeModule,true,audit.path);
    assert.equal(audit.evaluated,true,audit.path);
  }
  const manifestPath = 'extensions/inworld/openclaw.plugin.json';
  const manifestBytes = readFileSync(join(root,manifestPath));
  assert.deepEqual(capture.pluginManifest,JSON.parse(manifestBytes));
  assert.equal(capture.dataAudit.length,1);
  assert.equal(capture.dataAudit[0].path,manifestPath);
  assert.equal(capture.dataAudit[0].gitBlob,sourceBefore.find(file => file.path === manifestPath).gitBlob);
  assert.equal(capture.dataAudit[0].sourceSha256,hash(manifestBytes));
  for (const boundary of capture.platformBoundaries) assert.equal(boundary.originalSourceExecuted,false,boundary.module);
});

test('fresh API and CLI captures exactly equal frozen fixture and preserve old14', async () => {
  const frozenBytes = readFileSync(fixtureUrl), frozen = JSON.parse(frozenBytes);
  assert.deepEqual(capture,frozen);
  assert.deepEqual(await captureInworldSpeechContract(root),frozen);
  const cli = execFileSync(process.execPath,[
    '--experimental-vm-modules',
    fileURLToPath(new URL('./capture-inworld-speech-contract.mjs',import.meta.url)),
    '--source',root,
  ],{encoding:'utf8',maxBuffer:32 * 1024 * 1024,timeout:300000,
    env:{...process.env,NODE_NO_WARNINGS:'1'}});
  assert.deepEqual(JSON.parse(cli),frozen);
  assert.equal(cli,frozenBytes.toString(),'exact serialized CLI/frozen fixture equality');
  assert.deepEqual(trackedSourceSnapshot(),sourceBefore);
  for (const prior of old14) {
    assert.equal(hash(readFileSync(new URL('../../' + prior.path,import.meta.url))),prior.sha256,prior.path);
  }
});

