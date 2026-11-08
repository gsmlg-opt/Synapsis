import { Worker } from 'node:worker_threads';

// One public wire shape, EOF framed by default (no persistent protocol):
// { pdfBase64: string, maxPages?: integer, maxPixels?: integer,
//   minTextChars?: integer, password?: string, pageNumbers?: integer[] }
// Exactly one JSON extraction result plus LF is written after cleanup, then the
// process exits naturally. Failures use a fixed stderr diagnostic and terminate
// the whole process. No paths/URLs/retries.
// --port frames the request with LF, then accepts only the fixed cancel LF.
// The worker owns native work; this thread remains available throughout startup,
// extraction, cleanup and output flush. Cancellation kills this entire process.
const PDF_LIMITS = { maxBytes: 10 * 1024 * 1024, maxPixels: 4_000_000, maxPages: 1000, maxTextChars: 200_000 };
const base64Size = bytes => 4 * Math.ceil(bytes / 3);
const MAX_OPTIONS_BYTES = 64 * 1024;
const MAX_INPUT_FRAME_BYTES = base64Size(PDF_LIMITS.maxBytes) + MAX_OPTIONS_BYTES;
const DEFAULT_TIMEOUT_MS = 120_000;

// At most 4M RGBA pixels plus one filter byte per row (rows <= pixels).
// Deflate's worst case is bounded conservatively by twice those raw bytes plus
// 1024 bytes per PNG (zlib/chunk overhead). Base64 padding is per image.
// Text allows six JSON bytes per UTF-16 unit. Page/image metadata is budgeted
// separately at 256 bytes/page plus 4096 fixed bytes, using the host's 1000 cap.
const MAX_PNG_BYTES = 2 * (PDF_LIMITS.maxPixels * 5) + 1024 * PDF_LIMITS.maxPages;
const MAX_OUTPUT_FRAME_BYTES = base64Size(MAX_PNG_BYTES) + 4 * PDF_LIMITS.maxPages +
  6 * PDF_LIMITS.maxTextChars + 256 * PDF_LIMITS.maxPages + 4096;

const portMode = process.argv.includes('--port');
const timeoutArg = process.argv.slice(2).find(arg => arg.startsWith('--timeout-ms='));
const timeoutMs = timeoutArg === undefined ? DEFAULT_TIMEOUT_MS : Number(timeoutArg.slice('--timeout-ms='.length));
let chunks = [], size = 0, requestStarted = false, control = '', frame = null, completed = false;
let workerExited = false, flushing = false;
const abort = () => { if (!completed) process.kill(process.pid, 'SIGKILL'); };
const fail = () => {
  // No parser/native diagnostics, PDF bytes, extracted text or passwords.
  process.stderr.write('PDF extraction failed\n');
  abort();
};
const deadline = setTimeout(abort, Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= DEFAULT_TIMEOUT_MS ? timeoutMs : 1);

function flush() {
  if (!frame || !workerExited || flushing || completed) return;
  flushing = true;
  const output = frame;
  frame = null;
  process.stdout.write(output, error => {
    if (error) return fail();
    completed = true;
    clearTimeout(deadline);
    chunks = [];
    process.stdin.destroy();
  });
}

function startWorker() {
  try {
    if (requestStarted) return fail();
    requestStarted = true;
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
    chunks = [];
    size = 0;
    const worker = new Worker(new URL('./worker.mjs', import.meta.url), {
      workerData: { request: bytes.buffer, maxOutput: MAX_OUTPUT_FRAME_BYTES },
      transferList: [bytes.buffer], stdout: true, stderr: true
    });
    // Native stdout/stderr never shares the JSON protocol or leaks document data.
    worker.stdout.resume();
    worker.stderr.resume();
    worker.on('message', message => {
      if (!(message instanceof ArrayBuffer) || frame || message.byteLength > MAX_OUTPUT_FRAME_BYTES) return fail();
      frame = Buffer.from(message);
      flush();
    });
    worker.once('error', fail);
    worker.once('exit', code => {
      if (code !== 0 || !frame) return fail();
      workerExited = true;
      flush();
    });
  } catch {
    fail();
  }
}

function append(chunk) {
  size += chunk.length;
  if (size > MAX_INPUT_FRAME_BYTES) return fail();
  chunks.push(chunk);
}

process.stdin.on('data', chunk => {
  try {
    if (!portMode) return append(chunk);
    if (!requestStarted) {
      const lf = chunk.indexOf(10);
      if (lf === -1) return append(chunk);
      append(chunk.subarray(0, lf));
      startWorker();
      chunk = chunk.subarray(lf + 1);
    }
    // Only a seven-byte fixed control frame is retained after the request.
    if (control.length + chunk.length > 7) return fail();
    control += chunk.toString('ascii');
    if (!'cancel\n'.startsWith(control)) return fail();
    if (control === 'cancel\n') abort();
  } catch {
    fail();
  }
});
process.stdin.once('end', () => { if (portMode) abort(); else startWorker(); });
process.stdin.once('error', fail);
process.stdout.once('error', fail);
if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > DEFAULT_TIMEOUT_MS) fail();
