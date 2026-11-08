import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { inflateSync } from 'node:zlib';
import { createInterface } from 'node:readline';
import { createEngine } from 'clawpdf';
import { extractPdfContent } from '../src/pdf/extract.mjs';

const capsule = process.env.SYNAPSIS_DIFFS_CAPSULE;
const reference = process.env.SYNAPSIS_DIFFS_REFERENCE;
const chromiumExecutable = process.env.SYNAPSIS_DIFFS_CHROMIUM;
const stagingRoot = process.env.SYNAPSIS_DIFFS_STAGING;
assert.ok(capsule && reference && chromiumExecutable && stagingRoot, 'Explicit capsule/reference/browser/staging required');
const { DiffsRenderer } = await import(pathToFileURL(join(capsule, 'renderer.mjs')));
const product = await import(pathToFileURL(join(capsule, 'packages/tool-host/src/diffs/openclaw/extensions/diffs/src/render.js')));
const oracle = await import(pathToFileURL(reference));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const defaults = {fontFamily:'Fira Code',fontSize:15,lineSpacing:1.6,layout:'unified',showLineNumbers:true,diffIndicators:'bars',wordWrap:true,background:true,theme:'dark',fileFormat:'png',fileQuality:'standard',fileScale:2,fileMaxWidth:960,mode:'both',ttlSeconds:1800};
const a = {input:{kind:'before_after',before:'const value = 1;\n',after:'const value = 2;\n',path:'src/value.ts',lang:'TS',title:'Value update'},options:{presentation:defaults,image:{format:'png',qualityPreset:'standard',scale:2,maxWidth:960,maxPixels:8000000},expandUnchanged:false,languagePackAvailable:false},renderTarget:'both',mode:'both',ttlMs:1800000};
const patch = ['diff --git a/a.ts b/a.ts','--- a/a.ts','+++ b/a.ts','@@ -1,2 +1,3 @@','-const a = 1;','+const a = 2;','+const extra = true;',' const keep = 0;','diff --git a/b.ts b/b.ts','--- a/b.ts','+++ b/b.ts','@@ -1 +1 @@','-const b = 1;','+const b = 2;'].join('\n');
const b = {...a,input:{kind:'patch',patch,title:'Workspace patch'},options:{...a.options,presentation:{...defaults,layout:'split',theme:'light'},image:{...a.options.image,format:'pdf'},expandUnchanged:true}};
function identity(pid) { return readFile(`/proc/${pid}/stat`, 'utf8').then(raw => raw.slice(raw.lastIndexOf(')') + 2).split(' ')[19]); }
async function gone(pid, original) { assert.equal(await identity(pid).catch(()=>null) === original, false); }
function png(bytes) {
  assert.deepEqual(bytes.subarray(0,8),Buffer.from([137,80,78,71,13,10,26,10]));
  const width=bytes.readUInt32BE(16),height=bytes.readUInt32BE(20),channels=bytes[25]===2?3:4;
  assert.equal(bytes[24],8);assert.ok([2,6].includes(bytes[25]));
  const idat=[];for(let at=8;at<bytes.length;){const n=bytes.readUInt32BE(at);if(bytes.toString('ascii',at+4,at+8)==='IDAT')idat.push(bytes.subarray(at+8,at+8+n));at+=n+12;}
  const raw=inflateSync(Buffer.concat(idat)),stride=width*channels,pixels=Buffer.alloc(stride*height);assert.equal(raw.length,(stride+1)*height);
  for(let y=0;y<height;y++)for(let x=0;x<stride;x++){
    const at=y*stride+x,left=x>=channels?pixels[at-channels]:0,up=y?pixels[at-stride]:0,ul=y&&x>=channels?pixels[at-stride-channels]:0;
    const p=left+up-ul,d=[Math.abs(p-left),Math.abs(p-up),Math.abs(p-ul)],paeth=d[0]<=d[1]&&d[0]<=d[2]?left:d[1]<=d[2]?up:ul;
    const filter=raw[y*(stride+1)];assert.ok(filter<=4);pixels[at]=(raw[y*(stride+1)+1+x]+[0,left,up,Math.floor((left+up)/2),paeth][filter])&255;
  }
  const colors=new Set();for(let at=0;at<pixels.length;at+=channels)colors.add(pixels.subarray(at,at+3).toString('hex'));
  assert.ok(colors.size>30,'real highlighted content');return {width,height,colors:colors.size};
}
async function artifacts(receipt, staging) {
  const result={};for(const [key,item] of Object.entries(receipt.artifacts)){
    const bytes=await readFile(join(staging,item.path));assert.equal(bytes.length,item.bytes);assert.equal(sha(bytes),item.sha256);result[key]=bytes;
  }return result;
}
async function dom(page) {
  return page.evaluate(()=>[...document.querySelectorAll('diffs-container')].map(host=>{
    const pre=host.shadowRoot.querySelector('pre[data-diff]'),code=pre.querySelector('code[data-code]');
    const row=pre.querySelector('[data-content] > [data-line-type="change-addition"]');
    const theme=host.shadowRoot.querySelector('style[data-theme-css]');
    return {dehydrated:pre.hasAttribute('data-dehydrated'),layout:pre.getAttribute('data-diff-type'),overflow:pre.getAttribute('data-overflow'),background:pre.hasAttribute('data-background'),indicators:pre.getAttribute('data-indicators'),lineNumbers:!pre.hasAttribute('data-disable-line-numbers'),font:getComputedStyle(code).fontSize,lineHeight:getComputedStyle(row).lineHeight,whiteSpace:getComputedStyle(row).whiteSpace,color:getComputedStyle(row).color,backgroundColor:getComputedStyle(row).backgroundColor,scheme:getComputedStyle(host).colorScheme,theme:theme.textContent,toolbar:host.querySelectorAll('button.oc-diff-toolbar-button').length,rows:[...pre.querySelectorAll('code[data-code] > [data-content] > [data-line]')].map(r=>r.textContent.trimEnd()),columns:[...pre.querySelectorAll(':scope > code[data-code]')].map(c=>({unified:c.hasAttribute('data-unified'),deletions:c.hasAttribute('data-deletions'),additions:c.hasAttribute('data-additions'),x:c.querySelector('[data-content]').getBoundingClientRect().x}))};
  }));
}

