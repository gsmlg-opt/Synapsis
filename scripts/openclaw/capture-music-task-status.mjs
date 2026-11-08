// Complete pinned music status owner/actions, already-scoped successful snapshots only.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const MUSIC_TASK_STATUS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const shared = 'src/agents/media-generation-task-status-shared.ts';
const status = 'src/agents/media-generation-task-status.ts';
const details = 'src/agents/session-async-task-status.ts';
const actionHelper = 'src/agents/tools/media-generate-tool-actions-shared.ts';
const actions = 'src/agents/tools/music-generate-tool.actions.ts';
const strings = 'packages/normalization-core/src/string-coerce.ts';
const wholeSources = [shared, status, details, actionHelper, actions, strings];
const activity = 'src/agents/media-generation-activity.ts';
const unusedImports = [
  [shared, '@openclaw/normalization-core', ['stableStringify'], 'packages/normalization-core/src/index.ts', 'Request-key builder is uninvoked; supplied opaque keys are used verbatim.'],
  [shared, '@openclaw/normalization-core/utf16-slice', ['truncateUtf16Safe'], 'packages/normalization-core/src/utf16-slice.ts', 'Prompt-context/truncation is outside this batch and uninvoked.'],
  [shared, '../routing/session-key.js', ['parseAgentSessionKey'], 'src/routing/session-key.ts', 'All tasks have explicit same-Agent requesterAgentId; session-key fallback parser is uninvoked.'],
  [shared, './sanitize-for-prompt.js', ['sanitizeForPromptLiteral'], 'src/agents/sanitize-for-prompt.ts', 'Prompt-context sanitizer is outside this batch and uninvoked.'],
  [actions, '../../media-generation/registry.js', ['listMusicGenerationProviders'], 'src/media-generation/registry.ts', 'Provider list closure initializes, but registry is never queried.'],
  [actions, '../../music-generation/capabilities.js', ['listSupportedMusicGenerationModes'], 'src/music-generation/capabilities.ts', 'Provider list/capabilities callbacks are uninvoked.'],
  [actionHelper, '../../../packages/media-generation-core/src/catalog.js', ['listMediaGenerationProviderModels','synthesizeMediaGenerationCatalogEntries'], 'packages/media-generation-core/src/catalog.ts', 'Provider-list/catalog callbacks are uninvoked.'],
  [actionHelper, '../../secrets/provider-env-vars.js', ['getProviderEnvVarsCore'], 'src/secrets/provider-env-vars.ts', 'Provider-list credential hints are uninvoked.'],
  [actionHelper, './media-tool-shared.js', ['isCapabilityProviderConfiguredAsync','resolveGenerateAction'], 'src/agents/tools/media-tool-shared.ts', 'Provider readiness and public tool execute dispatch are uninvoked.'],
  [actionHelper, './model-config.helpers.js', ['prepareToolAuthProfileStore'], 'src/agents/tools/model-config.helpers.ts', 'Credential store and tool execution are uninvoked.'],
];
const provenance = ['LICENSE', activity, 'packages/normalization-core/src/stable-stringify.ts',
  'src/music-generation/types.ts', ...unusedImports.map(row => row[3])];
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sessionKey = 'agent:music:session:ordinary';
const agentId = 'music';
function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MUSIC_TASK_STATUS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MUSIC_TASK_STATUS_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source); const stat = lstatSync(file); const symlink = stat.isSymbolicLink();
    if (!symlink) assert.equal(Boolean(stat.mode & 0o111), mode === '100755', source + ' mode');
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, mode, gitBlob: blob, sha256: hash(bytes) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])), receipt: {
    verified: true, commit: MUSIC_TASK_STATUS_PIN,
    tree: git(root, ['rev-parse', `${MUSIC_TASK_STATUS_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)),
  } };
}

const task = (taskId, status = 'running', extra = {}) => ({ taskId, taskKind: 'music_generation',
  sourceId: 'music_generate:google', requestKey: 'opaque-key', task: 'same prompt', status,
  requesterAgentId: agentId, requesterSessionKey: sessionKey, ...extra });
function vectors() {
  const row = (id, op, tasks, request = {}) => ({ id, op, tasks, request });
  return plain([
    row('active-running-first-stable', 'active', [task('q1','queued'), task('r1'), task('r2'), task('q2','queued')]),
    row('active-queued-stable', 'active', [task('q1','queued'),task('q2','queued')]),
    row('active-running-insertion-order', 'active', [task('r2','running',{updatedAt:1}),task('r1','running',{updatedAt:999999})]),
    row('active-prompt-js-trim', 'active', [task('other','running',{task:'different prompt'}),task('matched','running',{task:'  same prompt\u00a0 '})], {prompt:' \uFEFFsame prompt\u00a0 '}),
    row('active-blank-query', 'active', [task('r1')], {prompt:' \uFEFF\u00a0 '}),
    row('active-delivering-completion', 'active', [task('q1','queued'),task('delivering','running',{progressSummary:'Generated media; delivering completion'})]),
    row('active-bare-source', 'active', [task('bare','running',{sourceId:' music_generate '})]),
    row('active-entire-provider-suffix', 'active', [task('suffix','running',{sourceId:' \uFEFFmusic_generate:  google:preview  \u00a0'})]),
    row('active-empty-provider-suffix', 'active', [task('empty-provider','running',{sourceId:'music_generate: \uFEFF '})]),
    row('active-raw-progress', 'active', [task('progress','running',{progressSummary:'  Verse done!\nnext  ',runId:' run raw '})]),
    row('duplicate-active-different-key', 'duplicate', [task('q1','queued',{requestKey:'old-q'}),task('r1','running',{requestKey:'old-r'})], {prompt:'same prompt',requestKey:'new full key'}),
    row('duplicate-active-prompt-trim', 'duplicate', [task('matched','queued',{task:' same prompt\u00a0 ',requestKey:'previous full key'})], {prompt:'\uFEFFsame prompt ',requestKey:'new full key'}),
    row('duplicate-recent-last-insertion', 'duplicate', [task('first','succeeded',{updatedAt:999999,task:'older prompt'}),task('last','succeeded',{updatedAt:1,task:'recent prompt',progressSummary:'Tracks sent.'})], {prompt:'same prompt',requestKey:'opaque-key'}),
    row('duplicate-recent-opaque-key', 'duplicate', [task('opaque','succeeded',{requestKey:' opaque key\n ',task:'prior prompt'})], {prompt:'same prompt',requestKey:' opaque key\n '}),
    row('duplicate-recent-with-other-active', 'duplicate', [task('other','running',{task:'different prompt'}),task('recent','succeeded')], {prompt:'same prompt',requestKey:'opaque-key'}),
    row('duplicate-recent-last-matching-key', 'duplicate', [task('first','succeeded'),task('other-key','succeeded',{requestKey:'another-key'}),task('last','succeeded')], {prompt:'same prompt',requestKey:'opaque-key'}),
    row('duplicate-recent-bare-source', 'duplicate', [task('bare-done','succeeded',{sourceId:'music_generate',terminalOutcome:'completed'})], {prompt:'same prompt',requestKey:'opaque-key'}),
    row('details-running-minimal', 'details', [{taskId:'minimal',status:'running'}]),
    row('details-queued-optional-empty', 'details', [{taskId:'queued',status:'queued',runId:'',taskKind:'',sourceId:'',progressSummary:''}]),
    row('details-succeeded', 'details', [task('done','succeeded',{runId:'run-done',progressSummary:'Music sent.'})]),
    row('details-truthy-whitespace', 'details', [task('raw','queued',{runId:'  ',sourceId:'  ',progressSummary:'  '})]),
    row('details-raw-provider-progress', 'details', [task('raw-suffix','succeeded',{sourceId:' music_generate:  minimax:portal ',progressSummary:'Sent: yes!',runId:' raw run '})]),
    row('status-empty-snapshot', 'status', []),
  ]);
}

class MusicStatusHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, {allowedSources:wholeSources});
    this.context=vm.createContext({__platform:{
      unused:name=>{ throw Error('Uninvoked import called: '+name); },
      list:(session, agent)=>{
        assert.equal(session,sessionKey);assert.equal(agent,agentId);
        assert.ok(this.current.tasks.every(task=>task.requesterAgentId===agentId));
        this.current.activityCalls.push({sessionKey:session,agentId:agent,returnedTaskIds:this.current.tasks.map(task=>task.taskId),
          implementation:'explicit-complete-already-scoped-ordered-snapshot-facade'});
        return this.current.tasks;
      },
    }},{codeGeneration:{strings:false,wasm:false}});
    this.sourceRecords=new Map();this.importBindings=new Map();this.dynamicImports=[];
  }
  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const source = relative(this.root, file); assert.ok(wholeSources.includes(source), source);
    const bytes = readFileSync(file); assert.equal(hash(bytes), this.tracked.get(source), source);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(bytes), executed: true, wholeModule: true,
      transformation: transform, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: specifier => { this.dynamicImports.push({ importer: source, specifier });
        throw Error('Undeclared music status dynamic import'); } });
    this.modules.set(file, mod); return mod;
  }
  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code), ...extra });
    return this.synthetic('capture:music-status:' + key, code);
  }
  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind: 'whole-source-module',
      source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }

  import(specifier,parent){
    const importer=relative(this.root,parent);
    if(specifier==='@openclaw/normalization-core/string-coerce'&&[shared,status].includes(importer))
      return this.source(importer,specifier,strings);
    if([shared,status].includes(importer)&&specifier==='./media-generation-activity.js')
      return this.binding(importer,specifier,'explicit-complete-already-scoped-ordered-snapshot-facade',['listMediaGenerationOperations'],
        'export const listMediaGenerationOperations=globalThis.__platform.list;', {source:activity,sourceSha256:this.tracked.get(activity),
          limit:'Snapshot order and exact same-session/Agent membership are supplied. No actual activity Store, pruning, lifecycle, key construction or scope enforcement runs.'});
    if(specifier.startsWith('.')){
      const source=relative(this.root,resolve(dirname(parent),specifier)).replace(/\.js$/,'.ts');
      if(wholeSources.includes(source))return this.source(importer,specifier,source);
    }
    const rule=unusedImports.find(row=>row[0]===importer&&row[1]===specifier);
    if(rule){
      const [,,exports,source,limit]=rule;
      return this.binding(importer,specifier,'uninvoked-import-facade',exports,
        exports.map(name=>'export const '+name+'=(...args)=>globalThis.__platform.unused('+JSON.stringify(source+'#'+name)+');').join('\n'),
        {source,sourceSha256:this.tracked.get(source),limit});
    }
    throw Error('Undeclared music status import: '+importer+' -> '+specifier);
  }
  async prepare(){
    await this.load(status);this.context.__status=this.context.__exports;
    await this.load(actions);this.context.__actions=this.context.__exports;
  }
  async run(vector){
    const tasks=plain(vector.tasks);const request=plain(vector.request);
    this.current={tasks,activityCalls:[]};
    const before=plain(tasks);this.context.__tasks=tasks;
    this.context.__session=' \uFEFF'+sessionKey+' \u00a0';this.context.__agent=agentId;
    this.context.__query={...request,agentId};
    let selected;
    const result={};
    const call=expr=>new vm.Script(expr).runInContext(this.context,{timeout:1000});
    if(vector.op==='active'){
      selected=await call('__status.findActiveMusicGenerationTaskForSession(__session,__query)');
      assert.ok(selected,'ordinary positive active selection');
      result.statusResult=plain(await call('__actions.createMusicGenerateStatusActionResult(__session,__agent)'));
    }else if(vector.op==='duplicate'){
      selected=await call('__status.findDuplicateGuardMusicGenerationTaskForSession(__session,__query)');
      assert.ok(selected,'ordinary positive duplicate selection');
      result.duplicateResult=plain(await call('__actions.createMusicGenerateDuplicateGuardResult(__session,__query)'));
    }else if(vector.op==='details'){
      selected=tasks[0];
    }else{
      assert.equal(vector.op,'status');
      result.statusResult=plain(await call('__actions.createMusicGenerateStatusActionResult(__session,__agent)'));
    }
    if(selected){
      assert.ok(tasks.includes(selected));this.context.__task=selected;
      result.selectedTask=plain(selected);
      result.details=this.call('__status.buildMusicGenerationTaskStatusDetails(__task)');
      result.text=this.call('__status.buildMusicGenerationTaskStatusText(__task)');
      result.textExplicitFalse=this.call('__status.buildMusicGenerationTaskStatusText(__task,{duplicateGuard:false})');
      result.duplicateText=this.call('__status.buildMusicGenerationTaskStatusText(__task,{duplicateGuard:true})');
    }
    assert.deepEqual(tasks,before);assert.deepEqual(request,vector.request);
    return plain({...vector,result,activityCalls:this.current.activityCalls,tasksAfter:tasks});
  }
}

export async function captureMusicTaskStatus(source=fixedRoot){
  assert.equal(process.versions.node,'24.22.1');assert.equal(realpathSync(process.execPath),realpathSync(fixedNode));
  const root=realpathSync(source);assert.equal(root,fixedRoot);
  const before=checkout(root);assert.equal(before.receipt.verifiedTrackedFiles,58558);
  const harness=new MusicStatusHarness(root,before.tracked);await harness.prepare();
  const observations=[];for(const vector of vectors())observations.push(await harness.run(vector));
  const sourceRecords=[...harness.sourceRecords.values()];
  for(const source of wholeSources)assert.ok(sourceRecords.some(row=>row.path===source&&row.wholeModule));
  for(const source of [...new Set(provenance)]){
    const bytes=readFileSync(join(root,source));assert.equal(hash(bytes),before.tracked.get(source));
    sourceRecords.push({path:source,sha256:hash(bytes),executed:false,provenanceOnly:true});
  }
  const after=checkout(root);assert.deepEqual(after.receipt,before.receipt);
  return plain({schemaVersion:1,referencePin:MUSIC_TASK_STATUS_PIN,
    exporter:{path:'scripts/openclaw/capture-music-task-status.mjs',sha256:hash(readFileSync(fileURLToPath(import.meta.url)))},
    harness:{path:'scripts/openclaw/capture-recipes.mjs',sha256:hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url)))},
    runtime:{executable:fixedNode,version:process.versions.node,sha256:hash(readFileSync(fixedNode)),platform:process.platform},
    sourceTree:{before:before.receipt,after:after.receipt},transformation:transform,
    sourceRecords,importBindings:[...harness.importBindings.values()],dynamicImports:harness.dynamicImports,
    sourceExports:{status:Object.keys(harness.context.__status),actions:Object.keys(harness.context.__actions)},
    scope:{sessionKey,agentId,implementation:'explicit-complete-already-scoped-ordered-snapshot-facade'},
    serviceFacadeLedger:[
      {name:'listMediaGenerationOperations',productionExecuted:false,limit:'Explicit complete same-session/Agent ordered snapshots only; tasks retain same requesterAgentId and session identity facts. Actual Store/registry/capture/pruning/TTL/owner enforcement are not executed.'},
      ...unusedImports.map(([importer,specifier,exports,source,limit])=>({name:specifier,importer,exports,source,productionExecuted:false,limit})),
    ],limits:[
      'Whole unchanged status shared/status/session async details/action helper/music actions/string normalization modules evaluate after TypeScript erasure. Their selected music owner methods and original status/duplicate envelope helpers execute; whole module evaluation does not imply every branch/export executed.',
      'Source activity list is a synthetic explicit complete ordered same-session/Agent snapshot. All selection facts have the same explicit requesterAgentId; ordinary source identity branch executes but does not qualify owner matching or scope enforcement. Host caller-scoped snapshot API does not reproduce the source Agent-key parser or enforce owner scope.',
      'Only queued/running/succeeded and active delivering facts execute. Running-first stable partition, prompt JS trim, active semantic duplicate despite different opaque request key, and last insertion succeeded selection are observed without timestamp sorting.',
      'Raw optional details, exact provider suffix/text and source action status/duplicate envelopes execute, including successful empty status query. No public tool or model dispatch executes.',
      'Request-key values are caller-supplied opaque strings; stableStringify/request-key builder, prompt-context/sanitizer/truncation exports are uninvoked throw-only import seams. No canonical key, key normalization, pruning/lifetime/TTL or bounded prompt-context acceptance claim.',
      'No actual registry/auth/provider/Store/network/filesystem state, owner mismatch/rejected no-match duplicate/failed/blocked/lifecycle/error/permission/security/negative/threshold/race/mixed-domain test; no native activation/background owner/media delivery/whole-reference/P10/goal completion.',
      'All58558 pinned tracked blobs/modes/symlinks verified before/after; LICENSE/full source/import/exporter/shared-harness/fixed-Node receipts reconstruct. No source projections were needed. No host implementation or expectations are imported; no host replay claim.',
    ],observations});
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const args=process.argv.slice(2);assert.equal(args.indexOf('--out'),1);assert.equal(args.length,3);
  const result=await captureMusicTaskStatus(args[0]);writeFileSync(args[2],JSON.stringify(result,null,2)+'\n');
  process.stdout.write(JSON.stringify({output:args[2],vectors:result.observations.length,
    wholeModules:result.sourceRecords.filter(row=>row.executed&&row.wholeModule).length,
    sourceProjections:result.sourceRecords.filter(row=>row.executed&&!row.wholeModule).length,
    trackedBlobs:result.sourceTree.before.verifiedTrackedFiles})+'\n');
}
