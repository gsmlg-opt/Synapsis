import { spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, rm, realpath, lstat, open, rename } from 'node:fs/promises';
import { randomUUID, createHash } from 'node:crypto';
import { constants, createReadStream } from 'node:fs';
import { join, isAbsolute, resolve, dirname, basename, relative, sep } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium, devices } from 'playwright-core';
import { captureNativeRoleSnapshot } from './native-role-snapshot.mjs';
import { captureAriaSnapshot, captureRawAriaSnapshot } from './aria-snapshot.mjs';
import { SnapshotDeltaCache, captureWithSnapshotDelta } from './snapshot-delta.mjs';
import { projectSnapshotQuery } from './snapshot-query.mjs';
import { createBrowserWaitPredicate } from './wait.mjs';
import { normalizePressKeyChord } from './input.mjs';
import { MAX_BROWSER_TIMEOUT_MS, prepareActRequest, interactionTimeoutMs, waitTimeoutMs,
  typingTimeoutMs, pressTimeoutMs, evaluateInnerTimeoutMs } from './timing.mjs';
import { screenshotDimensions, measureScreenshotLabels, planScreenshotLabels, createScreenshotOverlay,
  attachScreenshotOverlay, clearScreenshotOverlay, screenshotAnnotations } from './screenshot-labels.mjs';
import { normalizeScreenshot, scaleScreenshotAnnotations } from './screenshot-normalization.mjs';

export const ACTIONS = Object.freeze(['status', 'start', 'stop', 'profiles', 'tabs', 'open', 'focus', 'close', 'navigate', 'snapshot', 'act', 'screenshot', 'doctor', 'console', 'requests', 'errors', 'text', 'emulate', 'dialog', 'pdf', 'download', 'waitfordownload', 'upload']);
export const ACT_KINDS = Object.freeze(['batch', 'click', 'clickCoords', 'type', 'press', 'hover', 'scrollIntoView', 'drag', 'select', 'fill', 'resize', 'wait', 'evaluate', 'close']);
// Helper-private evidence survives result serialization without entering public JSON.
export const RESULT_DISPATCHED = Symbol('browserResultDispatched');
function withDispatchEvidence(result, dispatched) {
  Object.defineProperty(result, RESULT_DISPATCHED, { value: dispatched === true });
  return result;
}
const READ_ONLY = new Set(['status', 'profiles', 'doctor']);
const MAX_IMAGE_BYTES = 196608;
const MAX_TEXT = 131072;
const HISTORY_LIMIT = 200;
const HISTORY_BYTES = 131072;
const OBSERVATION_BYTES = 65536;
const PENDING_ACTION_LIMIT = 8;
const PENDING_ACTION_LIFETIME_MS = 120000;
const MAX_UPLOAD_BYTES = 64 * 1024 * 1024;
const ACTION_DOWNLOAD_GRACE_MS = 250;
const ACTION_DOWNLOAD_DRAIN_MS = 1000;

// Slice Unicode code points, with separate character and UTF-8 byte budgets.
function clip(value, maxChars = 2048, maxBytes = 8192) {
  let text = '';
  let chars = 0;
  let bytes = 0;
  for (const character of String(value)) {
    const size = Buffer.byteLength(character);
    if (chars + character.length > maxChars || bytes + size > maxBytes) break;
    text += character;
    chars += character.length;
    bytes += size;
  }
  return { text, truncated: text.length < String(value).length };
}
function observed(value, name, record) {
  const bounded = clip(value);
  if (bounded.truncated) record.truncated = true;
  record[name] = bounded.text;
}
function history() { return { entries: [], dropped: 0 }; }
function trimHistory(log) {
  while (log.entries.length > HISTORY_LIMIT || Buffer.byteLength(JSON.stringify(log.entries)) > HISTORY_BYTES) {
    log.entries.shift();
    log.dropped++;
  }
}
function append(log, entry) { log.entries.push(entry); trimHistory(log); }
function priority(level) { return level === 'error' ? 3 : ['warn', 'warning'].includes(level) ? 2 : level === 'debug' ? 0 : 1; }

export class HostError extends Error {
  constructor(klass, message, dispatched = false, cleanup) {
    super(message);
    this.class = klass;
    this.dispatched = dispatched;
    if (cleanup) this.cleanup = cleanup;
  }
}
const invalid = (message) => { throw new HostError('invalid_arguments', message); };
const positive = (value, name, max = 120000) => {
  if (!Number.isInteger(value) || value <= 0 || value > max) invalid(`${name} must be an integer in 1..${max}`);
  return value;
};
const string = (value, name) => {
  if (typeof value !== 'string' || !value.length) invalid(`${name} must be a nonempty string`);
  return value;
};
const object = (value, name) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid(`${name} must be an object`);
  return value;
};
function bounded(value, max, name, fallback) {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < 0 || value > max) invalid(`${name} must be in 0..${max}`);
  return value;
}
function url(value) {
  string(value, 'targetUrl');
  let parsed;
  try { parsed = new URL(value); } catch { invalid('targetUrl must be an absolute URL'); }
  if (!['http:', 'https:', 'about:'].includes(parsed.protocol)) invalid('targetUrl requires http, https, or about');
  return parsed.href;
}
async function within(promise, ms) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('cleanup deadline')), ms); })]); }
  finally { clearTimeout(timer); }
}

function normalizedTabLabel(value) {
  if (value === undefined) return undefined;
  if (typeof value !== 'string') invalid('label must be a string');
  const label = value.trim();
  if (!label) return undefined;
  if (!/^[A-Za-z0-9_.:-]{1,64}$/.test(label)) invalid('label must be 1-64 ASCII letters, numbers, _, ., :, or -');
  return label;
}

function resolveTabReference(reference, tabs) {
  const needle = string(reference, 'targetId').trim();
  // Raw ids and friendly aliases share one namespace. Gather all exact matches
  // before choosing, rather than giving either namespace silent precedence.
  let matches = new Map(tabs.filter(tab => tab.targetId === needle || tab.id === needle ||
    (tab.label ?? tab.id) === needle || tab.label === needle).map(tab => [tab.targetId, tab]));
  if (!matches.size) {
    const lower = needle.toLowerCase();
    if (lower) matches = new Map(tabs.filter(tab => tab.targetId?.toLowerCase().startsWith(lower)).map(tab => [tab.targetId, tab]));
  }
  if (matches.size > 1) throw new HostError('target_ambiguous', 'Tab reference matches more than one live tab');
  if (!matches.size) throw new HostError('target_missing', 'No matching managed tab; use tabs/open');
  return matches.values().next().value;
}

function canonicalActRequest(request, selected, tabs) {
  let descendants = 0;
  const visit = (item, depth, batched) => {
    object(item, 'batch item');
    if (!ACT_KINDS.includes(item.kind)) throw new HostError('not_implemented', `Unsupported act kind: ${item.kind}`);
    const result = { ...item };
    if (item.targetId !== undefined) {
      const resolved = resolveTabReference(item.targetId, batched ? tabs : [selected]);
      if (resolved.id !== selected.id) invalid('Batch/request targetId must match the selected tab');
      result.targetId = selected.id;
    }
    if (item.kind !== 'batch') {
      // Normalize every leaf on a private copy before executing any batch child.
      if (['click', 'clickCoords'].includes(item.kind)) result.delayMs = bounded(item.delayMs, 5000, 'delayMs', 0);
      if (item.kind === 'press') {
        result.key = string(normalizePressKeyChord(string(item.key, 'key')), 'key');
        result.delayMs = bounded(item.delayMs, 120000, 'delayMs', 0);
      }
      if (item.kind === 'type' && item.slowly) result.delayMs = bounded(item.delayMs, 1000, 'delayMs', 75);
      if (['click', 'type', 'hover', 'scrollIntoView', 'select', 'evaluate'].includes(item.kind) && typeof item.ref === 'string') result.ref = item.ref.trim();
      if (item.kind === 'drag') {
        for (const field of ['startRef', 'endRef']) {
          if (typeof item[field] === 'string') result[field] = item[field].trim();
        }
      }
      if (item.kind === 'fill') {
        if (!Array.isArray(item.fields) || !item.fields.length || item.fields.length > 100) invalid('fill requires 1..100 fields');
        result.fields = item.fields.map((field, index) => {
          const prefix = `fields[${index}]`;
          object(field, prefix);
          const ref = typeof field.ref === 'string' ? field.ref.trim() : '';
          if ((field.ref !== undefined || field.selector === undefined) && !ref) invalid(`${prefix} must include ref`);
          // selector is the existing local extension; refs retain target precedence.
          for (const key of Object.keys(field)) {
            if (!['ref', 'selector', 'type', 'value'].includes(key)) invalid(`${prefix} unsupported field key "${key}"; supported keys are ref, selector, type, value`);
          }
          const target = ref ? { ref } : { selector: string(field.selector, `${prefix} ref or selector`) };
          const type = typeof field.type === 'string' && field.type.trim() ? field.type.trim() : 'text';
          if (field.value === undefined || field.value === null) return { ...target, type };
          if (!['string', 'number', 'boolean'].includes(typeof field.value)) invalid(`${prefix} value must be a string, number, boolean, or null`);
          return { ...target, type, value: field.value };
        });
      }
      if (item.kind === 'wait') {
        for (const field of ['loadState', 'text', 'textGone', 'selector', 'url', 'fn']) {
          if (typeof result[field] !== 'string') continue;
          result[field] = result[field].trim();
          if (!result[field]) delete result[field];
        }
      }
      return result;
    }
    if (depth > 5) invalid('batch nesting exceeds maximum depth of 5');
    if (!Array.isArray(item.actions) || !item.actions.length) invalid('batch requires actions');
    result.actions = [];
    for (const child of item.actions) {
      if (++descendants > 100) invalid('batch exceeds maximum of 100 actions');
      result.actions.push(visit(child, depth + 1, true));
    }
    return result;
  };
  return visit(request, 0, false);
}

// Driver only: native identity, permission, and scheduling belong to the Elixir host.
export class BrowserHost {
  constructor(config) {
    object(config, 'config');
    const driver = config.driver ?? 'managed-host';
    if (!['managed-host', 'remote-cdp'].includes(driver)) invalid('driver must be managed-host or remote-cdp');
    const screenshotResultMode = config.screenshot_result_mode === undefined ? 'image' : config.screenshot_result_mode;
    if (!['image', 'path'].includes(screenshotResultMode)) invalid('screenshot_result_mode must be image or path');
    this.config = {
      driver, profile: string(config.profile, 'profile'), timeout_ms: positive(config.timeout_ms, 'timeout_ms'),
      max_image_bytes: positive(config.max_image_bytes, 'max_image_bytes', MAX_IMAGE_BYTES),
      screenshot_result_mode: screenshotResultMode,
      ...(config.project_root !== undefined ? { project_root: string(config.project_root, 'project_root') } : {}),
    };
    if (driver === 'managed-host') {
      this.config.executable = string(config.executable, 'executable');
      this.config.data_dir = string(config.data_dir, 'data_dir');
      if (!isAbsolute(config.executable) || !isAbsolute(config.data_dir)) invalid('executable and data_dir must be absolute');
    } else {
      let endpoint;
      try { endpoint = new URL(string(config.endpoint, 'endpoint')); } catch { invalid('endpoint must be an absolute CDP URL'); }
      if (!['http:', 'https:', 'ws:', 'wss:'].includes(endpoint.protocol) || !endpoint.hostname) invalid('endpoint requires http, https, ws, or wss');
      this.config.endpoint = endpoint.href;
    }
    if (this.config.project_root !== undefined && !isAbsolute(this.config.project_root)) invalid('project_root must be absolute');
    this.fileTasks = new Set();
    this.fileOwners = new Set();
    this.fileEpoch = 0;
    this.uploadSequence = 0;
    this.generation = 0;
    this.browser = null;
    this.remoteConnection = null;
    this.child = null;
    this.exitPromise = null;
    this.userDataDir = null;
    this.tabs = new Map();
    // Profile-owned aliases survive normal stop/start and are reconciled against
    // the next authoritative page snapshot. Handles remain attachment-owned.
    this.tabAliases = new Map();
    this.identityOwners = new Set();
    this.snapshotDelta = new SnapshotDeltaCache();
    this.tabSequence = 0;
    this.refSequence = 0;
    this.actionSequence = 0;
    this.activeTarget = null;
    this.operation = null;
    this.closed = false;
    this.closing = null;
    this.cleanupPromise = null;
    this.cleanupPending = false;
  }

  // Test diagnostics never enter the wire protocol.
  get diagnosticPid() { return this.child?.pid ?? null; }

