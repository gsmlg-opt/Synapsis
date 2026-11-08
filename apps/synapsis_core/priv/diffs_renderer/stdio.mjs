import { DiffsRenderer } from './renderer.mjs';

// Bounded metadata-only NDJSON. Artifact bytes never travel over this channel.
const INPUT_LIMIT = 8 * 1024 * 1024, OUTPUT_LIMIT = 64 * 1024;
const args = process.argv.slice(2);
if (args.length !== 4 || args[0] !== '--chromium' || args[2] !== '--staging') throw new Error('Explicit renderer paths required');
const renderer = new DiffsRenderer({ chromiumExecutable: args[1], stagingRoot: args[3] });
let chunks = [], size = 0, active = false, ready = false, closing = false;
let operationTimer, frameTimer;
const write = value => new Promise((resolve, reject) => {
  const frame = JSON.stringify(value) + '\n';
  if (Buffer.byteLength(frame) > OUTPUT_LIMIT) return reject(new Error('Metadata limit'));
  process.stdout.write(frame, error => error ? reject(error) : resolve());
});
async function close(failed = false) {
  if (closing) return;
  closing = true;
  clearTimeout(operationTimer); clearTimeout(frameTimer); clearTimeout(startupTimer);
  const watchdog = setTimeout(() => process.exit(1), 10_000);
  try {
    const result = await renderer.close();
    if (!failed) await write({ type: 'closed', ...result });
    process.exitCode = failed ? 1 : 0;
  } catch { process.exitCode = 1; }
  finally { clearTimeout(watchdog); process.stdin.destroy(); }
}
const fail = () => { void close(true); };
const startupTimer = setTimeout(fail, 15_000);
renderer.initialize().then(async manifest => {
  if (closing) return;
  await write({ type: 'ready', ...manifest });
  clearTimeout(startupTimer); ready = true;
}).catch(fail);
async function consume(bytes) {
  try {
    const message = JSON.parse(bytes.toString('utf8'));
    if (message.type === 'close' && !active && ready) { await close(); return; }
    if (closing || !ready || active || message.type !== 'request' ||
        message.id !== renderer.sequence + 1 || !Number.isSafeInteger(message.timeoutMs) ||
        message.timeoutMs < 1 || message.timeoutMs > 120_000) return fail();
    active = true;
    operationTimer = setTimeout(fail, message.timeoutMs);
    const receipt = await renderer.render(message.plan, message.timeoutMs);
    if (closing) return;
    await write({ type: 'result', receipt, browserPid: renderer.browserPid ?? null });
    clearTimeout(operationTimer); active = false;
  } catch { fail(); }
}
process.stdin.on('data', chunk => {
  while (chunk.length && !closing) {
    if (size === 0) frameTimer = setTimeout(fail, 15_000);
    const lf = chunk.indexOf(10), part = lf < 0 ? chunk : chunk.subarray(0, lf);
    size += part.length;
    if (size > INPUT_LIMIT) return fail();
    chunks.push(part);
    if (lf < 0) return;
    const frame = Buffer.concat(chunks, size);
    chunks = []; size = 0; clearTimeout(frameTimer);
    void consume(frame);
    chunk = chunk.subarray(lf + 1);
  }
});
process.stdin.once('end', fail);
process.stdin.once('error', fail);
process.stdout.once('error', fail);
