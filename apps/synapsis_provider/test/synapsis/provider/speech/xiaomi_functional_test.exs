defmodule Synapsis.Provider.Speech.XiaomiFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Provider.Speech.{Opus, Xiaomi}

  @moduletag timeout: 90_000
  # Independent source337 inputs/literals frozen before host production exists.
  # This embedded dictionary is never read from generated capture or /tmp at runtime.
  # Five source voice-note response byte strings are synthetic non-containers.
  # Only their HTTP response audio.data is bound to valid media below; original
  # wire/body/timing/output metadata stay literal. Synthetic transcode output is
  # provenance, never an expected actual codec artifact. See service-bindings.json.
  @recipes Jason.decode!(~S"""
           {
           "config": [
             {
               "id": "config-canonical-defaults",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech"
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "mimo_default",
                 "format": "mp3"
               }
             },
             {
               "id": "config-mimo-complete",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "mimo": {
                       "apiKey": " fixture-xiaomi-speech ",
                       "baseUrl": " https://Alias.Example/tenant/v2/// ",
                       "modelId": " custom-mimo ",
                       "voiceId": " Custom Voice ",
                       "format": " WAV ",
                       "style": " 轻柔、清晰。 "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://Alias.Example/tenant/v2",
                 "model": "custom-mimo",
                 "voice": "Custom Voice",
                 "format": "wav",
                 "style": "轻柔、清晰。"
               }
             },
             {
               "id": "config-canonical-whole-object-precedence",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech"
                     },
                     "mimo": {
                       "apiKey": "fixture-xiaomi-speech",
                       "baseUrl": "https://ignored.example/v7",
                       "model": "ignored-model",
                       "voice": "Dean",
                       "format": "wav",
                       "style": "ignored style"
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "mimo_default",
                 "format": "mp3"
               }
             },
             {
               "id": "config-model-primary-and-voice-alias-precedence",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "model": " mimo-v2.5-tts ",
                       "modelId": "mimo-v2.5-tts-voicedesign",
                       "speakerVoice": " Mia ",
                       "speakerVoiceId": "Chloe",
                       "voice": "Milo",
                       "voiceId": "Dean",
                       "format": " MP3 "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "Mia",
                 "format": "mp3"
               }
             },
             {
               "id": "config-speakerVoice",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "speakerVoice": " default_zh "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "default_zh",
                 "format": "mp3"
               }
             },
             {
               "id": "config-speakerVoiceId-before-voice",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "speakerVoiceId": " Chloe ",
                       "voice": "Milo",
                       "voiceId": "Dean"
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "Chloe",
                 "format": "mp3"
               }
             },
             {
               "id": "config-voice-before-voiceId",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "voice": " Milo ",
                       "voiceId": "Dean"
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "Milo",
                 "format": "mp3"
               }
             },
             {
               "id": "config-voiceId",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "voiceId": " Dean "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts",
                 "voice": "Dean",
                 "format": "mp3"
               }
             },
             {
               "id": "config-modelId-design-wav-style",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "modelId": " mimo-v2.5-tts-voicedesign ",
                       "format": " WaV ",
                       "style": " A bright storyteller. "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://api.xiaomimimo.com/v1",
                 "model": "mimo-v2.5-tts-voicedesign",
                 "voice": "mimo_default",
                 "format": "wav",
                 "style": "A bright storyteller."
               }
             },
             {
               "id": "config-custom-base-model-voice",
               "input": {
                 "rawConfig": {
                   "providers": {
                     "xiaomi": {
                       "apiKey": "fixture-xiaomi-speech",
                       "baseUrl": " https://Custom.Example/api/prefix//// ",
                       "model": " experimental-tts-v9 ",
                       "speakerVoice": " My Custom Voice ",
                       "format": " mP3 ",
                       "style": "  Gentle\nclear﻿ "
                     }
                   }
                 }
               },
               "expected": {
                 "apiKey": "fixture-xiaomi-speech",
                 "baseUrl": "https://Custom.Example/api/prefix",
                 "model": "experimental-tts-v9",
                 "voice": "My Custom Voice",
                 "format": "mp3",
                 "style": "Gentle\nclear"
               }
             }
           ],
           "synthesis": [
             {
               "id": "ordinary-mp3-audio-file",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech"
                 },
                 "target": "audio-file",
                 "timeoutMs": 21000
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "mimo_default"
                       }
                     }
                   },
                   "timeoutMs": 21000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "ordinary-mp3-voice-note",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech"
                 },
                 "target": "voice-note",
                 "timeoutMs": 21001.75
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "BQYHCA"
                         }
                       }
                     }
                   ]
                 },
                 "transcodeAudioBase64": "T1BVUw=="
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "mimo_default"
                       }
                     }
                   },
                   "timeoutMs": 21001,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "T1BVUw==",
                   "outputFormat": "opus",
                   "fileExtension": ".opus",
                   "voiceCompatible": true
                 },
                 "transcodes": [
                   {
                     "audioBase64": "BQYHCA==",
                     "audioHex": "05060708",
                     "byteLength": 4,
                     "inputExtension": "mp3",
                     "tempPrefix": "tts-xiaomi-",
                     "timeoutMs": 21001.75,
                     "outputAudioBase64": "T1BVUw==",
                     "outputAudioHex": "4f505553",
                     "outputByteLength": 4
                   }
                 ]
               }
             },
             {
               "id": "ordinary-wav-audio-file",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "format": " WAV ",
                   "voice": "default_zh"
                 },
                 "target": "audio-file",
                 "timeoutMs": 21002
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": " CQ\toL\n DA==\r "
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav",
                         "voice": "default_zh"
                       }
                     }
                   },
                   "timeoutMs": 21002,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "CQoLDA==",
                   "outputFormat": "wav",
                   "fileExtension": ".wav",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "ordinary-wav-voice-note",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "format": "wav",
                   "voice": "default_en"
                 },
                 "target": "voice-note",
                 "timeoutMs": 21003.5
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 },
                 "transcodeAudioBase64": "T1BVUw=="
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav",
                         "voice": "default_en"
                       }
                     }
                   },
                   "timeoutMs": 21003,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "T1BVUw==",
                   "outputFormat": "opus",
                   "fileExtension": ".opus",
                   "voiceCompatible": true
                 },
                 "transcodes": [
                   {
                     "audioBase64": "AQIDBA==",
                     "audioHex": "01020304",
                     "byteLength": 4,
                     "inputExtension": "wav",
                     "tempPrefix": "tts-xiaomi-",
                     "timeoutMs": 21003.5,
                     "outputAudioBase64": "T1BVUw==",
                     "outputAudioHex": "4f505553",
                     "outputByteLength": 4
                   }
                 ]
               }
             },
             {
               "id": "design-mp3-audio-file",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "voice": "Mia"
                 },
                 "target": "audio-file",
                 "timeoutMs": 21004
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3"
                       }
                     }
                   },
                   "timeoutMs": 21004,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "design-mp3-voice-note",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "speakerVoice": "Chloe"
                 },
                 "target": "voice-note",
                 "timeoutMs": 21005.25
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "BQYHCA"
                         }
                       }
                     }
                   ]
                 },
                 "transcodeAudioBase64": "T1BVUw=="
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3"
                       }
                     }
                   },
                   "timeoutMs": 21005,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "T1BVUw==",
                   "outputFormat": "opus",
                   "fileExtension": ".opus",
                   "voiceCompatible": true
                 },
                 "transcodes": [
                   {
                     "audioBase64": "BQYHCA==",
                     "audioHex": "05060708",
                     "byteLength": 4,
                     "inputExtension": "mp3",
                     "tempPrefix": "tts-xiaomi-",
                     "timeoutMs": 21005.25,
                     "outputAudioBase64": "T1BVUw==",
                     "outputAudioHex": "4f505553",
                     "outputByteLength": 4
                   }
                 ]
               }
             },
             {
               "id": "design-wav-audio-file",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "format": "wav",
                   "voiceId": "Milo"
                 },
                 "target": "audio-file",
                 "timeoutMs": 21006
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav"
                       }
                     }
                   },
                   "timeoutMs": 21006,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "wav",
                   "fileExtension": ".wav",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "design-wav-voice-note",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "format": " WaV ",
                   "speakerVoiceId": "Dean"
                 },
                 "target": "voice-note",
                 "timeoutMs": 21007.875
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": " CQ\toL\n DA==\r "
                         }
                       }
                     }
                   ]
                 },
                 "transcodeAudioBase64": "T1BVUw=="
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav"
                       }
                     }
                   },
                   "timeoutMs": 21007,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "T1BVUw==",
                   "outputFormat": "opus",
                   "fileExtension": ".opus",
                   "voiceCompatible": true
                 },
                 "transcodes": [
                   {
                     "audioBase64": "CQoLDA==",
                     "audioHex": "090a0b0c",
                     "byteLength": 4,
                     "inputExtension": "wav",
                     "tempPrefix": "tts-xiaomi-",
                     "timeoutMs": 21007.875,
                     "outputAudioBase64": "T1BVUw==",
                     "outputAudioHex": "4f505553",
                     "outputByteLength": 4
                   }
                 ]
               }
             },
             {
               "id": "override-speakerVoice",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "voice": "default_en"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "speakerVoice": " Mia "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "Mia"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-speakerVoiceId-before-voice",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "speakerVoice": "mimo_default"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "speakerVoiceId": " Chloe ",
                   "voice": "Milo",
                   "voiceId": "Dean"
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "Chloe"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-voice-before-voiceId",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "speakerVoiceId": "default_zh"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "voice": " Milo ",
                   "voiceId": "Dean"
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "Milo"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-voiceId",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "voice": "Mia"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "voiceId": " Dean "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "Dean"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-model-and-all-voice-alias-precedence",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "config-model",
                   "voice": "config-voice",
                   "format": "wav"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "model": " override-model ",
                   "modelId": "ignored-model",
                   "speakerVoice": " default_en ",
                   "speakerVoiceId": "Mia",
                   "voice": "Chloe",
                   "voiceId": "Milo",
                   "format": " MP3 "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "override-model",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "default_en"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-modelId",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "config-model"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "modelId": " custom-override-model "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "custom-override-model",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "mimo_default"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-into-voice-design",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "voice": "Mia",
                   "format": "mp3"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "modelId": " mimo-v2.5-tts-voicedesign ",
                   "voiceId": "Dean",
                   "format": " WAV "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "wav",
                   "fileExtension": ".wav",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "override-out-of-voice-design",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "voice": "default_zh",
                   "format": "wav"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "model": " mimo-v2.5-tts ",
                   "speakerVoice": " default_en ",
                   "format": " MP3 "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "default_en"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "custom-prefix-model-voice-style-exact-text-first-choice",
               "input": {
                 "text": "  你好，MiMo 👋\n\"quoted\" <xml> & café\r\n尾行  ",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "baseUrl": " https://Custom.Example/tenant/v8/// ",
                   "model": " custom-source-model ",
                   "voice": " My Custom Voice ",
                   "format": " WAV ",
                   "style": "  Soft & clear <read>\n亲切﻿ "
                 },
                 "target": "voice-note",
                 "timeoutMs": 34567.625
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": " CQ\toL\n DA==\r "
                         },
                         "content": "ignored transcript"
                       }
                     },
                     {
                       "message": {
                         "audio": {
                           "data": "EBESEw=="
                         }
                       }
                     }
                   ],
                   "usage": {
                     "total_tokens": 23
                   }
                 },
                 "transcodeAudioBase64": "U1lOVEg="
               },
               "expected": {
                 "request": {
                   "url": "https://Custom.Example/tenant/v8/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "custom-source-model",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Soft & clear <read>\n亲切"
                         },
                         {
                           "role": "assistant",
                           "content": "  你好，MiMo 👋\n\"quoted\" <xml> & café\r\n尾行  "
                         }
                       ],
                       "audio": {
                         "format": "wav",
                         "voice": "My Custom Voice"
                       }
                     }
                   },
                   "timeoutMs": 34567,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "U1lOVEg=",
                   "outputFormat": "opus",
                   "fileExtension": ".opus",
                   "voiceCompatible": true
                 },
                 "transcodes": [
                   {
                     "audioBase64": "CQoLDA==",
                     "audioHex": "090a0b0c",
                     "byteLength": 4,
                     "inputExtension": "wav",
                     "tempPrefix": "tts-xiaomi-",
                     "timeoutMs": 34567.625,
                     "outputAudioBase64": "U1lOVEg=",
                     "outputAudioHex": "53594e5448",
                     "outputByteLength": 5
                   }
                 ]
               }
             },
             {
               "id": "ordinary-config-style",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "style": " Calm, measured narration. "
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Calm, measured narration."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3",
                         "voice": "mimo_default"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "ordinary-override-style",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "style": "Configured style",
                   "format": "mp3"
                 },
                 "target": "audio-file",
                 "timeoutMs": 32123.75,
                 "providerOverrides": {
                   "style": " Bright\nprecise style. ",
                   "format": " WAV "
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Bright\nprecise style."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav",
                         "voice": "mimo_default"
                       }
                     }
                   },
                   "timeoutMs": 32123,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "wav",
                   "fileExtension": ".wav",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "design-config-style",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "style": " Whispering, but clear. ",
                   "voice": "Dean"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "Whispering, but clear."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "mp3"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "mp3",
                   "fileExtension": ".mp3",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             },
             {
               "id": "design-override-style",
               "input": {
                 "text": "Synthetic source speech.",
                 "providerConfig": {
                   "apiKey": "fixture-xiaomi-speech",
                   "model": "mimo-v2.5-tts-voicedesign",
                   "style": "Configured design style",
                   "format": "wav"
                 },
                 "target": "audio-file",
                 "timeoutMs": 30000,
                 "providerOverrides": {
                   "style": " A warm radio host. ",
                   "speakerVoiceId": "Chloe"
                 }
               },
               "response": {
                 "json": {
                   "choices": [
                     {
                       "message": {
                         "audio": {
                           "data": "AQIDBA=="
                         }
                       }
                     }
                   ]
                 }
               },
               "expected": {
                 "request": {
                   "url": "https://api.xiaomimimo.com/v1/chat/completions",
                   "init": {
                     "method": "POST",
                     "headers": {
                       "api-key": "fixture-xiaomi-speech",
                       "Content-Type": "application/json"
                     },
                     "body": {
                       "model": "mimo-v2.5-tts-voicedesign",
                       "messages": [
                         {
                           "role": "user",
                           "content": "A warm radio host."
                         },
                         {
                           "role": "assistant",
                           "content": "Synthetic source speech."
                         }
                       ],
                       "audio": {
                         "format": "wav"
                       }
                     }
                   },
                   "timeoutMs": 30000,
                   "policy": {
                     "fixturePolicy": "xiaomi-source-url"
                   },
                   "auditContext": "xiaomi.tts"
                 },
                 "result": {
                   "audioBase64": "AQIDBA==",
                   "outputFormat": "wav",
                   "fileExtension": ".wav",
                   "voiceCompatible": false
                 },
                 "transcodes": []
               }
             }
           ],
           "voices": [
             {
               "id": "voices-static-seven-ordered",
               "input": {},
               "expected": [
                 {
                   "id": "mimo_default",
                   "name": "mimo_default"
                 },
                 {
                   "id": "default_zh",
                   "name": "default_zh"
                 },
                 {
                   "id": "default_en",
                   "name": "default_en"
                 },
                 {
                   "id": "Mia",
                   "name": "Mia"
                 },
                 {
                   "id": "Chloe",
                   "name": "Chloe"
                 },
                 {
                   "id": "Milo",
                   "name": "Milo"
                 },
                 {
                   "id": "Dean",
                   "name": "Dean"
                 }
               ]
             }
           ]
           }
           """)
  @media Jason.decode!(~S"""
         {
         "mp3": {
           "bytes": 909,
           "sha256": "eaeb2b0a453849671cd50e6a8a3acd4b652beca86b19c78573587b19e38c8ec0",
           "base64": "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMgAAAAAAAAAAAAAA//OEwAAAAAAAAAAAAEluZm8AAAAPAAAABwAAA2AAVVVVVVVVVVVVVVVVVVVxcXFxcXFxcXFxcXFxcY6Ojo6Ojo6Ojo6Ojo6Oqqqqqqqqqqqqqqqqqqqqx8fHx8fHx8fHx8fHx8fj4+Pj4+Pj4+Pj4+Pj4///////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQEIAAAAAAAAANgrF8r0wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//NExAARgE6kX08YAAHv+2/AQ9D0PQ80zrVa4IIBnAzgqwkYm5L1Gzx4gIAgCAYicPvygYy4P8EHTnBN+J3cv7un3dPuxAAwfw+CByoBh/gh0+4gCSDCCAQAAI3Fnt1N//NExA0ViT6c15tQAFCYaqHeFgwXnkgwJLDxC0ycOLbPb18+ASgMgK/iCBuBuFX/ESIkiHw+/8hHo9Ih8Pv/yEej04fD43+CoiCoK/8sFQVEQVBX/8sqLnJXLrMAaAMz//NExAkUyFosAd8AAACIATMAyAITArwbQwZwSAMDUB9zBbwoo3GVFuMjOCgTBlwaAwOEDSMDvAfDAJAEcwCAAhMAgABwSAFF8l/S3////////9X////01YmsIXDMIKMy//NExAgS+F4cANf4JJTgYDArwUcxG0bNMFiALzBRxH06GTP3MXrCbzmjOM+mEx4MjD4bMIA4wSBy5adD92P1/+5enR9n/q/+32/+n5PT72ccYAtt2//wAGff1SOhOO4+//NExA8WOba1v1owAooOZukX8ZJSbzz+A37l+denp6e2hGPd3dxGPd69kEMe7/sghl3rYeACGXetlkCGXfbLIIZd+Msghj34xyCGPvjHIBgmUcGOUdwxjAAAFotFotFA//NExAkUAT7aX5OIAqBAAAAARVBGomijjUC6KuMQr+FUCKBbMckqFni3icBO5EzFA6j44BmyfIgRdlo1/L5OEXMy4X16/9MuF9aBmv+CYkC4jb/qTEFNRTMuMTAwVVVV//NExAwAAANIAcAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
         },
         "wav": {
           "bytes": 4844,
           "sha256": "4170f61ca9b5c83ed800b9f698efbec63e6f0cef2445034a9795be1a6a0ef828",
           "base64": "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"
         }
         }
         """)

  test "source metadata and complete static voice list remain advisory" do
    assert Xiaomi.metadata() == %{
             id: "xiaomi",
             label: "Xiaomi MiMo",
             aliases: ["mimo"],
             auto_select_order: 45,
             default_model: "mimo-v2.5-tts",
             models: ["mimo-v2.5-tts", "mimo-v2.5-tts-voicedesign"],
             voices: ~w(mimo_default default_zh default_en Mia Chloe Milo Dean)
           }

    assert Xiaomi.models() == ["mimo-v2.5-tts", "mimo-v2.5-tts-voicedesign"]
    assert Xiaomi.voices() == ~w(mimo_default default_zh default_en Mia Chloe Milo Dean)
    assert {:ok, voices} = Xiaomi.list_voices()

    assert voices ==
             Enum.map(
               ~w(mimo_default default_zh default_en Mia Chloe Milo Dean),
               &%{id: &1, name: &1}
             )

    assert Enum.sum(Enum.map(@recipes, fn {_, rows} -> length(rows) end)) == 32
  end

  for row <- @recipes["config"] do
    @row row
    test "source configuration #{@row["id"]}" do
      assert Xiaomi.resolve_config(@row["input"]["rawConfig"]) == canonical(@row["expected"])
    end
  end

  for row <- @recipes["synthesis"] do
    @row row
    test "source wire and real ordinary service #{@row["id"]}" do
      input = @row["input"]
      expected = @row["expected"]
      config = Xiaomi.resolve_config(%{"providers" => %{"xiaomi" => input["providerConfig"]}})

      request = %{
        text: input["text"],
        target: if(input["target"] == "voice-note", do: :voice_note, else: :audio_file),
        timeout_ms: input["timeoutMs"],
        deadline_ms: System.monotonic_time(:millisecond) + 90_000,
        provider_overrides: input["providerOverrides"] || %{}
      }

      assert {:ok, built} = Xiaomi.build_request(request, config)
      assert built.url == expected["request"]["url"]
      assert built.body == expected["request"]["init"]["body"]
      assert built.timeout_ms == expected["request"]["timeoutMs"]
      assert {"api-key", "fixture-xiaomi-speech"} in built.headers
      assert {"content-type", "application/json"} in built.headers

      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()
      path = URI.parse(built.url).path
      prefix = String.replace_suffix(path, "/chat/completions", "")
      note? = request.target == :voice_note
      format = built.body["audio"]["format"]
      response = bound_response(@row, format)

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == expected["request"]["init"]["body"]
        assert Plug.Conn.get_req_header(conn, "api-key") == ["fixture-xiaomi-speech"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        send(owner, {:xiaomi_http_completed, @row["id"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      endpoint = String.trim_trailing(Gaoxy.Test.url(fixture, "/"), "/") <> prefix
      config = config |> Map.put(:base_url, endpoint) |> Map.put(:max_bytes, 65_536)
      links_before = links()
      ports_before = owned_ports()
      temp_before = temp_paths()

      output =
        if note? do
          task =
            Task.async(fn ->
              receive do
                :synthesize -> Xiaomi.synthesize(request, config)
              end
            end)

          start_conversion_trace(task.pid)
          send(task.pid, :synthesize)
          Task.await(task, 80_000)
        else
          Xiaomi.synthesize(request, config)
        end

      assert {:ok, result} = output

      if note? do
        traces = finish_conversion_trace()

        assert [{bytes, options}] =
                 for(
                   {:trace, _, :call, {Opus, :transcode, [bytes, options]}} <- traces,
                   do: {bytes, options}
                 )

        assert bytes == media(format)
        assert Keyword.fetch!(options, :input_extension) == format
        assert Keyword.fetch!(options, :temp_prefix) == "tts-xiaomi-"
        assert Keyword.fetch!(options, :timeout_ms) === input["timeoutMs"]
        assert Keyword.fetch!(options, :deadline_ms) == request.deadline_ms

        assert Map.drop(result, [:audio]) ==
                 canonical(Map.delete(expected["result"], "audioBase64"))

        assert_opus(result.audio)
      else
        assert result == expected_result(expected["result"])
      end

      assert temp_paths() == temp_before
      assert owned_ports() == ports_before
      assert links() == links_before
      assert_receive {:xiaomi_http_completed, id}, 5_000
      assert id == @row["id"]
      refute_receive {:xiaomi_http_completed, _}, 20
    end
  end

  for {dialect, data} <- [
        {"unpadded", "AQIDBA"},
        {"ASCII whitespace", " A\tQ\nID BA==\r "},
        {"outer JS whitespace", "\uFEFF\u00A0AQIDBA==\u00A0\uFEFF"}
      ] do
    @dialect dialect
    @data data
    test "actual source successful base64 dialect #{@dialect} keeps first-choice bytes" do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()

      Gaoxy.Test.stub(fixture, "POST", "/custom/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "model" => "mimo-v2.5-tts",
                 "messages" => [
                   %{"role" => "assistant", "content" => "Ordinary line."}
                 ],
                 "audio" => %{"format" => "mp3", "voice" => "mimo_default"}
               }

        send(owner, :base64_xiaomi_request)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"audio" => %{"data" => @data}}},
              %{"message" => %{"audio" => %{"data" => "BQYHCA=="}}}
            ]
          })
        )
      end)

      config = %{
        api_key: "fixture",
        base_url: Gaoxy.Test.url(fixture, "/custom"),
        max_bytes: 65_536
      }

      assert {:ok, result} =
               Xiaomi.synthesize(
                 %{text: "Ordinary line.", target: :audio_file, timeout_ms: 21_000},
                 config
               )

      assert result == %{
               audio: <<1, 2, 3, 4>>,
               output_format: "mp3",
               file_extension: ".mp3",
               voice_compatible: false
             }

      assert_receive :base64_xiaomi_request, 5_000
      refute_receive :base64_xiaomi_request, 20
    end
  end

  test "positive blank aliases retain saved style and custom values with JS trim" do
    config =
      Xiaomi.resolve_config(%{
        "providers" => %{
          "mimo" => %{
            "apiKey" => "fixture",
            "model" => " ",
            "modelId" => "\uFEFFcustom-model\u00A0",
            "speakerVoice" => " ",
            "speakerVoiceId" => "\u00A0Custom Voice\uFEFF",
            "style" => " Saved style ",
            "format" => " WAV "
          }
        }
      })

    assert config.model == "custom-model"
    assert config.voice == "Custom Voice"

    request = %{
      text: "Exact line.",
      target: :audio_file,
      timeout_ms: 21_123.75,
      provider_overrides: %{"model" => " ", "modelId" => " custom-model-2 ", "style" => " "}
    }

    assert {:ok, built} = Xiaomi.build_request(request, Map.put(config, :timeout_ms, 60_000))
    assert built.timeout_ms == 21_123
    assert request.timeout_ms === 21_123.75

    assert built.body == %{
             "model" => "custom-model-2",
             "messages" => [
               %{"role" => "user", "content" => "Saved style"},
               %{"role" => "assistant", "content" => "Exact line."}
             ],
             "audio" => %{"format" => "wav", "voice" => "Custom Voice"}
           }
  end

  for format <- ~w(mp3 wav) do
    @format format
    test "shared actual #{@format} conversion owns one task Port and cleanup" do
      Code.ensure_loaded!(Opus)
      flags = Process.info(self(), :trap_exit)
      ports_before = owned_ports()
      temp_before = temp_paths()

      assert :erlang.trace_pattern({:erlang, :open_port, 2}, [{:_, [], [{:return_trace}]}], [
               :local
             ]) == 1

      on_exit(fn -> :erlang.trace_pattern({:erlang, :open_port, 2}, false, [:local]) end)
      supervisor = Process.whereis(Synapsis.Provider.TaskSupervisor)
      :erlang.trace(supervisor, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])
      on_exit(fn -> :erlang.trace(supervisor, false, [:call, :procs, :set_on_spawn]) end)

      assert {:ok, opus} =
               Opus.transcode(media(@format),
                 input_extension: @format,
                 temp_prefix: "tts-xiaomi-",
                 timeout_ms: 30_000.75,
                 deadline_ms: System.monotonic_time(:millisecond) + 35_000,
                 max_bytes: 65_536
               )

      barrier = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^barrier}, 5_000
      traces = codec_traces([])

      assert [{owner, {:spawn_executable, executable}, settings}] =
               for(
                 {:trace, pid, :call, {:erlang, :open_port, [name, settings]}} <- traces,
                 do: {pid, name, settings}
               )

      assert Path.basename(to_string(executable)) == "ffmpeg"

      assert [
               "-hide_banner",
               "-loglevel",
               "error",
               "-y",
               "-i",
               input,
               "-vn",
               "-sn",
               "-dn",
               "-c:a",
               "libopus",
               "-b:a",
               "64k",
               "-ar",
               "48000",
               "-ac",
               "1",
               "-f",
               "opus",
               output
             ] = Enum.map(Keyword.fetch!(settings, :args), &to_string/1)

      assert Path.basename(input) == "input." <> @format
      assert Path.basename(output) == "voice.opus"
      assert Path.dirname(input) == Path.dirname(output)
      assert String.starts_with?(Path.basename(Path.dirname(input)), "tts-xiaomi-")
      refute File.exists?(Path.dirname(input))

      assert [port] =
               for(
                 {:trace, ^owner, :return_from, {:erlang, :open_port, 2}, port} <- traces,
                 do: port
               )

      assert Port.info(port) == nil
      refute Process.alive?(owner)
      assert Process.info(self(), :trap_exit) == flags
      assert owned_ports() == ports_before
      assert temp_paths() == temp_before
      :erlang.trace(supervisor, false, [:call, :procs, :set_on_spawn])
      :erlang.trace_pattern({:erlang, :open_port, 2}, false, [:local])
      assert_opus(opus)
    end
  end

  defp bound_response(row, format) do
    if row["input"]["target"] == "voice-note" do
      encoded = @media[format]["base64"]
      # Keep unpadded and ASCII-whitespace dialect binding independently explicit.
      encoded =
        case row["id"] do
          id when id in ["ordinary-mp3-voice-note", "design-mp3-voice-note"] ->
            String.trim_trailing(encoded, "=")

          id
          when id in [
                 "design-wav-voice-note",
                 "custom-prefix-model-voice-style-exact-text-first-choice"
               ] ->
            <<head::binary-size(8), tail::binary>> = encoded
            " " <> head <> "\t\n" <> tail <> "\r "

          _ ->
            encoded
        end

      [first | rest] = row["response"]["json"]["choices"]
      first = put_in(first, ["message", "audio", "data"], encoded)
      Map.put(row["response"]["json"], "choices", [first | rest])
    else
      row["response"]["json"]
    end
  end

  defp media(format) do
    fixture = @media[format]
    bytes = Base.decode64!(fixture["base64"])
    assert byte_size(bytes) == fixture["bytes"]
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == fixture["sha256"]
    bytes
  end

  defp start_conversion_trace(caller) do
    Code.ensure_loaded!(Opus)
    :erlang.trace_pattern({Opus, :transcode, 2}, true, [:local])
    supervisor = Process.whereis(Synapsis.Provider.TaskSupervisor)
    :erlang.trace(supervisor, true, [:call, :set_on_spawn, {:tracer, self()}])
    :erlang.trace(caller, true, [:call, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({Opus, :transcode, 2}, false, [:local])
      :erlang.trace(supervisor, false, [:call, :set_on_spawn])
    end)
  end

  defp finish_conversion_trace do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000

    :erlang.trace(Process.whereis(Synapsis.Provider.TaskSupervisor), false, [:call, :set_on_spawn])

    :erlang.trace_pattern({Opus, :transcode, 2}, false, [:local])
    codec_traces([])
  end

  defp codec_traces(acc) do
    receive do
      {:trace, _, _, _} = event -> codec_traces([event | acc])
      {:trace, _, _, _, _} = event -> codec_traces([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp expected_result(raw),
    do:
      raw
      |> Map.delete("audioBase64")
      |> canonical()
      |> Map.put(:audio, Base.decode64!(raw["audioBase64"]))

  defp canonical(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {field(k), canonical(v)} end)

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp field(key),
    do:
      %{
        "apiKey" => :api_key,
        "baseUrl" => :base_url,
        "outputFormat" => :output_format,
        "fileExtension" => :file_extension,
        "voiceCompatible" => :voice_compatible,
        "model" => :model,
        "voice" => :voice,
        "format" => :format,
        "style" => :style
      }[key]

  defp links, do: self() |> Process.info(:links) |> elem(1) |> MapSet.new()
  defp temp_paths, do: Path.wildcard(Path.join(System.tmp_dir!(), "tts-xiaomi-*")) |> MapSet.new()

  defp owned_ports,
    do:
      :erlang.ports()
      |> Enum.filter(&(Port.info(&1, :connected) == {:connected, self()}))
      |> MapSet.new()

  defp assert_opus(bytes) do
    assert <<"OggS", _::binary>> = bytes
    assert :binary.match(bytes, "OpusHead") != :nomatch

    root =
      Path.join(System.tmp_dir!(), "xiaomi-test-decode-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    try do
      path = Path.join(root, "voice.opus")
      File.write!(path, bytes)

      probe =
        port_output(executable!("ffprobe"), [
          "-v",
          "error",
          "-show_entries",
          "stream=codec_name,sample_rate,channels",
          "-of",
          "json",
          path
        ])
        |> Jason.decode!()

      assert [stream] = probe["streams"]

      assert Map.take(stream, ~w(codec_name sample_rate channels)) == %{
               "codec_name" => "opus",
               "sample_rate" => "48000",
               "channels" => 1
             }

      decoded =
        port_output(executable!("ffmpeg"), [
          "-v",
          "error",
          "-i",
          path,
          "-f",
          "s16le",
          "-ac",
          "1",
          "-ar",
          "48000",
          "pipe:1"
        ])

      assert byte_size(decoded) in 9_000..10_600
      samples = for <<sample::little-signed-16 <- decoded>>, do: abs(sample)
      assert Enum.max(samples) > 5_000
    after
      File.rm_rf!(root)
    end
  end

  defp executable!(name),
    do:
      System.find_executable(name) ||
        flunk("BLOCKED_ENV: #{name} required for ordinary codec proof")

  defp port_output(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args
      ])

    try do
      collect_port(port, System.monotonic_time(:millisecond) + 15_000, [])
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_port(port, deadline, parts) do
    receive do
      {^port, {:data, data}} -> collect_port(port, deadline, [data | parts])
      {^port, {:exit_status, 0}} -> IO.iodata_to_binary(Enum.reverse(parts))
      {^port, {:exit_status, status}} -> flunk("ordinary codec process exited #{status}")
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("ordinary codec process did not finish")
    end
  end
end
