import { stat } from 'node:fs/promises';
import path from 'node:path';

// One invocation, no content reads or effects. Local owns path admission and
// verifies file identities around this actual builtin metadata capture.
const MAX_FRAME = 8 * 1024 * 1024;
const args = process.argv.slice(2);
const rawTimeout = args.length === 0 ? 5000
  : args.length === 2 && args[0] === '--timeout-ms' ? Number(args[1])
    : args.length === 1 && /^--timeout-ms=\d+$/.test(args[0]) ? Number(args[0].slice(13)) : NaN;
const validTimeout = Number.isSafeInteger(rawTimeout) && rawTimeout > 0 && rawTimeout <= 5000;
let chunks = [], bytes = 0, started = false, settled = false, control = '';
const timer = setTimeout(fail, validTimeout ? rawTimeout : 1);

function fail() {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  process.stdin.destroy();
  process.exit(1);
}

async function capture(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request) ||
      Object.keys(request).some(key => !['root', 'files', 'names'].includes(key)) ||
      typeof request.root !== 'string' || !path.isAbsolute(request.root) ||
      path.resolve(request.root) !== request.root || !Array.isArray(request.files) ||
      !Array.isArray(request.names ?? [])) throw new Error('Metadata capture failed');
  const files = request.files;
  const names = request.names ?? [];
  if (!names.every(name => typeof name === 'string' && !name.includes('\0')))
    throw new Error('Metadata capture failed');
  let sizeBytes = 0, updatedAtMs = 0;
  for (const file of files) {
    if (typeof file !== 'string' || path.isAbsolute(file) || file.includes('\\') || file.includes('\0') ||
        file.split('/').some(part => !part || part === '.' || part === '..'))
      throw new Error('Metadata capture failed');
    const metadata = await stat(path.join(request.root, file));
    if (!metadata.isFile()) throw new Error('Metadata capture failed');
    sizeBytes += metadata.size;
    updatedAtMs = Math.max(updatedAtMs, metadata.mtimeMs);
  }
  return { files: files.toSorted((a, b) => a === 'SKILL.md' ? -1 : b === 'SKILL.md' ? 1 : a.localeCompare(b)),
    sizeBytes, updatedAtMs: Math.trunc(updatedAtMs), names: names.toSorted((a, b) => a.localeCompare(b)) };
}

process.stdin.on('data', chunk => {
  if (settled) return;
  if (started) {
    if (control.length + chunk.length > 7) return fail();
    control += chunk.toString('latin1');
    if (!'cancel\n'.startsWith(control) || control === 'cancel\n') fail();
    return;
  }
  bytes += chunk.length;
  if (bytes > MAX_FRAME) return fail();
  const lf = chunk.indexOf(10);
  if (lf < 0) { chunks.push(chunk); return; }
  if (lf !== chunk.length - 1) return fail();
  chunks.push(chunk.subarray(0, lf));
  started = true;
  let request;
  try { request = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { return fail(); }
  chunks = [];
  capture(request).then(result => {
    if (settled) return;
    const frame = JSON.stringify({ protocol: 1, pid: process.pid,
      runtime: { node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
        icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch },
      result }) + '\n';
    if (Buffer.byteLength(frame) > MAX_FRAME) return fail();
    process.stdout.write(frame, error => {
      if (error || settled) return fail();
      settled = true;
      clearTimeout(timer);
      process.stdin.destroy();
      process.stdout.end();
    });
  }).catch(fail);
});
process.stdin.on('end', () => { if (!started) fail(); });
process.stdin.on('error', fail);
process.stdout.on('error', fail);
if (!validTimeout) fail();
