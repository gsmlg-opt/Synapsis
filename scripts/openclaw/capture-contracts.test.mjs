import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./capture-contracts.mjs', import.meta.url));
function repository(extra = {}) {
  const root = mkdtempSync(join(tmpdir(), 'openclaw-capture-test-'));
  const files = {
    'package.json': '{"name":"openclaw","type":"module"}',
    'LICENSE': 'MIT License\nCopyright capture test fixture\n',
    'src/agents/tool-catalog.ts': 'export function listCoreToolSections() { return [{id:"test",tools:[{id:"reference"}]}]; }',
    'src/agents/tools/reference.ts': 'export function createReferenceTool(options: {isSubagent?: boolean} = {}) { return {name:"reference", description:"Reference", parameters:{type:"object",properties:{action:{enum:options.isSubagent?["read"]:["read","write"]}}}, execute(){ throw new Error("EXECUTE MUST NEVER RUN"); }}; }',
    'extensions/sample/openclaw.plugin.json': '{"id":"sample","tools":["plugin_reference"]}',
    ...extra,
  };
  for (const [path, data] of Object.entries(files)) {
    mkdirSync(join(root, path, '..'), { recursive: true });
    writeFileSync(join(root, path), data);
  }
  function git(args) {
    const r = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout.trim();
  }
  git(['init', '-q']); git(['add', '.']);
  git(['-c', 'user.name=Capture Test', '-c', 'user.email=capture@example.invalid', 'commit', '-qm', 'fixture']);
  return { root, pin: git(['rev-parse', 'HEAD']), out: join(mkdtempSync(join(tmpdir(), 'openclaw-output-test-')), 'snapshot') };
}
function capture(repo, args = []) {
  return spawnSync(process.execPath, [script, '--source', repo.root, '--pin', repo.pin, '--out', repo.out, '--offline', ...args], { encoding: 'utf8', timeout: 30000 });
}

test('rejects a partial tree and wrong commit before writing output', () => {
  const repo = repository();
  const wrong = capture({ ...repo, pin: '0'.repeat(40) });
  assert.notEqual(wrong.status, 0);
  assert.match(wrong.stderr, /pin|duplicate/i);
  assert.equal(existsSync(repo.out), false);
  const partial = { ...repo, root: mkdtempSync(join(tmpdir(), 'openclaw-partial-test-')) };
  const result = capture(partial);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /checkout|git/i);
});

test('checks source blob hashes even when Git is told to assume a file unchanged', () => {
  const repo = repository();
  spawnSync('git', ['-C', repo.root, 'update-index', '--assume-unchanged', 'src/agents/tools/reference.ts']);
  writeFileSync(join(repo.root, 'src/agents/tools/reference.ts'), 'modified despite clean status');
  const result = capture(repo);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /source hash mismatch/i);
  assert.equal(existsSync(repo.out), false);
});

