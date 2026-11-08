// Independent Azure Speech ordinary oracle: literals reasoned from pinned source before execution.
// HTTP/media/secret/policy bindings are explicit synthetic success boundaries, not live transport/auth qualification.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { captureAzureSpeech, AZURE_SPEECH_CASES, AZURE_SPEECH_PIN, AZURE_SPEECH_SOURCE } from './capture-azure-speech.mjs';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/azure-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath,'utf8'));
const sourceRoot = '/tmp/openclaw-488631c';
const inputs = {
  "config": [
    {
      "id": "config-region-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": " westus "
            }
          }
        }
      }
    },
    {
      "id": "config-azure-alias-and-field-aliases",
      "input": {
        "rawConfig": {
          "providers": {
            "azure": {
              "apiKey": "fixture-azure-speech",
              "endpoint": " https://speech.example/prefix/cognitiveservices/v1/// ",
              "voiceId": " fr-FR-DeniseNeural ",
              "languageCode": " fr-FR ",
              "outputFormat": " riff-24khz-16bit-mono-pcm ",
              "voiceNoteOutputFormat": " webm-24khz-16bit-mono-opus ",
              "timeoutMs": 45000
            }
          }
        }
      }
    },
    {
      "id": "config-provider-id-precedes-alias",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "centralus",
              "voice": "Primary"
            },
            "azure": {
              "apiKey": "fixture-azure-speech",
              "region": "eastus",
              "voice": "Secondary"
            }
          }
        }
      }
    },
    {
      "id": "config-base-url-before-endpoint-and-region",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": " westus ",
              "endpoint": " https://ignored.example/endpoint ",
              "baseUrl": " https://Root.Example/custom/cognitiveservices/v1/// "
            }
          }
        }
      }
    },
    {
      "id": "config-uppercase-terminal-route",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "endpoint": " https://speech.example/tenant/CognitiveServices/V1//// "
            }
          }
        }
      }
    },
    {
      "id": "config-region-spelling-retained",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": " EastUS2 "
            }
          }
        }
      }
    },
    {
      "id": "config-primary-field-aliases",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "voice": " Primary ",
              "voiceId": "Secondary",
              "lang": " de-DE ",
              "languageCode": "fr-FR",
              "outputFormat": " AUDIO-24KHZ-MONO-MP3 ",
              "voiceNoteOutputFormat": " OGG-24KHZ-MONO-OPUS "
            }
          }
        }
      }
    },
    {
      "id": "config-blank-primary-retains-default",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "voice": " ",
              "voiceId": "Secondary",
              "lang": " ",
              "languageCode": "fr-FR"
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
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": " ﻿westus﻿ ",
              "voice": " ﻿zh-CN-XiaoxiaoNeural﻿ ",
              "lang": " zh-CN "
            }
          }
        }
      }
    },
    {
      "id": "config-positive-fraction-timeout-preserved",
      "input": {
        "rawConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "timeoutMs": 12345.5
            }
          }
        }
      }
    }
  ],
  "talkConfig": [
    {
      "id": "talk-inherit-all",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {}
      }
    },
    {
      "id": "talk-voice-only-route-inherited",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " TalkVoice "
        }
      }
    },
    {
      "id": "talk-region-selects-route",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "region": " northeurope "
        }
      }
    },
    {
      "id": "talk-endpoint-selects-route",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "endpoint": " https://talk.example/prefix/cognitiveservices/v1/// "
        }
      }
    },
    {
      "id": "talk-base-url-selects-route",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk-base.example/root/CognitiveServices/V1/// "
        }
      }
    },
    {
      "id": "talk-explicit-route-and-fields",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": "fixture-talk-key",
          "region": " eastus ",
          "endpoint": " https://talk-endpoint.example/alt ",
          "baseUrl": " https://talk-base.example/primary/ ",
          "voiceId": " TalkVoice ",
          "languageCode": " fr-FR ",
          "outputFormat": " webm-24khz-16bit-mono-opus "
        }
      }
    },
    {
      "id": "talk-blank-optional-fields-preserve-base",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "region": " ",
          "endpoint": " ",
          "baseUrl": " ",
          "voiceId": " ",
          "languageCode": " ",
          "outputFormat": " "
        }
      }
    },
    {
      "id": "talk-null-endpoint-uses-base-url",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "azure-speech": {
              "apiKey": "fixture-azure-speech",
              "region": "westus",
              "endpoint": "https://saved.example/root/cognitiveservices/v1",
              "baseUrl": "https://saved.example/root",
              "voice": "SavedVoice",
              "lang": "en-GB",
              "outputFormat": "riff-24khz-16bit-mono-pcm",
              "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
              "timeoutMs": 60000
            }
          }
        },
        "talkProviderConfig": {
          "endpoint": null,
          "baseUrl": " https://talk-null.example/root/ "
        }
      }
    }
  ],
  "talkOverride": [
    {
      "id": "talk-overrides-empty",
      "input": {
        "params": {}
      }
    },
    {
      "id": "talk-overrides-full",
      "input": {
        "params": {
          "voiceId": " VoiceOverride ",
          "languageCode": " ja-JP ",
          "outputFormat": " raw-24khz-16bit-mono-pcm "
        }
      }
    },
    {
      "id": "talk-overrides-voice-only",
      "input": {
        "params": {
          "voiceId": " zh-CN-XiaoxiaoNeural "
        }
      }
    },
    {
      "id": "talk-overrides-blank-optional",
      "input": {
        "params": {
          "voiceId": " ",
          "languageCode": " ",
          "outputFormat": " "
        }
      }
    }
  ],
  "synthesis": [
    {
      "id": "synthesis-default-file",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-default-voice-note",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-generic-telephony-is-file-format",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "telephony",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-config-timeout-precedes-request",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "timeoutMs": 60000
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-positive-fraction-timeout",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "timeoutMs": 12345.5
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-upper-mp3",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " AuDiO-24KHZ-MONO-MP3 "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-upper-ogg-opus",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " OGG-24KHZ-16BIT-MONO-OPUS "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-ogg-vorbis",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " ogg-24khz-16bit-mono-vorbis "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-webm-opus",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " webm-24khz-16bit-mono-opus "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-riff-pcm",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " riff-24khz-16bit-mono-pcm "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-raw-pcm",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " raw-24khz-16bit-mono-pcm "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-amr",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " amr-16khz-32kbps "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-custom",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " vendor-custom-encoding "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-format-mp3-substring-priority",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": " ogg-special-mp3-opus "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-exact-text-and-attribute-ssml",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "voice": "Ada \"&<>'",
          "lang": "en\"&<>'"
        },
        "text": "Fish & <sea> \"quoted\" 'waves'\n第二行",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-override-field-aliases",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "voiceId": " fr-FR-DeniseNeural ",
          "languageCode": " fr-FR ",
          "outputFormat": " riff-24khz-16bit-mono-pcm "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-primary-overrides-before-aliases",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "voice": " Primary ",
          "voiceId": "Secondary",
          "lang": " de-DE ",
          "languageCode": "fr-FR"
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-blank-primary-does-not-select-secondary",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "voice": " ",
          "voiceId": "Secondary",
          "lang": " ",
          "languageCode": "fr-FR",
          "outputFormat": " "
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-configured-voice-note-format",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "voiceNoteOutputFormat": " webm-24khz-16bit-mono-opus "
        },
        "text": "Hello Azure.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-override-format-before-note-config",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus"
        },
        "text": "Hello Azure.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": "riff-24khz-16bit-mono-pcm"
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "synthesis-configured-endpoint-route",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "endpoint": " https://speech.example/tenant/CognitiveServices/V1/// "
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    }
  ],
  "telephony": [
    {
      "id": "telephony-forced-default",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "telephony-ignores-configured-and-request-format",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "outputFormat": "riff-24khz-16bit-mono-pcm",
          "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus"
        },
        "text": "Hello Azure.",
        "target": "voice-note",
        "timeoutMs": 12345,
        "providerOverrides": {
          "outputFormat": "amr-16khz-32kbps"
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    },
    {
      "id": "telephony-keeps-voice-language-and-config-timeout",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "timeoutMs": 60000
        },
        "text": "Hello Azure.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "voiceId": "fr-FR-DeniseNeural",
          "languageCode": "fr-FR",
          "outputFormat": "riff-24khz-16bit-mono-pcm"
        }
      },
      "response": {
        "audioBase64": "AAEC/v8="
      }
    }
  ],
  "voices": [
    {
      "id": "voices-region-default-list-timeout",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        }
      },
      "response": {
        "json": [
          {
            "ShortName": " en-US-JennyNeural ",
            "DisplayName": " Jenny ",
            "Locale": " en-US ",
            "Gender": " Female "
          },
          {
            "ShortName": " fr-FR-DeniseNeural ",
            "LocalName": " Denise locale ",
            "Locale": " fr-FR ",
            "Gender": " Female "
          }
        ]
      }
    },
    {
      "id": "voices-explicit-request-route-and-timeout",
      "input": {
        "apiKey": "fixture-azure-speech",
        "baseUrl": " https://voices.example/custom/cognitiveservices/v1/// ",
        "timeoutMs": 12000
      },
      "response": {
        "json": [
          {
            "ShortName": " en-US-JennyNeural ",
            "DisplayName": " Jenny ",
            "Locale": " en-US ",
            "Gender": " Female "
          },
          {
            "ShortName": " fr-FR-DeniseNeural ",
            "LocalName": " Denise locale ",
            "Locale": " fr-FR ",
            "Gender": " Female "
          }
        ]
      }
    },
    {
      "id": "voices-config-timeout-before-request-and-request-route",
      "input": {
        "apiKey": "fixture-azure-speech",
        "baseUrl": " https://request-voices.example/root/// ",
        "timeoutMs": 12000,
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus",
          "baseUrl": "https://ignored-config.example",
          "timeoutMs": 60000
        }
      },
      "response": {
        "json": [
          {
            "ShortName": " en-US-JennyNeural ",
            "DisplayName": " Jenny ",
            "Locale": " en-US ",
            "Gender": " Female "
          },
          {
            "ShortName": " fr-FR-DeniseNeural ",
            "LocalName": " Denise locale ",
            "Locale": " fr-FR ",
            "Gender": " Female "
          }
        ]
      }
    },
    {
      "id": "voices-ordered-tags-personalities-and-duplicates",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "region": "westus"
        },
        "timeoutMs": 23456
      },
      "response": {
        "json": [
          {
            "ShortName": " zh-CN-XiaoxiaoNeural ",
            "DisplayName": " 晓晓 ",
            "LocalName": " ignored local ",
            "Locale": " zh-CN ",
            "Gender": " Female ",
            "Status": " Active ",
            "IsDeprecated": false,
            "VoiceTag": {
              "TailoredScenarios": [
                " General ",
                " Assistant "
              ],
              "VoicePersonalities": [
                " Warm ",
                " Friendly "
              ]
            }
          },
          {
            "ShortName": "en-US-JennyNeural",
            "DisplayName": " ",
            "LocalName": " Jenny local ",
            "Locale": "en-US",
            "Gender": "Female",
            "VoiceTag": {
              "VoicePersonalities": [
                " Cheerful "
              ]
            }
          },
          {
            "ShortName": "en-US-JennyNeural",
            "DisplayName": "Jenny duplicate",
            "Status": "Preview",
            "VoiceTag": {
              "TailoredScenarios": [
                " narration "
              ]
            }
          },
          {
            "ShortName": "de-DE-KatjaNeural",
            "DisplayName": "Katja",
            "VoiceTag": {
              "TailoredScenarios": [],
              "VoicePersonalities": []
            }
          }
        ]
      }
    },
    {
      "id": "voices-configured-endpoint-route",
      "input": {
        "providerConfig": {
          "apiKey": "fixture-azure-speech",
          "endpoint": " https://speech.example/tenant/CognitiveServices/V1/// "
        }
      },
      "response": {
        "json": [
          {
            "ShortName": " en-US-JennyNeural ",
            "DisplayName": " Jenny ",
            "Locale": " en-US ",
            "Gender": " Female "
          },
          {
            "ShortName": " fr-FR-DeniseNeural ",
            "LocalName": " Denise locale ",
            "Locale": " fr-FR ",
            "Gender": " Female "
          }
        ]
      }
    }
  ]
};
const expected = {
  "config": {
    "config-region-defaults": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://westus.tts.speech.microsoft.com",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
    },
    "config-azure-alias-and-field-aliases": {
      "apiKey": "fixture-azure-speech",
      "baseUrl": "https://speech.example/prefix",
      "voice": "fr-FR-DeniseNeural",
      "lang": "fr-FR",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://speech.example/prefix/cognitiveservices/v1///",
      "timeoutMs": 45000
    },
    "config-provider-id-precedes-alias": {
      "apiKey": "fixture-azure-speech",
      "region": "centralus",
      "baseUrl": "https://centralus.tts.speech.microsoft.com",
      "voice": "Primary",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
    },
    "config-base-url-before-endpoint-and-region": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://Root.Example/custom",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus",
      "endpoint": "https://ignored.example/endpoint"
    },
    "config-uppercase-terminal-route": {
      "apiKey": "fixture-azure-speech",
      "baseUrl": "https://speech.example/tenant",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus",
      "endpoint": "https://speech.example/tenant/CognitiveServices/V1////"
    },
    "config-region-spelling-retained": {
      "apiKey": "fixture-azure-speech",
      "region": "EastUS2",
      "baseUrl": "https://EastUS2.tts.speech.microsoft.com",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
    },
    "config-primary-field-aliases": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://westus.tts.speech.microsoft.com",
      "voice": "Primary",
      "lang": "de-DE",
      "outputFormat": "AUDIO-24KHZ-MONO-MP3",
      "voiceNoteOutputFormat": "OGG-24KHZ-MONO-OPUS"
    },
    "config-blank-primary-retains-default": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://westus.tts.speech.microsoft.com",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
    },
    "config-unicode-trim": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://westus.tts.speech.microsoft.com",
      "voice": "zh-CN-XiaoxiaoNeural",
      "lang": "zh-CN",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
    },
    "config-positive-fraction-timeout-preserved": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://westus.tts.speech.microsoft.com",
      "voice": "en-US-JennyNeural",
      "lang": "en-US",
      "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus",
      "timeoutMs": 12345.5
    }
  },
  "talkConfig": {
    "talk-inherit-all": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://saved.example/root",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://saved.example/root/cognitiveservices/v1",
      "timeoutMs": 60000
    },
    "talk-voice-only-route-inherited": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://saved.example/root",
      "voice": "TalkVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://saved.example/root/cognitiveservices/v1",
      "timeoutMs": 60000
    },
    "talk-region-selects-route": {
      "apiKey": "fixture-azure-speech",
      "region": "northeurope",
      "baseUrl": "https://northeurope.tts.speech.microsoft.com",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://saved.example/root/cognitiveservices/v1",
      "timeoutMs": 60000
    },
    "talk-endpoint-selects-route": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://talk.example/prefix",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://talk.example/prefix/cognitiveservices/v1///",
      "timeoutMs": 60000
    },
    "talk-base-url-selects-route": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://talk-base.example/root",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://talk-base.example/root/CognitiveServices/V1///",
      "timeoutMs": 60000
    },
    "talk-explicit-route-and-fields": {
      "apiKey": "fixture-talk-key",
      "region": "eastus",
      "baseUrl": "https://talk-base.example/primary",
      "voice": "TalkVoice",
      "lang": "fr-FR",
      "outputFormat": "webm-24khz-16bit-mono-opus",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://talk-endpoint.example/alt",
      "timeoutMs": 60000
    },
    "talk-blank-optional-fields-preserve-base": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://saved.example/root",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://saved.example/root/cognitiveservices/v1",
      "timeoutMs": 60000
    },
    "talk-null-endpoint-uses-base-url": {
      "apiKey": "fixture-azure-speech",
      "region": "westus",
      "baseUrl": "https://talk-null.example/root",
      "voice": "SavedVoice",
      "lang": "en-GB",
      "outputFormat": "riff-24khz-16bit-mono-pcm",
      "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
      "endpoint": "https://talk-null.example/root/",
      "timeoutMs": 60000
    }
  },
  "talkOverride": {
    "talk-overrides-empty": {},
    "talk-overrides-full": {
      "voice": "VoiceOverride",
      "lang": "ja-JP",
      "outputFormat": "raw-24khz-16bit-mono-pcm"
    },
    "talk-overrides-voice-only": {
      "voice": "zh-CN-XiaoxiaoNeural"
    },
    "talk-overrides-blank-optional": {}
  },
  "synthesis": {
    "synthesis-default-file": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-default-voice-note": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "ogg-24khz-16bit-mono-opus",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "ogg-24khz-16bit-mono-opus",
        "fileExtension": ".ogg",
        "voiceCompatible": true
      }
    },
    "synthesis-generic-telephony-is-file-format": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-config-timeout-precedes-request": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 60000,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-positive-fraction-timeout": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345.5,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-format-upper-mp3": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "AuDiO-24KHZ-MONO-MP3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "AuDiO-24KHZ-MONO-MP3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-format-upper-ogg-opus": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "OGG-24KHZ-16BIT-MONO-OPUS",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "OGG-24KHZ-16BIT-MONO-OPUS",
        "fileExtension": ".ogg",
        "voiceCompatible": true
      }
    },
    "synthesis-format-ogg-vorbis": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "ogg-24khz-16bit-mono-vorbis",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "ogg-24khz-16bit-mono-vorbis",
        "fileExtension": ".ogg",
        "voiceCompatible": false
      }
    },
    "synthesis-format-webm-opus": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "webm-24khz-16bit-mono-opus",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "webm-24khz-16bit-mono-opus",
        "fileExtension": ".webm",
        "voiceCompatible": false
      }
    },
    "synthesis-format-riff-pcm": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "riff-24khz-16bit-mono-pcm",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "synthesis-format-raw-pcm": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "raw-24khz-16bit-mono-pcm",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "raw-24khz-16bit-mono-pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false
      }
    },
    "synthesis-format-amr": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "amr-16khz-32kbps",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "amr-16khz-32kbps",
        "fileExtension": ".amr",
        "voiceCompatible": false
      }
    },
    "synthesis-format-custom": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "vendor-custom-encoding",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "vendor-custom-encoding",
        "fileExtension": ".audio",
        "voiceCompatible": false
      }
    },
    "synthesis-format-mp3-substring-priority": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "ogg-special-mp3-opus",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "ogg-special-mp3-opus",
        "fileExtension": ".mp3",
        "voiceCompatible": true
      }
    },
    "synthesis-exact-text-and-attribute-ssml": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en&quot;&amp;&lt;&gt;&apos;\"><voice name=\"Ada &quot;&amp;&lt;&gt;&apos;\">Fish &amp; &lt;sea&gt; \"quoted\" 'waves'\n第二行</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-override-field-aliases": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"fr-FR\"><voice name=\"fr-FR-DeniseNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "riff-24khz-16bit-mono-pcm",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "synthesis-primary-overrides-before-aliases": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"de-DE\"><voice name=\"Primary\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-blank-primary-does-not-select-secondary": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "synthesis-configured-voice-note-format": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "webm-24khz-16bit-mono-opus",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "webm-24khz-16bit-mono-opus",
        "fileExtension": ".webm",
        "voiceCompatible": false
      }
    },
    "synthesis-override-format-before-note-config": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "riff-24khz-16bit-mono-pcm",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "synthesis-configured-endpoint-route": {
      "url": "https://speech.example/tenant/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    }
  },
  "telephony": {
    "telephony-forced-default": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "raw-8khz-8bit-mono-mulaw",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "raw-8khz-8bit-mono-mulaw",
        "sampleRate": 8000
      }
    },
    "telephony-ignores-configured-and-request-format": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 12345,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "raw-8khz-8bit-mono-mulaw",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "raw-8khz-8bit-mono-mulaw",
        "sampleRate": 8000
      }
    },
    "telephony-keeps-voice-language-and-config-timeout": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
      "timeoutMs": 60000,
      "auditContext": "azure-speech.tts",
      "init": {
        "method": "POST",
        "headers": {
          "Content-Type": "application/ssml+xml",
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech",
          "X-Microsoft-OutputFormat": "raw-8khz-8bit-mono-mulaw",
          "User-Agent": "OpenClaw"
        },
        "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"fr-FR\"><voice name=\"fr-FR-DeniseNeural\">Hello Azure.</voice></speak>"
      },
      "result": {
        "audioBase64": "AAEC/v8=",
        "outputFormat": "raw-8khz-8bit-mono-mulaw",
        "sampleRate": 8000
      }
    }
  },
  "voices": {
    "voices-region-default-list-timeout": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/voices/list",
      "timeoutMs": 30000,
      "auditContext": "azure-speech.voices",
      "init": {
        "method": "GET",
        "headers": {
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech"
        }
      },
      "result": [
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny",
          "locale": "en-US",
          "gender": "Female"
        },
        {
          "id": "fr-FR-DeniseNeural",
          "name": "Denise locale",
          "locale": "fr-FR",
          "gender": "Female"
        }
      ]
    },
    "voices-explicit-request-route-and-timeout": {
      "url": "https://voices.example/custom/cognitiveservices/voices/list",
      "timeoutMs": 12000,
      "auditContext": "azure-speech.voices",
      "init": {
        "method": "GET",
        "headers": {
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech"
        }
      },
      "result": [
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny",
          "locale": "en-US",
          "gender": "Female"
        },
        {
          "id": "fr-FR-DeniseNeural",
          "name": "Denise locale",
          "locale": "fr-FR",
          "gender": "Female"
        }
      ]
    },
    "voices-config-timeout-before-request-and-request-route": {
      "url": "https://request-voices.example/root/cognitiveservices/voices/list",
      "timeoutMs": 60000,
      "auditContext": "azure-speech.voices",
      "init": {
        "method": "GET",
        "headers": {
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech"
        }
      },
      "result": [
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny",
          "locale": "en-US",
          "gender": "Female"
        },
        {
          "id": "fr-FR-DeniseNeural",
          "name": "Denise locale",
          "locale": "fr-FR",
          "gender": "Female"
        }
      ]
    },
    "voices-ordered-tags-personalities-and-duplicates": {
      "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/voices/list",
      "timeoutMs": 23456,
      "auditContext": "azure-speech.voices",
      "init": {
        "method": "GET",
        "headers": {
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech"
        }
      },
      "result": [
        {
          "id": "zh-CN-XiaoxiaoNeural",
          "name": "晓晓",
          "description": " General ,  Assistant ,  Warm ,  Friendly ",
          "locale": "zh-CN",
          "gender": "Female",
          "personalities": [
            " Warm ",
            " Friendly "
          ]
        },
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny local",
          "description": " Cheerful ",
          "locale": "en-US",
          "gender": "Female",
          "personalities": [
            " Cheerful "
          ]
        },
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny duplicate",
          "description": " narration "
        },
        {
          "id": "de-DE-KatjaNeural",
          "name": "Katja",
          "personalities": []
        }
      ]
    },
    "voices-configured-endpoint-route": {
      "url": "https://speech.example/tenant/cognitiveservices/voices/list",
      "timeoutMs": 30000,
      "auditContext": "azure-speech.voices",
      "init": {
        "method": "GET",
        "headers": {
          "Ocp-Apim-Subscription-Key": "fixture-azure-speech"
        }
      },
      "result": [
        {
          "id": "en-US-JennyNeural",
          "name": "Jenny",
          "locale": "en-US",
          "gender": "Female"
        },
        {
          "id": "fr-FR-DeniseNeural",
          "name": "Denise locale",
          "locale": "fr-FR",
          "gender": "Female"
        }
      ]
    }
  }
};
const metadata = {
  "id": "azure-speech",
  "label": "Azure Speech",
  "aliases": [
    "azure"
  ],
  "autoSelectOrder": 30
};
const groups = {config:'configObservations',talkConfig:'talkConfigObservations',talkOverride:'talkOverrideObservations',synthesis:'observations',telephony:'telephonyObservations',voices:'voiceObservations'};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const expectedModules = [
  'extensions/azure-speech/speech-provider.ts',
  'packages/normalization-core/src/string-coerce.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts',
  'src/tts/directive-parser.ts',
  'src/tts/directive-number.ts',
  'src/tts/tts-provider-helpers.ts',
];
test('independent input inventory and exact literal metadata', () => {
  assert.deepEqual(AZURE_SPEECH_CASES,inputs);
  assert.equal(AZURE_SPEECH_PIN,'488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(AZURE_SPEECH_SOURCE,'extensions/azure-speech/speech-provider.ts');
  assert.equal(fixture.referencePin,AZURE_SPEECH_PIN);
  assert.deepEqual(fixture.providerMetadata,metadata);
  assert.equal(fixture.counts.totalObservations,51);
  assert.equal(fixture.counts.httpRequests,29);
  assert.equal(fixture.counts.releases,29);
});
for (const [kind,rows] of Object.entries(inputs)) {
  for (const recipe of rows) {
    test(`${kind}: ${recipe.id}`, () => {
      const observation = fixture[groups[kind]].find(row=>row.id===recipe.id);
      assert.ok(observation,recipe.id);
      assert.deepEqual(observation.input,recipe.input);
      assert.deepEqual(observation.inputAfter,recipe.input);
      const exp=expected[kind][recipe.id];
      if (kind==='synthesis'||kind==='telephony'||kind==='voices') {
        assert.deepEqual(observation.result,exp.result);
        assert.equal(observation.releaseCount,1);
        assert.equal(observation.requests.length,1);
        const request=observation.requests[0];
        assert.equal(request.url,exp.url);
        assert.equal(request.timeoutMs,exp.timeoutMs);
        assert.equal(request.auditContext,exp.auditContext);
        assert.deepEqual(request.init,exp.init);
      } else {
        assert.deepEqual(observation.result,exp);
        assert.equal(observation.requests.length,0);
        assert.equal(observation.releaseCount,0);
      }
    });
  }
}
test('complete original modules pinned with TS erasure only and immutable checkout', () => {
  assert.equal(fixture.checkout.before.verified,true);
  assert.equal(fixture.checkout.after.verified,true);
  assert.equal(fixture.checkout.before.verifiedTrackedFiles,58558);
  assert.deepEqual(fixture.checkout.after,fixture.checkout.before);
  assert.equal(fixture.sourceAudit.length,expectedModules.length);
  assert.equal(fixture.counts.wholeModules,expectedModules.length);
  assert.deepEqual(fixture.sourceAudit.map(row=>row.path).sort(),[...expectedModules].sort());
  for (const row of fixture.sourceAudit) {
    assert.equal(hash(readFileSync(join(sourceRoot,row.path))),row.sourceSha256);
    const pinned=execFileSync('git',['-C',sourceRoot,'show',`${AZURE_SPEECH_PIN}:${row.path}`]);
    assert.equal(hash(pinned),row.sourceSha256);
    assert.equal(row.sourceBytes,pinned.length);
    assert.equal(row.wholeModule,true);
    assert.equal(row.executed,true);
  }
});
test('fresh VM and fresh CLI preserve full fixture JSON',async () => {
  assert.deepEqual(await captureAzureSpeech(sourceRoot),fixture);
  const dir=mkdtempSync(join(tmpdir(),'azure335-oracle-'));
  try {
    const output=join(dir,'capture.json');
    execFileSync(process.execPath,['--experimental-vm-modules','scripts/openclaw/capture-azure-speech.mjs','--source-root',sourceRoot,'--output',output],{timeout:60000,stdio:'pipe'});
    assert.deepEqual(JSON.parse(readFileSync(output,'utf8')),fixture);
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
