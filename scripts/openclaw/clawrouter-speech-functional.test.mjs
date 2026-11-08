// Independent ordinary ClawRouter speech oracle, authored from pinned source before capture execution.
// Opaque fixture8 bytes establish byte passthrough only. Synthetic successful HTTP/status/binary/media
// and dummy resolveApiKeyForProvider boundaries establish no provider, HTTP, codec, credential or policy behavior.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { captureClawRouterSpeech, CLAWROUTER_SPEECH_CASES, CLAWROUTER_SPEECH_PIN,
  CLAWROUTER_SPEECH_SOURCE } from './capture-clawrouter-speech.mjs';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/clawrouter-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const sourceRoot = '/tmp/openclaw-488631c';
// Expanded independent literals: neither inputs nor expected results are imported from capture output.
// Custom model labels appear only in pure configuration parsing; synthesis uses only openai/tts-1.
const inputs = {
  "config": [
    {
      "id": "config-empty-defaults",
      "input": {
        "rawConfig": {}
      }
    },
    {
      "id": "config-legacy-object-ignored",
      "input": {
        "rawConfig": {
          "clawrouter": {
            "model": "openai/tts-1",
            "voice": "nova",
            "speed": 1.4,
            "responseFormat": "wav",
            "baseUrl": "https://legacy.example/api"
          },
          "providers": {
            "other": {
              "voice": "echo"
            }
          }
        }
      }
    },
    {
      "id": "config-nested-primary-and-alias-precedence",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "baseUrl": " https://Tenant.Example/prefix/v1/// ",
              "model": " config-primary ",
              "modelId": "config-alias",
              "speakerVoice": " echo ",
              "speakerVoiceId": "fable",
              "voice": "onyx",
              "voiceId": "nova",
              "speed": 1.2,
              "responseFormat": " WaV "
            }
          }
        }
      }
    },
    {
      "id": "config-null-model-to-modelId",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "model": null,
              "modelId": " config-model-id ",
              "speakerVoice": null,
              "speakerVoiceId": " fable ",
              "voice": "onyx",
              "voiceId": "nova",
              "responseFormat": " OPUS "
            }
          }
        }
      }
    },
    {
      "id": "config-blank-model-masks-modelId",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "model": " \t ",
              "modelId": "config-masked-alias",
              "speakerVoice": " ",
              "speakerVoiceId": " ",
              "voice": " onyx ",
              "voiceId": "nova",
              "responseFormat": " AAC "
            }
          }
        }
      }
    },
    {
      "id": "config-voiceId-last-nonblank-alias",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "speakerVoice": " ",
              "speakerVoiceId": null,
              "voice": "\t",
              "voiceId": " nova ",
              "responseFormat": " FLAC ",
              "speed": 1.6
            }
          }
        }
      }
    },
    {
      "id": "config-shimmer-pcm",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "voice": " shimmer ",
              "responseFormat": " PCM ",
              "speed": 0.9
            }
          }
        }
      }
    },
    {
      "id": "config-blank-optionals-default",
      "input": {
        "rawConfig": {
          "providers": {
            "clawrouter": {
              "baseUrl": " ",
              "model": " ",
              "voice": " ",
              "responseFormat": " "
            }
          }
        }
      }
    },
    {
      "id": "config-nested-wins-legacy",
      "input": {
        "rawConfig": {
          "clawrouter": {
            "voice": "shimmer",
            "responseFormat": "wav"
          },
          "providers": {
            "clawrouter": {
              "voiceId": "echo",
              "responseFormat": " MP3 "
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
        "baseTtsConfig": {},
        "talkProviderConfig": {}
      }
    },
    {
      "id": "talk-base-inherited",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "baseUrl": " https://base.example/speech ",
              "model": "openai/tts-1",
              "voice": "fable",
              "speed": 1.1,
              "responseFormat": " OPUS "
            }
          }
        },
        "talkProviderConfig": {}
      }
    },
    {
      "id": "talk-complete-overrides",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "baseUrl": "https://base.example",
              "model": "openai/tts-1",
              "voice": "echo",
              "speed": 1.1,
              "responseFormat": "mp3"
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk.example/prefix/v1/// ",
          "modelId": " openai/tts-1 ",
          "speakerVoice": " nova ",
          "speakerVoiceId": "onyx",
          "voice": "fable",
          "voiceId": "shimmer",
          "speed": 1.8,
          "responseFormat": " WaV "
        }
      }
    },
    {
      "id": "talk-model-field-does-not-select-model",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "model": " base-model ",
              "voice": "echo"
            }
          }
        },
        "talkProviderConfig": {
          "model": "talk-model",
          "voiceId": " shimmer "
        }
      }
    },
    {
      "id": "talk-null-modelId-inherits-base",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "modelId": " base-model ",
              "voice": "fable"
            }
          }
        },
        "talkProviderConfig": {
          "modelId": null,
          "speakerVoice": null,
          "speakerVoiceId": " ",
          "voice": null,
          "voiceId": " "
        }
      }
    },
    {
      "id": "talk-blank-modelId-uses-default",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "model": "base-model",
              "voice": "onyx",
              "responseFormat": "wav",
              "baseUrl": "https://base.example"
            }
          }
        },
        "talkProviderConfig": {
          "modelId": " ",
          "baseUrl": " ",
          "responseFormat": " "
        }
      }
    },
    {
      "id": "talk-speakerVoiceId-before-voice",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "clawrouter": {
              "voice": "alloy"
            }
          }
        },
        "talkProviderConfig": {
          "speakerVoice": " ",
          "speakerVoiceId": " echo ",
          "voice": "nova",
          "voiceId": "shimmer"
        }
      }
    },
    {
      "id": "talk-voice-before-voiceId",
      "input": {
        "baseTtsConfig": {},
        "talkProviderConfig": {
          "voice": " onyx ",
          "voiceId": "nova",
          "speed": 1.25,
          "responseFormat": " AAC "
        }
      }
    }
  ],
  "talkOverrides": [
    {
      "id": "talk-overrides-empty",
      "input": {
        "params": {}
      }
    },
    {
      "id": "talk-overrides-literal-fields",
      "input": {
        "params": {
          "modelId": " openai/tts-1 ",
          "voiceId": " nova ",
          "speed": 1.35,
          "model": "ignored",
          "voice": "echo",
          "responseFormat": "wav"
        }
      }
    },
    {
      "id": "talk-overrides-nullish-preserved",
      "input": {
        "params": {
          "modelId": null,
          "voiceId": null
        }
      }
    },
    {
      "id": "talk-overrides-blank-preserved",
      "input": {
        "params": {
          "modelId": " ",
          "voiceId": " "
        }
      }
    }
  ],
  "synthesis": [
    {
      "id": "default-audio-file",
      "input": {
        "cfg": {},
        "text": "Ordinary source speech.",
        "providerConfig": {},
        "target": "audio-file",
        "timeoutMs": 21000
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "default-voice-note",
      "input": {
        "cfg": {},
        "text": "Ordinary source speech.",
        "providerConfig": {},
        "target": "voice-note",
        "timeoutMs": 21001.75
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-mp3-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " MP3 ",
          "voice": "alloy",
          "speed": 0.8
        },
        "target": "audio-file",
        "timeoutMs": 22002
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-mp3-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " MP3 ",
          "voice": "alloy",
          "speed": 0.8
        },
        "target": "voice-note",
        "timeoutMs": 22003
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-opus-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " OpUs ",
          "voice": "echo",
          "speed": 1.1
        },
        "target": "audio-file",
        "timeoutMs": 22004
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-opus-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " OpUs ",
          "voice": "echo",
          "speed": 1.1
        },
        "target": "voice-note",
        "timeoutMs": 22005
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-aac-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " AAC ",
          "voice": "fable",
          "speed": 1.4
        },
        "target": "audio-file",
        "timeoutMs": 22006
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-aac-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " AAC ",
          "voice": "fable",
          "speed": 1.4
        },
        "target": "voice-note",
        "timeoutMs": 22007
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-flac-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " fLaC ",
          "voice": "onyx",
          "speed": 1.7
        },
        "target": "audio-file",
        "timeoutMs": 22008
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-flac-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " fLaC ",
          "voice": "onyx",
          "speed": 1.7
        },
        "target": "voice-note",
        "timeoutMs": 22009
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-wav-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " WAV ",
          "voice": "nova",
          "speed": 2.2
        },
        "target": "audio-file",
        "timeoutMs": 22010
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-wav-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " WAV ",
          "voice": "nova",
          "speed": 2.2
        },
        "target": "voice-note",
        "timeoutMs": 22011
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-pcm-audio-file",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " PcM ",
          "voice": "shimmer",
          "speed": 3.2
        },
        "target": "audio-file",
        "timeoutMs": 22012
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "format-pcm-voice-note",
      "input": {
        "cfg": {},
        "text": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
        "providerConfig": {
          "responseFormat": " PcM ",
          "voice": "shimmer",
          "speed": 3.2
        },
        "target": "voice-note",
        "timeoutMs": 22013
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "override-primary-model-and-speakerVoice",
      "input": {
        "cfg": {},
        "text": "Aliases preserve speech.",
        "providerConfig": {
          "modelId": " openai/tts-1 ",
          "voice": "alloy",
          "speed": 0.8,
          "responseFormat": "wav"
        },
        "providerOverrides": {
          "model": " openai/tts-1 ",
          "modelId": "openai/tts-1",
          "speakerVoice": " echo ",
          "speakerVoiceId": "fable",
          "voice": "onyx",
          "voiceId": "nova",
          "speed": 1.6,
          "responseFormat": "opus",
          "baseUrl": "https://ignored.example"
        },
        "target": "voice-note",
        "timeoutMs": 23001
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "override-null-model-speakerVoiceId",
      "input": {
        "cfg": {},
        "text": "Alias two.",
        "providerConfig": {
          "model": "openai/tts-1",
          "voice": "alloy",
          "speed": 1.2
        },
        "providerOverrides": {
          "model": null,
          "modelId": " openai/tts-1 ",
          "speakerVoice": " ",
          "speakerVoiceId": " fable ",
          "voice": "onyx",
          "voiceId": "nova"
        },
        "target": "audio-file",
        "timeoutMs": 23002
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "override-blank-model-voice-before-voiceId",
      "input": {
        "cfg": {},
        "text": "Alias three.",
        "providerConfig": {
          "modelId": "openai/tts-1",
          "voice": "alloy",
          "speed": 1.3
        },
        "providerOverrides": {
          "model": " ",
          "modelId": "openai/tts-1",
          "speakerVoice": null,
          "speakerVoiceId": " ",
          "voice": " onyx ",
          "voiceId": "nova",
          "speed": null
        },
        "target": "audio-file",
        "timeoutMs": 23003
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "override-voiceId",
      "input": {
        "cfg": {},
        "text": "Alias four.",
        "providerConfig": {
          "voice": "echo"
        },
        "providerOverrides": {
          "speakerVoice": " ",
          "speakerVoiceId": null,
          "voice": " ",
          "voiceId": " nova ",
          "speed": 1.45
        },
        "target": "voice-note",
        "timeoutMs": 23004
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "override-nullish-and-blank-inherit",
      "input": {
        "cfg": {},
        "text": "Inherited voice.",
        "providerConfig": {
          "voice": "shimmer",
          "speed": 1.55,
          "responseFormat": "flac"
        },
        "providerOverrides": {
          "model": null,
          "modelId": null,
          "speakerVoice": null,
          "speakerVoiceId": " ",
          "voice": null,
          "voiceId": " ",
          "speed": null
        },
        "target": "audio-file",
        "timeoutMs": 23005
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-canonical-v1",
      "input": {
        "cfg": {},
        "text": "Canonical URL.",
        "providerConfig": {
          "baseUrl": " https://ClawRouter.Example/v1/// "
        },
        "target": "audio-file",
        "timeoutMs": 24001
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-root",
      "input": {
        "cfg": {},
        "text": "Root URL.",
        "providerConfig": {
          "baseUrl": " https://Root.Example//// "
        },
        "target": "audio-file",
        "timeoutMs": 24002
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-custom-prefix",
      "input": {
        "cfg": {},
        "text": "Prefix URL.",
        "providerConfig": {
          "baseUrl": "https://Prefix.Example/tenant/api///"
        },
        "target": "voice-note",
        "timeoutMs": 24003
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-custom-prefix-v1",
      "input": {
        "cfg": {},
        "text": "Prefix canonical URL.",
        "providerConfig": {
          "baseUrl": "https://Prefix.Example/tenant/api/v1///"
        },
        "target": "audio-file",
        "timeoutMs": 24004
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-case-sensitive-uppercase-V1",
      "input": {
        "cfg": {},
        "text": "Case-sensitive URL.",
        "providerConfig": {
          "baseUrl": "https://Case.Example/V1///"
        },
        "target": "audio-file",
        "timeoutMs": 24005
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-only-terminal-v1-removed",
      "input": {
        "cfg": {},
        "text": "One suffix URL.",
        "providerConfig": {
          "baseUrl": "https://Repeat.Example/v1/v1/"
        },
        "target": "audio-file",
        "timeoutMs": 24006
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-cfg-model-base-ordinary",
      "input": {
        "cfg": {
          "models": {
            "providers": {
              "clawrouter": {
                "baseUrl": " https://Configured.Example/service/v1/// "
              }
            }
          }
        },
        "text": "Configured route.",
        "providerConfig": {
          "baseUrl": " "
        },
        "target": "voice-note",
        "timeoutMs": 24007
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "url-provider-config-precedence",
      "input": {
        "cfg": {
          "models": {
            "providers": {
              "clawrouter": {
                "baseUrl": "https://ignored.example/base"
              }
            }
          }
        },
        "text": "Selected speech route.",
        "providerConfig": {
          "baseUrl": "https://Selected.Example/speech/v1/"
        },
        "target": "audio-file",
        "timeoutMs": 24008
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    }
  ],
  "telephony": [
    {
      "id": "telephony-default-forces-pcm",
      "input": {
        "cfg": {},
        "text": "Telephone speech.",
        "providerConfig": {},
        "target": "voice-note",
        "timeoutMs": 25001
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "telephony-overrides-and-pcm",
      "input": {
        "cfg": {},
        "text": "  Téléphone，您好 📞\n  ",
        "providerConfig": {
          "responseFormat": "opus",
          "voice": "echo",
          "speed": 1.1,
          "baseUrl": " https://Phone.Example/tenant/v1/// "
        },
        "providerOverrides": {
          "modelId": " openai/tts-1 ",
          "voiceId": " shimmer ",
          "speed": 1.65
        },
        "target": "audio-file",
        "timeoutMs": 25002.5
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    },
    {
      "id": "telephony-explicit-wav-still-pcm",
      "input": {
        "cfg": {},
        "text": "PCM output metadata.",
        "providerConfig": {
          "responseFormat": " WAV ",
          "speakerVoiceId": "nova",
          "speed": 2.1
        },
        "target": "voice-note",
        "timeoutMs": 25003
      },
      "response": {
        "audioBase64": "Zml4dHVyZTg="
      }
    }
  ],
  "voices": [
    {
      "id": "voices-six-source-order",
      "input": {}
    }
  ]
};
const expected = {
  "config": {
    "config-empty-defaults": {
      "model": "openai/tts-1",
      "voice": "alloy"
    },
    "config-legacy-object-ignored": {
      "model": "openai/tts-1",
      "voice": "alloy"
    },
    "config-nested-primary-and-alias-precedence": {
      "baseUrl": "https://Tenant.Example/prefix/v1///",
      "model": "config-primary",
      "voice": "echo",
      "speed": 1.2,
      "responseFormat": "wav"
    },
    "config-null-model-to-modelId": {
      "model": "config-model-id",
      "voice": "fable",
      "responseFormat": "opus"
    },
    "config-blank-model-masks-modelId": {
      "model": "openai/tts-1",
      "voice": "onyx",
      "responseFormat": "aac"
    },
    "config-voiceId-last-nonblank-alias": {
      "model": "openai/tts-1",
      "voice": "nova",
      "speed": 1.6,
      "responseFormat": "flac"
    },
    "config-shimmer-pcm": {
      "model": "openai/tts-1",
      "voice": "shimmer",
      "speed": 0.9,
      "responseFormat": "pcm"
    },
    "config-blank-optionals-default": {
      "model": "openai/tts-1",
      "voice": "alloy"
    },
    "config-nested-wins-legacy": {
      "model": "openai/tts-1",
      "voice": "echo",
      "responseFormat": "mp3"
    }
  },
  "talkConfig": {
    "talk-defaults": {
      "model": "openai/tts-1",
      "voice": "alloy"
    },
    "talk-base-inherited": {
      "baseUrl": "https://base.example/speech",
      "model": "openai/tts-1",
      "voice": "fable",
      "speed": 1.1,
      "responseFormat": "opus"
    },
    "talk-complete-overrides": {
      "baseUrl": "https://talk.example/prefix/v1///",
      "model": "openai/tts-1",
      "voice": "nova",
      "speed": 1.8,
      "responseFormat": "wav"
    },
    "talk-model-field-does-not-select-model": {
      "model": "base-model",
      "voice": "shimmer"
    },
    "talk-null-modelId-inherits-base": {
      "model": "base-model",
      "voice": "fable"
    },
    "talk-blank-modelId-uses-default": {
      "model": "openai/tts-1",
      "voice": "onyx"
    },
    "talk-speakerVoiceId-before-voice": {
      "model": "openai/tts-1",
      "voice": "echo"
    },
    "talk-voice-before-voiceId": {
      "model": "openai/tts-1",
      "voice": "onyx",
      "speed": 1.25,
      "responseFormat": "aac"
    }
  },
  "talkOverrides": {
    "talk-overrides-empty": {},
    "talk-overrides-literal-fields": {
      "model": " openai/tts-1 ",
      "voice": " nova ",
      "speed": 1.35
    },
    "talk-overrides-nullish-preserved": {
      "model": null,
      "voice": null
    },
    "talk-overrides-blank-preserved": {
      "model": " ",
      "voice": " "
    }
  },
  "synthesis": {
    "default-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Ordinary source speech.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 21000
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "default-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Ordinary source speech.",
          "voice": "alloy",
          "response_format": "opus"
        },
        "timeoutMs": 21001.75
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "format-mp3-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "alloy",
          "response_format": "mp3",
          "speed": 0.8
        },
        "timeoutMs": 22002
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "format-mp3-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "alloy",
          "response_format": "mp3",
          "speed": 0.8
        },
        "timeoutMs": 22003
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "format-opus-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "echo",
          "response_format": "opus",
          "speed": 1.1
        },
        "timeoutMs": 22004
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "format-opus-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "echo",
          "response_format": "opus",
          "speed": 1.1
        },
        "timeoutMs": 22005
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "format-aac-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "fable",
          "response_format": "aac",
          "speed": 1.4
        },
        "timeoutMs": 22006
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "aac",
        "fileExtension": ".aac",
        "voiceCompatible": false
      }
    },
    "format-aac-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "fable",
          "response_format": "aac",
          "speed": 1.4
        },
        "timeoutMs": 22007
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "aac",
        "fileExtension": ".aac",
        "voiceCompatible": false
      }
    },
    "format-flac-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "onyx",
          "response_format": "flac",
          "speed": 1.7
        },
        "timeoutMs": 22008
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "flac",
        "fileExtension": ".flac",
        "voiceCompatible": false
      }
    },
    "format-flac-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "onyx",
          "response_format": "flac",
          "speed": 1.7
        },
        "timeoutMs": 22009
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "flac",
        "fileExtension": ".flac",
        "voiceCompatible": false
      }
    },
    "format-wav-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "nova",
          "response_format": "wav",
          "speed": 2.2
        },
        "timeoutMs": 22010
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "format-wav-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "nova",
          "response_format": "wav",
          "speed": 2.2
        },
        "timeoutMs": 22011
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "format-pcm-audio-file": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "shimmer",
          "response_format": "pcm",
          "speed": 3.2
        },
        "timeoutMs": 22012
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false
      }
    },
    "format-pcm-voice-note": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Héllo，世界 👩🏽‍🚀\nCafé\t終。  ",
          "voice": "shimmer",
          "response_format": "pcm",
          "speed": 3.2
        },
        "timeoutMs": 22013
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false
      }
    },
    "override-primary-model-and-speakerVoice": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Aliases preserve speech.",
          "voice": "echo",
          "response_format": "wav",
          "speed": 1.6
        },
        "timeoutMs": 23001
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      }
    },
    "override-null-model-speakerVoiceId": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Alias two.",
          "voice": "fable",
          "response_format": "mp3",
          "speed": 1.2
        },
        "timeoutMs": 23002
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "override-blank-model-voice-before-voiceId": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Alias three.",
          "voice": "onyx",
          "response_format": "mp3",
          "speed": 1.3
        },
        "timeoutMs": 23003
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "override-voiceId": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Alias four.",
          "voice": "nova",
          "response_format": "opus",
          "speed": 1.45
        },
        "timeoutMs": 23004
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "override-nullish-and-blank-inherit": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Inherited voice.",
          "voice": "shimmer",
          "response_format": "flac",
          "speed": 1.55
        },
        "timeoutMs": 23005
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "flac",
        "fileExtension": ".flac",
        "voiceCompatible": false
      }
    },
    "url-canonical-v1": {
      "request": {
        "url": "https://ClawRouter.Example/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Canonical URL.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24001
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "url-root": {
      "request": {
        "url": "https://Root.Example/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Root URL.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24002
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "url-custom-prefix": {
      "request": {
        "url": "https://Prefix.Example/tenant/api/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Prefix URL.",
          "voice": "alloy",
          "response_format": "opus"
        },
        "timeoutMs": 24003
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "url-custom-prefix-v1": {
      "request": {
        "url": "https://Prefix.Example/tenant/api/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Prefix canonical URL.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24004
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "url-case-sensitive-uppercase-V1": {
      "request": {
        "url": "https://Case.Example/V1/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Case-sensitive URL.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24005
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "url-only-terminal-v1-removed": {
      "request": {
        "url": "https://Repeat.Example/v1/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "One suffix URL.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24006
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    },
    "url-cfg-model-base-ordinary": {
      "request": {
        "url": "https://Configured.Example/service/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Configured route.",
          "voice": "alloy",
          "response_format": "opus"
        },
        "timeoutMs": 24007
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      }
    },
    "url-provider-config-precedence": {
      "request": {
        "url": "https://Selected.Example/speech/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Selected speech route.",
          "voice": "alloy",
          "response_format": "mp3"
        },
        "timeoutMs": 24008
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "mp3",
        "fileExtension": ".mp3",
        "voiceCompatible": false
      }
    }
  },
  "telephony": {
    "telephony-default-forces-pcm": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "Telephone speech.",
          "voice": "alloy",
          "response_format": "pcm"
        },
        "timeoutMs": 25001
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false,
        "sampleRate": 24000
      }
    },
    "telephony-overrides-and-pcm": {
      "request": {
        "url": "https://Phone.Example/tenant/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "  Téléphone，您好 📞\n  ",
          "voice": "shimmer",
          "response_format": "pcm",
          "speed": 1.65
        },
        "timeoutMs": 25002.5
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false,
        "sampleRate": 24000
      }
    },
    "telephony-explicit-wav-still-pcm": {
      "request": {
        "url": "https://clawrouter.openclaw.ai/v1/audio/speech",
        "method": "POST",
        "body": {
          "model": "openai/tts-1",
          "input": "PCM output metadata.",
          "voice": "nova",
          "response_format": "pcm",
          "speed": 2.1
        },
        "timeoutMs": 25003
      },
      "result": {
        "audioBase64": "Zml4dHVyZTg=",
        "outputFormat": "pcm",
        "fileExtension": ".pcm",
        "voiceCompatible": false,
        "sampleRate": 24000
      }
    }
  },
  "voices": {
    "voices-six-source-order": [
      {
        "id": "alloy",
        "name": "alloy"
      },
      {
        "id": "echo",
        "name": "echo"
      },
      {
        "id": "fable",
        "name": "fable"
      },
      {
        "id": "onyx",
        "name": "onyx"
      },
      {
        "id": "nova",
        "name": "nova"
      },
      {
        "id": "shimmer",
        "name": "shimmer"
      }
    ]
  }
};
const metadata = {
  id: 'clawrouter', label: 'ClawRouter', defaultModel: 'openai/tts-1',
  models: ['openai/tts-1'], voices: ['alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer'],
};
const callbacks = ['resolveConfig', 'parseDirectiveToken', 'resolveTalkConfig', 'resolveTalkOverrides',
  'listVoices', 'isConfigured', 'isConfiguredAsync', 'synthesize', 'synthesizeTelephony'];
const groups = {
  config: 'configObservations', talkConfig: 'talkConfigObservations',
  talkOverrides: 'talkOverrideObservations', synthesis: 'observations',
  telephony: 'telephonyObservations', voices: 'voiceObservations',
};
const groupCounts = { config: 9, talkConfig: 8, talkOverrides: 4, synthesis: 27, telephony: 3, voices: 1 };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const moduleHashes = {
  'extensions/clawrouter/speech-provider.ts': '70a7a0c8a7c955eb32419c9af176eb3897f068a030f5a506d9a23092e54e3ef3',
  'extensions/clawrouter/base-url.ts': '5f08843cba520b9354bebc1ccba8a01fee956289e54624d54a1fb83e757549d7',
  'src/tts/directive-parser.ts': '5f629cc79bf82a2783885fbf97e87d87045c01b852298ba9e781c5b996c48329',
  'src/tts/directive-number.ts': '9d87677afe48ecc851ca209efdb820ef3c191b642a5e9c4f8b483cef57aaed4a',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'packages/normalization-core/src/record-coerce.ts': '541c179840c2cad4edc5c8103f77cc7f8c6b1ee5ec3e52c7c9fe097b18917f1c',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
};
const requestFacts = request => ({
  url: request.url, method: request.init.method, body: request.init.body, timeoutMs: request.timeoutMs,
});

test('independent raw recipes, factory metadata and exact ordinary inventory', () => {
  assert.deepEqual(CLAWROUTER_SPEECH_CASES, inputs);
  assert.equal(CLAWROUTER_SPEECH_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(CLAWROUTER_SPEECH_SOURCE, 'extensions/clawrouter/speech-provider.ts');
  assert.equal(fixture.referencePin, CLAWROUTER_SPEECH_PIN);
  assert.deepEqual(fixture.providerMetadata, metadata);
  assert.deepEqual(fixture.providerCallbacks, callbacks);
  for (const [kind, field] of Object.entries(groups)) {
    assert.equal(inputs[kind].length, groupCounts[kind]);
    assert.equal(fixture.counts[kind], groupCounts[kind]);
    assert.deepEqual(fixture[field].map(row => row.id), inputs[kind].map(row => row.id));
  }
  assert.equal(fixture.counts.totalObservations, 52);
  assert.equal(fixture.counts.httpRequests, 30);
  assert.equal(fixture.counts.releases, 30);
});
for (const [kind, recipes] of Object.entries(inputs)) {
  for (const recipe of recipes) {
    test(`${kind}: ${recipe.id}`, () => {
      const observation = fixture[groups[kind]].find(row => row.id === recipe.id);
      assert.ok(observation, recipe.id);
      assert.deepEqual(observation.input, recipe.input);
      assert.deepEqual(observation.inputAfter, recipe.input);
      assert.deepEqual(observation.providerMetadata, metadata);
      assert.deepEqual(observation.providerCallbacks, callbacks);
      const literal = expected[kind][recipe.id];
      if (kind === 'synthesis' || kind === 'telephony') {
        assert.deepEqual(observation.synthesisRequest, recipe.input);
        assert.deepEqual(observation.synthesisRequestAfter, recipe.input);
        assert.deepEqual(observation.response, recipe.response);
        assert.deepEqual(observation.result, literal.result);
        // Header/auth/policy fields are deliberately outside the qualification projection.
        assert.deepEqual(observation.requests.map(requestFacts), [literal.request]);
        assert.equal(observation.releaseCount, 1);
      } else {
        assert.deepEqual(observation.result, literal);
        assert.deepEqual(observation.requests, []);
        assert.equal(observation.releaseCount, 0);
      }
    });
  }
}
test('all seven complete original runtime modules match independent hashes and fixed checkout', () => {
  assert.equal(fixture.checkout.before.verified, true);
  assert.equal(fixture.checkout.after.verified, true);
  assert.equal(fixture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(fixture.checkout.after.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.checkout.after, fixture.checkout.before);
  assert.equal(fixture.sourceAudit.length, 7);
  assert.equal(fixture.counts.wholeModules, 7);
  assert.equal(fixture.counts.trackedFilesBefore, 58558);
  assert.equal(fixture.counts.trackedFilesAfter, 58558);
  assert.deepEqual(fixture.sourceAudit.map(row => row.path).sort(), Object.keys(moduleHashes).sort());
  for (const row of fixture.sourceAudit) {
    assert.equal(row.sourceSha256, moduleHashes[row.path]);
    assert.equal(hash(readFileSync(join(sourceRoot, row.path))), moduleHashes[row.path]);
    const pinned = execFileSync('git', ['-C', sourceRoot, 'show', `${CLAWROUTER_SPEECH_PIN}:${row.path}`],
      { timeout: 30000 });
    assert.equal(hash(pinned), moduleHashes[row.path]);
    assert.equal(row.sourceBytes, pinned.length);
    assert.equal(row.wholeModule, true);
    assert.equal(row.executed, true);
  }
});
test('fresh whole-module capture and fresh CLI reproduce the entire fixture JSON', async () => {
  // Whole-JSON equality checks deterministic capture provenance too; it does not qualify the
  // behavior represented by synthetic boundary records or incidental auth/header/policy fields.
  assert.deepEqual(await captureClawRouterSpeech(sourceRoot), fixture);
  const directory = mkdtempSync(join(tmpdir(), 'clawrouter339-oracle-'));
  try {
    const output = join(directory, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules', 'scripts/openclaw/capture-clawrouter-speech.mjs',
      '--source-root', sourceRoot, '--output', output], { timeout: 60000, stdio: 'pipe' });
    assert.deepEqual(JSON.parse(readFileSync(output, 'utf8')), fixture);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

