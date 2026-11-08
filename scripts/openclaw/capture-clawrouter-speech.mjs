// Complete pinned ClawRouter Speech callbacks; successful fixture inputs only.
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

export const CLAWROUTER_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const CLAWROUTER_SPEECH_SOURCE = 'extensions/clawrouter/speech-provider.ts';
// Independently authored raw callback inputs only; expected observations are never read.
export const CLAWROUTER_SPEECH_CASES = {
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

const baseUrl = 'extensions/clawrouter/base-url.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const sourcePaths = [CLAWROUTER_SPEECH_SOURCE, baseUrl, strings, records, numbers,
  directiveParser, directiveNumber];
const manifestPath = 'extensions/clawrouter/openclaw.plugin.json';
const provenancePaths = [manifestPath, 'extensions/clawrouter/index.ts',
  'extensions/clawrouter/capability-catalog.ts', 'LICENSE'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;
const lineRange = bytes => ({ startLine: 1,
  endLine: bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0) });

// Wiring-only facades; normalization and parser construction remain original whole modules.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    `export { createSpeechDirectiveParser } from '${directiveParser}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asOptionalRecord } from '${records}';\nexport { normalizeOptionalString } from '${strings}';`,
  '@openclaw/normalization-core/number-coercion': `export * from '${numbers}';`,
};
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Records input/path and trims explicit dummy strings only. No real secret resolution or credential authority executes; ordinary inputs carry no credentials.',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'Named synthetic ordinary-success status facade records response identity/label/options only. Original status/error behavior is unexecuted.',
    readProviderBinaryResponse: 'Named synthetic ordinary-success body facade records response identity/label/kind/options and returns eight opaque recipe bytes. Original body reader, limits and deadlines are unexecuted.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Records source-produced base URL and supplies an opaque synthetic policy. No hostname, TLS or network-policy algorithm executes; fields are provenance only.',
  },
  'openclaw/plugin-sdk/media-generation-runtime': {
    resolveGeneratedMediaMaxBytes: 'Named synthetic ordinary-success media-cap facade records cfg/kind and returns a fixed non-boundary fixture cap. No configuration, cap, budget or overflow semantics are qualified.',
  },
};
const contextBoundaries = {
  resolveApiKeyForProvider: 'Named positive dummy facade returns a fixed fixture key. Source arguments/header construction are provenance only; profiles, stores, environment fallback, credential selection and authentication are unqualified.',
  fetchWithSsrFGuard: 'Named synthetic ordinary-success context facade records exact source request/body/timeout and returns a synthetic successful response containing eight opaque bytes plus counted release. No real network or guard executes.',
};
const platformBoundaries = [
  ...Object.entries(boundaries).map(([module, exports]) => ({ module, exports })),
  { module: 'PluginCapabilityCatalogContext', exports: contextBoundaries },
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), CLAWROUTER_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', CLAWROUTER_SPEECH_PIN])
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
  return { verified: true, commit: CLAWROUTER_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${CLAWROUTER_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('ClawRouter speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class ClawRouterSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.calls = [];
    this.responses = [];
    this.releaseCount = 0;
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetch = () => { throw Error('Ambient fetch is excluded; source must use the named synthetic context guard'); };
    this.context = vm.createContext({ Buffer, URL, Uint8Array, fetch: this.fetch, process: { env: {} } },
      { codeGeneration: { strings: false, wasm: false } });
  }
  called(module, name, result, details = {}) {
    this.calls.push({ module, export: name, ...details });
    return result;
  }
  responseFacts(response, label) {
    assert.ok(this.responses.includes(response), 'synthetic response identity');
    return { responseIndex: this.responses.indexOf(response), status: response.status, label };
  }
  catalogContext() {
    return {
      resolveApiKeyForProvider: async params => this.called('PluginCapabilityCatalogContext',
        'resolveApiKeyForProvider', { apiKey: 'fixture-clawrouter-speech' },
        { provenanceOnly: true, input: plain(params) }),
      fetchWithSsrFGuard: async params => {
        const requestIndex = this.requests.length;
        this.requests.push({ url: params.url,
          init: { method: params.init.method, headers: plain(params.init.headers),
            body: JSON.parse(params.init.body), bodyText: params.init.body },
          timeoutMs: params.timeoutMs, policy: plain(params.policy), auditContext: params.auditContext,
          provenanceOnlyFields: ['init.headers', 'policy'] });
        const response = { ok: true, status: 200, fixtureResponse: plain(this.recipe.response) };
        this.responses.push(response);
        this.called('PluginCapabilityCatalogContext', 'fetchWithSsrFGuard', undefined, { requestIndex });
        return { response, release: async () => {
          this.releaseCount += 1;
          this.called('PluginCapabilityCatalogContext', 'release', undefined, { requestIndex });
        } };
      },
    };
  }
  platformModule(identifier) {
    const called = (name, result, details = {}) => this.called(identifier, name, result, details);
    const bindings = {};
    if (identifier === 'openclaw/plugin-sdk/secret-input') {
      bindings.normalizeResolvedSecretInputString = ({ value, path }) =>
        called('normalizeResolvedSecretInputString', typeof value === 'string' ? value.trim() : undefined,
          { provenanceOnly: true, path, ...(value === undefined ? {} : { value }) });
    } else if (identifier === 'openclaw/plugin-sdk/ssrf-runtime') {
      bindings.ssrfPolicyFromHttpBaseUrlAllowedHostname = url =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicy: 'clawrouter-source-url' },
          { provenanceOnly: true, url });
    } else if (identifier === 'openclaw/plugin-sdk/provider-http') {
      bindings.assertOkOrThrowProviderError = async (response, label, options) =>
        called('assertOkOrThrowProviderError', undefined,
          { ...this.responseFacts(response, label), options: plain(options), optionsProvenanceOnly: true });
      bindings.readProviderBinaryResponse = async (response, label, kind, options) => {
        const output = Buffer.from(response.fixtureResponse.audioBase64, 'base64');
        called('readProviderBinaryResponse', undefined, { ...this.responseFacts(response, label), kind,
          options: { maxBytes: options.maxBytes, onOverflow: typeof options.onOverflow },
          audioBase64: output.toString('base64'), audioHex: output.toString('hex'), byteLength: output.length });
        return output;
      };
    } else if (identifier === 'openclaw/plugin-sdk/media-generation-runtime') {
      bindings.resolveGeneratedMediaMaxBytes = (cfg, kind) =>
        called('resolveGeneratedMediaMaxBytes', 1_048_576, { input: plain(cfg), kind });
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
    const source = this.module(CLAWROUTER_SPEECH_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    this.context.catalogContext = this.catalogContext();
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildClawRouterSpeechProvider(catalogContext);
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      const callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      if (observationKind === 'config') return { metadata, callbacks, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, callbacks, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverrides') return { metadata, callbacks, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, callbacks, result: await provider.listVoices(speechInput) };
      const synthesisRequest = JSON.parse(JSON.stringify(speechInput));
      const callback = observationKind === 'telephony' ? 'synthesizeTelephony' : 'synthesize';
      const { audioBuffer, ...resultMetadata } = await provider[callback](speechInput);
      return { metadata, callbacks, result: { audioBase64: audioBuffer.toString('base64'), ...resultMetadata },
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(speechInput)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    const synthesizes = this.kind === 'synthesis' || this.kind === 'telephony';
    assert.equal(this.requests.length, synthesizes ? 1 : 0, 'ordinary callback request count');
    assert.equal(this.releaseCount, synthesizes ? 1 : 0, 'ordinary callback release count');
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

export async function captureClawRouterSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${CLAWROUTER_SPEECH_PIN}:${path}`], {
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
    return { path, gitBlob: git(root, ['rev-parse', `${CLAWROUTER_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, readRange: lineRange(bytes),
      executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const provenanceData = provenancePaths.map(path => ({ path, bytes: readOriginal(path) }));
  const dataAudit = provenanceData.map(({ path, bytes }) => ({ path,
    gitBlob: git(root, ['rev-parse', `${CLAWROUTER_SPEECH_PIN}:${path}`]), sourceSha256: hash(bytes), sourceBytes: bytes.length,
    readRange: lineRange(bytes), usage: path === 'LICENSE' ? 'Complete original license provenance.'
      : 'Complete original plugin data/registration/catalog provenance; not evaluated or registered.', evaluated: false }));
  assert.deepEqual(Object.keys(CLAWROUTER_SPEECH_CASES), ['config', 'talkConfig', 'talkOverrides', 'synthesis', 'telephony', 'voices']);
  const groups = {};
  for (const [kind, recipes] of Object.entries(CLAWROUTER_SPEECH_CASES)) {
    assert.ok(recipes.length > 0, 'independently authored recipes are embedded before execution');
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new ClawRouterSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  assert.equal(evaluated.size, sourcePaths.length, 'all seven complete original runtime modules evaluate');
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  const groupCounts = Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length]));
  return {
    schemaVersion: 1, referencePin: CLAWROUTER_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-clawrouter-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit, dataAudit,
    provenanceData: provenanceData.map(({ path, bytes }) => ({ path, text: bytes.toString() })),
    pluginManifest: JSON.parse(provenanceData.find(row => row.path === manifestPath).bytes),
    license: { path: 'LICENSE', text: provenanceData.find(row => row.path === 'LICENSE').bytes.toString() },
    platformBoundaries,
    globalBoundaries: {
      process: 'Isolated VM process.env={} only; no ambient credentials, profile store, fallback or configured predicate is exercised.',
      fetch: 'Throwing ambient binding; only the named synthetic successful context guarded-fetch facade is invoked.',
      Buffer: 'Native Buffer carries eight opaque synthetic bytes; no real audio format, codec or playback is established.',
      clock: 'Source passes raw ordinary request timeouts to the synthetic context guard. VM and asynchronous deadlines bound harness execution only; no source timeout behavior is qualified.',
    },
    providerMetadata: runs[0].observation.providerMetadata,
    providerCallbacks: runs[0].observation.providerCallbacks,
    counts: { ...groupCounts, totalObservations: runs.length,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0),
      wholeModules: evaluated.size, trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverrides.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    telephonyObservations: groups.telephony.map(run => run.observation),
    voiceObservations: groups.voices.map(run => run.observation),
    limits: [
      'All 58558 pinned tracked blobs/modes are verified before and after; complete original executable modules match pinned Git bytes before TypeScript erasure only.',
      'Seven whole original runtime modules evaluate: speech provider/base URL, string/record/number normalization, directive parser/number. Whole-module evaluation is not all-branch execution.',
      'Original factory, metadata, resolveConfig, resolveTalkConfig, resolveTalkOverrides, static listVoices, buffered synthesis and telephony execute ordinary positive recipes.',
      'Original directive parser construction executes; directive dispatch and isConfigured/isConfiguredAsync are never invoked.',
      'Original alias precedence, Talk overlay, exact text/JSON request construction, base-URL normalization, output format, file extension, Opus voiceCompatible and telephony 24000 Hz result metadata execute.',
      'Original auth call and header assembly execute only with a fixed named dummy context resolver; captured credential/header/policy fields are provenance, not authentication, credential-selection, permission, policy or TLS qualification.',
      'Secret normalization, status, binary read, media cap, policy and guarded HTTP are named positive synthetic facades. Eight opaque successful response bytes and counted release do not establish network, real media, codec or limit behavior.',
      'Manifest, index, capability catalog and license are complete original unevaluated provenance data; plugin activation, registration and production Synapsis installation are unexecuted.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
  };
}
export async function writeClawRouterSpeechCapture(root, output) {
  const capture = await captureClawRouterSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-clawrouter-speech.mjs --source-root DIR [--output FILE]');
    if (args[index] === '--source-root') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) return writeClawRouterSpeechCapture(root, output);
  const capture = await captureClawRouterSpeech(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
