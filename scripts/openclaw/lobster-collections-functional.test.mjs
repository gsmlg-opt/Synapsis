// Independent ordinary-success literals frozen before collection product/capture.
// Complete unchanged reference modules execute in the capture; input lifecycle,
// strict-reference and zero-sign checks are observations of original values.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureLobsterCollections } from './capture-lobster-collections.mjs';

const EXPECTED_CASES = [
  {
    "id": "sort-eager-before-zero-demand",
    "pipeline": "sort | head --n 0 | json",
    "inputKind": "iterator_items",
    "input": [
      3,
      1,
      2
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:yield:2",
          "input:finally",
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "head": 1,
            "json": 1
          },
          "input": {
            "opens": 1,
            "yields": 3,
            "finishes": 1
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "group-eager-before-zero-demand",
    "pipeline": "groupBy --key k | head --n 0 | json",
    "inputKind": "iterator_items",
    "input": [
      {
        "k": "b"
      },
      {
        "k": "a"
      },
      {
        "k": "b"
      }
    ],
    "runs": [
      {
        "trace": [
          "run:groupBy",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:yield:2",
          "input:finally",
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "groupBy": 1,
            "head": 1,
            "json": 1
          },
          "input": {
            "opens": 1,
            "yields": 3,
            "finishes": 1
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "dedupe-zero-demand-stays-lazy",
    "pipeline": "dedupe | head --n 0 | json",
    "inputKind": "iterator_items",
    "input": [
      1,
      1,
      2
    ],
    "runs": [
      {
        "trace": [
          "run:dedupe",
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "dedupe": 1,
            "head": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "dedupe-skip-then-normal-return",
    "pipeline": "dedupe | head --n 2 | json",
    "inputKind": "iterator_items",
    "input": [
      2,
      2,
      1,
      3
    ],
    "runs": [
      {
        "trace": [
          "run:dedupe",
          "run:head",
          "run:json",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:yield:2",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "dedupe": 1,
            "head": 1,
            "json": 1
          },
          "input": {
            "opens": 1,
            "yields": 3,
            "finishes": 1
          }
        },
        "result": {
          "items": [
            2,
            1
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "sort-default-numeric",
    "pipeline": "sort | json",
    "inputKind": "array",
    "input": [
      10,
      2,
      1
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            1,
            2,
            10
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "sort-utf16-empty-desc-is-false",
    "pipeline": "sort --desc='' | json",
    "inputKind": "array",
    "input": [
      "",
      "😀",
      "a",
      "𐀀"
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            "a",
            "𐀀",
            "😀",
            ""
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "sort-nested-desc-string-stable-ties",
    "pipeline": "sort --key .meta..rank. --desc=false | pick id | json",
    "inputKind": "array",
    "input": [
      {
        "id": "a",
        "meta": {
          "rank": 2
        }
      },
      {
        "id": "b",
        "meta": {
          "rank": 3
        }
      },
      {
        "id": "c",
        "meta": {
          "rank": 2
        }
      }
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "pick": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "id": "b"
            },
            {
              "id": "a"
            },
            {
              "id": "c"
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "optional-keys-retain-literal-whitespace",
    "pipeline": "sort --key ' k ' | dedupe --key ' k ' | pick id | json",
    "inputKind": "array",
    "input": [
      {
        "id": "a",
        " k ": 2
      },
      {
        "id": "b",
        " k ": 1
      },
      {
        "id": "c",
        " k ": 2
      }
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:dedupe",
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "dedupe": 1,
            "pick": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "id": "b"
            },
            {
              "id": "a"
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "arrays-string-sort-json-dedupe-empty-key",
    "pipeline": "sort --key '' | dedupe --key '' | json",
    "inputKind": "array",
    "input": [
      [
        2
      ],
      [
        10
      ],
      [
        2
      ],
      [
        1,
        2
      ]
    ],
    "observeReferences": "items",
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:dedupe",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "dedupe": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            [
              1,
              2
            ],
            [
              10
            ],
            [
              2
            ]
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputInputIndices": [
          3,
          1,
          0
        ]
      }
    ]
  },
  {
    "id": "array-index-then-length-composition",
    "pipeline": "sort --key 0 | dedupe --key 0 | groupBy --key length | pick key,count | json",
    "inputKind": "array",
    "input": [
      [
        2,
        8
      ],
      [
        1
      ],
      [
        2,
        9
      ],
      [
        3
      ]
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:dedupe",
          "run:groupBy",
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "dedupe": 1,
            "groupBy": 1,
            "pick": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "key": 1,
              "count": 2
            },
            {
              "key": 2,
              "count": 1
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "dedupe-object-json-order-and-original-roots",
    "pipeline": "dedupe | json",
    "inputKind": "array",
    "input": [
      {
        "a": 1,
        "b": 2
      },
      {
        "a": 1,
        "b": 2
      },
      {
        "b": 2,
        "a": 1
      }
    ],
    "observeReferences": "items",
    "runs": [
      {
        "trace": [
          "run:dedupe",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "dedupe": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "a": 1,
              "b": 2
            },
            {
              "b": 2,
              "a": 1
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputInputIndices": [
          0,
          2
        ]
      }
    ]
  },
  {
    "id": "group-explicit-null-only",
    "pipeline": "groupBy --key k | json",
    "inputKind": "array",
    "input": [
      {
        "k": null,
        "id": 1
      },
      {
        "k": null,
        "id": 2
      }
    ],
    "observeOwnFields": true,
    "runs": [
      {
        "trace": [
          "run:groupBy",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "groupBy": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "key": null,
              "items": [
                {
                  "k": null,
                  "id": 1
                },
                {
                  "k": null,
                  "id": 2
                }
              ],
              "count": 2
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputOwnFields": [
          {
            "keys": [
              "key",
              "items",
              "count"
            ],
            "undefinedKeys": []
          }
        ]
      }
    ]
  },
  {
    "id": "dedupe-zero-sign-keeps-first-root",
    "pipeline": "dedupe | json",
    "inputKind": "array",
    "input": [
      0,
      0,
      0
    ],
    "inputJson": "[-0,0,-0]",
    "observeNegativeZero": true,
    "runs": [
      {
        "trace": [
          "run:dedupe",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "dedupe": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            0
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputNegativeZero": [
          true
        ]
      }
    ]
  },
  {
    "id": "group-trimmed-nested-key-and-first-appearance",
    "pipeline": "groupBy --key ' .meta..label. ' | pick key,count | json",
    "inputKind": "array",
    "input": [
      {
        "meta": {
          "label": "b"
        },
        "id": 1
      },
      {
        "meta": {
          "label": "a"
        },
        "id": 2
      },
      {
        "meta": {
          "label": "b"
        },
        "id": 3
      }
    ],
    "runs": [
      {
        "trace": [
          "run:groupBy",
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "groupBy": 1,
            "pick": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "key": "b",
              "count": 2
            },
            {
              "key": "a",
              "count": 1
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "group-object-json-identity-first-key-reference",
    "pipeline": "groupBy --key k | json",
    "inputKind": "array",
    "input": [
      {
        "k": {
          "a": 1,
          "b": 2
        },
        "id": 1
      },
      {
        "k": {
          "a": 1,
          "b": 2
        },
        "id": 2
      },
      {
        "k": {
          "b": 2,
          "a": 1
        },
        "id": 3
      }
    ],
    "observeReferences": "groups",
    "observeOwnFields": true,
    "runs": [
      {
        "trace": [
          "run:groupBy",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "groupBy": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "key": {
                "a": 1,
                "b": 2
              },
              "items": [
                {
                  "k": {
                    "a": 1,
                    "b": 2
                  },
                  "id": 1
                },
                {
                  "k": {
                    "a": 1,
                    "b": 2
                  },
                  "id": 2
                }
              ],
              "count": 2
            },
            {
              "key": {
                "b": 2,
                "a": 1
              },
              "items": [
                {
                  "k": {
                    "b": 2,
                    "a": 1
                  },
                  "id": 3
                }
              ],
              "count": 1
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputGroupReferences": [
          {
            "keyInputIndices": [
              0
            ],
            "memberInputIndices": [
              0,
              1
            ]
          },
          {
            "keyInputIndices": [
              2
            ],
            "memberInputIndices": [
              2
            ]
          }
        ],
        "outputOwnFields": [
          {
            "keys": [
              "key",
              "items",
              "count"
            ],
            "undefinedKeys": []
          },
          {
            "keys": [
              "key",
              "items",
              "count"
            ],
            "undefinedKeys": []
          }
        ]
      }
    ]
  },
  {
    "id": "group-array-json-key-retains-first-key",
    "pipeline": "groupBy --key k | json",
    "inputKind": "array",
    "input": [
      {
        "k": [
          1,
          2
        ],
        "id": 1
      },
      {
        "k": [
          2,
          1
        ],
        "id": 2
      },
      {
        "k": [
          1,
          2
        ],
        "id": 3
      }
    ],
    "observeReferences": "groups",
    "runs": [
      {
        "trace": [
          "run:groupBy",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "groupBy": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            {
              "key": [
                1,
                2
              ],
              "items": [
                {
                  "k": [
                    1,
                    2
                  ],
                  "id": 1
                },
                {
                  "k": [
                    1,
                    2
                  ],
                  "id": 3
                }
              ],
              "count": 2
            },
            {
              "key": [
                2,
                1
              ],
              "items": [
                {
                  "k": [
                    2,
                    1
                  ],
                  "id": 2
                }
              ],
              "count": 1
            }
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        },
        "outputGroupReferences": [
          {
            "keyInputIndices": [
              0
            ],
            "memberInputIndices": [
              0,
              2
            ]
          },
          {
            "keyInputIndices": [
              1
            ],
            "memberInputIndices": [
              1
            ]
          }
        ]
      }
    ]
  },
  {
    "id": "composed-trio-terminal-pretty-json",
    "pipeline": "sort --key rank | dedupe --key k | groupBy --key k | pick key,count | json",
    "inputKind": "array",
    "input": [
      {
        "rank": 3,
        "k": "b"
      },
      {
        "rank": 1,
        "k": "a"
      },
      {
        "rank": 2,
        "k": "a"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:sort",
          "run:dedupe",
          "run:groupBy",
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "dedupe": 1,
            "groupBy": 1,
            "pick": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": true,
          "renderedItems": [
            {
              "key": "a",
              "count": 1
            },
            {
              "key": "b",
              "count": 1
            }
          ],
          "stdout": "[\n  {\n    \"key\": \"a\",\n    \"count\": 1\n  },\n  {\n    \"key\": \"b\",\n    \"count\": 1\n  }\n]\n"
        }
      }
    ]
  },
  {
    "id": "collection-preview-same-stage-fresh-resume",
    "pipeline": "sort | dedupe | groupBy --key length | pick key,count | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
    "inputKind": "iterator_items",
    "input": [
      "bb",
      "a",
      "bb"
    ],
    "responses": [
      {
        "mode": "same_stage",
        "response": "continue"
      }
    ],
    "runs": [
      {
        "trace": [
          "run:sort",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:yield:2",
          "input:finally",
          "run:dedupe",
          "run:groupBy",
          "run:pick",
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "sort": 1,
            "dedupe": 1,
            "groupBy": 1,
            "pick": 1,
            "ask": 1
          },
          "input": {
            "opens": 1,
            "yields": 3,
            "finishes": 1
          }
        },
        "result": {
          "items": [
            {
              "type": "input_request",
              "prompt": "Review",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "{\"key\":1,\"count\":1}\n{\"key\":2,\"count\":1}"
              },
              "items": [],
              "commandInput": {
                "pending": {
                  "requestIndex": 0,
                  "metadata": {
                    "prompt": "Review",
                    "responseSchema": {
                      "type": "string"
                    },
                    "subject": {
                      "text": "{\"key\":1,\"count\":1}\n{\"key\":2,\"count\":1}"
                    },
                    "signature": "{\"prompt\":\"Review\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"{\\\"key\\\":1,\\\"count\\\":1}\\n{\\\"key\\\":2,\\\"count\\\":1}\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "{\"key\":1,\"count\":1}\n{\"key\":2,\"count\":1}"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 4,
            "name": "ask",
            "inPlace": true
          },
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      },
      {
        "trace": [
          "run:ask",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "ask": 1,
            "json": 1
          },
          "input": {
            "opens": 0,
            "yields": 0,
            "finishes": 0
          }
        },
        "result": {
          "items": [
            "continue"
          ],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  }
];

const captured = await captureLobsterCollections({
  referenceRoot: '/tmp/openclaw-488631c',
  archive: '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
  dependencies: '/tmp/synapsis-workflow186-fydsjreq/npm/manifest.json',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole source matches literal eager, lazy, identity, reference, rendering and resume observations', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('source provenance preserves the actual Ajv profile and explicit native and persistence limits', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(captured.sourcePackage.name, '@clawdbot/lobster');
  assert.equal(captured.sourcePackage.version, '2026.9.16');
  assert.equal(captured.sourcePackage.integrity, 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==');
  assert.equal(captured.sourcePackage.installed, false);
  assert.equal(captured.executedWorkflowRuntime, true);
  assert.equal(captured.productionCatalogInstalled, false);
  assert.equal(captured.checkpointPersistenceExecuted, false);
  assert.equal(captured.fullToolRuntimeExecuted, false);
  assert.equal(captured.nativeToolExecution, false);
  assert.deepEqual(captured.dependencies.map(({ name, version }) => ({ name, version })).sort((a, b) => a.name.localeCompare(b.name)), [
    { name: 'ajv', version: '8.20.0' },
    { name: 'fast-deep-equal', version: '3.1.3' },
    { name: 'json-schema-traverse', version: '1.0.0' },
    { name: 'require-from-string', version: '2.0.2' },
    { name: 'fast-uri', version: '4.2.2' },
  ].sort((a, b) => a.name.localeCompare(b.name)));
});

test('all sixteen unchanged source modules include the real shared path helper with exact archive hashes', () => {
  const hashes = {
    "package/dist/src/command_tokens.js": "a8cd45e37b2348cc3f847c1b06b2e2959594f360e05521f3ae45f57966a495fa",
    "package/dist/src/commands/stdlib/ask.js": "9133cbe30bddd28d322d3017f428317a6f98ab2bd9f43992b9f74594e3af6537",
    "package/dist/src/commands/stdlib/head.js": "3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1",
    "package/dist/src/commands/stdlib/json.js": "9e3f24e0a2bcba55e466f300901fd0f0b2d079fa075a55ee296c54201df76b58",
    "package/dist/src/commands/stdlib/pick.js": "3d224840f187aa86c8414873f3782827e80e0ef9e176c085ceb2bb05f12d402c",
    "package/dist/src/input_request.js": "4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4",
    "package/dist/src/parser.js": "e8f3f5cc67b1739b7347da70ea9a543d68f8e5f622387910d0202bb0f5b030ce",
    "package/dist/src/renderers/json.js": "1a739a179aacb410add5fe954aec53e05fc89434b8e0aa8d8718b69fabfce681",
    "package/dist/src/runtime.js": "7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53",
    "package/dist/src/state/atomic_file.js": "87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5",
    "package/dist/src/state/store.js": "8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c",
    "package/dist/src/validation.js": "a9e087f2b5502be86dc223f2746c1d598446d4c1b5537f697003418417933f6b",
    "package/dist/src/commands/stdlib/sort.js": "a3d7fca0d780ebaac95e461703f27a8b4623ce40ac6f9e8e5d0d5eea5665d90f",
    "package/dist/src/commands/stdlib/dedupe.js": "44884031087e54b4c10210b615827ab4852d72dd203e61ff6ad792ce1ae85f4f",
    "package/dist/src/commands/stdlib/group_by.js": "60befdc46480c45bf0d1c869a603780348fcf0b62b66a5cc34e4ef860d106cdc",
    "package/dist/src/core/value_path.js": "e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f"
};
  assert.equal(captured.sourceRecords.length, 16);
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(({ path, sha256 }) => [path, sha256])), hashes);
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.deepEqual(captured.referenceRecords.map(({ path }) => path), [
    'extensions/lobster/package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'package.json',
  ]);
  assert.equal(captured.harness.path, 'scripts/openclaw/capture-lobster-collections.mjs');
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-collections.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, '0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb');
  assert.equal(captured.license.sha256, digest(captured.license.text));
});

test('fresh collections capture equals every field of the frozen fixture', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-collections.json', import.meta.url)));
  assert.deepEqual(frozen.cases, EXPECTED_CASES);
  assert.deepEqual(captured, frozen);
});
