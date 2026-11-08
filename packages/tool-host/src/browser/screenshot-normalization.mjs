/*
 * Adapted from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b:
 * extensions/browser/src/browser/screenshot.ts and screenshot-annotate.ts,
 * src/agents/tool-images.ts and src/media/image-ops.ts.
 *
 * MIT License
 * Copyright (c) 2026 OpenClaw Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
import { Worker } from 'node:worker_threads';
import { screenshotDimensions } from './screenshot-labels.mjs';

const MAX_BYTES = 5 * 1024 * 1024;

// Captures are PNG/JPEG, so their dimensions can be read without loading the
// codec on the host's event loop. Only actual transforms need a compute owner.
export async function normalizeScreenshot(buffer, type, { maxSide = 2000, signal } = {}) {
  signal?.throwIfAborted();
  const sourceDimensions = screenshotDimensions(buffer, type);
  if (buffer.length <= MAX_BYTES && sourceDimensions.width <= maxSide && sourceDimensions.height <= maxSide) {
    return { buffer, type, sourceDimensions, dimensions: sourceDimensions };
  }
  // The source stays reusable by the caller and every candidate in the worker.
  const input = Uint8Array.from(buffer);
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./image-worker.mjs', import.meta.url), {
      workerData: { input, maxSide, sourceDimensions }, transferList: [input.buffer],
    });
    let reply; let failure;
    const onAbort = () => {
      failure = signal.reason ?? new Error('Browser image normalization cancelled');
      // Settlement belongs to exit, not terminate's request or a message. The
      // outer fileTask consequently cannot confirm cleanup with live compute.
      void worker.terminate().catch(error => { failure ??= error; });
    };
    worker.once('message', value => { reply = value; });
    worker.once('error', error => { failure ??= error; });
    worker.once('exit', code => {
      signal?.removeEventListener('abort', onAbort);
      if (failure) return reject(failure);
      if (code !== 0 || !reply) return reject(new Error(`Browser image worker exited without a result (${code})`));
      if (reply.error) return reject(new Error(reply.error));
      const output = Buffer.from(reply.output.buffer, reply.output.byteOffset, reply.output.byteLength);
      resolve({ buffer: output, type: 'jpeg', sourceDimensions, dimensions: reply.dimensions });
    });
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) onAbort();
  });
}

// Browser annotations describe the saved artifact. Generic inline sanitization
// changes only image bytes and MIME and never applies this scale a second time.
export function scaleScreenshotAnnotations(annotations, source, saved) {
  if (source.width === saved.width && source.height === saved.height) return annotations;
  const scaleX = saved.width / source.width; const scaleY = saved.height / source.height;
  return annotations.map(item => ({ ...item, box: {
    x: Math.round(item.box.x * scaleX), y: Math.round(item.box.y * scaleY),
    width: Math.max(1, Math.round(item.box.width * scaleX)), height: Math.max(1, Math.round(item.box.height * scaleY)),
  } }));
}
