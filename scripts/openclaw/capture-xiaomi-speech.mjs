// Complete pinned Xiaomi Speech callbacks; successful fixture inputs only.
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

export const XIAOMI_SPEECH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const XIAOMI_SPEECH_SOURCE = 'extensions/xiaomi/speech-provider.ts';
// Independently authored raw callback inputs and positive synthetic response bytes; no expected maps.
export const XIAOMI_SPEECH_CASES = {
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

const strings = 'packages/normalization-core/src/string-coerce.ts';
const records = 'packages/normalization-core/src/record-coerce.ts';
const numbers = 'packages/normalization-core/src/number-coercion.ts';
const base64 = 'packages/media-core/src/base64.ts';
const blobRuntime = 'src/plugin-sdk/blob-runtime.ts';
const directiveParser = 'src/tts/directive-parser.ts';
const directiveNumber = 'src/tts/directive-number.ts';
const providerHelpers = 'src/tts/tts-provider-helpers.ts';
const sourcePaths = [XIAOMI_SPEECH_SOURCE, strings, records, numbers, base64,
  blobRuntime, directiveParser, directiveNumber, providerHelpers];
const manifestPath = 'extensions/xiaomi/openclaw.plugin.json';
const provenancePaths = [manifestPath, 'extensions/xiaomi/index.ts',
  'extensions/xiaomi/capability-catalog.ts', 'LICENSE'];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
const executionTimeoutMs = 2000;

// Wiring-only facades: every algorithm remains in its complete original TS-erased module.
const sdkFacades = {
  'openclaw/plugin-sdk/number-runtime': `export { resolveTimerTimeoutMs } from '${numbers}';`,
  'openclaw/plugin-sdk/speech-provider':
    `export { createSpeechDirectiveParser } from '${directiveParser}';\nexport { resolveSpeechProviderApiKey } from '${providerHelpers}';`,
  'openclaw/plugin-sdk/string-coerce-runtime':
    `export { asOptionalRecord } from '${records}';\nexport { normalizeOptionalString } from '${strings}';`,
  'openclaw/plugin-sdk/blob-runtime': `export * from '${blobRuntime}';`,
  '@openclaw/normalization-core/string-coerce': `export * from '${strings}';`,
  '@openclaw/normalization-core/number-coercion': `export * from '${numbers}';`,
  '@openclaw/media-core/base64': `export * from '${base64}';`,
};
const unused = 'Linked solely for complete original module evaluation; never invoked by these ordinary recipes.';
const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'Records explicit dummy value/path and trims strings only. No real secret resolution or credential authority executes.',
  },
  'openclaw/plugin-sdk/provider-http': {
    assertOkOrThrowProviderError: 'Records the synthetic successful response identity and label only. Original status/error behavior is unexecuted.',
    readProviderJsonResponse: 'Records response identity/label and returns fresh positive recipe JSON. Original body reader, decoder, limits and deadlines are unexecuted.',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    ssrfPolicyFromHttpBaseUrlAllowedHostname: 'Records the source-produced base URL and supplies an opaque named fixture policy. No hostname or network policy algorithm executes.',
    fetchWithSsrFGuard: 'Records exact source URL, JSON/headers/timeout/audit fields and returns a synthetic 200 response plus counted release. No network or guard implementation executes.',
  },
  'openclaw/plugin-sdk/media-runtime': {
    transcodeAudioBufferToOpus: 'Records actual source-decoded binary, selected input extension, temp prefix and raw request timeout; returns opaque recipe bytes. No files, FFmpeg or codec executes.',
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
  assert.equal(git(root, ['rev-parse', 'HEAD']), XIAOMI_SPEECH_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', XIAOMI_SPEECH_PIN])
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
  return { verified: true, commit: XIAOMI_SPEECH_PIN,
    tree: git(root, ['rev-parse', `${XIAOMI_SPEECH_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Xiaomi speech capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

class XiaomiSpeechCapture {
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
    } else if (identifier === 'openclaw/plugin-sdk/ssrf-runtime') {
      bindings.ssrfPolicyFromHttpBaseUrlAllowedHostname = url =>
        called('ssrfPolicyFromHttpBaseUrlAllowedHostname', { fixturePolicy: 'xiaomi-source-url' }, { url });
      bindings.fetchWithSsrFGuard = async params => {
        this.requests.push({ url: params.url,
          init: { method: params.init.method, headers: plain(params.init.headers), body: JSON.parse(params.init.body) },
          timeoutMs: params.timeoutMs, policy: plain(params.policy), auditContext: params.auditContext });
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
      bindings.readProviderJsonResponse = async (response, label) => {
        called('readProviderJsonResponse', undefined, responseFacts(response, label));
        return plain(response.fixtureResponse.json);
      };
    } else if (identifier === 'openclaw/plugin-sdk/media-runtime') {
      bindings.transcodeAudioBufferToOpus = async ({ audioBuffer, inputExtension, tempPrefix, timeoutMs }) => {
        const output = Buffer.from(this.recipe.response.transcodeAudioBase64, 'base64');
        const details = { audioBase64: audioBuffer.toString('base64'), audioHex: audioBuffer.toString('hex'),
          byteLength: audioBuffer.length, inputExtension, tempPrefix, timeoutMs,
          outputAudioBase64: output.toString('base64'), outputAudioHex: output.toString('hex'), outputByteLength: output.length };
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
    const source = this.module(XIAOMI_SPEECH_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildXiaomiSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      const callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      if (observationKind === 'config') return { metadata, callbacks, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'voices') return { metadata, callbacks, result: await provider.listVoices(speechInput) };
      const synthesisRequest = JSON.parse(JSON.stringify(speechInput));
      const { audioBuffer, ...resultMetadata } = await provider.synthesize(speechInput);
      return { metadata, callbacks, result: { audioBase64: audioBuffer.toString('base64'), ...resultMetadata },
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(speechInput)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    if (this.kind === 'synthesis') {
      assert.equal(this.requests.length, 1, 'ordinary source callback makes one successful request');
      assert.equal(this.releaseCount, 1, 'ordinary source callback releases exactly once');
      assert.equal(this.transcodes.length, this.recipe.input.target === 'voice-note' ? 1 : 0);
    } else {
      assert.equal(this.requests.length, 0, 'pure source callback makes no request');
      assert.equal(this.releaseCount, 0, 'pure source callback has no response to release');
      assert.equal(this.transcodes.length, 0, 'pure source callback does not transcode');
    }
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      result: plain(execution.result), providerMetadata: plain(execution.metadata),
      providerCallbacks: plain(execution.callbacks),
      ...(execution.synthesisRequest ? { synthesisRequest: plain(execution.synthesisRequest),
        synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      ...(this.recipe.response ? { response: plain(this.recipe.response) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls, transcodes: this.transcodes };
    return { observation, staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(path => this.modules.get(path)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureXiaomiSpeech(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const readOriginal = path => {
    const bytes = readFileSync(join(root, path));
    const original = execFileSync('git', ['-C', root, 'show', `${XIAOMI_SPEECH_PIN}:${path}`], {
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
    return { path, gitBlob: git(root, ['rev-parse', `${XIAOMI_SPEECH_PIN}:${path}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, executableSha256: hash(executable), wholeModule: true, executed: false };
  });
  const provenanceData = provenancePaths.map(path => ({ path, bytes: readOriginal(path) }));
  const dataAudit = provenanceData.map(({ path, bytes }) => ({ path,
    gitBlob: git(root, ['rev-parse', `${XIAOMI_SPEECH_PIN}:${path}`]), sourceSha256: hash(bytes), sourceBytes: bytes.length,
    usage: path === 'LICENSE' ? 'Complete original license provenance.'
      : 'Complete original plugin data/registration/catalog provenance; not evaluated or registered.', evaluated: false }));
  assert.deepEqual(Object.keys(XIAOMI_SPEECH_CASES), ['config', 'synthesis', 'voices']);
  const groups = {};
  for (const [kind, recipes] of Object.entries(XIAOMI_SPEECH_CASES)) {
    assert.ok(recipes.length > 0, 'independently authored recipes are embedded before execution');
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new XiaomiSpeechCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.executed = evaluated.has(row.path);
  assert.equal(evaluated.size, sourcePaths.length, 'all nine complete original runtime modules evaluate');
  const after = verifyCheckout(root);
  assert.deepEqual(after, before);
  const groupCounts = Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length]));
  return {
    schemaVersion: 1, referencePin: XIAOMI_SPEECH_PIN,
    harness: { path: 'scripts/openclaw/capture-xiaomi-speech.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
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
      process: 'Isolated VM process.env={} only. Original route/key code reads absent fields as provenance; no ambient environment, credential fallback or configured predicate is qualified.',
      fetch: 'Throwing ambient binding; only the explicitly named synthetic successful guarded-fetch facade is invoked.',
      Buffer: 'Node native Buffer carries original source-canonicalized synthetic opaque audio bytes; this does not establish a real media format or codec.',
      clock: 'Actual source numeric helper floors supplied positive fractional HTTP timeouts; raw timeouts reach synthetic media. No real timeout, retry, cancellation or recovery semantics are qualified.',
    },
    providerMetadata: runs[0].observation.providerMetadata,
    providerCallbacks: runs[0].observation.providerCallbacks,
    counts: { ...groupCounts, totalObservations: runs.length,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0),
      transcodes: runs.reduce((sum, run) => sum + run.observation.transcodes.length, 0),
      wholeModules: evaluated.size, trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles },
    configObservations: groups.config.map(run => run.observation),
    observations: groups.synthesis.map(run => run.observation),
    voiceObservations: groups.voices.map(run => run.observation),
    limits: [
      'All 58558 pinned tracked blobs/modes are verified before and after; complete original executable modules match pinned Git bytes before TypeScript erasure only.',
      'All nine whole modules evaluate: provider, TTS helpers, directive parser/number, string/record/number normalization, base64 and original blob-runtime. Whole-module evaluation is not all-branch execution.',
      'Original factory, metadata, config, static listVoices and buffered synthesis execute ordinary successful recipes. Original directive parser construction executes; directive dispatch and isConfigured/isConfiguredAsync remain uninvoked.',
      'Original field aliases, provider-object precedence, exact JSON request construction, voice-design/style decision, numeric HTTP timeout helper, successful response extraction and base64 canonicalizer execute.',
      'Original first-nonblank explicit dummy-key helper and source api-key header execute as provenance, not authentication/credential/security qualification. Real secret resolution, guarded HTTP, status checks and JSON readers are named positive synthetic facades.',
      'Synthetic Opus boundary records original decoded MP3/WAV bytes, source input extension/prefix and raw timeout, then returns fixed opaque recipe bytes after successful release. Codec/transcoding/playback/channel delivery remain unqualified.',
      'Static catalog returns all seven ordered source voices without HTTP. Manifest, index, capability catalog and license are complete original data provenance only; plugin activation/registration is not executed.',
      'No dedicated Talk, preparation, streaming or telephony callback is invented. No real HTTP, supplier, codec, runtime dependency or host production implementation executes.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed, budget/truncation/eviction/threshold/race, real provider or remote MCP execution.',
    ],
  };
}
export async function writeXiaomiSpeechCapture(root, output) {
  const capture = await captureXiaomiSpeech(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source-root', '--output'].includes(args[index]) && args[index + 1],
      'Usage: node --experimental-vm-modules scripts/openclaw/capture-xiaomi-speech.mjs --source-root DIR [--output FILE]');
    if (args[index] === '--source-root') root = args[index + 1];
    else output = args[index + 1];
  }
  if (output) return writeXiaomiSpeechCapture(root, output);
  const capture = await captureXiaomiSpeech(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
