import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { evaluate } from '../../../apps/synapsis_core/priv/skill_workshop/contract.mjs';

// Literal successful expectations, frozen independently before the host exists.
// These exercise authoring behavior; scanner/permission and failure tests are excluded.
const pin = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const skill = (description, body = '1. Inspect the release.\n2. Record the result.') =>
  `---\nname: deploy-guide\ndescription: ${description}\n---\n\n${body}\n`;
const advisory = text => `Advisory (not blocking): ${text} Fix with action=patch.`;
const identityAdvisory = advisory('description opens with "This skill"; open with the situation that triggers it.');
const narrativeAdvisory = advisory('found an update note or date; fold the lesson into the step it changes.');

test('frontmatter retains scalar strings and source serialization of ordinary metadata', async () => {
  const request = Object.freeze({ operation: 'frontmatter', content: [
    '---',
    'name: deploy-guide',
    'description: Deploy a reviewed release.',
    'enabled: true',
    'retries: 3',
    'mode: yes',
    'tags:',
    '  - alpha',
    '  - beta',
    'metadata:',
    '  openclaw:',
    '    events:',
    '      - command:new',
    'display: {"emoji": "disk", "label": "café"} # display metadata',
    'flow: {a: 1,',
    '  b: 2}',
    '---',
    'Ordinary Markdown.',
  ].join('\n') });
  const original = structuredClone(request);
  assert.deepEqual(await evaluate(request), {
    name: 'deploy-guide', description: 'Deploy a reviewed release.', enabled: 'true',
    retries: '3', mode: 'yes', tags: '["alpha","beta"]',
    metadata: '{"openclaw":{"events":["command:new"]}}',
    display: '{"emoji": "disk", "label": "café"}', flow: '{"a":1,"b":2}',
  });
  assert.deepEqual(request, original);
});

test('authored colon-rich freeform fields recover while structured siblings remain complete', async () => {
  const content = [
    '---',
    'name: deploy-guide',
    'description: Release: inspect the reviewed build.',
    'read_when: signals: user announcing a conversion task',
    'summary: handles formats: pdf and docx',
    'metadata:',
    '  openclaw:',
    '    emoji: beaker',
    '---',
    'Record the result.',
  ].join('\n');
  assert.deepEqual(await evaluate({ operation: 'frontmatter', content }), {
    name: 'deploy-guide', description: 'Release: inspect the reviewed build.',
    read_when: 'signals: user announcing a conversion task', summary: 'handles formats: pdf and docx',
    metadata: '{"openclaw":{"emoji":"beaker"}}',
  });
});

test('BOM and ordinary Windows or classic Mac line endings retain block-scalar metadata', async () => {
  const lines = ['---  ', 'name: deploy-guide', 'description: >-',
    '  Deploy a reviewed release', '  and record the result.', '---\t', 'Body.'];
  for (const separator of ['\r\n', '\r']) {
    assert.deepEqual(await evaluate({ operation: 'frontmatter', content: '\uFEFF' + lines.join(separator) }), {
      name: 'deploy-guide', description: 'Deploy a reviewed release and record the result.',
    });
  }
});

test('ordinary scalar and structured aliases resolve into independent string values', async () => {
  const content = [
    '---', 'name: deploy-guide', 'title: &trigger Deploy a reviewed release.',
    'description: *trigger', 'shared: &release', '  steps:', '    - inspect', '    - record',
    'metadata: *release', '---', 'Inspect the release.',
  ].join('\n');
  assert.deepEqual(await evaluate({ operation: 'frontmatter', content }), {
    name: 'deploy-guide', title: 'Deploy a reviewed release.', description: 'Deploy a reviewed release.',
    shared: '{"steps":["inspect","record"]}', metadata: '{"steps":["inspect","record"]}',
  });
});

test('ordinary full SKILL.md analysis returns metadata and leaves exact authored bytes alone', async () => {
  const content = skill('Deploy a reviewed release.');
  const request = Object.freeze({ operation: 'analyze', name: 'deploy-guide', filePath: 'SKILL.md', content });
  assert.deepEqual(await evaluate(request), {
    frontmatter: { name: 'deploy-guide', description: 'Deploy a reviewed release.' },
    description: 'Deploy a reviewed release.', advisories: [],
  });
  assert.equal(request.content, '---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\n\n1. Inspect the release.\n2. Record the result.\n');
});

