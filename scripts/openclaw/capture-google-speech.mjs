// Complete pinned Google Speech source callbacks; ordinary successful fixture inputs only.
// Node 24.21.0 with --experimental-vm-modules; original algorithms receive TS erasure only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const GOOGLE_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const GOOGLE_SPEECH_SOURCE = 'extensions/google/speech-provider.ts';
// Raw independently authored callback inputs and positive synthetic response bytes only.
export const GOOGLE_SPEECH_CASES = {
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

const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const utf16 = 'packages/normalization-core/src/utf16-slice.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const sharedHttp = 'src/media-understanding/shared.ts';
const requestConfig = 'src/agents/provider-request-config.ts';
const retry = 'src/infra/retry.ts';
const sourcePaths = [GOOGLE_SPEECH_SOURCE,
  'extensions/google/speech-models.ts', 'extensions/google/voice-catalog.ts',
  'extensions/google/http-request.ts', 'extensions/google/base64.ts',
  'extensions/google/gemini-auth.ts', 'extensions/google/oauth-token-shared.ts',
  'extensions/google/google-api-client-header.ts', 'extensions/google/provider-policy.ts',
  'extensions/google/model-id.ts', 'extensions/google/src/google-api-base-url.ts',
  strings, records, numbers, utf16, directiveParser, directiveNumber, sharedHttp, requestConfig,
  'src/secrets/provider-request-secret-fields.ts', 'src/shared/text-truncate.ts',
  retry, 'src/infra/retry-attempt-errors.ts', 'src/infra/backoff.ts',
  'packages/retry/src/index.ts', 'packages/media-core/src/base64.ts'];
const manifestPath = 'extensions/google/openclaw.plugin.json';
const licensePath = 'LICENSE';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;

// Re-export wiring only. Each original algorithm is evaluated from its complete TS-erased module.
const sdkFacades = {
  'openclaw/plugin-sdk/speech-provider':
    `export { createSpeechDirectiveParser } from '${directiveParser}';\nexport { retryAsync } from '${retry}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asOptionalRecord } from '${records}';\nexport { readStringValue, normalizeOptionalString } from '${strings}';`,
  '@openclaw/normalization-core/string-coerce': `export * from '${strings}';`,
  '@openclaw/normalization-core/number-coercion': `export * from '${numbers}';`,
  '@openclaw/normalization-core/utf16-slice': `export * from '${utf16}';`,
  'openclaw/plugin-sdk/realtime-voice-provider':
    `export { canonicalizeBase64 } from 'packages/media-core/src/base64.ts';`,
  'openclaw/plugin-sdk/provider-http':
    `export { resolveProviderHttpRequestConfig, postJsonRequest } from '${sharedHttp}';
export { sanitizeConfiguredModelProviderRequest, resolveProviderRequestHeaders } from '${requestConfig}';
export { assertOkOrThrowProviderError, readProviderJsonResponse } from 'fixture:provider-response';`,
};
const unused = 'Throwing binding retained only to link a whole original module; never invoked by these successful recipes.';
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Records explicit fixture value/path, trims strings only; no production secret resolution or credential authority.',
  },
  'src/agents/provider-attribution.ts': {
    resolveProviderRequestCapabilities: 'Records original request capability facts; returns fixed empty attribution headers and fixture endpoint class. Plugin metadata discovery and attribution policy are unexecuted.',
  },
  'src/infra/net/fetch-guard.ts': {
    fetchWithSsrFGuard: 'Records original shared HTTP serialized JSON body, headers, timeout and raw policy fields; returns synthetic 200 response and counted release. No network or guard implementation executes.',
    GUARDED_FETCH_MODE: 'Static fixture mode label; no mode-selection qualification.',
  },
  'src/infra/net/proxy-env.ts': {
    shouldUseEnvHttpProxyForUrl: 'Records URL and returns fixed false; no ambient proxy environment or network-policy qualification.',
  },
  'fixture:provider-response': {
    readProviderJsonResponse: 'Records response identity, label, exact fixture headers and callback presence, returns fresh recipe JSON. Original response reader/budget/error/idle-timeout behavior unexecuted.',
    assertOkOrThrowProviderError: unused,
  },
  'openclaw/plugin-sdk/media-runtime': {
    transcodeAudioBufferToOpus: 'Records original source-generated WAV bytes, extension, prefix and supplied timeout; returns fixed fixture bytes explicitly not encoded Opus. No FFmpeg, filesystem or real codec executes.',
  },
  'openclaw/plugin-sdk/retry-runtime': { isTransientNetworkError: unused },
  'openclaw/plugin-sdk/model-ref-parse': {
    normalizeAntigravityPreviewModelId: unused, normalizeGooglePreviewModelId: unused,
  },
  'openclaw/plugin-sdk/provider-thinking-runtime': {
    isGoogleGemini3ProModel: unused, isGoogleGemini3ThinkingLevelModel: unused,
  },
  'src/config/types.secrets.ts': { assertSecretInputResolved: unused },
  'src/plugins/provider-auth-authority.ts': {
    attachProviderAuthAuthority: unused, getProviderAuthAuthority: unused,
  },
  'src/infra/secure-random.ts': { generateSecureFraction: unused },
  'src/agents/provider-http-errors.ts': {
    assertOkOrThrowHttpError: unused, createProviderHttpError: unused,
    readProviderJsonObjectResponse: unused, readProviderJsonResponse: unused,
  },
  'src/provider-runtime/operation-retry.ts': {
    executeProviderOperationWithRetry: unused, isTransientProviderHttpStatus: unused,
  },
  'src/plugin-sdk/blob-runtime.ts': { bufferToBlobPart: unused },
  'src/utils/fetch-timeout.ts': { fetchWithTimeout: unused },
  'node:path': { default: 'Uninvoked path binding for unrelated whole-module transcription helpers.' },
};
const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({ module, exports }));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), GOOGLE_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', GOOGLE_SPEECH_PIN])
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
  return { verified: true, commit: GOOGLE_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${GOOGLE_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Google speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class GoogleSpeechCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.calls = [];
    this.responses = [];
    this.releaseCount = 0;
    this.transcodes = [];
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetch = () => { throw Error('Ambient fetch is excluded; original shared helper must use the synthetic guard'); };
    this.context = vm.createContext({ Buffer, URL, Headers, Uint8Array,
      fetch: this.fetch, process: { env: {} } }, { codeGeneration: { strings: false, wasm: false } });
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
    } else if (identifier === 'src/agents/provider-attribution.ts') {
      bindings.resolveProviderRequestCapabilities = params =>
        called('resolveProviderRequestCapabilities', { attributionHeaders: {}, endpointClass: 'google-generative-ai' },
          { params: plain(params) });
    } else if (identifier === 'src/infra/net/proxy-env.ts') {
      bindings.shouldUseEnvHttpProxyForUrl = url => called('shouldUseEnvHttpProxyForUrl', false, { url });
    } else if (identifier === 'src/infra/net/fetch-guard.ts') {
      bindings.GUARDED_FETCH_MODE = { TRUSTED_ENV_PROXY: 'fixture-trusted-env-proxy' };
      bindings.fetchWithSsrFGuard = async params => {
        assert.equal(params.fetchImpl, this.fetch, 'original caller supplied excluded fetch binding');
        const headers = Object.fromEntries(params.init.headers.entries());
        const raw = plain({ ...params, init: { ...params.init, headers } });
        this.requests.push({ ...raw, headers, body: JSON.parse(params.init.body), bodyText: params.init.body });
        const response = { ok: true, status: 200, headers: new Headers({ 'Content-Type': 'application/json' }),
          fixtureJson: plain(this.recipe.response.json) };
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
    } else if (identifier === 'fixture:provider-response') {
      bindings.readProviderJsonResponse = async (response, label, options) => {
        assert.ok(this.responses.includes(response), 'synthetic response identity');
        called('readProviderJsonResponse', undefined, { status: response.status, label,
          requestHeaders: Object.fromEntries(options.requestHeaders.entries()),
          onIdleTimeoutSupplied: typeof options.onIdleTimeout === 'function' });
        return plain(response.fixtureJson);
      };
    } else if (identifier === 'openclaw/plugin-sdk/media-runtime') {
      bindings.transcodeAudioBufferToOpus = async ({ audioBuffer, ...params }) => {
        const output = Buffer.from(this.recipe.response.transcodeAudioBase64, 'base64');
        const details = { ...plain(params), audioBase64: audioBuffer.toString('base64'), outputAudioBase64: output.toString('base64') };
        this.transcodes.push(details);
        called('transcodeAudioBufferToOpus', undefined, details);
        return output;
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
    const source = this.module(GOOGLE_SPEECH_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildGoogleSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      if (observationKind === 'config') return { metadata, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverride') return { metadata, result: provider.resolveTalkOverrides(speechInput) };
      if (observationKind === 'voices') return { metadata, result: await provider.listVoices(speechInput) };
      const resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig });
      const request = { text: speechInput.text, target: speechInput.target, timeoutMs: speechInput.timeoutMs,
        providerConfig: resolvedConfig, providerOverrides: speechInput.providerOverrides, cfg: speechInput.cfg,
        persona: speechInput.persona };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      if (observationKind === 'prepare') {
        const result = provider.prepareSynthesis(request);
        return { metadata, result, resolvedConfig, synthesisRequest,
          synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
      }
      const buffered = observationKind === 'telephony'
        ? await provider.synthesizeTelephony(request) : await provider.synthesize(request);
      const { audioBuffer, ...resultMetadata } = buffered;
      return { metadata, result: { audioBase64: audioBuffer.toString('base64'), ...resultMetadata },
        resolvedConfig, synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    if (['synthesis', 'telephony'].includes(this.kind)) {
      assert.equal(this.requests.length, 1, 'ordinary source path makes one successful request');
      assert.equal(this.releaseCount, 1, 'ordinary source path releases exactly once');
    }
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      result: plain(execution.result), providerMetadata: plain(execution.metadata),
      ...(execution.resolvedConfig ? { resolvedConfig: plain(execution.resolvedConfig),
        synthesisRequest: plain(execution.synthesisRequest), synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      ...(this.recipe.response ? { response: plain(this.recipe.response) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls, transcodes: this.transcodes };
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureGoogleSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${GOOGLE_SPEECH_PIN}:${path}`], {
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
    return { path, gitBlob: git(root, ['rev-parse', `${GOOGLE_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const manifestBytes = readOriginal(manifestPath), licenseBytes = readOriginal(licensePath);
  const groups = {};
  for (const [kind, recipes] of Object.entries(GOOGLE_SPEECH_CASES)) {
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new GoogleSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  const groupCounts = Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length]));
  return {
    schemaVersion: 1, referencePin: GOOGLE_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-google-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    checkout: { before, after },
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    sourceAudit,
    dataAudit: [
      { path: manifestPath, gitBlob: git(root, ['rev-parse', `${GOOGLE_SPEECH_PIN}:${manifestPath}`]), sourceSha256: hash(manifestBytes),
        usage: 'Complete original manifest data provenance; no JSON import or plugin registration executes.', evaluated: false },
      { path: licensePath, gitBlob: git(root, ['rev-parse', `${GOOGLE_SPEECH_PIN}:${licensePath}`]), sourceSha256: hash(licenseBytes),
        usage: 'Complete original source license provenance.', evaluated: false },
    ],
    pluginManifest: JSON.parse(manifestBytes), license: { path: licensePath, text: licenseBytes.toString() },
    platformBoundaries,
    globalBoundaries: { process: 'Isolated VM env={} only; every synthesis has explicit fixture key; original env lookup and OAuth parsing remain uninvoked.',
      fetch: 'Throwing ambient binding; only original shared HTTP code reaches the named positive synthetic guarded-fetch boundary.',
      Headers: 'Node native Headers represents original Google/shared source-built headers; all keys are explicit fixtures, not real credentials.',
      clock: 'Invoked successful algorithms do not require clock APIs; no timeout, delay, random or retry branch is exercised.' },
    providerMetadata: runs[0].observation.providerMetadata,
    counts: { ...groupCounts, totalObservations: runs.length,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0),
      transcodes: runs.reduce((sum, run) => sum + run.observation.transcodes.length, 0),
      wholeModules: evaluated.size, trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    talkConfigObservations: groups.talkConfig.map(run => run.observation),
    talkOverrideObservations: groups.talkOverride.map(run => run.observation),
    prepareObservations: groups.prepare.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    telephonyObservations: groups.telephony.map(run => run.observation),
    voiceObservations: groups.voices.map(run => run.observation),
    limits: [
      'All 58558 pinned tracked blobs/modes verified before and after; complete original executable modules match pinned Git bytes before TypeScript erasure only.',
      'Whole-module evaluation is not all-branch execution. Original factory, metadata, config/Talk, listVoices, prepareSynthesis, buffered synthesis and telephony execute ordinary successful recipes.',
      'All five source catalog models execute both buffered file and voice-note callbacks; Gemini 3.8 is explicit opt-in through original Interactions requests and the implicit default stays generateContent.',
      'Original prompt wrapping/unwrapping, dialogue splitting/style composition, response extraction, Google/shared base64 normalization, PCM/WAV stripping and WAV wrapping execute complete source algorithms.',
      'Original shared HTTP/request-config modules normalize source inputs, assemble fixture headers, serialize exact JSON and forward supplied timeout to a synthetic guard. Raw policy fields are provenance, not security qualification.',
      'Original gemini-auth parseGeminiAuth explicit fixture-key header branch executes; original env lookup, OAuth parsing, auth predicates/configured discovery and directive dispatch remain uninvoked.',
      'Original directive parser construction and complete original retry runner first successful attempt execute. No retry predicate, delay, failure, random or recovery path executes.',
      'Synthetic response reader returns fresh positive JSON. Synthetic Opus boundary returns fixed opaque bytes and records source-generated WAV input and supplied timeout; codec/transcoding/playback/channel delivery remain unqualified.',
      'Static catalog returns all 30 voices without HTTP. Manifest/license are complete data provenance only; plugin discovery, activation and registration remain unexecuted.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real provider or remote MCP execution. No host production implementation is installed.',
    ],
  };
}
export async function writeGoogleSpeechCapture(root, output) {
  const capture = await captureGoogleSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-google-speech.mjs --source-root DIR [--output FILE]');
    if (args[index] === '--source-root') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) await writeGoogleSpeechCapture(root, output);
  else process.stdout.write(JSON.stringify(await captureGoogleSpeech(root), null, 2) + '\n');
}
