import { parentPort } from 'node:worker_threads';
import path from 'node:path';
import { createValidator, decodeRoots } from './schema.mjs';
import { renderTemplate } from './template.mjs';

// Only this worker parses semantic JSON and performs synchronous compute work.
// Main retains an independent watchdog even during compilation and regex work.
const validator = createValidator();
const MAX_OUTPUT_BYTES = 64 * 1024;

function decodeCapturedText(request) {
  const id = request?.id;
  try {
    if (typeof id !== 'string' || Object.keys(request).length !== 3 ||
        typeof request.bytes_base64 !== 'string') throw new TypeError('invalid_request');
    const bytes = Buffer.from(request.bytes_base64, 'base64');
    if (bytes.toString('base64') !== request.bytes_base64) throw new TypeError('invalid_request');
    return { id, result: 'ok', outcome: 'decoded', value: { type: 'string', value: bytes.toString('utf8') } };
  } catch {
    return { id, result: 'error', outcome: 'invalid_request' };
  }
}

// Exact keyToPath algorithm from @clawdbot/lobster 2026.9.16 state/store.js.
// Only the supplied directory spelling is used; no defaults or filesystem IO.
//
// MIT License
//
// Copyright (c) 2026 Vignesh
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
function keyToPath(stateDir, key) {
  let safe = String(key)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "_")
    .replace(/_+/g, "_");
  if (safe.startsWith("_"))
    safe = safe.slice(1);
  if (safe.endsWith("_"))
    safe = safe.slice(0, -1);
  if (!safe)
    throw new Error("state key is empty/invalid");
  return path.join(stateDir, `${safe}.json`);
}

function stateKeyPath(request, heap) {
  const id = request?.id;
  try {
    if (typeof id !== 'string' || Object.keys(request).length !== 4 ||
        !Object.hasOwn(request, 'key') || typeof request.state_dir !== 'string' ||
        !request.state_dir.isWellFormed()) throw new TypeError('invalid_request');
    let key = request.key;
    if (key?.type === 'string') {
      ({ schema: key } = decodeRoots({ schema: key }, heap));
    } else if (typeof key !== 'string' && typeof key !== 'boolean' &&
        !(typeof key === 'number' && Number.isFinite(key))) {
      throw new TypeError('invalid_request');
    }
    return { id, result: 'ok', outcome: 'state_path', lexical_path: keyToPath(request.state_dir, key) };
  } catch {
    return { id, result: 'error', outcome: 'invalid_request' };
  }
}

function render(request, heap) {
  const id = request?.id;
  let template, item;
  try {
    if (typeof id !== 'string' || !Object.hasOwn(request, 'template') ||
        !Object.hasOwn(request, 'item')) throw new TypeError('invalid_request');
    ({ schema: template, response: item } = decodeRoots({
      schema: request.template, response: request.item
    }, heap));
    if (typeof template !== 'string') throw new TypeError('invalid_template');
  } catch {
    return { id, result: 'error', outcome: 'invalid_request' };
  }
  try {
    const text = renderTemplate(template, item);
    const value = text.isWellFormed()
      ? { type: 'string', value: text }
      : { type: 'string', utf16le: Buffer.from(text, 'utf16le').toString('base64') };
    return { id, result: 'ok', outcome: 'rendered', value };
  } catch {
    return { id, result: 'error', outcome: 'template_failed' };
  }
}

function sortItems(request, heap) {
  const id = request?.id;
  try {
    if (typeof id !== 'string' || Object.keys(request).length !== 5 ||
        typeof request.desc !== 'boolean' || !Number.isSafeInteger(request.stage_index) ||
        request.stage_index < 0) throw new TypeError('invalid_request');
    const { schema: keys } = decodeRoots({ schema: request.keys }, heap);
    if (!Array.isArray(keys)) throw new TypeError('invalid_request');
    const decorated = keys.map((value, index) => ({ index, value }));
    decorated.sort((left, right) => {
      const comparison = defaultCompare(left.value, right.value);
      return request.desc ? -comparison : comparison;
    });
    return { id, result: 'ok', outcome: 'sorted', indices: decorated.map(item => item.index) };
  } catch {
    return { id, result: 'error', outcome: 'invalid_request' };
  }
}

function defaultCompare(a, b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  const sa = String(a);
  const sb = String(b);
  return sa < sb ? -1 : sa > sb ? 1 : 0;
}

parentPort.on('message', message => {
  if (message.type === 'close') {
    parentPort.close();
    return;
  }
  try {
    const envelope = JSON.parse(Buffer.from(message.bytes).toString('utf8'));
    if (envelope.type !== 'request' || !envelope.request || !envelope.heap) {
      throw new TypeError('invalid_envelope');
    }
    let operation;
    if (envelope.request.kind === 'decode_template_file' ||
        envelope.request.kind === 'decode_state_text') {
      operation = decodeCapturedText(envelope.request);
    } else if (envelope.request.kind === 'state_key_path') {
      operation = stateKeyPath(envelope.request, envelope.heap);
    } else if (envelope.request.kind === 'render_template') {
      operation = render(envelope.request, envelope.heap);
    } else if (envelope.request.kind === 'sort_items') {
      operation = sortItems(envelope.request, envelope.heap);
    } else {
      operation = validator.fulfill(envelope.request, envelope.heap);
    }
    const frame = new TextEncoder().encode(JSON.stringify({
      type: 'result', ...operation, cacheEntries: validator.cacheSize()
    }) + '\n');
    if (frame.byteLength > MAX_OUTPUT_BYTES) throw new RangeError('output_budget');
    parentPort.postMessage({
      type: 'result', sequence: message.sequence, bytes: frame.buffer,
      terminal: operation.outcome === 'resource_limit'
    }, [frame.buffer]);
  } catch {
    // Never emit parser/schema/template/data text on a protocol or diagnostic fd.
    process.exitCode = 1;
    parentPort.close();
  }
});
parentPort.postMessage({ type: 'ready' });
