import { parentPort, workerData } from 'node:worker_threads';
import { prepareReadableDocument } from './document.mjs';

try {
  // Readability and decoding stay off the controller's ownership/deadline loop.
  const request = JSON.parse(Buffer.from(workerData.request).toString('utf8'));
  workerData.request = null;
  const result = await prepareReadableDocument(request);
  const frame = new TextEncoder().encode(JSON.stringify(result) + '\n');
  if (frame.byteLength > workerData.maxOutput) throw new RangeError();
  parentPort.postMessage({ correlation: workerData.correlation, frame: frame.buffer }, [frame.buffer]);
} catch {
  process.exitCode = 1;
} finally {
  parentPort.close();
}
