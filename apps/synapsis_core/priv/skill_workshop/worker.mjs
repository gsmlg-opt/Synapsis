import { Worker } from 'node:worker_threads';

const REFERENCE = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const FRAME_BYTES = 8 * 1024 * 1024;
const args = process.argv.slice(2);
const supplied = args.length === 0 ? 5000
  : args.length === 2 && args[0] === '--timeout-ms' ? Number(args[1]) : NaN;
const timeout = Number.isInteger(supplied) && supplied > 0 ? Math.min(supplied, 5000) : 1;
let chunks = [], bytes = 0, started = false, settled = false, evaluation, response;
const timer = setTimeout(() => void fail(), timeout);
process.stdin.on('error', () => void fail());
process.stdout.on('error', () => void fail());
process.stdin.on('end', () => { if (!started) void fail(); });
process.stdin.on('data', chunk => {
  if (settled) return;
  if (started) return void fail();
  bytes += chunk.length;
  if (bytes > FRAME_BYTES) return void fail();
  const end = chunk.indexOf(10);
  if (end < 0) { chunks.push(chunk); return; }
  if (end !== chunk.length - 1) return void fail();
  chunks.push(chunk.subarray(0, end));
  started = true;
  let request;
  try { request = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { return void fail(); }
  chunks = [];
  try {
    evaluation = new Worker(new URL('./evaluation-worker.mjs', import.meta.url), { workerData: request });
  } catch { return void fail(); }
  evaluation.on('message', message => {
    if (settled || response !== undefined || !message || !Object.hasOwn(message, 'result')) return void fail();
    response = message;
  });
  evaluation.on('error', () => void fail());
  evaluation.on('exit', code => {
    evaluation = undefined;
    if (settled) return;
    if (code !== 0 || response === undefined) return void fail();
    let output;
    try {
      output = JSON.stringify({ protocol: 1, referenceCommit: REFERENCE, pid: process.pid,
        runtime: { node: process.versions.node, v8: process.versions.v8, unicode: process.versions.unicode,
          icu: process.versions.icu, cldr: process.versions.cldr, platform: process.platform, arch: process.arch },
        result: response.result }) + '\n';
    } catch { return void fail(); }
    if (Buffer.byteLength(output) > FRAME_BYTES) return void fail();
    process.stdout.write(output, error => {
      if (error || settled) return void fail();
      settled = true;
      clearTimeout(timer);
      process.stdin.destroy();
      process.stdout.end(() => process.exit(0));
    });
  });
});

async function fail() {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  process.stdin.destroy();
  try { await evaluation?.terminate(); } catch { /* Parent Port still treats this as failure. */ }
  process.exit(1);
}
