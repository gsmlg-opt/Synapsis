// Literal expectations independently derived from pinned read-page.ts before capture/product edits.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { captureReadPages } from './capture-read-pages.mjs';

const root = process.env.OPENCLAW_REFERENCE_ROOT ?? '/tmp/openclaw-488631c';
const report = await captureReadPages(root);
const fixture = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/read-pages.json', import.meta.url), 'utf8'));
const expected = {
  'normalized-eof': {text:'alpha\nbeta\ngamma\n', details:{kind:'text',content:'alpha\nbeta\ngamma\n'}},
  'one-based-slice': {text:'beta\n\n[1 more line in file. Use offset=3 to continue.]',details:{kind:'truncated',content:'beta',continuation:{kind:'line',offset:3,limit:1},truncation:{truncated:true,truncatedBy:'lines',totalLines:3,totalBytes:4,outputLines:1,outputBytes:4,lastLinePartial:false,firstLineExceedsLimit:false,maxLines:1,maxBytes:51200}}},
  'continuation-eof': {text:'gamma\n',details:{kind:'text',content:'gamma\n'}},
  'plural-slice': {text:'one\ntwo\n\n[2 more lines in file. Use offset=3 to continue.]',details:{kind:'truncated',content:'one\ntwo',continuation:{kind:'line',offset:3,limit:2},truncation:{truncated:true,truncatedBy:'lines',totalLines:4,totalBytes:7,outputLines:2,outputBytes:7,lastLinePartial:false,firstLineExceedsLimit:false,maxLines:2,maxBytes:51200}}},
  'utf16-selected-slice': {text:'中B\n\n[1 more line in file. Use offset=2 to continue.]',details:{kind:'truncated',content:'中B',continuation:{kind:'line',offset:2,limit:1},truncation:{truncated:true,truncatedBy:'lines',totalLines:2,totalBytes:4,outputLines:1,outputBytes:4,lastLinePartial:false,firstLineExceedsLimit:false,maxLines:1,maxBytes:51200}}},
  'unicode-eof': {text:'😀中B\n尾\n',details:{kind:'text',content:'😀中B\n尾\n'}},
  'preserved-cr-bom': {text:'one\rtwo\n\uFEFFthree\n',details:{kind:'text',content:'one\rtwo\n\uFEFFthree\n'}},
  'blank-raw-page': {text:'\n\n',details:{kind:'text',content:'\n\n'}},
};

test('complete pinned page helper matches every independent ordinary literal', () => {
  assert.equal(report.reference.commit, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(report.cases.length, 8);
  assert.deepEqual(report.cases.map(x=>x.id).sort(),Object.keys(expected).sort());
  for (const row of report.cases) assert.deepEqual(row.result,expected[row.id],row.id);
});

test('complete original graph retains sources, license, aliases, real natives and transforms', () => {
  const sources = report.provenance.sources;
  assert.equal(sources.length, 11); // nine full TS modules, original tsconfig and root LICENSE
  for (const row of sources) {
    assert.equal(createHash('sha256').update(row.content).digest('hex'),row.sha256,row.path);
    assert.equal(row.content, readFileSync(root+'/'+row.path,'utf8'), row.path);
  }
  assert.equal(report.provenance.transforms.length,9);
  for (const row of report.provenance.transforms) {
    assert.equal(createHash('sha256').update(row.executable).digest('hex'),row.executableSha256,row.path);
  }
  assert.deepEqual(report.provenance.nativeImports.sort(),['node:async_hooks','node:buffer']);
  assert.deepEqual(report.provenance.aliases,{
    '@openclaw/normalization-core/cjk-chars':'packages/normalization-core/src/cjk-chars.ts',
    '@openclaw/normalization-core/utf16-slice':'packages/normalization-core/src/utf16-slice.ts'
  });
  assert.match(sources.find(x=>x.path==='LICENSE').content,/MIT License/);
  assert.equal(report.provenance.harness.sha256,createHash('sha256').update(readFileSync(new URL('./capture-read-pages.mjs',import.meta.url))).digest('hex'));
});

test('fresh full report matches frozen capture without dropping provenance',()=>assert.deepEqual(report,fixture));
