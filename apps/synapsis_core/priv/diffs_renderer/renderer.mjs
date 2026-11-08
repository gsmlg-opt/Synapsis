import { createHash, randomUUID } from 'node:crypto';
import { readFile, writeFile, mkdir, rename, lstat, realpath } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';
import { chromium } from './node_modules/playwright-core/index.mjs';

const root = fileURLToPath(new URL('./', import.meta.url));
const base = 'http://127.0.0.1/plugins/diffs/view/local/local';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const MAX_ARTIFACT = 32 * 1024 * 1024;

// Internal, explicit-path capsule owner. It does not serve URLs, enact TTL,
// discover executables, register tools or publish durable session results.
export class DiffsRenderer {
  constructor({ chromiumExecutable, stagingRoot }) {
    if (![chromiumExecutable, stagingRoot].every(isAbsolute)) throw new Error('Absolute paths required');
    this.chromiumExecutable = chromiumExecutable;
    this.stagingRoot = stagingRoot;
    this.sequence = 0;
    this.pages = new Set();
    this.workerClosed = false;
    this.closing = false;
  }

  async initialize() {
    await mkdir(this.stagingRoot, { recursive: true });
    if (await realpath(this.stagingRoot) !== this.stagingRoot) throw new Error('Staging root must be canonical');
    this.manifest = JSON.parse(await readFile(join(root, 'capsule.json'), 'utf8'));
    this.worker = new Worker(new URL('./worker.mjs', import.meta.url), {
      stdout: true, stderr: true,
      resourceLimits: { maxOldGenerationSizeMb: 256, maxYoungGenerationSizeMb: 32, stackSizeMb: 4 }
    });
    this.worker.stdout.resume(); this.worker.stderr.resume();
    this.workerExit = new Promise(resolve => this.worker.once('exit', code => resolve(code)));
    this.worker.on('message', message => {
      if (this.pending && message.id === this.pending.id) {
        const pending = this.pending; this.pending = null;
        if (message.error) pending.reject(new Error('SSR failed'));
        else pending.resolve(message.document);
      }
    });
    this.worker.on('error', () => this.pending?.reject(new Error('SSR worker failed')));
    this.worker.on('exit', () => {
      if (this.pending) {
        this.pending.reject(new Error('SSR worker closed'));
        this.pending = null;
      }
    });
    await new Promise((resolve, reject) => {
      this.worker.once('message', message => message.type === 'ready' ? resolve() : reject(new Error('Worker not ready')));
      this.worker.once('error', reject);
      this.worker.once('exit', () => reject(new Error('Worker exited before ready')));
    });
    return { version: 1, reference: this.manifest.reference, languagePackAvailable: false,
      packages: this.manifest.packages, assets: this.manifest.assets };
  }

  async browser(timeout) {
    if (this.closing) throw new Error('Renderer closing');
    if (!this.launch) this.launch = (async () => {
      this.server = await chromium.launchServer({ executablePath: this.chromiumExecutable,
        headless: true, args: ['--disable-dev-shm-usage'], timeout });
      const child = this.server.process();
      this.browserPid = child.pid;
      this.browserExit = new Promise(resolve => child.once('exit', (code, signal) => resolve({ pid: child.pid, code, signal })));
      this.instance = await chromium.connect(this.server.wsEndpoint(), { timeout });
      return this.instance;
    })();
    return this.launch;
  }

