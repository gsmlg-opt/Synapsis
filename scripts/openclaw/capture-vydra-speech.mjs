// Pinned complete Vydra speech/default/shared callbacks; ordinary successful fixtures only.
// Run with Node 24.21.0 and --experimental-vm-modules; original algorithms receive TS erasure only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import nodePath, { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const VYDRA_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const VYDRA_SPEECH_SOURCE = 'extensions/vydra/speech-provider.ts';
const defaults = 'extensions/vydra/defaults.ts';
const vydraShared = 'extensions/vydra/shared.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const ttsHelpers = 'src/tts/tts-provider-helpers.ts';
const mime = 'packages/media-core/src/mime.ts';
const fileName = 'packages/media-core/src/file-name.ts';
const constants = 'packages/media-core/src/constants.ts';
const jsonPost = 'src/media-understanding/provider-json-post.ts';
const operations = 'src/media-understanding/shared.ts';
const manifestPath = 'extensions/vydra/openclaw.plugin.json';
const licensePath = 'LICENSE';
const wholeSources = [VYDRA_SPEECH_SOURCE, defaults, vydraShared, strings, records, numbers,
  ttsHelpers, mime, fileName, constants, jsonPost];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2_000;
const operationModule = 'capture:vydra-speech:operations';
const platformModule = 'capture:vydra-speech:platform';

