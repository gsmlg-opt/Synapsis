// Independent ordinary-success literals frozen before invoke capture implementation.
// Source command semantics with synthetic fetch; no real HTTP or native lifecycle claim.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';
import { captureLobsterInvoke } from './capture-lobster-invoke.mjs';

const referenceRoot = '/tmp/openclaw-488631c';
const archive = '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
const sourcePaths = [
  'package/dist/src/commands/stdlib/openclaw_invoke.js',
  'package/dist/src/read_response_text.js',
];

const EXPECTED_CASES = [
  {
    id: 'single-drains-input-false',
    command: 'openclaw.invoke',
    args: { tool: 'fixture.read', action: 'read', 'args-json': '{"path":"雪.txt"}' },
    input: ['ignored', { old: 1 }],
    env: { OPENCLAW_URL: 'http://127.0.0.1:4242/base?ignored=1' },
    replies: [{ ok: true, result: false }],
    observed: {
      trace: [
        'run:start', 'input:open', 'input:yield:0', 'input:yield:1',
        'input:finally', 'effect', 'fetch:0', 'run:return', 'output:0', 'output:done',
      ],
      calls: [{
        url: 'http://127.0.0.1:4242/tools/invoke',
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{"tool":"fixture.read","action":"read","args":{"path":"雪.txt"}}',
      }],
      output: [false],
    },
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
    observed: {
      trace: [
        'run:start', 'input:open', 'input:yield:0', 'effect', 'fetch:0',
        'input:yield:1', 'effect', 'fetch:1', 'input:finally', 'run:return',
        'output:0', 'output:1', 'output:2', 'output:done',
      ],
      calls: [
        {
          url: 'http://127.0.0.1:4242/tools/invoke',
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: '{"tool":"fixture.write","action":"write","args":{"keep":0,"value":{"tag":"一"}}}',
        },
        {
          url: 'http://127.0.0.1:4242/tools/invoke',
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: '{"tool":"fixture.write","action":"write","args":{"keep":0,"value":false}}',
        },
      ],
      output: [{ n: 1 }, { n: 2 }, null],
    },
  },
  {
    id: 'legacy-command-environment-raw-array',
    command: 'clawd.invoke',
    args: { tool: 'fixture.list', action: 'list' },
    input: [],
    env: { CLAWD_URL: 'http://localhost:4242/old' },
    replies: [[{ label: 'raw' }, 0]],
    observed: {
      trace: [
        'run:start', 'input:open', 'input:finally', 'effect', 'fetch:0',
        'run:return', 'output:0', 'output:1', 'output:done',
      ],
      calls: [{
        url: 'http://localhost:4242/tools/invoke',
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{"tool":"fixture.list","action":"list","args":{}}',
      }],
      output: [{ label: 'raw' }, 0],
    },
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
    observed: {
      trace: [
        'run:start', 'input:open', 'input:yield:0', 'effect', 'fetch:0',
        'input:finally', 'run:return', 'output:0', 'output:done',
      ],
      calls: [{
        url: 'http://127.0.0.1:4243/tools/invoke',
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{"tool":"fixture.write","action":"write","args":{"item":"unchanged","payload":"雪😀"},"sessionKey":"fixture-session"}',
      }],
      output: [{ z: 1, a: 2 }],
    },
  },
];

const EXPECTED_META = {
  description: 'Call a local OpenClaw tool endpoint',
  argsSchema: {
    type: 'object',
    properties: {
      url: { type: 'string', description: 'OpenClaw control URL (or OPENCLAW_URL / CLAWD_URL)' },
      token: { type: 'string', description: 'Bearer token (or OPENCLAW_TOKEN / CLAWD_TOKEN)' },
      tool: { type: 'string', description: 'Tool name (e.g. message, cron, github, etc.)' },
      action: { type: 'string', description: 'Tool action' },
      'args-json': { type: 'string', description: 'JSON string of tool args' },
      sessionKey: { type: 'string', description: 'Optional session key attribution' },
      'session-key': { type: 'string', description: 'Alias for sessionKey' },
      dryRun: { type: 'boolean', description: 'Dry run' },
      'dry-run': { type: 'boolean', description: 'Alias for dryRun' },
      each: { type: 'boolean', description: 'Map each pipeline item into tool args' },
      itemKey: { type: 'string', description: 'Key to set from the pipeline item (default: item)' },
      'item-key': { type: 'string', description: 'Alias for itemKey' },
      _: { type: 'array', items: { type: 'string' } },
    },
    required: ['tool', 'action'],
  },
  sideEffects: ['calls_clawd_tool'],
};