  status() {
    for (const tab of this.tabs.values()) if (!tab.page.isClosed() && tab.identityError) throw tab.identityError;
    const remote = this.config.driver === 'remote-cdp';
    return { generation: this.generation, profile: this.config.profile, driver: this.config.driver,
      running: Boolean(!this.cleanupPending && this.browser?.isConnected() && (remote || this.child && this.child.exitCode === null && this.child.signalCode === null)),
      closed: this.closed, cleanup_pending: this.cleanupPending,
      actions: remote ? ACTIONS.filter(action => !['download', 'waitfordownload'].includes(action)) : [...ACTIONS], actKinds: [...ACT_KINDS],
      tabs: [...this.tabs.values()].filter(tab => tab.targetId && !tab.page.isClosed()).slice(0, 50).map(tab => ({ ...this.tabMetadata(tab), url: clip(tab.page.url(), 2048, 8192).text, active: tab.id === this.activeTarget, browserState: { upload: { current: this.uploadState(tab).current } } })),
      tabsTruncated: this.tabs.size > 50 || [...this.tabs.values()].some(tab => !tab.targetId && !tab.page.isClosed()),
      snapshotFormats: ['ai', 'aria'], snapshotRefs: ['role', 'aria', 'ax'], snapshotFrames: ['main', 'iframe-css'],
      snapshotSemantics: 'AI defaults to page-wide public Playwright YAML with aria refs, even with refs=role alone; labels=true, urls=true, mode=efficient, interactive=true, compact=true, explicit depth or selector/frame select native AX role capture unless refs=aria; native role does not recurse into child frames; raw aria: main-document native AX, informational nodes and exact actionable Element refs; not full Browser parity' };
  }

  async invoke(action, args = {}, { timeoutMs = this.config.timeout_ms, generation } = {}) {
    if (!ACTIONS.includes(action)) throw new HostError('not_implemented', `Unsupported browser action: ${action}`);
    if (this.config.driver === 'remote-cdp' && ['download', 'waitfordownload'].includes(action)) {
      throw new HostError('not_implemented', 'Remote CDP downloads require a remote artifact transport; no shared filesystem is assumed');
    }
    object(args, 'args');
    if (args.target !== undefined && args.target !== 'host') invalid('Only target=host is implemented');
    if (args.profile !== undefined && args.profile !== this.config.profile) invalid('Profile does not match this browser host');
    if (args.project_root !== undefined) invalid('project_root is trusted configuration only');
    if (args.screenshot_result_mode !== undefined) invalid('screenshot_result_mode is trusted configuration only');
    if (args.node !== undefined || args.browser !== undefined || args.systemProfile !== undefined || args.into !== undefined) invalid('External browser/profile routing is not implemented');
    positive(timeoutMs, 'timeoutMs', MAX_BROWSER_TIMEOUT_MS);
    if (!Number.isInteger(generation) || generation !== this.generation) throw new HostError('generation_conflict', `Expected generation ${this.generation}`);
    if (this.closed || this.closing) throw new HostError('closed', 'Browser host is closed');
    if (READ_ONLY.has(action)) {
      if (action === 'profiles') return { generation: this.generation, profiles: [{ name: this.config.profile, driver: this.config.driver, running: this.status().running }] };
      if (action === 'doctor') {
        if (this.config.driver === 'remote-cdp') return { ...this.status(), endpointConfigured: true, cleanupScope: 'connection' };
        let executableAvailable = true;
        try { await access(this.config.executable, constants.X_OK); } catch { executableAvailable = false; }
        return { ...this.status(), executableAvailable };
      }
      return this.status();
    }
    if (this.operation) throw new HostError('busy', 'A browser operation is already pending');
    const operation = { aborted: false, dispatched: false, timer: null, task: null, abortReject: null, controller: new AbortController(), deadline: Date.now() + timeoutMs };
    this.operation = operation;
    const interrupted = new Promise((_, reject) => { operation.abortReject = reject; });
    const dialogInterrupted = new Promise((_, reject) => { operation.dialogReject = reject; });
    operation.timer = setTimeout(() => {
      operation.aborted = true;
      operation.reason = 'timeout';
      operation.controller.abort();
      operation.abortReject(new HostError('timeout', 'Browser operation timed out', operation.dispatched));
    }, timeoutMs);
    operation.task = this.dispatch(action, args, operation);
    try {
      const result = await Promise.race([operation.task, interrupted, dialogInterrupted]);
      this.check(operation);
      return withDispatchEvidence({ generation: this.generation, ...result }, operation.dispatched);
    } catch (error) {
      if (error?.class === 'dialog_pending' && !operation.aborted) {
        // Only original actions own suspended work. A dialog response can itself
        // observe the next dialog, but must not retain another wrapper future.
        const tab = operation.tab;
        if (action !== 'dialog') this.retainDialogTask(tab, operation);
        return withDispatchEvidence({ generation: this.generation, ...this.metadata(tab), dialogPending: true,
          browserState: this.browserState(tab) }, operation.dispatched);
      }
      const failure = error instanceof HostError ? error : new HostError(
        operation.aborted || error?.name === 'TimeoutError' ? operation.reason ?? 'timeout' : 'browser_error',
        operation.aborted ? (operation.reason === 'cancelled' ? 'Browser operation cancelled' : 'Browser operation timed out') : String(error?.message ?? error).slice(0, 2000),
        operation.dispatched, error?.cleanup,
      );
      if (operation.aborted || error?.name === 'TimeoutError') {
        operation.aborted = true;
        operation.controller.abort();
        const cleanup = await this.shutdown();
        // Child exit interrupts Playwright calls. Any late continuation checks operation.aborted.
        await within(operation.task.catch(() => {}), 2000).catch(() => { cleanup.cleanup_confirmed = false; cleanup.operation_settled = false; this.closed = true; });
        failure.cleanup = cleanup;
      } else if (action === 'start' && (this.child || this.remoteConnection) && failure.class !== 'cleanup_unconfirmed') {
        failure.cleanup = await this.shutdown();
      }
      // Later validation can fail after an earlier field/action already changed the page.
      failure.dispatched = failure.dispatched === true || operation.dispatched;
      throw failure;
    } finally {
      clearTimeout(operation.timer);
      if (this.operation === operation) this.operation = null;
    }
  }

  check(operation) {
    if (operation.aborted || this.closed) throw new HostError('cancelled', 'Browser operation cancelled', operation.dispatched);
    if (operation.dialogBlocked) throw new HostError('dialog_pending', 'Respond to the pending browser dialog before continuing', operation.dispatched);
  }

  async cancel() {
    const operation = this.operation;
    const hadResource = Boolean(this.child || this.remoteConnection);
    if (operation) {
      operation.aborted = true;
      operation.reason = 'cancelled';
      operation.controller.abort();
      operation.abortReject(new HostError('cancelled', 'Browser operation cancelled', operation.dispatched));
    }
    const cleanup = await this.shutdown();
    if (operation) await within(operation.task.catch(() => {}), 2000).catch(() => { cleanup.cleanup_confirmed = false; cleanup.operation_settled = false; this.closed = true; });
    return withDispatchEvidence({ generation: this.generation, cancelled: Boolean(operation), ...cleanup }, hadResource || Boolean(operation?.dispatched));
  }

  close() {
    if (!this.closing) this.closing = (async () => {
      this.closed = true;
      const cleanup = await this.cancel();
      this.tabAliases.clear();
      this.activeTarget = null;
      return withDispatchEvidence({ closed: true, ...cleanup }, cleanup[RESULT_DISPATCHED]);
    })();
    return this.closing;
  }

