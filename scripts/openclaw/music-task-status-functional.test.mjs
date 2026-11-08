// Independent literal music status plans. No host code or captured expectations supply them.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMusicTaskStatus, MUSIC_TASK_STATUS_PIN } from './capture-music-task-status.mjs';

const root='/tmp/openclaw-488631c';
const capture=await captureMusicTaskStatus(root);
const rows=new Map(capture.observations.map(row=>[row.id,row]));
const hash=value=>createHash('sha256').update(value).digest('hex');
const sessionKey='agent:music:session:ordinary',agentId='music';
const fact=(taskId,status='running',extra={})=>({taskId,taskKind:'music_generation',sourceId:'music_generate:google',
  requestKey:'opaque-key',task:'same prompt',status,requesterAgentId:agentId,requesterSessionKey:sessionKey,...extra});
const plans=[
  ['active-running-first-stable','active',fact('r1'),['q1','r1','r2','q2']],
  ['active-queued-stable','active',fact('q1','queued'),['q1','q2']],
  ['active-running-insertion-order','active',fact('r2','running',{updatedAt:1}),['r2','r1']],
  ['active-prompt-js-trim','active',fact('matched','running',{task:'  same prompt\u00a0 '}),['other','matched'],
    {statusTask:fact('other','running',{task:'different prompt'})}],
  ['active-blank-query','active',fact('r1'),['r1']],
  ['active-delivering-completion','active',fact('delivering','running',{progressSummary:'Generated media; delivering completion'}),['q1','delivering']],
  ['active-bare-source','active',fact('bare','running',{sourceId:' music_generate '}),['bare'],{provider:null}],
  ['active-entire-provider-suffix','active',fact('suffix','running',{sourceId:' \uFEFFmusic_generate:  google:preview  \u00a0'}),['suffix'],{provider:'google:preview'}],
  ['active-empty-provider-suffix','active',fact('empty-provider','running',{sourceId:'music_generate: \uFEFF '}),['empty-provider'],{provider:null}],
  ['active-raw-progress','active',fact('progress','running',{progressSummary:'  Verse done!\nnext  ',runId:' run raw '}),['progress']],
  ['duplicate-active-different-key','duplicate',fact('r1','running',{requestKey:'old-r'}),['q1','r1']],
  ['duplicate-active-prompt-trim','duplicate',fact('matched','queued',{task:' same prompt\u00a0 ',requestKey:'previous full key'}),['matched']],
  ['duplicate-recent-last-insertion','duplicate',fact('last','succeeded',{updatedAt:1,task:'recent prompt',progressSummary:'Tracks sent.'}),['first','last']],
  ['duplicate-recent-opaque-key','duplicate',fact('opaque','succeeded',{requestKey:' opaque key\n ',task:'prior prompt'}),['opaque']],
  ['duplicate-recent-with-other-active','duplicate',fact('recent','succeeded'),['other','recent']],
  ['duplicate-recent-last-matching-key','duplicate',fact('last','succeeded'),['first','other-key','last']],
  ['duplicate-recent-bare-source','duplicate',fact('bare-done','succeeded',{sourceId:'music_generate',terminalOutcome:'completed'}),['bare-done'],{provider:null}],
  ['details-running-minimal','details',{taskId:'minimal',status:'running'},[],{provider:null}],
  ['details-queued-optional-empty','details',{taskId:'queued',status:'queued',runId:'',taskKind:'',sourceId:'',progressSummary:''},[],{provider:null}],
  ['details-succeeded','details',fact('done','succeeded',{runId:'run-done',progressSummary:'Music sent.'}),[]],
  ['details-truthy-whitespace','details',fact('raw','queued',{runId:'  ',sourceId:'  ',progressSummary:'  '}),[],{provider:null}],
  ['details-raw-provider-progress','details',fact('raw-suffix','succeeded',{sourceId:' music_generate:  minimax:portal ',progressSummary:'Sent: yes!',runId:' raw run '}),[],{provider:'minimax:portal'}],
  ['status-empty-snapshot','status',null,[]],
];
const endTurn='Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here.';
function expectedDetails(task,provider){
  return {async:true,active:['queued','running'].includes(task.status),existingTask:true,status:task.status,
    task:{taskId:task.taskId,...(task.runId?{runId:task.runId}:{})},
    ...(task.taskKind?{taskKind:task.taskKind}:{}),...(task.progressSummary?{progressSummary:task.progressSummary}:{}),
    ...(task.sourceId?{sourceId:task.sourceId}:{}),...(provider?{provider}:{})};
}
function expectedText(task,provider,duplicate=false){
  const active=task.status==='queued'||task.status==='running';
  const first=`Music generation task ${task.taskId} ${active?'is already':'recently'} ${task.status}${provider?' with '+provider:''}.`;
  const tail=duplicate?(active?'Do not call music_generate again for this request. '+endTurn
    :'Do not call music_generate again for the same request; this recent music generation already completed.'):endTurn;
  return [first,...(task.progressSummary?['Progress: '+task.progressSummary+'.']:[]),tail].join('\n');
}

