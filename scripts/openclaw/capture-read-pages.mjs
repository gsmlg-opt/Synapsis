// Ordinary selected-page observations from nine complete pinned source modules.
// This does not execute read.ts, file selection/decoding, factories, or a Worker.
import assert from 'node:assert/strict';
import * as asyncHooks from 'node:async_hooks';
import * as nodeBuffer from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import vm from 'node:vm';

const PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const ENTRY = 'src/agents/sessions/tools/read-page.ts';
const HARNESS = 'scripts/openclaw/capture-read-pages.mjs';
const TRANSFORMATION = 'node:module.stripTypeScriptTypes(mode=strip,sourceMap=false)';
const SOURCE_HASHES = {
  LICENSE: '9efd316ecf1c4c60f6fd5d26433142fff2b6794d7d328e9bc6179b29bf9c82a4',
  'tsconfig.json': '7ccd7e1a86ea71116777e6fc8836b050c0b0c3307ea04a1738663a03ddb798f5',
  'src/agents/sessions/tools/read-page.ts': 'ba7fc52f5839e2af046bfc8a39c9881ca82bc944dc610100aad68ab7cf4ec6e4',
  'src/utils/utf8-truncate.ts': '73a5e81b92b3159cc076b33fdfa020d5775df80f0d2b7c6ed66b8e4da4872865',
  'src/agents/embedded-agent-runner/tool-result-text-budget.ts': '0837f0d8b2b5527de213674cb398ea2924797c125814a6169a3e2ed885444b53',
  'packages/normalization-core/src/cjk-chars.ts': '4fd72b01592ca56ac87842841ccac645d1bb4d7268ba89a154c95190d49b41d1',
  'packages/normalization-core/src/utf16-slice.ts': '12fd3212b08522a1523263c92f654151ad01605ee48a0ff58a1256889fb7cb5f',
  'src/agents/tool-result-limits.ts': 'a04aed3851e79cd087b2421569d7850a84b69a30b09f6bd0ab6b9d4d4e01aa9f',
  'src/shared/global-singleton.ts': '26f316b3de3b42f05a87cea8e862f2b1bb4eb3ed06e2d815a3865d56c47c59ab',
  'src/agents/sessions/tools/truncate.ts': '9bcbe09cd22363d3840587ccf43a50190a93c58c2c487078bbb80200897c62c5',
  'packages/agent-core/src/harness/utils/truncate.ts': 'b903db35cd4b042c802b9cb14b94bdab3029c753dd0d442ee70f8495457a0862',
};
const ALIASES = {
  '@openclaw/normalization-core/cjk-chars': 'packages/normalization-core/src/cjk-chars.ts',
  '@openclaw/normalization-core/utf16-slice': 'packages/normalization-core/src/utf16-slice.ts',
};
const NATIVES = new Map([
  ['node:async_hooks', asyncHooks],
  ['node:buffer', nodeBuffer],
]);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const byPath = (a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0;

// Git is read-only. Compare working bytes with the pinned blobs on both sides
// of execution, independently of the tracked-worktree cleanliness check.
function verifiedSnapshot(root) {
  const git = args => execFileSync('git', ['-C', root, ...args], {
    timeout: 10_000, maxBuffer: 4 * 1024 * 1024,
  });
  assert.equal(realpathSync(git(['rev-parse', '--show-toplevel']).toString().trim()), root);
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), PIN, 'reference commit');
  assert.equal(git(['status', '--porcelain', '--untracked-files=no']).toString(), '', 'clean tracked reference');
  const sources = Object.entries(SOURCE_HASHES).map(([path, sha256]) => {
    const file = resolve(root, path);
    assert.equal(realpathSync(file), file, `canonical source path: ${path}`);
    const bytes = readFileSync(file);
    assert.ok(bytes.equals(git(['show', `${PIN}:${path}`])), `pinned blob bytes: ${path}`);
    assert.equal(digest(bytes), sha256, `pinned SHA256: ${path}`);
    const content = bytes.toString('utf8');
    assert.ok(nodeBuffer.Buffer.from(content, 'utf8').equals(bytes), `retained complete bytes: ${path}`);
    return { path, content, sha256 };
  }).sort(byPath);
  return sources;
}

