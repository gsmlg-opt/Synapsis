import { Worker } from 'node:worker_threads';
import { HISTORY_ENVIRONMENT_KEYS, REFERENCE_COMMIT } from './host-history-services.mjs';

// One invocation deadline and worker serve legacy waves and serial history
// targets. History transfers have independent per-transfer accounting.
const MAX_INPUT_BYTES = 8 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const WIRE_BYTES = 65_536;
const CHUNK_BYTES = 32_768;
const DEFAULT_TIMEOUT_MS = 120_000;
const args = process.argv.slice(2);
const timeoutText = args.length === 1 && args[0].startsWith('--timeout-ms=')
  ? args[0].slice('--timeout-ms='.length)
  : args.length === 2 && args[0] === '--timeout-ms' ? args[1] : args.length === 0 ? String(DEFAULT_TIMEOUT_MS) : '';
const timeoutMs = Number(timeoutText);
let worker, timer, activeId, activeSlot, pendingReadId, ready = false, closing = false, stopped = false, busy = false;
let buffer = Buffer.alloc(0), inputBytes = 0, outputBytes = 0, waves = 0, targets = 0, transferNumber = 0;
let incomingTransfer, outgoingTransfer;
const operationIds = new Set(), receivedTransferIds = new Set();
const envelope = type => ({ type, protocol: 1, historyProtocol: 1 });

function write(frame, callback) {
  if (stopped) return;
  const output = typeof frame === 'string' ? frame + '\n' : JSON.stringify(frame) + '\n';
  const history = typeof frame === 'object' && frame.type.startsWith('history_');
  if (history) {
    if (Buffer.byteLength(output) > WIRE_BYTES) return void fail();
  } else {
    outputBytes += Buffer.byteLength(output);
    if (outputBytes > MAX_OUTPUT_BYTES) return void fail();
  }
  process.stdout.write(output, error => error ? void fail() : callback?.());
}

function finishTarget() {
  busy = false;
  activeId = activeSlot = pendingReadId = undefined;
}

function writeLogical(frame, callback) {
  const bytes = Buffer.from(JSON.stringify(frame));
  if (bytes.length + 1 <= WIRE_BYTES) return write(frame, callback);
  if (bytes.length > MAX_INPUT_BYTES || incomingTransfer || outgoingTransfer) return void fail();
  outgoingTransfer = { transferId: 'helper-transfer-' + (++transferNumber), bytes, offset: 0, sequence: 0, callback, ended: false };
  write({ ...envelope('history_transfer_start'), transferId: outgoingTransfer.transferId, logicalType: frame.type, bytes: bytes.length });
}

function receiveAck(frame) {
  const transfer = outgoingTransfer;
  if (!transfer || frame.transferId !== transfer.transferId || frame.nextSequence !== transfer.sequence) return void fail();
  if (transfer.ended) {
    if (frame.complete !== true) return void fail();
    outgoingTransfer = undefined;
    // Complete synchronously before a following target in the same stdin batch.
    transfer.callback?.();
  } else if (transfer.offset < transfer.bytes.length) {
    if (frame.complete !== undefined) return void fail();
    const bytes = transfer.bytes.subarray(transfer.offset, transfer.offset + CHUNK_BYTES);
    transfer.offset += bytes.length;
    write({ ...envelope('history_transfer_chunk'), transferId: transfer.transferId,
      sequence: transfer.sequence++, data: bytes.toString('base64') });
  } else {
    if (frame.complete !== undefined) return void fail();
    transfer.ended = true;
    write({ ...envelope('history_transfer_end'), transferId: transfer.transferId });
  }
}

function receiveTransfer(frame) {
  if (frame.type === 'history_transfer_start') {
    if (incomingTransfer || outgoingTransfer || typeof frame.transferId !== 'string' || !frame.transferId || receivedTransferIds.has(frame.transferId) ||
        !['history_start', 'history_read_result'].includes(frame.logicalType) || !Number.isSafeInteger(frame.bytes) ||
        frame.bytes + 1 <= WIRE_BYTES || frame.bytes > MAX_INPUT_BYTES) return void fail();
    receivedTransferIds.add(frame.transferId);
    incomingTransfer = { ...frame, chunks: [], sequence: 0, received: 0 };
    return write({ ...envelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: 0 });
  }
  const transfer = incomingTransfer;
  if (!transfer || frame.transferId !== transfer.transferId) return void fail();
  if (frame.type === 'history_transfer_chunk') {
    if (frame.sequence !== transfer.sequence || typeof frame.data !== 'string') return void fail();
    const bytes = Buffer.from(frame.data, 'base64');
    if (!bytes.length || bytes.length > CHUNK_BYTES || bytes.toString('base64') !== frame.data || transfer.received + bytes.length > transfer.bytes) return void fail();
    transfer.chunks.push(bytes);
    transfer.received += bytes.length;
    transfer.sequence += 1;
    write({ ...envelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: transfer.sequence });
  } else if (frame.type === 'history_transfer_end') {
    if (transfer.received !== transfer.bytes) return void fail();
    const logical = JSON.parse(Buffer.concat(transfer.chunks).toString('utf8'));
    if (logical.type !== transfer.logicalType) return void fail();
    incomingTransfer = undefined;
    write({ ...envelope('history_transfer_ack'), transferId: frame.transferId, nextSequence: transfer.sequence, complete: true });
    receive(logical);
  } else void fail();
}