// Raw ordinary recipes supplied independently of this capture implementation.
export const VYDRA_SPEECH_CASES = {
  "config": [
    {
      "id": "config-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        }
      },
      "environment": {}
    },
    {
      "id": "config-explicit",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " https://speech.example.test/custom/v7/// ",
              "model": " custom/model ",
              "voiceId": " custom-voice "
            }
          }
        }
      },
      "environment": {}
    },
    {
      "id": "config-source-env",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        }
      },
      "environment": {
        "VYDRA_BASE_URL": " https://env.example.test/voice/// ",
        "VYDRA_TTS_MODEL": " env/model ",
        "VYDRA_TTS_VOICE_ID": " env-voice "
      }
    },
    {
      "id": "config-before-env",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " https://speech.example.test/custom/v7/// ",
              "model": " custom/model ",
              "voiceId": " custom-voice "
            }
          }
        }
      },
      "environment": {
        "VYDRA_BASE_URL": " https://env.example.test/voice/// ",
        "VYDRA_TTS_MODEL": " env/model ",
        "VYDRA_TTS_VOICE_ID": " env-voice "
      }
    },
    {
      "id": "config-empty-strings-source-env",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " ",
              "model": " ",
              "voiceId": " "
            }
          }
        }
      },
      "environment": {
        "VYDRA_BASE_URL": " https://env.example.test/voice/// ",
        "VYDRA_TTS_MODEL": " env/model ",
        "VYDRA_TTS_VOICE_ID": " env-voice "
      }
    },
    {
      "id": "config-unicode",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " ﻿https://vydra.ai/﻿ ",
              "model": " ﻿ elevenlabs/tts ﻿ ",
              "voiceId": " ﻿ Rachel-custom ﻿ "
            }
          }
        }
      },
      "environment": {}
    },
    {
      "id": "config-root-canonical",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": "https://vydra.ai///"
            }
          }
        }
      },
      "environment": {}
    }
  ],
  "base": [
    {
      "id": "base-canonical-root",
      "input": {
        "value": "https://vydra.ai/"
      }
    },
    {
      "id": "base-custom-prefix",
      "input": {
        "value": " https://voice.example.test/custom/v7/// "
      }
    },
    {
      "id": "base-custom-root",
      "input": {
        "value": "https://voice.example.test"
      }
    },
    {
      "id": "base-port",
      "input": {
        "value": "https://vydra.ai:8443/voice///"
      }
    },
    {
      "id": "base-query-fragment",
      "input": {
        "value": "https://vydra.ai/?mode=voice#section"
      }
    }
  ],
  "extraction": [
    {
      "id": "extract-root-priority",
      "input": {
        "payload": {
          "url": "https://www.vydra.ai/assets/third",
          "resultUrl": "https://www.vydra.ai/assets/second",
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "kind": "audio"
      }
    },
    {
      "id": "extract-arrays",
      "input": {
        "payload": {
          "audioUrls": [
            [
              "https://www.vydra.ai/assets/first",
              "https://www.vydra.ai/assets/second"
            ],
            "https://www.vydra.ai/assets/third"
          ]
        },
        "kind": "audio"
      }
    },
    {
      "id": "extract-nested-order",
      "input": {
        "payload": {
          "outputs": [
            {
              "url": "https://www.vydra.ai/assets/second"
            },
            {
              "audioUrl": "https://www.vydra.ai/assets/third"
            }
          ],
          "output": {
            "resultUrl": "https://www.vydra.ai/assets/first"
          }
        },
        "kind": "audio"
      }
    },
    {
      "id": "extract-ordered-dedup",
      "input": {
        "payload": {
          "audioUrls": [
            "https://www.vydra.ai/assets/first",
            "https://www.vydra.ai/assets/second",
            "https://www.vydra.ai/assets/first"
          ],
          "data": {
            "audioUrl": "https://www.vydra.ai/assets/second",
            "url": "https://www.vydra.ai/assets/third"
          }
        },
        "kind": "audio"
      }
    },
    {
      "id": "extract-all-keys-and-recursion",
      "input": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/key-1",
          "audioUrls": [
            "https://www.vydra.ai/assets/key-2"
          ],
          "resultUrl": "https://www.vydra.ai/assets/key-3",
          "resultUrls": [
            "https://www.vydra.ai/assets/key-4"
          ],
          "outputUrl": "https://www.vydra.ai/assets/key-5",
          "outputUrls": [
            "https://www.vydra.ai/assets/key-6"
          ],
          "url": "https://www.vydra.ai/assets/key-7",
          "urls": [
            "https://www.vydra.ai/assets/key-8"
          ],
          "output": {
            "url": "https://www.vydra.ai/assets/key-9"
          },
          "outputs": [
            {
              "url": "https://www.vydra.ai/assets/key-10"
            }
          ],
          "result": {
            "url": "https://www.vydra.ai/assets/key-11"
          },
          "results": [
            {
              "url": "https://www.vydra.ai/assets/key-12"
            }
          ],
          "data": {
            "url": "https://www.vydra.ai/assets/key-13"
          },
          "asset": {
            "url": "https://www.vydra.ai/assets/key-14"
          },
          "assets": [
            {
              "url": "https://www.vydra.ai/assets/key-15"
            }
          ]
        },
        "kind": "audio"
      }
    }
  ],
  "synthesis": [
    {
      "id": "default-file",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "default-note",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "wav-file",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/wav"
      }
    },
    {
      "id": "wav-note",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/wav"
      }
    },
    {
      "id": "default-mime",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": null
      }
    },
    {
      "id": "configured-model-voice",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " https://speech.example.test/custom/v7/// ",
              "model": " custom/model ",
              "voiceId": " custom-voice "
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://speech.example.test/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "override-model-voice",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {
          "model": " custom/override ",
          "voiceId": " override-voice "
        }
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "blank-override-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {
          "model": " ",
          "voiceId": " "
        }
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "configured-namespace-retained",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "model": " vydra/elevenlabs/custom "
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "source-env-all",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {
        "VYDRA_BASE_URL": " https://env.example.test/voice/// ",
        "VYDRA_TTS_MODEL": " env/model ",
        "VYDRA_TTS_VOICE_ID": " env-voice "
      },
      "response": {
        "payload": {
          "audioUrl": "https://env.example.test/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "source-env-model",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {
        "VYDRA_TTS_MODEL": " env/model "
      },
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "source-env-voice",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {
        "VYDRA_TTS_VOICE_ID": " env-voice "
      },
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "configured-before-source-env",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " https://speech.example.test/custom/v7/// ",
              "model": " custom/model ",
              "voiceId": " custom-voice "
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {
        "VYDRA_BASE_URL": " https://env.example.test/voice/// ",
        "VYDRA_TTS_MODEL": " env/model ",
        "VYDRA_TTS_VOICE_ID": " env-voice "
      },
      "response": {
        "payload": {
          "audioUrl": "https://speech.example.test/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "canonical-root",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": "https://vydra.ai///"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "custom-root",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": "https://voice.example.test"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://voice.example.test/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "port-literal-url",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": "https://vydra.ai:8443/voice///"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai:8443/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "query-fragment-literal-url",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": "https://vydra.ai/?mode=voice#section"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "unicode-config",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech",
              "baseUrl": " ﻿https://vydra.ai/﻿ ",
              "model": " ﻿ elevenlabs/tts ﻿ ",
              "voiceId": " ﻿ Rachel-custom ﻿ "
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "exact-authored-text",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "synthesis-extract-root-priority",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "url": "https://www.vydra.ai/assets/third",
          "resultUrl": "https://www.vydra.ai/assets/second",
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "synthesis-extract-arrays",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrls": [
            [
              "https://www.vydra.ai/assets/first",
              "https://www.vydra.ai/assets/second"
            ],
            "https://www.vydra.ai/assets/third"
          ]
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "synthesis-extract-nested-order",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "outputs": [
            {
              "url": "https://www.vydra.ai/assets/second"
            },
            {
              "audioUrl": "https://www.vydra.ai/assets/third"
            }
          ],
          "output": {
            "resultUrl": "https://www.vydra.ai/assets/first"
          }
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "synthesis-extract-ordered-dedup",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrls": [
            "https://www.vydra.ai/assets/first",
            "https://www.vydra.ai/assets/second",
            "https://www.vydra.ai/assets/first"
          ],
          "data": {
            "audioUrl": "https://www.vydra.ai/assets/second",
            "url": "https://www.vydra.ai/assets/third"
          }
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "synthesis-extract-all-keys-and-recursion",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/key-1",
          "audioUrls": [
            "https://www.vydra.ai/assets/key-2"
          ],
          "resultUrl": "https://www.vydra.ai/assets/key-3",
          "resultUrls": [
            "https://www.vydra.ai/assets/key-4"
          ],
          "outputUrl": "https://www.vydra.ai/assets/key-5",
          "outputUrls": [
            "https://www.vydra.ai/assets/key-6"
          ],
          "url": "https://www.vydra.ai/assets/key-7",
          "urls": [
            "https://www.vydra.ai/assets/key-8"
          ],
          "output": {
            "url": "https://www.vydra.ai/assets/key-9"
          },
          "outputs": [
            {
              "url": "https://www.vydra.ai/assets/key-10"
            }
          ],
          "result": {
            "url": "https://www.vydra.ai/assets/key-11"
          },
          "results": [
            {
              "url": "https://www.vydra.ai/assets/key-12"
            }
          ],
          "data": {
            "url": "https://www.vydra.ai/assets/key-13"
          },
          "asset": {
            "url": "https://www.vydra.ai/assets/key-14"
          },
          "assets": [
            {
              "url": "https://www.vydra.ai/assets/key-15"
            }
          ]
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "mpeg-parameters",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": " audio/mpeg; codecs=mp3 "
      }
    },
    {
      "id": "wav-parameters",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": " audio/wav; codecs=pcm "
      }
    },
    {
      "id": "wav-case-divergence",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "Audio/WAV"
      }
    },
    {
      "id": "mpeg-parameter-divergence",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg; name=wave"
      }
    },
    {
      "id": "x-wav",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/x-wav"
      }
    },
    {
      "id": "flac-source-labels",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/flac"
      }
    },
    {
      "id": "octet-stream-source-labels",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 12345,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "application/octet-stream"
      }
    },
    {
      "id": "explicit-timeout-45000",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "audio-file",
        "timeoutMs": 45000,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    },
    {
      "id": "explicit-timeout-75000-note",
      "input": {
        "rawConfig": {
          "providers": {
            "vydra": {
              "apiKey": "fixture-vydra-speech"
            }
          }
        },
        "text": "Ordinary Vydra speech.",
        "target": "voice-note",
        "timeoutMs": 75000,
        "cfg": {},
        "providerOverrides": {}
      },
      "environment": {},
      "response": {
        "payload": {
          "audioUrl": "https://www.vydra.ai/assets/first"
        },
        "audioBase64": "UklGRgABAv8=",
        "contentType": "audio/mpeg"
      }
    }
  ]
};

