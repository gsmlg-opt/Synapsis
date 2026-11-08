// Independently authored ordinary-success literals, frozen before capture/product.
// Initial lazy input and lifecycle events are harness observations of a real
// async generator. Actual pinned source/Ajv execute; no host validator claim.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureLobsterMachine } from './capture-lobster-machine.mjs';

const EXPECTED_CASES = [
  {
    "id": "constructors-before-zero-demand",
    "pipeline": "pick id | head --n 0 | json",
    "inputKind": "iterator_items",
    "input": [
      {
        "id": 1
      },
      {
        "id": 2
      }
    ],
    "runs": [
      {
        "trace": [
          "run:pick",
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
            "pick": 1,
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
    "id": "fractional-demand-and-return",
    "pipeline": "head --n 1.5 | pick id | json",
    "inputKind": "iterator_items",
    "input": [
      {
        "id": 1
      },
      {
        "id": 2
      },
      {
        "id": 3
      }
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:pick",
          "run:json",
          "input:open",
          "input:yield:0",
          "input:yield:1",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "head": 1,
            "pick": 1,
            "json": 1
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
              "id": 1
            },
            {
              "id": 2
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
    "id": "per-pull-undefined",
    "pipeline": "pick \" id , absent \" | head --n 1 | json",
    "inputKind": "iterator_items",
    "input": [
      {
        "id": 1,
        "extra": true
      },
      {
        "id": 2
      }
    ],
    "observeOwnFields": true,
    "runs": [
      {
        "trace": [
          "run:pick",
          "run:head",
          "run:json",
          "input:open",
          "input:yield:0",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "pick": 1,
            "head": 1,
            "json": 1
          },
          "input": {
            "opens": 1,
            "yields": 1,
            "finishes": 1
          }
        },
        "result": {
          "items": [
            {
              "id": 1
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
              "id",
              "absent"
            ],
            "undefinedKeys": [
              "absent"
            ]
          }
        ]
      }
    ]
  },
  {
    "id": "array-index-length-and-noncanonical",
    "pipeline": "pick \" 0 , length , 01 , missing \" | json",
    "inputKind": "array",
    "input": [
      [
        "first",
        "second"
      ]
    ],
    "observeOwnFields": true,
    "runs": [
      {
        "trace": [
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
              "0": "first",
              "length": 2
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
              "0",
              "length",
              "01",
              "missing"
            ],
            "undefinedKeys": [
              "01",
              "missing"
            ]
          }
        ]
      }
    ]
  },
  {
    "id": "unicode-field-trim",
    "pipeline": "pick \"﻿id , absent \" | json",
    "inputKind": "array",
    "input": [
      {
        "id": 1
      }
    ],
    "observeOwnFields": true,
    "runs": [
      {
        "trace": [
          "run:pick",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
              "id": 1
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
              "id",
              "absent"
            ],
            "undefinedKeys": [
              "absent"
            ]
          }
        ]
      }
    ]
  },
  {
    "id": "head-empty-string",
    "pipeline": "head --n \"\" | json",
    "inputKind": "array",
    "input": [
      "a",
      "b",
      "c"
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
    "id": "head-hex",
    "pipeline": "head --n 0x2 | json",
    "inputKind": "array",
    "input": [
      "a",
      "b",
      "c"
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
          "items": [
            "a",
            "b"
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
    "id": "head-boolean-flag",
    "pipeline": "head --n | json",
    "inputKind": "array",
    "input": [
      "a",
      "b",
      "c"
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
          "items": [
            "a"
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
    "id": "head-finite-decimal",
    "pipeline": "head --n 2.0 | json",
    "inputKind": "array",
    "input": [
      "a",
      "b",
      "c"
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:json"
        ],
        "counters": {
          "constructors": {
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
          "items": [
            "a",
            "b"
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
    "id": "json-tracker-is-lazy-before-ask",
    "pipeline": "json | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
    "inputKind": "array",
    "input": [
      "draft"
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
          "run:json",
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "json": 1,
            "ask": 1
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
              "type": "input_request",
              "prompt": "Review",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "draft"
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
                      "text": "draft"
                    },
                    "signature": "{\"prompt\":\"Review\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"draft\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "draft"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 1,
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
  },
  {
    "id": "actual-array-replay",
    "pipeline": "ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
    "inputKind": "array",
    "input": [
      "draft"
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
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "ask": 1
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
              "type": "input_request",
              "prompt": "Review",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "draft"
              },
              "items": [
                "draft"
              ],
              "commandInput": {
                "pending": {
                  "requestIndex": 0,
                  "metadata": {
                    "prompt": "Review",
                    "responseSchema": {
                      "type": "string"
                    },
                    "subject": {
                      "text": "draft"
                    },
                    "signature": "{\"prompt\":\"Review\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"draft\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "draft"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 0,
            "name": "ask",
            "inPlace": true
          },
          "executionStarted": false,
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
  },
  {
    "id": "preserved-subject-and-prefix-slice",
    "pipeline": "head --n 1 | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
    "inputKind": "iterator_items",
    "input": [
      "draft",
      "later"
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
          "run:head",
          "run:ask",
          "input:open",
          "input:yield:0",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "head": 1,
            "ask": 1
          },
          "input": {
            "opens": 1,
            "yields": 1,
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
                "text": "draft"
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
                      "text": "draft"
                    },
                    "signature": "{\"prompt\":\"Review\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"draft\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "draft"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 1,
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
  },
  {
    "id": "emit-next-stage-slice",
    "pipeline": "head --n 1 | ask --prompt Review --schema '{\"type\":\"boolean\"}' --emit | json",
    "inputKind": "iterator_items",
    "input": [
      "draft",
      "later"
    ],
    "responses": [
      {
        "mode": "next_stage",
        "response": true
      }
    ],
    "runs": [
      {
        "trace": [
          "run:head",
          "run:ask",
          "input:open",
          "input:yield:0",
          "input:finally"
        ],
        "counters": {
          "constructors": {
            "head": 1,
            "ask": 1
          },
          "input": {
            "opens": 1,
            "yields": 1,
            "finishes": 1
          }
        },
        "result": {
          "items": [
            {
              "type": "input_request",
              "prompt": "Review",
              "responseSchema": {
                "type": "boolean"
              },
              "items": [
                "draft"
              ]
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 1,
            "name": "ask",
            "inPlace": false
          },
          "executionStarted": true,
          "rendered": false,
          "renderedItems": []
        }
      },
      {
        "trace": [
          "run:json"
        ],
        "counters": {
          "constructors": {
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
            true
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
    "id": "sequential-asks",
    "pipeline": "ask --prompt First --schema '{\"type\":\"string\"}' --subject-from-stdin | ask --prompt Second --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
    "inputKind": "array",
    "input": [
      "draft"
    ],
    "responses": [
      {
        "mode": "same_stage",
        "response": "alpha"
      },
      {
        "mode": "same_stage",
        "response": "beta"
      }
    ],
    "runs": [
      {
        "trace": [
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "ask": 1
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
              "type": "input_request",
              "prompt": "First",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "draft"
              },
              "items": [
                "draft"
              ],
              "commandInput": {
                "pending": {
                  "requestIndex": 0,
                  "metadata": {
                    "prompt": "First",
                    "responseSchema": {
                      "type": "string"
                    },
                    "subject": {
                      "text": "draft"
                    },
                    "signature": "{\"prompt\":\"First\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"draft\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "draft"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 0,
            "name": "ask",
            "inPlace": true
          },
          "executionStarted": false,
          "rendered": false,
          "renderedItems": []
        }
      },
      {
        "trace": [
          "run:ask",
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "ask": 2
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
              "type": "input_request",
              "prompt": "Second",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "alpha"
              },
              "items": [],
              "commandInput": {
                "pending": {
                  "requestIndex": 0,
                  "metadata": {
                    "prompt": "Second",
                    "responseSchema": {
                      "type": "string"
                    },
                    "subject": {
                      "text": "alpha"
                    },
                    "signature": "{\"prompt\":\"Second\",\"responseSchema\":{\"type\":\"string\"},\"subject\":{\"text\":\"alpha\"}}"
                  },
                  "suspendedState": {
                    "type": "ask",
                    "subject": {
                      "text": "alpha"
                    }
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 1,
            "name": "ask",
            "inPlace": true
          },
          "executionStarted": false,
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
            "beta"
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
    "id": "renderer-before-zero-head",
    "pipeline": "pick id,label | json | head --n 0",
    "inputKind": "array",
    "input": [
      {
        "id": 1,
        "label": "一",
        "extra": true
      }
    ],
    "renderOutput": true,
    "runs": [
      {
        "trace": [
          "run:pick",
          "run:json",
          "run:head"
        ],
        "counters": {
          "constructors": {
            "pick": 1,
            "json": 1,
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
          "rendered": true,
          "renderedItems": [
            {
              "id": 1,
              "label": "一"
            }
          ],
          "stdout": "[\n  {\n    \"id\": 1,\n    \"label\": \"一\"\n  }\n]\n"
        }
      }
    ]
  },
  {
    "id": "ask-defaults",
    "pipeline": "ask",
    "inputKind": "array",
    "input": [
      "draft"
    ],
    "runs": [
      {
        "trace": [
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "ask": 1
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
              "type": "input_request",
              "prompt": "Input required",
              "responseSchema": {
                "type": "object",
                "properties": {
                  "decision": {
                    "type": "string",
                    "enum": [
                      "approve",
                      "reject",
                      "redraft"
                    ]
                  },
                  "feedback": {
                    "type": "string",
                    "description": "Feedback for redraft"
                  }
                },
                "required": [
                  "decision"
                ]
              },
              "items": [
                "draft"
              ],
              "commandInput": {
                "pending": {
                  "requestIndex": 0,
                  "metadata": {
                    "prompt": "Input required",
                    "responseSchema": {
                      "type": "object",
                      "properties": {
                        "decision": {
                          "type": "string",
                          "enum": [
                            "approve",
                            "reject",
                            "redraft"
                          ]
                        },
                        "feedback": {
                          "type": "string",
                          "description": "Feedback for redraft"
                        }
                      },
                      "required": [
                        "decision"
                      ]
                    },
                    "signature": "{\"prompt\":\"Input required\",\"responseSchema\":{\"properties\":{\"decision\":{\"enum\":[\"approve\",\"reject\",\"redraft\"],\"type\":\"string\"},\"feedback\":{\"description\":\"Feedback for redraft\",\"type\":\"string\"}},\"required\":[\"decision\"],\"type\":\"object\"}}"
                  },
                  "suspendedState": {
                    "type": "ask"
                  }
                },
                "history": []
              }
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 0,
            "name": "ask",
            "inPlace": true
          },
          "executionStarted": false,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  },
  {
    "id": "ask-string-flags-are-truthy",
    "pipeline": "ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin=false --emit=false",
    "inputKind": "array",
    "input": [
      "draft"
    ],
    "runs": [
      {
        "trace": [
          "run:ask"
        ],
        "counters": {
          "constructors": {
            "ask": 1
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
              "type": "input_request",
              "prompt": "Review",
              "responseSchema": {
                "type": "string"
              },
              "subject": {
                "text": "draft"
              },
              "items": [
                "draft"
              ]
            }
          ],
          "halted": true,
          "haltedAt": {
            "index": 0,
            "name": "ask",
            "inPlace": false
          },
          "executionStarted": false,
          "rendered": false,
          "renderedItems": []
        }
      }
    ]
  }
];

const captured = await captureLobsterMachine({
  referenceRoot: '/tmp/openclaw-488631c',
  archive: '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
  dependencies: '/tmp/synapsis-workflow186-fydsjreq/npm/manifest.json',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole pinned runtime matches literal constructor, pull, replay, resume and rendering observations', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('provenance records the source and actual Ajv dependencies while native driver execution stays open', () => {
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
    { name: 'fast-uri', version: '4.2.2' },
    { name: 'json-schema-traverse', version: '1.0.0' },
    { name: 'require-from-string', version: '2.0.2' },
  ]);
});

test('whole unchanged modules, reference records and the published license are identified by exact hashes', () => {
  const hashes = {
    'package/dist/src/command_tokens.js': 'a8cd45e37b2348cc3f847c1b06b2e2959594f360e05521f3ae45f57966a495fa',
    'package/dist/src/commands/stdlib/ask.js': '9133cbe30bddd28d322d3017f428317a6f98ab2bd9f43992b9f74594e3af6537',
    'package/dist/src/commands/stdlib/head.js': '3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1',
    'package/dist/src/commands/stdlib/json.js': '9e3f24e0a2bcba55e466f300901fd0f0b2d079fa075a55ee296c54201df76b58',
    'package/dist/src/commands/stdlib/pick.js': '3d224840f187aa86c8414873f3782827e80e0ef9e176c085ceb2bb05f12d402c',
    'package/dist/src/input_request.js': '4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4',
    'package/dist/src/parser.js': 'e8f3f5cc67b1739b7347da70ea9a543d68f8e5f622387910d0202bb0f5b030ce',
    'package/dist/src/renderers/json.js': '1a739a179aacb410add5fe954aec53e05fc89434b8e0aa8d8718b69fabfce681',
    'package/dist/src/runtime.js': '7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53',
    'package/dist/src/state/atomic_file.js': '87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5',
    'package/dist/src/state/store.js': '8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c',
    'package/dist/src/validation.js': 'a9e087f2b5502be86dc223f2746c1d598446d4c1b5537f697003418417933f6b',
  };
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(({ path, sha256 }) => [path, sha256])), hashes);
  for (const row of captured.sourceRecords) {
    assert.equal(row.wholeModule, true, row.path);
    assert.equal(row.executed, true, row.path);
  }
  assert.deepEqual(captured.referenceRecords.map(({ path }) => path), [
    'extensions/lobster/package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'package.json',
  ]);
  assert.equal(captured.harness.path, 'scripts/openclaw/capture-lobster-machine.mjs');
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-machine.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, '0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb');
  assert.equal(captured.license.sha256, digest(captured.license.text));
});

test('fresh source capture exactly reproduces every frozen machine-oracle fixture field', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-machine.json', import.meta.url)));
  assert.deepEqual(fixture.cases, EXPECTED_CASES);
  assert.deepEqual(captured, fixture);
});