test('actual pinned SSR matches an independently materialized original and source target/title matrix',async()=>{
  const withoutTitle={...a.input};delete withoutTitle.title;
  const plain={kind:'before_after',before:a.input.before,after:a.input.after};
  const solo={kind:'patch',patch:'diff --git a/solo.ts b/solo.ts\n--- a/solo.ts\n+++ b/solo.ts\n@@ -1 +1 @@\n-const x = 1;\n+const x = 2;'};
  for(const [input,options,target,title,count] of [[a.input,a.options,'both','Value update',1],[withoutTitle,a.options,'viewer','src/value.ts',1],[plain,a.options,'image','Text diff',1],[solo,a.options,'viewer','Patch diff',1],[b.input,b.options,'both','Workspace patch',2]]){
    const actual=await product.renderDiffDocument(input,options,target),expected=await oracle.renderDiffDocument(input,options,target);
    assert.deepEqual(actual,expected);assert.equal(actual.title,title);assert.equal(actual.fileCount,count);
    assert.equal(Object.hasOwn(actual,'html'),target!=='image');assert.equal(Object.hasOwn(actual,'imageHtml'),target!=='viewer');
    for(const key of ['html','imageHtml'])if(actual[key]){
      assert.match(actual[key],/pre[^>]*data-diff/);assert.match(actual[key],/data-dehydrated/);assert.match(actual[key],/shadowrootmode="open"/);
      assert.match(actual[key],/data-openclaw-diff-payload/);assert.ok(actual[key].length>10000);
    }
  }
});

