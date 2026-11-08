import { Worker } from 'node:worker_threads';

// Fixed compute NDJSON. The trusted caller puts the finite deadline
// ahead of request/heap; this thread never JSON-parses either semantic value.
const MAX_INPUT_BYTES = 8 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024;
const MAX_TIMEOUT_MS = 120_000;
const STARTUP_TIMEOUT_MS = 15_000;
const CLEANUP_TIMEOUT_MS = 2_000;
const HEADER_BYTES = 96;
let chunks = [], size = 0, header = Buffer.alloc(0), frameStarted = null;
let frameTimer = null, operationTimer = null, cleanupTimer = null;
let ready = false, active = null, sequence = 0, closing = false, completed = false;

// A whole-process kill also stops a CPU-bound Worker. Port.close/worker.terminate
// alone is never used here as a claim that an OS process was cleaned up.
function abort() { if (!completed) process.kill(process.pid, 'SIGKILL'); }
function clearTimers() {
  for (const timer of [startupTimer, frameTimer, operationTimer, cleanupTimer]) clearTimeout(timer);
}
function write(frame, callback = () => {}) {
  if (Buffer.byteLength(frame) > MAX_OUTPUT_BYTES) return abort();
  process.stdout.write(frame, error => { if (error) abort(); else callback(); });
}
const startupTimer = setTimeout(abort, STARTUP_TIMEOUT_MS);
const worker = new Worker(new URL('./schema-worker.mjs', import.meta.url), {
  stdout: true, stderr: true,
  resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 }
});
worker.stdout.resume();
worker.stderr.resume();
worker.once('error', abort);
worker.on('message', message => {
  if (message.type === 'ready' && !ready && !closing) {
    ready = true;
    clearTimeout(startupTimer);
    write('{"type":"ready","version":1,"profile":"ajv-8.20.0-draft07"}\n');
    return;
  }
  if (message.type !== 'result' || !active || message.sequence !== active || closing ||
      !(message.bytes instanceof ArrayBuffer) || message.bytes.byteLength > MAX_OUTPUT_BYTES) {
    return abort();
  }
  write(Buffer.from(message.bytes), () => {
    clearTimeout(operationTimer);
    operationTimer = null;
    active = null;
    // A budget failure is an explicit terminal session result, never eviction.
    if (message.terminal) abort();
  });
});
worker.once('exit', code => {
  if (!closing || code !== 0 || active !== null) return abort();
  write('{"type":"closed"}\n', () => {
    completed = true;
    clearTimers();
    chunks = [];
    header = Buffer.alloc(0);
    process.stdin.destroy();
  });
});

function append(chunk) {
  if (chunk.length === 0) return;
  if (frameStarted === null) {
    frameStarted = Date.now();
    frameTimer = setTimeout(abort, STARTUP_TIMEOUT_MS);
  }
  size += chunk.length;
  if (size > MAX_INPUT_BYTES) return abort();
  chunks.push(chunk);
  if (header.length < HEADER_BYTES) {
    header = Buffer.concat([header, chunk.subarray(0, HEADER_BYTES - header.length)]);
    const match = /^\{"type":"request","timeoutMs":([0-9]+),/.exec(header.toString('ascii'));
    if (match) {
      const timeout = Number(match[1]);
      if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > MAX_TIMEOUT_MS) return abort();
      clearTimeout(frameTimer);
      frameTimer = setTimeout(abort, Math.max(0, frameStarted + timeout - Date.now()));
    }
  }
}

function consumeFrame() {
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  const prefix = header.toString('ascii');
  const started = frameStarted;
  chunks = []; size = 0; header = Buffer.alloc(0); frameStarted = null;
  clearTimeout(frameTimer); frameTimer = null;
  if (bytes.length === 17 && Buffer.from(bytes).equals(Buffer.from('{"type":"cancel"}'))) return abort();
  if (bytes.length === 16 && Buffer.from(bytes).equals(Buffer.from('{"type":"close"}'))) {
    if (!ready || active !== null || closing) return abort();
    closing = true;
    cleanupTimer = setTimeout(abort, CLEANUP_TIMEOUT_MS);
    worker.postMessage({ type: 'close' });
    return;
  }
  const match = /^\{"type":"request","timeoutMs":([0-9]+),"request":/.exec(prefix);
  if (!match || !ready || active !== null || closing) return abort();
  const timeout = Number(match[1]);
  if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > MAX_TIMEOUT_MS) return abort();
  const remaining = started + timeout - Date.now();
  if (remaining <= 0) return abort();
  active = ++sequence;
  operationTimer = setTimeout(abort, remaining);
  worker.postMessage({ type: 'request', sequence: active, bytes: bytes.buffer }, [bytes.buffer]);
}

process.stdin.on('data', chunk => {
  try {
    while (chunk.length) {
      const lf = chunk.indexOf(10);
      if (lf === -1) { append(chunk); return; }
      append(chunk.subarray(0, lf));
      consumeFrame();
      chunk = chunk.subarray(lf + 1);
    }
  } catch { abort(); }
});
process.stdin.once('end', abort);
process.stdin.once('error', abort);
process.stdout.once('error', abort);