// These facades wire exact original exports or explicitly named platform boundaries.
const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export {asOptionalRecord} from '${records}'; export {normalizeOptionalString,normalizeOptionalLowercaseString} from '${strings}';`,
  '@openclaw/normalization-core/string-coerce':
    `export {normalizeOptionalString,normalizeOptionalLowercaseString} from '${strings}';`,
  'openclaw/plugin-sdk/speech-provider': `export {resolveSpeechProviderApiKey} from '${ttsHelpers}';`,
  'openclaw/plugin-sdk/secret-input': `export {secret as normalizeResolvedSecretInputString} from '${platformModule}';`,
  'openclaw/plugin-sdk/media-mime': `export {extensionForMime} from '${mime}';`,
  'openclaw/plugin-sdk/number-runtime': `export {resolvePositiveTimerTimeoutMs} from '${numbers}';`,
  'openclaw/plugin-sdk/media-generation-runtime':
    `export {mediaCap as resolveGeneratedMediaMaxBytes,unused as resolveGeneratedImageDownloadMaxBytes} from '${platformModule}';`,
  'openclaw/plugin-sdk/provider-http':
    `export {createProviderOperationDeadline,createProviderOperationTimeoutError,createProviderOperationTimeoutResolver,resolveProviderOperationTimeoutMs} from '${operationModule}';
