import { BrowserHost, HostError, RESULT_DISPATCHED } from './host.mjs';

const FRAME_LIMIT = 1024 * 1024;
const MAX_REQUESTS = 4;
const MAX_REQUEST_BYTES = 2 * FRAME_LIMIT;
const MAX_OUTPUT_BYTES = MAX_REQUESTS * FRAME_LIMIT;
const WRITE_TIMEOUT_MS = 5000;
let host = null;
let active = null;
let ending = false;
let finishPromise = null;
let requestBytes = 0;
let capacityWaiter = null;
let outputBytes = 0;
let outputFrames = 0;
let outputTail = Promise.resolve();
const requests = new Set();
const pendingIds = new Set();

class TransportError extends Error {}
function errorData(error, dispatched) {
  return { class: error.class ?? 'browser_error', message: String(error.message ?? error).slice(0, 2000),
    generation: host?.generation ?? 0, dispatched: error.dispatched === true || dispatched, ...(error.cleanup ? { cleanup: error.cleanup } : {}) };
}
function encode(id, result, error, dispatched) {
  let frame;
  try {
    frame = JSON.stringify({ version: 1, id, ...(error ? { error: errorData(error, dispatched) } : { result }) });
  } catch {
    frame = JSON.stringify({ version: 1, id, error: { class: 'serialization_error', message: 'Browser response is not JSON serializable', generation: host?.generation ?? 0, dispatched } });
  }
  if (Buffer.byteLength(frame) + 1 > FRAME_LIMIT) {
    frame = JSON.stringify({ version: 1, id, error: { class: 'result_budget', message: 'Response exceeds protocol frame budget', generation: host?.generation ?? 0, dispatched } });
  }
  return `${frame}\n`;
}
function write(frame) {
  return new Promise((resolve, reject) => {
    let callbackDone = false;
    let drained = false;
    const timer = setTimeout(() => settle(new TransportError('stdout write deadline')), WRITE_TIMEOUT_MS);
    function settle(error) {
      clearTimeout(timer);
      process.stdout.off('drain', onDrain);
      process.stdout.off('error', onError);
      if (error) reject(error); else resolve();
    }
    function complete() { if (callbackDone && drained) settle(); }
    function onDrain() { drained = true; complete(); }
    function onError() { settle(new TransportError('stdout unavailable')); }
    process.stdout.once('drain', onDrain);
    process.stdout.once('error', onError);
    try {
      drained = process.stdout.write(frame, error => {
        if (error) { onError(); return; }
        callbackDone = true;
        complete();
      });
    } catch { onError(); }
  });
}
function send(id, result, error) {
  const dispatched = result?.[RESULT_DISPATCHED] === true || error?.dispatched === true;
  const frame = encode(id, result, error, dispatched);
  const bytes = Buffer.byteLength(frame);
  // Every admitted request emits at most one response. The output reservation is
  // therefore bounded even when all admitted requests finish simultaneously.
  if (outputFrames >= MAX_REQUESTS || outputBytes + bytes > MAX_OUTPUT_BYTES) {
    throw new TransportError('output admission exhausted');
  }
  outputFrames++;
  outputBytes += bytes;
  const task = outputTail.then(() => write(frame)).finally(() => { outputFrames--; outputBytes -= bytes; });
  outputTail = task.catch(() => {});
  return task;
}
function invalid(message) { return new HostError('invalid_request', message); }

