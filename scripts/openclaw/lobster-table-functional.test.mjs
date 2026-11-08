// Independent table.js ordinary-success literals frozen before product/capture edits.
// No missing/undefined, mixed, negative, security, provider or resource-bound cases.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureLobsterTable } from './capture-lobster-table.mjs';

const EXPECTED_CASES = [
  {
    "id": "false-array-preserves-original-roots",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": false,
    "observeReferences": "items",
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
              "x": "a"
            },
            {
              "x": "b"
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
          1
        ]
      }
    ]
  },
  {
    "id": "false-iterator-preserves-original-roots",
    "pipeline": "table",
    "inputKind": "iterator_items",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": false,
    "observeReferences": "items",
    "runs": [
      {
        "trace": [
          "run:table",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "table": 1
          },
          "input": {
            "opens": 1,
            "yields": 2,
            "finishes": 1
          }
        },
        "result": {
          "items": [
            {
              "x": "a"
            },
            {
              "x": "b"
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
          1
        ]
      }
    ]
  },
  {
    "id": "false-downstream-zero-keeps-input-unopened",
    "pipeline": "table | head --n 0",
    "inputKind": "iterator_items",
    "input": [
      "a",
      "b"
    ],
    "renderOutput": false,
    "runs": [
      {
        "trace": [
          "run:table",
          "run:head"
        ],
        "counters": {
          "constructors": {
            "table": 1,
            "head": 1
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
    "id": "true-eager-despite-downstream-zero",
    "pipeline": "table | head --n 0",
    "inputKind": "iterator_items",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "b"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:finally",
          "run:head"
        ],
        "counters": {
          "constructors": {
            "table": 1,
            "head": 1
          },
          "input": {
            "opens": 1,
            "yields": 2,
            "finishes": 1
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": true,
          "renderedItems": [],
          "stdout": "x  \n---\na  \nb  \n"
        }
      }
    ]
  },
  {
    "id": "empty-iterator-renders-no-results",
    "pipeline": "table",
    "inputKind": "iterator_items",
    "input": [],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table",
          "input:open",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "table": 1
          },
          "input": {
            "opens": 1,
            "yields": 0,
            "finishes": 1
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": true,
          "renderedItems": [],
          "stdout": "(no results)\n"
        }
      }
    ]
  },
  {
    "id": "empty-array-renders-no-results",
    "pipeline": "table",
    "inputKind": "array",
    "input": [],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "(no results)\n"
        }
      }
    ]
  },
  {
    "id": "sample-twenty-excludes-last-extra-key",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "a"
      },
      {
        "x": "long",
        "extra": "ignored"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "x   \n----\na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \nlong\n"
        }
      }
    ]
  },
  {
    "id": "own-numeric-keys-order-before-insertion-keys",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "10": "ten",
        "2": "two",
        "z": "zee",
        "01": "one"
      },
      {
        "01": "uno",
        "z": "zed",
        "2": "dos",
        "10": "dix"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "2    10   z    01 \n---  ---  ---  ---\ntwo  ten  zee  one\ndos  dix  zed  uno\n"
        }
      }
    ]
  },
  {
    "id": "utf16-supplementary-header-and-cell-width",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "😀😀": "𐀀𐀀𐀀",
        "k": "x"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "😀😀    k  \n------  ---\n𐀀𐀀𐀀  x  \n"
        }
      }
    ]
  },
  {
    "id": "min-three-and-final-column-padding",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "a": "x",
        "b": "y"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "a    b  \n---  ---\nx    y  \n"
        }
      }
    ]
  },
  {
    "id": "table-header-and-cell-flatten-only-lf",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "h\n\r": "a\nb\rc"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "h \r  \n-----\na b\rc\n"
        }
      }
    ]
  },
  {
    "id": "strings-fallback-keeps-lf-and-cr",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      "a\nb",
      "c\rd"
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "a\nb\nc\rd\n"
        }
      }
    ]
  },
  {
    "id": "arrays-fallback-compact-json",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      [
        1,
        2
      ],
      [
        3
      ]
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "[1,2]\n[3]\n"
        }
      }
    ]
  },
  {
    "id": "numbers-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      1,
      1.25,
      -2
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "1\n1.25\n-2\n"
        }
      }
    ]
  },
  {
    "id": "booleans-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      true,
      false
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "true\nfalse\n"
        }
      }
    ]
  },
  {
    "id": "null-fallback",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      null,
      null
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "\n\n"
        }
      }
    ]
  },
  {
    "id": "number-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "n": 1
      },
      {
        "n": 1.25
      },
      {
        "n": -2
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "n   \n----\n1   \n1.25\n-2  \n"
        }
      }
    ]
  },
  {
    "id": "boolean-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "b": true
      },
      {
        "b": false
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "b    \n-----\ntrue \nfalse\n"
        }
      }
    ]
  },
  {
    "id": "null-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "n": null
      },
      {
        "n": null
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "n  \n---\n   \n   \n"
        }
      }
    ]
  },
  {
    "id": "array-valued-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "v": [
          1,
          2
        ]
      },
      {
        "v": [
          3
        ]
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "v    \n-----\n[1,2]\n[3]  \n"
        }
      }
    ]
  },
  {
    "id": "object-valued-cells",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {
        "v": {
          "a": 1
        }
      },
      {
        "v": {
          "a": 2
        }
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "v      \n-------\n{\"a\":1}\n{\"a\":2}\n"
        }
      }
    ]
  },
  {
    "id": "zero-columns-empty-own-objects",
    "pipeline": "table",
    "inputKind": "array",
    "input": [
      {},
      {}
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table"
        ],
        "counters": {
          "constructors": {
            "table": 1
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
          "renderedItems": [],
          "stdout": "\n\n\n\n"
        }
      }
    ]
  },
  {
    "id": "upstream-head-normal-return",
    "pipeline": "head --n 2 | table",
    "inputKind": "iterator_items",
    "input": [
      "a",
      "b",
      "c"
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:head",
          "run:table",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "head": 1,
            "table": 1
          },
          "input": {
            "opens": 1,
            "yields": 2,
            "finishes": 1
          }
        },
        "result": {
          "items": [],
          "halted": false,
          "haltedAt": null,
          "executionStarted": true,
          "rendered": true,
          "renderedItems": [],
          "stdout": "a\nb\n"
        }
      }
    ]
  },
  {
    "id": "rendered-empty-generator-feeds-json",
    "pipeline": "table | json",
    "inputKind": "array",
    "input": [
      {
        "x": "a"
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:table",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "table": 1,
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
          "renderedItems": [],
          "stdout": "x  \n---\na  \n[]\n"
        }
      }
    ]
  }
];