export {postJsonResponse} from '${jsonPost}';
export {guarded as fetchWithTimeoutGuarded,status as assertOkOrThrowHttpError,readBinary as readProviderBinaryResponse,requestConfig as resolveProviderHttpRequestConfig,
  unused as pollProviderOperationJson,unused as resolveProviderApiKeyHttpRequestConfig,unused as sanitizeConfiguredModelProviderRequest} from '${platformModule}';`,
  'src/agents/provider-http-errors.ts':
    `export {status as assertOkOrThrowHttpError,readJson as readProviderJsonResponse,readObject as readProviderJsonObjectResponse} from '${platformModule}';`,
};

const platformBoundaries = [
  { module: 'openclaw/plugin-sdk/secret-input', originalSourceExecuted: false,
    exports: { normalizeResolvedSecretInputString: 'Returns the explicit fixture string; records source path. Secret resolution, configured predicates and ambient credentials are unexecuted.' } },
  { module: 'src/plugin-sdk/provider-http.ts', originalSourceExecuted: false, exports: {
    resolveProviderHttpRequestConfig: 'Records full source arguments; returns explicit normalized base and Headers(defaultHeaders), without applying transport policy.',
    fetchWithTimeoutGuarded: 'Records original POST/GET URL, body, timeout and raw policy provenance; returns a synthetic successful response and counted release. No network or original guarded transport executes.',
    assertOkOrThrowHttpError: 'Records successful status/label only; original error handling unexecuted.',
    readProviderJsonResponse: 'Returns complete explicit successful JSON payload; original JSON reader unexecuted.',
    readProviderJsonObjectResponse: 'Uninvoked throwing binding; source speech uses generic JSON wrapper.',
    readProviderBinaryResponse: 'Returns exact opaque fixture bytes; records original deadline callback value and raw cap/callback presence only; original body reader unexecuted.',
    pollProviderOperationJson: 'Uninvoked throwing binding; Vydra speech has no polling step.',
    resolveProviderApiKeyHttpRequestConfig: 'Uninvoked throwing binding for unrelated shared generation export.',
    sanitizeConfiguredModelProviderRequest: 'Uninvoked throwing binding for unrelated shared generation export.',
  } },
  { module: 'openclaw/plugin-sdk/media-generation-runtime', originalSourceExecuted: false, exports: {
    resolveGeneratedMediaMaxBytes: 'Returns fixed 16777216 audio fixture cap for ordinary cfg={}; cap selection/budget behavior unqualified.',
    resolveGeneratedImageDownloadMaxBytes: 'Uninvoked throwing binding for unrelated shared generation export.',
  } },
  { module: 'node:fs', originalSourceExecuted: false, exports: { rmSync: 'Uninvoked throwing binding; the complete original speech helper cleanup export is never called.' } },
  { module: 'node:path', originalSourceExecuted: true, exports: { default: 'Node platform path module exported unchanged; MIME file-path/sniff functions remain uncalled.' } },
  { module: 'globalThis', originalSourceExecuted: false, exports: {
    fetch: 'Uninvoked throwing binding passed to the synthetic guarded transport; no real network executes.',
    'process.env': 'Fresh plain object containing only the recorded recipe environment; real process environment is not exposed.',
    'Date.now': 'Constant 1700000000000 per fresh VM, used by original positive operation/deadline helpers. No elapsed-time or timer qualification.',
    sleepWithAbort: 'Uninvoked throwing binding; no source speech polling.',
    executeProviderOperationWithRetry: 'Uninvoked throwing binding; ordinary POST has no retryStage.',
    fetchWithTimeout: 'Uninvoked throwing binding; original postGuardedRequest uses the declared guarded boundary.',
    createProviderHttpError: 'Uninvoked throwing binding for unrelated error branches.',
    isTransientProviderHttpStatus: 'Uninvoked throwing binding; ordinary source POST has no retryStage.',
  } },
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), VYDRA_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', VYDRA_SPEECH_PIN])
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
  return { verified: true, commit: VYDRA_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${VYDRA_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}

async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Vydra speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

function originalOperationRegions(readOriginal) {
  const bytes = readOriginal(operations);
  const selections = [
    ['export function createProviderOperationDeadline(', '/** Waits for the next poll interval'],
    ['function resolveGuardedRequestOptions(', '// Keep the shipped transcription name'],
  ];
  const regions = selections.map(([startMarker, endMarker]) => {
    const startByte = bytes.indexOf(startMarker), endByte = bytes.indexOf(endMarker, startByte);
    assert.ok(startByte >= 0 && endByte > startByte, operations + ' exact region');
    assert.equal(bytes.indexOf(startMarker, startByte + 1), -1, operations + ' unique marker');
    return { startByte, endByte, sourceRegionSha256: hash(bytes.subarray(startByte, endByte)) };
  });
  const prelude = `import {resolveDateTimestampMs,resolveExpiresAtMsFromDurationMs,resolveTimerTimeoutMs} from '${numbers}';
