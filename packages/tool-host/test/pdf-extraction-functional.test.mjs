import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { inflateSync } from 'node:zlib';
import { extractPdfContent } from '../src/pdf/extract.mjs';
import { pdfFixture, FIRST_TEXT, THIRD_TEXT } from './fixtures/pdf-fixture.mjs';

function png(image) {
  assert.deepEqual(Object.keys(image).sort(), ['data', 'mimeType', 'type']);
  assert.equal(image.type, 'image');
  assert.equal(image.mimeType, 'image/png');
  const bytes = Buffer.from(image.data, 'base64');
  assert.deepEqual(bytes.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  assert.equal(bytes[24], 8);
  assert.equal(bytes[25], 6); // Decode real 8-bit RGBA, including all PNG row filters.
  const chunks = [];
  for (let at = 8; at < bytes.length;) {
    const size = bytes.readUInt32BE(at), type = bytes.toString('ascii', at + 4, at + 8);
    if (type === 'IDAT') chunks.push(bytes.subarray(at + 8, at + 8 + size));
    at += size + 12;
  }
  const raw = inflateSync(Buffer.concat(chunks));
  const stride = width * 4, rgba = Buffer.alloc(stride * height);
  assert.equal(raw.length, (stride + 1) * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const at = y * stride + x;
      const left = x >= 4 ? rgba[at - 4] : 0, up = y ? rgba[at - stride] : 0;
      const upperLeft = y && x >= 4 ? rgba[at - stride - 4] : 0;
      const p = left + up - upperLeft;
      const distances = [Math.abs(p - left), Math.abs(p - up), Math.abs(p - upperLeft)];
      const paeth = distances[0] <= distances[1] && distances[0] <= distances[2] ? left : distances[1] <= distances[2] ? up : upperLeft;
      const predictors = [0, left, up, Math.floor((left + up) / 2), paeth];
      assert.ok(filter <= 4);
      rgba[at] = (raw[y * (stride + 1) + 1 + x] + predictors[filter]) & 255;
    }
  }
  const center = (Math.floor(height / 2) * width + Math.floor(width / 2)) * 4;
  return { width, height, center: [...rgba.subarray(center, center + 4)] };
}

const normalized = value => value.replaceAll('\r\n', '\n').trim();

test('PDFium reads actual per-page text and renders only sparse/vector pages as ordered PNGs', { timeout: 30000 }, async () => {
  const result = await extractPdfContent({ buffer: pdfFixture() });
  assert.equal(normalized(result.text), `${FIRST_TEXT}\n\nSparse second page\n\n${THIRD_TEXT}`);
  assert.deepEqual(result.metadata, {
    pages: { processed: [1, 2, 3, 4], total: 4, selection: 'automatic', truncated: false },
    textTruncated: false, imagesTruncated: false
  });
  assert.equal(result.images.length, 2);
  const images = result.images.map(png);
  assert.deepEqual(images, [
    { width: 192, height: 96, center: [255, 0, 0, 255] },
    { width: 192, height: 96, center: [0, 0, 255, 255] }
  ]);
});

test('explicit pages are unique, numerically ordered and retain total-document metadata', { timeout: 30000 }, async () => {
  const result = await extractPdfContent({ buffer: new Uint8Array(pdfFixture()), pageNumbers: [4, 2, 2] });
  assert.equal(normalized(result.text), 'Sparse second page');
  assert.deepEqual(result.metadata.pages, { processed: [2, 4], total: 4, selection: 'explicit', truncated: false });
  assert.deepEqual(result.images.map(image => png(image).center), [[255, 0, 0, 255], [0, 0, 255, 255]]);
});

test('maxPages reports ordinary automatic and explicit selection truncation accurately', { timeout: 30000 }, async () => {
  const automatic = await extractPdfContent({ buffer: pdfFixture(), maxPages: 2 });
  assert.deepEqual(automatic.metadata.pages, { processed: [1, 2], total: 4, selection: 'automatic', truncated: true });
  assert.equal(normalized(automatic.text), `${FIRST_TEXT}\n\nSparse second page`);
  const explicit = await extractPdfContent({ buffer: pdfFixture(), pageNumbers: [4, 3, 2], maxPages: 2 });
  assert.deepEqual(explicit.metadata.pages, { processed: [2, 3], total: 4, selection: 'explicit', truncated: true });
  assert.equal(normalized(explicit.text), `Sparse second page\n\n${THIRD_TEXT}`);
  assert.equal(explicit.images.length, 1);
});

