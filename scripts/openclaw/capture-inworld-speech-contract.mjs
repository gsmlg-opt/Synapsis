// Complete pinned Inworld factory ordinary contract; no extracted helpers.
// Parent owns Node VM execution; declared successful platform facades only.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const INWORLD_SPEECH_CONTRACT_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const INWORLD_SPEECH_CONTRACT_SOURCE = 'extensions/inworld/speech-provider.ts';
const sourcePaths = [INWORLD_SPEECH_CONTRACT_SOURCE, 'extensions/inworld/tts.ts',
  'src/tts/tts-provider-helpers.ts', 'src/tts/directive-parser.ts', 'src/tts/directive-number.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/record-coerce.ts', 'packages/normalization-core/src/utf16-slice.ts',
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts'];
const manifestPath = 'extensions/inworld/openclaw.plugin.json';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const fixtureKey = 'fixture-inworld-speech-contract';
const executionTimeoutMs = 2000;

const sdkFacades = {
  'openclaw/plugin-sdk/string-coerce-runtime':
    'export { asFiniteNumberInRange } from "packages/normalization-core/src/number-coercion.ts";\n' +
    'export { asOptionalRecord, filterStringRecord } from "packages/normalization-core/src/record-coerce.ts";\n' +
    'export { normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  'openclaw/plugin-sdk/speech-provider':
    'export { createSpeechDirectiveParser } from "src/tts/directive-parser.ts";\n' +
    'export { resolveSpeechProviderApiKey } from "src/tts/tts-provider-helpers.ts";\n' +
    'export { truncateUtf16Safe } from "packages/normalization-core/src/utf16-slice.ts";\n',
  '@openclaw/normalization-core/string-coerce':
    'export { normalizeOptionalLowercaseString, normalizeOptionalString } from "packages/normalization-core/src/string-coerce.ts";\n',
  '@openclaw/normalization-core/number-coercion':
    'export { asFiniteNumberInRange, parseStrictFiniteNumber } from "packages/normalization-core/src/number-coercion.ts";\n',
  'openclaw/plugin-sdk/media-runtime':
    'export { canonicalizeBase64 } from "packages/media-core/src/base64.ts";\n' +
    'export { MAX_AUDIO_BYTES } from "packages/media-core/src/constants.ts";\n',
};

const boundaries = {
  'openclaw/plugin-sdk/secret-input': {
    normalizeResolvedSecretInputString: 'supports undefined or explicit dummy fixture only; production secret resolution unexecuted',
  },
  'node:fs': { rmSync: 'uninvoked throwing binding required by complete tts-provider-helpers; no cleanup callback executes' },
  'openclaw/plugin-sdk/response-limit-runtime': {
    readResponseWithLimit: 'records supplied limits and callback presence, returns successful synthetic Response bytes; production bounded/idle reader unexecuted',
  },
  'openclaw/plugin-sdk/ssrf-runtime': {
    fetchWithSsrFGuard: 'records complete original URL/init/body/timeout/policy/audit inputs; returns successful synthetic Response and counted release; original fetch/guard unexecuted',
  },
};

const platformBoundaries = Object.entries(boundaries).map(([module, exports]) => ({
  module, originalSourceExecuted: false, exports,
}));
const lineRange = bytes => ({
  start: 1, end: bytes.toString().split('\n').length - (bytes.at(-1) === 10 ? 1 : 0),
});

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function verifyCheckout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), INWORLD_SPEECH_CONTRACT_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', INWORLD_SPEECH_CONTRACT_PIN])
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
  return { verified: true, commit: INWORLD_SPEECH_CONTRACT_PIN,
    tree: git(root, ['rev-parse', `${INWORLD_SPEECH_CONTRACT_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) };
}
async function withDeadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Inworld speech contract capture asynchronous deadline exceeded')), executionTimeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

// Independent raw literals embedded before first execution.
export const INWORLD_SPEECH_CONTRACT_CASES = {
  "config": [
    {
      "id": "empty-defaults",
      "input": {
        "rawConfig": {}
      }
    },
    {
      "id": "root-and-legacy-not-selected",
      "input": {
        "rawConfig": {
          "apiKey": "fixture-inworld-speech-contract",
          "voiceId": "RootVoice",
          "modelId": "RootModel",
          "inworld": {
            "voiceId": "LegacyVoice",
            "modelId": "LegacyModel"
          }
        }
      }
    },
    {
      "id": "nested-all-fields",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://speech.example.test/v2/// ",
              "voiceId": " Ashley ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.75
            }
          }
        }
      }
    },
    {
      "id": "empty-nested-masks-legacy",
      "input": {
        "rawConfig": {
          "voiceId": "RootVoice",
          "inworld": {
            "voiceId": "LegacyVoice"
          },
          "providers": {
            "inworld": {}
          }
        }
      }
    },
    {
      "id": "blank-optionals-use-defaults",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " \t ",
              "voiceId": " ",
              "modelId": "\n "
            }
          }
        }
      }
    },
    {
      "id": "ecmascript-trim",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": " fixture-inworld-speech-contract ",
              "baseUrl": "﻿ https://trim.example.test/api/// ﻿",
              "voiceId": "﻿  Olivia  ﻿",
              "modelId": "﻿  inworld-tts-1  ﻿",
              "temperature": 1.1
            }
          }
        }
      }
    },
    {
      "id": "custom-values-preserved",
      "input": {
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://studio.example.test/prefix/",
              "voiceId": " Studio / Voice ",
              "modelId": " custom-studio-model ",
              "temperature": 1.25
            }
          }
        }
      }
    }
  ],
  "talkConfig": [
    {
      "id": "defaults-from-empty-base",
      "input": {
        "baseTtsConfig": {},
        "talkProviderConfig": {}
      }
    },
    {
      "id": "inherit-normalized-base",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://base.example.test/api/// ",
              "voiceId": " Dennis ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {}
      }
    },
    {
      "id": "explicit-talk-fields",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "apiKey": " fixture-inworld-speech-contract ",
          "baseUrl": " https://talk.example.test/v1/// ",
          "voiceId": "﻿  Wendy  ﻿",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "partial-talk-composition",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley ",
          "temperature": 0.9
        }
      }
    },
    {
      "id": "blank-talk-optionals-inherit",
      "input": {
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " \t ",
          "voiceId": "﻿ ",
          "modelId": " "
        }
      }
    }
  ],
  "talkOverrides": [
    {
      "id": "empty-params",
      "input": {
        "params": {}
      }
    },
    {
      "id": "canonical-fields",
      "input": {
        "params": {
          "voiceId": "﻿  Olivia  ﻿",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "partial-temperature",
      "input": {
        "params": {
          "temperature": 0.6
        }
      }
    },
    {
      "id": "aliases-not-projected",
      "input": {
        "params": {
          "voice": "AliasVoice",
          "model": "AliasModel",
          "voice_id": "SnakeVoice",
          "model_id": "SnakeModel",
          "outputFormat": "mp3",
          "language": "en-US"
        }
      }
    },
    {
      "id": "blank-canonical-optionals",
      "input": {
        "params": {
          "voiceId": " \t ",
          "modelId": "﻿ ",
          "voice": "AliasVoice",
          "model": "AliasModel"
        }
      }
    }
  ],
  "synthesis": [
    {
      "id": "file-default-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract"
            }
          }
        }
      }
    },
    {
      "id": "file-configured-from-raw",
      "input": {
        "request": {
          "text": "  Ordinary speech.\n你好 🌍 — café.\t ",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://speech.example.test/v2/// ",
              "voiceId": " Ashley ",
              "modelId": " inworld-tts-1.5-mini ",
              "temperature": 0.75
            }
          }
        }
      }
    },
    {
      "id": "file-pre-resolved-config",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": "https://resolved.example.test/api",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1-max",
            "temperature": 0.9
          }
        }
      }
    },
    {
      "id": "file-talk-config-and-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk.example.test/v1/// ",
          "voiceId": "Ashley"
        },
        "talkParams": {
          "voiceId": " Olivia ",
          "modelId": " inworld-tts-1 ",
          "temperature": 1.1
        }
      }
    },
    {
      "id": "note-default-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract"
            }
          }
        }
      }
    },
    {
      "id": "note-talk-config-and-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "voice-note",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "voiceId": "Dennis",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley ",
          "modelId": " inworld-tts-1-max "
        },
        "talkParams": {
          "temperature": 0.7
        }
      }
    },
    {
      "id": "file-direct-alias-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voice": " Olivia ",
            "model": " inworld-tts-1 ",
            "temperature": 1.2
          }
        }
      }
    },
    {
      "id": "file-primary-overrides",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          },
          "providerOverrides": {
            "voiceId": " Ashley ",
            "voice": "Olivia",
            "modelId": " inworld-tts-1-max ",
            "model": "inworld-tts-1",
            "temperature": 0.9
          }
        }
      }
    },
    {
      "id": "file-blank-primary-uses-config",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "voiceId": "Dennis",
            "modelId": "inworld-tts-1.5-mini",
            "temperature": 0.8
          },
          "providerOverrides": {
            "voiceId": " ",
            "voice": "Olivia",
            "modelId": "\t",
            "model": "inworld-tts-1"
          }
        }
      }
    },
    {
      "id": "file-multiple-audio-lines",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "{\"result\":{\"audioContent\":\"UklGRg==\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"
        }
      }
    },
    {
      "id": "file-metadata-and-blank-lines",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "\n \t\n{\"requestId\":\"ordinary-request\"}\n﻿  {\"result\":{\"audioContent\":\"UklGRg==\"}}  ﻿\n{\"result\":{\"requestId\":\"ordinary-progress\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"
        }
      }
    },
    {
      "id": "file-canonical-base64-variants",
      "input": {
        "request": {
          "text": "Ordinary Inworld speech.",
          "target": "audio-file",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract"
          }
        },
        "response": {
          "ndjson": "{\"result\":{\"audioContent\":\" UklG Rg==\\t\"}}\n{\"result\":{\"audioContent\":\"AAE\"}}\n{\"result\":{\"audioContent\":\"Av8\"}}\n"
        }
      }
    }
  ],
  "telephony": [
    {
      "id": "phone-from-raw",
      "input": {
        "request": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        }
      }
    },
    {
      "id": "phone-pre-resolved-and-aliases",
      "input": {
        "request": {
          "text": "  Phone speech.\n你好 📞\t ",
          "target": "telephony",
          "timeoutMs": 12345,
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": " https://phone.example.test/api/// ",
            "voiceId": "Sarah",
            "modelId": "inworld-tts-1.5-max"
          },
          "providerOverrides": {
            "voice": " Wendy ",
            "model": " inworld-tts-1 ",
            "temperature": 1.1
          }
        }
      }
    },
    {
      "id": "phone-talk-composition",
      "input": {
        "request": {
          "text": "Ordinary Inworld phone speech.",
          "target": "telephony",
          "timeoutMs": 12345
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "modelId": "inworld-tts-1.5-mini",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "voiceId": " Ashley "
        },
        "talkParams": {
          "modelId": " inworld-tts-1-max ",
          "temperature": 0.7
        }
      }
    }
  ],
  "voices": [
    {
      "id": "explicit-get-projection",
      "input": {
        "request": {
          "apiKey": "fixture-inworld-speech-contract",
          "baseUrl": " https://voices.example.test/api/// ",
          "timeoutMs": 12345
        },
        "response": {
          "voices": [
            {
              "voiceId": " Sarah ",
              "displayName": " Sarah Voice ",
              "description": " A calm narrator. ",
              "langCode": " en-US ",
              "tags": [
                "warm",
                "female",
                "male"
              ],
              "source": "curated"
            },
            {
              "voiceId": "Dennis",
              "displayName": " Dennis ",
              "langCode": "en-GB",
              "tags": [
                "male",
                "female"
              ]
            },
            {
              "voiceId": "Sarah",
              "displayName": " Second Sarah ",
              "description": "   ",
              "langCode": "fr-CA",
              "tags": [
                "neutral",
                "female"
              ]
            },
            {
              "voiceId": "Minimal",
              "tags": [
                "Male",
                "FEMALE",
                "character"
              ]
            }
          ]
        }
      }
    },
    {
      "id": "provider-config-default-timeout",
      "input": {
        "request": {
          "providerConfig": {
            "apiKey": "fixture-inworld-speech-contract",
            "baseUrl": " https://catalog.example.test/v2/// "
          }
        },
        "response": {
          "voices": [
            {
              "voiceId": "Locale",
              "displayName": " Locale Voice ",
              "description": " Description ",
              "langCode": "\tpt-BR ",
              "tags": [
                "other",
                "male"
              ]
            },
            {
              "voiceId": "Optional",
              "displayName": "  ",
              "description": "\t",
              "langCode": "",
              "tags": []
            }
          ]
        }
      }
    },
    {
      "id": "raw-config-voice-list",
      "input": {
        "request": {
          "timeoutMs": 12345
        },
        "rawConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": " https://rawvoices.example.test/api/// "
            }
          }
        },
        "response": {
          "voices": [
            {
              "voiceId": " RawVoice "
            }
          ]
        }
      }
    },
    {
      "id": "talk-config-explicit-url",
      "input": {
        "request": {
          "baseUrl": " https://explicit.example.test/list/// ",
          "timeoutMs": 4567
        },
        "baseTtsConfig": {
          "providers": {
            "inworld": {
              "apiKey": "fixture-inworld-speech-contract",
              "baseUrl": "https://base.example.test/api",
              "voiceId": "Dennis",
              "temperature": 0.8
            }
          }
        },
        "talkProviderConfig": {
          "baseUrl": " https://talk.example.test/v1/// ",
          "modelId": " inworld-tts-1 "
        },
        "response": {
          "voices": [
            {
              "voiceId": "TalkVoice",
              "displayName": " Talk Voice ",
              "description": " Talk catalog ",
              "langCode": "ja-JP",
              "tags": [
                "female",
                "male"
              ]
            }
          ]
        }
      }
    }
  ]
};

class InworldSpeechContractCapture {
  constructor(executables, recipe, kind) {
    Object.assign(this, { executables, recipe, kind });
    this.modules = new Map();
    this.requests = [];
    this.responses = [];
    this.calls = [];
    this.releaseCount = 0;
    this.staticImports = [];
    this.dynamicImports = [];
    this.fetch = () => { throw Error('Ambient fetch excluded; use the named successful HTTP facade'); };
    this.context = vm.createContext({ Buffer, URL,
      fetch: this.fetch, process: { env: {} } }, { codeGeneration: { strings: false, wasm: false } });
  }
  platformModule(identifier) {
    const called = (name, value, details = {}) => {
      this.calls.push({ module: identifier, export: name, ...details });
      return value;
    };
    const bindings = {
      normalizeResolvedSecretInputString: ({ value, path }) => {
        assert.ok(value === undefined || (typeof value === 'string' && value.trim() === fixtureKey),
          'secret facade supports undefined or explicit dummy only');
        return called('normalizeResolvedSecretInputString', value?.trim() || undefined,
          { provenanceOnly: true, path, ...(value === undefined ? {} : { value }) });
      },
      rmSync: () => { throw Error('Excluded cleanup binding invoked'); },
      readResponseWithLimit: async (response, maxBytes, options) => {
        assert.ok(this.responses.includes(response));
        assert.equal(response.ok, true);
        called('readResponseWithLimit', undefined, { provenanceOnly: true,
          responseIndex: this.responses.indexOf(response), maxBytes,
          chunkTimeoutMs: options.chunkTimeoutMs,
          overflowCallbackProvided: typeof options.onOverflow === 'function',
          idleCallbackProvided: typeof options.onIdleTimeout === 'function' });
        return Buffer.from(await response.arrayBuffer());
      },
      fetchWithSsrFGuard: async params => {
        const requestIndex = this.requests.length;
        this.requests.push({ url: params.url, method: params.init.method ?? 'GET',
          headers: plain(params.init.headers),
          ...(params.init.body === undefined ? {} : {
            body: JSON.parse(params.init.body), bodyText: params.init.body }),
          ...(params.timeoutMs === undefined ? {} : { timeoutMs: params.timeoutMs }),
          auditContext: params.auditContext });
        called('fetchWithSsrFGuard', undefined, { provenanceOnly: true, requestIndex,
          args: plain(params) });
        const responseBody = this.kind === 'voices' ? JSON.stringify(this.recipe.input.response)
          : this.recipe.input.response?.ndjson ?? '{"result":{"audioContent":"UklGRgABAv8="}}\n';
        const response = new Response(responseBody, { status: 200,
          headers: { 'Content-Type': this.kind === 'voices' ? 'application/json' : 'application/x-ndjson' } });
        this.responses.push(response);
        return { response, release: async () => {
          this.releaseCount += 1;
          called('release', undefined, { requestIndex });
        } };
      },
    };
    const names = Object.keys(boundaries[identifier]);
    for (const name of names) assert.ok(Object.hasOwn(bindings, name), `named facade: ${identifier} ${name}`);
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
      assert.equal(typeof executable, 'string', `declared complete original source or facade: ${identifier}`);
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
    const source = this.module(INWORLD_SPEECH_CONTRACT_SOURCE);
    await withDeadline(source.link((specifier, importer) => this.resolveImport(specifier, importer, this.staticImports)));
    await withDeadline(source.evaluate({ timeout: executionTimeoutMs }));
    this.context.speechSource = source.namespace;
    this.context.speechInput = plain(this.recipe.input);
    this.context.observationKind = this.kind;
    const execution = await withDeadline(vm.runInContext(`(async () => {
      const provider = speechSource.buildInworldSpeechProvider();
      const metadata = Object.fromEntries(Object.entries(provider).filter(([, value]) => typeof value !== 'function'));
      metadata.callbacks = Object.keys(provider).filter(key => typeof provider[key] === 'function');
      if (observationKind === 'config') return { metadata, result: provider.resolveConfig(speechInput) };
      if (observationKind === 'talkConfig') return { metadata, result: provider.resolveTalkConfig(speechInput) };
      if (observationKind === 'talkOverrides') return { metadata, result: provider.resolveTalkOverrides(speechInput) };
      let request = JSON.parse(JSON.stringify(speechInput.request ?? speechInput));
      let resolvedConfig;
      if (Object.hasOwn(speechInput, 'rawConfig')) {
        resolvedConfig = provider.resolveConfig({ rawConfig: speechInput.rawConfig });
      } else if (Object.hasOwn(speechInput, 'baseTtsConfig')) {
        resolvedConfig = provider.resolveTalkConfig({ baseTtsConfig: speechInput.baseTtsConfig,
          talkProviderConfig: speechInput.talkProviderConfig });
      }
      if (resolvedConfig !== undefined) request.providerConfig = resolvedConfig;
      if (Object.hasOwn(speechInput, 'talkParams')) {
        request.providerOverrides = { ...(request.providerOverrides ?? {}),
          ...provider.resolveTalkOverrides({ params: speechInput.talkParams }) };
      }
      if (observationKind === 'voices') return { metadata, result: await provider.listVoices(request),
        ...(resolvedConfig === undefined ? {} : { resolvedConfig }) };
      request = { cfg: {}, ...request };
      const synthesisRequest = JSON.parse(JSON.stringify(request));
      const callback = observationKind === 'telephony' ? 'synthesizeTelephony' : 'synthesize';
      const sourceResult = await provider[callback](request);
      const { audioBuffer, ...resultMetadata } = sourceResult;
      const result = { audioBase64: audioBuffer.toString('base64'), ...resultMetadata };
      return { metadata, result, ...(resolvedConfig === undefined ? {} : { resolvedConfig }),
        synthesisRequest, synthesisRequestAfter: JSON.parse(JSON.stringify(request)) };
    })()`, this.context, { timeout: executionTimeoutMs }));
    const inputAfter = plain(this.context.speechInput);
    assert.deepEqual(inputAfter, this.recipe.input, 'callback input remains unchanged');
    if (execution.synthesisRequest) assert.deepEqual(plain(execution.synthesisRequestAfter), plain(execution.synthesisRequest),
      'synthesis request remains unchanged');
    const http = ['synthesis', 'telephony', 'voices'].includes(this.kind);
    assert.equal(this.requests.length, http ? 1 : 0, 'ordinary successful callback request count');
    assert.equal(this.releaseCount, http ? 1 : 0, 'ordinary successful callback release count');
    const observation = { id: this.recipe.id, input: plain(this.recipe.input), inputAfter,
      ...(Object.hasOwn(execution, 'resolvedConfig') ? { resolvedConfig: plain(execution.resolvedConfig) } : {}),
      result: plain(execution.result),
      ...(execution.synthesisRequest ? { synthesisRequest: plain(execution.synthesisRequest),
        synthesisRequestAfter: plain(execution.synthesisRequestAfter) } : {}),
      requests: this.requests, releaseCount: this.releaseCount, platformCalls: this.calls };
    return { observation, metadata: plain(execution.metadata),
      staticImports: this.staticImports, dynamicImports: this.dynamicImports,
      evaluatedSourcePaths: sourcePaths.filter(sourcePath => this.modules.get(sourcePath)?.status === 'evaluated') };
  }
}
const unique = rows => [...new Map(rows.map(row => [JSON.stringify(row), row])).values()];

export async function captureInworldSpeechContract(sourceRoot = '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const before = verifyCheckout(root);
  const executables = new Map();
  const sourceAudit = sourcePaths.map(sourcePath => {
    const bytes = readFileSync(join(root, sourcePath));
    const original = execFileSync('git', ['-C', root, 'show', `${INWORLD_SPEECH_CONTRACT_PIN}:${sourcePath}`], {
      timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    });
    assert.deepEqual(bytes, original, `complete pinned source bytes: ${sourcePath}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    executables.set(sourcePath, executable);
    return { path: sourcePath, gitBlob: git(root, ['rev-parse', `${INWORLD_SPEECH_CONTRACT_PIN}:${sourcePath}`]),
      sourceSha256: hash(bytes), sourceBytes: bytes.length, readRange: lineRange(bytes),
      executableSha256: hash(executable), wholeModule: true, evaluated: false };
  });
  assert.deepEqual(Object.keys(INWORLD_SPEECH_CONTRACT_CASES),
    ['config', 'talkConfig', 'talkOverrides', 'synthesis', 'telephony', 'voices']);
  const groups = {};
  for (const [kind, recipes] of Object.entries(INWORLD_SPEECH_CONTRACT_CASES)) {
    assert.ok(recipes.length > 0, 'independent raw recipes embedded before execution');
    groups[kind] = [];
    for (const recipe of recipes) groups[kind].push(await new InworldSpeechContractCapture(executables, recipe, kind).run());
  }
  const runs = Object.values(groups).flat();
  const evaluated = new Set(runs.flatMap(run => run.evaluatedSourcePaths));
  for (const row of sourceAudit) row.evaluated = evaluated.has(row.path);
  assert.equal(evaluated.size, sourcePaths.length, 'all eleven complete original runtime modules evaluate');
  const metadata = runs[0].metadata;
  for (const run of runs) assert.deepEqual(run.metadata, metadata, 'stable provider metadata across isolated contexts');
  const after = verifyCheckout(root);
  assert.deepEqual(after, before, 'pinned checkout remains identical after source capture');
  return { schemaVersion: 1, sourcePin: INWORLD_SPEECH_CONTRACT_PIN,
    harness: { path: 'scripts/openclaw/capture-inworld-speech-contract.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    sourceAudit, sourceIntegrity: { before, after },
    dataAudit: [{ path: manifestPath, gitBlob: git(root, ['rev-parse', `${INWORLD_SPEECH_CONTRACT_PIN}:${manifestPath}`]),
      sourceSha256: hash(readFileSync(join(root, manifestPath))),
      usage: 'complete original plugin manifest provenance; plugin registration unexecuted' }],
    pluginManifest: JSON.parse(readFileSync(join(root, manifestPath))),
    transformation: { api: 'node:module.stripTypeScriptTypes', options: { mode: 'transform', sourceMap: false },
      sdkFacades: Object.entries(sdkFacades).map(([module, source]) => ({ module, source, sha256: hash(source) })),
      staticImports: unique(runs.flatMap(run => run.staticImports)), dynamicImports: unique(runs.flatMap(run => run.dynamicImports)) },
    metadata,
    observations: Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.map(run => run.observation)])),
    counts: { ...Object.fromEntries(Object.entries(groups).map(([kind, rows]) => [kind, rows.length])),
      observations: runs.length, totalObservations: runs.length, wholeModules: evaluated.size,
      trackedFilesBefore: before.verifiedTrackedFiles, trackedFilesAfter: after.verifiedTrackedFiles,
      httpRequests: runs.reduce((sum, run) => sum + run.observation.requests.length, 0),
      releases: runs.reduce((sum, run) => sum + run.observation.releaseCount, 0) },
    platformBoundaries,
    globalBoundaries: {
      process: 'Fresh VM process.env={} only. No ambient environment, credential/profile/auth-store lookup or source readiness execution.',
      fetch: 'Throwing ambient binding. Only named synthetic successful HTTP facade executes.',
      Buffer: 'Native Buffer carries eight opaque fixture bytes; no codec, valid audio or playback evidence.',
      clock: 'Raw source timeouts pass to synthetic HTTP only; 2000ms VM/asynchronous harness deadlines are execution bounds, not source timeout acceptance.',
    },
    limits: [
      'All58558 pinned tracked blobs/modes/symlinks verified before/after; eleven complete original modules equal pinned Git bytes before TypeScript erasure.',
      'Whole module evaluation is not every export or branch. Factory metadata/raw/Talk config/overrides, successful buffered NDJSON, fixed PCM22050 phone and GET voices callbacks execute.',
      'Original NDJSON/Base64/normalization/voice mapping algorithms execute. Source buffers its NDJSON response; no streamSynthesize callback or incremental delivery is invented.',
      'Secret input, HTTP/guard, bounded/idle response reader and cleanup bindings are explicit synthetic or uninvoked boundaries. Exact reader/policy/header arguments are provenance only.',
      'Directive parser constructs only; no dispatch/isConfigured/isConfiguredAsync/readiness or automatic Talk/channel/phone consumer.',
      'Opaque eight-byte audio is result assembly evidence only, not valid audio, codec, publication or player evidence.',
      'Existing14 source qualification remains frozen and is not rerun. No host production, dependency, configuration or Git changes in this source phase.',
      'No security/permission/authTLS, negative/error/failure/cancel/crash, mixed/directory suites, budget/truncation/threshold/eviction/race, realprovider or remoteMCP verification.',
    ],
  };
}
export async function writeInworldSpeechContract(root, output) {
  const capture = await captureInworldSpeechContract(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
export async function runCLIFromArgs(args) {
  let root = '/tmp/openclaw-488631c', output;
  if (args.length && !args[0].startsWith('--')) {
    assert.ok(args.length <= 2, 'Usage: capture-inworld-speech-contract.mjs [ROOT [OUTPUT]]');
    [root, output] = args;
  } else {
    for (let index = 0; index < args.length; index += 2) {
      assert.ok(['--source', '--output'].includes(args[index]) && args[index + 1],
        'Usage: capture-inworld-speech-contract.mjs --source DIR [--output FILE]');
      if (args[index] === '--source') root = args[index + 1];
      else output = args[index + 1];
    }
  }
  if (output) return writeInworldSpeechContract(root, output);
  const capture = await captureInworldSpeechContract(root);
  process.stdout.write(JSON.stringify(capture, null, 2) + '\n');
  return capture;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await runCLIFromArgs(process.argv.slice(2));
}
