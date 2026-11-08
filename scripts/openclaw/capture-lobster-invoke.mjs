// Complete pinned source modules with an explicit synthetic success transport.
// No package entrypoint, real HTTP, or native tool runtime is executed.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const integrity = 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==';
const sourcePaths = [
  'package/dist/src/commands/stdlib/openclaw_invoke.js',
  'package/dist/src/read_response_text.js',
];
const sourcePins = [
  { bytes: 8052, sha256: '8f30e8f834446dbdb527f96dcf9b86caf8392139c0f96f3d9aac864d1705dd71' },
  { bytes: 2531, sha256: '7afd34f45b0b0f6c94fb291b7d6a7a3a006e420e2771f8c526d9323d0f529c9a' },
];
const digest = (bytes, algorithm = 'sha256', encoding = 'hex') =>
  createHash(algorithm).update(bytes).digest(encoding);
const plain = value => JSON.parse(JSON.stringify(value));

// Inputs only: observations are obtained from command.run, never fixture literals.
const recipes = [
  {
    id: 'single-drains-input-false',
    command: 'openclaw.invoke',
    args: { tool: 'fixture.read', action: 'read', 'args-json': '{"path":"雪.txt"}' },
    input: ['ignored', { old: 1 }],
    env: { OPENCLAW_URL: 'http://127.0.0.1:4242/base?ignored=1' },
    replies: [{ ok: true, result: false }],
  },
  {
    id: 'each-merges-before-publishing',
    command: 'openclaw.invoke',
    args: {
      tool: 'fixture.write', action: 'write', each: true, 'item-key': 'value',
      'args-json': '{"keep":0,"value":"old"}',
    },
    input: [{ tag: '一' }, false],
    env: { OPENCLAW_URL: 'http://127.0.0.1:4242/base?ignored=1' },
    replies: [{ ok: true, result: [{ n: 1 }, { n: 2 }] }, { ok: true, result: null }],
  },
  {
    id: 'legacy-command-environment-raw-array',
    command: 'clawd.invoke',
    args: { tool: 'fixture.list', action: 'list' },
    input: [],
    env: { CLAWD_URL: 'http://localhost:4242/old' },
    replies: [[{ label: 'raw' }, 0]],
  },
  {
    id: 'explicit-url-own-item-key-object',
    command: 'openclaw.invoke',
    args: {
      url: 'http://127.0.0.1:4243/explicit', tool: 'fixture.write', action: 'write',
      each: true, itemKey: 'payload', 'args-json': '{"item":"unchanged","payload":"old"}',
      sessionKey: 'fixture-session',
    },
    input: ['雪😀'],
    env: {},
    replies: [{ ok: true, result: { z: 1, a: 2 } }],
  },
];

function referenceSnapshot(referenceRoot) {
  const git = args => execFileSync('git', ['-C', referenceRoot, ...args], {
    timeout: 5000, maxBuffer: 8 * 1024 * 1024,
  });
  assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), pin);
  return ['extensions/lobster/package.json', 'pnpm-lock.yaml'].map(path => {
    const bytes = readFileSync(resolve(referenceRoot, path));
    assert.deepEqual(bytes, git(['show', `${pin}:${path}`]), path);
    return { path, sha256: digest(bytes), bytes: bytes.length };
  });
}

function archiveFiles(archive) {
  // Read only the three required regular-file members; do not extract to disk.
  const script = [
    'import base64,json,sys,tarfile',
    'wanted=json.loads(sys.argv[2])',
    'out={}',
    'with tarfile.open(sys.argv[1],"r:gz") as archive:',
    ' for name in wanted:',
    '  member=archive.getmember(name)',
    '  assert member.isfile() and 0 <= member.size <= 1048576, name',
    '  with archive.extractfile(member) as stream:',
    '   data=stream.read(member.size+1)',
    '  assert len(data)==member.size, name',
    '  out[name]=base64.b64encode(data).decode("ascii")',
    'print(json.dumps(out))',
  ].join('\n');
  const encoded = JSON.parse(execFileSync('python3', [
    '-c', script, archive, JSON.stringify(['package/package.json', ...sourcePaths]),
  ], { timeout: 5000, maxBuffer: 4 * 1024 * 1024 }).toString('utf8'));
  return new Map(Object.entries(encoded).map(([path, data]) => [path, Buffer.from(data, 'base64')]));
}