  async openPage(html, options, timeout) {
    const browser = await this.browser(timeout);
    const page = await browser.newPage({ viewport: { width: Math.max(Math.ceil(options.image.maxWidth + 240), 1200), height: 900 },
      deviceScaleFactor: options.image.scale, colorScheme: options.presentation.theme });
    this.pages.add(page);
    page.setDefaultTimeout(timeout);
    page.setDefaultNavigationTimeout(timeout);
    try {
      await page.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.href === 'about:blank' || url.protocol === 'data:') return route.continue();
        const name = url.pathname.slice('/plugins/diffs/assets/'.length);
        const asset = this.manifest.assets[name];
        if (url.origin !== 'http://127.0.0.1' || !url.pathname.startsWith('/plugins/diffs/assets/') || !asset) return route.abort();
        const bytes = await readFile(join(root, 'assets', name));
        if (digest(bytes) !== asset.sha256) return route.abort();
        await route.fulfill({ status: 200, contentType: name.endsWith('.js') ? 'text/javascript' : 'application/json', body: bytes });
      });
      await page.setContent(html.replace('<head>', `<head><base href="${base}" />`), { waitUntil: 'load' });
      await page.waitForFunction(() => document.documentElement.dataset.openclawDiffsReady === 'true', undefined, { timeout: Math.min(timeout, 10_000) });
      await page.evaluate(async () => { await document.fonts.ready; });
      return page;
    } catch (error) {
      await this.closePage(page);
      throw error;
    }
  }

  async closePage(page) {
    await page.context().close();
    this.pages.delete(page);
  }

  async render(plan, timeoutMs = 120_000) {
    if (this.active || this.closing || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000) throw new Error('Renderer unavailable');
    this.active = true;
    const deadline = Date.now() + timeoutMs;
    const id = ++this.sequence;
    const remaining = () => { const ms = deadline - Date.now(); if (this.closing || ms <= 0) throw new Error('Render deadline'); return ms; };
    try {
      const document = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('SSR deadline')), remaining());
        this.pending = { id, resolve: result => { clearTimeout(timer); resolve(result); }, reject: error => { clearTimeout(timer); reject(error); } };
        this.worker.postMessage({ id, plan });
      });
      const directory = `${id}-${randomUUID()}`;
      await mkdir(join(this.stagingRoot, directory));
      const artifacts = {};
      const save = async (name, bytes, mimeType) => {
        if (bytes.length > MAX_ARTIFACT) throw new Error('Artifact limit');
        const path = join(directory, name), target = join(this.stagingRoot, path), temporary = target + '.partial';
        await writeFile(temporary, bytes, { flag: 'wx', mode: 0o600 });
        remaining();
        await rename(temporary, target);
        const stat = await lstat(target);
        if (!stat.isFile() || stat.size !== bytes.length) throw new Error('Incomplete artifact');
        return { path, mimeType, bytes: bytes.length, sha256: digest(bytes) };
      };
      if (document.html !== undefined) artifacts.html = await save('viewer.html', Buffer.from(document.html), 'text/html; charset=utf-8');
      if (document.imageHtml !== undefined) {
        artifacts.imageHtml = await save('image.html', Buffer.from(document.imageHtml), 'text/html; charset=utf-8');
        const file = await this.capture(document.imageHtml, plan.options, remaining);
        artifacts.file = await save(`diff.${plan.options.image.format}`, file, plan.options.image.format === 'pdf' ? 'application/pdf' : 'image/png');
      }
      remaining();
      return { version: 1, id, title: document.title, inputKind: document.inputKind, fileCount: document.fileCount, artifacts };
    } finally { this.active = false; }
  }

  // Source: OpenClaw 488631c browser.runtime.ts screenshotHtml. Geometry,
  // fonts, pixel-scale reduction and PDF screen sizing retain source behavior.
  // Ownership replaces the source global idle lease with this helper's browser.
  async capture(html, options, remaining) {
    let currentScale = options.image.scale;
    for (let attempt = 0; attempt <= 2; attempt++) {
      const page = await this.openPage(html, { ...options, image: { ...options.image, scale: currentScale } }, remaining());
      try {
        await page.evaluate(() => { document.querySelector('.oc-frame').dataset.renderMode = 'image'; });
        const frame = page.locator('.oc-frame');
        await frame.waitFor();
        const initial = await frame.boundingBox();
        if (!initial) throw new Error('Missing frame');
        const pdf = options.image.format === 'pdf', padding = pdf ? 0 : 20;
        const clipWidth = Math.ceil(initial.width + padding * 2);
        const clipHeight = Math.ceil(Math.max(initial.height + padding * 2, 320));
        await page.setViewportSize({ width: Math.max(clipWidth + padding, 900), height: Math.max(clipHeight + padding, 700) });
        const box = await frame.boundingBox();
        if (!box) throw new Error('Missing resized frame');
        if (pdf) {
          await page.emulateMedia({ media: 'screen' });
          await page.evaluate(() => {
            document.documentElement.style.background = 'transparent';
            Object.assign(document.body.style, { margin: '0', padding: '0', background: 'transparent' });
            document.body.style.setProperty('-webkit-print-color-adjust', 'exact');
            document.querySelector('.oc-frame').style.margin = '0';
          });
          const pdfBox = await frame.boundingBox();
          if (!pdfBox) throw new Error('Missing PDF frame');
          const width = Math.max(Math.ceil(pdfBox.width), 1), height = Math.max(Math.ceil(pdfBox.height), 1);
          if (width * height > options.image.maxPixels || Math.ceil(height / 1056) > 50) throw new Error('Image size limit');
          return await page.pdf({ width: `${width}px`, height: `${height}px`, printBackground: true,
            margin: { top: '0', right: '0', bottom: '0', left: '0' }, timeout: remaining() });
        }
        const dpr = await page.evaluate(() => window.devicePixelRatio || 1);
        const rawX = Math.max(box.x - padding, 0), rawY = Math.max(box.y - padding, 0);
        const x = Math.floor(rawX * dpr) / dpr, y = Math.floor(rawY * dpr) / dpr;
        const width = Math.max(Math.ceil((rawX + clipWidth) * dpr) / dpr - x, 1);
        const height = Math.max(Math.ceil((rawY + clipHeight) * dpr) / dpr - y, 1);
        if (width * height * dpr * dpr > options.image.maxPixels) {
          const reduced = Math.max(1, Math.round(Math.min(currentScale, Math.sqrt(options.image.maxPixels / (width * height))) * 100) / 100);
          if (currentScale > 1 && reduced < currentScale - 0.01 && attempt < 2) { currentScale = reduced; continue; }
          throw new Error('Image size limit');
        }
        return await page.screenshot({ type: 'png', scale: 'device', clip: { x, y, width, height }, timeout: remaining() });
      } finally { await this.closePage(page); }
    }
    throw new Error('Image size limit');
  }

  async close() {
    if (this.closePromise) return this.closePromise;
    this.closing = true;
    this.closePromise = (async () => {
      for (const page of this.pages) await this.closePage(page);
      if (this.worker) { await this.worker.terminate(); await this.workerExit; this.workerClosed = true; }
      if (this.launch) {
        // A failed connection may still have launched a browser we own.
        try { await this.launch; } catch { /* Still close the captured server. */ }
      }
      let browserExit = null;
      if (this.server) { await this.server.close(); browserExit = await this.browserExit; }
      return { workerClosed: this.workerClosed, browserExit };
    })();
    return this.closePromise;
  }
}
