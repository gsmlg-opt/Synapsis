// Execute the four unchanged pinned modules for message-mode heartbeat text presentation only.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const EVENT_REPLY_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'src/auto-reply/heartbeat.ts';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const wholeSources = [
  entry,
  'packages/normalization-core/src/string-coerce.ts',
  'src/shared/regexp.ts',
  'src/auto-reply/tokens.ts',
];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), EVENT_REPLY_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', EVENT_REPLY_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: hash(bytes) };
  });
  return {
    tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: EVENT_REPLY_PIN,
      tree: git(root, ['rev-parse', `${EVENT_REPLY_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}

const vectors = [
  {
    "id": "exact-ack",
    "raw": "HEARTBEAT_OK",
    "expected": {
      "shouldSkip": true,
      "text": "",
      "didStrip": true
    }
  },
  {
    "id": "prefix-meaningful",
    "raw": "HEARTBEAT_OK all good",
    "expected": {
      "shouldSkip": false,
      "text": "all good",
      "didStrip": true
    }
  },
  {
    "id": "suffix-meaningful",
    "raw": "All done HEARTBEAT_OK",
    "expected": {
      "shouldSkip": false,
      "text": "All done",
      "didStrip": true
    }
  },
  {
    "id": "repeated-edges",
    "raw": "HEARTBEAT_OK HEARTBEAT_OK All done HEARTBEAT_OK",
    "expected": {
      "shouldSkip": false,
      "text": "All done",
      "didStrip": true
    }
  },
  {
    "id": "markdown-wrapper",
    "raw": "**HEARTBEAT_OK**",
    "expected": {
      "shouldSkip": false,
      "text": "****",
      "didStrip": true
    }
  },
  {
    "id": "html-wrapper-meaningful",
    "raw": "<code>HEARTBEAT_OK</code> all good",
    "expected": {
      "shouldSkip": false,
      "text": "all good",
      "didStrip": true
    }
  },
  {
    "id": "html-nbsp-wrapper",
    "raw": "<b>HEARTBEAT_OK</b>&nbsp;Ready",
    "expected": {
      "shouldSkip": false,
      "text": "Ready",
      "didStrip": true
    }
  },
  {
    "id": "suffix-period",
    "raw": "I should not respond HEARTBEAT_OK.",
    "expected": {
      "shouldSkip": false,
      "text": "I should not respond.",
      "didStrip": true
    }
  },
  {
    "id": "suffix-punctuation",
    "raw": "All done HEARTBEAT_OK!!!",
    "expected": {
      "shouldSkip": false,
      "text": "All done!!!",
      "didStrip": true
    }
  },
  {
    "id": "prefix-punctuation",
    "raw": "HEARTBEAT_OK.",
    "expected": {
      "shouldSkip": false,
      "text": ".",
      "didStrip": true
    }
  },
  {
    "id": "js-trim-and-collapse",
    "raw": "﻿ HEARTBEAT_OK Ready  now ",
    "expected": {
      "shouldSkip": false,
      "text": "Ready now",
      "didStrip": true
    }
  },
  {
    "id": "unicode-prose",
    "raw": "HEARTBEAT_OK 完成 🙂",
    "expected": {
      "shouldSkip": false,
      "text": "完成 🙂",
      "didStrip": true
    }
  },
  {
    "id": "meaningful-nel",
    "raw": "HEARTBEAT_OK Ready",
    "expected": {
      "shouldSkip": false,
      "text": "Ready",
      "didStrip": true
    }
  },
  {
    "id": "ordinary-unchanged",
    "raw": "Ordinary\n\nanswer",
    "expected": {
      "shouldSkip": false,
      "text": "Ordinary\n\nanswer",
      "didStrip": false
    }
  },
  {
    "id": "interior-marker-unchanged",
    "raw": "hello HEARTBEAT_OK there",
    "expected": {
      "shouldSkip": false,
      "text": "hello HEARTBEAT_OK there",
      "didStrip": false
    }
  },
  {
    "id": "four-utf16-suffix-units",
    "raw": "Ready HEARTBEAT_OK🙂🙂",
    "expected": {
      "shouldSkip": false,
      "text": "Ready🙂🙂",
      "didStrip": true
    }
  },
  {
    "id": "six-utf16-suffix-units",
    "raw": "Ready HEARTBEAT_OK🙂🙂🙂",
    "expected": {
      "shouldSkip": false,
      "text": "Ready HEARTBEAT_OK🙂🙂🙂",
      "didStrip": false
    }
  },
  {
    "id": "ascii-word-class-unicode-suffix",
    "raw": "Ready HEARTBEAT_OKé",
    "expected": {
      "shouldSkip": false,
      "text": "Readyé",
      "didStrip": true
    }
  }
];

export async function captureEventReply(source = '/tmp/openclaw-488631c') {
  assert.equal(process.versions.node, '24.22.1', 'use the fixed capture runtime');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  const before = checkout(root);
  const context = vm.createContext({});
  const modules = new Map();
  const records = new Map();
  const load = path => {
    assert.ok(wholeSources.includes(path), `declared whole module: ${path}`);
    if (!modules.has(path)) {
      const bytes = readFileSync(join(root, path));
      assert.equal(hash(bytes), before.tracked.get(path), path);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      records.set(path, { path, sha256: hash(bytes), executableSha256: hash(executable),
        executed: true, wholeModule: true });
      modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path }));
    }
    return modules.get(path);
  };
  const module = load(entry);
  await module.link((specifier, owner) => {
    if (specifier === '@openclaw/normalization-core/string-coerce') {
      return load('packages/normalization-core/src/string-coerce.ts');
    }
    assert.ok(specifier.startsWith('.') && specifier.endsWith('.js'), `declared source import: ${specifier}`);
    return load(posix.normalize(posix.join(posix.dirname(owner.identifier), specifier)).replace(/\.js$/, '.ts'));
  });
  await module.evaluate({ timeout: 1000 });
  assert.deepEqual([...records.keys()].sort(), [...wholeSources].sort());
  context.heartbeatExports = module.namespace;
  const observations = vectors.map(vector => {
    context.raw = vector.raw;
    const actual = plain(new vm.Script('heartbeatExports.stripHeartbeatToken(raw, {mode: "message"})')
      .runInContext(context, { timeout: 1000 }));
    assert.deepEqual(actual, vector.expected, vector.id);
    return { id: vector.id, raw: vector.raw, mode: 'message', actual };
  });
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return {
    schemaVersion: 1, referencePin: EVENT_REPLY_PIN,
    exporter: { path: 'scripts/openclaw/capture-event-reply.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    sourceTree: { before: before.receipt, after: after.receipt },
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    entry: { path: entry, export: 'stripHeartbeatToken', mode: 'message', calls: observations.length },
    sourceRecords: [...records.values()],
    importBindings: [],
    scope: { pureMessageHelperExecuted: true, heartbeatModeExecuted: false,
      normalizeReplyCallsiteExecuted: false, dispatchExecuted: false,
      nativeRuntimeExecuted: false, browserExecuted: false, cliExecuted: false },
    limits: [
      'Only stripHeartbeatToken in explicit message mode executes from four complete unchanged pinned TypeScript modules; evaluating whole modules does not claim every function executes.',
      'All tracked reference blobs are verified before and after; source, transformed executable, exporter and fixed runtime hashes are recorded. No source or installed package is patched, sliced or replaced by a facade.',
      'The Markdown wrapper **HEARTBEAT_OK** preserves the observed original-candidate result ****; it is not suppressed according to an inferred cleanup intention.',
      'The non-Unicode JavaScript suffix regex counts UTF-16 units and uses ASCII word characters; two astral symbols strip while three remain, and accented non-word suffixes strip.',
      'Heartbeat quiet-history suppression, normalize-reply callsite, full dispatch, native lifecycle, browser, media and CLI delivery do not execute in this helper capture.',
    ],
    observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-event-reply.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureEventReply(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], vectors: result.observations.length,
    helperCalls: result.entry.calls, wholeModules: result.sourceRecords.length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
