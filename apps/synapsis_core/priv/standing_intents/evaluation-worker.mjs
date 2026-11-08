import { parentPort, workerData } from 'node:worker_threads';
import { evaluate } from './contract.mjs';

// Invocation-owned evaluation thread makes the parent timeout responsive even
// while native date/string/number routines execute synchronously.
try {
  const result = await evaluate(workerData);
  parentPort.postMessage({ result });
  parentPort.close();
} catch {
  parentPort.close();
  process.exitCode = 1;
}
