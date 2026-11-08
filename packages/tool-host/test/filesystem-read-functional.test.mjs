// Batch208: independent ordinary expectations frozen before production GO.
// No production detector, fixture helper, codec or encoder defines these oracles.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { crc32, deflateSync, inflateSync } from 'node:zlib';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
const packaged = join(repository, 'apps/synapsis_core/priv/filesystem_read');
const referenceCommit = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const runtime = {
  node: '24.22.1', v8: '13.6.233.17-node.58', unicode: '17.0', icu: '78.3',
  cldr: '48.0', platform: 'linux', arch: 'x64',
};
const codecVersions = { rastermill: '0.4.0', photon: '0.3.4', fileType: '22.1.1' };
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';
const gif = 'R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs=';
const webp = 'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==';
// Pinned OpenClaw src/plugin-sdk/test-helpers/image-fixtures.ts TINY_JPEG literal.
const jpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/ASP/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/ASP/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Aqf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IV//2gAMAwEAAgADAAAAEP/EFBQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QH//EFBQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EFBABAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z';
const bmp = 'Qk06AAAAAAAAADYAAAAoAAAAAQAAAAEAAAABABgAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AA==';
const visionNote = '[Current model does not support images. The image will be omitted from this request.]';
const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const advice = mime => `Read did not return file contents because it detected a binary document [${mime}]. Use an available document parser or converter, or convert the file to text, Markdown, or CSV, then read the converted file.`;
const textResult = text => ({ content: [{ type: 'text', text }], details: { kind: 'text', content: text } });
const imageResult = (mimeType, data, text = `Read image file [${mimeType}]`) => ({
  content: [{ type: 'text', text }, { type: 'image', data, mimeType }],
  details: { kind: 'image', content: text, mimeType },
});
const preparedResult = result => ({ kind: 'result', result });
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function qualifiedNode() {
  assert.ok(process.env.SYNAPSIS_FILESYSTEM_NODE, 'qualified Node supplied explicitly');
  assert.equal(realpathSync(process.execPath), realpathSync(process.env.SYNAPSIS_FILESYSTEM_NODE));
  assert.deepEqual({
    node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
    icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch,
  }, runtime);
}

function request(id, bytes, options = {}) {
  return Object.freeze({ protocol: 1, id, operation: 'read_content', input: Object.freeze({
    bytes: Buffer.from(bytes).toString('base64'), autoResizeImages: true, decodeMode: 'local', ...options,
  }) });
}

function envelope(req, result) {
  return { protocol: 1, id: req.id, referenceCommit, codecVersions, runtime, result };
}

async function api(root = packaged) {
  qualifiedNode();
  // Import inside each test: absent pre-GO production yields individual RED cases.
  const module = await import(pathToFileURL(join(root, 'read_content.mjs')).href);
  assert.equal(typeof module.prepareReadContent, 'function');
  return module.prepareReadContent;
}

async function checkPure(prepare, req, result) {
  const before = JSON.stringify(req);
  assert.deepEqual(await prepare(req), envelope(req, result), req.id);
  assert.equal(JSON.stringify(req), before, `${req.id}: immutable request retained`);
}

function tree(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true })
    .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    .flatMap(entry => {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) return [[path, 'directory'], ...tree(root, path)];
      if (entry.isSymbolicLink()) return [[path, 'symlink', readlinkSync(join(root, path))]];
      return [[path, 'file', sha256(readFileSync(join(root, path)))]];
    });
}

// Standard stored ZIP records: actual bytes, CRC32 and central directory, not a
// MIME override. The OOXML package includes content types, relationships and body.
function officeZip() {
  const entries = [
    ['[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'],
    ['_rels/.rels', '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'],
    ['word/document.xml', '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>ordinary document</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'],
  ];
  const locals = [], central = [];
  let offset = 0;
  for (const [path, text] of entries) {
    const name = Buffer.from(path), bytes = Buffer.from(text), crc = crc32(bytes);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); header.writeUInt16LE(20, 4); header.writeUInt16LE(33, 12);
    header.writeUInt32LE(crc, 14); header.writeUInt32LE(bytes.length, 18); header.writeUInt32LE(bytes.length, 22);
    header.writeUInt16LE(name.length, 26);
    locals.push(header, name, bytes);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50, 0); record.writeUInt16LE(20, 4); record.writeUInt16LE(20, 6);
    record.writeUInt16LE(33, 14); record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(bytes.length, 20); record.writeUInt32LE(bytes.length, 24);
    record.writeUInt16LE(name.length, 28); record.writeUInt32LE(offset, 42);
    central.push(record, name);
    offset += header.length + name.length + bytes.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

function pngChunk(type, data) {
  const name = Buffer.from(type), length = Buffer.alloc(4), crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([length, name, data, crc]);
}

