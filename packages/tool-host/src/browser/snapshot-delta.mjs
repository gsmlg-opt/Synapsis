import { createHash } from 'node:crypto';

const SNAPSHOT_BYTES = 262144;

// A helper owns one profile. Tab/options slots are process-local and never
// persist handles or survive normal tab/host shutdown.
export class SnapshotDeltaCache {
  constructor() { this.entries = new Map(); }

  previous(tabId, family, documentIdentity) {
    if (documentIdentity === undefined) return undefined;
    const key = JSON.stringify([tabId, family]);
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    this.entries.delete(key);
    if (entry.documentIdentity !== documentIdentity) return undefined;
    this.entries.set(key, entry);
    return entry.keys;
  }

  record(tabId, family, documentIdentity, keys) {
    if (documentIdentity === undefined) return;
    const key = JSON.stringify([tabId, family]);
    this.entries.delete(key);
    this.entries.set(key, { tabId, documentIdentity, keys: new Set(keys) });
    while (this.entries.size > 32) this.entries.delete(this.entries.keys().next().value);
  }

  clearTab(tabId) {
    for (const [key, entry] of this.entries) if (entry.tabId === tabId) this.entries.delete(key);
  }

  clear() { this.entries.clear(); }
}

function documentIdentities(roots, expectedFrames) {
  const loader = roots[0]?.frame?.loaderId;
  const mainFrame = typeof loader === 'string' && loader.trim() ? `cdp:${loader.trim()}` : undefined;
  const documents = new Map(); const pending = roots.filter(Boolean);
  while (pending.length) {
    const node = pending.pop(); const id = node.frame?.id; const loaderId = node.frame?.loaderId;
    if (typeof id !== 'string' || !id.trim() || typeof loaderId !== 'string' || !loaderId.trim()) return { mainFrame };
    const previous = documents.get(id.trim());
    if (previous !== undefined && previous !== loaderId.trim()) return { mainFrame };
    documents.set(id.trim(), loaderId.trim());
    pending.push(...(node.childFrames ?? []));
  }
  if (expectedFrames !== undefined && documents.size !== expectedFrames) return { mainFrame };
  const ordered = [...documents].sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0);
  return { mainFrame, frameTree: ordered.length ? `cdp-tree:${createHash('sha256').update(JSON.stringify(ordered)).digest('hex')}` : undefined };
}

// Capture-owned sessions make read-only committed-document observations. Main
// Page.getFrameTree omits OOP targets, so frame-spanning families also retain
// each public OOP Frame session. Same-process frames are covered by their parent.
export async function captureWithSnapshotDelta({ page, tabId, family, cache, assertCurrent, capture, error }) {
  const sessions = [];
  let captured; let documentIdentity; let failure;
  try {
    assertCurrent();
    const spansFrames = family.identity === 'aria' || Boolean(family.frame);
    const frames = spansFrames ? page.frames() : undefined;
    const main = await page.context().newCDPSession(page);
    sessions.push(main);
    assertCurrent();
    if (spansFrames) for (const frame of frames) {
      if (frame === page.mainFrame()) continue;
      let attached;
      try {
        attached = await page.context().newCDPSession(frame);
        // Even late sessions belong to cleanup before any operation guard.
        sessions.push(attached);
        assertCurrent();
      } catch (cause) {
        assertCurrent();
        if (attached || !String(cause.message).includes('does not have a separate CDP session')) throw cause;
      }
    }
    const scope = spansFrames ? 'frameTree' : 'mainFrame';
    const readIdentity = async () => {
      assertCurrent();
      const roots = [];
      for (const session of sessions) {
        const result = await session.send('Page.getFrameTree');
        assertCurrent();
        roots.push(result.frameTree);
      }
      if (spansFrames) {
        const current = page.frames();
        if (current.length !== frames.length || current.some(frame => !frames.includes(frame))) throw new Error('Snapshot frame set changed before delta publication');
      }
      return documentIdentities(roots, frames?.length)[scope];
    };
    documentIdentity = await readIdentity();
    const previousKeys = cache.previous(tabId, family, documentIdentity);
    captured = await capture(previousKeys);
    assertCurrent();
    const current = await readIdentity();
    if (documentIdentity !== undefined && current !== documentIdentity) throw new Error('Snapshot document changed before delta publication');
  } catch (cause) { failure = cause; }
  let cleanupFailed = false;
  for (const session of sessions) { try { await session.detach(); } catch { cleanupFailed = true; } }
  if (!failure && !cleanupFailed) { try { assertCurrent(); } catch (cause) { failure = cause; } }
  if (failure || cleanupFailed) {
    if (captured) {
      const disposed = await Promise.allSettled([...captured.handles.values()].map(handle => handle.dispose()));
      cleanupFailed ||= disposed.some(result => result.status === 'rejected');
    }
    if (cleanupFailed) throw error('Snapshot delta cleanup could not be confirmed', { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
    throw failure;
  }
  return { ...captured, deltaDocumentIdentity: documentIdentity };
}

// Visible keys/counts are computed by structured renderers before binding. The
// summary follows any URL appendix and consumes the same whole-line budget.
export function appendSnapshotDeltaSummary(result, maxChars) {
  if (!result.newElements) return result;
  const addition = `\n${result.newElements} new element(s) since last snapshot`;
  if (result.snapshot.length + addition.length > maxChars || Buffer.byteLength(result.snapshot) + Buffer.byteLength(addition) > SNAPSHOT_BYTES) return { ...result, truncated: true };
  return { ...result, snapshot: result.snapshot + addition };
}
