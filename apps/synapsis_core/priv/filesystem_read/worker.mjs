import { parentPort, workerData } from 'node:worker_threads';
import { prepareReadContent } from './read_content.mjs';

try {
  // Parsing, asynchronous classification and synchronous WASM computation stay
  // off the unchanged stdio controller's ownership/deadline event loop.
  const request = JSON.parse(Buffer.from(workerData.request).toString('utf8'));
  workerData.request = null;
  const result = await prepareReadContent(request);
  const frame = new TextEncoder().encode(JSON.stringify(result) + '\n');
  if (frame.byteLength > workerData.maxOutput) throw new RangeError();
  parentPort.postMessage({ correlation: workerData.correlation, frame: frame.buffer }, [frame.buffer]);
} catch {
  process.exitCode = 1;
} finally {
  parentPort.close();
}
