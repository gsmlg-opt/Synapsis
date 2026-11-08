// Qualify authored raw-event inputs with the complete pinned memory byte-window module.
// This does not reconstruct source events from host records or execute a storage reader.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const SESSION_READER_WINDOW_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const tree = '47509a47273231ab15f57252960fe716d7379ffb';
const navigation = 'src/config/sessions/session-actor-memory-history-navigation.ts';
const sourcePages = 'src/gateway/session-transcript-source-pages.ts';
const historyTail = 'src/gateway/session-history-tail.ts';
const selector = 'resolveSessionActorMemoryHistoryStart';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const rawBytes = text => Buffer.byteLength(text, 'utf8') + 1;

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' },
  }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), SESSION_READER_WINDOW_PIN);
  assert.equal(git(root, ['rev-parse', `${SESSION_READER_WINDOW_PIN}^{tree}`]), tree);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '', 'clean tracked reference');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', SESSION_READER_WINDOW_PIN])
    .split('\0').filter(Boolean).map(item => {
      const [header, path] = item.split('\t');
      const [mode, type, gitBlob] = header.split(' ');
      assert.equal(type, 'blob');
      assert.ok(['100644', '100755', '120000'].includes(mode));
      assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
      const file = join(root, path);
      const symlink = lstatSync(file).isSymbolicLink();
      assert.equal(symlink, mode === '120000');
      assert.ok(realpathSync(file).startsWith(root + sep));
      const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
      assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
      return { path, gitBlob, bytes: bytes.length, sha256: hash(bytes) };
    });
  return {
    tracked: new Map(files.map(row => [row.path, row])),
    receipt: { verified: true, commit: SESSION_READER_WINDOW_PIN, tree,
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}

// Only these actual import edges are unused by the selected pure export.
// Every exported facade records its invocation and throws; none may supply a result.
const unusedEdges = [
  ['@openclaw/normalization-core/record-coerce', ['isRecord']],
  ['../../../packages/agent-core/src/harness/session/tool-result-pairing.js', ['selectResetKeptEntries']],
  ['./session-entry-codec.js', ['isIndexedSessionEntry']],
  ['./session-history-visibility.js', ['isVisibleHistoryNonMessageEvent']],
  ['./session-transcript-projection-append.js', ['hasTranscriptMessage', 'shouldProjectActiveEvent']],
  ['./transcript-tree.js', ['scanSessionTranscriptTree', 'selectSessionTranscriptActiveEntries']],
];

// Explicit fictional source events: retained JSON text, parents, ordering and whitespace
// are inputs to this oracle, not evidence of any native host/source producer mapping.
const ordinary = [
  '{"type":"message","id":"event-a","parentId":null,"timestamp":"2026-11-06T00:00:00.000Z","message":{"role":"user","content":"First"}}',
  '{"type":"message","id":"event-b","parentId":"event-a","timestamp":"2026-11-06T00:00:01.000Z","message":{"role":"assistant","content":"你好😀"}}',
  '{\n  "message": { "content": "Line one\\nLine two", "role": "user" },\n  "timestamp": "2026-11-06T00:00:02.000Z", "parentId": "event-b", "id": "event-c", "type": "message"\n}',
  '{"type":"message","id":"event-d","parentId":"event-c","timestamp":"2026-11-06T00:00:03.000Z","message":{"role":"assistant","content":"Done"}}',
];
const indivisible = '{"type":"message","id":"large-soft","parentId":"event-b","timestamp":"2026-11-06T00:00:02.000Z","message":{"role":"assistant","content":"' + '文😀'.repeat(350) + '"}}';
const middle = '{"type":"message","id":"middle","parentId":"event-a","timestamp":"2026-11-06T00:00:01.000Z","message":{"role":"assistant","content":"' + 'Long ordinary text. '.repeat(80) + '"}}';
const afterMiddle = '{"type":"message","id":"last","parentId":"middle","timestamp":"2026-11-06T00:00:02.000Z","message":{"role":"user","content":"Latest"}}';
const vectors = [
  {
    id: 'raw-utf8-equality-suffix', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]), maxMessages: 3, allowOversized: false },
  },
  {
    id: 'preserve-json-text-and-order', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: 4096, maxMessages: 3, allowOversized: false },
  },
  {
    id: 'contiguous-newest-suffix', eventJson: [ordinary[0], middle, afterMiddle],
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[0]) + rawBytes(afterMiddle), maxMessages: 3, allowOversized: false },
  },
  {
    id: 'max-messages-bound', eventJson: ordinary,
    options: { start: 0, end: 4, maxBytes: 4096, maxMessages: 2, allowOversized: false },
  },
  {
    id: 'initial-bytes-inclusive-boundary', eventJson: ordinary.slice(0, 3),
    options: { start: 0, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]) + 37, maxMessages: 3, allowOversized: false, initialBytes: 37 },
  },
  {
    id: 'complete-requested-subwindow', eventJson: ordinary,
    options: { start: 1, end: 3, maxBytes: rawBytes(ordinary[1]) + rawBytes(ordinary[2]), maxMessages: 2, allowOversized: false, initialBytes: 0, requireComplete: true },
  },
  {
    id: 'eligible-window-start', eventJson: ordinary,
    options: { start: 2, end: 4, maxBytes: 4096, maxMessages: 4, allowOversized: false },
  },
  {
    id: 'indivisible-newest-above-soft-request', eventJson: [...ordinary.slice(0, 2), indivisible],
    options: { start: 0, end: 3, maxBytes: 1024, maxMessages: 3, allowOversized: true },
  },
];

