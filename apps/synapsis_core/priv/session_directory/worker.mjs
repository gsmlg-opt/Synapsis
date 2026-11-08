import { parentPort } from 'node:worker_threads';
import { initializeInvocationServices, REFERENCE_COMMIT } from './host-history-services.mjs';

const MAX_OUTPUT_BYTES = 1024 * 1024;
const runtime = { engine: 'node-worker', heapLimitMb: 128, workerExitObserved: false };
let projectRows, projectHistory, projectStandaloneHistory, pendingRead, active, readNumber = 0;

parentPort.on('message', async frame => {
  if (frame.type === 'history_read_result') {
    if (!pendingRead || pendingRead.id !== frame.id || pendingRead.readId !== frame.readId || pendingRead.slot !== frame.slot) return fail();
    const { resolve } = pendingRead;
    pendingRead = undefined;
    resolve(frame);
    return;
  }
  if (frame.type === 'history_error') {
    if (!pendingRead || pendingRead.id !== frame.id) return fail();
    const { reject } = pendingRead;
    pendingRead = undefined;
    reject(new Error(frame.reason));
    return;
  }
  if (active) return fail();
  active = true;
  try {
    if (frame.type === 'project') {
      projectRows ??= (await import('./session-projection.mjs')).projectRows;
      const result = projectRows(frame.rows, frame.options);
      const output = JSON.stringify({ type: 'result', protocol: 1, id: frame.id, referenceCommit: REFERENCE_COMMIT, result, runtime });
      if (Buffer.byteLength(output) + 1 > MAX_OUTPUT_BYTES) throw new RangeError('Projection output exceeds limit');
      active = false;
      parentPort.postMessage({ type: 'result', output });
    } else if (frame.type === 'history_start') {
      const view = await initializeInvocationServices(frame.servicePolicy);
      let project;
      if (frame.mode === 'standalone') {
        projectStandaloneHistory ??= (await import('./standalone-history.mjs')).projectStandaloneHistory;
        project = projectStandaloneHistory;
      } else if (frame.mode === undefined || frame.mode === 'inline') {
        projectHistory ??= (await import('./history.mjs')).projectHistory;
        project = projectHistory;
      } else throw new Error('history_start');
      const result = await project(frame, (operation, options) => new Promise((resolve, reject) => {
        const request = { type: 'history_read', protocol: 1, historyProtocol: 1, id: frame.id,
          readId: 'r' + (++readNumber), slot: frame.target.slot, operation, options };
        pendingRead = { ...request, resolve, reject };
        parentPort.postMessage(request);
      }), view);
      active = false;
      parentPort.postMessage({ ...result, runtime });
    } else fail();
  } catch (error) {
    if (frame.type === 'history_start') {
      active = false;
      parentPort.postMessage({ type: 'history_error', protocol: 1, historyProtocol: 1, id: frame.id,
        reason: error.message === 'history_reader_admission' ? 'history_reader_admission' : 'history_projection' });
    } else fail();
  }
});

function fail() {
  parentPort.postMessage({ type: 'error' });
  parentPort.close();
  process.exitCode = 1;
}

parentPort.postMessage({ type: 'ready', protocol: 1, referenceCommit: REFERENCE_COMMIT });
