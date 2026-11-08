// Independent ordinary source oracle, authored before capture-personal-instructions.mjs.
// Parent runs/finalizes this at scripts/openclaw/personal-instructions-functional.test.mjs.
// No production host activation or authentication qualification follows from these fixtures.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { capturePersonalInstructions } from './capture-personal-instructions.mjs';

const sourceRoot = '/tmp/openclaw-488631c';
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const captured = await capturePersonalInstructions(sourceRoot);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const requiredWholeModuleHashes = {
  "src/agents/tools/personal-instructions-tool.ts": "a0461e67cd2ba3a71a39150b5c5350092192f5e3b05dff8778f44e0dab27ae03",
  "src/gateway/server-methods/users-personal-file.ts": "643800b2c46e58601fae64b012f557d7e18abec56647271a0041cec84053c961",
  "src/agents/workspace-personal-bootstrap.ts": "df3aee990d66096e81c8680038a889871fd5b0305669d3ae2322bcf17a442e62",
  "src/agents/system-prompt-context-files.ts": "eae20691556c8c852edb0791b595eab9dcd530073fd028be445cae32ff49bf08",
  "src/agents/tools/tool-results.ts": "13d2e22b750609d8cc848a548a17324e99000f004e89730bf305b3960da2ce3b",
  "src/agents/workspace-file-read.ts": "edb6001141c818feb61e734cd307d801e52705105346c01f3c9eef0b15fe4208",
  "src/agents/workspace-bootstrap-read.ts": "6e78be181407908735fb2a188d9d0da3bd81f97089beadfd3d34c8c9fe6c09c3",
  "src/gateway/server-methods/workspace-fs.ts": "27f1e741443c07cbe80ad409c582c0b36cfb2ab071fdb54f13aa5e182f39a538",
  "src/infra/fs-safe.ts": "acab39ab706c0807be4c20231a4999aef99f0d7efc269246c49f5c097a162789"
};
const expectedFactory = {
  "name": "personal_instructions",
  "label": "Personal Instructions",
  "description": "On a multi-user Gateway, read or update the authenticated requesting user’s personal USER.md from any Gateway chat session, including project worktrees. Defaults to this agent’s configured workspace; agentId selects another permitted agent. Use get first, preserve unrelated preferences, then set the complete content with expectedHash set to the returned hash (null only when missing). Limit 4,000 characters. Only update when the user asks. Never use the session owner’s identity or shared USER.md. Requires a live authenticated user turn; does not grant general filesystem access.",
  "parameters": {
    "additionalProperties": false,
    "type": "object",
    "required": [
      "action"
    ],
    "properties": {
      "action": {
        "anyOf": [
          {
            "const": "get",
            "type": "string"
          },
          {
            "const": "set",
            "type": "string"
          }
        ]
      },
      "agentId": {
        "minLength": 1,
        "type": "string"
      },
      "content": {
        "maxLength": 4000,
        "type": "string"
      },
      "expectedHash": {
        "anyOf": [
          {
            "pattern": "^[a-f0-9]{64}$",
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      }
    }
  }
};
const expectedBoundaries = {
  "executed": [
    "original personal_instructions factory",
    "original usersPersonalFileHandlers get/set owner",
    "real fixture filesystem read/write and SHA256",
    "original workspace update queue",
    "original loadPersonalUserBootstrapFile",
    "original prepareContextFilesForPrompt and buildProjectContextSection"
  ],
  "supplied": [
    "successful requester and admitted-run identity facade for Profile_356",
    "successful resident catalog and multiuser-enabled facade",
    "successful configured Agent and workspace facade for fixture-main",
    "successful gateway dispatch facade into original owner",
    "successful selected bootstrap subject facade for Profile_356"
  ]
};
const expectedLimitations = [
  "Source-only oracle; no native Synapsis production implementation or activation is qualified.",
  "Identity, catalog, multiuser and admission facades supply successful host inputs; this is not authentication qualification.",
  "The original multiuser-only eligibility remains unchanged; the actual user answer about a single-operator Synapsis adaptation is pending.",
  "Requester and session-selected bootstrap person follow distinct source policies; this ordinary fixture supplies Profile_356 for both and does not qualify cross-user or cross-Agent isolation.",
  "No security, permission, authentication, negative, error, conflict, retry, cancellation, crash, budget, threshold, truncation, eviction, race, mixed, directory or real-provider tests are executed.",
  "No 4000-limit boundary or large-existing-file parity is qualified."
];
const workspace = '<fixture-root>/configured-main';
const relativePath = 'users/Profile_356/USER.md';
const created = '\uFEFF# Personal preferences\r\n- Reply in 中文 😀.\r\n- Keep the original spelling: e\u0301.\r\n';
const replaced = created + '- Prefer concise answers.\r\n';
const createdHash = 'd6886c22884e451a1aea95b0b95ac6d2a93a5d9dbd88c8d8e6477e464e0af3bb';
const replacedHash = '92b66df404f5b24a2f06ba89c5f97261bdb19fe88c356fd95404ddb770050d8b';
const emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
// Each literal row is [id, original input, expected complete saved text, hash, missing].
const lifecycle = [
  ['get-missing', { action: 'get' }, '', null, true],
  ['create', { action: 'set', content: created, expectedHash: null }, created, createdHash, false],
  ['get-created', { action: 'get' }, created, createdHash, false],
  ['replace', { action: 'set', content: replaced, expectedHash: createdHash }, replaced, replacedHash, false],
  ['get-replaced', { action: 'get' }, replaced, replacedHash, false],
  ['empty', { action: 'set', content: '', expectedHash: replacedHash }, '', emptyHash, false],
  ['get-empty', { action: 'get' }, '', emptyHash, false],
  ['restore', { action: 'set', content: replaced, expectedHash: emptyHash }, replaced, replacedHash, false],
  ['explicit-get', { action: 'get', agentId: 'fixture-main',
    content: 'Read does not replace saved preferences.', expectedHash: null }, replaced, replacedHash, false],
];

// Actual public owner field insertion order is part of jsonResult's text representation.
function publicResult(content, hash, missing) {
  return { agentId: 'fixture-main', profileId: 'Profile_356', missing, content, hash };
}

const expectedBootstrap = {
  "subjectProfileId": "Profile_356",
  "workspace": "<fixture-root>/configured-main",
  "shared": {
    "name": "USER.md",
    "path": "<fixture-root>/configured-main/USER.md",
    "content": "# Shared preferences\n- Use clear language.\n- Prefer detailed answers.\n",
    "missing": false,
    "origin": {
      "kind": "agent-workspace",
      "rootPath": "<fixture-root>/configured-main"
    }
  },
  "personal": {
    "name": "USER.md",
    "path": "<fixture-root>/configured-main/users/Profile_356/USER.md",
    "content": "﻿# Personal preferences\r\n- Reply in 中文 😀.\r\n- Keep the original spelling: é.\r\n- Prefer concise answers.\r\n",
    "missing": false,
    "personalUser": true,
    "origin": {
      "kind": "personal",
      "rootPath": "<fixture-root>/configured-main/users/Profile_356"
    }
  },
  "prepared": [
    {
      "file": {
        "name": "USER.md",
        "path": "<fixture-root>/configured-main/USER.md",
        "content": "# Shared preferences\n- Use clear language.\n- Prefer detailed answers.\n",
        "missing": false,
        "origin": {
          "kind": "agent-workspace",
          "rootPath": "<fixture-root>/configured-main"
        }
      },
      "path": "<fixture-root>/configured-main/USER.md",
      "basename": "user.md",
      "order": 40
    },
    {
      "file": {
        "name": "USER.md",
        "path": "<fixture-root>/configured-main/users/Profile_356/USER.md",
        "content": "﻿# Personal preferences\r\n- Reply in 中文 😀.\r\n- Keep the original spelling: é.\r\n- Prefer concise answers.\r\n",
        "missing": false,
        "personalUser": true,
        "origin": {
          "kind": "personal",
          "rootPath": "<fixture-root>/configured-main/users/Profile_356"
        }
      },
      "path": "<fixture-root>/configured-main/users/Profile_356/USER.md",
      "basename": "user.md",
      "order": 40
    }
  ],
  "section": [
    "# Project Context",
    "",
    "Loaded project context:",
    "USER.md: durable user preferences and profile directives; follow unless higher-priority instructions override.",
    "The personal users/<profile-id>/USER.md belongs to this session's selected person (assigned human owner, otherwise human creator). It supplements shared USER.md and overrides conflicting shared preferences, not higher-priority rules. Other participants do not change this personal context.",
    "",
    "## <fixture-root>/configured-main/USER.md",
    "",
    "# Shared preferences\n- Use clear language.\n- Prefer detailed answers.\n",
    "",
    "## <fixture-root>/configured-main/users/Profile_356/USER.md",
    "",
    "﻿# Personal preferences\r\n- Reply in 中文 😀.\r\n- Keep the original spelling: é.\r\n- Prefer concise answers.\r\n",
    ""
  ]
};

test('pinned unchanged original modules, supplied boundaries and exact factory match the frozen oracle', () => {
  assert.deepEqual(Object.keys(captured).sort(), [
    'schemaVersion', 'referenceCommit', 'sourceTree', 'sourceRecords', 'importBindings',
    'factory', 'cases', 'bootstrap', 'boundaries', 'limitations',
  ].sort());
  assert.equal(captured.schemaVersion, 1);
  assert.equal(captured.referenceCommit, pin);
  assert.equal(captured.sourceTree.before.commit, pin);
  assert.equal(captured.sourceTree.before.verified, true);
  assert.deepEqual(captured.sourceTree.after, captured.sourceTree.before);
  assert.deepEqual(captured.factory, expectedFactory);
  const sources = new Map(captured.sourceRecords.map(row => [row.path, row]));
  assert.equal(sources.size, captured.sourceRecords.length, 'unique source provenance paths');
  for (const [path, expectedHash] of Object.entries(requiredWholeModuleHashes)) {
    const row = sources.get(path);
    assert.ok(row, path);
    assert.equal(row.wholeModule, true, path);
    assert.equal(row.executed, true, path);
    assert.equal(row.sha256, expectedHash, path);
    const bytes = readFileSync(join(sourceRoot, path));
    assert.equal(sha256(bytes), expectedHash, path);
    assert.equal(row.executableSha256, sha256(stripTypeScriptTypes(bytes.toString('utf8'),
      { mode: 'transform', sourceMap: false })), path);
  }
  // Additional tracked files may be provenance-only or transparent original declaration
  // projections. No arbitrary module count or whole-barrel assumption is imposed.
  for (const row of captured.sourceRecords) {
    assert.equal(row.sha256, sha256(readFileSync(join(sourceRoot, row.path))), row.path);
  }
  assert.ok(Array.isArray(captured.importBindings));
  for (const row of captured.importBindings) {
    assert.equal(typeof row.importer, 'string');
    assert.equal(typeof row.specifier, 'string');
    assert.equal(typeof row.kind, 'string');
    if (row.generatedCode !== undefined) {
      assert.equal(row.generatedSha256, sha256(row.generatedCode), row.specifier);
    }
  }
  const filesystem = captured.importBindings.find(row => row.importer === 'src/infra/fs-safe.ts'
    && row.specifier === '@openclaw/fs-safe/root');
  assert.ok(filesystem, 'real filesystem owner binding is recorded');
  assert.equal(filesystem.kind, 'native-package-binding');
  assert.equal(filesystem.package, '@openclaw/fs-safe');
  assert.equal(filesystem.version, '0.26.8');
  assert.match(filesystem.sha256, /^[a-f0-9]{64}$/);
  assert.equal(filesystem.artifactReceipt.sha256,
    sha256(readFileSync(filesystem.artifactReceipt.path)));
  assert.ok(Array.isArray(filesystem.packages));
  const queue = captured.importBindings.find(row => row.importer === 'src/gateway/server-methods/workspace-fs.ts'
    && row.specifier === '@openclaw/fs-safe/advanced');
  assert.ok(queue, 'original workspace queue binds the actual lock package');
  assert.equal(queue.kind, 'native-package-binding');
  assert.equal(queue.package, '@openclaw/fs-safe');
  assert.equal(queue.version, '0.26.8');
  assert.deepEqual(captured.boundaries, expectedBoundaries);
  for (const limitation of expectedLimitations) assert.ok(captured.limitations.includes(limitation), limitation);
  const frozen = JSON.parse(readFileSync(new URL(
    '../../apps/synapsis_agent/test/fixtures/openclaw/488631c/personal-instructions.json', import.meta.url), 'utf8'));
  assert.deepEqual(captured, frozen, 'fresh original source execution equals the frozen object');
});

test('ordinary missing, create, replacement, empty, restore and explicit read preserve whole content and bytes', () => {
  assert.equal(sha256(Buffer.from(created, 'utf8')), createdHash);
  assert.equal(sha256(Buffer.from(replaced, 'utf8')), replacedHash);
  assert.equal(sha256(Buffer.alloc(0)), emptyHash);
  assert.deepEqual(captured.cases.map(row => row.id), lifecycle.map(row => row[0]));
  for (const [index, [id, input, content, hash, missing]] of lifecycle.entries()) {
    const row = captured.cases[index];
    assert.deepEqual(Object.keys(row).sort(), ['id', 'input', 'gateway', 'publicResult', 'result', 'file'].sort(), id);
    assert.deepEqual(row.input, input, id);
    const params = input.action === 'get' ? { agentId: 'fixture-main' }
      : { agentId: 'fixture-main', content: input.content, expectedHash: input.expectedHash };
    assert.deepEqual(row.gateway, { method: `users.personalFile.${input.action}`, params }, id);
    const result = publicResult(content, hash, missing);
    assert.deepEqual(row.publicResult, result, id);
    assert.deepEqual(row.result, { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
      details: result }, id);
    assert.deepEqual(row.file, missing ? null : { relativePath, utf8: content, sha256: hash,
      bytes: [...Buffer.from(content, 'utf8')] }, id);
  }
  // Complete replacement preserves both earlier preferences and adds the requested one;
  // the ordinary empty state is a real zero-byte file and remains readable.
  assert.equal(captured.cases[3].publicResult.content, replaced);
  assert.deepEqual(captured.cases[5].file.bytes, []);
  assert.equal(captured.cases[6].publicResult.missing, false);
  assert.deepEqual(captured.cases[8].gateway.params, { agentId: 'fixture-main' });
});

test('actual personal loader supplements shared USER.md in complete original prompt order with exact guidance', () => {
  assert.deepEqual(captured.bootstrap, expectedBootstrap);
  assert.equal(captured.bootstrap.workspace, workspace);
  assert.equal(captured.bootstrap.personal.content, replaced);
  assert.equal(captured.bootstrap.personal.path, `${workspace}/${relativePath}`);
  assert.equal(captured.bootstrap.personal.personalUser, true);
  assert.equal(captured.bootstrap.personal.missing, false);
  assert.deepEqual(captured.bootstrap.personal.origin,
    { kind: 'personal', rootPath: `${workspace}/users/Profile_356` });
  assert.deepEqual(captured.bootstrap.prepared.map(row => row.path),
    [`${workspace}/USER.md`, `${workspace}/${relativePath}`]);
  assert.equal(captured.bootstrap.section[4],
    "The personal users/<profile-id>/USER.md belongs to this session's selected person (assigned human owner, otherwise human creator). It supplements shared USER.md and overrides conflicting shared preferences, not higher-priority rules. Other participants do not change this personal context.");
});
