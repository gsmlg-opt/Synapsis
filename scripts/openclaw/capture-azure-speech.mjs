// Complete pinned Azure Speech callbacks; successful fixture inputs only.
// Parent-owned Node 24 execution with --experimental-vm-modules; original TS erasure only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const AZURE_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const AZURE_SPEECH_SOURCE = 'extensions/azure-speech/speech-provider.ts';
// Independently authored raw callback inputs and positive synthetic response bytes; no expected maps.
export const AZURE_SPEECH_CASES = {
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

const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const providerHelpers = 'src/tts/tts-provider-helpers.ts';
const sourcePaths = [AZURE_SPEECH_SOURCE, strings, records, numbers,
  directiveParser, directiveNumber, providerHelpers];
const manifestPath = 'extensions/azure-speech/openclaw.plugin.json';
const provenancePaths = [manifestPath, 'extensions/azure-speech/index.ts',
  'extensions/azure-speech/capability-catalog.ts', 'LICENSE'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;

// Wiring-only facades: algorithms remain in complete original TS-erased modules.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    `export { createSpeechDirectiveParser } from '${directiveParser}';\nexport { resolveSpeechProviderApiKey } from '${providerHelpers}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asOptionalRecord, filterStringRecord } from '${records}';\nexport { normalizeOptionalString } from '${strings}';\nexport { asFiniteNumber } from '${numbers}';`,
  '@openclaw/normalization-core/string-coerce': `export * from '${strings}';`,
  '@openclaw/normalization-core/number-coercion': `export * from '${numbers}';`,
};
const unused = 'Linked solely for complete original module evaluation; never invoked by these ordinary recipes.';
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Records explicit dummy value/path and trims strings only. No real secret resolution or credential authority executes.',
  },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'Records cfg/media kind and returns a fixed positive fixture allowance. Original media settings, cap and overflow semantics are unexecuted.',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'Records the synthetic successful response identity and label only. Original status/error behavior is unexecuted.',
    readProviderBinaryResponse: 'Records response identity/label/kind/reader options and returns fresh opaque fixture audio bytes. Original body reader, limits and deadlines are unexecuted.',
    readProviderJsonResponse: 'Records response identity/label and returns fresh positive fixture voice JSON. Original reader and malformed/error behavior are unexecuted.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Records the source-produced URL and supplies an opaque named fixture policy. No hostname or network policy algorithm executes.',
    fetchWithSsrFGuard: 'Records exact source URL, SSML/headers/timeout/audit fields and returns a synthetic 200 response plus counted release. No network or guard implementation executes.',
  },
  'node:fs': { rmSync: unused },
};
const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({ module, exports }));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), AZURE_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', AZURE_SPEECH_PIN])
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
  return { verified: true, commit: AZURE_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${AZURE_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Azure speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class AzureSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.calls = [];
    this.responses = [];
    this.releaseCount = 0;
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetch = () => { throw Error('Ambient fetch is excluded; source must use the named synthetic guard'); };
    this.context = vm.createContext({ Buffer, URL, Uint8Array, fetch: this.fetch, process: { env: {} } },
      { codeGeneration: { strings: false, wasm: false } });
  }
  platformModule(identifier) {
    const called = (name, result, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return result;
    };
    const uninvoked = name => () => { throw Error(`Excluded boundary invoked: ${identifier}#${name}`); };
    const bindings = Object.fromEntries(Object.keys(boundaries[identifier]).map(name => [name, uninvoked(name)]));
    if (identifier === 'openclaw/plugin-sdk/secret-input') {
      bindings.normalizeResolvedSecretInputString = ({ value, path }) =>
        called('normalizeResolvedSecretInputString', typeof value === 'string' ? value.trim() : undefined,
          { path, ...(value === undefined ? {} : { value }) });
    } else if (identifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      bindings.resolveGeneratedMediaMaxBytes = (cfg, kind) =>
        called('resolveGeneratedMediaMaxBytes', 1024 * 1024, { cfg: plain(cfg), kind });
    } else if (identifier === 'openclaw/plugin-sdk/ssrf-runtime') {
      bindings.ssrfPolicyFromHttpBaseUrlAllowedHostname = url =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicy: 'azure-source-url' }, { url });
      bindings.fetchWithSsrFGuard = async params => {
        const request = plain(params);
        this.requests.push({ ...request, headers: plain(params.init.headers),
          ...(params.init.body === undefined ? {} : { bodyText: params.init.body }) });
        const response = { ok: true, status: 200, fixtureResponse: plain(this.recipe.response) };
        this.responses.push(response);
        const requestIndex = this.requests.length - 1;
        called('fetchWithSsrFGuard', undefined, { requestIndex });
        let released = false;
        return { response, release: async () => {
          assert.equal(released, false, 'source release is called once');
          released = true;
          this.releaseCount += 1;
          called('release', undefined, { requestIndex });
        } };
      };
    } else if (identifier === 'openclaw/plugin-sdk/provider-http') {
      const responseFacts = (response, label) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        return { status: response.status, label };
      };
      bindings.assertOkOrThrowProviderError = async (response, label) => {
        called('assertOkOrThrowProviderError', undefined, responseFacts(response, label));
      };
      bindings.readProviderBinaryResponse = async (response, label, kind, options) => {
        const bytes = Buffer.from(response.fixtureResponse.audioBase64, 'base64');
        called('readProviderBinaryResponse', undefined, { ...responseFacts(response, label), kind,
          maxBytes: options.maxBytes, onOverflowSupplied: typeof options.onOverflow === 'function',
          audioBase64: bytes.toString('base64'), audioHex: bytes.toString('hex'), byteLength: bytes.length });
        return bytes;
      };
      bindings.readProviderJsonResponse = async (response, label) => {
        called('readProviderJsonResponse', undefined, responseFacts(response, label));
        return plain(response.fixtureResponse.json);
      };
    }
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
    const source = this.module(AZURE_SPEECH_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildAzureSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      const callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      if (observationKind === 'config') return { metadata, callbacks, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, callbacks, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverride') return { metadata, callbacks, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, callbacks, result: await provider.listVoices(speechInput) };
      const synthesisRequest = JSON.parse(JSON.stringify(speechInput));
      const buffered = observationKind === 'telephony'
        ? await provider.synthesizeTelephony(speechInput) : await provider.synthesize(speechInput);
      const { audioBuffer, ...resultMetadata } = buffered;
      return { metadata, callbacks, result: { audioBase64: audioBuffer.toString('base64'), ...resultMetadata },
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(speechInput)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    if (['synthesis', 'telephony', 'voices'].includes(this.kind)) {
      assert.equal(this.requests.length, 1, 'ordinary source callback makes one successful request');
      assert.equal(this.releaseCount, 1, 'ordinary source callback releases exactly once');
    } else {
      assert.equal(this.requests.length, 0, 'pure source callback makes no request');
      assert.equal(this.releaseCount, 0, 'pure source callback has no response to release');
    }
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      result: plain(execution.result), providerMetadata: plain(execution.metadata),
      providerCallbacks: plain(execution.callbacks),
      ...(execution.synthesisRequest ? { synthesisRequest: plain(execution.synthesisRequest),
        synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      ...(this.recipe.response ? { response: plain(this.recipe.response) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls };
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureAzureSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${AZURE_SPEECH_PIN}:${path}`], {
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
    return { path, gitBlob: git(root, ['rev-parse', `${AZURE_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const dataAudit = provenancePaths.map(path => {
    const bytes = readOriginal(path);
    return { path, gitBlob: git(root, ['rev-parse', `${AZURE_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length,
      usage: path === 'LICENSE' ? 'Complete original license provenance.' : 'Complete original plugin data/registration/catalog provenance; not evaluated or registered.',
      evaluated: false };
  });
  const groups = {};
  for (const [kind, recipes] of Object.entries(AZURE_SPEECH_CASES)) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new AzureSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  assert.ok(runs.length > 0, 'independently authored recipes are embedded before execution');
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  const groupCounts = Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length]));
  return {
    schemaVersion: 1, referencePin: AZURE_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-azure-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit, dataAudit,
    pluginManifest: JSON.parse(readFileSync(join(root, manifestPath))),
    license: { path: 'LICENSE', text: readFileSync(join(root, 'LICENSE')).toString() },
    platformBoundaries,
    globalBoundaries: {
      process: 'Isolated VM process.env={} only. Original route/key code can read these absent fields as provenance; no ambient env values, credential fallback or configured predicate is qualified.',
      fetch: 'Throwing ambient binding; only the explicitly named synthetic successful guarded-fetch facade is invoked.',
      Buffer: 'Node native Buffer carries synthetic opaque fixture audio unchanged; this does not establish a real media format or codec.',
      clock: 'Successful source callbacks pass timeout values to a synthetic boundary; no actual timer, timeout, retry, cancellation or recovery semantics are qualified.',
    },
    providerMetadata: runs[0].observation.providerMetadata,
    providerCallbacks: runs[0].observation.providerCallbacks,
    counts: { ...groupCounts, totalObservations: runs.length,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0),
      wholeModules: evaluated.size, trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverride.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    telephonyObservations: groups.telephony.map(run => run.observation),
    voiceObservations: groups.voices.map(run => run.observation),
    limits: [
      'All 58558 pinned tracked blobs/modes are verified before and after; complete original executable modules match pinned Git bytes before TypeScript erasure only.',
      'Whole-module evaluation is not all-branch execution. Original factory, metadata, config/Talk/overrides, full SSML construction, buffered synthesis, telephony and ordered voice catalog callbacks execute ordinary recipes.',
      'The actual normalization modules preserve source nullish-before-trim aliases, finite-number treatment, explicit route precedence/inheritance and config-first timeout selection.',
      'Source formats retain original spelling and classify MP3/Ogg/WebM/WAV/PCM/AMR/custom extension metadata; generic telephony target is distinct from the forced raw8000mulaw dedicated callback. No actual media codec is involved.',
      'Original directive parser construction executes only; directive policy dispatch and isConfigured/isConfiguredAsync are never invoked. Source env reads see an empty isolated object and remain provenance only.',
      'Original first-nonblank explicit dummy-key helper and source request headers execute as provenance, not authentication/credential/security qualification. Real secret resolution, guarded HTTP and response/body readers are named positive synthetic facades.',
      'Voices preserve source order, duplicate IDs, normalized public fields and untrimmed accepted tag strings. Deprecated/disabled/malformed filtering branches are not qualified by the permitted positive inputs.',
      'Manifest, index, capability catalog and license are complete source provenance only; plugin activation/registration is not executed.',
      'No Azure SDK, retry runner, preparation stage, streaming or transcoder exists in this provider. No real HTTP, supplier, codec, playback, channel routing or host production installation executes.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
  };
}
export async function writeAzureSpeechCapture(root, output) {
  const capture = await captureAzureSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-azure-speech.mjs --source-root DIR [--output FILE]');
    if (args[index] === '--source-root') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) return writeAzureSpeechCapture(root, output);
  const capture = await captureAzureSpeech(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
