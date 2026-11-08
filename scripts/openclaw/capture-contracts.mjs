#!/usr/bin/env node
// Read-only reference capture. Never calls a tool's execute function.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness, captureRecipes, representativeContexts } from './capture-recipes.mjs';
import { captureBrowserRegistrations } from './capture-browser-registration.mjs';
import { captureSessionFactories } from './capture-session-factories.mjs';
import { capturePdfFactories } from './capture-pdf-factories.mjs';
import { captureTtsFactories } from './capture-tts-factories.mjs';
import { captureCronSchemas } from './capture-cron-schemas.mjs';

const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const inside = (root, path) => path === root || path.startsWith(root + sep);
const unique = (values) => [...new Set(values)].sort();
function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, stable(value[k])]));
  return value;
}
function options(args) {
  const result = {};
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!['--source', '--pin', '--out', '--offline'].includes(key) || key in result) throw Error(`unknown or duplicate argument: ${key}`);
    result[key] = key === '--offline' ? true : args[++i];
  }
  if (!result['--offline'] || !result['--source'] || !result['--out'] || !/^[a-f0-9]{40}$/.test(result['--pin'] ?? '')) {
    throw Error('usage: capture-contracts.mjs --source PATH --pin SHA --out DIR --offline');
  }
  return result;
}
function git(root, args) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } });
  if (result.status !== 0) throw Error(`verified git checkout required: ${result.stderr.trim()}`);
  return result.stdout.trimEnd();
}
function checkout(root, pin) {
  if (realpathSync(git(root, ['rev-parse', '--show-toplevel'])) !== root) throw Error('source must be a complete checkout root');
  if (git(root, ['rev-parse', 'HEAD']) !== pin) throw Error('source commit does not match pin');
  if (git(root, ['status', '--porcelain', '--untracked-files=no'])) throw Error('source has modified tracked files');
  const files = new Map();
  for (const entry of git(root, ['ls-tree', '-rz', '--full-tree', pin]).split('\0').filter(Boolean)) {
    const [header, path] = entry.split('\t');
    const [mode, type, oid] = header.split(' ');
    if (!path || isAbsolute(path) || path.split('/').includes('..') || !inside(root, resolve(root, path))) throw Error('source path traversal');
    if (type !== 'blob' || !['100644', '100755', '120000'].includes(mode)) throw Error(`non-file source rejected: ${path}`);
    const symlink = lstatSync(join(root, path)).isSymbolicLink();
    if (symlink !== (mode === '120000') || !inside(root, realpathSync(join(root, path)))) throw Error(`symlink traversal rejected: ${path}`);
    const bytes = symlink ? Buffer.from(readlinkSync(join(root, path))) : readFileSync(join(root, path));
    const actual = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
    if (actual !== oid) throw Error(`source hash mismatch: ${path}`);
    files.set(path, { path, sha256: hash(bytes), ...(symlink ? { kind: 'symlink' } : {}) });
  }
  for (const required of ['package.json', 'LICENSE', 'src/agents/tool-catalog.ts']) if (!files.has(required)) throw Error(`incomplete checkout: missing ${required}`);
  return { commit: pin, tree: git(root, ['rev-parse', `${pin}^{tree}`]), files: [...files.values()], verified: true };
}