async function fail() {
  if (stopped) return;
  stopped = true;
  clearTimeout(timer);
  buffer = Buffer.alloc(0);
  incomingTransfer = outgoingTransfer = undefined;
  process.stdin.destroy();
  try { await worker?.terminate(); } finally {
    process.stderr.write('Session projection failed\n');
    process.exitCode = 1;
  }
}

async function close() {
  closing = true;
  await worker.terminate();
  if (stopped) return;
  write({ type: 'closed', protocol: 1, runtime: { engine: 'node-worker', heapLimitMb: 128, workerExitObserved: true } }, () => {
    stopped = true;
    clearTimeout(timer);
    process.stdin.destroy();
  });
}

function receive(frame) {
  if (!ready || closing || stopped || !frame || typeof frame !== 'object' || Array.isArray(frame)) return void fail();
  if (frame.type === 'close' && !busy && !incomingTransfer && !outgoingTransfer) return void close().catch(fail);
  if (typeof frame.type === 'string' && frame.type.startsWith('history_')) {
    if (frame.protocol !== 1 || frame.historyProtocol !== 1) return void fail();
    if (frame.type === 'history_transfer_ack') return receiveAck(frame);
    if (frame.type.startsWith('history_transfer_')) return receiveTransfer(frame);
    if (incomingTransfer || outgoingTransfer) return void fail();
    if (frame.type === 'history_start') {
      if (busy || targets >= 200 || typeof frame.id !== 'string' || !frame.id || operationIds.has(frame.id) || typeof frame.target?.slot !== 'string') return void fail();
      targets += 1;
      operationIds.add(frame.id);
      busy = true;
      activeId = frame.id;
      activeSlot = frame.target.slot;
      worker.postMessage(frame);
    } else if (frame.type === 'history_read_result' || frame.type === 'history_error') {
      if (!busy || frame.id !== activeId || frame.readId !== pendingReadId ||
          frame.type === 'history_read_result' && frame.slot !== activeSlot) return void fail();
      pendingReadId = undefined;
      worker.postMessage(frame);
    } else void fail();
    return;
  }
  if (frame.type !== 'project' || frame.protocol !== 1 || typeof frame.id !== 'string' || !frame.id || operationIds.has(frame.id) ||
      !Array.isArray(frame.rows) || busy || waves >= 2 || incomingTransfer || outgoingTransfer ||
      frame.options !== undefined && (!frame.options || typeof frame.options !== 'object' || Array.isArray(frame.options))) return void fail();
  waves += 1;
  operationIds.add(frame.id);
  busy = true;
  activeId = frame.id;
  worker.postMessage(frame);
}

if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > DEFAULT_TIMEOUT_MS) {
  await fail();
} else {
  timer = setTimeout(fail, timeoutMs);
  const environment = Object.fromEntries(HISTORY_ENVIRONMENT_KEYS.filter(key => Object.hasOwn(process.env, key)).map(key => [key, process.env[key]]));
  worker = new Worker(new URL('./worker.mjs', import.meta.url), {
    env: environment,
    resourceLimits: { maxOldGenerationSizeMb: 112, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 },
    stdout: true, stderr: true,
  });
  worker.stdout.resume();
  worker.stderr.resume();
  worker.on('message', frame => {
    if (stopped || closing) return;
    if (frame.type === 'ready' && !ready && frame.referenceCommit === REFERENCE_COMMIT) {
      ready = true;
      return write(frame);
    }
    if (frame.type === 'result' && busy && activeSlot === undefined && typeof frame.output === 'string') {
      const result = JSON.parse(frame.output);
      if (result.id !== activeId || result.referenceCommit !== REFERENCE_COMMIT) return void fail();
      return write(frame.output, finishTarget);
    }
    if (!busy || frame.id !== activeId || frame.protocol !== 1 || frame.historyProtocol !== 1) return void fail();
    if (frame.type === 'history_read' && frame.slot === activeSlot && !pendingReadId) {
      pendingReadId = frame.readId;
      return write(frame);
    }
    if (frame.type === 'history_result' && frame.slot === activeSlot && !pendingReadId) return writeLogical(frame, finishTarget);
    if (frame.type === 'history_error') return write(frame, finishTarget);
    void fail();
  });
  worker.once('error', fail);
  worker.once('exit', () => { if (!closing && !stopped) void fail(); });
  process.stdin.on('data', chunk => {
    if (closing || stopped) return;
    buffer = Buffer.concat([buffer, chunk]);
    let newline;
    while ((newline = buffer.indexOf(10)) !== -1 && !stopped && !closing) {
      const line = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      try {
        const frame = JSON.parse(line.toString('utf8'));
        if (typeof frame.type === 'string' && frame.type.startsWith('history_')) {
          if (line.length + 1 > WIRE_BYTES) return void fail();
        } else {
          inputBytes += line.length + 1;
          if (inputBytes > MAX_INPUT_BYTES) return void fail();
        }
        receive(frame);
      } catch { void fail(); }
    }
    if (buffer.length > MAX_INPUT_BYTES) void fail();
  });
  process.stdin.once('end', () => { if (!closing && !stopped) void fail(); });
  process.stdin.once('error', fail);
  process.stdout.once('error', fail);
}