const expectedHelp = name => `${name} — call a local OpenClaw tool endpoint\n\n`
  + 'Usage:\n'
  + `  ${name} --tool message --action send --args-json '{"provider":"telegram","to":"...","message":"..."}'\n`
  + `  ${name} --tool message --action send --args-json '{...}' --dry-run\n`
  + `  ... | ${name} --tool message --action send --each --item-key message --args-json '{"provider":"telegram","to":"..."}'\n\n`
  + 'Config:\n'
  + '  - Uses OPENCLAW_URL env var by default (or pass --url).\n'
  + '  - Backward compatible: CLAWD_URL is also supported.\n'
  + '  - Optional Bearer token via OPENCLAW_TOKEN env var (or pass --token).\n'
  + '  - Backward compatible: CLAWD_TOKEN is also supported.\n'
  + '  - Optional attribution via --session-key <sessionKey>.\n\n'
  + 'Notes:\n'
  + '  - This is a thin transport bridge. Lobster should not own OAuth/secrets.\n';

const digest = (bytes, algorithm = 'sha256', encoding = 'hex') =>
  createHash(algorithm).update(bytes).digest(encoding);

// Read the tar members independently of the capture implementation, without imports
// from its extraction helpers and without installing or executing package entrypoints.
function tarMember(archiveBytes, memberPath) {
  const tar = gunzipSync(archiveBytes);
  const field = (header, start, end) =>
    header.subarray(start, end).toString('utf8').replace(/\0.*$/s, '');
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    const name = field(header, 0, 100);
    if (!name) break;
    const prefix = field(header, 345, 500);
    const path = prefix ? `${prefix}/${name}` : name;
    const size = Number.parseInt(field(header, 124, 136).trim(), 8);
    assert.ok(Number.isSafeInteger(size) && size >= 0, `tar size: ${path}`);
    const start = offset + 512;
    if (path === memberPath) return tar.subarray(start, start + size);
    offset = start + Math.ceil(size / 512) * 512;
  }
  assert.fail(`missing archive member: ${memberPath}`);
}

const captured = await captureLobsterInvoke({ referenceRoot, archive });

test('whole invoke source matches independent ordinary-success calls, outputs and ordering', () => {
  assert.deepEqual(captured.cases, EXPECTED_CASES);
});

test('both source commands retain the complete metadata schema and help', () => {
  assert.deepEqual(captured.commands, ['openclaw.invoke', 'clawd.invoke'].map(name => ({
    name, meta: EXPECTED_META, help: expectedHelp(name),
  })));
});

test('invoke provenance binds the pinned package, both complete source modules and harness', () => {
  const archiveBytes = readFileSync(archive);
  const integrity = 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==';
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.deepEqual(captured.referenceRecords, ['extensions/lobster/package.json', 'pnpm-lock.yaml'].map(path => {
    const bytes = readFileSync(`${referenceRoot}/${path}`);
    return { path, sha256: digest(bytes), bytes: bytes.length };
  }));
  assert.equal(`sha512-${digest(archiveBytes, 'sha512', 'base64')}`, integrity);
  const packageJson = JSON.parse(tarMember(archiveBytes, 'package/package.json'));
  assert.equal(packageJson.name, '@clawdbot/lobster');
  assert.equal(packageJson.version, '2026.9.16');
  assert.deepEqual(captured.package, {
    name: '@clawdbot/lobster', version: '2026.9.16', integrity,
    archiveBytes: archiveBytes.length, archiveSha256: digest(archiveBytes),
  });
  assert.deepEqual(captured.sources, sourcePaths.map(path => {
    const bytes = tarMember(archiveBytes, path);
    return { path, sha256: digest(bytes), bytes: bytes.length, wholeModule: true, executed: true };
  }));
  assert.deepEqual([...captured.evaluatedModules].sort(), [...sourcePaths].sort());
  assert.deepEqual(captured.platformBoundary, {
    fetch: 'synthetic ordinary-success response transport',
    response: 'native Response and actual source reader',
    nativeExecution: false,
  });
  assert.deepEqual(captured.harness, {
    path: 'scripts/openclaw/capture-lobster-invoke.mjs',
    sha256: digest(readFileSync(new URL('./capture-lobster-invoke.mjs', import.meta.url))),
  });
});

test('fresh invoke capture equals every field of the frozen fixture', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-invoke.json', import.meta.url)));
  assert.deepEqual(frozen.cases, EXPECTED_CASES);
  assert.deepEqual(captured, frozen);
});
