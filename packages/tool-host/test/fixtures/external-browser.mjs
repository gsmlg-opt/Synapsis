import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium } from 'playwright-core';

const marker = 'external-browser-owned-by-fixture';

async function within(promise, timeoutMs) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('external fixture deadline')), timeoutMs); })]); }
  finally { clearTimeout(timer); }
}

// This fixture, rather than BrowserHost, owns the external Chromium process.
export async function startExternalBrowser({ executable, directory, initialUrl = 'about:blank', timeoutMs = 15000 }) {
  await mkdir(directory, { recursive: true });
  const profileDir = await mkdtemp(join(directory, 'external-profile-'));
  const markerPath = join(profileDir, 'fixture-owner-marker');
  await writeFile(markerPath, marker);
  const child = spawn(executable, [
    '--headless=new', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
    `--user-data-dir=${profileDir}`, '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-component-update', initialUrl,
  ], { stdio: ['ignore', 'ignore', 'ignore'] });
  let spawnError;
  const exited = new Promise(resolveExit => {
    child.once('error', error => { spawnError = error; resolveExit(); });
    child.once('exit', resolveExit);
  });
  let closing;
  const close = () => closing ??= (async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    try { await within(exited, 3000); }
    catch {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      await within(exited, 3000);
    }
    await rm(profileDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    return { closed: true, exited: true };
  })();
  try {
    let endpoint;
    const deadline = Date.now() + timeoutMs;
    while (!endpoint) {
      if (spawnError || child.exitCode !== null || child.signalCode !== null) throw new Error('external fixture Chromium exited before readiness');
      if (Date.now() >= deadline) throw new Error('external fixture Chromium readiness deadline');
      try {
        const [port, path] = (await readFile(join(profileDir, 'DevToolsActivePort'), 'utf8')).trim().split('\n');
        if (/^\d+$/.test(port) && path?.startsWith('/devtools/browser/')) endpoint = `ws://127.0.0.1:${port}${path}`;
      } catch { /* The fixture-owned process is still starting. */ }
      if (!endpoint) await delay(25);
    }
    const inspect = async fn => {
      const browser = await chromium.connectOverCDP(endpoint, { timeout: timeoutMs, noDefaults: true });
      try {
        const pages = [];
        for (const context of browser.contexts()) {
          context.setDefaultTimeout(timeoutMs);
          for (const page of context.pages()) {
            await page.waitForLoadState('domcontentloaded');
            pages.push({ url: page.url(), ...(fn ? { value: await page.evaluate(`(${fn})()`) } : {}) });
          }
        }
        return { alive: child.exitCode === null && child.signalCode === null, marker: await readFile(markerPath, 'utf8'), pages };
      } finally { await within(browser.close(), 3000); }
    };
    const initial = await chromium.connectOverCDP(endpoint, { timeout: timeoutMs, noDefaults: true });
    try {
      const context = initial.contexts()[0];
      const page = context.pages()[0] ?? await context.waitForEvent('page', { timeout: timeoutMs });
      await page.waitForURL(new URL(initialUrl).href, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    } finally { await within(initial.close(), 3000); }
    return { endpoint, pid: child.pid, profileDir, markerPath, initialUrl, inspect, close };
  } catch (error) { await close(); throw error; }
}

async function main() {
  const [executable, directory, initialUrl] = process.argv.slice(2);
  const fixture = await startExternalBrowser({ executable, directory, initialUrl });
  const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
  send({ event: 'ready', ...Object.fromEntries(['endpoint', 'pid', 'profileDir', 'markerPath', 'initialUrl'].map(key => [key, fixture[key]])) });
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      const command = JSON.parse(line);
      if (command.method === 'inspect') send({ id: command.id, ...await fixture.inspect(command.fn) });
      else if (command.method === 'close') { send({ id: command.id, ...await fixture.close() }); break; }
      else throw new Error('unknown external fixture command');
    }
  } finally { lines.close(); await fixture.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