async function handle(frame, oversized) {
  if (oversized) { await send(null, null, invalid('Input exceeds protocol frame budget')); return; }
  let request;
  try { request = JSON.parse(frame); }
  catch { await send(null, null, invalid('Expected a JSON protocol frame')); return; }
  const id = request?.id;
  if (request?.version !== 1 || typeof id !== 'string' || id.length < 1 || id.length > 256 || !['initialize', 'call', 'cancel', 'close'].includes(request?.method)) {
    await send(typeof id === 'string' && id.length <= 256 ? id : null, null, invalid('Expected version 1, bounded string id, and supported method'));
    return;
  }
  if (pendingIds.has(id)) { await send(id, null, new HostError('busy', 'Request id is already pending')); return; }
  pendingIds.add(id);
  let result;
  let failure;
  let closing = false;
  try {
    if (ending) throw new HostError('closed', 'Helper is closing');
    if (request.method === 'initialize') {
      if (host) throw invalid('Helper is already initialized');
      host = new BrowserHost(request.params);
      result = { initialized: true, ...host.status() };
    } else {
      if (!host) throw invalid('Initialize the helper first');
      if (request.method === 'close') {
        ending = true;
        closing = true;
        process.stdin.pause();
        result = await host.close();
        if (active) await active.settled;
      } else if (request.method === 'cancel') {
        if (typeof request.params?.id !== 'string' || request.params.id !== active?.id) throw invalid('cancel requires the exact pending call id in params.id');
        const call = active;
        result = await host.cancel();
        await call.settled;
        // Preserve helper-private evidence when extending public cancellation data.
        Object.defineProperty(result, 'callId', { value: call.id, enumerable: true });
      } else {
        const params = request.params;
        if (!params || typeof params !== 'object' || Array.isArray(params)) throw invalid('call params must be an object');
        const readOnly = ['status', 'profiles', 'doctor'].includes(params.action);
        if (!readOnly && active) throw new HostError('busy', 'A browser call is already pending');
        let complete;
        const call = { id, settled: new Promise(resolve => { complete = resolve; }) };
        if (!readOnly) active = call;
        try {
          result = await host.invoke(params.action, params.args, { timeoutMs: params.timeout_ms, generation: params.generation });
        } finally {
          if (active === call) active = null;
          complete();
        }
      }
    }
  } catch (error) { failure = error; }
  try {
    await send(id, result, failure);
    if (closing) process.exit(result?.cleanup_confirmed ? 0 : 1);
  } finally { pendingIds.delete(id); }
}

async function admit(frame, oversized = false) {
  const bytes = Buffer.byteLength(frame);
  // There is one parser and at most one capacity waiter, with no request queue.
  while (!ending && (requests.size >= MAX_REQUESTS || requestBytes + bytes > MAX_REQUEST_BYTES)) {
    await new Promise(resolve => { capacityWaiter = resolve; });
  }
  if (ending) return;
  requestBytes += bytes;
  const task = handle(frame, oversized).catch(() => { void finish(1); }).finally(() => {
    requests.delete(task);
    requestBytes -= bytes;
    const wake = capacityWaiter;
    capacityWaiter = null;
    wake?.();
  });
  requests.add(task);
}

async function readInput() {
  let buffer = Buffer.alloc(0);
  let discarding = false;
  // Async iteration applies pipe backpressure while admission is full. In-memory
  // input is limited to one bounded partial frame and one bounded current chunk.
  for await (const chunk of process.stdin) {
    if (ending) return;
    if (chunk.length > FRAME_LIMIT) throw new TransportError('input chunk exceeds buffer budget');
    let offset = 0;
    while (offset < chunk.length && !ending) {
      const newline = chunk.indexOf(10, offset);
      const end = newline === -1 ? chunk.length : newline;
      const fragment = chunk.subarray(offset, end);
      if (!discarding) {
        if (buffer.length + fragment.length >= FRAME_LIMIT) {
          buffer = Buffer.alloc(0);
          discarding = true;
          await admit('', true);
        } else buffer = Buffer.concat([buffer, fragment]);
      }
      if (newline !== -1) {
        if (!discarding) {
          const frame = buffer.toString('utf8');
          if (frame.trim()) await admit(frame);
        }
        buffer = Buffer.alloc(0);
        discarding = false;
      }
      offset = end + 1;
    }
  }
  await finish(0);
}
function finish(code) {
  if (!finishPromise) finishPromise = (async () => {
    ending = true;
    process.stdin.pause();
    capacityWaiter?.();
    capacityWaiter = null;
    const result = host ? await host.close() : { cleanup_confirmed: true };
    if (active) await active.settled;
    await Promise.allSettled([...requests]);
    await outputTail;
    process.exit(code || (result.cleanup_confirmed ? 0 : 1));
  })();
  return finishPromise;
}
process.stdout.on('error', () => { void finish(1); });
process.once('SIGTERM', () => { void finish(0); });
process.once('SIGINT', () => { void finish(0); });
void readInput().catch(() => { void finish(1); });