test('default first-20 selection is configurable for a larger ordinary document', { timeout: 30000 }, async () => {
  const buffer = pdfFixture(Array.from({ length: 22 }, (_, i) => ({ text: `Document page ${i + 1}` })));
  const automatic = await extractPdfContent({ buffer, minTextChars: 1 });
  assert.deepEqual(automatic.metadata.pages, { processed: Array.from({ length: 20 }, (_, i) => i + 1), total: 22, selection: 'automatic', truncated: true });
  assert.match(automatic.text, /Document page 20$/);
  const configured = await extractPdfContent({ buffer, maxPages: 22, minTextChars: 1 });
  assert.deepEqual(configured.metadata.pages.processed, Array.from({ length: 22 }, (_, i) => i + 1));
  assert.equal(configured.metadata.pages.truncated, false);
  assert.match(configured.text, /Document page 22$/);
  assert.deepEqual(configured.images, []);
});

test('aggregate pixel allocation produces real reduced images and reports the reduction', { timeout: 30000 }, async () => {
  const result = await extractPdfContent({ buffer: pdfFixture(), maxPixels: 10000 });
  const images = result.images.map(png);
  assert.equal(images.length, 2);
  assert.ok(images.reduce((sum, image) => sum + image.width * image.height, 0) <= 10000);
  assert.ok(images.every(image => image.width < 192 && image.height < 96));
  assert.deepEqual(images.map(image => image.center), [[255, 0, 0, 255], [0, 0, 255, 255]]);
  assert.equal(result.metadata.imagesTruncated, true);
  assert.equal(result.metadata.textTruncated, false);
});

test('a long vector page renders within the reference 10000-pixel edge cap', { timeout: 30000 }, async () => {
  const result = await extractPdfContent({ buffer: pdfFixture([{ width: 100000, height: 1, color: [0, 0, 1] }]) });
  assert.deepEqual(png(result.images[0]), { width: 10000, height: 1, center: [0, 0, 255, 255] });
  assert.equal(result.metadata.imagesTruncated, true);
});

test('ordinary long extracted text returns the exact 200000-character prefix and metadata', { timeout: 30000 }, async () => {
  // The original single-literal fixture yielded 32767 characters with this PDFium
  // build; use independently readable pages to cross the extractor's text ceiling.
  const pages = Array.from({ length: 8 }, () => ({ text: 'A'.repeat(30000), fontSize: 0.001 }));
  const text = pages.map(page => page.text).join('\n\n');
  const result = await extractPdfContent({ buffer: pdfFixture(pages), minTextChars: 1 });
  assert.equal(result.text, text.slice(0, 200000));
  assert.equal(result.metadata.textTruncated, true);
  assert.equal(result.metadata.pages.truncated, false);
  assert.deepEqual(result.images, []);
});

test('one EOF-framed stdio request emits an actual extraction result and the child exits cleanly', { timeout: 30000 }, async t => {
  const child = spawn(process.execPath, [new URL('../src/pdf/stdio.mjs', import.meta.url).pathname], { stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill(); });
  const output = [], diagnostics = [];
  child.stdout.on('data', chunk => output.push(chunk));
  child.stderr.on('data', chunk => diagnostics.push(chunk));
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  child.stdin.end(JSON.stringify({ pdfBase64: pdfFixture().toString('base64'), pageNumbers: [4, 2] }));
  assert.deepEqual(await completion, { code: 0, signal: null });
  assert.equal(Buffer.concat(diagnostics).toString(), '');
  const stdout = Buffer.concat(output).toString();
  assert.equal(stdout.trim().split('\n').length, 1);
  const result = JSON.parse(stdout);
  assert.equal(normalized(result.text), 'Sparse second page');
  assert.deepEqual(result.metadata.pages, { processed: [2, 4], total: 4, selection: 'explicit', truncated: false });
  assert.deepEqual(result.images.map(image => png(image).center), [[255, 0, 0, 255], [0, 0, 255, 255]]);
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
});
