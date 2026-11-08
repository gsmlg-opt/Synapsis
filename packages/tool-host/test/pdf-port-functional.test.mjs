import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { inflateSync } from 'node:zlib';
import { pdfFixture } from './fixtures/pdf-fixture.mjs';

function helper(t) {
  const child = spawn(process.execPath, [new URL('../src/pdf/stdio.mjs', import.meta.url).pathname, '--port', '--timeout-ms=15000'], {
    stdio: ['pipe', 'pipe', 'pipe']
  });
  const output = [], diagnostics = [];
  child.stdout.on('data', chunk => output.push(chunk));
  child.stderr.on('data', chunk => diagnostics.push(chunk));
  child.stdin.on('error', () => {}); // The helper owns completion and closes its input.
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill(); });
  return { child, output, diagnostics, completion };
}

function center(image) {
  assert.equal(image.mimeType, 'image/png');
  assert.equal(image.type, 'image');
  const bytes = Buffer.from(image.data, 'base64');
  assert.deepEqual(bytes.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20), chunks = [];
  assert.equal(width, 192);
  assert.equal(height, 96);
  for (let at = 8; at < bytes.length;) {
    const length = bytes.readUInt32BE(at);
    if (bytes.toString('ascii', at + 4, at + 8) === 'IDAT') chunks.push(bytes.subarray(at + 8, at + 8 + length));
    at += length + 12;
  }
  const raw = inflateSync(Buffer.concat(chunks)), stride = width * 4, rgba = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    assert.ok(filter <= 4);
    for (let x = 0; x < stride; x++) {
      const at = y * stride + x, left = x >= 4 ? rgba[at - 4] : 0;
      const up = y ? rgba[at - stride] : 0, diagonal = y && x >= 4 ? rgba[at - stride - 4] : 0;
      const p = left + up - diagonal, distances = [Math.abs(p - left), Math.abs(p - up), Math.abs(p - diagonal)];
      const paeth = distances[0] <= distances[1] && distances[0] <= distances[2] ? left : distances[1] <= distances[2] ? up : diagonal;
      rgba[at] = (raw[y * (stride + 1) + x + 1] + [0, left, up, Math.floor((left + up) / 2), paeth][filter]) & 255;
    }
  }
  const at = (Math.floor(height / 2) * width + Math.floor(width / 2)) * 4;
  return [...rgba.subarray(at, at + 4)];
}

test('Port request completes with one real selected PDF result while stdin remains open', { timeout: 30000 }, async t => {
  const { child, output, diagnostics, completion } = helper(t);
  child.stdin.write(JSON.stringify({ pdfBase64: pdfFixture().toString('base64'), pageNumbers: [4, 2, 2] }) + '\n');
  assert.deepEqual(await completion, { code: 0, signal: null });
  assert.equal(Buffer.concat(diagnostics).toString(), '');
  const wire = Buffer.concat(output).toString();
  assert.equal(wire.split('\n').length, 2);
  assert.ok(wire.endsWith('\n'));
  const result = JSON.parse(wire);
  assert.equal(result.text.replaceAll('\r\n', '\n').trim(), 'Sparse second page');
  assert.deepEqual(result.metadata, {
    pages: { processed: [2, 4], total: 4, selection: 'explicit', truncated: false },
    textTruncated: false, imagesTruncated: false
  });
  assert.deepEqual(result.images.map(center), [[255, 0, 0, 255], [0, 0, 255, 255]]);
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
});

test('ordinary pending Port extraction accepts cancellation and the owned helper exits', { timeout: 30000 }, async t => {
  const { child, output, completion } = helper(t);
  child.stdin.write(JSON.stringify({ pdfBase64: pdfFixture().toString('base64') }) + '\n');
  child.stdin.write('cancel\n');
  const result = await completion;
  if (result.code === 0) {
    assert.equal(result.signal, null);
    assert.deepEqual(JSON.parse(Buffer.concat(output)).metadata.pages.processed, [1, 2, 3, 4]);
  } else {
    assert.deepEqual(result, { code: null, signal: 'SIGKILL' });
  }
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
});
