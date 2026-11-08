// Independent literal Google Speech oracle authored from full pinned originals before execution.
// Only ordinary success; credential/policy header fields stay provenance, no auth/security tests.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { captureGoogleSpeech, GOOGLE_SPEECH_CASES, GOOGLE_SPEECH_PIN, GOOGLE_SPEECH_SOURCE } from './capture-google-speech.mjs';
const fixturePath = 'apps/synapsis_agent/test/fixtures/openclaw/488631c/google-speech.json';
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const sourceRoot = '/tmp/openclaw-488631c';
const inputs = {
  "config": [
    {
      "id": "config-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech"
            }
          }
        }
      }
    },
    {
      "id": "config-model-gemini-3.8-flash-tts",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-3.8-flash-tts "
            }
          }
        }
      }
    },
    {
      "id": "config-model-gemini-3.8-flash-lite-tts",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-3.8-flash-lite-tts "
            }
          }
        }
      }
    },
    {
      "id": "config-model-gemini-3.1-flash-tts-preview",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-3.1-flash-tts-preview "
            }
          }
        }
      }
    },
    {
      "id": "config-model-gemini-2.5-flash-preview-tts",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-2.5-flash-preview-tts "
            }
          }
        }
      }
    },
    {
      "id": "config-model-gemini-2.5-pro-preview-tts",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-2.5-pro-preview-tts "
            }
          }
        }
      }
    },
    {
      "id": "config-alias-rich",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " google/gemini-3.1-flash-tts ",
              "voice": " Puck ",
              "baseUrl": " https://generativelanguage.googleapis.com/v1beta/// ",
              "audioProfile": " Warm ",
              "speakerName": " Guide ",
              "promptTemplate": " audio-profile-v1 ",
              "personaPrompt": " Speak clearly "
            }
          }
        }
      }
    },
    {
      "id": "config-dialogue-aliases",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts",
              "voiceName": " Zephyr ",
              "voice": "Kore",
              "speakers": [
                {
                  "speaker": " Puck ",
                  "voice": " Puck ",
                  "style": " Bright "
                },
                {
                  "name": " Kore ",
                  "voiceName": " Kore ",
                  "style": " Gentle "
                }
              ]
            }
          }
        }
      }
    },
    {
      "id": "config-unicode",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": " ﻿google/gemini-3.1-flash-tts﻿ ",
              "voiceName": " ﻿Kore﻿ "
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
        "baseTtsConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech"
            }
          }
        },
        "talkProviderConfig": {}
      }
    },
    {
      "id": "talk-overlay",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "audioProfile": " Warm ",
              "speakerName": " Guide ",
              "promptTemplate": "audio-profile-v1",
              "personaPrompt": " Calm "
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": " fixture-google-talk ",
          "baseUrl": " https://generativelanguage.googleapis.com/ ",
          "modelId": " google/gemini-3.8-flash-lite-tts ",
          "voiceId": " Zephyr "
        }
      }
    },
    {
      "id": "talk-inherit",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts",
              "voiceName": "Puck",
              "speakers": [
                {
                  "speaker": " Puck ",
                  "voice": " Puck ",
                  "style": " Bright "
                },
                {
                  "name": " Kore ",
                  "voiceName": " Kore ",
                  "style": " Gentle "
                }
              ]
            }
          }
        },
        "talkProviderConfig": {
          "modelId": " ",
          "voiceId": " ",
          "baseUrl": " "
        }
      }
    },
    {
      "id": "talk-alias",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech"
            }
          }
        },
        "talkProviderConfig": {
          "modelId": "google/gemini-3.1-flash-tts",
          "voiceId": " Aoede "
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
      "id": "talk-overrides-both",
      "input": {
        "params": {
          "voiceId": " Puck ",
          "modelId": " google/gemini-3.8-flash-tts "
        }
      }
    },
    {
      "id": "talk-overrides-alias",
      "input": {
        "params": {
          "modelId": " google/gemini-3.1-flash-tts "
        }
      }
    },
    {
      "id": "talk-overrides-voice",
      "input": {
        "params": {
          "voiceId": " Kore "
        }
      }
    }
  ],
  "prepare": [
    {
      "id": "prepare-plain",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech"
            }
          }
        },
        "text": "Hello plain."
      }
    },
    {
      "id": "prepare-profile-label",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "promptTemplate": "audio-profile-v1",
              "personaPrompt": " Warm\r\nClear\u0001 "
            }
          }
        },
        "text": " Hello\r\nworld. ",
        "persona": {
          "label": " Narrator\u0002 ",
          "id": "ignored"
        }
      }
    },
    {
      "id": "prepare-persona-id",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "personaPrompt": " Be calm "
            }
          }
        },
        "text": " A quiet line. ",
        "persona": {
          "id": " Assistant "
        }
      }
    },
    {
      "id": "prepare-template-only",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "promptTemplate": "audio-profile-v1"
            }
          }
        },
        "text": " Hello template. "
      }
    },
    {
      "id": "prepare-already-wrapped",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "promptTemplate": "audio-profile-v1",
              "personaPrompt": "Different"
            }
          }
        },
        "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."
      }
    },
    {
      "id": "prepare-interactions-unwrap",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts"
            }
          }
        },
        "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."
      }
    },
    {
      "id": "prepare-interactions-plain",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts",
              "personaPrompt": "Calm"
            }
          }
        },
        "text": "Read this verbatim."
      }
    },
    {
      "id": "prepare-override-interactions",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "promptTemplate": "audio-profile-v1"
            }
          }
        },
        "providerOverrides": {
          "model": "gemini-3.8-flash-lite-tts"
        },
        "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."
      }
    }
  ],
  "synthesis": [
    {
      "id": "synthesize-gemini-3.8-flash-tts-file",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "output_audio": {
            "data": "AAD/fwCA//8="
          }
        }
      }
    },
    {
      "id": "synthesize-gemini-3.8-flash-tts-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "output_audio": {
            "data": "AAD/fwCA//8="
          }
        },
        "transcodeAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
      }
    },
    {
      "id": "synthesize-gemini-3.8-flash-lite-tts-file",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "output_audio": {
            "data": "AAD/fwCA//8="
          }
        }
      }
    },
    {
      "id": "synthesize-gemini-3.8-flash-lite-tts-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "output_audio": {
            "data": "AAD/fwCA//8="
          }
        },
        "transcodeAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
      }
    },
    {
      "id": "synthesize-gemini-3.1-flash-tts-preview-file",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.1-flash-tts-preview"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "synthesize-gemini-3.1-flash-tts-preview-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.1-flash-tts-preview"
            }
          }
        },
        "text": "Hello Google.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        },
        "transcodeAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
      }
    },
    {
      "id": "synthesize-gemini-2.5-flash-preview-tts-file",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-flash-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "synthesize-gemini-2.5-flash-preview-tts-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-flash-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        },
        "transcodeAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
      }
    },
    {
      "id": "synthesize-gemini-2.5-pro-preview-tts-file",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-pro-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "synthesize-gemini-2.5-pro-preview-tts-voice-note",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-pro-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "voice-note",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        },
        "transcodeAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
      }
    },
    {
      "id": "generate-alias-overrides",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "google/gemini-3.1-flash-tts",
              "voiceName": "Puck",
              "audioProfile": " Warm ",
              "speakerName": " Guide "
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345,
        "providerOverrides": {
          "voice": " Zephyr ",
          "audioProfile": " Bright ",
          "speakerName": " Narrator "
        }
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "first candidate"
                  }
                ]
              }
            },
            {
              "content": {
                "parts": [
                  {
                    "inline_data": {
                      "data": " -_8AAQ==\n"
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "generate-custom-model",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "fixture-custom-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8"
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "generate-wav-strip",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-flash-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "first candidate"
                  }
                ]
              }
            },
            {
              "content": {
                "parts": [
                  {
                    "inline_data": {
                      "data": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "generate-odd-chunk-strip",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-pro-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "interactions-single-style",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts",
              "voice": " Aoede ",
              "audioProfile": " Warm ",
              "speakerName": " Narrator ",
              "personaPrompt": " Calm "
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "outputAudio": {
            "data": "-_8AAQ"
          }
        }
      }
    },
    {
      "id": "interactions-dialogue",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts",
              "speakers": [
                {
                  "speaker": " Puck ",
                  "voice": " Puck ",
                  "style": " Bright "
                },
                {
                  "name": " Kore ",
                  "voiceName": " Kore ",
                  "style": " Gentle "
                }
              ],
              "audioProfile": " Warm ",
              "personaPrompt": " Clear "
            }
          }
        },
        "text": "Intro before label.\r\nKore:Hello.\nKore:Again.\nBudget: 10 dollars\nPuck: Welcome.\nContinuation.\nPuck:\nKore: Bye.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "steps": [
            {
              "content": [
                {
                  "type": "text",
                  "data": "spoken metadata"
                },
                {
                  "type": "audio",
                  "data": "UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                }
              ]
            }
          ]
        }
      }
    },
    {
      "id": "interactions-lite-dialogue",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts",
              "speakers": [
                {
                  "speaker": " Puck ",
                  "voice": " Puck ",
                  "style": " Bright "
                },
                {
                  "name": " Kore ",
                  "voiceName": " Kore ",
                  "style": " Gentle "
                }
              ]
            }
          }
        },
        "text": "Puck: First.\nKore: Second.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "steps": [
            {
              "content": [
                {
                  "mime_type": "audio/l16",
                  "data": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                }
              ]
            }
          ]
        }
      }
    },
    {
      "id": "interactions-speakers-unlabeled",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts",
              "speakers": [
                {
                  "speaker": " Puck ",
                  "voice": " Puck ",
                  "style": " Bright "
                },
                {
                  "name": " Kore ",
                  "voiceName": " Kore ",
                  "style": " Gentle "
                }
              ]
            }
          }
        },
        "text": "An unlabeled single utterance.",
        "target": "file",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "steps": [
            {
              "content": [
                {
                  "mimeType": "audio/l16",
                  "data": "AAD/fwCA//8="
                }
              ]
            }
          ]
        }
      }
    },
    {
      "id": "request-source-normalization",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.1-flash-tts-preview",
              "baseUrl": " https://generativelanguage.googleapis.com/v1beta/openai/// "
            }
          }
        },
        "text": "Hello Google.",
        "target": "file",
        "timeoutMs": 12345,
        "cfg": {
          "models": {
            "providers": {
              "google": {
                "request": {
                  "headers": {
                    "X-Fixture": " trace-google "
                  }
                }
              }
            }
          }
        }
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    }
  ],
  "telephony": [
    {
      "id": "telephony-generate-pcm",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.1-flash-tts-preview"
            }
          }
        },
        "text": "Hello Google.",
        "target": "telephony",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "synthetic metadata"
                  },
                  {
                    "inlineData": {
                      "mimeType": "audio/L16",
                      "data": "AAD/fwCA//8="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "telephony-generate-wav",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-2.5-flash-preview-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "telephony",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "first candidate"
                  }
                ]
              }
            },
            {
              "content": {
                "parts": [
                  {
                    "inline_data": {
                      "data": "UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "id": "telephony-interactions-pcm",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "telephony",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "outputAudio": {
            "data": "-_8AAQ=="
          }
        }
      }
    },
    {
      "id": "telephony-interactions-wav",
      "input": {
        "rawConfig": {
          "providers": {
            "google": {
              "apiKey": "fixture-google-speech",
              "model": "gemini-3.8-flash-lite-tts"
            }
          }
        },
        "text": "Hello Google.",
        "target": "telephony",
        "timeoutMs": 12345
      },
      "response": {
        "json": {
          "steps": [
            {
              "content": [
                {
                  "type": "text",
                  "data": "spoken metadata"
                },
                {
                  "type": "audio",
                  "data": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
                }
              ]
            }
          ]
        }
      }
    }
  ],
  "voices": [
    {
      "id": "voices-static",
      "input": {}
    }
  ]
};
const expected = {
  "config": {
    "config-defaults": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Kore"
    },
    "config-model-gemini-3.8-flash-tts": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.8-flash-tts",
      "voiceName": "Kore"
    },
    "config-model-gemini-3.8-flash-lite-tts": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.8-flash-lite-tts",
      "voiceName": "Kore"
    },
    "config-model-gemini-3.1-flash-tts-preview": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Kore"
    },
    "config-model-gemini-2.5-flash-preview-tts": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-2.5-flash-preview-tts",
      "voiceName": "Kore"
    },
    "config-model-gemini-2.5-pro-preview-tts": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-2.5-pro-preview-tts",
      "voiceName": "Kore"
    },
    "config-alias-rich": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Puck",
      "baseUrl": "https://generativelanguage.googleapis.com/v1beta///",
      "audioProfile": "Warm",
      "speakerName": "Guide",
      "promptTemplate": "audio-profile-v1",
      "personaPrompt": "Speak clearly"
    },
    "config-dialogue-aliases": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.8-flash-tts",
      "voiceName": "Zephyr",
      "speakers": [
        {
          "speaker": "Puck",
          "voice": "Puck",
          "style": "Bright"
        },
        {
          "speaker": "Kore",
          "voice": "Kore",
          "style": "Gentle"
        }
      ]
    },
    "config-unicode": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Kore"
    }
  },
  "talkConfig": {
    "talk-defaults": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Kore"
    },
    "talk-overlay": {
      "apiKey": "fixture-google-talk",
      "model": "gemini-3.8-flash-lite-tts",
      "voiceName": "Zephyr",
      "baseUrl": "https://generativelanguage.googleapis.com/",
      "audioProfile": "Warm",
      "speakerName": "Guide",
      "promptTemplate": "audio-profile-v1",
      "personaPrompt": "Calm"
    },
    "talk-inherit": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.8-flash-tts",
      "voiceName": "Puck",
      "speakers": [
        {
          "speaker": "Puck",
          "voice": "Puck",
          "style": "Bright"
        },
        {
          "speaker": "Kore",
          "voice": "Kore",
          "style": "Gentle"
        }
      ]
    },
    "talk-alias": {
      "apiKey": "fixture-google-speech",
      "model": "gemini-3.1-flash-tts-preview",
      "voiceName": "Aoede"
    }
  },
  "talkOverride": {
    "talk-overrides-empty": {},
    "talk-overrides-both": {
      "voiceName": "Puck",
      "model": "gemini-3.8-flash-tts"
    },
    "talk-overrides-alias": {
      "model": "gemini-3.1-flash-tts-preview"
    },
    "talk-overrides-voice": {
      "voiceName": "Kore"
    }
  },
  "prepare": {
    "prepare-plain": null,
    "prepare-profile-label": {
      "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm\nClear\n\n### TRANSCRIPT\nHello\nworld."
    },
    "prepare-persona-id": {
      "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Assistant\n\n### DIRECTOR'S NOTES\nProvider notes:\nBe calm\n\n### TRANSCRIPT\nA quiet line."
    },
    "prepare-template-only": {
      "text": "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n### TRANSCRIPT\nHello template."
    },
    "prepare-already-wrapped": null,
    "prepare-interactions-unwrap": {
      "text": "Hello there.\n\n### TRANSCRIPT\nSpoken delimiter."
    },
    "prepare-interactions-plain": null,
    "prepare-override-interactions": {
      "text": "Hello there.\n\n### TRANSCRIPT\nSpoken delimiter."
    }
  },
  "synthesis": {
    "synthesize-gemini-3.8-flash-tts-file": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "synthesize-gemini-3.8-flash-tts-voice-note": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "T2dnUwBmaXh0dXJlLW9wdXM=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      },
      "transcodes": [
        {
          "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
          "inputExtension": "wav",
          "tempPrefix": "tts-google-",
          "timeoutMs": 12345,
          "outputAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
        }
      ]
    },
    "synthesize-gemini-3.8-flash-lite-tts-file": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-lite-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "synthesize-gemini-3.8-flash-lite-tts-voice-note": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-lite-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "T2dnUwBmaXh0dXJlLW9wdXM=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      },
      "transcodes": [
        {
          "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
          "inputExtension": "wav",
          "tempPrefix": "tts-google-",
          "timeoutMs": 12345,
          "outputAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
        }
      ]
    },
    "synthesize-gemini-3.1-flash-tts-preview-file": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "synthesize-gemini-3.1-flash-tts-preview-voice-note": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "T2dnUwBmaXh0dXJlLW9wdXM=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      },
      "transcodes": [
        {
          "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
          "inputExtension": "wav",
          "tempPrefix": "tts-google-",
          "timeoutMs": 12345,
          "outputAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
        }
      ]
    },
    "synthesize-gemini-2.5-flash-preview-tts-file": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "synthesize-gemini-2.5-flash-preview-tts-voice-note": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "T2dnUwBmaXh0dXJlLW9wdXM=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      },
      "transcodes": [
        {
          "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
          "inputExtension": "wav",
          "tempPrefix": "tts-google-",
          "timeoutMs": 12345,
          "outputAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
        }
      ]
    },
    "synthesize-gemini-2.5-pro-preview-tts-file": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "synthesize-gemini-2.5-pro-preview-tts-voice-note": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "T2dnUwBmaXh0dXJlLW9wdXM=",
        "outputFormat": "opus",
        "fileExtension": ".opus",
        "voiceCompatible": true
      },
      "transcodes": [
        {
          "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
          "inputExtension": "wav",
          "tempPrefix": "tts-google-",
          "timeoutMs": 12345,
          "outputAudioBase64": "T2dnUwBmaXh0dXJlLW9wdXM="
        }
      ]
    },
    "generate-alias-overrides": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Bright\n\nSpeaker name: Narrator\n\nHello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Zephyr"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAD7/wAB",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "generate-custom-model": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/fixture-custom-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "generate-wav-strip": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "generate-odd-chunk-strip": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "interactions-single-style": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google.",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Narrator",
                    "style": "Warm\n\nCalm"
                  }
                ]
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Aoede"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAD7/wAB",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "interactions-dialogue": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Intro before label. Hello. Again. Budget: 10 dollars",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Kore",
                    "style": "Gentle\n\nWarm\n\nClear"
                  }
                ]
              },
              {
                "type": "text",
                "text": "Welcome. Continuation.",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Puck",
                    "style": "Bright\n\nWarm\n\nClear"
                  }
                ]
              },
              {
                "type": "text",
                "text": "Bye.",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Kore",
                    "style": "Gentle\n\nWarm\n\nClear"
                  }
                ]
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": {
            "mode": "conversational",
            "speakers": [
              {
                "speaker": "Puck",
                "voice": "Puck"
              },
              {
                "speaker": "Kore",
                "voice": "Kore"
              }
            ]
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "interactions-lite-dialogue": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-lite-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "First.",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Puck",
                    "style": "Bright"
                  }
                ]
              },
              {
                "type": "text",
                "text": "Second.",
                "annotations": [
                  {
                    "type": "speech_metadata",
                    "speaker": "Kore",
                    "style": "Gentle"
                  }
                ]
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": {
            "mode": "conversational",
            "speakers": [
              {
                "speaker": "Puck",
                "voice": "Puck"
              },
              {
                "speaker": "Kore",
                "voice": "Kore"
              }
            ]
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "interactions-speakers-unlabeled": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-lite-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "An unlabeled single utterance."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    },
    "request-source-normalization": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==",
        "outputFormat": "wav",
        "fileExtension": ".wav",
        "voiceCompatible": false
      },
      "transcodes": []
    }
  },
  "telephony": {
    "telephony-generate-pcm": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "AAD/fwCA//8=",
        "outputFormat": "pcm",
        "sampleRate": 24000
      },
      "transcodes": []
    },
    "telephony-generate-wav": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent",
      "body": {
        "contents": [
          {
            "role": "user",
            "parts": [
              {
                "text": "Hello Google."
              }
            ]
          }
        ],
        "generationConfig": {
          "responseModalities": [
            "AUDIO"
          ],
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {
                "voiceName": "Kore"
              }
            }
          }
        }
      },
      "result": {
        "audioBase64": "AAD/fwCA//8=",
        "outputFormat": "pcm",
        "sampleRate": 24000
      },
      "transcodes": []
    },
    "telephony-interactions-pcm": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "+/8AAQ==",
        "outputFormat": "pcm",
        "sampleRate": 24000
      },
      "transcodes": []
    },
    "telephony-interactions-wav": {
      "url": "https://generativelanguage.googleapis.com/v1beta/interactions",
      "body": {
        "model": "gemini-3.8-flash-lite-tts",
        "store": false,
        "input": [
          {
            "type": "user_input",
            "content": [
              {
                "type": "text",
                "text": "Hello Google."
              }
            ]
          }
        ],
        "response_format": {
          "type": "audio",
          "mime_type": "audio/l16",
          "sample_rate": 24000
        },
        "generation_config": {
          "speech_config": [
            {
              "voice": "Kore"
            }
          ]
        }
      },
      "result": {
        "audioBase64": "AAD/fwCA//8=",
        "outputFormat": "pcm",
        "sampleRate": 24000
      },
      "transcodes": []
    }
  },
  "voices": {
    "voices-static": [
      {
        "id": "Zephyr",
        "name": "Zephyr"
      },
      {
        "id": "Puck",
        "name": "Puck"
      },
      {
        "id": "Charon",
        "name": "Charon"
      },
      {
        "id": "Kore",
        "name": "Kore"
      },
      {
        "id": "Fenrir",
        "name": "Fenrir"
      },
      {
        "id": "Leda",
        "name": "Leda"
      },
      {
        "id": "Orus",
        "name": "Orus"
      },
      {
        "id": "Aoede",
        "name": "Aoede"
      },
      {
        "id": "Callirrhoe",
        "name": "Callirrhoe"
      },
      {
        "id": "Autonoe",
        "name": "Autonoe"
      },
      {
        "id": "Enceladus",
        "name": "Enceladus"
      },
      {
        "id": "Iapetus",
        "name": "Iapetus"
      },
      {
        "id": "Umbriel",
        "name": "Umbriel"
      },
      {
        "id": "Algieba",
        "name": "Algieba"
      },
      {
        "id": "Despina",
        "name": "Despina"
      },
      {
        "id": "Erinome",
        "name": "Erinome"
      },
      {
        "id": "Algenib",
        "name": "Algenib"
      },
      {
        "id": "Rasalgethi",
        "name": "Rasalgethi"
      },
      {
        "id": "Laomedeia",
        "name": "Laomedeia"
      },
      {
        "id": "Achernar",
        "name": "Achernar"
      },
      {
        "id": "Alnilam",
        "name": "Alnilam"
      },
      {
        "id": "Schedar",
        "name": "Schedar"
      },
      {
        "id": "Gacrux",
        "name": "Gacrux"
      },
      {
        "id": "Pulcherrima",
        "name": "Pulcherrima"
      },
      {
        "id": "Achird",
        "name": "Achird"
      },
      {
        "id": "Zubenelgenubi",
        "name": "Zubenelgenubi"
      },
      {
        "id": "Vindemiatrix",
        "name": "Vindemiatrix"
      },
      {
        "id": "Sadachbia",
        "name": "Sadachbia"
      },
      {
        "id": "Sadaltager",
        "name": "Sadaltager"
      },
      {
        "id": "Sulafat",
        "name": "Sulafat"
      }
    ]
  }
};
const metadata = {
  "id": "google",
  "label": "Google",
  "autoSelectOrder": 50,
  "defaultModel": "gemini-3.1-flash-tts-preview",
  "models": [
    "gemini-3.8-flash-tts",
    "gemini-3.8-flash-lite-tts",
    "gemini-3.1-flash-tts-preview",
    "gemini-2.5-flash-preview-tts",
    "gemini-2.5-pro-preview-tts"
  ],
  "voices": [
    "Zephyr",
    "Puck",
    "Charon",
    "Kore",
    "Fenrir",
    "Leda",
    "Orus",
    "Aoede",
    "Callirrhoe",
    "Autonoe",
    "Enceladus",
    "Iapetus",
    "Umbriel",
    "Algieba",
    "Despina",
    "Erinome",
    "Algenib",
    "Rasalgethi",
    "Laomedeia",
    "Achernar",
    "Alnilam",
    "Schedar",
    "Gacrux",
    "Pulcherrima",
    "Achird",
    "Zubenelgenubi",
    "Vindemiatrix",
    "Sadachbia",
    "Sadaltager",
    "Sulafat"
  ]
};
const groups = {config:'configObservations', talkConfig:'talkConfigObservations', talkOverride:'talkOverrideObservations', prepare:'prepareObservations', synthesis:'observations', telephony:'telephonyObservations', voices:'voiceObservations'};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
test('independent input inventory and exact literal metadata', () => {
  assert.deepEqual(GOOGLE_SPEECH_CASES, inputs);
  assert.equal(GOOGLE_SPEECH_PIN, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(GOOGLE_SPEECH_SOURCE, 'extensions/google/speech-provider.ts');
  assert.equal(fixture.referencePin, GOOGLE_SPEECH_PIN);
  assert.deepEqual(fixture.providerMetadata, metadata);
  assert.equal(fixture.counts.totalObservations, 49);
  assert.equal(fixture.counts.httpRequests, 23);
  assert.equal(fixture.counts.releases, 23);
});
for (const [kind, rows] of Object.entries(inputs)) {
  for (const recipe of rows) {
    test(`${kind}: ${recipe.id}`, () => {
      const observation = fixture[groups[kind]].find(x => x.id === recipe.id);
      assert.ok(observation, recipe.id);
      assert.deepEqual(observation.input, recipe.input);
      assert.deepEqual(observation.inputAfter, recipe.input);
      const exp = expected[kind][recipe.id];
      if (kind === 'synthesis' || kind === 'telephony') {
        assert.deepEqual(observation.result, exp.result);
        assert.equal(observation.releaseCount, 1);
        assert.equal(observation.requests.length, 1);
        const request = observation.requests[0];
        assert.equal(request.url, exp.url);
        assert.equal(request.timeoutMs, 12345);
        assert.equal(request.init.method, 'POST');
        assert.deepEqual(request.body, exp.body);
        assert.equal(request.init.body, JSON.stringify(exp.body));
        assert.deepEqual(observation.transcodes, exp.transcodes);
        assert.deepEqual(observation.synthesisRequestAfter, observation.synthesisRequest);
      } else {
        assert.deepEqual(observation.result, exp);
        assert.equal(observation.requests.length, 0);
        assert.equal(observation.releaseCount, 0);
        assert.deepEqual(observation.transcodes, []);
      }
    });
  }
}
test('complete original modules pinned with TS erasure only and immutable checkout', () => {
  assert.equal(fixture.checkout.before.verified, true);
  assert.equal(fixture.checkout.after.verified, true);
  assert.equal(fixture.checkout.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(fixture.checkout.after, fixture.checkout.before);
  assert.equal(fixture.sourceAudit.length, 26);
  assert.equal(fixture.counts.wholeModules, 26);
  for (const row of fixture.sourceAudit) {
    assert.equal(hash(readFileSync(join(sourceRoot, row.path))), row.sourceSha256);
    const pinned = execFileSync('git', ['-C', sourceRoot, 'show', `${GOOGLE_SPEECH_PIN}:${row.path}`]);
    assert.equal(hash(pinned), row.sourceSha256);
    assert.equal(row.sourceBytes, pinned.length);
    assert.equal(row.wholeModule, true);
    assert.equal(row.executed, true);
  }
  for (const file of ['extensions/google/speech-provider.ts','extensions/google/speech-models.ts','extensions/google/voice-catalog.ts','extensions/google/http-request.ts','extensions/google/base64.ts','packages/media-core/src/base64.ts','src/infra/retry.ts']) {
    assert.ok(fixture.sourceAudit.some(row=>row.path===file), file);
  }
});
test('fresh VM and fresh CLI preserve full fixture JSON', async () => {
  assert.deepEqual(await captureGoogleSpeech(sourceRoot), fixture);
  const dir = mkdtempSync(join(tmpdir(), 'google333-oracle-'));
  try {
    const output = join(dir, 'capture.json');
    execFileSync(process.execPath, ['--experimental-vm-modules','scripts/openclaw/capture-google-speech.mjs','--source-root',sourceRoot,'--output',output], {timeout:60000,stdio:'pipe'});
    assert.deepEqual(JSON.parse(readFileSync(output,'utf8')),fixture);
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