test('rejects modified tracked source and symlink traversal', () => {
  const repo = repository();
  writeFileSync(join(repo.root, 'src/agents/tools/reference.ts'), 'modified');
  const dirty = capture(repo);
  assert.notEqual(dirty.status, 0);
  assert.match(dirty.stderr, /modified|dirty|hash/i);
  assert.equal(existsSync(repo.out), false);
  const linked = repository();
  symlinkSync(tmpdir(), join(linked.root, 'escape'));
  spawnSync('git', ['-C', linked.root, 'add', 'escape']);
  spawnSync('git', ['-C', linked.root, '-c', 'user.name=Test', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'link']);
  linked.pin = spawnSync('git', ['-C', linked.root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
  const traversal = capture(linked);
  assert.notEqual(traversal.status, 0);
  assert.match(traversal.stderr, /symlink|traversal/i);
});

test('captures actual factory variants deterministically while reporting incomplete assembly', () => {
  const repo = repository();
  const first = capture(repo);
  assert.equal(first.status, 2, first.stderr);
  const bytes = readFileSync(join(repo.out, 'capture.json'), 'utf8');
  const report = JSON.parse(bytes);
  assert.equal(report.source.commit, repo.pin);
  assert.deepEqual(report.inventory.core, ['reference']);
  const variants = report.factories.filter(x => x.status === 'executed' && x.tool?.name === 'reference');
  assert.ok(variants.some(x => x.context.startsWith('primary/') && x.tool.actions.includes('write')));
  assert.ok(variants.some(x => x.context.startsWith('child/') && !x.tool.actions.includes('write')));
  assert.equal(report.completeness.complete, false);
  assert.ok(report.completeness.gaps.length > 0);
  const second = capture({ ...repo, out: `${repo.out}-second` });
  assert.equal(second.status, 2, second.stderr);
  assert.equal(readFileSync(join(`${repo.out}-second`, 'capture.json'), 'utf8'), bytes);
});

test('blocks filesystem, network, process and execute effects in factories', () => {
  const sentinel = join(tmpdir(), `openclaw-must-not-exist-${process.pid}`);
  const repo = repository({
    'src/agents/tools/effect.ts': `import {writeFileSync} from "node:fs"; export function createEffectTool(){writeFileSync(${JSON.stringify(sentinel)},"bad");return {name:"bad",parameters:{}};}`,
    'src/agents/tools/network.ts': 'export function createNetworkTool(){fetch("https://example.invalid"); return {name:"bad",parameters:{}};}',
    'src/agents/tools/process.ts': 'export function createProcessTool(){process.exit(0);}',
  });
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  assert.equal(existsSync(sentinel), false);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  for (const name of ['createEffectTool', 'createNetworkTool', 'createProcessTool']) {
    assert.ok(report.factories.some(x => x.export === name && x.status === 'unresolved'));
    assert.ok(!report.factories.some(x => x.export === name && x.status === 'executed'));
  }
});

test('refuses output inside the source checkout', () => {
  const repo = repository();
  const result = capture({ ...repo, out: join(repo.root, 'capture') });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /output|source/i);
  assert.equal(existsSync(join(repo.root, 'capture')), false);
});

test('accepts pinned in-tree symlinks without evaluating aliases', () => {
  const repo = repository();
  symlinkSync('reference.ts', join(repo.root, 'src/agents/tools/alias.ts'));
  spawnSync('git', ['-C', repo.root, 'add', '.']);
  spawnSync('git', ['-C', repo.root, '-c', 'user.name=Test', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'internal alias']);
  repo.pin = spawnSync('git', ['-C', repo.root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  assert.equal(report.source.verified, true);
  assert.ok(!report.factories.some(x => x.source.endsWith('alias.ts')));
});

function recipeSources(canvasBody = 'return {...canvasToolDefinition,execute(){throw Error("EXECUTE MUST NEVER RUN")}};', llmBody = 'return {...llmTaskToolDefinition,execute(){throw Error("EXECUTE MUST NEVER RUN")}};') {
  return {
    'extensions/voice-call/src/tool-schema.ts': 'export const VoiceCallToolSchema={anyOf:[{type:"object",properties:{action:{const:"initiate_call"}},required:["action"]},{type:"object",properties:{mode:{type:"string"}}}]};',
    'extensions/canvas/src/tool-schema.ts': 'import {optionalFiniteNumberSchema,optionalPositiveIntegerSchema,stringEnum} from "openclaw/plugin-sdk/channel-actions"; export const canvasToolDefinition={name:"canvas",description:"Canvas",parameters:{type:"object",properties:{action:stringEnum(["present","hide","navigate"]),x:optionalFiniteNumberSchema(),timeoutMs:optionalPositiveIntegerSchema()}}};',
    'extensions/canvas/src/tool.ts': `import {jsonResult} from "openclaw/plugin-sdk/channel-actions"; import {canvasToolDefinition} from "./tool-schema.js"; export function createCanvasTool(options){${canvasBody}}`,
    'extensions/llm-task/src/llm-task-tool-definition.ts': 'import {optionalPositiveIntegerSchema} from "openclaw/plugin-sdk/channel-actions"; export const llmTaskToolDefinition={name:"llm-task",description:"JSON task",parameters:{type:"object",properties:{prompt:{type:"string"},maxTokens:optionalPositiveIntegerSchema()}}};',
    'extensions/llm-task/src/llm-task-tool.ts': `import {llmTaskToolDefinition} from "./llm-task-tool-definition.js"; export function createLlmTaskTool(api){${llmBody}}`,
    'src/agents/schema/typebox.ts': 'export function optionalFiniteNumberSchema(){return {type:"number"}} export function optionalPositiveIntegerSchema(){return {type:"integer",minimum:1}}',
    'src/agents/schema/string-enum.ts': 'export function stringEnum(values){return {type:"string",enum:values}}',
  };
}

test('bounded recipes execute real schema exports and factories without calling execute', () => {
  const repo = repository(recipeSources());
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  const voice = report.recipes.find(x => x.id === 'voice-call/schema');
  assert.equal(voice.status, 'captured');
  assert.equal(voice.evidence, 'schema-export');
  assert.equal(voice.schema.actionlessBranches, 1);
  for (const name of ['canvas', 'llm-task']) {
    const row = report.recipes.find(x => x.id === `${name}/factory`);
    assert.equal(row.status, 'captured', JSON.stringify(row));
    assert.equal(row.evidence, 'factory-return');
    assert.equal(row.descriptorMatch, true);
    assert.deepEqual(row.attemptedCalls, []);
    assert.equal(row.eligibility.status, 'unresolved');
    assert.equal(row.registration.status, 'unresolved');
    assert.ok(row.loadedFiles.some(x => x.path.startsWith(`extensions/${name}/`)));
  }
});

test('a caught execution-service call or API property access leaves recipe unresolved', () => {
  const repo = repository(recipeSources('try{jsonResult({})}catch{}return {...canvasToolDefinition,execute(){}};', 'try{void api.config}catch{}return {...llmTaskToolDefinition,execute(){}};'));
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  for (const name of ['canvas', 'llm-task']) {
    const row = report.recipes.find(x => x.id === `${name}/factory`);
    assert.equal(row.status, 'unresolved');
    assert.ok(row.attemptedCalls.length > 0);
  }
});

test('dynamic import and an unaudited importer cannot acquire execution-service imports', () => {
  const repo = repository(recipeSources('void import("node:fs").catch(()=>{});return {...canvasToolDefinition,execute(){}};'));
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  const row = report.recipes.find(x => x.id === 'canvas/factory');
  assert.equal(row.status, 'unresolved');
  assert.ok(row.attemptedCalls.some(x => x.kind === 'dynamic-import'));
  const unknown = repository({...recipeSources(), 'extensions/canvas/src/tool-schema.ts':'import {jsonResult} from "openclaw/plugin-sdk/channel-actions"; export const canvasToolDefinition={name:"canvas",parameters:{}};'});
  const blocked = capture(unknown);
  assert.equal(blocked.status, 2, blocked.stderr);
  const blockedReport = JSON.parse(readFileSync(join(unknown.out, 'capture.json'), 'utf8'));
  assert.equal(blockedReport.recipes.find(x => x.id === 'canvas/schema').status, 'unresolved');
});

test('recipe snapshots and source-backed projections are deterministic', () => {
  const repo = repository(recipeSources());
  assert.equal(capture(repo).status, 2);
  assert.equal(capture({...repo,out:repo.out+'-second'}).status, 2);
  const first = readFileSync(join(repo.out, 'capture.json'), 'utf8');
  assert.equal(readFileSync(join(repo.out+'-second', 'capture.json'), 'utf8'), first);
  const row = JSON.parse(first).recipes.find(x => x.id === 'canvas/schema');
  assert.ok(row.projections.some(x => x.exports.includes('stringEnum') && x.source === 'src/agents/schema/string-enum.ts'));
});

test('generic discovery excludes test helpers and fixture factories', () => {
  const repo = repository({'src/agents/tools/test-helpers.ts':'export function createFakeTool(){return {name:"fake",parameters:{}}}', 'extensions/sample/test/fixture.ts':'export function createFakeTool(){return {name:"fake",parameters:{}}}'});
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  assert.ok(!report.factories.some(x => x.export === 'createFakeTool'));
});

test('copies applicable source licenses and hashes only captured evidence', () => {
  const repo = repository({...recipeSources(), 'NOTICE':'Root notice', 'extensions/canvas/LICENSE':'Canvas notice', 'unrelated/photo.txt':'Do not serialize an unrelated hash'});
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  for (const path of ['LICENSE','NOTICE','extensions/canvas/LICENSE']) {
    assert.ok(report.licenses.some(x => x.path === path));
    assert.equal(readFileSync(join(repo.out,'sources',path),'utf8'), readFileSync(join(repo.root,path),'utf8'));
  }
  assert.ok(!report.source.files.some(x => x.path === 'unrelated/photo.txt'));
  assert.equal(report.source.hashScope, 'referenced capture evidence; full checkout blobs verified against pinned tree');
});

test('generic factories cannot hide caught dynamic imports or contaminate the next case', () => {
  const repo = repository({'src/agents/tools/audit.ts': 'export function createAttemptTool(){void import("node:fs").catch(()=>{});return {name:"attempt",parameters:{}}} export function createCleanTool(){return {name:"clean",parameters:{}}}'});
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  const attempted = report.factories.filter(x => x.export === 'createAttemptTool');
  assert.equal(attempted.length, 24);
  assert.ok(attempted.every(x => x.status === 'unresolved' && x.attemptedCalls.some(a => a.kind === 'dynamic-import')));
  const clean = report.factories.filter(x => x.export === 'createCleanTool');
  assert.equal(clean.length, 24);
  assert.ok(clean.every(x => x.status === 'executed' && !x.attemptedCalls?.length));
});

test('generic factories retain caught module-initialization dynamic import attempts', () => {
  const repo = repository({'src/agents/tools/audit.ts': 'void import("node:fs").catch(()=>{});export function createAttemptTool(){return {name:"attempt",parameters:{}}}'});
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  const attempted = report.factories.filter(x => x.export === 'createAttemptTool');
  assert.equal(attempted.length, 24);
  assert.ok(attempted.every(x => x.status === 'unresolved' && x.attemptedCalls.some(a => a.kind === 'dynamic-import')));
});

test('rejects an installed TypeBox version different from the pinned capture dependency', () => {
  const repo = repository({
    ...recipeSources(),
    'extensions/voice-call/src/tool-schema.ts':'import {Type} from "typebox";export const VoiceCallToolSchema=Type.Object({});',
    'node_modules/typebox/package.json':'{"name":"typebox","version":"9.9.9","type":"module","main":"index.js"}',
    'node_modules/typebox/index.js':'export const Type={Object:x=>({type:"object",properties:x})};',
  });
  const result = capture(repo);
  assert.equal(result.status, 2, result.stderr);
  const report = JSON.parse(readFileSync(join(repo.out, 'capture.json'), 'utf8'));
  const voice = report.recipes.find(x => x.id === 'voice-call/schema');
  assert.equal(voice.status, 'unresolved');
  assert.match(voice.reason, /TypeBox.*1\.3\.37.*9\.9\.9/i);
});