for(const [caseName,plans] of [['before_after',[a]],['partial_patch',[b]]]) test(`${caseName}: relocated capsule hydrates controls, produces PNG/PDF and observes Chromium close`, {timeout:120000},async t=>{
  const renderer=new DiffsRenderer({chromiumExecutable,stagingRoot});
  t.after(()=>renderer.close());
  const ready=await renderer.initialize();
  const manifest=JSON.parse(await readFile(join(capsule,'capsule.json')));
  assert.equal(ready.reference,'488631c18fae7cc541ba8fc8beff6cbb0438787b');assert.equal(ready.languagePackAvailable,false);
  assert.deepEqual(ready.assets,manifest.assets);
  for(const [path,pkg] of Object.entries(manifest.packages))assert.deepEqual(JSON.parse(await readFile(join(capsule,path,'package.json'))).version,pkg.version);
  const resolved=JSON.parse(execFileSync(process.execPath,['--input-type=module','-e',"console.log(JSON.stringify(['@pierre/diffs','shiki','playwright-core'].map(n=>import.meta.resolve(n))))"],{cwd:join(capsule,'packages/tool-host'),encoding:'utf8'}));
  for(const path of resolved)assert.ok(path.startsWith(pathToFileURL(capsule+'/').href));
  let browserPid,browserIdentity;
  const receipts=[],observations=[];
  try{
    for(const plan of plans){
      const document=await product.renderDiffDocument(plan.input,plan.options,'both');
      const page=await renderer.openPage(document.html,plan.options,30000);
      try{
        const errors=[];page.on('pageerror',e=>errors.push(e.message));
        const initial=await dom(page);observations.push({kind:'viewer',initial,assets:await page.evaluate(()=>performance.getEntriesByType('resource').map(r=>r.name))});assert.equal(initial.length,plan===a?1:2);
        for(const state of initial){assert.equal(state.dehydrated,false);assert.equal(state.toolbar,4);assert.equal(state.font,'15px');assert.equal(state.lineHeight,'24px');assert.equal(state.overflow,'wrap');assert.equal(state.background,true);assert.equal(state.indicators,'bars');assert.equal(state.lineNumbers,true);assert.ok(state.rows.length>=2);}
        assert.ok(initial[0].rows.includes(plan===a?'const value = 2;':'const a = 2;'));
        const operations=[['layout',plan===a?'Switch to split diff':'Switch to unified diff'],['wrap','Disable word wrap'],['background','Hide background highlights'],['theme',plan===a?'Switch to light theme':'Switch to dark theme']];
        for(const [kind,label] of operations){
          const before=await dom(page);await page.locator('diffs-container').first().getByRole('button',{name:label,exact:true}).click();
          const after=await dom(page);observations.push({kind,after});
          for(let i=0;i<after.length;i++){
            if(kind==='layout'){assert.equal(after[i].layout,before[i].layout==='single'?'split':'single');assert.equal(after[i].columns.length,after[i].layout==='split'?2:1);if(after[i].columns.length===2)assert.ok(after[i].columns[0].x<after[i].columns[1].x);}
            if(kind==='wrap'){assert.equal(after[i].overflow,'scroll');assert.equal(after[i].whiteSpace,'pre');}
            if(kind==='background'){assert.equal(after[i].background,false);assert.notEqual(after[i].backgroundColor,before[i].backgroundColor);}
            if(kind==='theme'){assert.notEqual(after[i].scheme,before[i].scheme);assert.notEqual(after[i].color,before[i].color);assert.ok(after[i].theme.includes(`color-scheme: ${after[i].scheme};`));}
          }
        }
        assert.deepEqual(errors,[]);
      }finally{await renderer.closePage(page);}
      const imagePage=await renderer.openPage(document.imageHtml,plan.options,30000);
      let frame;
      try{for(const state of await dom(imagePage)){assert.equal(state.toolbar,0);assert.equal(state.font,'16px');assert.equal(state.lineHeight,'26px');assert.equal(state.dehydrated,false);}frame=await imagePage.locator('.oc-frame').boundingBox();}finally{await renderer.closePage(imagePage);}
      for(const format of ['png','pdf']){
        const current={...plan,options:{...plan.options,image:{...plan.options.image,format}}};
        const receipt=await renderer.render(current,30000);receipts.push(receipt);const bytes=await artifacts(receipt,stagingRoot);
        assert.equal(bytes.html.toString(),document.html);assert.equal(bytes.imageHtml.toString(),document.imageHtml);
        if(format==='png'){
          const decoded=png(bytes.file);assert.equal(decoded.width,Math.ceil(frame.width+40)*2);assert.equal(decoded.height,Math.ceil(Math.max(frame.height+40,320))*2);
          if(plan===a)assert.deepEqual([decoded.width,decoded.height],[2000,640]);
        }else{
          const extracted=await extractPdfContent({buffer:bytes.file,minTextChars:1});
          // PDFium emits separate text runs around highlighted tokens, including punctuation.
          // Compare source fragments after removing only whitespace; retain all code characters.
          const text=extracted.text.replace(/\s+/g,'');
          for(const literal of plan===a?['src/value.ts','const value = 1;','const value = 2;']:['a.ts','b.ts','const a = 1;','const a = 2;','const extra = true;','const keep = 0;','const b = 1;','const b = 2;'])assert.ok(text.includes(literal.replace(/\s+/g,'')),literal);
          const engine=await createEngine();let pdf;
          try{pdf=await engine.open(bytes.file);assert.equal(pdf.pageCount,1);const page=pdf.page(1);assert.ok(Math.abs(page.width-Math.ceil(frame.width)*0.75)<1);assert.ok(Math.abs(page.height-Math.ceil(frame.height)*0.75)<1);}finally{await pdf?.destroy();await engine.destroy();}
        }
        browserPid??=renderer.browserPid;assert.equal(renderer.browserPid,browserPid);browserIdentity??=await identity(browserPid);assert.equal(await identity(browserPid),browserIdentity);assert.equal(renderer.pages.size,0);
      }
    }
  }finally{
    const exit=await renderer.close();assert.equal(exit.workerClosed,true);if(browserPid){assert.deepEqual(exit.browserExit,{pid:browserPid,code:0,signal:null});await gone(browserPid,browserIdentity);}
  }
  for(const receipt of receipts)await artifacts(receipt,stagingRoot);
  await writeFile(join(stagingRoot,'receipts.json'),JSON.stringify(receipts,null,2));
  await writeFile(join(stagingRoot,caseName+'-observations.json'),JSON.stringify({browserPid,browserIdentity,closed:await renderer.close(),observations},null,2));
});