function aliasEvidence(sources) {
  const config = sources.find(row => row.path === 'tsconfig.json');
  // Read the exact two JSONC string-array entries without changing tsconfig.
  // No wildcard/barrel/package-export resolution participates in this graph.
  return Object.entries(ALIASES).map(([specifier, target]) => {
    const key = JSON.stringify(specifier);
    const index = config.content.indexOf(key);
    assert.ok(index >= 0, `original tsconfig alias: ${specifier}`);
    assert.equal(config.content.lastIndexOf(key), index, `unique alias: ${specifier}`);
    const match = config.content.slice(index + key.length).match(/^\s*:\s*\[\s*"([^"]+)"\s*\]/);
    assert.ok(match, `single original source mapping: ${specifier}`);
    assert.equal(match[1], './' + target);
    return {
      specifier, target, originalMapping: match[1], path: config.path,
      sourceSha256: config.sha256,
      line: config.content.slice(0, index).split('\n').length,
    };
  });
}

function recipes() {
  // These are source-owner-selected parameters, not a second selection algorithm.
  const row = (id, input) => ({ id, input: { ...input, maxBytes: 51_200 } });
  return [
    row('normalized-eof', { content: 'alpha\nbeta\ngamma\n', startLine: 1, endLine: 3, totalLines: 3 }),
    row('one-based-slice', { content: 'beta', startLine: 2, endLine: 2, totalLines: 3, limit: 1 }),
    row('continuation-eof', { content: 'gamma\n', startLine: 3, endLine: 3, totalLines: 3, limit: 1 }),
    row('plural-slice', { content: 'one\ntwo', startLine: 1, endLine: 2, totalLines: 4, limit: 2 }),
    row('utf16-selected-slice', { content: '中B', startLine: 1, endLine: 1, totalLines: 2, cursor: 3, limit: 1 }),
    row('unicode-eof', { content: '😀中B\n尾\n', startLine: 1, endLine: 2, totalLines: 2, cursor: 1 }),
    row('preserved-cr-bom', { content: 'one\rtwo\n\uFEFFthree\n', startLine: 1, endLine: 2, totalLines: 2 }),
    row('blank-raw-page', { content: '\n\n', startLine: 1, endLine: 2, totalLines: 2 }),
  ];
}

