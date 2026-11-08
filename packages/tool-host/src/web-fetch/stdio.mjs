import { Worker } from 'node:worker_threads';

// One request JSON + LF, with stdin kept open as the caller's ownership channel.
// The only subsequent input is the fixed seven-byte cancellation frame.
// Captured response bytes and the source-shaped document have separate finite
// transport ceilings; these never enlarge the public presentation limits.
const MAX_INPUT_FRAME_BYTES = 2 * 1024 * 1024;
const MAX_OUTPUT_FRAME_BYTES = 262144;
const DEFAULT_TIMEOUT_MS = 5000;
const args = process.argv.slice(2);
const timeoutArg = args[0];
const timeoutMs = timeoutArg === undefined ? DEFAULT_TIMEOUT_MS : Number(timeoutArg.slice('--timeout-ms='.length));
let chunks = [], size = 0, started = false, control = '';
let frame = null, workerExited = false, flushing = false, completed = false;
const correlation = 1; // One worker, one request; never supplied by the model.

function fail() {
  if (completed) return;
  completed = true;
  process.stderr.write('Readable document preparation failed\n');
  // Process termination also retires its worker thread. No child process, pool,
  // filesystem handle or target effect is owned by this pure helper.
  process.exit(1);
}

// This controller deadline also covers request framing, worker startup and flush.
const validTimeout = Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= DEFAULT_TIMEOUT_MS;
const deadline = setTimeout(fail, validTimeout ? timeoutMs : 1);

function flush() {
  if (frame === null || !workerExited || flushing || completed) return;
  flushing = true;
  const output = frame;
  frame = null;
  process.stdout.write(output, error => {
    if (error) return fail();
    completed = true;
    clearTimeout(deadline);
    chunks = [];
    process.stdin.destroy();
    // Natural exit0 follows stdout flush and the already-observed worker exit0.
  });
}

function startWorker() {
  started = true;
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  chunks = [];
  size = 0;
  const worker = new Worker(new URL('./worker.mjs', import.meta.url), {
    workerData: { request: bytes.buffer, maxOutput: MAX_OUTPUT_FRAME_BYTES, correlation },
    transferList: [bytes.buffer], stdout: true, stderr: true,
  });
  worker.stdout.resume();
  worker.stderr.resume();
  worker.on('message', message => {
    if (completed || !message || message.correlation !== correlation ||
        !(message.frame instanceof ArrayBuffer) || frame !== null || flushing ||
        message.frame.byteLength > MAX_OUTPUT_FRAME_BYTES) return fail();
    frame = Buffer.from(message.frame);
    flush();
  });
  worker.once('error', fail);
  worker.once('exit', code => {
    if (code !== 0 || frame === null) return fail();
    workerExited = true;
    flush();
  });
}

function append(chunk) {
  size += chunk.length;
  if (size > MAX_INPUT_FRAME_BYTES) return fail();
  chunks.push(chunk);
}

process.stdin.on('data', chunk => {
  try {
    if (!started) {
      const lf = chunk.indexOf(10);
      if (lf === -1) return append(chunk);
      append(chunk.subarray(0, lf));
      startWorker();
      chunk = chunk.subarray(lf + 1);
    }
    if (control.length + chunk.length > 7) return fail();
    control += chunk.toString('latin1');
    if (!'cancel\n'.startsWith(control) || control === 'cancel\n') return fail();
  } catch {
    fail();
  }
});
process.stdin.once('end', fail);
process.stdin.once('close', fail);
process.stdin.once('error', fail);
process.stdout.once('error', fail);
if (!validTimeout || args.length > 1 || (timeoutArg !== undefined && !/^--timeout-ms=\d+$/.test(timeoutArg))) fail();
