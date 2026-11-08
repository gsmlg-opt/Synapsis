defmodule Synapsis.Provider.Speech.ClawRouterFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.ClawRouter

  @moduletag timeout: 90_000

  # The complete independently frozen source339 dictionaries are embedded verbatim.
  # No capture, production implementation or /tmp file supplies runtime expectations.
  # Source response bytes are the opaque eight bytes "fixture8", not codec evidence.
  @raw Jason.decode!(~S"""
       {
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
       }

       """)
  @expected Jason.decode!(~S"""
            {
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
            }

            """)

  test "dedicated metadata advertises the one source model and six ordered voices" do
    assert ClawRouter.metadata() == %{
             id: "clawrouter",
             label: "ClawRouter",
             default_model: "openai/tts-1",
             models: ["openai/tts-1"],
             voices: ~w(alloy echo fable onyx nova shimmer)
           }

    assert ClawRouter.models() == ["openai/tts-1"]
    assert ClawRouter.voices() == ~w(alloy echo fable onyx nova shimmer)

    assert Map.new(@raw, fn {category, rows} -> {category, length(rows)} end) ==
             %{
               "config" => 9,
               "talkConfig" => 8,
               "talkOverrides" => 4,
               "synthesis" => 27,
               "telephony" => 3,
               "voices" => 1
             }
  end

  for row <- @raw["config"] do
    @row row
    @literal @expected["config"][row["id"]]
    test "frozen source config #{@row["id"]}" do
      assert ClawRouter.resolve_config(@row["input"]["rawConfig"]) == source_fields(@literal)
    end
  end

  for row <- @raw["talkConfig"] do
    @row row
    @literal @expected["talkConfig"][row["id"]]
    test "frozen source Talk config #{@row["id"]}" do
      input = @row["input"]

      assert ClawRouter.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"]) ==
               source_fields(@literal)
    end
  end

  for row <- @raw["talkOverrides"] do
    @row row
    @literal @expected["talkOverrides"][row["id"]]
    test "frozen literal Talk overrides #{@row["id"]}" do
      # Exact map equality retains explicit nil keys and distinguishes absent keys.
      assert ClawRouter.resolve_talk_overrides(@row["input"]["params"]) == source_fields(@literal)
    end
  end

  for row <- @raw["voices"] do
    @row row
    @literal @expected["voices"][row["id"]]
    test "frozen static voices #{@row["id"]}" do
      assert ClawRouter.list_voices() == {:ok, Enum.map(@literal, &source_fields/1)}
    end
  end

  for category <- ["synthesis", "telephony"], row <- @raw[category] do
    @category category
    @row row
    @literal @expected[category][row["id"]]
    test "frozen builder and genuine HTTP #{@category} #{@row["id"]}" do
      input = @row["input"]
      request = source_request(input)
      source_config = input["providerConfig"]

      config =
        ClawRouter.resolve_config(%{"providers" => %{"clawrouter" => source_config}})
        |> Map.put(:api_key, "clawrouter-host-fixture")
        |> Map.put(:max_bytes, 65_536)

      # Dedicated phone synthesis forces PCM. Pure builder receives that explicit
      # phone format binding; actual phone service below receives the original config.
      builder_config =
        if @category == "telephony", do: Map.put(config, :response_format, "pcm"), else: config

      assert {:ok, built} = ClawRouter.build_request(request, builder_config)
      assert_source_request(built, @literal, input)

      raw_builder_config =
        source_config
        |> Map.put("apiKey", "clawrouter-host-fixture")
        |> Map.put("max_bytes", 65_536)

      raw_builder_config =
        if @category == "telephony",
          do: Map.put(raw_builder_config, "responseFormat", "pcm"),
          else: raw_builder_config

      assert {:ok, raw_built} = ClawRouter.build_request(request, raw_builder_config)
      assert_source_request(raw_built, @literal, input)

      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()
      id = @row["id"]
      path = URI.parse(@literal["request"]["url"]).path
      bytes = Base.decode64!(@row["response"]["audioBase64"])
      assert bytes == "fixture8"
      assert byte_size(bytes) == 8

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == @literal["request"]["body"]
        assert conn.request_path == path
        send(owner, {:clawrouter_source_http, id, conn.method, conn.request_path, raw_body})
        Plug.Conn.resp(conn, 200, bytes)
      end)

      # Only authority changes for actual HTTP. Preserve the selected source
      # base path, including repeated /v1 or uppercase /V1 and trailing slashes.
      local_config = Map.put(config, :base_url, loopback_base(fixture, input))

      assert {:ok, local_built} =
               ClawRouter.build_request(request, phone_config(local_config, @category))

      assert local_built.url == local_origin(fixture) <> path
      assert local_built.body == @literal["request"]["body"]
      assert local_built.timeout_ms === input["timeoutMs"]

      output =
        if @category == "telephony",
          do: ClawRouter.synthesize_telephony(request, local_config),
          else: ClawRouter.synthesize(request, local_config)

      assert output == {:ok, source_result(@literal["result"])}
      assert_receive {:clawrouter_source_http, ^id, "POST", ^path, body}, 5_000
      assert Jason.decode!(body) == @literal["request"]["body"]
    end
  end

  # These literal positive compositions bind the Talk APIs to actual HTTP. The
  # two source custom-model parsing recipes remain pure config tests above.
  for {id, source_id, body, format, compatible} <- [
        {"defaults", "talk-defaults",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "alloy",
           "response_format" => "mp3"
         }, "mp3", false},
        {"inherited", "talk-base-inherited",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "fable",
           "response_format" => "opus",
           "speed" => 1.1
         }, "opus", true},
        {"complete", "talk-complete-overrides",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "nova",
           "response_format" => "wav",
           "speed" => 1.8
         }, "wav", false},
        {"blank", "talk-blank-modelId-uses-default",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "onyx",
           "response_format" => "mp3"
         }, "mp3", false},
        {"speaker-alias", "talk-speakerVoiceId-before-voice",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "echo",
           "response_format" => "mp3"
         }, "mp3", false},
        {"voice-alias", "talk-voice-before-voiceId",
         %{
           "model" => "openai/tts-1",
           "input" => "  Talk line.\n世界  ",
           "voice" => "onyx",
           "response_format" => "aac",
           "speed" => 1.25
         }, "aac", false}
      ] do
    @composition_id id
    @talk_row Enum.find(@raw["talkConfig"], &(&1["id"] == source_id))
    @body body
    @format format
    @compatible compatible
    test "positive Talk config composes into genuine HTTP #{@composition_id}" do
      input = @talk_row["input"]
      config = ClawRouter.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])
      assert_talk_http(config, %{}, @body, @format, @compatible)
    end
  end

  for {id, voice, speed} <- [
        {"talk-overrides-empty", "alloy", nil},
        {"talk-overrides-literal-fields", "nova", 1.35},
        {"talk-overrides-nullish-preserved", "alloy", nil},
        {"talk-overrides-blank-preserved", "alloy", nil}
      ] do
    @override_row Enum.find(@raw["talkOverrides"], &(&1["id"] == id))
    @voice voice
    @speed speed
    test "positive literal Talk override composes into genuine HTTP #{id}" do
      overrides = ClawRouter.resolve_talk_overrides(@override_row["input"]["params"])

      body = %{
        "model" => "openai/tts-1",
        "input" => "  Talk line.\n世界  ",
        "voice" => @voice,
        "response_format" => "mp3"
      }

      body = if @speed, do: Map.put(body, "speed", @speed), else: body
      assert_talk_http(%{model: "openai/tts-1", voice: "alloy"}, overrides, body, "mp3", false)
    end
  end

  defp source_request(input) do
    %{
      text: input["text"],
      target: if(input["target"] == "voice-note", do: :voice_note, else: :audio_file),
      timeout_ms: input["timeoutMs"],
      cfg: input["cfg"],
      provider_overrides: input["providerOverrides"] || %{},
      deadline_ms: System.monotonic_time(:millisecond) + 60_000
    }
  end

  defp assert_source_request(built, literal, input) do
    assert built.method == :post
    assert built.url == literal["request"]["url"]
    assert built.body == literal["request"]["body"]
    assert built.timeout_ms === literal["request"]["timeoutMs"]
    assert built.timeout_ms === input["timeoutMs"]
    assert built.max_bytes == 65_536

    assert Map.take(built, [:output_format, :file_extension, :voice_compatible]) ==
             source_fields(
               Map.take(literal["result"], ~w(outputFormat fileExtension voiceCompatible))
             )
  end

  defp phone_config(config, "telephony"), do: Map.put(config, :response_format, "pcm")
  defp phone_config(config, "synthesis"), do: config

  defp loopback_base(fixture, input) do
    explicit = input["providerConfig"]["baseUrl"]
    fallback = get_in(input, ["cfg", "models", "providers", "clawrouter", "baseUrl"])

    source =
      Enum.find([explicit, fallback], "https://clawrouter.openclaw.ai", fn value ->
        is_binary(value) and String.trim(value) != ""
      end)

    local_origin(fixture) <> (URI.parse(String.trim(source)).path || "")
  end

  defp local_origin(fixture), do: String.trim_trailing(Gaoxy.Test.url(fixture, "/"), "/")

  defp assert_talk_http(config, overrides, body, format, compatible) do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    config =
      Map.merge(config, %{
        api_key: "clawrouter-host-fixture",
        base_url: Gaoxy.Test.url(fixture, "/talk"),
        max_bytes: 65_536
      })

    request = %{
      text: "  Talk line.\n世界  ",
      target: :audio_file,
      timeout_ms: 26_001.25,
      provider_overrides: overrides
    }

    Gaoxy.Test.stub(fixture, "POST", "/talk/v1/audio/speech", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body
      send(owner, {:clawrouter_talk_http, raw})
      Plug.Conn.resp(conn, 200, "fixture8")
    end)

    assert {:ok, built} = ClawRouter.build_request(request, config)
    assert built.timeout_ms === 26_001.25
    assert built.body == body

    assert ClawRouter.synthesize(request, config) ==
             {:ok,
              %{
                audio: "fixture8",
                output_format: format,
                file_extension: "." <> format,
                voice_compatible: compatible
              }}

    assert_receive {:clawrouter_talk_http, raw}, 5_000
    assert Jason.decode!(raw) == body
  end

  defp source_result(raw) do
    raw
    |> Map.delete("audioBase64")
    |> source_fields()
    |> Map.put(:audio, Base.decode64!(raw["audioBase64"]))
  end

  # Explicit source-to-host field adapter, with no implementation-derived defaults.
  defp source_fields(map) do
    fields = %{
      "baseUrl" => :base_url,
      "model" => :model,
      "voice" => :voice,
      "speed" => :speed,
      "responseFormat" => :response_format,
      "outputFormat" => :output_format,
      "fileExtension" => :file_extension,
      "voiceCompatible" => :voice_compatible,
      "sampleRate" => :sample_rate,
      "id" => :id,
      "name" => :name
    }

    Map.new(map, fn {key, value} -> {Map.fetch!(fields, key), value} end)
  end
end