async function finite(operation) {
  let timer;
  try {
    return await Promise.race([
      operation,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('ordinary invoke capture deadline exceeded')), 5000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function captureRecipe(files, recipe) {
  const trace = [], calls = [], output = [];
  const context = vm.createContext({
    URL, Response, TextDecoder, Uint8Array,
    fetch: async (url, options) => {
      const index = calls.length;
      assert.ok(index < recipe.replies.length, 'unrecorded synthetic request');
      trace.push(`fetch:${index}`);
      calls.push({
        url: String(url), method: options.method,
        headers: plain(options.headers), body: options.body,
      });
      return new Response(JSON.stringify(recipe.replies[index]), {
        status: 200, headers: { 'content-type': 'application/json' },
      });
    },
  }, { codeGeneration: { strings: false, wasm: false } });
  const modules = new Map(sourcePaths.map(path => [path,
    new vm.SourceTextModule(files.get(path).toString('utf8'), { context, identifier: path }),
  ]));
  const commandModule = modules.get(sourcePaths[0]);
  await commandModule.link((specifier, importer) => {
    assert.equal(importer.identifier, sourcePaths[0]);
    assert.equal(specifier, '../../read_response_text.js');
    return modules.get(sourcePaths[1]);
  });
  await commandModule.evaluate({ timeout: 5000 });
  for (const [path, module] of modules) assert.equal(module.status, 'evaluated', path);
  const commands = [
    commandModule.namespace.openclawInvokeCommand,
    commandModule.namespace.clawdInvokeCommand,
  ];
  const command = commands.find(command => command.name === recipe.command);
  assert.ok(command, recipe.command);
  const input = (async function* () {
    trace.push('input:open');
    try {
      for (let index = 0; index < recipe.input.length; index++) {
        trace.push(`input:yield:${index}`);
        yield recipe.input[index];
      }
    } finally {
      trace.push('input:finally');
    }
  })();
  trace.push('run:start');
  const result = await finite(command.run({
    input, args: plain(recipe.args),
    ctx: { env: plain(recipe.env), onNonRetryableSideEffect() { trace.push('effect'); } },
  }));
  trace.push('run:return');
  await finite((async () => {
    for await (const item of result.output) {
      trace.push(`output:${output.length}`);
      output.push(item);
    }
    trace.push('output:done');
  })());
  assert.equal(calls.length, recipe.replies.length, 'unused synthetic reply');
  return {
    case: plain({ ...recipe, observed: { trace, calls, output } }),
    commands: commands.map(command => plain({
      name: command.name, meta: command.meta, help: command.help(),
    })),
    evaluatedModules: [...modules.keys()],
  };
}

export async function captureLobsterInvoke({ referenceRoot, archive }) {
  assert.equal(typeof vm.SourceTextModule, 'function', 'run Node with --experimental-vm-modules');
  const referenceRecords = referenceSnapshot(referenceRoot);
  const manifest = JSON.parse(readFileSync(resolve(referenceRoot, 'extensions/lobster/package.json')));
  assert.equal(manifest.dependencies['@clawdbot/lobster'], '2026.9.16');
  const lock = readFileSync(resolve(referenceRoot, 'pnpm-lock.yaml'), 'utf8');
  assert.ok(lock.includes(`'@clawdbot/lobster@2026.9.16':\n    resolution: {integrity: ${integrity}}`));
  const archiveBytes = readFileSync(archive);
  assert.equal(archiveBytes.length, 195429);
  assert.equal(digest(archiveBytes), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
  assert.equal('sha512-' + digest(archiveBytes, 'sha512', 'base64'), integrity);
  const files = archiveFiles(archive);
  const metadata = JSON.parse(files.get('package/package.json').toString('utf8'));
  assert.equal(metadata.name, '@clawdbot/lobster');
  assert.equal(metadata.version, '2026.9.16');
  const sources = sourcePaths.map((path, index) => {
    const bytes = files.get(path);
    assert.equal(bytes.length, sourcePins[index].bytes, path);
    assert.equal(digest(bytes), sourcePins[index].sha256, path);
    return { path, sha256: digest(bytes), bytes: bytes.length, wholeModule: true, executed: true };
  });
  const runs = [];
  for (const recipe of recipes) runs.push(await captureRecipe(files, plain(recipe)));
  for (const run of runs) {
    assert.deepEqual(run.commands, runs[0].commands);
    assert.deepEqual(run.evaluatedModules, sourcePaths);
  }
  assert.deepEqual(referenceSnapshot(referenceRoot), referenceRecords);
  return {
    referencePin: pin, referenceRecords,
    package: {
      name: metadata.name, version: metadata.version, integrity,
      archiveBytes: archiveBytes.length, archiveSha256: digest(archiveBytes),
    },
    sources, evaluatedModules: runs[0].evaluatedModules,
    platformBoundary: {
      fetch: 'synthetic ordinary-success response transport',
      response: 'native Response and actual source reader',
      nativeExecution: false,
    },
    harness: {
      path: 'scripts/openclaw/capture-lobster-invoke.mjs',
      sha256: digest(readFileSync(fileURLToPath(import.meta.url))),
    },
    commands: runs[0].commands,
    cases: runs.map(run => run.case),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [referenceRoot, archive, output] = process.argv.slice(2);
  assert.ok(referenceRoot && archive && output, 'provide referenceRoot archive output');
  writeFileSync(output, JSON.stringify(await captureLobsterInvoke({ referenceRoot, archive }), null, 2) + '\n');
}
