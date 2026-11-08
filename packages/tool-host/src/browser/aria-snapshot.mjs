import { randomUUID } from 'node:crypto';
import { appendSnapshotUrls, collectSnapshotUrls } from './snapshot-urls.mjs';
import { appendSnapshotDeltaSummary } from './snapshot-delta.mjs';

import { renderAriaYaml } from './aria-yaml.mjs';

const SNAPSHOT_BYTES = 262144;
const axValue = field => field?.value === undefined ? '' : String(field.value);

export async function captureAriaSnapshot({ page, options, nextRef, assertCurrent, dispatched, timeout, signal, error }) {
  const handles = new Map();
  try {
    assertCurrent();
    // Public AI capture executes page work. Preserve dispatch evidence even if
    // cancellation or a frame epoch change prevents subsequent adoption.
    dispatched();
    const yaml = await page.ariaSnapshot({ mode: 'ai', timeout, signal });
    assertCurrent();
    let result = renderAriaYaml(yaml, options, nextRef);
    if (options.urls) {
      const collected = await collectSnapshotUrls(page);
      assertCurrent();
      const appended = appendSnapshotUrls(result.snapshot, collected, options.maxChars);
      result = { ...result, ...appended, truncated: result.truncated || appended.truncated };
    }
    result = appendSnapshotDeltaSummary(result, options.maxChars);
    for (const info of result.refs) {
      assertCurrent();
      const handle = await page.getByRef(info.sourceRef).elementHandle({ timeout });
      if (handle) handles.set(info.ref, handle);
      assertCurrent();
      if (!handle) throw new Error('ARIA reference could not be bound to its exact element');
      const connected = await handle.evaluate(element => element.nodeType === 1 && element.isConnected);
      assertCurrent();
      if (!connected) throw new Error('ARIA reference is no longer an attached element');
    }
    return { ...result, handles, refs: result.refs.map(({ sourceRef: _source, ...info }) => info) };
  } catch (cause) {
    const cleanup = await Promise.allSettled([...handles.values()].map(handle => handle.dispose()));
    if (cleanup.some(result => result.status === 'rejected')) throw error('ARIA snapshot cleanup could not be confirmed', { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
    throw cause;
  }
}

// Raw AX includes document, ignored, text and virtual nodes. It does not use
// role/compact/depth shaping. Keep complete native strings and truncate only at
// whole-node boundaries, before binding or publishing any reference.
function renderRawTree(nodes, limit, nextRef) {
  const byId = new Map(nodes.map(node => [node.nodeId, node]));
  const referenced = new Set(nodes.flatMap(node => node.childIds ?? []));
  const root = nodes.find(node => !referenced.has(node.nodeId)) ?? nodes[0];
  const pending = root ? [{ node: root, depth: 0 }] : [];
  const seen = new Set(); const rendered = [];
  let bytes = 2; let truncated = false;
  while (pending.length) {
    const { node, depth } = pending.pop();
    if (seen.has(node.nodeId)) continue;
    seen.add(node.nodeId);
    if (rendered.length >= limit) { truncated = true; break; }
    const value = axValue(node.value); const description = axValue(node.description);
    const record = { ref: nextRef(), role: axValue(node.role) || 'unknown', name: axValue(node.name),
      ...(value ? { value } : {}), ...(description ? { description } : {}),
      ...(typeof node.backendDOMNodeId === 'number' ? { backendDOMNodeId: node.backendDOMNodeId } : {}), depth, actionable: false };
    const size = Buffer.byteLength(JSON.stringify(record)) + (rendered.length ? 1 : 0);
    if (bytes + size > SNAPSHOT_BYTES) { truncated = true; break; }
    rendered.push(record); bytes += size;
    for (const id of [...(node.childIds ?? [])].reverse()) {
      const child = byId.get(id);
      if (child) pending.push({ node: child, depth: depth + 1 });
    }
  }
  return { nodes: rendered, truncated };
}

// A separate public CDP session owns this capture. A temporary document
// property bridges each exact backend object to a public evaluateHandle result.
// Unlike CSS markers this also reaches native Elements in closed/UA shadow DOM.
// Document/text/virtual nodes remain informational rather than guessed.
export async function captureRawAriaSnapshot({ page, options, nextRef, assertCurrent, dispatched, error }) {
  let session; let result; let failure;
  const attribute = `synapsis-ax-handle-${randomUUID()}`;
  const objects = new Set(); const marked = new Set(); const handles = new Map(); const candidates = new Set();
  const send = async (method, params) => { assertCurrent(); const result = await session.send(method, params); assertCurrent(); return result; };
  const callObject = async (objectId, declaration, args, cleanup = false) => {
    if (!cleanup) assertCurrent();
    const response = await session.send('Runtime.callFunctionOn', {
      objectId, functionDeclaration: declaration, arguments: args.map(value => ({ value })), returnByValue: true,
    });
    if (!cleanup) assertCurrent();
    if (response.exceptionDetails) throw new Error('Raw AX temporary identity operation failed');
    return response.result?.value;
  };
  try {
    assertCurrent();
    // Assign late sessions before guarding so cleanup always owns the attach.
    session = await page.context().newCDPSession(page);
    assertCurrent();
    const captured = await send('Accessibility.getFullAXTree');
    result = renderRawTree(captured.nodes, options.limit, nextRef);
    for (const node of result.nodes) {
      assertCurrent();
      if (node.backendDOMNodeId === undefined) continue;
      const { object } = await session.send('DOM.resolveNode', { backendNodeId: node.backendDOMNodeId });
      if (object?.objectId) objects.add(object.objectId);
      assertCurrent();
      if (!object?.objectId) throw new Error('Raw AX DOM identity could not be resolved');
      const nodeType = await callObject(object.objectId, 'function() { return this.nodeType; }', []);
      if (nodeType === 1) {
        // Own the original document before mutating it. Adoption can change
        // element.ownerDocument without a navigation epoch, and a mutation may
        // execute even when its CDP reply is lost. Neither changes cleanup's owner.
        const owner = await session.send('Runtime.callFunctionOn', {
          objectId: object.objectId, functionDeclaration: 'function() { return this.ownerDocument; }',
          returnByValue: false,
        });
        const documentObjectId = owner.result?.objectId;
        if (documentObjectId) objects.add(documentObjectId);
        // Late returned objects belong to cleanup before any operation guard.
        assertCurrent();
        if (owner.exceptionDetails || !documentObjectId) throw new Error('Raw AX original document could not be retained');
        marked.add(documentObjectId);
        dispatched();
        const bridge = await session.send('Runtime.callFunctionOn', {
          objectId: documentObjectId,
          functionDeclaration: 'function(attribute, element) { if (!element.isConnected || element.ownerDocument !== this) return false; Object.defineProperty(this, attribute, {value:element,configurable:true}); return true; }',
          arguments: [{ value: attribute }, { objectId: object.objectId }], returnByValue: true,
        });
        assertCurrent();
        if (bridge.exceptionDetails) throw new Error('Raw AX temporary identity operation failed');
        if (bridge.result?.value !== true) throw new Error('Raw AX reference is no longer attached to its original document');
        const candidate = await page.evaluateHandle(attribute => document[attribute], attribute);
        candidates.add(candidate);
        const handle = candidate.asElement();
        if (handle) handles.set(node.ref, handle);
        else await candidate.dispose();
        candidates.delete(candidate);
        assertCurrent();
        if (!handle) throw new Error('Raw AX reference could not be bound to its exact element');
        const attached = await handle.evaluate(element => element.nodeType === 1 && element.isConnected && element.ownerDocument === document);
        assertCurrent();
        if (!attached) throw new Error('Raw AX reference changed during exact binding');
        node.actionable = true;
        await callObject(documentObjectId, 'function(attribute) { if (!delete this[attribute]) throw new Error("Raw AX bridge cleanup failed"); }', [attribute]);
        marked.delete(documentObjectId);
        await send('Runtime.releaseObject', { objectId: documentObjectId });
        objects.delete(documentObjectId);
      }
      await send('Runtime.releaseObject', { objectId: object.objectId });
      objects.delete(object.objectId);
    }
  } catch (cause) { failure = cause; }
  // Cleanup ignores operation epochs but touches only capture-owned resources.
  const cleanupErrors = [];
  const cleanup = async fn => { try { await fn(); } catch (cause) { cleanupErrors.push(cause); } };
  for (const objectId of marked) await cleanup(() => callObject(objectId, 'function(attribute) { if (!delete this[attribute]) throw new Error("Raw AX bridge cleanup failed"); }', [attribute], true));
  for (const candidate of candidates) await cleanup(() => candidate.dispose());
  for (const objectId of objects) await cleanup(() => session.send('Runtime.releaseObject', { objectId }));
  if (session) await cleanup(() => session.detach());
  if (!failure) { try { assertCurrent(); } catch (cause) { failure = cause; } }
  if (cleanupErrors.length || failure) {
    for (const handle of handles.values()) await cleanup(() => handle.dispose());
    if (cleanupErrors.length) throw error('Raw AX snapshot cleanup could not be confirmed', { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
    throw failure;
  }
  return { ...result, handles, refs: result.nodes.filter(node => node.actionable).map(({ ref, role, name }) => ({ ref, role: role.toLowerCase(), name })) };
}