function solidPng(width, height) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 3, 127)]);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), pngChunk('IHDR', header),
    pngChunk('IDAT', deflateSync(Buffer.concat(Array.from({ length: height }, () => row)))), pngChunk('IEND', Buffer.alloc(0))]);
}

function assertPng(base64, width, height) {
  const bytes = Buffer.from(base64, 'base64');
  assert.equal(bytes.toString('base64'), base64);
  assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const imageData = [];
  let offset = 8, header, ended = false;
  while (offset < bytes.length) {
    const length = bytes.readUInt32BE(offset), type = bytes.toString('ascii', offset + 4, offset + 8);
    const body = bytes.subarray(offset + 8, offset + 8 + length);
    assert.equal(bytes.readUInt32BE(offset + 8 + length), crc32(bytes.subarray(offset + 4, offset + 8 + length)));
    if (type === 'IHDR') header = body;
    if (type === 'IDAT') imageData.push(body);
    if (type === 'IEND') ended = true;
    offset += 12 + length;
  }
  assert.equal(offset, bytes.length); assert.equal(ended, true); assert.ok(header);
  assert.equal(header.readUInt32BE(0), width); assert.equal(header.readUInt32BE(4), height);
  const depths = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[header[9]];
  assert.ok(depths[header[9]]?.includes(header[8]), 'standard PNG color type and bit depth');
  assert.equal(header[10], 0); assert.equal(header[11], 0); assert.ok([0, 1].includes(header[12]));
  // This checker is used for the 1x1 BMP: even Adam7 has one populated pass.
  assert.equal(width, 1); assert.equal(height, 1);
  assert.equal(inflateSync(Buffer.concat(imageData)).length, 1 + Math.ceil(channels * header[8] / 8));
}

function jpegDimensions(bytes) {
  assert.deepEqual([...bytes.subarray(0, 3)], [255, 216, 255]);
  assert.deepEqual([...bytes.subarray(-2)], [255, 217]);
  const sof = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  let at = 2;
  while (at < bytes.length) {
    assert.equal(bytes[at++], 255);
    while (bytes[at] === 255) at++;
    const marker = bytes[at++];
    const length = bytes.readUInt16BE(at);
    if (sof.has(marker)) return { width: bytes.readUInt16BE(at + 5), height: bytes.readUInt16BE(at + 3) };
    at += length;
  }
  assert.fail('ordinary output JPEG carries dimensions');
}

