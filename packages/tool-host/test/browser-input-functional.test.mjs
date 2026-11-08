import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserHost } from '../src/browser/host.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'synapsis-input-functional-'));
  const server = createServer((_request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><title>Input phases</title>
      <style>button,input{display:block;width:240px;height:50px;margin:24px}</style>
      <button id="pointer">Pointer</button><button id="other">Other</button>
      <form id="form"><label>Text<input id="text" value="seed"></label></form>
      <script>
        window.events = []; window.submits = 0;
        for (const type of ['pointerover','mousedown','mouseup','click','dblclick','contextmenu','keydown','keyup','input']) {
          document.addEventListener(type, event => {
            events.push({type, id:event.target.id, at:performance.now(), key:event.key,
              button:event.button, detail:event.detail, shift:event.shiftKey, ctrl:event.ctrlKey,
              meta:event.metaKey, alt:event.altKey, value:event.target.value});
            if (type === 'contextmenu' || (type === 'keydown' && (event.ctrlKey || event.metaKey))) event.preventDefault();
          });
        }
        text.addEventListener('click', () => text.setSelectionRange(2, 2));
        form.addEventListener('submit', event => { event.preventDefault(); window.submits++; });
      </script>`);
  });
  const host = new BrowserHost({ profile: 'functional', executable: process.env.SYNAPSIS_TEST_CHROMIUM ?? '/run/current-system/sw/bin/chromium', data_dir: directory, project_root: directory, timeout_ms: 15000, max_image_bytes: 196608 });
  t.after(async () => {
    const pid = host.diagnosticPid;
    try {
      assert.equal((await host.close()).cleanup_confirmed, true);
      if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally {
      try {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const call = (action, args = {}) => host.invoke(action, args, { generation: host.generation, timeoutMs: 15000 });
  await call('start');
  const { targetId } = await call('open', { targetUrl: `http://127.0.0.1:${server.address().port}` });
  const act = request => call('act', { targetId, request });
  const evaluate = async fn => (await act({ kind: 'evaluate', fn })).value;
  const snapshot = await call('snapshot', { targetId, interactive: true });
  const ref = name => snapshot.refs.find(item => item.name === name).ref;
  return { act, evaluate, ref };
}

test('element click hovers before its delay and double click emits both clicks', { timeout: 60000 }, async t => {
  const { act, evaluate, ref } = await fixture(t);
  await act({ kind: 'click', ref: ref('Pointer'), delayMs: 180, modifiers: ['Shift'] });
  let events = await evaluate('() => window.events.filter(e => e.id === "pointer")');
  const over = events.find(e => e.type === 'pointerover');
  const down = events.find(e => e.type === 'mousedown');
  assert.ok(down.at - over.at >= 160, JSON.stringify(events));
  assert.equal(down.shift, true);
  await act({ kind: 'hover', selector: '#other' });
  await evaluate('() => { window.events = []; }');
  await act({ kind: 'click', selector: '#pointer', doubleClick: true, delayMs: 100, modifiers: ['Alt'] });
  events = await evaluate('() => window.events.filter(e => e.id === "pointer")');
  assert.deepEqual(events.filter(e => ['mousedown','mouseup','click','dblclick'].includes(e.type)).map(e => [e.type, e.detail]),
    [['mousedown',1],['mouseup',1],['click',1],['mousedown',2],['mouseup',2],['click',2],['dblclick',2]]);
  assert.ok(events.find(e => e.type === 'mousedown').at - events.find(e => e.type === 'pointerover').at >= 80);
  assert.ok(events.filter(e => e.type === 'click').every(e => e.alt));
  await act({ kind: 'click', selector: '#other', button: 'right', modifiers: ['Control'] });
  const right = await evaluate('() => window.events.find(e => e.id === "other" && e.type === "mousedown")');
  assert.equal(right.button, 2);
  assert.equal(right.ctrl, true);
});

test('coordinate click holds the mouse button for its delay', { timeout: 60000 }, async t => {
  const { act, evaluate } = await fixture(t);
  const point = await evaluate('() => { const r = pointer.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; }');
  await act({ kind: 'clickCoords', ...point, button: 'middle', delayMs: 160 });
  const events = await evaluate('() => window.events.filter(e => e.id === "pointer")');
  const down = events.find(e => e.type === 'mousedown');
  const up = events.find(e => e.type === 'mouseup');
  assert.equal(down.button, 1);
  assert.ok(up.at - down.at >= 140, JSON.stringify(events));
});

test('targetless, selector and ref presses hold keys and normalize ordinary aliases and plus', { timeout: 60000 }, async t => {
  const { act, evaluate, ref } = await fixture(t);
  await act({ kind: 'click', selector: '#text' });
  for (const target of [{}, { selector: '#text' }, { ref: ref('Text') }]) {
    await evaluate('() => { window.events = []; }');
    await act({ kind: 'press', ...target, key: 'ArrowRight', delayMs: 130 });
    const events = await evaluate('() => window.events.filter(e => e.key === "ArrowRight")');
    assert.deepEqual(events.map(e => e.type), ['keydown', 'keyup']);
    assert.ok(events[1].at - events[0].at >= 110, JSON.stringify(events));
  }
  await act({ kind: 'type', selector: '#text', text: '' });
  await evaluate('() => { window.events = []; }');
  for (const key of ['Esc','Return','Del','Ctrl+Home','Cmd+Home','space',' ',' + ','+ ','Shift++','Ctrl++','Ctrl+Space']) {
    await act({ kind: 'press', key });
  }
  const events = await evaluate('() => window.events.filter(e => e.type === "keydown")');
  assert.deepEqual(events.filter(e => !['Control','Meta','Shift'].includes(e.key)).map(e => e.key),
    ['Escape','Enter','Delete','Home','Home',' ',' ','+','+','+','+',' ']);
  assert.ok(events.some(e => e.key === 'Home' && e.ctrl));
  assert.ok(events.some(e => e.key === 'Home' && e.meta));
  assert.ok(events.some(e => e.key === '+' && e.shift));
  assert.ok(events.some(e => e.key === '+' && e.ctrl));
  assert.equal(await evaluate('() => text.value'), '  +++');
});

test('slow typing clicks and preserves existing text at the resulting caret with default and explicit delays', { timeout: 60000 }, async t => {
  const { act, evaluate, ref } = await fixture(t);
  await act({ kind: 'type', ref: ref('Text'), text: 'abc', slowly: true, submit: true });
  assert.equal(await evaluate('() => text.value'), 'seabced');
  assert.equal(await evaluate('() => window.submits'), 1);
  let events = await evaluate('() => window.events.filter(e => e.id === "text")');
  assert.ok(events.findIndex(e => e.type === 'click') < events.findIndex(e => e.type === 'keydown'));
  let inputs = events.filter(e => e.type === 'input');
  assert.deepEqual(inputs.map(e => e.value), ['seaed','seabed','seabced']);
  for (let i = 1; i < inputs.length; i++) assert.ok(inputs[i].at - inputs[i-1].at >= 65, JSON.stringify(inputs));
  await evaluate('() => { text.value = "seed"; window.events = []; }');
  await act({ kind: 'type', selector: '#text', text: 'xy', slowly: true, delayMs: 120 });
  assert.equal(await evaluate('() => text.value'), 'sexyed');
  events = await evaluate('() => window.events.filter(e => e.id === "text")');
  inputs = events.filter(e => e.type === 'input');
  assert.ok(inputs[1].at - inputs[0].at >= 110, JSON.stringify(inputs));
  await act({ kind: 'type', selector: '#text', text: 'replacement', submit: true });
  assert.equal(await evaluate('() => text.value'), 'replacement');
  assert.equal(await evaluate('() => window.submits'), 2);
});

test('recursive batches normalize private leaf copies and retain ordered input results', { timeout: 60000 }, async t => {
  const { act, evaluate } = await fixture(t);
  const request = { kind: 'batch', actions: [
    { kind: 'type', selector: '#text', text: '' },
    { kind: 'batch', actions: [
      { kind: 'press', selector: '#text', key: 'space', delayMs: 90 },
      { kind: 'batch', actions: [{ kind: 'press', key: ' + ' }] },
      { kind: 'evaluate', fn: '() => text.value' },
    ] },
    { kind: 'press', key: 'Return' },
    { kind: 'evaluate', fn: '() => ({value:text.value,submits:window.submits})' },
  ] };
  const raw = structuredClone(request);
  const result = await act(request);
  assert.deepEqual(request, raw);
  assert.equal(result.results[0].ok, true);
  assert.equal(result.results[1].results[0].ok, true);
  assert.equal(result.results[1].results[1].results[0].ok, true);
  assert.equal(result.results[1].results[2].value, ' +');
  assert.equal(result.results[2].ok, true);
  assert.deepEqual(result.results[3].value, { value: ' +', submits: 1 });
  const events = await evaluate('() => window.events.filter(e => e.type === "keydown" || e.type === "keyup")');
  // Playwright's fill('') clears the initial seed with a Delete press.
  assert.deepEqual(events.map(e => [e.type,e.key]), [['keydown','Delete'],['keyup','Delete'],['keydown',' '],['keyup',' '],['keydown','+'],['keyup','+'],['keydown','Enter'],['keyup','Enter']]);
  assert.ok(events[3].at - events[2].at >= 75);
});
