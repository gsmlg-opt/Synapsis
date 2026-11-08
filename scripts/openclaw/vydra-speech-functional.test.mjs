// Independent literal Vydra speech oracle authored from pinned source before target execution.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureVydraSpeech, VYDRA_SPEECH_CASES, VYDRA_SPEECH_PIN } from './capture-vydra-speech.mjs';
const source = '/tmp/openclaw-488631c';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/vydra-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const inputs = {
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
const expected = {
  "config": [
    {
      "id": "config-defaults",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      }
    },
    {
      "id": "config-explicit",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://speech.example.test/custom/v7",
        "model": "custom/model",
        "voiceId": "custom-voice"
      }
    },
    {
      "id": "config-source-env",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://env.example.test/voice",
        "model": "env/model",
        "voiceId": "env-voice"
      }
    },
    {
      "id": "config-before-env",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://speech.example.test/custom/v7",
        "model": "custom/model",
        "voiceId": "custom-voice"
      }
    },
    {
      "id": "config-empty-strings-source-env",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://env.example.test/voice",
        "model": "env/model",
        "voiceId": "env-voice"
      }
    },
    {
      "id": "config-unicode",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "Rachel-custom"
      }
    },
    {
      "id": "config-root-canonical",
      "result": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      }
    }
  ],
  "base": [
    {
      "id": "base-canonical-root",
      "result": "https://www.vydra.ai/api/v1"
    },
    {
      "id": "base-custom-prefix",
      "result": "https://voice.example.test/custom/v7"
    },
    {
      "id": "base-custom-root",
      "result": "https://voice.example.test/api/v1"
    },
    {
      "id": "base-port",
      "result": "https://www.vydra.ai:8443/voice"
    },
    {
      "id": "base-query-fragment",
      "result": "https://www.vydra.ai/api/v1?mode=voice#section"
    }
  ],
  "extraction": [
    {
      "id": "extract-root-priority",
      "result": [
        "https://www.vydra.ai/assets/first",
        "https://www.vydra.ai/assets/second",
        "https://www.vydra.ai/assets/third"
      ]
    },
    {
      "id": "extract-arrays",
      "result": [
        "https://www.vydra.ai/assets/first",
        "https://www.vydra.ai/assets/second",
        "https://www.vydra.ai/assets/third"
      ]
    },
    {
      "id": "extract-nested-order",
      "result": [
        "https://www.vydra.ai/assets/first",
        "https://www.vydra.ai/assets/second",
        "https://www.vydra.ai/assets/third"
      ]
    },
    {
      "id": "extract-ordered-dedup",
      "result": [
        "https://www.vydra.ai/assets/first",
        "https://www.vydra.ai/assets/second",
        "https://www.vydra.ai/assets/third"
      ]
    },
    {
      "id": "extract-all-keys-and-recursion",
      "result": [
        "https://www.vydra.ai/assets/key-1",
        "https://www.vydra.ai/assets/key-2",
        "https://www.vydra.ai/assets/key-3",
        "https://www.vydra.ai/assets/key-4",
        "https://www.vydra.ai/assets/key-5",
        "https://www.vydra.ai/assets/key-6",
        "https://www.vydra.ai/assets/key-7",
        "https://www.vydra.ai/assets/key-8",
        "https://www.vydra.ai/assets/key-9",
        "https://www.vydra.ai/assets/key-10",
        "https://www.vydra.ai/assets/key-11",
        "https://www.vydra.ai/assets/key-12",
        "https://www.vydra.ai/assets/key-13",
        "https://www.vydra.ai/assets/key-14",
        "https://www.vydra.ai/assets/key-15"
      ]
    }
  ],
  "synthesis": [
    {
      "id": "default-file",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "wav-file",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "wav-note",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "default-mime",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "configured-model-voice",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://speech.example.test/custom/v7",
        "model": "custom/model",
        "voiceId": "custom-voice"
      },
      "request": {
        "url": "https://speech.example.test/custom/v7/models/custom/model",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "custom-voice"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://speech.example.test/assets/first",
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
      "id": "override-model-voice",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/custom/override",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "override-voice"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "blank-override-defaults",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "configured-namespace-retained",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "vydra/elevenlabs/custom",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/vydra/elevenlabs/custom",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "source-env-all",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://env.example.test/voice",
        "model": "env/model",
        "voiceId": "env-voice"
      },
      "request": {
        "url": "https://env.example.test/voice/models/env/model",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "env-voice"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://env.example.test/assets/first",
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
      "id": "source-env-model",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "env/model",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/env/model",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "source-env-voice",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "env-voice"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "env-voice"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "configured-before-source-env",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://speech.example.test/custom/v7",
        "model": "custom/model",
        "voiceId": "custom-voice"
      },
      "request": {
        "url": "https://speech.example.test/custom/v7/models/custom/model",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "custom-voice"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://speech.example.test/assets/first",
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
      "id": "canonical-root",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "custom-root",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://voice.example.test/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://voice.example.test/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://voice.example.test/assets/first",
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
      "id": "port-literal-url",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai:8443/voice",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai:8443/voice/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai:8443/assets/first",
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
      "id": "query-fragment-literal-url",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1?mode=voice#section",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1?mode=voice#section/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "unicode-config",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "Rachel-custom"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "Rachel-custom"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "exact-authored-text",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "synthesis-extract-root-priority",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "synthesis-extract-arrays",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "synthesis-extract-nested-order",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "synthesis-extract-ordered-dedup",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "synthesis-extract-all-keys-and-recursion",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/key-1",
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
      "id": "mpeg-parameters",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "wav-parameters",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "wav-case-divergence",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    {
      "id": "mpeg-parameter-divergence",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
        "timeoutMs": 12345
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "wav",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    {
      "id": "x-wav",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "flac-source-labels",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "octet-stream-source-labels",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 12345
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "explicit-timeout-45000",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 45000
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
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
      "id": "explicit-timeout-75000-note",
      "resolvedConfig": {
        "apiKey": "fixture-vydra-speech",
        "baseUrl": "https://www.vydra.ai/api/v1",
        "model": "elevenlabs/tts",
        "voiceId": "21m00Tcm4TlvDq8ikWAM"
      },
      "request": {
        "url": "https://www.vydra.ai/api/v1/models/elevenlabs/tts",
        "body": {
          "text": "Ordinary Vydra speech.",
          "voice_id": "21m00Tcm4TlvDq8ikWAM"
        },
        "timeoutMs": 75000
      },
      "download": {
        "url": "https://www.vydra.ai/assets/first",
        "timeoutMs": 75000
      },
      "result": {
        "audioBase64": "UklGRgABAv8=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    }
  ]
};
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const semantic = row => ({id:row.id,resolvedConfig:row.resolvedConfig,
  request:row.request,download:row.download,result:row.result});

test('original factory metadata and static voices retain the complete ordinary surface', () => {
  assert.equal(VYDRA_SPEECH_PIN, pin);
  assert.equal(fixture.referencePin, pin);
  assert.deepEqual(fixture.providerMetadata, {id:'vydra',label:'Vydra',models:['elevenlabs/tts'],
    voices:['21m00Tcm4TlvDq8ikWAM'],defaultTimeoutMs:null});
  assert.deepEqual(fixture.listVoices,[{id:'21m00Tcm4TlvDq8ikWAM',name:'Rachel'}]);
  assert.deepEqual(VYDRA_SPEECH_CASES, inputs);
});

test('all seven original config callbacks preserve exact defaults explicit settings and source-only env', () => {
  assert.equal(fixture.configObservations.length,7);
  assert.deepEqual(fixture.configObservations.map(({id,result})=>({id,result})),expected.config);
  for(const row of fixture.configObservations){const input=inputs.config.find(x=>x.id===row.id);
    assert.deepEqual(row.input,input.input);assert.deepEqual(row.environment,input.environment);}
});

test('all five valid base URL callbacks retain canonical root prefix port and query-fragment behavior', () => {
  assert.deepEqual(fixture.baseObservations.map(({id,result})=>({id,result})),expected.base);
});

test('ordinary URL extraction retains exact key recursion array order and stable deduplication', () => {
  assert.deepEqual(fixture.extractionObservations.map(({id,result})=>({id,result})),expected.extraction);
});

test('all33 synthesis callbacks retain independent literal resolved config wire first GET and opaque results', () => {
  assert.equal(fixture.observations.length,33);
  assert.deepEqual(fixture.observations.map(semantic),expected.synthesis);
  for(const row of fixture.observations){const input=inputs.synthesis.find(x=>x.id===row.id);
    assert.deepEqual(row.input,input.input);assert.deepEqual(row.environment,input.environment);
    assert.deepEqual(row.inputAfter,row.input);
    assert.deepEqual(row.synthesisRequestAfter,row.synthesisRequest);}
});

test('both file and note targets preserve complete MP3 and WAV callbacks', () => {
  const find=id=>fixture.observations.find(row=>row.id===id);
  for(const [file,note] of [['default-file','default-note'],['wav-file','wav-note']]){
    assert.deepEqual(find(file).request,find(note).request);
    assert.deepEqual(find(file).download,find(note).download);
    assert.deepEqual(find(file).result,find(note).result);
    assert.equal(find(file).input.target,'audio-file');assert.equal(find(note).input.target,'voice-note');
  }
});

test('source case-sensitive output format remains independent of MIME-normalized filename extension', () => {
  const row=fixture.observations.find(row=>row.id==='wav-case-divergence');
  assert.deepEqual(row.result,{audioBase64:'UklGRgABAv8=',outputFormat:'mp3',fileExtension:'.wav',voiceCompatible:false});
  assert.deepEqual(fixture.observations.find(row=>row.id==='mpeg-parameter-divergence').result,
    {audioBase64:'UklGRgABAv8=',outputFormat:'wav',fileExtension:'.mp3',voiceCompatible:false});
  for(const id of ['flac-source-labels','octet-stream-source-labels'])
    assert.deepEqual(fixture.observations.find(row=>row.id===id).result,
      {audioBase64:'UklGRgABAv8=',outputFormat:'mp3',fileExtension:'.mp3',voiceCompatible:false});
});

test('original complete modules helper regions data and full pinned checkout have exact provenance', () => {
  assert.equal(fixture.checkout.before.verifiedTrackedFiles,58558);
  assert.deepEqual(fixture.checkout.after,fixture.checkout.before);
  const required=['extensions/vydra/speech-provider.ts','extensions/vydra/defaults.ts','extensions/vydra/shared.ts',
    'packages/normalization-core/src/string-coerce.ts','packages/normalization-core/src/record-coerce.ts',
    'packages/normalization-core/src/number-coercion.ts','src/tts/tts-provider-helpers.ts',
    'packages/media-core/src/mime.ts','packages/media-core/src/file-name.ts','packages/media-core/src/constants.ts',
    'src/media-understanding/provider-json-post.ts'];
  for(const path of required){const row=fixture.sourceAudit.find(row=>row.path===path && row.wholeModule);
    assert.ok(row,path+' complete original module');assert.equal(row.executed,true);
    assert.equal(row.sourceSha256??row.sha256,sha(readFileSync(join(source,path))));}
  for(const row of [...fixture.sourceAudit,...fixture.dataAudit])
    assert.equal(row.sourceSha256??row.sha256,sha(readFileSync(join(source,row.path))),row.path);
  for(const row of fixture.sourceAudit.filter(row=>row.projection)){
    const original=readFileSync(join(source,row.path));
    const regions=row.projection.regions.map(region=>{
      const bytes=original.subarray(region.startByte,region.endByte);
      assert.equal(sha(bytes),region.sourceRegionSha256);return bytes.toString();});
    const generated=row.projection.prelude+'\n'+regions.join('\n');
    assert.equal(generated,row.projection.generatedCode);
    assert.equal(sha(generated),row.projection.generatedSha256);
    assert.equal(sha(stripTypeScriptTypes(generated,{mode:'transform',sourceMap:false})),row.executableSha256);
    assert.equal(row.executed,true);
  }
  assert.deepEqual(fixture.pluginManifest,JSON.parse(readFileSync(join(source,'extensions/vydra/openclaw.plugin.json'))));
  assert.equal(fixture.license.text,readFileSync(join(source,'LICENSE'),'utf8'));
});

test('fresh isolated original-module capture exactly matches the entire saved fixture', async () => {
  assert.deepEqual(await captureVydraSpeech(source),fixture);
});

test('fresh CLI capture exactly matches saved full JSON without replacing the fixture', () => {
  const temp=mkdtempSync(join(tmpdir(),'synapsis-vydra-speech-oracle-'));
  try{const output=join(temp,'capture.json');
    execFileSync(process.execPath,['--experimental-vm-modules',fileURLToPath(new URL('./capture-vydra-speech.mjs',import.meta.url)),
      '--source',source,'--output',output],{cwd:resolve('.'),timeout:90000,stdio:['ignore','pipe','pipe']});
    assert.deepEqual(JSON.parse(readFileSync(output,'utf8')),fixture);
  }finally{rmSync(temp,{recursive:true,force:true});}
});