  async launch(operation) {
    this.check(operation);
    if (this.config.driver === 'remote-cdp') return this.connectRemote(operation);
    if (this.child || this.cleanupPending) throw new HostError('cleanup_unconfirmed', 'Previous Chromium ownership must be settled before launch', operation.dispatched, { cleanup_confirmed: false });
    await mkdir(this.config.data_dir, { recursive: true });
    this.check(operation);
    const directory = await mkdtemp(join(this.config.data_dir, 'synapsis-browser-'));
    if (operation.aborted || this.closed) { await rm(directory, { recursive: true, force: true }); this.check(operation); }
    this.userDataDir = directory;
    const child = spawn(this.config.executable, [
      '--headless=new', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
      `--user-data-dir=${this.userDataDir}`, '--no-first-run', '--no-default-browser-check',
      '--disable-background-networking', '--disable-component-update', 'about:blank',
    ], { stdio: ['ignore', 'ignore', 'ignore'] });
    this.child = child;
    operation.dispatched = true;
    let spawnError = null;
    this.exitPromise = new Promise((resolve) => {
      child.once('error', (error) => { spawnError = error; resolve({ error: error.code }); });
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    let endpoint;
    while (!endpoint) {
      this.check(operation);
      if (spawnError || child.exitCode !== null || child.signalCode !== null) {
        await this.shutdown();
        throw new HostError('browser_unavailable', 'Owned Chromium exited before CDP readiness', true);
      }
      try {
        const [port, path] = (await readFile(join(this.userDataDir, 'DevToolsActivePort'), 'utf8')).trim().split('\n');
        if (/^\d+$/.test(port) && path?.startsWith('/devtools/browser/')) endpoint = `ws://127.0.0.1:${port}${path}`;
      } catch { /* Owned Chromium has not written its port yet. */ }
      if (!endpoint) await delay(25);
    }
    this.check(operation);
    const browser = await chromium.connectOverCDP(endpoint, { timeout: this.config.timeout_ms });
    if (operation.aborted || this.closed) { await browser.close().catch(() => {}); this.check(operation); }
    this.browser = browser;
    const context = browser.contexts()[0];
    if (!context) throw new HostError('browser_unavailable', 'Chromium did not expose its managed context', true);
    context.setDefaultTimeout(this.config.timeout_ms);
    context.on('page', (page) => this.register(page));
    for (const page of context.pages()) this.register(page);
    await this.readyTabs(operation);
    this.check(operation);
    this.generation++;
    return this.status();
  }

  async connectRemote(operation) {
    if (this.remoteConnection || this.cleanupPending) throw new HostError('cleanup_unconfirmed', 'Previous CDP connection must be settled before reconnecting', operation.dispatched, { cleanup_confirmed: false });
    const connection = { browser: null, promise: null, disconnectPromise: null, settled: false, disconnected: false, cleanupRequested: false };
    this.remoteConnection = connection;
    operation.dispatched = true;
    connection.promise = chromium.connectOverCDP(this.config.endpoint, { timeout: this.config.timeout_ms, noDefaults: true }).then(async browser => {
      connection.browser = browser;
      if (connection.cleanupRequested || operation.aborted || this.closed) {
        await this.disconnectRemote(connection);
        this.check(operation);
        throw new HostError('cancelled', 'CDP connection was closed before adoption', true);
      }
      this.browser = browser;
      const context = browser.contexts()[0];
      if (!context) throw new HostError('browser_unavailable', 'Configured Chromium did not expose a default context', true);
      context.setDefaultTimeout(this.config.timeout_ms);
      context.on('page', page => this.register(page));
      for (const page of context.pages()) this.register(page);
      await this.readyTabs(operation);
      this.check(operation);
      this.generation++;
      return this.status();
    }).catch(error => {
      if (!connection.browser) connection.disconnected = true;
      if (error instanceof HostError) throw error;
      // A Playwright connection error may contain the trusted endpoint URL.
      throw new HostError('browser_unavailable', 'Could not connect to configured remote Chromium; check the configured endpoint and browser availability', true);
    }).finally(() => { connection.settled = true; });
    return connection.promise;
  }

  async disconnectRemote(connection) {
    if (!connection.browser || connection.disconnected) return;
    if (!connection.disconnectPromise) {
      // Public close() disconnects a connectOverCDP client; it does not terminate
      // external Chromium or roll back JavaScript already dispatched there.
      connection.disconnectPromise = connection.browser.close().then(() => {
        connection.disconnected = true;
        if (this.browser === connection.browser) this.browser = null;
      });
    }
    return connection.disconnectPromise;
  }

  async shutdown({ preserveAliases = false } = {}) {
    if (this.cleanupPromise) return this.cleanupPromise;
    this.cleanupPromise = this.performShutdown(preserveAliases);
    try { return await this.cleanupPromise; } finally { this.cleanupPromise = null; }
  }

  async performShutdown(preserveAliases) {
    const child = this.child;
    const browser = this.browser;
    const exitPromise = this.exitPromise;
    const directory = this.userDataDir;
    const connection = this.remoteConnection;
    if (connection) connection.cleanupRequested = true;
    this.cleanupPending = true;
    const identities = [...this.identityOwners];
    for (const owner of identities) owner.controller.abort();
    this.fileEpoch++;
    for (const owner of this.fileOwners) { owner.aborted = true; owner.controller.abort(); }
    const suspended = [];
    for (const tab of this.tabs.values()) {
      this.cancelUpload(tab, 'cancelled');
      if (tab.upload) suspended.push(tab.upload.task);
      this.clearDialogArm(tab);
      this.clearDialogTaskTimers(tab);
      suspended.push(...[...tab.dialogTasks.values()].map(record => record.task));
    }
    this.tabs.clear();
    this.snapshotDelta.clear();
    if (!preserveAliases) {
      this.tabAliases.clear();
      this.activeTarget = null;
    }
    let confirmed = !child;
    if (connection) {
      // A pending connect remains owned. A late connection observes the cleanup
      // request and disconnects before adoption; timeout cannot prove cleanup.
      try {
        if (connection.browser) await within(this.disconnectRemote(connection), 1000);
        await within(connection.promise.catch(() => {}), 1000);
        confirmed = connection.settled && connection.disconnected;
      } catch { confirmed = false; }
    } else if (browser) await within(browser.close(), 1000).catch(() => {});
    if (child) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
      try { await within(exitPromise, 2000); confirmed = true; }
      catch {
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
        try { await within(exitPromise, 2000); confirmed = true; } catch { confirmed = false; }
      }
    }
    let operationSettled = true;
    try { await within(Promise.all([...suspended, ...this.fileTasks, ...identities.map(owner => owner.settled)].map(task => task.catch(() => {}))), 2000); }
    catch { operationSettled = false; confirmed = false; this.closed = true; }
    if (confirmed) {
      this.browser = null;
      this.remoteConnection = null;
      this.cleanupPending = false;
      this.child = null;
      this.exitPromise = null;
      this.userDataDir = null;
      if (directory) await rm(directory, { recursive: true, force: true }).catch(() => {});
    }
    this.generation++;
    return { cleanup_confirmed: confirmed, running: false,
      ...(connection ? { cleanupScope: 'connection', disconnected: confirmed } : {}),
      ...(operationSettled ? {} : { operation_settled: false }) };
  }

  register(page) {
    if (this.closed || this.cleanupPending || page.isClosed()) return null;
    for (const tab of this.tabs.values()) if (tab.page === page) return tab;
    const tab = { page, id: `t${++this.tabSequence}`, registration: this.tabSequence, document: 0, snapshot: 0, refs: new Map(), refMetadata: new Map(), snapshotTruncated: false,
      console: history(), requests: history(), errors: history(), requestIds: new WeakMap(), nextRequest: 0,
      pendingDialogs: [], recentDialogs: [], nextDialog: 0, dialogArm: null, dialogTasks: new Map(), emulation: null, upload: null, recentUploads: [] };
    this.tabs.set(tab.id, tab);
    page.on('framenavigated', (frame) => { if (frame === page.mainFrame()) tab.document++; this.invalidate(tab); });
    page.on('framedetached', () => this.invalidate(tab));
    page.on('close', () => {
      this.cancelUpload(tab, 'cancelled');
      this.clearDialogArm(tab);
      this.clearDialogTaskTimers(tab);
      tab.pendingDialogs = [];
      void tab.emulation?.session.then(session => session.detach()).catch(() => {});
      tab.identityOwner?.controller.abort();
      this.invalidate(tab); this.tabs.delete(tab.targetId ?? tab.id); this.snapshotDelta.clearTab(tab.id);
      // An external close keeps the sticky identity. Only an explicit close
      // retires selection; later implicit actions must not silently redirect.
    });
    page.on('console', message => {
      const location = message.location();
      const entry = { timestamp: new Date().toISOString(), location: { lineNumber: location.lineNumber, columnNumber: location.columnNumber } };
      observed(message.type(), 'type', entry);
      observed(message.text(), 'text', entry);
      const source = clip(location.url);
      entry.location.url = source.text;
      if (source.truncated) entry.truncated = true;
      append(tab.console, entry);
    });
    page.on('pageerror', error => {
      const entry = { timestamp: new Date().toISOString() };
      observed(error.name ?? 'Error', 'name', entry);
      observed(error.message ?? String(error), 'message', entry);
      observed(error.stack ?? '', 'stack', entry);
      append(tab.errors, entry);
    });
    page.on('request', request => {
      const entry = { id: `r${++tab.nextRequest}`, timestamp: new Date().toISOString() };
      observed(request.url(), 'url', entry);
      observed(request.method(), 'method', entry);
      observed(request.resourceType(), 'resourceType', entry);
      tab.requestIds.set(request, entry);
      append(tab.requests, entry);
    });
    page.on('response', response => {
      const entry = tab.requestIds.get(response.request());
      if (entry) { entry.status = response.status(); entry.ok = response.ok(); trimHistory(tab.requests); }
    });
    page.on('requestfinished', request => { const entry = tab.requestIds.get(request); if (entry) entry.finished = true; });
    page.on('requestfailed', request => {
      const entry = tab.requestIds.get(request);
      if (entry) { entry.ok = false; observed(request.failure()?.errorText ?? '', 'failureText', entry); trimHistory(tab.requests); }
    });
    page.on('dialog', dialog => this.observeDialog(tab, dialog));
    const owner = { controller: new AbortController(), task: null, cleanup: null, settled: null };
    tab.identityOwner = owner;
    this.identityOwners.add(owner);
    owner.task = this.discoverTabIdentity(tab, owner);
    // Popup discovery can finish between requests. Retain its rejection for the
    // next operation while immediately owning both work and late session cleanup.
    owner.settled = owner.task.catch(error => { tab.identityError = error; }).then(() => owner.cleanup?.catch(() => {}))
      .finally(() => this.identityOwners.delete(owner));
    tab.identity = owner.task;
    return tab;
  }

  async discoverTabIdentity(tab, owner) {
    const signal = owner.controller.signal;
    let timer; let rejectAbort; let targetId; let failure;
    const interrupted = new Promise((_, reject) => { rejectAbort = reject; });
    const onAbort = () => rejectAbort(new HostError('cancelled', 'Tab identity discovery cancelled'));
    signal.addEventListener('abort', onAbort, { once: true });
    timer = setTimeout(() => {
      rejectAbort(new HostError('timeout', 'Tab identity discovery timed out'));
      owner.controller.abort();
    }, this.config.timeout_ms);
    const current = () => {
      if (signal.aborted || this.closed || this.cleanupPending || tab.page.isClosed() || this.tabs.get(tab.id) !== tab) {
        throw new HostError('cancelled', 'Tab identity discovery cancelled');
      }
    };
    // Keep the attachment future even if cancellation wins, so a late-created
    // session still belongs to cleanup and shutdown cannot claim it settled early.
    const attached = Promise.resolve().then(() => { current(); return tab.page.context().newCDPSession(tab.page); });
    try {
      const session = await Promise.race([attached, interrupted]);
      current();
      const result = await Promise.race([session.send('Target.getTargetInfo'), interrupted]);
      current();
      if (result.targetInfo?.type !== 'page' || typeof result.targetInfo.targetId !== 'string' || !result.targetInfo.targetId.trim()) {
        throw new HostError('browser_error', 'Chromium did not expose a page target identity');
      }
      targetId = result.targetInfo.targetId;
    } catch (error) { failure = error; }
    finally {
      clearTimeout(timer);
      signal.removeEventListener('abort', onAbort);
      owner.cleanup = attached.then(session => session.detach(), () => {});
      try { await within(owner.cleanup, 1000); }
      catch {
        failure = new HostError('cleanup_unconfirmed', 'Tab identity session cleanup could not be confirmed', false,
          { cleanup_confirmed: false, identity_cleanup_confirmed: false });
      }
    }
    if (failure) throw failure;
    current();
    if ([...this.tabs.values()].some(other => other !== tab && other.targetId === targetId)) {
      throw new HostError('browser_error', 'Chromium page target identity is already registered');
    }
    tab.targetId = targetId;
    // Preserve registration order when asynchronous discoveries finish out of
    // order. Raw keys also keep public diagnostic lookup aligned with metadata.
    this.tabs.delete(tab.id);
    this.tabs.set(targetId, tab);
    this.tabs = new Map([...this.tabs].sort(([, left], [, right]) => left.registration - right.registration));
    return targetId;
  }

  async readyTabs(operation) {
    const context = this.browser.contexts()[0];
    for (;;) {
      this.check(operation);
      const pages = context.pages().filter(page => !page.isClosed());
      const tabs = pages.map(page => this.register(page));
      const identities = await Promise.allSettled(tabs.map(tab => tab.identity));
      this.check(operation);
      const latest = context.pages().filter(page => !page.isClosed());
      // Page events and CDP identity discovery can arrive in different orders.
      // Reconcile only after every member of a complete, still-current public
      // page snapshot is ready; retry a changed snapshot before retiring aliases.
      if (latest.length !== pages.length || latest.some(page => !pages.includes(page))) continue;
      for (const identity of identities) if (identity.status === 'rejected') throw identity.reason;
      this.reconcileTabAliases(tabs);
      return tabs.sort((left, right) => left.registration - right.registration);
    }
  }

  rememberTabAlias(tab) {
    this.tabAliases.set(tab.targetId, { id: tab.id, url: tab.page.url(),
      ...(tab.label === undefined ? {} : { label: tab.label }) });
  }

  reconcileTabAliases(tabs) {
    // A new CDP attachment creates fresh Page wrappers with provisional aliases.
    // Restore metadata by exact raw identity before finding replacements; retain
    // their new refs, histories, dialogs, uploads and immutable registration order.
    for (const tab of tabs) {
      const entry = this.tabAliases.get(tab.targetId);
      if (!entry) continue;
      tab.id = entry.id;
      if (entry.label !== undefined) tab.label = entry.label;
    }
    const liveIds = new Set(tabs.map(tab => tab.targetId));
    const stale = [...this.tabAliases].filter(([targetId]) => !liveIds.has(targetId));
    const candidates = tabs.filter(tab => !this.tabAliases.has(tab.targetId));
    for (const [oldTargetId, entry] of stale) {
      const url = entry.url?.trim();
      // Match the pinned target-id.ts rules: a one-for-one replacement may
      // change URL; larger sets require an exact, unique trimmed-URL bucket.
      const candidate = stale.length === 1 && candidates.length === 1 ? candidates[0]
        : url && stale.filter(([, other]) => other.url?.trim() === url).length === 1
          && candidates.filter(tab => tab.page.url().trim() === url).length === 1
          ? candidates.find(tab => tab.page.url().trim() === url) : undefined;
      if (!candidate) continue;
      // Reuse the friendly identity only. The replacement keeps its own page,
      // refs, document/snapshot epochs, dialogs, emulation, and upload owners.
      this.snapshotDelta.clearTab(entry.id);
      this.snapshotDelta.clearTab(candidate.id);
      candidate.id = entry.id;
      if (entry.label !== undefined) candidate.label = entry.label;
      this.tabAliases.set(candidate.targetId, entry);
      this.tabAliases.delete(oldTargetId);
      // activeTarget is the canonical friendly identity, so a selected stale
      // target now names this replacement without resolving a movable label.
    }
    for (const targetId of this.tabAliases.keys()) if (!liveIds.has(targetId)) this.tabAliases.delete(targetId);
    for (const tab of tabs) this.rememberTabAlias(tab);
    this.tabs = new Map([...this.tabs].sort(([, left], [, right]) => left.registration - right.registration));
  }

  invalidate(tab) {
    for (const handle of tab.refs.values()) void handle.dispose().catch(() => {});
    tab.refs.clear();
    tab.refMetadata.clear();
    tab.snapshotTruncated = false;
    tab.snapshot++;
  }

  tab(args, tabs) {
    if (args.targetId !== undefined && args.targetId !== null) return resolveTabReference(args.targetId, tabs);
    // Only a fresh connection or an explicit close permits first-live fallback.
    // An existing sticky identity is canonical, not user alias input.
    const tab = this.activeTarget === null ? tabs[0] : tabs.find(tab => tab.id === this.activeTarget);
    if (!tab) throw new HostError('target_missing', 'No matching managed tab; use tabs/open');
    return tab;
  }

  metadata(tab) { return { targetId: tab.targetId, url: tab.page.url() }; }
  tabMetadata(tab) {
    return { ...this.metadata(tab), tabId: tab.id, suggestedTargetId: tab.label ?? tab.id,
      ...(tab.label === undefined ? {} : { label: tab.label }) };
  }

  async dispatch(action, args, operation) {
    this.check(operation);
    if (action === 'start') {
      if (this.status().running) { await this.readyTabs(operation); return this.status(); }
      if (this.child || this.remoteConnection || this.cleanupPending) {
        operation.dispatched = true;
        const cleanup = await this.shutdown();
        this.check(operation);
        if (!cleanup.cleanup_confirmed) throw new HostError('cleanup_unconfirmed', 'Previous browser resource cleanup is unconfirmed; refusing replacement', true, cleanup);
      }
      return this.launch(operation);
    }
    if (action === 'stop') {
      operation.dispatched = Boolean(this.child || this.remoteConnection);
      const cleanup = await this.shutdown({ preserveAliases: true });
      return { stopped: cleanup.cleanup_confirmed, ...cleanup };
    }
    if (!this.status().running) throw new HostError('not_running', 'Browser is dormant; call start explicitly');
    if (action === 'tabs') {
      const tabs = [];
      for (const tab of await this.readyTabs(operation)) {
        // Route a newly arriving dialog through the normal intervention receipt.
        operation.tab = tab;
        if (tab.pendingDialogs.length || tab.dialogTasks.size >= PENDING_ACTION_LIMIT) {
          tabs.push({ ...this.tabMetadata(tab), title: null,
            titleUnavailable: tab.pendingDialogs.length ? 'dialog_pending' : 'pending_action_capacity',
            browserState: this.browserState(tab), active: tab.id === this.activeTarget });
          continue;
        }
        const title = await tab.page.title();
        this.check(operation);
        tabs.push({ ...this.tabMetadata(tab), browserState: this.browserState(tab), title: title.slice(0, 4096), active: tab.id === this.activeTarget });
      }
      return { tabs };
    }
    if (action === 'open') {
      const label = normalizedTabLabel(args.label);
      const targetUrl = url(args.targetUrl ?? args.url ?? 'about:blank');
      this.check(operation);
      operation.dispatched = true;
      const page = await this.browser.contexts()[0].newPage();
      this.check(operation);
      const tab = this.register(page);
      operation.tab = tab;
      await tab.identity;
      this.check(operation);
      await page.goto(targetUrl, { waitUntil: 'domcontentloaded' });
      this.check(operation);
      if (label !== undefined) {
        for (const entry of this.tabAliases.values()) if (entry.label === label) delete entry.label;
        for (const previous of this.tabs.values()) {
          if (previous !== tab && !previous.page.isClosed() && previous.label === label) delete previous.label;
        }
        tab.label = label;
      }
      // Dedicated open reserves its fresh alias before any later reconciliation.
      this.rememberTabAlias(tab);
      this.activeTarget = tab.id;
      return this.tabMetadata(tab);
    }
    const liveTabs = await this.readyTabs(operation);
    const tab = this.tab(args, liveTabs);
    operation.tab = tab;
    // Selecting a page does not bring it to the foreground. Focus commits only
    // after success; dedicated close preserves selection of a background tab.
    if (!['close', 'focus'].includes(action)) this.activeTarget = tab.id;
    if (['console', 'requests', 'errors'].includes(action)) return this.observations(tab, action, args, operation);
    if (action === 'dialog') return this.dialog(tab, args, operation);
    if (tab.dialogTasks.size >= PENDING_ACTION_LIMIT && action !== 'close') {
      return { ...this.metadata(tab), actionPending: true, overloaded: true, browserState: this.browserState(tab) };
    }
    if (tab.pendingDialogs.length && !['close', 'focus'].includes(action)) {
      return { ...this.metadata(tab), dialogPending: true, browserState: this.browserState(tab) };
    }
    if (['pdf', 'download', 'waitfordownload', 'upload'].includes(action)) return this.fileTask(operation, () => action === 'upload' ? this.upload(tab, args, operation) : this.saveFile(tab, action, args, operation));
    if (action === 'text') return this.text(tab, args, operation);
    if (action === 'emulate') return this.emulate(tab, args, operation);
    if (action === 'focus') { operation.dispatched = true; await tab.page.bringToFront(); this.check(operation); this.activeTarget = tab.id; return this.metadata(tab); }
    if (action === 'close') {
      operation.dispatched = true; await tab.page.close(); await tab.upload?.task; this.check(operation);
      this.tabAliases.delete(tab.targetId);
      if (this.activeTarget === tab.id) this.activeTarget = null;
      return { targetId: tab.targetId, closed: true };
    }
    if (action === 'navigate') {
      const targetUrl = url(args.targetUrl ?? args.url);
      return this.fileTask(operation, () => this.navigate(tab, targetUrl, args, operation));
    }
    if (action === 'snapshot') return args.labels === true
      ? this.fileTask(operation, () => this.snapshot(tab, args, operation))
      : this.snapshot(tab, args, operation);
    if (action === 'screenshot') return this.screenshot(tab, args, operation);
    if (action === 'act') {
      const request = prepareActRequest(canonicalActRequest(object(args.request ?? args, 'request'), tab, liveTabs));
      const outcome = await this.fileTask(operation, () => this.actWithDownloads(tab, request, operation));
      this.check(operation);
      const result = { ...this.metadata(tab), ...outcome, ...(tab.upload ? { browserState: this.browserState(tab) } : {}) };
      if (result.aborted?.reason === 'navigation' || result.results?.some(entry => entry.navigated === true) === true) {
        return this.appendNavigatedPageState(tab, result, operation);
      }
      return result;
    }
    throw new HostError('not_implemented', `Unsupported browser action: ${action}`);
  }

  async actWithDownloads(tab, request, operation) {
    // OpenClaw488631c pw-tools-core.interactions.execution.ts and
    // pw-session-downloads.ts: one capture surrounds the entire root action.
    // Descendant batches share it; every observed save starts in event order.
    const pending = [];
    let lastEventAt;
    let detached = false;
    let finishWait = null;
    const detach = () => {
      detached = true;
      tab.page.off('download', onDownload);
      tab.page.off('close', detach);
      tab.page.off('dialog', onDialog);
      operation.controller.signal.removeEventListener('abort', detach);
      finishWait?.();
    };
    const onDownload = download => {
      lastEventAt = Date.now();
      const task = (async () => {
        this.checkFile(operation);
        if (this.config.driver === 'remote-cdp') throw new HostError('not_implemented', 'Remote CDP downloads require a remote artifact transport; no shared filesystem is assumed', true);
        // Download outputs include blob/data URLs. Preserve the actual source
        // string instead of applying the navigation-target URL validator.
        const downloadUrl = string(download.url(), 'Download URL');
        const saved = await this.saveFile(tab, 'act', {}, operation, download);
        return { url: downloadUrl, suggestedFilename: saved.suggestedFilename,
          path: saved.path, bytes: saved.bytes, sha256: saved.sha256 };
      })();
      pending.push(task);
      // A save may reject while another descendant is still executing. Own its
      // rejection immediately, then join every save before returning or throwing.
      void task.catch(() => {});
      finishWait?.();
    };
    const onDialog = () => { if (operation.dialogBlocked) detach(); };
    const waitForEvent = timeout => {
      if (detached || timeout <= 0) return Promise.resolve();
      return new Promise(resolveWait => {
        const finish = () => {
          clearTimeout(timer);
          if (finishWait === finish) finishWait = null;
          resolveWait();
        };
        const timer = setTimeout(finish, timeout);
        timer.unref();
        finishWait = finish;
      });
    };
    const needsGrace = action => action.kind === 'batch'
      ? action.actions.some(needsGrace)
      : action.kind === 'wait' ? Boolean(action.fn) : !['close', 'resize'].includes(action.kind);
    tab.page.on('download', onDownload);
    tab.page.once('close', detach);
    tab.page.on('dialog', onDialog);
    operation.controller.signal.addEventListener('abort', detach, { once: true });
    let outcome;
    let actionFailed = false;
    let actionError;
    try {
      if (operation.controller.signal.aborted) detach();
      try { outcome = await this.act(tab, request, operation); }
      catch (error) { actionFailed = true; actionError = error; }
      // This event window never extends the original invocation deadline.
      const deadline = Math.min(operation.deadline, Date.now() + ACTION_DOWNLOAD_DRAIN_MS);
      const remaining = () => Math.max(0, deadline - Date.now());
      if (!pending.length && needsGrace(request)) {
        await waitForEvent(Math.min(ACTION_DOWNLOAD_GRACE_MS, remaining()));
      }
      while (!detached && lastEventAt !== undefined) {
        const quiet = Math.min(ACTION_DOWNLOAD_GRACE_MS - (Date.now() - lastEventAt), remaining());
        if (quiet <= 0) break;
        await waitForEvent(quiet);
      }
    } catch (error) {
      actionFailed = true;
      actionError = error;
    } finally {
      // Fix event ownership before awaiting file I/O, including action errors.
      // Slow saves cannot collect unrelated downloads after the action window.
      detach();
    }
    const settled = await Promise.allSettled(pending);
    const failed = settled.find(result => result.status === 'rejected');
    // The reference gives a download-save error precedence over action errors.
    // allSettled additionally keeps later saves owned until they have finished.
    if (failed) throw failed.reason;
    if (actionFailed) throw actionError;
    return { ...outcome, ...(settled.length ? { downloads: settled.map(result => result.value) } : {}) };
  }

  async navigate(tab, targetUrl, args, operation) {
    const timeout = args.timeoutMs === undefined ? this.config.timeout_ms : positive(args.timeoutMs, 'timeoutMs');
    const deadline = Math.min(operation.deadline, Date.now() + timeout);
    const waiter = this.eventWaiter(tab.page, 'download', operation, deadline);
    try {
      try {
        this.checkFile(operation);
        operation.dispatched = true;
        // Actual committed frame events invalidate refs. An attachment leaves
        // the original document and its retained handles unchanged.
        await tab.page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: Math.max(1, deadline - Date.now()) });
      } catch (error) {
        this.checkFile(operation);
        // OpenClaw488631c pw-session-downloads.ts recognizes these two engine
        // signals. A genuine download event is additionally required; the
        // navigation itself is never retried or treated as a file by message alone.
        const message = String(error?.message ?? error).toLowerCase();
        if (!message.includes('download is starting') &&
            !(message.includes('net::err_aborted') && message.includes(targetUrl.toLowerCase()))) throw error;
        let download;
        try { download = await waiter.promise; }
        catch (captureError) { if (captureError?.class === 'timeout') throw error; throw captureError; }
        this.checkFile(operation);
        if (this.config.driver === 'remote-cdp') throw new HostError('not_implemented', 'Remote CDP downloads require a remote artifact transport; no shared filesystem is assumed', true);
        const downloadUrl = url(download.url() || targetUrl);
        // Navigation has no model-selected output path. Reuse the existing
        // project-local staging, hash and atomic publication owner.
        const saved = await this.saveFile(tab, 'navigate', {}, operation, download);
        return { ...this.metadata(tab), url: downloadUrl, documentGeneration: tab.document,
          download: { url: downloadUrl, suggestedFilename: saved.suggestedFilename,
            path: saved.path, bytes: saved.bytes, sha256: saved.sha256 } };
      }
      waiter.cancel();
      this.checkFile(operation);
      const result = { ...this.metadata(tab), documentGeneration: tab.document };
      return await this.appendNavigatedPageState(tab, result, operation);
    } finally {
      waiter.cancel();
    }
  }

  async appendNavigatedPageState(tab, result, operation) {
    try {
      // Keep feedback on this exact tab and invocation. The ordinary snapshot
      // path adopts real refs without renewing the navigation's deadline.
      const pageState = { generation: this.generation, ...await this.snapshot(tab, { mode: 'efficient' }, operation) };
      return { ...result, pageState };
    } catch (error) {
      this.check(operation);
      if (['AbortError', 'TimeoutError'].includes(error?.name) ||
          ['cancelled', 'timeout', 'cleanup_unconfirmed'].includes(error?.class) ||
          error?.cleanup?.cleanup_confirmed === false) throw error;
      // Navigation already succeeded. Missing optional feedback must remain
      // explicit instead of presenting the mutation as safe to repeat.
      return { ...result, pageStateUnavailable: 'Page snapshot unavailable. Use action=snapshot to read the page.' };
    }
  }

  observations(tab, action, args, operation) {
    const limit = args.limit === undefined ? 50 : positive(args.limit, 'limit', HISTORY_LIMIT);
    if (args.clear !== undefined && typeof args.clear !== 'boolean') invalid('clear must be boolean');
    if (args.level !== undefined && !['debug', 'log', 'info', 'warn', 'warning', 'error'].includes(args.level)) invalid('Unsupported console level');
    const filter = args.filter === undefined ? '' : string(args.filter, 'filter').trim();
    const log = tab[action];
    const matching = log.entries.filter(entry =>
      (action !== 'console' || args.level === undefined || priority(entry.type) >= priority(args.level)) &&
      (action !== 'requests' || !filter || entry.url.includes(filter) || entry.resourceType.includes(filter)));
    const key = action === 'console' ? 'messages' : action;
    let entries = matching.slice(-limit);
    while (entries.length && Buffer.byteLength(JSON.stringify(entries)) > OBSERVATION_BYTES) entries = entries.slice(1);
    const result = { ...this.metadata(tab), [key]: entries, total: matching.length, returned: entries.length, limit,
      truncated: log.dropped > 0 || entries.length < matching.length || entries.some(entry => entry.truncated),
      dropped: log.dropped, omitted: matching.length - entries.length, cleared: args.clear === true };
    if (args.clear === true) {
      operation.dispatched = true;
      tab[action] = history();
      if (action === 'requests') tab.requestIds = new WeakMap();
    }
    return result;
  }

  async text(tab, args, operation) {
    // Match the pinned article/main/body preference and visible innerText semantics.
    if (args.maxChars !== undefined && (!Number.isSafeInteger(args.maxChars) || args.maxChars <= 0)) invalid('maxChars must be a positive safe integer');
    const maxChars = Math.min(args.maxChars ?? 40000, 40000);
    let selector = args.selector === undefined ? null : string(args.selector, 'selector');
    if (!selector) {
      selector = 'body';
      for (const candidate of ['article', 'main']) {
        const count = await tab.page.locator(candidate).count();
        this.check(operation);
        if (count) { selector = candidate; break; }
      }
    }
    const text = await tab.page.locator(selector).first().innerText();
    this.check(operation);
    const shaped = clip(text, maxChars, OBSERVATION_BYTES);
    // JSON escaping also consumes the canonical string budget after projection.
    let value = shaped.text;
    while (Buffer.byteLength(JSON.stringify(value)) > OBSERVATION_BYTES) value = clip(value, Math.floor(value.length * 0.9), OBSERVATION_BYTES).text;
    return { ...this.metadata(tab), ok: true, text: value, truncated: shaped.truncated || value.length < text.length };
  }

  async emulationSession(tab, operation) {
    tab.emulation ??= { session: tab.page.context().newCDPSession(tab.page), metrics: null };
    const session = await tab.emulation.session;
    this.check(operation);
    return session;
  }

  async viewport(tab, viewport, operation) {
    // Keep device metrics for an equal viewport; release them before resizing.
    const metrics = tab.emulation?.metrics;
    if (metrics && (metrics.width !== viewport.width || metrics.height !== viewport.height)) {
      const session = await this.emulationSession(tab, operation);
      this.check(operation);
      operation.dispatched = true;
      await session.send('Emulation.clearDeviceMetricsOverride');
      this.check(operation);
      tab.emulation.metrics = null;
    }
    operation.dispatched = true;
    await tab.page.setViewportSize(viewport);
    this.check(operation);
  }

  async emulate(tab, args, operation) {
    const fields = ['device', 'colorScheme', 'timezoneId', 'locale'];
    const unsupported = Object.keys(args).filter(key => ![...fields, 'targetId', 'target', 'profile'].includes(key));
    if (unsupported.length) invalid(`Unsupported emulation options: ${unsupported.join(', ')}`);
    const requested = fields.filter(field => args[field] !== undefined);
    if (!requested.length) invalid('emulate requires device, colorScheme, timezoneId, or locale');
    for (const field of requested) string(args[field], field);
    if (args.colorScheme !== undefined && !['dark', 'light', 'no-preference', 'none'].includes(args.colorScheme)) invalid('colorScheme must be dark|light|no-preference|none');
    if (args.device !== undefined && !Object.hasOwn(devices, args.device)) invalid(`Unknown device: ${args.device}`);
    const applied = [];
    for (const field of requested) {
      this.check(operation);
      if (field === 'colorScheme') {
        operation.dispatched = true;
        await tab.page.emulateMedia({ colorScheme: args.colorScheme === 'none' ? null : args.colorScheme });
      } else {
        const session = await this.emulationSession(tab, operation);
        if (field === 'device') {
          const descriptor = devices[args.device];
          const screen = descriptor.screen ?? descriptor.viewport;
          const landscape = screen.width > screen.height;
          await this.viewport(tab, { ...descriptor.viewport }, operation);
          operation.dispatched = true;
          await session.send('Emulation.setUserAgentOverride', { userAgent: descriptor.userAgent });
          this.check(operation);
          await session.send('Emulation.setDeviceMetricsOverride', {
            mobile: descriptor.isMobile, ...descriptor.viewport, deviceScaleFactor: descriptor.deviceScaleFactor,
            screenWidth: screen.width, screenHeight: screen.height,
            screenOrientation: descriptor.isMobile && !landscape ? { angle: 0, type: 'portraitPrimary' } : { angle: descriptor.isMobile ? 90 : 0, type: 'landscapePrimary' },
          });
          this.check(operation);
          tab.emulation.metrics = { ...descriptor.viewport };
          await session.send('Emulation.setTouchEmulationEnabled', { enabled: descriptor.hasTouch });
          this.check(operation);
          tab.emulation.touch = descriptor.hasTouch;
        } else {
          operation.dispatched = true;
          await session.send(field === 'timezoneId' ? 'Emulation.setTimezoneOverride' : 'Emulation.setLocaleOverride',
            field === 'timezoneId' ? { timezoneId: args.timezoneId } : { locale: args.locale });
        }
      }
      this.check(operation);
      applied.push(field);
    }
    return { ...this.metadata(tab), ok: true, applied };
  }

  browserState(tab) {
    const record = ({ dialog, ...entry }) => entry;
    return { upload: this.uploadState(tab), dialogs: { pending: tab.pendingDialogs.map(record), recent: tab.recentDialogs.map(record) },
      pendingActions: [...tab.dialogTasks.values()].map(({ id, deadline }) => ({ id, deadline })),
      pendingActionLimit: PENDING_ACTION_LIMIT, capacityAvailable: Math.max(0, PENDING_ACTION_LIMIT - tab.dialogTasks.size) };
  }

  retainDialogTask(tab, operation) {
    if (tab.dialogTasks.has(operation.task)) return;
    const record = { id: `a${++this.actionSequence}`, task: operation.task, operation,
      deadline: new Date(Date.now() + PENDING_ACTION_LIFETIME_MS).toISOString(), timer: null };
    tab.dialogTasks.set(operation.task, record);
    record.timer = setTimeout(() => {
      if (tab.dialogTasks.get(operation.task) !== record) return;
      // A timed-out suspended action cannot be abandoned while Chromium lives.
      // cancel() fences any current operation and waits for actual owned exit.
      operation.aborted = true;
      operation.controller.abort();
      void this.cancel().catch(() => { this.closed = true; this.cleanupPending = true; });
    }, PENDING_ACTION_LIFETIME_MS);
    record.timer.unref();
    void operation.task.catch(() => {}).finally(() => {
      clearTimeout(record.timer);
      if (tab.dialogTasks.get(operation.task) === record) tab.dialogTasks.delete(operation.task);
    });
  }

  clearDialogTaskTimers(tab) {
    for (const record of tab.dialogTasks.values()) {
      clearTimeout(record.timer);
      record.operation.aborted = true;
      record.operation.controller.abort();
    }
  }

  clearDialogArm(tab) {
    if (tab.dialogArm) clearTimeout(tab.dialogArm.timer);
    tab.dialogArm = null;
  }

  observeDialog(tab, dialog) {
    const entry = { id: `d${++tab.nextDialog}`, type: dialog.type(), openedAt: new Date().toISOString(), dialog };
    observed(dialog.message(), 'message', entry);
    if (entry.type === 'prompt') observed(dialog.defaultValue(), 'defaultValue', entry);
    tab.pendingDialogs.push(entry);
    const arm = tab.dialogArm;
    this.clearDialogArm(tab);
    if (arm && arm.expiresAt > Date.now()) {
      void this.settleDialog(tab, entry, arm, 'armed').catch(error => {
        // Keep failed responses pending and visible, instead of silently dismissing.
        entry.responseError = clip(String(error.message)).text;
        this.interruptForDialog(tab);
      });
    } else this.interruptForDialog(tab);
  }

  interruptForDialog(tab) {
    const operation = this.operation;
    if (operation?.tab === tab && !operation.aborted) {
      operation.dialogBlocked = true;
      operation.dialogReject(new HostError('dialog_pending', 'Browser action requires a dialog response', operation.dispatched));
    }
  }

  async settleDialog(tab, entry, response, closedBy) {
    if (response.accept) await entry.dialog.accept(response.promptText);
    else await entry.dialog.dismiss();
    tab.pendingDialogs = tab.pendingDialogs.filter(pending => pending !== entry);
    const { dialog, ...record } = entry;
    tab.recentDialogs.push({ ...record, closedAt: new Date().toISOString(), closedBy });
    if (tab.recentDialogs.length > 10) tab.recentDialogs.shift();
  }

  async dialog(tab, args, operation) {
    if (typeof args.accept !== 'boolean') invalid('accept must be boolean');
    if (args.promptText !== undefined && typeof args.promptText !== 'string') invalid('promptText must be a string');
    if (args.dialogId !== undefined) string(args.dialogId, 'dialogId');
    const timeoutMs = args.timeoutMs === undefined ? 120000 : positive(args.timeoutMs, 'timeoutMs');
    const pending = args.dialogId === undefined ? tab.pendingDialogs[0] : tab.pendingDialogs.find(entry => entry.id === args.dialogId);
    if (args.dialogId !== undefined && !pending) invalid('The requested dialogId is not pending');
    if (pending) {
      this.clearDialogArm(tab);
      operation.dispatched = true;
      await this.settleDialog(tab, pending, args, 'handled');
      this.check(operation);
      // The original page function may need a later act to resolve its Promise.
      // Its separate bounded lifetime remains owned by retainDialogTask().
      return { ...this.metadata(tab), ok: true, armed: false, dialogId: pending.id, browserState: this.browserState(tab) };
    }
    this.clearDialogArm(tab);
    operation.dispatched = true;
    const arm = { accept: args.accept, ...(args.promptText !== undefined ? { promptText: args.promptText } : {}), expiresAt: Date.now() + timeoutMs };
    arm.timer = setTimeout(() => { if (tab.dialogArm === arm) tab.dialogArm = null; }, timeoutMs);
    arm.timer.unref();
    tab.dialogArm = arm;
    return { ...this.metadata(tab), ok: true, armed: true, expiresAt: new Date(arm.expiresAt).toISOString(), browserState: this.browserState(tab) };
  }

  fileTask(operation, callback) {
    operation.fileEpoch = this.fileEpoch;
    this.fileOwners.add(operation);
    const task = Promise.resolve().then(callback);
    this.fileTasks.add(task);
    void task.then(() => { this.fileTasks.delete(task); this.fileOwners.delete(operation); }, () => { this.fileTasks.delete(task); this.fileOwners.delete(operation); });
    return task;
  }

  checkFile(operation) {
    this.check(operation);
    if (operation.fileEpoch !== this.fileEpoch || this.cleanupPending) throw new HostError('cancelled', 'Browser file operation cancelled', operation.dispatched);
  }

  async projectRoot(operation) {
    if (!this.config.project_root) invalid('File actions require trusted absolute project_root');
    const root = await realpath(this.config.project_root);
    this.checkFile(operation);
    if (!(await lstat(root)).isDirectory()) invalid('project_root must be a directory');
    this.checkFile(operation);
    return root;
  }

  beneath(root, path) {
    const tail = relative(root, path);
    if (tail === '..' || tail.startsWith(`..${sep}`) || isAbsolute(tail)) invalid('File path must remain beneath project_root');
    return path;
  }

  async outputPath(root, requested, extension, operation) {
    let path;
    if (requested !== undefined) path = this.beneath(root, resolve(root, string(requested, 'path')));
    else path = join(root, '.synapsis', 'browser-files', `${randomUUID()}.${extension}`);
    if (path === root) invalid('Output must name a file beneath project_root');
    // Walk one ancestor at a time, checking the real destination before creating
    // children. Browser-suggested filenames never participate in path routing.
    let parent = root;
    for (const component of relative(root, dirname(path)).split(sep).filter(Boolean)) {
      this.checkFile(operation);
      const next = join(parent, component);
      operation.dispatched = true;
      try { await mkdir(next); } catch (error) { if (error.code !== 'EEXIST') throw error; }
      this.checkFile(operation);
      parent = this.beneath(root, await realpath(next));
      this.checkFile(operation);
      if (!(await lstat(parent)).isDirectory()) invalid('Output parent must be a directory');
    }
    path = join(parent, basename(path));
    await this.regularOutput(path, operation);
    return path;
  }

  async regularOutput(path, operation) {
    try {
      const info = await lstat(path);
      this.checkFile(operation);
      if (!info.isFile() || info.isSymbolicLink()) invalid('Output must be a regular file');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.checkFile(operation);
  }

  // Unlike a raced waitForEvent promise, this waiter can remove all of its
  // native listeners immediately on cancellation or an unsuccessful click.
  eventWaiter(page, event, operation, deadline) {
    let finish;
    const promise = new Promise((resolveEvent, reject) => {
      const onEvent = value => finish(null, value);
      const onClose = () => finish(new HostError('target_missing', 'Browser tab closed', operation.dispatched));
      const onAbort = () => finish(new HostError('cancelled', 'Browser file operation cancelled', operation.dispatched));
      const timer = setTimeout(() => finish(new HostError('timeout', `Browser ${event} wait timed out`, operation.dispatched)), Math.max(1, deadline - Date.now()));
      timer.unref();
      finish = (error, value) => {
        clearTimeout(timer); page.off(event, onEvent); page.off('close', onClose); operation.controller.signal.removeEventListener('abort', onAbort);
        error ? reject(error) : resolveEvent(value);
      };
      page.on(event, onEvent); page.once('close', onClose); operation.controller.signal.addEventListener('abort', onAbort, { once: true });
      if (operation.controller.signal.aborted) onAbort();
    });
    void promise.catch(() => {});
    return { promise, cancel: () => finish(new HostError('cancelled', 'Browser event waiter cancelled', operation.dispatched)) };
  }

  async saveFile(tab, action, args, operation, capturedDownload = null) {
    const root = await this.projectRoot(operation);
    const timeout = args.timeoutMs === undefined ? this.config.timeout_ms : positive(args.timeoutMs, 'timeoutMs');
    if (action === 'download') { string(args.ref, 'ref'); string(args.path, 'path'); }
    const target = action === 'download' ? await this.target(tab, { ref: args.ref }, operation) : null;
    this.checkFile(operation);
    const output = await this.outputPath(root, args.path, action === 'pdf' ? 'pdf' : 'download', operation);
    this.checkFile(operation);
    operation.dispatched = true;
    const staging = await mkdtemp(join(dirname(output), '.browser-stage-'));
    let waiter;
    try {
      this.checkFile(operation);
      const temporary = join(staging, 'artifact');
      let suggestedFilename;
      if (action === 'pdf') {
        operation.dispatched = true;
        const bytes = await tab.page.pdf({ printBackground: true });
        this.checkFile(operation);
        const file = await open(temporary, 'wx', 0o600);
        try { this.checkFile(operation); await file.writeFile(bytes); } finally { await file.close(); }
      } else {
        this.checkFile(operation);
        operation.dispatched = true;
        let download = capturedDownload;
        if (!download) {
          waiter = this.eventWaiter(tab.page, 'download', operation, Date.now() + timeout);
          if (target) { await target.click({ timeout }); this.checkFile(operation); }
          download = await waiter.promise;
        }
        this.checkFile(operation);
        suggestedFilename = clip(download.suggestedFilename().split(/[\\/]/).at(-1).replace(/[\x00-\x1f\x7f]/g, '_'), 255, 1024).text;
        await download.saveAs(temporary);
      }
      this.checkFile(operation);
      const hash = createHash('sha256');
      let bytes = 0;
      const stream = createReadStream(temporary, { signal: operation.controller.signal });
      for await (const chunk of stream) { this.checkFile(operation); bytes += chunk.length; hash.update(chunk); }
      this.checkFile(operation);
      // Recheck actual parent ancestry immediately before the atomic publish.
      this.beneath(root, await realpath(dirname(output)));
      this.checkFile(operation);
      await this.regularOutput(output, operation);
      await rename(temporary, output);
      this.checkFile(operation);
      return { ...this.metadata(tab), ok: true, path: output, bytes, sha256: hash.digest('hex'),
        ...(action === 'pdf' ? { mimeType: 'application/pdf' } : { suggestedFilename }) };
    } finally {
      waiter?.cancel();
      await rm(staging, { recursive: true, force: true });
    }
  }

  uploadState(tab) {
    const publicRecord = record => record ? { id: record.id, state: record.state, deadline: record.deadline, fileCount: record.fileCount,
      ...(record.error ? { error: record.error } : {}) } : null;
    return { current: publicRecord(tab.upload), recent: tab.recentUploads.map(publicRecord), maxFiles: 32, maxBytes: MAX_UPLOAD_BYTES };
  }

  cancelUpload(tab, reason) {
    const record = tab.upload;
    if (!record || ['completed', 'failed', 'expired', 'superseded', 'cancelled'].includes(record.state)) return;
    record.state = reason;
    record.operation.aborted = true;
    record.operation.controller.abort();
    record.waiter?.cancel();
    clearTimeout(record.timer);
  }

  async upload(tab, args, operation) {
    const timeout = args.timeoutMs === undefined ? this.config.timeout_ms : positive(args.timeoutMs, 'timeoutMs');
    const deadline = Date.now() + timeout;
    if (!Array.isArray(args.paths) || args.paths.length < 1 || args.paths.length > 32) invalid('paths must contain 1..32 files');
    if ([args.ref, args.inputRef, args.element].filter(value => value !== undefined).length > 1) invalid('Choose only one of ref, inputRef, or element');
    const root = await this.projectRoot(operation);
    const payloads = [];
    let total = 0;
    for (const requested of args.paths) {
      const path = this.beneath(root, resolve(root, string(requested, 'paths entry')));
      const actual = this.beneath(root, await realpath(path));
      this.checkFile(operation);
      const file = await open(actual, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        this.checkFile(operation);
        const info = await file.stat();
        if (!info.isFile()) invalid('Upload paths must be regular files');
        total += info.size;
        if (total > MAX_UPLOAD_BYTES) invalid('Upload files exceed 64 MiB aggregate budget');
        this.checkFile(operation);
        // Bound reads even if a source grows after stat, and allow cancellation.
        const chunks = [];
        let length = 0;
        const stream = file.createReadStream({ autoClose: false, signal: operation.controller.signal });
        for await (const chunk of stream) {
          this.checkFile(operation); length += chunk.length;
          if (length > info.size || total - info.size + length > MAX_UPLOAD_BYTES) invalid('Upload file changed or exceeds aggregate budget');
          chunks.push(chunk);
        }
        const extension = basename(path).split('.').at(-1).toLowerCase();
        const mime = { txt: 'text/plain', csv: 'text/csv', json: 'application/json', pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', html: 'text/html' }[extension] ?? 'application/octet-stream';
        payloads.push({ name: basename(path), mimeType: mime, buffer: Buffer.concat(chunks) });
      } finally { await file.close(); }
      this.checkFile(operation);
      if (Date.now() >= deadline) throw new HostError('timeout', 'Upload deadline expired', operation.dispatched);
    }
    const direct = args.inputRef !== undefined || args.element !== undefined;
    const target = direct ? await this.target(tab, args.inputRef !== undefined ? { ref: string(args.inputRef, 'inputRef') } : { selector: string(args.element, 'element') }, operation)
      : args.ref !== undefined ? await this.target(tab, { ref: string(args.ref, 'ref') }, operation) : null;
    this.checkFile(operation);
    const previous = tab.upload;
    this.cancelUpload(tab, 'superseded');
    // A successor never installs its listener while an old native setFiles is
    // still completing. Rejection is public state, but task settlement is joined.
    if (previous) {
      await previous.task;
      this.checkFile(operation);
      tab.recentUploads.push(previous);
      if (tab.recentUploads.length > 10) tab.recentUploads.shift();
    }
    if (Date.now() >= deadline) throw new HostError('timeout', 'Upload deadline expired', operation.dispatched);
    const owner = direct || target ? operation : { aborted: false, dispatched: true, fileEpoch: this.fileEpoch, controller: new AbortController() };
    const record = { id: `u${++this.uploadSequence}`, state: direct ? 'setting' : 'armed', deadline: new Date(deadline).toISOString(), fileCount: payloads.length, operation: owner, task: null, timer: null, waiter: null };
    tab.upload = record;
    operation.dispatched = true;
    record.timer = setTimeout(() => { this.cancelUpload(tab, 'expired'); }, Math.max(1, deadline - Date.now()));
    record.timer.unref();
    if (!direct) record.waiter = this.eventWaiter(tab.page, 'filechooser', owner, deadline);
    const execute = async () => {
      try {
        this.checkFile(owner);
        if (direct) await target.setInputFiles(payloads, { timeout: Math.max(1, deadline - Date.now()) });
        else {
          if (target) { await target.click({ timeout: Math.max(1, deadline - Date.now()) }); this.checkFile(owner); }
          const chooser = await record.waiter.promise;
          this.checkFile(owner);
          record.state = 'setting';
          await chooser.setFiles(payloads, { timeout: Math.max(1, deadline - Date.now()) });
        }
        this.checkFile(owner);
        record.state = 'completed';
      } catch (error) {
        if (!['superseded', 'cancelled', 'expired'].includes(record.state)) record.state = Date.now() >= deadline ? 'expired' : 'failed';
        record.error = { class: error.class ?? 'browser_error', message: clip(String(error.message), 512, 2048).text };
        if (target || direct) throw error;
      } finally {
        clearTimeout(record.timer); record.waiter?.cancel(); record.waiter = null; payloads.length = 0;
      }
    };
    const completion = execute();
    // Keep a settled nonrejecting join for supersession/cleanup; callers of
    // atomic/direct routes still observe the actual failure via completion.
    record.task = completion.then(() => {}, () => {});
    this.fileTasks.add(record.task);
    void record.task.then(() => this.fileTasks.delete(record.task));
    if (target || direct) await completion;
    this.checkFile(operation);
    return { ...this.metadata(tab), ok: true, uploadId: record.id, armed: record.state === 'armed', expiresAt: record.deadline, browserState: this.browserState(tab) };
  }

  async snapshot(tab, args, operation) {
    if (args.snapshotFormat !== undefined && !['ai', 'aria'].includes(args.snapshotFormat)) invalid('snapshotFormat must be ai or aria');
    if (args.refs !== undefined && !['role', 'aria'].includes(args.refs)) invalid('refs must be role or aria');
    const raw = args.snapshotFormat === 'aria';
    // Resolve request intent before selector and shaping defaults are installed.
    // refs=role alone does not request native role capture in the pinned route.
    const wantsRoleSnapshot = args.labels === true || args.urls === true || args.mode === 'efficient'
      || args.interactive === true || args.compact === true || args.depth !== undefined
      || args.selector !== undefined || args.frame !== undefined;
    const aria = !raw && (args.refs === 'aria' || !wantsRoleSnapshot);
    if (args.labels !== undefined && typeof args.labels !== 'boolean') invalid('labels must be a boolean');
    const labels = args.labels === true;
    if (raw && labels) invalid('Raw ARIA snapshots do not support labels');
    if ((raw || aria) && (args.selector !== undefined || args.frame !== undefined)) invalid('ARIA snapshots do not support selector/frame');
    if (raw && args.mode !== undefined) invalid('Raw ARIA snapshots do not support mode');
    if (args.mode !== undefined && args.mode !== 'efficient') invalid('Only snapshot mode=efficient is implemented');
    if (args.delta !== undefined) invalid('Snapshot delta is not implemented');
    for (const option of ['interactive', 'compact', 'urls']) if (args[option] !== undefined && typeof args[option] !== 'boolean') invalid(`${option} must be a boolean`);
    const efficient = args.mode === 'efficient';
    const selector = args.selector === undefined ? ':root' : string(args.selector, 'selector');
    const frameSelector = args.frame === undefined ? undefined : string(args.frame, 'frame');
    const options = {
      limit: raw ? (args.limit === undefined ? 500 : positive(args.limit, 'limit', 2000)) : bounded(args.limit, 500, 'limit', 100),
      depth: bounded(args.depth, 100, 'depth', efficient ? 6 : 100),
      maxChars: bounded(args.maxChars, MAX_TEXT, 'maxChars', efficient ? 8000 : 40000),
      interactive: args.interactive ?? efficient,
      compact: args.compact ?? efficient,
      urls: args.urls ?? false,
    };
    this.invalidate(tab);
    const document = tab.document;
    const epoch = tab.snapshot;
    const assertCurrent = () => {
      this.check(operation);
      if (tab.document !== document || tab.snapshot !== epoch || tab.page.isClosed()) throw new HostError('stale_snapshot', 'Snapshot scope changed; request a new snapshot', operation.dispatched);
    };
    const capture = raw ? captureRawAriaSnapshot : aria ? captureAriaSnapshot : captureNativeRoleSnapshot;
    const params = {
      page: tab.page, selector, frameSelector, options,
      nextRef: () => `${raw ? 'ax' : 'e'}${++this.refSequence}`, assertCurrent,
      timeout: this.config.timeout_ms, signal: operation.controller.signal,
      dispatched: () => { operation.dispatched = true; },
      error: (message, cleanup) => new HostError('cleanup_unconfirmed', message, operation.dispatched, cleanup),
    };
    // Mode is represented by resolved options; the local body line limit also
    // separates comparable families, unlike the pin's role renderer.
    const family = { identity: aria ? 'aria' : 'role', interactive: options.interactive, compact: options.compact,
      depth: options.depth, selector: aria ? undefined : selector, frame: frameSelector,
      urls: options.urls, maxChars: options.maxChars, limit: options.limit };
    const refMetadata = captured => new Map(captured.refs.filter(info => captured.handles.has(info.ref))
      .map(({ ref, role, name }) => [ref, { role, name }]));
    const captured = raw ? await capture(params) : await captureWithSnapshotDelta({
      page: tab.page, tabId: tab.id, family, cache: this.snapshotDelta, assertCurrent, error: params.error,
      capture: async previousKeys => {
        const staged = await capture({ ...params, options: { ...options, previousKeys } });
        if (!labels) return staged;
        try {
          assertCurrent();
          // Use only this finalized capture's handles. The delta helper's final
          // document observation and cleanup still precede adoption/publication.
          const image = await this.#captureScreenshot(tab, { labels: true }, operation, {
            handles: staged.handles, metadata: refMetadata(staged), truncated: staged.truncated, assertCurrent,
          });
          const artifact = await this.#publishScreenshot(image, operation);
          assertCurrent();
          return { ...staged, image: { metadata: { ...image.metadata, ...artifact, imagePath: artifact.path, imageType: image.metadata.type }, inline: image.inline } };
        } catch (error) {
          const cleanup = await Promise.allSettled([...staged.handles.values()].map(handle => handle.dispose()));
          if (cleanup.some(result => result.status === 'rejected')) throw params.error('Snapshot image capture cleanup could not be confirmed', { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
          throw error;
        }
      },
    });
    try {
      assertCurrent();
      // Adoption is synchronous and all-or-nothing after capture-owned cleanup.
      tab.refs = captured.handles;
      tab.refMetadata = refMetadata(captured);
      tab.snapshotTruncated = captured.truncated;
      if (!raw) this.snapshotDelta.record(tab.id, family, captured.deltaDocumentIdentity, captured.deltaKeys);
    } catch (error) {
      const cleanup = await Promise.allSettled([...captured.handles.values()].map(handle => handle.dispose()));
      if (cleanup.some(result => result.status === 'rejected')) throw new HostError('cleanup_unconfirmed', 'Snapshot adoption cleanup could not be confirmed', operation.dispatched, { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
      throw error;
    }
    const result = projectSnapshotQuery({ ...this.metadata(tab), format: raw ? 'aria' : 'ai', refsType: raw ? 'ax' : aria ? 'aria' : 'role',
      ...(raw ? { nodes: captured.nodes, nodeCount: captured.nodes.length } : { snapshot: captured.snapshot }), refs: captured.refs,
      refCount: captured.refs.length, documentGeneration: tab.document, snapshotGeneration: tab.snapshot, truncated: captured.truncated,
      ...(captured.newElements === undefined ? {} : { newElements: captured.newElements }),
      semantics: raw
        ? 'Main-document native Chromium AX preorder, including ignored/document/text/virtual nodes; ax aliases are informational unless actionable=true; exact backend Element handles; host-monotonic aliases; only limit shapes raw nodes (refs/depth/interactive/compact/maxChars/urls ignored); whole-node UTF-8 budget'
        : aria
          ? 'Page-wide public Playwright AI YAML, including open shadow and iframe content; pinned rendered-line shaping preserves YAML properties, text and quoting; host-monotonic e aliases map privately to exact Playwright source refs and retained Element handles; urls=true appends main-document anchors within shared output budgets; not native AX'
          : 'Native Chromium AX roles, names and states; selected scope with retained backend-node identity; no child-frame recursion; urls=true appends the whole selected document anchors within shared output budgets' }, args);
    if (!captured.image) return result;
    const { metadata: imageMetadata, inline } = captured.image;
    const combined = { generation: this.generation, ...imageMetadata, ...result };
    return { ...combined, content: [{ type: 'text', text: JSON.stringify(combined) }, inline] };
  }

  async target(tab, request, operation) {
    if (request.ref !== undefined) {
      const handle = tab.refs.get(request.ref);
      if (!handle || !await handle.evaluate(element => element.isConnected).catch(() => false)) throw new HostError('stale_reference', 'Reference is unavailable; request a new snapshot');
      this.check(operation);
      return handle;
    }
    return tab.page.locator(string(request.selector, 'ref or selector'));
  }

  async act(tab, request, operation) {
    this.check(operation);
    const kind = request.kind;
    const interactionTimeout = interactionTimeoutMs(request);
    const waitTimeout = waitTimeoutMs(request);
    if (!ACT_KINDS.includes(kind)) throw new HostError('not_implemented', `Unsupported act kind: ${kind}`);
    if (request.targetId !== undefined && request.targetId !== tab.id) invalid('Batch/request targetId must match the selected tab');
    if (kind === 'batch') {
      const results = [];
      const document = tab.document;
      // register() increments this generation on every main-frame navigation,
      // including same-URL reloads. Each enclosing batch observes the same commit.
      const finish = reason => {
        const url = tab.page.url();
        if (reason === 'navigation' && results.length) Object.assign(results.at(-1), { navigated: true, url });
        const skipped = request.actions.length - results.length;
        return { results, ...(skipped ? { aborted: { reason, afterAction: results.length, url, skipped } } : {}) };
      };
      for (const item of request.actions) {
        this.check(operation);
        if (tab.page.isClosed()) return finish('closed');
        if (tab.document !== document) return finish('navigation');
        let result;
        try {
          result = { ok: true, ...await this.act(tab, item, operation) };
          // Preserve the child's rich outcomes while allowing each parent's own
          // stopOnError to apply even when the nested batch continued after error.
          const failure = item.kind === 'batch' && result.results.find(child => !child.ok);
          if (failure) Object.assign(result, { ok: false, error: failure.error });
        }
        catch (error) {
          if (operation.aborted || operation.dialogBlocked || error?.name === 'TimeoutError' || ['cancelled', 'timeout', 'dialog_pending'].includes(error?.class)) throw error;
          result = { ok: false, error: { class: error.class ?? 'browser_error', message: String(error.message).slice(0, 2000), dispatched: error.dispatched === true || operation.dispatched } };
        }
        results.push(result);
        if (tab.page.isClosed()) return finish('closed');
        if (tab.document !== document) return finish('navigation');
        if (!result.ok && request.stopOnError !== false) break;
      }
      return { results };
    }
    if (kind === 'close') {
      operation.dispatched = true; await tab.page.close(); await tab.upload?.task; this.check(operation);
      this.tabAliases.delete(tab.targetId);
      if (this.activeTarget === tab.id) this.activeTarget = null;
      return { closed: true };
    }
    if (kind === 'resize') { const width = positive(request.width, 'width', 10000); const height = positive(request.height, 'height', 10000); await this.viewport(tab, { width, height }, operation); return { ok: true }; }
    if (kind === 'evaluate') {
      const fn = string(request.fn, 'fn');
      const args = { fn, timeoutMs: evaluateInnerTimeoutMs(request) };
      operation.dispatched = true;
      const result = request.ref === undefined
        ? await tab.page.evaluate(({ fn, timeoutMs }) => {
            const callback = (0, eval)(`(${fn})`);
            if (typeof callback !== 'function') throw new Error('fn must be a function expression');
            const result = callback();
            if (!result || typeof result.then !== 'function') return result;
            let timer;
            return Promise.race([result, new Promise((_, reject) => {
              timer = setTimeout(() => reject(new Error(`evaluate timed out after ${timeoutMs}ms`)), timeoutMs);
            })]).finally(() => clearTimeout(timer));
          }, args)
        : await (await this.target(tab, request, operation)).evaluate((element, { fn, timeoutMs }) => {
            const callback = (0, eval)(`(${fn})`);
            if (typeof callback !== 'function') throw new Error('fn must be a function expression');
            const result = callback(element);
            if (!result || typeof result.then !== 'function') return result;
            let timer;
            return Promise.race([result, new Promise((_, reject) => {
              timer = setTimeout(() => reject(new Error(`evaluate timed out after ${timeoutMs}ms`)), timeoutMs);
            })]).finally(() => clearTimeout(timer));
          }, args);
      this.check(operation);
      let encoded;
      try { encoded = JSON.stringify(result ?? null); } catch { throw new HostError('result_budget', 'evaluate result must be JSON serializable', true); }
      if (Buffer.byteLength(encoded) > MAX_TEXT) throw new HostError('result_budget', 'evaluate result exceeds text budget', true);
      return { value: JSON.parse(encoded) };
    }
    if (kind === 'wait') {
      const predicate = request.fn === undefined ? undefined : createBrowserWaitPredicate(string(string(request.fn, 'fn').trim(), 'fn'));
      const document = tab.document;
      let documentHandle; let resultHandle;
      const current = () => {
        this.check(operation);
        if (predicate && (tab.document !== document || tab.page.isClosed())) throw new HostError('browser_error', 'Wait predicate document changed', operation.dispatched);
      };
      try {
        // Capture before prerequisites: an executable wait belongs to the live
        // document where the whole sequence began, including time/text waits.
        if (predicate) { documentHandle = await tab.page.evaluateHandle(() => globalThis.document); current(); }
        let requested = false;
        if (request.timeMs !== undefined) { requested = true; await delay(bounded(request.timeMs, 120000, 'timeMs', 0), undefined, { signal: operation.controller.signal }); current(); }
        if (request.text !== undefined) { requested = true; await tab.page.getByText(string(request.text, 'text'), { exact: false }).first().waitFor({ state: 'visible', timeout: waitTimeout }); current(); }
        if (request.textGone !== undefined) { requested = true; await tab.page.getByText(string(request.textGone, 'textGone'), { exact: false }).first().waitFor({ state: 'hidden', timeout: waitTimeout }); current(); }
        if (request.selector || request.ref) {
          requested = true;
          const target = await this.target(tab, request, operation);
          current();
          if (typeof target.waitForElementState === 'function') await target.waitForElementState('visible', { timeout: waitTimeout });
          else await target.first().waitFor({ state: 'visible', timeout: waitTimeout });
          current();
        }
        if (request.url !== undefined) { requested = true; await tab.page.waitForURL(string(request.url, 'url'), { timeout: waitTimeout }); current(); }
        if (request.loadState !== undefined) { requested = true; if (!['load','domcontentloaded','networkidle'].includes(request.loadState)) invalid('Unsupported loadState'); await tab.page.waitForLoadState(request.loadState, { timeout: waitTimeout }); current(); }
        if (predicate) {
          requested = true;
          current();
          operation.dispatched = true;
          // The live handle also stops Playwright from transparently rerunning
          // this predicate in a replacement execution context.
          resultHandle = await tab.page.waitForFunction(predicate, { document: documentHandle }, { timeout: waitTimeout });
          current();
        }
        if (!requested) invalid('wait requires a condition');
        return { ok: true };
      } finally {
        const cleanup = await Promise.allSettled([resultHandle, documentHandle].filter(Boolean).map(handle => handle.dispose()));
        if (cleanup.some(result => result.status === 'rejected')) throw new HostError('cleanup_unconfirmed', 'Wait handle cleanup could not be confirmed', operation.dispatched, { cleanup_confirmed: false, wait_cleanup_confirmed: false });
      }
    }
    if (kind === 'press' && request.ref === undefined && request.selector === undefined) {
      operation.dispatched = true;
      await tab.page.keyboard.press(request.key, { delay: request.delayMs });
      this.check(operation);
      return { ok: true };
    }
    if (kind === 'clickCoords') {
      if (!Number.isFinite(request.x) || !Number.isFinite(request.y)) invalid('x and y must be finite coordinates');
      if (request.modifiers !== undefined) invalid('clickCoords modifiers are not implemented');
      operation.dispatched = true;
      await tab.page.mouse.click(request.x, request.y, { button: request.button ?? 'left', clickCount: request.doubleClick ? 2 : 1, delay: request.delayMs });
      this.check(operation);
      return { ok: true };
    }
    if (kind === 'fill') {
      for (const field of request.fields) {
        const target = await this.target(tab, field, operation);
        this.check(operation);
        operation.dispatched = true;
        if (field.type === 'checkbox' || field.type === 'radio') {
          const checked = field.value === true || field.value === 1 || field.value === '1' || field.value === 'true';
          await target.setChecked(checked, { timeout: interactionTimeout });
        } else await target.fill(String(field.value ?? ''), { timeout: interactionTimeout });
        this.check(operation);
      }
      return { ok: true };
    }
    if (kind === 'drag') {
      const document = tab.document;
      const deadline = Math.min(operation.deadline, Date.now() + interactionTimeout);
      const remaining = () => {
        this.check(operation);
        if (tab.document !== document || tab.page.isClosed()) throw new HostError('browser_error', 'Drag document changed', operation.dispatched);
        const timeout = deadline - Date.now();
        if (timeout <= 0) {
          // Route local expiry through invoke's existing timeout shutdown, so
          // mouse-down cannot outlive a drag that exhausted its shared phase.
          operation.aborted = true;
          operation.reason = 'timeout';
          operation.controller.abort();
          throw new HostError('timeout', 'Drag deadline expired', operation.dispatched);
        }
        return timeout;
      };
      const source = await this.target(tab, { ref: string(request.startRef, 'startRef') }, operation);
      const destination = await this.target(tab, { ref: string(request.endRef, 'endRef') }, operation);
      remaining(); operation.dispatched = true;
      // Keep the exact snapshot handles. Hover supplies pointer actionability
      // and a visible point, without scrolling the destination before mouse-down.
      await source.hover({ timeout: remaining() });
      remaining();
      // A rejected down/up may already have changed the button state. Keep that
      // custody until up succeeds; invoke owns the existing shutdown/settlement.
      try {
        await tab.page.mouse.down();
        await destination.hover({ timeout: remaining() });
        remaining(); await tab.page.mouse.up();
      } catch (error) {
        // Preserve the existing suspended-dialog path and its original task.
        if (error?.class === 'dialog_pending') throw error;
        const failure = error instanceof HostError ? error : new HostError(
          error?.name === 'TimeoutError' ? 'timeout' : 'browser_error',
          String(error?.message ?? error).slice(0, 2000), operation.dispatched, error?.cleanup,
        );
        operation.aborted = true;
        operation.reason ??= failure.class;
        operation.controller.abort();
        throw failure;
      }
      remaining();
      return { ok: true };
    }
    const document = tab.document;
    const currentInput = () => {
      this.check(operation);
      if (tab.document !== document || tab.page.isClosed()) throw new HostError('browser_error', 'Input document changed', operation.dispatched);
    };
    const target = await this.target(tab, request, operation);
    this.check(operation);
    operation.dispatched = true;
    if (kind === 'click') {
      currentInput();
      if (request.delayMs > 0) {
        await target.hover({ timeout: interactionTimeout }); currentInput();
        await delay(request.delayMs, undefined, { signal: operation.controller.signal }); currentInput();
      }
      const options = { button: request.button ?? 'left', modifiers: request.modifiers, timeout: interactionTimeout };
      await (request.doubleClick ? target.dblclick(options) : target.click(options));
    }
    else if (kind === 'type') {
      if (typeof request.text !== 'string') invalid('text must be a string');
      if (request.slowly) {
        currentInput();
        await target.click({ timeout: interactionTimeout }); currentInput();
        await target.type(request.text, { delay: request.delayMs, timeout: typingTimeoutMs(request) }); currentInput();
      } else { await target.fill(request.text, { timeout: interactionTimeout }); this.check(operation); }
      if (request.submit) { currentInput(); await target.press('Enter', { timeout: interactionTimeout }); }
    }
    else if (kind === 'press') await target.press(request.key, { delay: request.delayMs, timeout: pressTimeoutMs(request) });
    else if (kind === 'hover') await target.hover({ timeout: interactionTimeout });
    else if (kind === 'scrollIntoView') await target.scrollIntoViewIfNeeded({ timeout: waitTimeout });
    else if (kind === 'select') { if (!Array.isArray(request.values) || !request.values.every(v => typeof v === 'string')) invalid('values must be strings'); await target.selectOption(request.values, { timeout: interactionTimeout }); }
    this.check(operation);
    return { ok: true };
  }

  async screenshot(tab, args, operation) {
    return this.fileTask(operation, async () => {
      // Capture restores native state and enforces the same image budgets before
      // publishing the finalized bytes in either presentation mode.
      const captured = await this.#captureScreenshot(tab, args, operation);
      const artifact = await this.#publishScreenshot(captured, operation);
      const { metadata, inline } = captured;
      if (this.config.screenshot_result_mode === 'image') {
        const result = { ...metadata, ...artifact };
        return { ...result, content: [{ type: 'text', text: JSON.stringify(result) }, inline] };
      }
      const receipt = { generation: this.generation, ok: true, path: artifact.path,
        targetId: clip(metadata.targetId, 256, 1024).text, url: clip(metadata.url, 2048, 8192).text,
        type: metadata.type, mimeType: `image/${metadata.type}`, bytes: metadata.bytes,
        sha256: artifact.sha256, media: { outbound: false },
        ...(metadata.labels ? { labels: true, labelsCount: metadata.labelsCount, labelsSkipped: metadata.labelsSkipped,
          annotationCount: metadata.annotations?.length ?? 0, ...(metadata.truncated ? { truncated: true } : {}) } : {}) };
      return { ...receipt, content: [{ type: 'text', text: JSON.stringify(receipt) }] };
    });
  }

  async #publishScreenshot(captured, operation) {
    // The public capture owns one fileTask; this publisher also serves staged
    // labeled snapshots before their refs and delta baseline are adopted.
    this.checkFile(operation);
    const { buffer, type } = captured.artifact;
    if (buffer.length > this.config.max_image_bytes || buffer.toString('base64').length > 262144) throw new HostError('result_budget', 'Screenshot exceeds configured image budget');
    const root = await this.projectRoot(operation);
    const output = await this.outputPath(root, undefined, type, operation);
    this.checkFile(operation);
    if (output.length > 4096) invalid('Screenshot artifact path exceeds 4096 characters');
    operation.dispatched = true;
    const staging = await mkdtemp(join(dirname(output), '.browser-stage-'));
    try {
      this.checkFile(operation);
      const temporary = join(staging, 'artifact');
      const file = await open(temporary, 'wx', 0o600);
      try { this.checkFile(operation); await file.writeFile(buffer); } finally { await file.close(); }
      this.checkFile(operation);
      this.beneath(root, await realpath(dirname(output)));
      this.checkFile(operation);
      await this.regularOutput(output, operation);
      await rename(temporary, output);
      this.checkFile(operation);
      return { path: output, sha256: createHash('sha256').update(buffer).digest('hex'),
        media: { outbound: false, mediaUrl: output } };
    } finally {
      // Published artifacts belong to the project and survive host cleanup.
      await rm(staging, { recursive: true, force: true });
    }
  }

  async #captureScreenshot(tab, args, operation, staged) {
    if (args.path !== undefined) invalid('Screenshot output paths are generated by the host');
    if (args.labels !== undefined && typeof args.labels !== 'boolean') invalid('labels must be a boolean');
    const type = args.type ?? 'png';
    if (!['png', 'jpeg'].includes(type)) invalid('type must be png or jpeg');
    const targeted = args.ref !== undefined || args.element !== undefined;
    if (targeted && args.fullPage === true) invalid('fullPage is not supported for element screenshots');
    const labels = args.labels === true;
    if (labels && args.ref === undefined && !staged) await this.snapshot(tab, { selector: ':root', limit: 500, maxChars: MAX_TEXT }, operation);
    const document = tab.document; const snapshot = tab.snapshot;
    const assertCurrent = () => {
      this.check(operation);
      staged?.assertCurrent();
      if (labels && (tab.document !== document || tab.snapshot !== snapshot || tab.page.isClosed())) throw new HostError('stale_snapshot', 'Screenshot label references changed during capture', operation.dispatched);
    };
    let buffer;
    let element;
    let overlay;
    let plan;
    let captureClip;
    let temporary = false;
    const emulation = tab.emulation;
    try {
      if (args.ref !== undefined) {
        element = await this.target(tab, { ref: string(args.ref, 'ref') }, operation);
      } else if (args.element !== undefined) {
        element = await tab.page.locator(string(args.element, 'element')).first().elementHandle({ timeout: this.config.timeout_ms });
        temporary = true;
        if (!element) throw new HostError('target_missing', 'Screenshot element is unavailable');
      }
      assertCurrent();
      if (element) {
        // Scrolling changes the page even if a later capture or projection fails.
        operation.dispatched = true;
        await element.scrollIntoViewIfNeeded({ timeout: this.config.timeout_ms });
        assertCurrent();
      }
      if (labels) {
        const space = args.fullPage === true ? 'fullpage' : targeted ? 'element' : 'viewport';
        const measurement = await measureScreenshotLabels({ page: tab.page, handles: staged?.handles ?? tab.refs, metadata: staged?.metadata ?? tab.refMetadata, space, assertCurrent });
        const view = measurement.view;
        const box = element ? await element.boundingBox() : null;
        assertCurrent();
        if (targeted && (!box || !box.width || !box.height)) throw new HostError('target_missing', 'Screenshot element must be visible and have a size');
        const elementRect = box ? { x: box.x + view.x, y: box.y + view.y, width: box.width, height: box.height } : undefined;
        plan = planScreenshotLabels(measurement, space, elementRect);
        captureClip = elementRect ? { x: Math.floor(elementRect.x), y: Math.floor(elementRect.y),
          width: Math.ceil(elementRect.x + elementRect.width) - Math.floor(elementRect.x) }
          : space === 'fullpage' ? { x: 0, y: 0, width: view.fullWidth }
            : { x: view.x, y: view.y, width: Math.floor((tab.page.viewportSize()?.width ?? await tab.page.evaluate(() => innerWidth)) / view.scale + 1e-3) };
        assertCurrent();
        if (plan.overlays.length) {
          overlay = await createScreenshotOverlay(tab.page);
          assertCurrent();
          operation.dispatched = true;
          await attachScreenshotOverlay(overlay, plan.overlays, space === 'element' ? elementRect.y : space === 'viewport' ? view.y : 0);
          assertCurrent();
        }
      }
      if (emulation?.metrics) {
        const box = element ? await element.boundingBox() : null;
        assertCurrent();
        if (targeted && (!box || !box.width || !box.height)) throw new HostError('target_missing', 'Screenshot element must be visible and have a size');
        const session = await this.emulationSession(tab, operation);
        assertCurrent();
        const metrics = await session.send('Page.getLayoutMetrics');
        assertCurrent();
        const visual = metrics.cssVisualViewport;
        const owner = emulation.metrics;
        let clip = args.fullPage === true ? { ...metrics.cssContentSize, scale: 1 } : {
          x: visual.pageX, y: visual.pageY, width: Math.ceil(owner.width / visual.scale),
          height: Math.ceil(owner.height / visual.scale), scale: visual.scale,
        };
        if (box) {
          const x = Math.floor(box.x + visual.pageX);
          const y = Math.floor(box.y + visual.pageY);
          clip = { x, y, width: Math.ceil(box.x + visual.pageX + box.width) - x,
            height: Math.ceil(box.y + visual.pageY + box.height) - y, scale: 1 };
        }
        if (labels) captureClip = clip;
        // Chromium restores the capturing session's metrics; use their owner.
        operation.dispatched = true;
        const capture = await session.send('Page.captureScreenshot', { format: type, clip,
          captureBeyondViewport: (args.fullPage === true || targeted) && (clip.width > owner.width || clip.height > owner.height),
          ...(type === 'jpeg' ? { quality: 85 } : {}) });
        assertCurrent();
        buffer = Buffer.from(capture.data, 'base64');
      } else {
        // The outer operation owns cancellation and joins native restoration.
        const options = { type, timeout: 0 };
        operation.dispatched = true;
        buffer = await (element ? element.screenshot(options) : tab.page.screenshot({ ...options, fullPage: args.fullPage === true }));
      }
      assertCurrent();
    } finally {
      let cleanupFailure;
      try {
        await clearScreenshotOverlay(overlay, () => new HostError('cleanup_unconfirmed', 'Screenshot overlay cleanup could not be confirmed', operation.dispatched,
          { cleanup_confirmed: false, screenshot_cleanup_confirmed: false }));
      } catch (error) { cleanupFailure = error; }
      try {
        if (emulation?.touch !== undefined && !operation.aborted) {
          this.check(operation);
          const session = await this.emulationSession(tab, operation);
          await session.send('Emulation.setTouchEmulationEnabled', { enabled: emulation.touch });
          this.check(operation);
        }
      } catch (error) { cleanupFailure ??= error; }
      // Snapshot refs remain owned by the tab and must survive this capture.
      try { if (temporary) await element?.dispose(); } catch (error) { cleanupFailure ??= error; }
      if (cleanupFailure) throw cleanupFailure;
    }
    this.check(operation);
    assertCurrent();
    const rawDimensions = screenshotDimensions(buffer, type);
    const rawAnnotations = labels ? screenshotAnnotations(plan, captureClip, rawDimensions) : undefined;
    const artifact = await normalizeScreenshot(buffer, type, { signal: operation.controller.signal });
    assertCurrent();
    if (artifact.buffer.length > this.config.max_image_bytes || artifact.buffer.toString('base64').length > 262144) throw new HostError('result_budget', 'Screenshot exceeds configured image budget');
    const annotations = labels ? scaleScreenshotAnnotations(rawAnnotations, rawDimensions, artifact.dimensions) : undefined;
    let inline;
    if (staged || this.config.screenshot_result_mode === 'image') {
      const image = await normalizeScreenshot(artifact.buffer, artifact.type, { maxSide: 1200, signal: operation.controller.signal });
      assertCurrent();
      const base64 = image.buffer.toString('base64');
      if (image.buffer.length > this.config.max_image_bytes || base64.length > 262144) throw new HostError('result_budget', 'Screenshot exceeds configured image budget');
      inline = { type: 'image', data: { source: 'base64', media_type: `image/${image.type}`, data: base64 } };
    }
    assertCurrent();
    const metadata = { ...this.metadata(tab), type: artifact.type, bytes: artifact.buffer.length,
      ...(labels ? { labels: true, labelsCount: plan.overlays.length, labelsSkipped: plan.skipped,
        ...(annotations.length ? { annotations } : {}), ...((staged?.truncated ?? tab.snapshotTruncated) ? { truncated: true } : {}) } : {}) };
    return { metadata, artifact, inline };
  }
}