export async function captureSessionReaderWindow(referenceRoot = '/tmp/openclaw-488631c') {
  assert.equal(process.versions.node, '24.21.0', 'use the fixed capture runtime');
  const executable = realpathSync(process.execPath);
  const runtimeHash = hash(readFileSync(executable));
  const root = realpathSync(referenceRoot);
  const before = checkout(root);
  const sources = new Map();
  function source(path) {
    if (sources.has(path)) return sources.get(path).content;
    const record = before.tracked.get(path);
    assert.ok(record, 'tracked pinned source: ' + path);
    const bytes = readFileSync(join(root, path));
    assert.equal(hash(bytes), record.sha256, 'unchanged exact blob: ' + path);
    const content = bytes.toString('utf8');
    assert.ok(Buffer.from(content, 'utf8').equals(bytes), 'complete UTF-8 source: ' + path);
    sources.set(path, { ...record, content });
    return content;
  }

  const context = vm.createContext({ __facadeCalls: [] });
  const modules = new Map();
  const transforms = [];
  const imports = [];
  const facadeEdges = [];
  function module(path) {
    if (modules.has(path)) return modules.get(path);
    assert.ok([navigation, sourcePages].includes(path), 'declared whole module: ' + path);
    const generatedSource = stripTypeScriptTypes(source(path), { mode: 'strip', sourceMap: false });
    transforms.push({ path, mode: 'whole-module', sourceSha256: sources.get(path).sha256,
      generatedSource, generatedSha256: hash(generatedSource),
      transformation: 'node:module.stripTypeScriptTypes(mode=strip,sourceMap=false)' });
    const result = new vm.SourceTextModule(generatedSource, { context, identifier: path });
    modules.set(path, result);
    return result;
  }
  const entry = module(navigation);
  await entry.link((specifier, importer) => {
    assert.equal(importer.identifier, navigation, 'only navigation has runtime imports');
    if (specifier === '../../gateway/session-transcript-source-pages.js') {
      imports.push({ importer: navigation, specifier, target: sourcePages, rewritten: false });
      return module(sourcePages);
    }
    const edge = unusedEdges.find(([name]) => name === specifier);
    assert.ok(edge, 'declared unused source edge: ' + specifier);
    assert.ok(source(navigation).includes(specifier), 'original source edge');
    const identifier = 'unused:' + navigation + ':' + specifier;
    if (!modules.has(identifier)) {
      const generatedSource = edge[1].map(name => {
        const call = JSON.stringify({ importer: navigation, specifier, export: name });
        return `export function ${name}(){__facadeCalls.push(${call});throw Error("Unused reference facade invoked");}`;
      }).join('\n');
      facadeEdges.push({ importer: navigation, specifier, exports: [...edge[1]],
        kind: 'throwing-uncalled-import-edge', generatedSource, generatedSha256: hash(generatedSource) });
      modules.set(identifier, new vm.SourceTextModule(generatedSource, { context, identifier }));
    }
    return modules.get(identifier);
  });
  await entry.evaluate({ timeout: 1000 });
  for (const path of [navigation, sourcePages]) assert.equal(modules.get(path).status, 'evaluated');
  const sourcePageMaxBytes = modules.get(sourcePages).namespace.SOURCE_PAGE_MAX_BYTES;

  // Evaluate the exact caller constant declaration, keeping its complete source proof.
  // The tail caller and its imports are not executed by this pure-helper capture.
  const tail = source(historyTail);
  const matches = [...tail.matchAll(/^const HISTORY_PAGE_MAX_BYTES = [^\r\n]+;$/gm)];
  assert.equal(matches.length, 1, 'single original caller byte-limit declaration');
  const declaration = matches[0];
  const historyPageMaxBytes = new vm.Script(declaration[0] + '\nHISTORY_PAGE_MAX_BYTES')
    .runInContext(vm.createContext({}), { timeout: 1000 });
  const constantProofs = [{ path: historyTail, name: 'HISTORY_PAGE_MAX_BYTES',
    sourceSha256: sources.get(historyTail).sha256, declaration: declaration[0],
    startByte: Buffer.byteLength(tail.slice(0, declaration.index)),
    endByte: Buffer.byteLength(tail.slice(0, declaration.index + declaration[0].length)),
    sha256: hash(declaration[0]), value: historyPageMaxBytes,
    execution: 'exact constant declaration only; caller not executed' }];

  context.__selector = entry.namespace[selector];
  assert.equal(typeof context.__selector, 'function');
  const calls = [];
  const observations = vectors.map(vector => {
    const eventJson = [...vector.eventJson];
    const serializedBytes = eventJson.map(rawBytes);
    const rows = eventJson.map((text, index) => ({ eventJson: text, serializedBytes: serializedBytes[index] }));
    const options = { ...vector.options };
    context.__args = [rows, options.start, options.end, options.maxBytes, options.maxMessages,
      options.allowOversized, options.initialBytes, options.requireComplete];
    const start = new vm.Script('__selector(...__args)').runInContext(context, { timeout: 1000 });
    calls.push({ path: navigation, export: selector, result: start });
    const selectedEventJson = eventJson.slice(start, options.end);
    return { id: vector.id, eventJson, serializedBytes, options,
      result: { start, selectedIds: selectedEventJson.map(text => JSON.parse(text).id), selectedEventJson } };
  });
  assert.equal(context.__facadeCalls.length, 0, 'no unused facade invoked');

  const licenseText = source('LICENSE');
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt, 'reference unchanged after execution');
  assert.equal(hash(readFileSync(executable)), runtimeHash, 'runtime unchanged');
  return {
    version: 1,
    reference: { commit: SESSION_READER_WINDOW_PIN, tree, trackedClean: true },
    scope: 'ordinary-raw-event-window-helper',
    limits: { sourcePageMaxBytes, historyPageMaxBytes },
    runtime: { executable, version: process.versions.node, sha256: runtimeHash, platform: process.platform },
    exporter: { path: 'scripts/openclaw/capture-session-reader-window.mjs',
      sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    license: { path: 'LICENSE', sha256: sources.get('LICENSE').sha256, text: licenseText },
    evidence: {
      sourceTree: { before: before.receipt, after: after.receipt },
      sources: [...sources.values()].map(({ content: _, ...record }) => record)
        .sort((a, b) => a.path.localeCompare(b.path)),
      transforms, imports, constantProofs, facadeEdges,
      facadeCalls: Array.from(context.__facadeCalls), calls,
      byteAccounting: { path: navigation, expression: 'Buffer.byteLength(row.eventJson) + 1',
        input: 'authored original event JSON text encoded as UTF-8 plus one LF byte',
        sourceSha256: sources.get(navigation).sha256 },
    },
    exclusions: [
      'Inputs are authored source events with explicit fictional identities, parents and timestamps; no native host producer or stored-event parity is asserted.',
      'Only the pure byte-window export executes; complete module evaluation does not execute actor navigation, source-page iteration or the history-tail caller.',
      'No active/archive storage reader, recent/page normalization, maxLines, source tree/reset projection, factory, gateway, provider, browser or native runtime executes.',
      'No security, permission, error, cancellation, crash, hard-limit exhaustion or extended-budget qualification is included.',
    ],
    vectors: observations,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const usage = 'usage: node --experimental-vm-modules scripts/openclaw/capture-session-reader-window.mjs [--source PINNED_SOURCE] [--output OUTPUT_JSON]';
  const args = process.argv.slice(2);
  const options = new Map();
  for (let index = 0; index < args.length; index += 2) {
    assert.ok(['--source', '--output'].includes(args[index]), usage);
    assert.ok(args[index + 1] && !args[index + 1].startsWith('--'), usage);
    assert.ok(!options.has(args[index]), usage);
    options.set(args[index], args[index + 1]);
  }
  const receipt = await captureSessionReaderWindow(options.get('--source'));
  const json = JSON.stringify(receipt, null, 2) + '\n';
  if (options.has('--output')) writeFileSync(options.get('--output'), json);
  else process.stdout.write(json);
}