test('23 literal source plans exercise complete music owner selections and action envelopes',()=>{
  assert.equal(plans.length,23);assert.deepEqual([...rows.keys()],plans.map(row=>row[0]));
  for(const [id,op,task,ids,options={}] of plans){
    const row=rows.get(id);assert.equal(row.op,op,id);
    const provider=Object.hasOwn(options,'provider')?options.provider:'google';
    const expected={};
    if(op==='status'){
      expected.statusResult={content:[{type:'text',text:'No active music generation task is currently running for this session.'}],
        details:{action:'status',active:false}};
    }else{
      const details=expectedDetails(task,provider),text=expectedText(task,provider),duplicateText=expectedText(task,provider,true);
      Object.assign(expected,{selectedTask:task,details,text,textExplicitFalse:text,duplicateText});
      if(op==='active'){
        const statusTask=options.statusTask??task;
        expected.statusResult={content:[{type:'text',text:expectedText(statusTask,provider)}],
          details:{action:'status',...expectedDetails(statusTask,provider)}};
      }else if(op==='duplicate'){
        expected.duplicateResult={content:[{type:'text',text:duplicateText}],details:{action:'status',duplicateGuard:true,...details}};
      }
    }
    assert.deepEqual(row.result,expected,id+' complete result/details/exact text envelope');
    const calls=op==='details'?0:op==='status'?1:2;
    assert.deepEqual(row.activityCalls,Array.from({length:calls},()=>({sessionKey,agentId,returnedTaskIds:ids,
      implementation:'explicit-complete-already-scoped-ordered-snapshot-facade'})),id+' complete ordered scope seam calls');
    assert.deepEqual(row.tasksAfter,row.tasks,id+' snapshot immutable');
  }
});

test('ordinary precedence uses stable running order and exact opaque key without timestamp sorting',()=>{
  assert.equal(rows.get('active-running-first-stable').result.selectedTask.taskId,'r1');
  assert.equal(rows.get('active-running-insertion-order').result.selectedTask.updatedAt,1);
  const active=rows.get('duplicate-active-different-key');
  assert.equal(active.request.requestKey,'new full key');assert.equal(active.result.selectedTask.requestKey,'old-r');
  assert.equal(rows.get('duplicate-recent-last-insertion').tasks[0].updatedAt,999999);
  assert.equal(rows.get('duplicate-recent-last-insertion').result.selectedTask.updatedAt,1);
  assert.equal(rows.get('duplicate-recent-opaque-key').request.requestKey,' opaque key\n ');
  assert.equal(rows.get('duplicate-recent-opaque-key').result.selectedTask.requestKey,' opaque key\n ');
  assert.equal(rows.get('active-delivering-completion').result.selectedTask.taskId,'delivering');
});

test('raw optional details and provider suffix have independent exact literal goldens',()=>{
  assert.deepEqual(rows.get('details-queued-optional-empty').result.details,
    {async:true,active:true,existingTask:true,status:'queued',task:{taskId:'queued'}});
  assert.deepEqual(rows.get('details-truthy-whitespace').result.details,
    {async:true,active:true,existingTask:true,status:'queued',task:{taskId:'raw',runId:'  '},
      taskKind:'music_generation',progressSummary:'  ',sourceId:'  '});
  assert.equal(rows.get('active-entire-provider-suffix').result.text,
    'Music generation task suffix is already running with google:preview.\n'+endTurn);
  assert.equal(rows.get('active-raw-progress').result.text,
    'Music generation task progress is already running with google.\nProgress:   Verse done!\nnext  .\n'+endTurn);
  assert.equal(rows.get('details-raw-provider-progress').result.duplicateText,
    'Music generation task raw-suffix recently succeeded with minimax:portal.\nProgress: Sent: yes!.\nDo not call music_generate again for the same request; this recent music generation already completed.');
  assert.deepEqual(rows.get('status-empty-snapshot').result,
    {statusResult:{content:[{type:'text',text:'No active music generation task is currently running for this session.'}],details:{action:'status',active:false}}});
});