import {guarded as fetchWithTimeoutGuarded,status as assertOkOrThrowHttpError,unused as fetchWithTimeout,unused as createProviderHttpError,
  unused as isTransientProviderHttpStatus,unused as executeProviderOperationWithRetry} from '${platformModule}';
const DEFAULT_GUARDED_HTTP_TIMEOUT_MS=60000;`;
  const generated = prelude + '\n' + regions.map(region => bytes.subarray(region.startByte, region.endByte).toString()).join('\n');
  const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
  return { executable, audit: { path: operations, gitBlob: git(readOriginal.root, ['rev-parse', `${VYDRA_SPEECH_PIN}:${operations}`]),
    sourceSha256: hash(bytes), wholeModule: false, executed: false,
    projection: { regions, prelude, generatedCode: generated, generatedSha256: hash(generated) },
    executableSha256: hash(executable), executableIdentifier: operationModule } };
}

class VydraSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetchBinding = () => { throw Error('Uninvoked fixture global fetch binding called'); };
    this.context = vm.createContext({ Buffer, URL, Headers, fetch: this.fetchBinding,
      process: { env: plain(recipe.environment ?? {}) } }, { codeGeneration: { strings: false, wasm: false } });
    vm.runInContext('Date.now=()=>1700000000000;', this.context, { timeout: executionTimeoutMs });
  }

  platform() {
    const called = (name, value, details = {}) => {
      this.calls.push({ export: name, ...details });
      return value;
    };
    const bindings = {
      secret: ({ value, path }) => called('normalizeResolvedSecretInputString', value,
        { path, ...(value === undefined ? {} : { value }) }),
      requestConfig: params => called('resolveProviderHttpRequestConfig', {
        baseUrl: params.baseUrl, headers: new Headers(params.defaultHeaders),
        allowPrivateNetwork: params.allowPrivateNetwork, dispatcherPolicy: params.dispatcherPolicy,
      }, { input: plain(params) }),
      mediaCap: (cfg, kind) => called('resolveGeneratedMediaMaxBytes', 16 * 1024 * 1024,
        { cfg: plain(cfg ?? {}), kind, implementation: 'fixed-positive-platform-cap-no-budget-qualification' }),
      guarded: async (url, init, timeoutMs, fetchFn, options) => {
        assert.equal(fetchFn, this.fetchBinding);
        const stage = init.method === 'POST' ? 'submission' : 'download';
        const receipt = { stage, method: init.method, url,
          headers: Object.fromEntries(new Headers(init.headers)), timeoutMs: timeoutMs ?? null,
          ...(init.body === undefined ? {} : { rawBody: init.body, body: JSON.parse(init.body) }),
          options: plain(options ?? {}), releaseCount: 0 };
        this.requests.push(receipt);
        called('fetchWithTimeoutGuarded', undefined, { stage, timeoutMs: timeoutMs ?? null });
        const headers = init.method === 'POST' ? new Headers({ 'content-type': 'application/json' })
          : new Headers(this.recipe.response.contentType === null ? {} : { 'content-type': this.recipe.response.contentType });
        const response = { status: 200, ok: true, headers };
        return { response, release: async () => {
          receipt.releaseCount += 1;
          this.releaseCount += 1;
          called('release', undefined, { stage });
        } };
      },
      status: async (response, label, options) => called('assertOkOrThrowHttpError', undefined,
        { status: response.status, label, bodyTimeoutCallbackProvided: typeof options?.bodyTimeoutMs === 'function' }),
      readJson: async (response, label) => called('readProviderJsonResponse', plain(this.recipe.response.payload),
        { status: response.status, label }),
      readObject: () => { throw Error('Uninvoked JSON object reader boundary'); },
      readBinary: async (response, label, kind, options) => {
        called('readProviderBinaryResponse', undefined, { status: response.status, label, kind,
          timeoutMs: typeof options?.timeoutMs === 'function' ? options.timeoutMs() : options?.timeoutMs ?? null,
          maxBytes: options?.maxBytes ?? null, chunkTimeoutMs: options?.chunkTimeoutMs ?? null,
          timeoutCallbackProvided: typeof options?.onTimeout === 'function',
          overflowCallbackProvided: typeof options?.onOverflow === 'function' });
        return Buffer.from(this.recipe.response.audioBase64, 'base64');
      },
      unused: () => { throw Error('Uninvoked platform binding outside ordinary Vydra speech callback'); },
    };
    return new vm.SyntheticModule(Object.keys(bindings), function () {
      for (const [name, value] of Object.entries(bindings)) this.setExport(name, value);
    }, { context: this.context, identifier: platformModule });
  }

  module(identifier) {
    if (this.modules.has(identifier)) return this.modules.get(identifier);
    let module;
    if (identifier === platformModule) module = this.platform();
    else if (identifier === 'node:path') module = new vm.SyntheticModule(['default'], function () {
      this.setExport('default', nodePath);
    }, { context: this.context, identifier });
    else if (identifier === 'node:fs') module = new vm.SyntheticModule(['rmSync'], function () {
      this.setExport('rmSync', () => { throw Error('Uninvoked source cleanup binding'); });
    }, { context: this.context, identifier });
    else {
      const executable = this.executables.get(identifier) ?? sdkFacades[identifier];
      assert.equal(typeof executable, 'string', `declared source or facade: ${identifier}`);
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
    let resolved = specifier.startsWith('.')
      ? posix.normalize(posix.join(dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts') : specifier;
    if (importer.identifier === jsonPost && specifier === './shared.js') resolved = operationModule;
    assert.ok(this.executables.has(resolved) || Object.hasOwn(sdkFacades, resolved)
      || [platformModule, 'node:path', 'node:fs'].includes(resolved),
    `declared import: ${importer.identifier} -> ${specifier}`);
    provenance.push({ importer: importer.identifier, specifier, resolved });
    return this.module(resolved);
  }

  async evaluate(identifier) {
    const module = this.module(identifier);
    if (module.status === 'unlinked') await withDeadline(module.link((name, from) => this.resolveImport(name, from, this.staticImports)));
    if (module.status === 'linked') await withDeadline(module.evaluate({ timeout: executionTimeoutMs }));
    return module;
  }

  async run() {
    await this.evaluate(VYDRA_SPEECH_SOURCE);
    if (this.kind === 'extraction') await this.evaluate(vydraShared);
    this.context.speechSource = this.modules.get(VYDRA_SPEECH_SOURCE).namespace;
    this.context.defaultSource = this.modules.get(defaults).namespace;
    if (this.kind === 'extraction') this.context.sharedSource = this.modules.get(vydraShared).namespace;
    this.context.recipeInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildVydraSpeechProvider();
      const metadata = {id:provider.id,label:provider.label,models:provider.models,voices:provider.voices,
        defaultTimeoutMs:provider.defaultTimeoutMs ?? null};
      const listVoices = await provider.listVoices();
      if (observationKind === 'config') return {result:provider.resolveConfig({rawConfig:recipeInput.rawConfig}),metadata,listVoices};
      if (observationKind === 'base') return {result:defaultSource.normalizeVydraBaseUrl(recipeInput.value),metadata,listVoices};
      if (observationKind === 'extraction') return {result:sharedSource.extractVydraResultUrls(recipeInput.payload,recipeInput.kind),metadata,listVoices};
      const resolvedConfig = provider.resolveConfig({rawConfig:recipeInput.rawConfig});
      const request = {text:recipeInput.text,target:recipeInput.target,timeoutMs:recipeInput.timeoutMs,
        providerConfig:resolvedConfig,providerOverrides:recipeInput.providerOverrides,cfg:recipeInput.cfg};
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      const result = await provider.synthesize(request);
      return {resolvedConfig,result,metadata,listVoices,synthesisRequest,synthesisRequestAfter:JSON.parse(JSON.stringify(request))};
    })()`, this.context, { timeout: executionTimeoutMs }));
    const common = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter: plain(this.context.recipeInput),
      environment: plain(this.recipe.environment ?? {}),
      providerMetadata: plain(execution.metadata), listVoices: plain(execution.listVoices),
      platformCalls: this.calls };
    let observation;
    if (this.kind === 'synthesis') {
      assert.equal(this.requests.length, 2);
      assert.equal(this.releaseCount, 2);
      const [post, download] = this.requests;
      assert.equal(post.method, 'POST');
      assert.equal(download.method, 'GET');
      const { audioBuffer, ...metadata } = execution.result;
      assert.deepEqual(audioBuffer, Buffer.from(this.recipe.response.audioBase64, 'base64'));
      observation = { ...common, resolvedConfig: plain(execution.resolvedConfig),
        synthesisRequest: plain(execution.synthesisRequest), synthesisRequestAfter: plain(execution.synthesisRequestAfter),
        request: { url: post.url, body: plain(post.body), timeoutMs: post.timeoutMs },
        download: { url: download.url, timeoutMs: download.timeoutMs },
        response: plain(this.recipe.response),
        result: { audioBase64: audioBuffer.toString('base64'), ...plain(metadata) },
        releaseCount: this.releaseCount, rawRequests: plain(this.requests) };
    } else {
      assert.equal(this.requests.length, 0);
      assert.equal(this.releaseCount, 0);
      observation = { ...common, result: plain(execution.result) };
    }
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: wholeSources.filter(path => this.modules.get(path)?.status === 'evaluated'),
      operationRegionsEvaluated: this.modules.get(operationModule)?.status === 'evaluated' };
  }
}