const captured = await captureLobsterTable({
  referenceRoot: '/tmp/openclaw-488631c',
  archive: '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
  dependencies: '/tmp/synapsis-workflow186-fydsjreq/npm/manifest.json',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole reference table source matches complete independent ordinary observations', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('table provenance uses the fixed archive and complete unmodified source modules', () => {
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
  const hashes = Object.fromEntries(captured.sourceRecords.map(({ path, sha256 }) => [path, sha256]));
  assert.equal(hashes['package/dist/src/commands/stdlib/table.js'], 'a95a58ca8153f97596e7bf5eb1236e25c0ebdd0ddbf416fadcf2a4f4d07dd13e');
  assert.equal(hashes['package/dist/src/runtime.js'], '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53');
  assert.equal(hashes['package/dist/src/input_request.js'], '4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4');
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.equal(captured.harness.path, 'scripts/openclaw/capture-lobster-table.mjs');
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-table.mjs', import.meta.url))));
  assert.equal(captured.license.sha256, '0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb');
  assert.equal(captured.license.sha256, digest(captured.license.text));
});

test('fresh table capture equals every field of the frozen fixture', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-table.json', import.meta.url)));
  assert.deepEqual(frozen.cases, EXPECTED_CASES);
  assert.deepEqual(captured, frozen);
});