test('all snapshot selection facts are already in one explicit successful scope',()=>{
  for(const row of rows.values()){
    if(row.op==='details')continue;
    assert.ok(row.tasks.every(task=>task.requesterAgentId==='music'&&task.requesterSessionKey===sessionKey));
    assert.ok(row.tasks.every(task=>['queued','running','succeeded'].includes(task.status)));
    assert.ok(row.tasks.every(task=>task.terminalOutcome!=='blocked'));
  }
  for(const name of ['findActiveMusicGenerationTaskForSession','findDuplicateGuardMusicGenerationTaskForSession',
    'buildMusicGenerationTaskStatusDetails','buildMusicGenerationTaskStatusText'])assert.ok(capture.sourceExports.status.includes(name));
  for(const name of ['createMusicGenerateStatusActionResult','createMusicGenerateDuplicateGuardResult'])
    assert.ok(capture.sourceExports.actions.includes(name));
  assert.ok(capture.serviceFacadeLedger.every(row=>row.productionExecuted===false&&row.limit.length>35));
});

test('six unchanged complete modules and explicit import/LICENSE/runtime receipts reconstruct',()=>{
  assert.equal(MUSIC_TASK_STATUS_PIN,'488631c18fae7cc541ba8fc8beff6cbb0438787b');assert.equal(capture.referencePin,MUSIC_TASK_STATUS_PIN);
  assert.deepEqual(capture.sourceTree.before,capture.sourceTree.after);assert.equal(capture.sourceTree.before.verifiedTrackedFiles,58558);
  assert.equal(capture.sourceTree.before.verified,true);
  const whole=['src/agents/media-generation-task-status-shared.ts','src/agents/media-generation-task-status.ts',
    'src/agents/session-async-task-status.ts','src/agents/tools/media-generate-tool-actions-shared.ts',
    'src/agents/tools/music-generate-tool.actions.ts','packages/normalization-core/src/string-coerce.ts'];
  assert.deepEqual(capture.sourceRecords.filter(row=>row.executed).map(row=>row.path).sort(),whole.sort());
  assert.ok(capture.sourceRecords.some(row=>row.path==='LICENSE'&&row.provenanceOnly));
  for(const row of capture.sourceRecords){
    const bytes=readFileSync(join(root,row.path));assert.equal(row.sha256,hash(bytes),row.path);
    if(!row.executed){assert.equal(row.provenanceOnly,true);continue;}
    assert.equal(row.wholeModule,true);assert.equal(row.transformation,'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)');
    assert.equal(row.executableSha256,hash(stripTypeScriptTypes(bytes.toString(),{mode:'transform',sourceMap:false})));
    assert.equal(Object.hasOwn(row,'projection'),false);
  }
  for(const binding of capture.importBindings){
    if(binding.generatedCode)assert.equal(binding.generatedSha256,hash(binding.generatedCode));
    if(binding.source)assert.equal(binding.sourceSha256,hash(readFileSync(join(root,binding.source))));
    if(binding.kind==='uninvoked-import-facade')assert.ok(binding.limit.length>35);
  }
  assert.deepEqual(capture.dynamicImports,[]);
  assert.equal(capture.runtime.version,'24.22.1');assert.equal(capture.runtime.sha256,hash(readFileSync(capture.runtime.executable)));
  assert.equal(capture.exporter.sha256,hash(readFileSync(new URL('./capture-music-task-status.mjs',import.meta.url))));
  assert.equal(capture.harness.sha256,hash(readFileSync(new URL('./capture-recipes.mjs',import.meta.url))));
});

test('second independent capture stays plain/deterministic and matches saved CLI fixture',async()=>{
  assert.deepEqual(await captureMusicTaskStatus(root),capture);
  assert.deepEqual(JSON.parse(JSON.stringify(capture)),capture);
  const fixture=JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/music-task-status.json',import.meta.url)));
  assert.deepEqual(fixture,capture);
});