test('ordinary examples and templates remain support bytes without a Markdown metadata substitute', async () => {
  const content = '{"release": "<version>", "note": "café 雪 😀"}\r\n$& $1 $$\n';
  for (const filePath of ['examples/release.json', 'templates/check.txt']) {
    const request = Object.freeze({ operation: 'analyze', name: 'deploy-guide', filePath, content });
    assert.deepEqual(await evaluate(request), { advisories: [] });
    assert.equal(request.content, content);
  }
});

test('successful authoring reports the first three newly introduced style rules in source order', async () => {
  const content = skill('This skill is powerful.', [
    '- Never duplicate a release step.', "- Don't repeat the inventory.",
    '1. Do not repeat the report.', 'UPDATE: Record the release result.',
  ].join('\n'));
  assert.deepEqual(await evaluate({ operation: 'analyze', name: 'deploy-guide', filePath: 'SKILL.md', content }), {
    frontmatter: { name: 'deploy-guide', description: 'This skill is powerful.' },
    description: 'This skill is powerful.',
    advisories: [identityAdvisory,
      advisory('cut no-op emphasis (powerful); plain steps carry the same weight.'),
      advisory("3 lines start with Never/Don't; state the behavior to produce instead.")],
  });
});

test('standing style rules stay suppressed even when their wording changes', async () => {
  const before = skill('Deploy the reviewed release.', '1. Make sure to collect the result.');
  const after = skill('This skill records releases.',
    '1. IMPORTANT: Make sure to record the result.\nUPDATE: Fold the new step into the procedure.');
  assert.deepEqual(await evaluate({ operation: 'advisories', before, after }), [identityAdvisory, narrativeAdvisory]);
  assert.deepEqual(await evaluate({ operation: 'analyze', name: 'deploy-guide', filePath: 'SKILL.md',
    content: after, before, maxSkillBytes: 8192 }), {
    frontmatter: { name: 'deploy-guide', description: 'This skill records releases.' },
    description: 'This skill records releases.', advisories: [identityAdvisory, narrativeAdvisory],
  });
});

test('quoted code stays out of prose advice and emphasis follows actual source match order', async () => {
  const quoted = skill('Deploy the reviewed release.', [
    '1. Run `IMPORTANT robust`.', '```text', 'UPDATE: robust', 'Never duplicate.',
    "Don't repeat.", 'Do not copy.', '```', '2. Record the result.',
  ].join('\n'));
  assert.deepEqual(await evaluate({ operation: 'advisories', before: '', after: quoted }), []);
  const after = skill('Deploy the reviewed release.',
    '1. IMPORTANT: Make sure to record the result.\n2. Make sure to report it.');
  assert.deepEqual(await evaluate({ operation: 'advisories', before: '', after }), [
    advisory('cut no-op emphasis (Make sure to, IMPORTANT); plain steps carry the same weight.'),
  ]);
});

test('one ordinary worker response preserves the reference and completes with actual exit zero', async () => {
  const worker = fileURLToPath(new URL('../../../apps/synapsis_core/priv/skill_workshop/worker.mjs', import.meta.url));
  const child = spawn(process.execPath, [worker], { stdio: ['pipe', 'pipe', 'pipe'] });
  const stdout = [], stderr = [];
  child.stdout.on('data', chunk => stdout.push(chunk));
  child.stderr.on('data', chunk => stderr.push(chunk));
  const closed = once(child, 'close');
  child.stdin.end(JSON.stringify({ operation: 'frontmatter', content: skill('Deploy a reviewed release.') }) + '\n');
  const [exitStatus, signal] = await closed;
  assert.equal(exitStatus, 0);
  assert.equal(signal, null);
  assert.equal(child.exitCode, 0);
  assert.equal(Buffer.concat(stderr).toString(), '');
  const output = Buffer.concat(stdout).toString();
  assert.equal(output.trim().split('\n').length, 1);
  assert.deepEqual(JSON.parse(output), {
    protocol: 1, referenceCommit: pin, pid: child.pid,
    runtime: { node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
      icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch },
    result: { name: 'deploy-guide', description: 'Deploy a reviewed release.' },
  });
  if (process.platform === 'linux') assert.equal(existsSync(`/proc/${child.pid}`), false);
});
