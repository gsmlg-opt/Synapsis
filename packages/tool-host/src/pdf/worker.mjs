import { parentPort, workerData } from 'node:worker_threads';

const WIRE_FIELDS = new Set(['pdfBase64', 'maxPages', 'maxPixels', 'minTextChars', 'password', 'pageNumbers']);

try {
  const request = JSON.parse(Buffer.from(workerData.request).toString('utf8'));
  workerData.request = null;
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new TypeError();
  for (const field of Object.keys(request)) if (!WIRE_FIELDS.has(field)) throw new TypeError();
  const { pdfBase64, ...options } = request;
  if (typeof pdfBase64 !== 'string' || pdfBase64.length === 0 || pdfBase64.length > 4 * Math.ceil(10 * 1024 * 1024 / 3) ||
      pdfBase64.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(pdfBase64)) throw new TypeError();
  const buffer = Buffer.from(pdfBase64, 'base64');
  const { extractPdfContent } = await import('./extract.mjs');
  const result = await extractPdfContent({ ...options, buffer });
  const frame = new TextEncoder().encode(JSON.stringify(result) + '\n');
  if (frame.byteLength > workerData.maxOutput) throw new RangeError();
  parentPort.postMessage(frame.buffer, [frame.buffer]);
} catch {
  // The parent emits a fixed generic diagnostic after observing this exit.
  process.exitCode = 1;
} finally {
  parentPort.close();
}
