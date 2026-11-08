// Independent Xiaomi ordinary oracle. Inputs and expected literals were authored from pinned source before execution.
// Synthetic HTTP/media/secret/policy boundaries do not establish supplier, codec, credentials or host behavior.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { captureXiaomiSpeech, XIAOMI_SPEECH_CASES, XIAOMI_SPEECH_PIN, XIAOMI_SPEECH_SOURCE } from './capture-xiaomi-speech.mjs';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/xiaomi-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const sourceRoot = '/tmp/openclaw-488631c';
const inputs = {
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
      }
    }
  ],
  "voices": [
    {
      "id": "voices-static-seven-ordered",
      "input": {}
    }
  ]
};
const expected = {
  "config": {
    "config-canonical-defaults": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "mimo_default",
      "format": "mp3"
    },
    "config-mimo-complete": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://Alias.Example/tenant/v2",
      "model": "custom-mimo",
      "voice": "Custom Voice",
      "format": "wav",
      "style": "轻柔、清晰。"
    },
    "config-canonical-whole-object-precedence": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "mimo_default",
      "format": "mp3"
    },
    "config-model-primary-and-voice-alias-precedence": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "Mia",
      "format": "mp3"
    },
    "config-speakerVoice": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "default_zh",
      "format": "mp3"
    },
    "config-speakerVoiceId-before-voice": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "Chloe",
      "format": "mp3"
    },
    "config-voice-before-voiceId": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "Milo",
      "format": "mp3"
    },
    "config-voiceId": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts",
      "voice": "Dean",
      "format": "mp3"
    },
    "config-modelId-design-wav-style": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://api.xiaomimimo.com/v1",
      "model": "mimo-v2.5-tts-voicedesign",
      "voice": "mimo_default",
      "format": "wav",
      "style": "A bright storyteller."
    },
    "config-custom-base-model-voice": {
      "apiKey": "fixture-xiaomi-speech",
      "baseUrl": "https://Custom.Example/api/prefix",
      "model": "experimental-tts-v9",
      "voice": "My Custom Voice",
      "format": "mp3",
      "style": "Gentle\nclear"
    }
  },
  "synthesis": {
    "ordinary-mp3-audio-file": {
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
    },
    "ordinary-mp3-voice-note": {
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
    },
    "ordinary-wav-audio-file": {
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
    },
    "ordinary-wav-voice-note": {
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
    },
    "design-mp3-audio-file": {
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
    },
    "design-mp3-voice-note": {
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
    },
    "design-wav-audio-file": {
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
    },
    "design-wav-voice-note": {
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
    },
    "override-speakerVoice": {
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
    },
    "override-speakerVoiceId-before-voice": {
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
    },
    "override-voice-before-voiceId": {
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
    },
    "override-voiceId": {
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
    },
    "override-model-and-all-voice-alias-precedence": {
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
    },
    "override-modelId": {
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
    },
    "override-into-voice-design": {
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
    },
    "override-out-of-voice-design": {
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
    },
    "custom-prefix-model-voice-style-exact-text-first-choice": {
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
    },
    "ordinary-config-style": {
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
    },
    "ordinary-override-style": {
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
    },
    "design-config-style": {
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
    },
    "design-override-style": {
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
  },
  "voices": {
    "voices-static-seven-ordered": [
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
};
const metadata = {
  id: 'xiaomi', label: 'Xiaomi MiMo', aliases: ['mimo'], autoSelectOrder: 45,
  defaultModel: 'mimo-v2.5-tts',
  models: ['mimo-v2.5-tts', 'mimo-v2.5-tts-voicedesign'],
  voices: ['mimo_default', 'default_zh', 'default_en', 'Mia', 'Chloe', 'Milo', 'Dean'],
};
const callbacks = ['resolveConfig', 'parseDirectiveToken', 'listVoices', 'isConfigured', 'isConfiguredAsync', 'synthesize'];
const groups = { config: 'configObservations', synthesis: 'observations', voices: 'voiceObservations' };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const moduleHashes = {
  'extensions/xiaomi/speech-provider.ts': '09f7d68df2a8f1a4887be97a19a475f23a9fe3ac4679d0a0247089fcd1e0b369',
  'src/tts/tts-provider-helpers.ts': '1f1425d541d933324b9cafc5135997487d26d9ff1638b2dd7b653498f5357747',
  'src/tts/directive-parser.ts': '5f629cc79bf82a2783885fbf97e87d87045c01b852298ba9e781c5b996c48329',
  'src/tts/directive-number.ts': '9d87677afe48ecc851ca209efdb820ef3c191b642a5e9c4f8b483cef57aaed4a',
  'packages/normalization-core/src/string-coerce.ts': '0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf',
  'packages/normalization-core/src/record-coerce.ts': '541c179840c2cad4edc5c8103f77cc7f8c6b1ee5ec3e52c7c9fe097b18917f1c',
  'packages/normalization-core/src/number-coercion.ts': '8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4',
  'packages/media-core/src/base64.ts': '93e6ef481601a3bee0a6cbd304506a0b1ab4e1e05d363be78a00ebe7b63173ac',
  'src/plugin-sdk/blob-runtime.ts': '73551b7bf55cb99a9054e8e3642666b043a739fd7c86d9c4c513d564ba432b20',
};
const secretCall = value => ({ module: 'openclaw/plugin-sdk/secret-input', export: 'normalizeResolvedSecretInputString',
  path: 'tts.providers.xiaomi.apiKey', value });
const requestCall = (name, details) => ({ module: 'openclaw/plugin-sdk/ssrf-runtime', export: name, ...details });
const responseCall = (name, label) => ({ module: 'openclaw/plugin-sdk/provider-http', export: name, status: 200, label });

test('independent input inventory, literal metadata and exact positive observation counts', () => {
  assert.deepEqual(XIAOMI_SPEECH_CASES, inputs);
  assert.equal(XIAOMI_SPEECH_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(XIAOMI_SPEECH_SOURCE, 'extensions/xiaomi/speech-provider.ts');
  assert.equal(fixture.referencePin, XIAOMI_SPEECH_PIN);
  assert.deepEqual(fixture.providerMetadata, metadata);
  assert.deepEqual(fixture.providerCallbacks, callbacks);
  assert.equal(fixture.counts.totalObservations, 32);
  assert.equal(fixture.counts.httpRequests, 21);
  assert.equal(fixture.counts.releases, 21);
  assert.equal(fixture.counts.transcodes, 5);
  for (const [kind, field] of Object.entries(groups)) {
    assert.deepEqual(fixture[field].map(row => row.id), inputs[kind].map(row => row.id));
  }
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
      const exp = expected[kind][recipe.id];
      if (kind === 'synthesis') {
        assert.deepEqual(observation.synthesisRequest, recipe.input);
        assert.deepEqual(observation.synthesisRequestAfter, recipe.input);
        assert.deepEqual(observation.response, recipe.response);
        assert.deepEqual(observation.result, exp.result);
        assert.deepEqual(observation.requests, [exp.request]);
        assert.equal(observation.releaseCount, 1);
        assert.deepEqual(observation.transcodes, exp.transcodes);
        const calls = [
          secretCall(recipe.input.providerConfig.apiKey),
          requestCall('ssrfPolicyFromHttpBaseUrlAllowedHostname', { url: exp.request.url.slice(0, -'/chat/completions'.length) }),
          requestCall('fetchWithSsrFGuard', { requestIndex: 0 }),
          responseCall('assertOkOrThrowProviderError', 'Xiaomi TTS API error'),
          responseCall('readProviderJsonResponse', 'Xiaomi TTS API'),
          requestCall('release', { requestIndex: 0 }),
          ...exp.transcodes.map(details => ({ module: 'openclaw/plugin-sdk/media-runtime', export: 'transcodeAudioBufferToOpus', ...details })),
        ];
        assert.deepEqual(observation.platformCalls, calls);
      } else {
        assert.deepEqual(observation.result, exp);
        assert.deepEqual(observation.requests, []);
        assert.equal(observation.releaseCount, 0);
        assert.deepEqual(observation.transcodes, []);
        const explicitConfig = kind === 'config'
          ? recipe.input.rawConfig.providers.xiaomi ?? recipe.input.rawConfig.providers.mimo : undefined;
        assert.deepEqual(observation.platformCalls, kind === 'config' ? [secretCall(explicitConfig.apiKey)] : []);
      }
    });
  }
}
test('nine complete original modules match independent literal hashes and immutable tracked58558 checkout', () => {
  assert.equal(fixture.checkout.before.verified, true);
  assert.equal(fixture.checkout.after.verified, true);
  assert.equal(fixture.checkout.before.verifiedTrackedFiles, 58558);
  assert.equal(fixture.checkout.after.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.checkout.after, fixture.checkout.before);
  assert.equal(fixture.sourceAudit.length, 9);
  assert.equal(fixture.counts.wholeModules, 9);
  assert.equal(fixture.counts.trackedFilesBefore, 58558);
  assert.equal(fixture.counts.trackedFilesAfter, 58558);
  assert.deepEqual(fixture.sourceAudit.map(row => row.path).sort(), Object.keys(moduleHashes).sort());
  for (const row of fixture.sourceAudit) {
    assert.equal(row.sourceSha256, moduleHashes[row.path]);
    assert.equal(hash(readFileSync(join(sourceRoot, row.path))), moduleHashes[row.path]);
    const pinned = execFileSync('git', ['-C', sourceRoot, 'show', `${XIAOMI_SPEECH_PIN}:${row.path}`], { timeout: 30000 });
    assert.equal(hash(pinned), moduleHashes[row.path]);
    assert.equal(row.sourceBytes, pinned.length);
    assert.equal(row.wholeModule, true);
    assert.equal(row.executed, true);
  }
});
test('fresh VM and fresh CLI preserve the full fixture JSON', async () => {
  assert.deepEqual(await captureXiaomiSpeech(sourceRoot), fixture);
  const dir = mkdtempSync(join(tmpdir(), 'xiaomi337-oracle-'));
  try {
    const output = join(dir, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules', 'scripts/openclaw/capture-xiaomi-speech.mjs',
      '--source-root', sourceRoot, '--output', output], { timeout: 60000, stdio: 'pipe' });
    assert.deepEqual(JSON.parse(readFileSync(output, 'utf8')), fixture);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