function actions(schema) {
  const found = [];
  function walk(value) {
    if (!value || typeof value !== 'object') return;
    const action = value.properties?.action;
    if (typeof action?.const === 'string') found.push(action.const);
    if (Array.isArray(action?.enum)) found.push(...action.enum.filter(x => typeof x === 'string'));
    for (const x of Object.values(value)) if (Array.isArray(x)) x.forEach(walk); else walk(x);
  }
  walk(schema);
  return unique(found);
}
async function capture(root, source) {
  const tracked = new Set(source.files.filter(x => x.kind !== 'symlink').map(x => x.path));
  const catalog = new FactoryHarness(root, tracked);
  await catalog.load('src/agents/tool-catalog.ts');
  const core = unique(catalog.call('__exports.listCoreToolSections({swarmEnabled:true,personalInstructionsEnabled:true}).flatMap(s=>s.tools.map(t=>t.id))'));
  const manifests = source.files.filter(x => /^extensions\/[^/]+\/openclaw\.plugin\.json$/.test(x.path));
  const plugins = manifests.map(file => {
    const data = JSON.parse(readFileSync(join(root, file.path), 'utf8'));
    return { plugin: data.id, source: file.path, sourceSha256: file.sha256, tools: data.contracts?.tools ?? data.tools ?? [], enabledByDefault: data.enabledByDefault ?? 'unspecified', activation: data.activation ?? {}, toolMetadata: data.toolMetadata ?? {} };
  }).filter(x => x.tools.length > 0);
  const pluginNames = unique(plugins.flatMap(x => x.tools));
  const union = unique([...core, ...pluginNames]);
  const matrix = representativeContexts();
  const factories = [], registrations = [], dependencies = new Map();
  const recipeRows = [
    ...await captureRecipes(root, source.files),
    ...await captureSessionFactories(root, source.files),
    ...await capturePdfFactories(root, source.files),
    ...await captureTtsFactories(root, source.files),
  ];
  const browserRegistrations = await captureBrowserRegistrations(root, source.files);
  const schemaCaptures = await captureCronSchemas(root, source.files);
  const referencedSources = new Set(['package.json', ...catalog.loadedFiles.keys(), ...manifests.map(x => x.path)]);
  for (const file of source.files.filter(x => x.kind !== 'symlink' && /^(src|extensions)\/.+\.(ts|js)$/.test(x.path) && !/(?:^|\/)(?:tests?|fixtures?|__tests__|__fixtures__)(?:\/|$)|(?:^|[.\/-])(?:test|spec|test-helpers?|test-support|test-utils|test-harness)(?:[.\/-]|$)/.test(x.path))) {
    const code = readFileSync(join(root, file.path), 'utf8');
    for (const match of code.matchAll(/\b(?:registerTool|defineToolPlugin)\s*\(/g)) registrations.push({ source: file.path, sourceSha256: file.sha256, line: code.slice(0, match.index).split('\n').length, status: 'static-discovery', assemblyStatus: 'unresolved' });
    const exports = unique([...code.matchAll(/export\s+(?:async\s+)?function\s+(create\w*Tool)\s*\(/g)].map(x => x[1]));
    if (!exports.length) continue;
    const harness = new FactoryHarness(root, tracked);
    let loadError;
    try { await harness.load(file.path); } catch (error) { loadError = error; }
    const loadAttempts = harness.call('globalThis.__captureAudit');
    for (const name of exports) for (const context of matrix) {
      const row = { source: file.path, sourceSha256: file.sha256, export: name, context: context.id };
      // Keep module-initialization attempts, but isolate calls made by each case.
      harness.call('globalThis.__captureAudit=[]');
      try {
        if (loadError) throw loadError;
        if (loadAttempts.length) throw Error('blocked module-initialization attempt');
        // Serialization inside the VM inspects only metadata; execute is never called.
        const tool = harness.call(`(()=>{const t=__exports[${JSON.stringify(name)}](${JSON.stringify(context.options)});if(t==null)return null;if(typeof t.then==='function')throw Error('async factory unresolved');if(typeof t.name!=='string'||!t.parameters)throw Error('not a tool descriptor');return {name:t.name,description:t.description,parameters:t.parameters};})()`);
        if (harness.call('globalThis.__captureAudit').length) throw Error('blocked factory execution attempt');
        if (tool) {
          row.status = 'executed'; row.evidence = 'factory-invocation'; row.eligibility = 'factory-returned-tool';
          const schemaJson = JSON.stringify(stable(tool.parameters));
          row.tool = { ...tool, actions: actions(tool.parameters), schemaJson, schemaSha256: hash(schemaJson) };
        } else { row.status = 'ineligible'; row.eligibility = 'factory-returned-null'; }
      } catch (error) {
        row.status = 'unresolved';
        row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
      }
      const attemptedCalls = [...loadAttempts, ...harness.call('globalThis.__captureAudit')];
      if (attemptedCalls.length) row.attemptedCalls = attemptedCalls;
      factories.push(row);
    }
    for (const [key, item] of harness.dependencies) dependencies.set(key, item);
    for (const path of harness.loadedFiles.keys()) referencedSources.add(path);
  }
  for (const item of [...factories, ...registrations]) referencedSources.add(item.source);
  for (const row of [...recipeRows, ...browserRegistrations, ...schemaCaptures]) {
    if (row.sourceSha256) referencedSources.add(row.source);
    for (const evidence of [row, ...(row.definitionComparison ? [row.definitionComparison] : [])]) {
      for (const item of evidence.loadedFiles) referencedSources.add(item.path);
      for (const item of evidence.projections) if (item.sourceSha256) referencedSources.add(item.source);
      for (const file of evidence.typebox.files) dependencies.set(file.path, file);
    }
    if (row.status === 'captured' && row.evidence === 'factory-return') factories.push({ source: row.source, sourceSha256: row.sourceSha256, export: row.export, context: row.context, status: 'executed', evidence: 'factory-invocation', recipe: row.id, eligibility: 'factory-returned-tool; runtime admission unresolved', tool: { name: row.descriptor.name, description: row.descriptor.description, ...row.schema, ...(row.descriptor.outputSchema ? { outputSchema: row.descriptor.outputSchema, outputSchemaJson: row.outputSchema.schemaJson, outputSchemaSha256: row.outputSchema.schemaSha256 } : {}) } });
  }
  const gaps = [];
  for (const row of browserRegistrations) if (row.status !== 'captured') gaps.push({ kind: 'unresolved-browser-registration-callback', context: row.context, reason: row.reason });
  for (const row of recipeRows) if (row.status !== 'captured') gaps.push({kind:'unresolved-recipe',recipe:row.id,reason:row.reason});
  for (const name of union) if (!factories.some(x => x.status === 'executed' && x.tool.name === name)) gaps.push({ kind: 'missing-factory', tool: name });
  for (const row of factories.filter(x => x.status === 'unresolved')) gaps.push({ kind: 'unresolved-factory', source: row.source, export: row.export, context: row.context });
  const knownActions = new Map();
  for (const row of [...recipeRows, ...schemaCaptures.filter(x => x.evidence === 'schema-builder')].filter(x => x.status === 'captured')) {
    const variants = knownActions.get(row.referenceTool) ?? new Set();
    for (const action of row.schema.actions) variants.add(action);
    if (row.schema.actionlessBranches) variants.add('$call');
    knownActions.set(row.referenceTool, variants);
  }
  for (const [tool, variants] of knownActions) for (const action of [...variants].sort()) gaps.push({ kind: 'missing-action-cases', tool, action, cases: ['valid', 'invalid', 'denied', 'unavailable'], reason: 'tool execution not performed by offline reference capture' });
  // Direct construction does not prove policy/assembly eligibility or dynamic registration.
  gaps.push({ kind: 'assembly-contexts', reason: 'primary/child/scheduled profile and config assembly not executed; direct factory options alone do not establish eligibility' });
  for (const item of registrations) gaps.push({ kind: 'unresolved-registration', source: item.source, line: item.line });
  const copiedPaths = ['src/agents/tool-catalog.ts', ...manifests.map(x => x.path), ...[...recipeRows, ...browserRegistrations, ...schemaCaptures].flatMap(x => x.loadedFiles.map(file => file.path))];
  const licenses = source.files.filter(x => /^(?:LICEN[CS]E|NOTICE)(?:\.[^/]+)?$/i.test(x.path.split('/').at(-1)) && copiedPaths.some(path => dirname(x.path) === '.' || path.startsWith(dirname(x.path) + '/')));
  for (const item of licenses) referencedSources.add(item.path);
  source.verifiedTrackedFiles = source.files.length;
  source.hashScope = 'referenced capture evidence; full checkout blobs verified against pinned tree';
  source.files = source.files.filter(x => referencedSources.has(x.path));
  return { schemaVersion: 1, referenceRole: 'capability_reference', runtimeContractAuthority: 'backplane_agent_runtime',
    source, captureRuntime: { node: process.version }, captureMethod: 'restricted direct factory invocation, bounded source-backed recipes including session, PDF and TTS factories, separate cron schema-only evidence, and projected Browser registerTool callbacks; no execute calls; full plugin registration and assembly unresolved',
    inventory: { core, plugins, scannedManifests: manifests, union, counts: { core: core.length, manifestsScanned: manifests.length, toolManifests: plugins.length, uniquePluginTools: pluginNames.length, corePluginOverlap: core.filter(x => pluginNames.includes(x)).length, pluginOnly: pluginNames.filter(x => !core.includes(x)).length, union: union.length } },
    contexts: matrix, recipes: recipeRows, browserRegistrations, schemaCaptures, factories, registrations, licenses, dependencies: [...dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)),
    completeness: { complete: gaps.length === 0, gaps },
  };
}
async function main() {
  const args = options(process.argv.slice(2));
  const root = realpathSync(args['--source']);
  const out = resolve(args['--out']);
  let ancestor = out;
  while (!existsSync(ancestor)) ancestor = dirname(ancestor);
  if (inside(root, resolve(realpathSync(ancestor), relative(ancestor, out)))) throw Error('output must be outside the source checkout');
  if (existsSync(out)) throw Error('output directory already exists; choose a new output path');
  const source = checkout(root, args['--pin']);
  const report = await capture(root, source);
  // Recheck the bytes after evaluation to catch concurrent source modifications.
  checkout(root, args['--pin']);
  mkdirSync(out, { recursive: true });
  const snapshots = new Map([source.files.find(x => x.path === 'src/agents/tool-catalog.ts'), ...report.inventory.scannedManifests, ...[...report.recipes, ...report.browserRegistrations, ...report.schemaCaptures].flatMap(x => [x, ...(x.definitionComparison ? [x.definitionComparison] : [])].flatMap(item => item.loadedFiles)), ...report.licenses].map(x => [x.path, x]));
  for (const file of snapshots.values()) {
    const target = join(out, 'sources', file.path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, readFileSync(join(root, file.path)));
  }
  writeFileSync(join(out, 'capture.json'), JSON.stringify(stable(report), null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: join(out, 'capture.json'), counts: report.inventory.counts, complete: report.completeness.complete, gaps: report.completeness.gaps.length }) + '\n');
  process.exitCode = report.completeness.complete ? 0 : 2;
}
if (!vm.SourceTextModule) {
  const child = spawnSync(process.execPath, ['--experimental-vm-modules', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exitCode = child.status ?? 1;
} else {
  main().catch(error => { process.stderr.write(`capture: ${error.message}\n`); process.exitCode = 1; });
}