async function runChild(executable, args, cwd, req) {
  const child = spawn(executable, args, {
    cwd, env: { ...process.env, NODE_PATH: '', NODE_OPTIONS: '' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const output = [], diagnostics = [], inputErrors = [];
  let exit, closed, error, finished = false;
  child.stdout.on('data', value => output.push(value)); child.stderr.on('data', value => diagnostics.push(value));
  child.stdin.on('finish', () => { finished = true; }); child.stdin.on('error', value => inputErrors.push(value));
  child.once('error', value => { error = value; });
  child.once('exit', (code, signal) => { exit = { code, signal }; });
  const closure = new Promise(resolveClose => child.once('close', (code, signal) => { closed = { code, signal }; resolveClose(); }));
  let timer;
  const bound = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ordinary helper closure not observed')), 30_000); });
  try {
    if (req) child.stdin.write(JSON.stringify(req) + '\n');
    await Promise.race([closure, bound]);
    if (error) throw error;
    assert.deepEqual(exit, { code: 0, signal: null }); assert.deepEqual(closed, { code: 0, signal: null });
    assert.deepEqual(inputErrors, []); assert.equal(existsSync(`/proc/${child.pid}`), false);
    if (req) {
      assert.equal(finished, false, 'stdin ownership remains open through normal closure');
      assert.equal(Buffer.concat(diagnostics).toString(), '');
      const wire = Buffer.concat(output).toString();
      assert.equal(wire.split('\n').length, 2); assert.equal(wire.endsWith('\n'), true);
      return JSON.parse(wire);
    }
    return { stdout: Buffer.concat(output).toString(), stderr: Buffer.concat(diagnostics).toString() };
  } finally {
    clearTimeout(timer);
    if (!closed) { child.kill('SIGKILL'); await closure; } // Harness cleanup only.
  }
}

async function stdio(root, cwd, req) {
  qualifiedNode();
  return runChild(process.execPath, [resolve(root, 'stdio.mjs')], cwd, req);
}

test('packaged preparation decodes ordinary local text without taking TextRead normalization ownership', async () => {
  const prepare = await api();
  const rows = [
    ['le', [255, 254, 104, 0, 105, 0, 10, 0], 'hi\n'],
    ['be', [254, 255, 0, 104, 0, 105, 0, 10], 'hi\n'],
    ['replacement', [99, 97, 102, 233, 10], 'caf\uFFFD\n'],
    ['bom-crlf', Buffer.from('\uFEFFhello\r\nworld\r'), '\uFEFFhello\r\nworld\r'],
    ['bom-only', [255, 254], ''],
  ];
  for (const [id, bytes, text] of rows) await checkPure(prepare, request(id, bytes), { kind: 'text', text });
  await checkPure(prepare, request('custom-utf8', Buffer.from('测试\r\n'), { decodeMode: 'utf8' }), { kind: 'text', text: '测试\r\n' });
});

test('small real image formats preserve exact bytes with default/off resize and exact-false successful vision choice', async () => {
  const prepare = await api();
  for (const [mime, base64] of [['image/png', png], ['image/jpeg', jpeg], ['image/webp', webp], ['image/gif', gif]]) {
    for (const autoResizeImages of [true, false]) {
      const req = request(`${mime}:${autoResizeImages}`, Buffer.from(base64, 'base64'), { autoResizeImages });
      await checkPure(prepare, req, preparedResult(imageResult(mime, base64)));
    }
    const omitted = request(`${mime}:text-model`, Buffer.from(base64, 'base64'), { modelHasVision: false });
    await checkPure(prepare, omitted, preparedResult(textResult(`Read image file [${mime}]\n${visionNote}`)));
  }
  await checkPure(prepare, request('explicit-vision', Buffer.from(png, 'base64'), { modelHasVision: true }), preparedResult(imageResult('image/png', png)));
});

test('real BMP conversion and ordinary 3000x1500 resize retain exact hints and independent output dimensions', async () => {
  const prepare = await api();
  const req = request('bmp', Buffer.from(bmp, 'base64'), { autoResizeImages: false });
  const actual = await prepare(req);
  const text = 'Read image file [image/png]\n[Image converted from image/bmp to image/png.]';
  const image = actual.result.result.content[1];
  assertPng(image.data, 1, 1);
  assert.deepEqual(actual, envelope(req, preparedResult(imageResult('image/png', image.data, text))));
  await checkPure(prepare, request('bmp:text-model', Buffer.from(bmp, 'base64'), { autoResizeImages: false, modelHasVision: false }),
    preparedResult(textResult(`${text}\n${visionNote}`)));

  const large = request('ordinary-dimension-resize', solidPng(3000, 1500));
  const resized = await prepare(large), output = resized.result.result.content[1];
  assert.deepEqual(jpegDimensions(Buffer.from(output.data, 'base64')), { width: 2000, height: 1000 });
  assert.deepEqual(resized, envelope(large, preparedResult(imageResult('image/jpeg', output.data,
    'Read image file [image/jpeg]\n[Image: original 3000x1500, displayed at 2000x1000. Multiply coordinates by 1.50 to map to original image.]'))));
});

test('real PDF and complete tiny Office ZIP route by bytes and stdio retires normally with stdin held open', async () => {
  const prepare = await api();
  const pdf = request('pdf-neutral-name', Buffer.from('%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF'));
  await checkPure(prepare, pdf, preparedResult(textResult(advice('application/pdf'))));
  const docx = request('office-neutral-name', officeZip());
  await checkPure(prepare, docx, preparedResult(textResult(advice(docxMime))));
  assert.deepEqual(await stdio(packaged, tmpdir(), docx), envelope(docx, preparedResult(textResult(advice(docxMime)))));
});

test('isolated reproducible artifact includes the real classifier and Photon WASM closure without repository runtime dependencies', async () => {
  qualifiedNode();
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-read-contract-'));
  try {
    const before = tree(packaged), artifact = join(temporary, 'artifact');
    await runChild(process.execPath, [join(repository, 'scripts/build-filesystem-read.mjs'), '--output', artifact], temporary);
    assert.deepEqual(tree(artifact), before, 'isolated --output reproduces every packaged byte');
    assert.equal(existsSync(join(temporary, 'node_modules')), false);
    const prepare = await api(artifact);
    const docx = request('isolated-office', officeZip());
    await checkPure(prepare, docx, preparedResult(textResult(advice(docxMime))));
    assert.deepEqual(await stdio(artifact, temporary, docx), envelope(docx, preparedResult(textResult(advice(docxMime)))));
    const bitmap = request('isolated-bmp', Buffer.from(bmp, 'base64'), { autoResizeImages: false });
    const actual = await stdio(artifact, temporary, bitmap), image = actual.result.result.content[1];
    assertPng(image.data, 1, 1);
    assert.deepEqual(actual, envelope(bitmap, preparedResult(imageResult('image/png', image.data,
      'Read image file [image/png]\n[Image converted from image/bmp to image/png.]'))));
    assert.deepEqual(tree(artifact), before, 'isolated artifact unchanged by use');
    assert.deepEqual(tree(packaged), before, 'original artifact unchanged by build/use');
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