const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureVydraSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${VYDRA_SPEECH_PIN}:${path}`], {
      timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete pinned source bytes: ${path}`);
    return bytes;
  };
  readOriginal.root = root;
  const executables = new Map();
  const sourceAudit = wholeSources.map(path => {
    const bytes = readOriginal(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(path, executable);
    return { path, gitBlob: git(root, ['rev-parse', `${VYDRA_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const projected = originalOperationRegions(readOriginal);
  executables.set(operationModule, projected.executable);
  const manifestBytes = readOriginal(manifestPath), licenseBytes = readOriginal(licensePath);
  const groups = {};
  for (const [kind, recipes] of Object.entries(VYDRA_SPEECH_CASES)) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new VydraSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  projected.audit.executed = runs.some(run => run.operationRegionsEvaluated);
  sourceAudit.push(projected.audit);
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  return {
    schemaVersion: 1, referencePin: VYDRA_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-vydra-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [
      { path: manifestPath, gitBlob: git(root, ['rev-parse', `${VYDRA_SPEECH_PIN}:${manifestPath}`]), sourceSha256: hash(manifestBytes),
        usage: 'Complete original plugin-manifest provenance; speech does not import this JSON or invoke plugin registration.', evaluated: false },
      { path: licensePath, gitBlob: git(root, ['rev-parse', `${VYDRA_SPEECH_PIN}:${licensePath}`]), sourceSha256: hash(licenseBytes),
        usage: 'Complete original source license provenance', evaluated: false },
    ],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries,
    providerMetadata: runs[0].observation.providerMetadata, listVoices: runs[0].observation.listVoices,
    counts: { configObservations: groups.config.length, baseObservations: groups.base.length,
      extractionObservations: groups.extraction.length, synthesisCallbacks: groups.synthesis.length,
      totalObservations: runs.length, httpRequests: groups.synthesis.length * 2,
      releases: groups.synthesis.length * 2, listVoicesCallbacks: runs.length,
      wholeModules: evaluated.size, completeRegionModules: projected.audit.executed ? 1 : 0,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    baseObservations: groups.base.map(run => run.observation),
    extractionObservations: groups.extraction.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    limits: [
      'All58558 pinned tracked blobs/modes verified before and after; whole original source modules, exact source regions, manifest and LICENSE additionally match pinned Git bytes.',
      'Whole-module execution means evaluation, not all exports: original factory/resolveConfig/listVoices/synthesize, normalizeVydraBaseUrl, extractVydraResultUrls and downloadVydraAsset execute.',
      'Original shared operation/deadline/post functions use recorded complete source regions with exact spans/prelude/generated/executable hashes. Original JSON wrapper executes; status/JSON/binary readers and transport are explicit successful synthetic boundaries.',
      'Original MIME/file-name/constants modules execute unchanged after TS erasure. Only extensionForMime/normalization are called; dynamic file-type import/sniffing and unrelated file-path functions are uninvoked.',
      'Source speech has exactly one POST followed by first ordered URL GET, with no polling. Both targets retain the same branch and voiceCompatible=false.',
      'Raw MIME.includes(wav) is case-sensitive, while helper filename extension uses normalized MIME; outputFormat and fileExtension can intentionally diverge. Opaque bytes do not prove codec/transcode/playback.',
      'Every recipe supplies an explicit positive timeout. Original POST passes the explicit per-stage timeout to the synthetic guarded boundary; original download creates its own absolute deadline with constant recorded Date.now. No elapsed-time, fallback/retry/expiration or original guarded transport qualification.',
      'Only recipe process.env is exposed. Source environment config fallback is observed; host configuration/environment policy is not installed. Fixed explicit key normalization is part of synthesis, not authentication or security acceptance.',
      'Manifest is exact source provenance, not an evaluated import or plugin-registration claim. isConfigured/isConfiguredAsync, Talk/telephony/streaming and actual channel delivery are uncalled or absent.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real-provider or remote-MCP test executes.',
    ],
  };
}

export async function writeVydraSpeechCapture(root, output) {
  const capture = await captureVydraSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-vydra-speech.mjs --source DIR [--output FILE]');
    if (args[index] === '--source') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeVydraSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureVydraSpeech(root), null, 2) + '\n');
}