export async function captureReadPages(referenceRoot) {
  const root = realpathSync(resolve(referenceRoot));
  const sources = verifiedSnapshot(root);
  const aliases = aliasEvidence(sources);
  const context = vm.createContext({ Buffer: nodeBuffer.Buffer });
  const modules = new Map();
  const nativeModules = new Map();
  const links = new Map();
  const transforms = [];

  // One canonical module per original repository path preserves shared caches,
  // imports, and the source-owned symbol-keyed global singleton in this realm.
  for (const source of sources.filter(row => row.path.endsWith('.ts'))) {
    const executable = stripTypeScriptTypes(source.content, { mode: 'strip', sourceMap: false });
    transforms.push({
      path: source.path, sourceSha256: source.sha256, executable,
      executableSha256: digest(executable), transformation: TRANSFORMATION,
    });
    modules.set(source.path, new vm.SourceTextModule(executable, {
      context, identifier: source.path,
    }));
  }

  const nativeModule = specifier => {
    if (!nativeModules.has(specifier)) {
      const namespace = NATIVES.get(specifier);
      // Only unmodified real Node namespace values cross this bridge.
      nativeModules.set(specifier, new vm.SyntheticModule(Object.keys(namespace), function () {
        for (const [name, value] of Object.entries(namespace)) this.setExport(name, value);
      }, { context, identifier: specifier }));
    }
    return nativeModules.get(specifier);
  };
  const entry = modules.get(ENTRY);
  await entry.link((specifier, importer) => {
    let target;
    let kind;
    let module;
    if (NATIVES.has(specifier)) {
      target = specifier;
      kind = 'actual-node-native-namespace';
      module = nativeModule(specifier);
    } else {
      if (Object.hasOwn(ALIASES, specifier)) {
        target = ALIASES[specifier];
        kind = 'exact-original-tsconfig-source-alias';
      } else {
        assert.ok(specifier.startsWith('.') && specifier.endsWith('.js'), `original relative import: ${specifier}`);
        target = posix.normalize(posix.join(posix.dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts');
        kind = 'original-relative-js-to-ts';
      }
      assert.ok(modules.has(target), `complete pinned module in closure: ${target}`);
      module = modules.get(target);
    }
    links.set(`${importer.identifier}:${specifier}`, { importer: importer.identifier, specifier, target, kind });
    return module;
  });
  await entry.evaluate({ timeout: 10_000 });
  assert.equal(modules.size, 9);
  for (const module of modules.values()) assert.equal(module.status, 'evaluated', module.identifier);
  assert.deepEqual([...nativeModules.keys()].sort(), [...NATIVES.keys()].sort());
  assert.equal(context.Buffer, nodeBuffer.Buffer);
  assert.equal(nativeModules.get('node:buffer').namespace.Buffer, nodeBuffer.Buffer);
  assert.equal(nativeModules.get('node:async_hooks').namespace.AsyncLocalStorage, asyncHooks.AsyncLocalStorage);
  const singletonKey = Symbol.for('openclaw.fullToolResultDelivery');
  // Observe through the original owner inside its realm: the external context
  // object does not expose every symbol slot on the contextified globalThis.
  const { readGlobalSingleton } = modules.get('src/shared/global-singleton.ts').namespace;
  const singleton = readGlobalSingleton(singletonKey);
  assert.ok(singleton instanceof asyncHooks.AsyncLocalStorage, 'source singleton uses native AsyncLocalStorage');
  assert.equal(readGlobalSingleton(singletonKey), singleton);

  const cases = recipes().map(({ id, input }) => ({
    id, input, result: plain(entry.namespace.createBoundedReadTextPage(input)),
  }));
  assert.deepEqual(verifiedSnapshot(root), sources, 'reference source and pin unchanged after capture');
  assert.equal(readGlobalSingleton(singletonKey), singleton, 'original singleton identity retained');

  return {
    version: 1,
    reference: {
      repository: 'openclaw/openclaw', commit: PIN,
      trackedCleanBefore: true, trackedCleanAfter: true,
      originalBlobBytesVerifiedBeforeAndAfter: true,
    },
    cases,
    provenance: {
      sources, transforms: transforms.sort(byPath),
      nativeImports: [...nativeModules.keys()].sort(),
      aliases: { ...ALIASES }, aliasEvidence: aliases,
      links: [...links.values()].sort((a, b) => {
        const left = `${a.importer}:${a.specifier}`;
        const right = `${b.importer}:${b.specifier}`;
        return left < right ? -1 : left > right ? 1 : 0;
      }),
      nativeEvidence: {
        globalBufferIsNodeBuffer: true, importedBufferIsNodeBuffer: true,
        importedAsyncLocalStorageIsNodeAsyncLocalStorage: true,
        sourceSingletonIsNativeAsyncLocalStorage: true,
        sourceSingletonIdentityPreserved: true,
      },
      moduleIdentity: 'One cached SourceTextModule per canonical original path and one cached native namespace bridge per specifier in a shared VM realm',
      harness: { path: HARNESS, sha256: digest(readFileSync(new URL(import.meta.url))) },
      runtime: { node: process.version, loader: 'node:vm.SourceTextModule', transformation: TRANSFORMATION },
    },
    boundaries: {
      invocation: 'createBoundedReadTextPage(source-owner-selected parameters)',
      completeOriginalModules: 9, serviceBindings: [], sourceRewrites: [],
      ordinarySelectedPagesOnly: true,
      limits: [
        'Inputs are already normalized/selected literal text; read.ts normalization, decoding, UTF-16 selection and cursor validation are unexecuted.',
        'Blank raw page output is the page helper result, not the read.ts friendly blank-line display message.',
        'Only complete selected pages and ordinary explicit line-slice continuations are exercised; no model budget or byte/line cap branch is exercised.',
        'Real files, mutation queues, path resolution, read/ls factories, image processing, service assembly and Worker integration are unexecuted.',
        'No security, permission, auth, TLS, negative, unavailable, mixed, failure, cancellation, crash, expiry, budget, real-provider or overflow/underflow scenarios are exercised.',
      ],
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: {
    'reference-root': { type: 'string', default: '/tmp/openclaw-488631c' },
    output: { type: 'string' },
  } });
  const report = await captureReadPages(values['reference-root']);
  const json = JSON.stringify(report, null, 2) + '\n';
  if (values.output) writeFileSync(values.output, json);
  else process.stdout.write(json);
}
