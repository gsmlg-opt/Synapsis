/*
 * Adapted from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b:
 * extensions/browser/src/browser/screenshot.ts, src/agents/tool-images.ts,
 * src/media/image-ops.ts and image-processor-config.ts.
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
import { parentPort, workerData } from 'node:worker_threads';
import { createRastermill } from 'rastermill';

const MAX_BYTES = 5 * 1024 * 1024;
const processor = createRastermill({ execution: 'internal', limits: { inputPixels: 25_000_000, outputPixels: 25_000_000 } });

async function normalize() {
  const { input, maxSide, sourceDimensions } = workerData;
  const sideStart = Math.min(maxSide, Math.max(sourceDimensions.width, sourceDimensions.height));
  const sides = [...new Set([sideStart, 1800, 1600, 1400, 1200, 1000, 800].map(side => Math.min(maxSide, side)))]
    .filter(side => side > 0).sort((a, b) => b - a);
  let smallest = Infinity;
  for (const side of sides) for (const quality of [85, 75, 65, 55, 45, 35]) {
    // Always start from the original stage input, never the previous candidate.
    const encoded = await processor.encode(input, { format: 'jpeg', resize: { maxSide: side, enlarge: false }, quality });
    smallest = Math.min(smallest, encoded.data.length);
    if (encoded.data.length <= MAX_BYTES) {
      const output = Uint8Array.from(encoded.data);
      parentPort.postMessage({ output, dimensions: { width: encoded.width, height: encoded.height } }, [output.buffer]);
      return;
    }
  }
  throw new Error(`Browser screenshot could not be reduced below 5MB (got ${(smallest / (1024 * 1024)).toFixed(2)}MB)`);
}

try { await normalize(); }
catch (error) { parentPort.postMessage({ error: String(error.message ?? error) }); }
finally { parentPort.close(); }
