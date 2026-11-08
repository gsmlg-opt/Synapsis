defmodule Synapsis.Provider.Speech.AzureFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Provider.Speech.Azure

  # Frozen ordinary inputs from batch335's recipe-contract.json. Expectations
  # were authored independently from the complete original Azure service source;
  # neither production output nor the captured fixture is loaded at test runtime.
  # Shape adaptation only: camelCase -> atom snake_case, file -> :audio_file,
  # voice-note -> :voice_note, audioBase64 -> exact :audio bytes, {:ok, result}.
  # Local HTTP replaces only the selected origin, retaining each literal prefix.
  # OpenClaw User-Agent is provenance; the host retains its own HTTP identity.
  @recipes Jason.decode!(~S"""
           {
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://westus.tts.speech.microsoft.com",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "endpoint": "https://speech.example/prefix/cognitiveservices/v1///",
                   "baseUrl": "https://speech.example/prefix",
                   "voice": "fr-FR-DeniseNeural",
                   "lang": "fr-FR",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 45000
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "centralus",
                   "baseUrl": "https://centralus.tts.speech.microsoft.com",
                   "voice": "Primary",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://Root.Example/custom",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus",
                   "endpoint": "https://ignored.example/endpoint"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "endpoint": "https://speech.example/tenant/CognitiveServices/V1////",
                   "baseUrl": "https://speech.example/tenant",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "EastUS2",
                   "baseUrl": "https://EastUS2.tts.speech.microsoft.com",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://westus.tts.speech.microsoft.com",
                   "voice": "Primary",
                   "lang": "de-DE",
                   "outputFormat": "AUDIO-24KHZ-MONO-MP3",
                   "voiceNoteOutputFormat": "OGG-24KHZ-MONO-OPUS"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://westus.tts.speech.microsoft.com",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://westus.tts.speech.microsoft.com",
                   "voice": "zh-CN-XiaoxiaoNeural",
                   "lang": "zh-CN",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "baseUrl": "https://westus.tts.speech.microsoft.com",
                   "voice": "en-US-JennyNeural",
                   "lang": "en-US",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "voiceNoteOutputFormat": "ogg-24khz-16bit-mono-opus",
                   "timeoutMs": 12345.5
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://saved.example/root/cognitiveservices/v1",
                   "baseUrl": "https://saved.example/root",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://saved.example/root/cognitiveservices/v1",
                   "baseUrl": "https://saved.example/root",
                   "voice": "TalkVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"TalkVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "northeurope",
                   "endpoint": "https://saved.example/root/cognitiveservices/v1",
                   "baseUrl": "https://northeurope.tts.speech.microsoft.com",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://talk.example/prefix/cognitiveservices/v1///",
                   "baseUrl": "https://talk.example/prefix",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://talk-base.example/root/CognitiveServices/V1///",
                   "baseUrl": "https://talk-base.example/root",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-talk-key",
                   "region": "eastus",
                   "endpoint": "https://talk-endpoint.example/alt",
                   "baseUrl": "https://talk-base.example/primary",
                   "voice": "TalkVoice",
                   "lang": "fr-FR",
                   "outputFormat": "webm-24khz-16bit-mono-opus",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"fr-FR\"><voice name=\"TalkVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://saved.example/root/cognitiveservices/v1",
                   "baseUrl": "https://saved.example/root",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
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
                 },
                 "expected": {
                   "apiKey": "fixture-azure-speech",
                   "region": "westus",
                   "endpoint": "https://talk-null.example/root/",
                   "baseUrl": "https://talk-null.example/root",
                   "voice": "SavedVoice",
                   "lang": "en-GB",
                   "outputFormat": "riff-24khz-16bit-mono-pcm",
                   "voiceNoteOutputFormat": "webm-24khz-16bit-mono-opus",
                   "timeoutMs": 60000
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-GB\"><voice name=\"SavedVoice\">A Talk line.</voice></speak>"
               }
             ],
             "talkOverride": [
               {
                 "id": "talk-overrides-empty",
                 "input": {
                   "params": {}
                 },
                 "expected": {},
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">A Talk line.</voice></speak>",
                 "httpResult": {
                   "audioBase64": "AAEC/v8=",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
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
                 },
                 "expected": {
                   "voice": "VoiceOverride",
                   "lang": "ja-JP",
                   "outputFormat": "raw-24khz-16bit-mono-pcm"
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"ja-JP\"><voice name=\"VoiceOverride\">A Talk line.</voice></speak>",
                 "httpResult": {
                   "audioBase64": "AAEC/v8=",
                   "outputFormat": "raw-24khz-16bit-mono-pcm",
                   "fileExtension": ".pcm",
                   "voiceCompatible": false
                 }
               },
               {
                 "id": "talk-overrides-voice-only",
                 "input": {
                   "params": {
                     "voiceId": " zh-CN-XiaoxiaoNeural "
                   }
                 },
                 "expected": {
                   "voice": "zh-CN-XiaoxiaoNeural"
                 },
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"zh-CN-XiaoxiaoNeural\">A Talk line.</voice></speak>",
                 "httpResult": {
                   "audioBase64": "AAEC/v8=",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
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
                 },
                 "expected": {},
                 "httpBody": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">A Talk line.</voice></speak>",
                 "httpResult": {
                   "audioBase64": "AAEC/v8=",
                   "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "ogg-24khz-16bit-mono-opus",
                     "fileExtension": ".ogg",
                     "voiceCompatible": true
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 60000,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345.5,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "AuDiO-24KHZ-MONO-MP3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "OGG-24KHZ-16BIT-MONO-OPUS",
                     "fileExtension": ".ogg",
                     "voiceCompatible": true
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "ogg-24khz-16bit-mono-vorbis",
                     "fileExtension": ".ogg",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "webm-24khz-16bit-mono-opus",
                     "fileExtension": ".webm",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "riff-24khz-16bit-mono-pcm",
                     "fileExtension": ".wav",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "raw-24khz-16bit-mono-pcm",
                     "fileExtension": ".pcm",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "amr-16khz-32kbps",
                     "fileExtension": ".amr",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "vendor-custom-encoding",
                     "fileExtension": ".audio",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "ogg-special-mp3-opus",
                     "fileExtension": ".mp3",
                     "voiceCompatible": true
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en&quot;&amp;&lt;&gt;&apos;\"><voice name=\"Ada &quot;&amp;&lt;&gt;&apos;\">Fish &amp; &lt;sea&gt; \"quoted\" 'waves'\n第二行</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"fr-FR\"><voice name=\"fr-FR-DeniseNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "riff-24khz-16bit-mono-pcm",
                     "fileExtension": ".wav",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"de-DE\"><voice name=\"Primary\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "webm-24khz-16bit-mono-opus",
                     "fileExtension": ".webm",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "riff-24khz-16bit-mono-pcm",
                     "fileExtension": ".wav",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://speech.example/tenant/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "audio-24khz-48kbitrate-mono-mp3",
                     "fileExtension": ".mp3",
                     "voiceCompatible": false
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "raw-8khz-8bit-mono-mulaw",
                     "sampleRate": 8000
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 12345,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "raw-8khz-8bit-mono-mulaw",
                     "sampleRate": 8000
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/v1",
                   "body": "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"fr-FR\"><voice name=\"fr-FR-DeniseNeural\">Hello Azure.</voice></speak>",
                   "timeoutMs": 60000,
                   "result": {
                     "audioBase64": "AAEC/v8=",
                     "outputFormat": "raw-8khz-8bit-mono-mulaw",
                     "sampleRate": 8000
                   }
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/voices/list",
                   "timeoutMs": 30000,
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
                 },
                 "expected": {
                   "url": "https://voices.example/custom/cognitiveservices/voices/list",
                   "timeoutMs": 12000,
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
                 },
                 "expected": {
                   "url": "https://request-voices.example/root/cognitiveservices/voices/list",
                   "timeoutMs": 60000,
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
                 },
                 "expected": {
                   "url": "https://westus.tts.speech.microsoft.com/cognitiveservices/voices/list",
                   "timeoutMs": 23456,
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
                 },
                 "expected": {
                   "url": "https://speech.example/tenant/cognitiveservices/voices/list",
                   "timeoutMs": 30000,
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
             ]
           }
           """)

  test "exact source metadata and explicit service interfaces" do
    assert Azure.metadata() == %{
             id: "azure-speech",
             label: "Azure Speech",
             aliases: ["azure"],
             auto_select_order: 30
           }

    for {name, arity} <- [
          resolve_config: 1,
          resolve_talk_config: 2,
          resolve_talk_overrides: 1,
          build_request: 2,
          synthesize: 2,
          synthesize_telephony: 2,
          list_voices: 2
        ] do
      assert function_exported?(Azure, name, arity)
    end
  end

  for group <- ~w(config talkConfig talkOverride), row <- @recipes[group] do
    @group group
    @row row
    test "literal source callback #{@group}: #{row["id"]}" do
      input = @row["input"]
      expected = canonical(@row["expected"])

      actual =
        case @group do
          "config" ->
            Azure.resolve_config(input["rawConfig"])

          "talkConfig" ->
            Azure.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])

          "talkOverride" ->
            Azure.resolve_talk_overrides(input["params"])
        end

      assert actual == expected
    end
  end

  for row <- @recipes["synthesis"] do
    @row row
    test "literal SSML, format, timing and single HTTP synthesis: #{row["id"]}" do
      input = @row["input"]
      expected = @row["expected"]
      config = source_config(input["providerConfig"])
      request = synthesis_request(input)
      assert {:ok, built} = Azure.build_request(request, config)
      assert built.url == expected["url"]
      assert built.body == expected["body"]
      assert built.timeout_ms == expected["timeoutMs"]

      assert Map.take(built, [:output_format, :file_extension, :voice_compatible, :media_format]) ==
               Map.drop(expected_result(expected["result"]), [:audio])

      assert built.media_format == String.trim_leading(expected["result"]["fileExtension"], ".")
      assert_headers(built.headers, expected["result"]["outputFormat"], "fixture-azure-speech")

      fixture = http_fixture()
      path = URI.parse(expected["url"]).path

      counter =
        stub_synthesis(fixture, path, expected["body"], expected["result"]["outputFormat"])

      local = local_config(config, fixture, path, "/cognitiveservices/v1")
      before_links = links()
      {result, requests} = trace_http(fn -> Azure.synthesize(request, local) end)
      assert result == {:ok, expected_result(expected["result"])}
      assert :counters.get(counter, 1) == 1
      assert links() == before_links
      assert_http_timeout(requests, Gaoxy.Test.url(fixture, path), expected["timeoutMs"])
    end
  end

  for row <- @recipes["telephony"] do
    @row row
    test "dedicated raw mu-law callback retains voice and timing: #{row["id"]}" do
      input = @row["input"]
      expected = @row["expected"]
      config = source_config(input["providerConfig"])
      fixture = http_fixture()
      path = "/cognitiveservices/v1"
      counter = stub_synthesis(fixture, path, expected["body"], "raw-8khz-8bit-mono-mulaw")
      local = local_config(config, fixture, path, path)
      before_links = links()

      {result, requests} =
        trace_http(fn -> Azure.synthesize_telephony(synthesis_request(input), local) end)

      assert result == {:ok, expected_result(expected["result"])}
      assert :counters.get(counter, 1) == 1
      assert links() == before_links
      assert_http_timeout(requests, Gaoxy.Test.url(fixture, path), expected["timeoutMs"])
    end
  end

  for row <- @recipes["voices"] do
    @row row
    test "literal ordered voice catalog and one discovery GET: #{row["id"]}" do
      input = @row["input"]
      expected = @row["expected"]
      fixture = http_fixture()
      path = URI.parse(expected["url"]).path
      counter = stub_voices(fixture, path, @row["response"]["json"])
      config = source_config(input["providerConfig"] || %{})
      request = canonical(Map.drop(input, ["providerConfig"]))

      {request, config} =
        if Map.has_key?(request, :base_url) do
          # Keep a distinct configured path so request-route precedence is observable.
          configured_path =
            URI.parse(config[:base_url] || "https://configured.example").path || ""

          request_path = URI.parse(String.trim(input["baseUrl"])).path || ""

          request =
            Map.put(request, :base_url, " " <> local_url(fixture, request_path) <> " ")

          {request, Map.put(config, :base_url, local_url(fixture, configured_path))}
        else
          {request, local_config(config, fixture, path, "/cognitiveservices/voices/list")}
        end

      before_links = links()
      {result, requests} = trace_http(fn -> Azure.list_voices(request, config) end)
      assert result == {:ok, canonical(expected["result"])}
      assert :counters.get(counter, 1) == 1
      assert links() == before_links
      assert_http_timeout(requests, Gaoxy.Test.url(fixture, path), expected["timeoutMs"])
    end
  end

  for row <- @recipes["talkConfig"] do
    @row row
    test "explicit Talk config composes with synthesis and discovery: #{row["id"]}" do
      input = @row["input"]
      expected = canonical(@row["expected"])
      config = Azure.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])
      assert config == expected
      fixture = http_fixture()
      root = URI.parse(expected.base_url).path || ""
      speech_path = root <> "/cognitiveservices/v1"
      voices_path = root <> "/cognitiveservices/voices/list"

      speech =
        stub_synthesis(
          fixture,
          speech_path,
          @row["httpBody"],
          expected.output_format,
          expected.api_key
        )

      voices =
        stub_voices(
          fixture,
          voices_path,
          [%{"ShortName" => "TalkVoice", "DisplayName" => "Talk voice", "Status" => "Active"}],
          expected.api_key
        )

      local = Map.put(config, :base_url, local_url(fixture, root))
      request = %{text: "A Talk line.", target: :audio_file, timeout_ms: 10_000}
      {output, calls} = trace_http(fn -> Azure.synthesize(request, local) end)
      assert {:ok, audio} = output
      assert audio.audio == <<0, 1, 2, 254, 255>>
      assert audio.output_format == expected.output_format
      assert_http_timeout(calls, Gaoxy.Test.url(fixture, speech_path), 60_000)
      {catalog, calls} = trace_http(fn -> Azure.list_voices(%{timeout_ms: 10_000}, local) end)
      assert catalog == {:ok, [%{id: "TalkVoice", name: "Talk voice"}]}
      assert_http_timeout(calls, Gaoxy.Test.url(fixture, voices_path), 60_000)
      assert :counters.get(speech, 1) == 1
      assert :counters.get(voices, 1) == 1
    end
  end

  for row <- @recipes["talkOverride"] do
    @row row
    test "explicit Talk overrides compose with actual synthesis: #{row["id"]}" do
      fixture = http_fixture()
      result = @row["httpResult"]

      counter =
        stub_synthesis(fixture, "/cognitiveservices/v1", @row["httpBody"], result["outputFormat"])

      config =
        source_config(%{"apiKey" => "fixture-azure-speech", "baseUrl" => Gaoxy.Test.url(fixture)})

      overrides = Azure.resolve_talk_overrides(@row["input"]["params"])
      assert overrides == canonical(@row["expected"])

      request = %{
        text: "A Talk line.",
        target: :audio_file,
        timeout_ms: 12_345,
        provider_overrides: overrides
      }

      assert Azure.synthesize(request, config) == {:ok, expected_result(result)}
      assert :counters.get(counter, 1) == 1
    end
  end

  test "an existing empty primary record precedes the azure alias" do
    assert Azure.resolve_config(%{
             "providers" => %{
               "azure-speech" => %{},
               "azure" => %{"voice" => "Secondary", "region" => "eastus"}
             }
           }) == %{
             voice: "en-US-JennyNeural",
             lang: "en-US",
             output_format: "audio-24khz-48kbitrate-mono-mp3",
             voice_note_output_format: "ogg-24khz-16bit-mono-opus"
           }
  end

  test "finite host synthesis fallback stays separate from absent provider timeout" do
    config = source_config(%{"apiKey" => "fixture-azure-speech", "region" => "westus"})
    refute Map.has_key?(config, :timeout_ms)

    assert {:ok, built} =
             Azure.build_request(%{text: "Hello Azure.", target: :audio_file}, config)

    assert built.timeout_ms == 30_000

    assert {:ok, requested} =
             Azure.build_request(
               %{text: "Hello Azure.", target: :audio_file, timeout_ms: 75_000},
               config
             )

    assert requested.timeout_ms == 75_000
  end

  defp source_config(config),
    do: Azure.resolve_config(%{"providers" => %{"azure-speech" => config}})

  defp synthesis_request(input) do
    %{
      text: input["text"],
      target:
        %{"file" => :audio_file, "voice-note" => :voice_note, "telephony" => :telephony}[
          input["target"]
        ],
      timeout_ms: input["timeoutMs"],
      provider_overrides: canonical(input["providerOverrides"] || %{})
    }
  end

  defp expected_result(raw) do
    result =
      raw
      |> Map.delete("audioBase64")
      |> canonical()
      |> Map.put(:audio, Base.decode64!(raw["audioBase64"]))

    # Host publication adds an extension label; vendor output_format stays exact.
    # Dedicated telephony has no file extension and gains no invented label.
    case Map.fetch(raw, "fileExtension") do
      {:ok, extension} -> Map.put(result, :media_format, String.trim_leading(extension, "."))
      :error -> result
    end
  end

  defp canonical(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {field(key), canonical(item)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp field(key) do
    %{
      "apiKey" => :api_key,
      "baseUrl" => :base_url,
      "timeoutMs" => :timeout_ms,
      "voiceId" => :voice_id,
      "languageCode" => :language_code,
      "outputFormat" => :output_format,
      "voiceNoteOutputFormat" => :voice_note_output_format,
      "fileExtension" => :file_extension,
      "voiceCompatible" => :voice_compatible,
      "sampleRate" => :sample_rate,
      "region" => :region,
      "endpoint" => :endpoint,
      "voice" => :voice,
      "lang" => :lang,
      "id" => :id,
      "name" => :name,
      "description" => :description,
      "locale" => :locale,
      "gender" => :gender,
      "personalities" => :personalities
    }
    |> Map.fetch!(key)
  end

  defp http_fixture do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    fixture
  end

  defp stub_synthesis(fixture, path, body, format, key \\ "fixture-azure-speech") do
    counter = :counters.new(1, [])

    Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert raw == body
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/ssml+xml"]
      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") == [key]
      assert Plug.Conn.get_req_header(conn, "x-microsoft-outputformat") == [format]
      :counters.add(counter, 1, 1)
      Plug.Conn.resp(conn, 200, <<0, 1, 2, 254, 255>>)
    end)

    counter
  end

  defp stub_voices(fixture, path, payload, key \\ "fixture-azure-speech") do
    counter = :counters.new(1, [])

    Gaoxy.Test.stub(fixture, "GET", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ""
      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") == [key]
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    counter
  end

  defp assert_headers(headers, format, key) do
    normalized = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    assert Map.take(normalized, [
             "content-type",
             "ocp-apim-subscription-key",
             "x-microsoft-outputformat"
           ]) == %{
             "content-type" => "application/ssml+xml",
             "ocp-apim-subscription-key" => key,
             "x-microsoft-outputformat" => format
           }
  end

  defp local_config(config, fixture, path, suffix) do
    Map.put(config, :base_url, local_url(fixture, prefix(path, suffix)))
  end

  defp local_url(fixture, ""),
    do: String.trim_trailing(Gaoxy.Test.url(fixture, "/"), "/")

  defp local_url(fixture, path), do: Gaoxy.Test.url(fixture, path)

  defp prefix(path, suffix), do: String.replace_suffix(path, suffix, "")
  defp links, do: self() |> Process.info(:links) |> elem(1) |> MapSet.new()

  # Trace only this invocation and descendants. No transport mock or new
  # production observer is needed to inspect actual finite HTTP option selection.
  defp trace_http(fun) do
    Code.ensure_loaded!(Req)
    assert :erlang.trace_pattern({Req, :request, 1}, true, [:local]) == 1

    task =
      Task.async(fn ->
        receive do
          :start ->
            before_links = links()
            result = fun.()
            assert links() == before_links
            result
        end
      end)

    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :start)

    try do
      result = Task.await(task, 5_000)
      barrier = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^barrier}, 5_000
      {result, drain_http([])}
    after
      :erlang.trace_pattern({Req, :request, 1}, false, [:local])
    end
  end

  defp drain_http(acc) do
    receive do
      {:trace, _pid, :call, {Req, :request, [%Req.Request{} = request]}} ->
        drain_http([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_http_timeout(requests, url, source_timeout) do
    assert [request] = Enum.filter(requests, &(URI.to_string(&1.url) == url))
    assert request.options[:retry] == false
    duration = ceil(source_timeout)
    # Original numeric provenance is asserted exactly in build_request/config.
    # Actual integer timer options can spend a little time reaching Req.
    assert request.options[:request_timeout] in (duration - 1_000)..duration
    assert request.options[:receive_timeout] in 1..min(duration, 30_000)
    assert request.options[:finch][:pool_timeout] in 1..duration
  end
end