for(const [caseName,plans] of [['before_after',[a,{...a,options:{...a.options,image:{...a.options.image,format:'pdf'}}}]],['partial_patch',[a,b]]]) test(`${caseName}: actual NDJSON helper retains identity and observes normal close`, {timeout:90000},async()=>{
  const staging=join(stagingRoot,'ipc-'+caseName);await mkdir(staging,{recursive:true});
  const child=spawn(process.execPath,[join(capsule,'stdio.mjs'),'--chromium',chromiumExecutable,'--staging',staging],{cwd:staging,stdio:['pipe','pipe','pipe']});
  let stdinError;child.stdin.on('error',error=>{stdinError=error;});
  const exit=new Promise(resolve=>child.once('close',(code,signal)=>resolve({code,signal})));
  const lines=createInterface({input:child.stdout})[Symbol.asyncIterator]();
  let stderr='';child.stderr.on('data',b=>stderr+=b);
  const next=async()=>{const line=await lines.next();assert.equal(line.done,false,stderr);return JSON.parse(line.value);};
  const nodeIdentity=await identity(child.pid);let browserPid,browserIdentity;
  let completed=false;
  try{
    const ready=await next();assert.equal(ready.type,'ready');assert.equal(ready.version,1);
    for(const [i,plan]of plans.entries()){
      child.stdin.write(JSON.stringify({type:'request',timeoutMs:30000,id:i+1,plan})+'\n');
      const result=await next();assert.equal(result.type,'result');assert.equal(result.receipt.id,i+1);await artifacts(result.receipt,staging);
      browserPid??=result.browserPid;assert.equal(result.browserPid,browserPid);browserIdentity??=await identity(browserPid);assert.equal(await identity(browserPid),browserIdentity);
      assert.equal(await identity(child.pid),nodeIdentity);
    }
    completed=true;
  }finally{
    if(!completed){child.stdin.write('{"type":"close"}\n');await exit;}else{

    child.stdin.write('{"type":"close"}\n');const closed=await next();assert.equal(closed.type,'closed');assert.equal(closed.workerClosed,true);assert.deepEqual(closed.browserExit,{pid:browserPid,code:0,signal:null});
    const nodeExit=await exit;assert.deepEqual(nodeExit,{code:0,signal:null});assert.equal(stdinError,undefined);await gone(child.pid,nodeIdentity);await gone(browserPid,browserIdentity);
    await writeFile(join(staging,'lifecycle.json'),JSON.stringify({nodePid:child.pid,nodeIdentity,browserPid,browserIdentity,nodeExit,closed},null,2));
    }
  }
});
