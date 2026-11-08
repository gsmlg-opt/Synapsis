// Source-derived ordinary expectations frozen before oracle implementation/execution.
// Exact changed receipts are frozen in the genuine-source report, never invented here.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureEditPlans } from './capture-edit-plans.mjs';

const root=process.env.OPENCLAW_REFERENCE_ROOT??'/tmp/openclaw-488631c';
const diffRoot=process.env.OPENCLAW_DIFF_ROOT;
assert.ok(diffRoot,'Provide the verified lock-pinned diff9 package root');
const report=await captureEditPlans(root,diffRoot);
const fixture=JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/edit-plans.json',import.meta.url),'utf8'));
const sha=v=>createHash('sha256').update(v).digest('hex');
const expected={
  'original-snapshot':{changed:true,content:'beta\nBETA\ngamma\n',editCount:2},
  'reversed-request':{changed:true,content:'beta\nBETA\ngamma\n',editCount:2},
  'unicode-utf16':{changed:true,content:'😀 鍵\ncafé tail\n',editCount:2},
  'identical-noop':{changed:false,message:'No changes made to edit.txt. The replacement text is identical to the original.'},
  'normalized-noop':{changed:false,message:'No changes made to edit.txt. The replacement produced identical content.'},
  'bom-crlf':{changed:true,content:'\uFEFFA\r\nB\r\nC\r\ngamma\r\n',editCount:1},
  'line-ending-style':{changed:true,content:'\uFEFFone\r\nTWO\nTHREE\rPLUS\rfour\r\n',editCount:1},
  'fuzzy-preserves-untouched':{changed:true,content:'😀 office = "new"  \nkeep ﬁ + e\u0301\n',editCount:1},
};

test('whole original edit planner matches all independent content and no-op literals',()=>{
 assert.equal(report.reference.commit,'488631c18fae7cc541ba8fc8beff6cbb0438787b');
 const edits=report.cases.filter(x=>x.kind==='edit');assert.equal(edits.length,8);
 assert.deepEqual(edits.map(x=>x.id).sort(),Object.keys(expected).sort());
 for(const row of edits){
  const {receipt,...fields}=row.result;assert.deepEqual(fields,expected[row.id],row.id);
  if(fields.changed){assert.equal(typeof receipt.diff,'string');assert.equal(typeof receipt.patch,'string');assert.equal(typeof receipt.firstChangedLine,'number');}
 }
 assert.deepEqual(edits[0].result,edits[1].result);
});

test('write receipts come from the real planner without fabricated effect envelopes',()=>{
 const writes=report.cases.filter(x=>x.kind==='write');assert.equal(writes.length,2);
 assert.deepEqual(writes.map(x=>x.id),['write-create','write-overwrite']);
 for(const row of writes){assert.deepEqual(Object.keys(row.result).sort(),['diff','firstChangedLine','patch']);assert.equal(typeof row.result.patch,'string');assert.equal(row.result.firstChangedLine,1);}
 assert.deepEqual(writes[0].input,{path:'write.txt',content:'new\n',created:true});
 assert.deepEqual(writes[1].input,{path:'write.txt',content:'new\n',beforeText:'old\n',created:false});
});

test('whole-source graph, actual pinned dependency and complete executables retain provenance',()=>{
 const prov=report.provenance;assert.equal(prov.sources.length,27); //23 TS+LICENSE+tsconfig+package+lock
 for(const source of prov.sources){assert.equal(sha(source.content),source.sha256,source.path);assert.equal(source.content,readFileSync(root+'/'+source.path,'utf8'),source.path);}
 assert.equal(prov.transforms.length,23);
 for(const row of prov.transforms)assert.equal(sha(row.executable),row.executableSha256,row.path);
 assert.equal(prov.dependency.name,'diff');assert.equal(prov.dependency.version,'9.0.0');
 assert.equal(prov.dependency.integrity,'sha512-svtcdpS8CgJyqAjEQIXdb3OjhFVVYjzGAPO8WGCmRbrml64SPw/jJD4GoE98aR7r25A0XcgrK3F02yw9R/vhQw==');
 assert.ok(prov.dependency.files.some(x=>x.path==='LICENSE'));
 for(const file of prov.dependency.files){assert.equal(sha(Buffer.from(file.base64,'base64')),file.sha256,file.path);assert.deepEqual(Buffer.from(file.base64,'base64'),readFileSync(diffRoot+'/'+file.path),file.path);}
 assert.equal(prov.aliases['@openclaw/normalization-core'],'packages/normalization-core/src/index.ts');
 assert.equal(prov.aliases['@openclaw/normalization-core/utf16-slice'],'packages/normalization-core/src/utf16-slice.ts');
 assert.equal(prov.harness.sha256,sha(readFileSync(new URL('./capture-edit-plans.mjs',import.meta.url))));
});

test('all changed receipts and provenance match the genuine frozen report',()=>assert.deepEqual(report,fixture));
