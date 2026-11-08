import { parentPort, workerData } from 'node:worker_threads';
import { planFilesystem } from './planner.mjs';

try {
  // JSON parsing, original synchronous algorithms, and serialization all stay
  // off the controller thread so its ownership channel and deadline remain live.
  const request = JSON.parse(Buffer.from(workerData.request).toString('utf8'));
  workerData.request = null;
  const result = planFilesystem(request);
  const frame = new TextEncoder().encode(JSON.stringify(result) + '\n');
  if (frame.byteLength > workerData.maxOutput) throw new RangeError();
  parentPort.postMessage({ correlation: workerData.correlation, frame: frame.buffer }, [frame.buffer]);
} catch {
  // Only the controller emits the fixed diagnostic, after observing termination.
  process.exitCode = 1;
} finally {
  parentPort.close();
}
