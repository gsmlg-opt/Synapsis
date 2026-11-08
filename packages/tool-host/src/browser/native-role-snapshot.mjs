import { randomUUID } from 'node:crypto';
import { appendSnapshotUrls, collectSnapshotUrls } from './snapshot-urls.mjs';
import { appendSnapshotDeltaSummary } from './snapshot-delta.mjs';

// Role membership follows the pinned OpenClaw 488631c snapshot-roles.ts contract.
// Tree capture, shaping and temporary identity binding below are local code.
const INTERACTIVE_ROLES = new Set(['button', 'checkbox', 'combobox', 'link', 'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'textbox', 'treeitem']);
const CONTENT_ROLES = new Set(['article', 'cell', 'columnheader', 'gridcell', 'heading', 'listitem', 'main', 'navigation', 'region', 'rowheader']);
const STRUCTURAL_ROLES = new Set(['application', 'directory', 'document', 'generic', 'grid', 'group', 'ignored', 'list', 'menu', 'menubar', 'none', 'presentation', 'row', 'rowgroup', 'table', 'tablist', 'toolbar', 'tree', 'treegrid']);
const value = field => field?.value === undefined ? '' : String(field.value);

function stateSuffix(node) {
  const properties = new Map((node.properties ?? []).map(item => [item.name, item.value?.value]));
  return ['checked', 'disabled', 'expanded', 'pressed', 'selected', 'level', 'invalid'].flatMap(name => {
    const state = properties.get(name);
    if (state === true || state === 'true') return [` [${name}]`];
    if (state === 'mixed' || (name === 'level' && typeof state === 'number') ||
        (name === 'invalid' && typeof state === 'string' && state !== 'false')) return [` [${name}=${state}]`];
    return [];
  }).join('');
}

// Traverse only descendants of the fixed selected root. Suppressed structural
// nodes still consume depth; ignored and unnamed generic nodes are transparent.
export function renderNativeRoleTree(nodes, rootBackendNodeId, options, nextRef) {
  const byId = new Map(nodes.map(node => [node.nodeId, node]));
  const root = nodes.find(node => node.backendDOMNodeId === rootBackendNodeId);
  if (!root) throw new Error('Snapshot root is absent from the native accessibility tree');
  const records = [];
  const visited = new Set();
  const occurrences = new Map();
  const ordinals = new Map();
  // The pin assigns duplicate identity in the native array's order, before
  // traversal, depth, interactive/compact shaping or output budgets.
  for (const node of nodes) {
    const normalized = value(node.role).toLowerCase();
    const name = value(node.name);
    const transparent = node.ignored === true || ['none', 'presentation', 'fragment'].includes(normalized) || (normalized === 'generic' && !name);
    const hasRef = INTERACTIVE_ROLES.has(normalized) || (CONTENT_ROLES.has(normalized) && Boolean(name)) || normalized === 'iframe';
    if (!hasRef || transparent) continue;
    const key = JSON.stringify([normalized, name]);
    const nth = occurrences.get(key) ?? 0;
    occurrences.set(key, nth + 1);
    ordinals.set(node, { nth, identity: JSON.stringify([normalized, name, nth]) });
  }
  const pending = [{ node: root, depth: 0 }];
  let truncated = false;
  while (pending.length) {
    const { node, depth } = pending.pop();
    if (visited.has(node.nodeId)) continue;
    visited.add(node.nodeId);
    const role = value(node.role);
    const normalized = role.toLowerCase();
    const name = value(node.name);
    const transparent = node.ignored === true || ['none', 'presentation', 'fragment'].includes(normalized) || (normalized === 'generic' && !name);
    const hasRef = INTERACTIVE_ROLES.has(normalized) || (CONTENT_ROLES.has(normalized) && Boolean(name)) || normalized === 'iframe';
    const { nth, identity } = ordinals.get(node) ?? {};
    const included = depth <= options.depth && !transparent && (options.interactive
      ? INTERACTIVE_ROLES.has(normalized) || normalized === 'iframe'
      : !(options.compact && STRUCTURAL_ROLES.has(normalized) && !name && !hasRef));
    if (included) records.push({ node, role, name, depth, hasRef, identity, nth });
    // Native iframe nodes are leaves in this scoped contract, even if a CDP
    // response happens to include a child frame's AX nodes.
    if (normalized !== 'iframe') {
      for (const id of [...(node.childIds ?? [])].reverse()) {
        const child = byId.get(id);
        if (child) pending.push({ node: child, depth: depth + (transparent ? 0 : 1) });
      }
    }
  }
  if (!records.length) records.push({ fallback: options.interactive ? '(no interactive elements)' : '(empty)' });
  const lines = [];
  const refs = [];
  const deltaKeys = new Set();
  const newKeys = options.previousKeys === undefined ? undefined : new Set();
  let chars = 0;
  let bytes = 0;
  for (const record of records) {
    if (lines.length >= options.limit) { truncated = true; break; }
    const { node, role, name, depth, hasRef, identity, nth } = record;
    const ref = hasRef ? nextRef() : undefined;
    const isNew = ref && newKeys !== undefined && !options.previousKeys.has(identity);
    const line = record.fallback ?? `${'  '.repeat(options.interactive ? 0 : depth)}- ${role}${name ? ` ${JSON.stringify(name)}` : ''}${ref ? ` [ref=${ref}]` : ''}${nth > 0 ? ` [nth=${nth}]` : ''}${stateSuffix(node)}${value(node.value) ? ` value=${JSON.stringify(value(node.value))}` : ''}${isNew ? ' [new]' : ''}`;
    const separator = lines.length ? 1 : 0;
    const size = Buffer.byteLength(line) + separator;
    if (chars + line.length + separator > options.maxChars || bytes + size > 262144) { truncated = true; break; }
    lines.push(line);
    chars += line.length + separator;
    bytes += size;
    if (ref) {
      refs.push({ ref, role: role.toLowerCase(), name, backendNodeId: node.backendDOMNodeId });
      deltaKeys.add(identity);
      if (isNew) newKeys.add(identity);
    }
  }
  return { snapshot: lines.join('\n'), refs, truncated, deltaKeys, ...(newKeys === undefined ? {} : { newElements: newKeys.size }) };
}

async function scopedNodes(send, backendNodeId) {
  const queried = await send('Accessibility.queryAXTree', { backendNodeId });
  if (queried.nodes.some(node => node.backendDOMNodeId === backendNodeId)) return queried.nodes;
  // Chromium omits an ignored root (and sometimes its descendants) in queryAXTree.
  const partial = await send('Accessibility.getPartialAXTree', { backendNodeId, fetchRelatives: true });
  const root = partial.nodes.find(node => node.backendDOMNodeId === backendNodeId);
  if (!root?.ignored || !root.nodeId) throw new Error('Snapshot root changed before native capture');
  if (!root.childIds?.length) return [root];
  const frameId = partial.nodes.find(node => node.frameId)?.frameId;
  if (!frameId) throw new Error('Snapshot native frame identity is unavailable');
  const full = await send('Accessibility.getFullAXTree', { frameId });
  const byId = new Map(full.nodes.map(node => [node.nodeId, node]));
  const nodes = [root];
  const seen = new Set([root.nodeId]);
  for (const node of nodes) for (const id of node.childIds ?? []) {
    const child = byId.get(id);
    if (child && !seen.has(id)) { seen.add(id); nodes.push(child); }
  }
  return nodes;
}

// All temporary identities, objects, searches, sessions and unadopted handles
// remain capture-owned until cleanup has succeeded and the caller adopts Map.
export async function captureNativeRoleSnapshot({ page, selector, frameSelector, options, nextRef, assertCurrent, dispatched, error }) {
  let frame = page.mainFrame();
  let frameElement;
  let root;
  let session;
  let searchId;
  let rootMarked = false;
  const rootAttribute = `data-synapsis-ax-root-${randomUUID()}`;
  const refAttribute = `data-synapsis-ax-ref-${randomUUID()}`;
  const objects = new Set();
  const markedObjects = new Set();
  const handles = new Map();
  let result;
  let failure;
  const checked = async promise => { const result = await promise; assertCurrent(); return result; };
  const send = async (method, params) => { assertCurrent(); return checked(session.send(method, params)); };
  const callObject = async (objectId, declaration, args, cleanup = false) => {
    if (!cleanup) assertCurrent();
    const response = await session.send('Runtime.callFunctionOn', {
      objectId, functionDeclaration: declaration, arguments: args.map(item => ({ value: item })), returnByValue: true,
    });
    if (!cleanup) assertCurrent();
    if (response.exceptionDetails) throw new Error('Native snapshot temporary identity operation failed');
    return response.result?.value;
  };
  try {
    assertCurrent();
    if (frameSelector) {
      frameElement = await page.locator(frameSelector).elementHandle();
      assertCurrent();
      if (!frameElement) throw new Error('Snapshot iframe is unavailable');
      frame = await checked(frameElement.contentFrame());
      if (!frame) throw new Error('Snapshot selector does not identify an attached iframe');
    }
    root = await frame.locator(selector).elementHandle();
    assertCurrent();
    if (!root) throw new Error('Snapshot root is unavailable');
    let owner = frame;
    for (;;) {
      assertCurrent();
      try {
        // A late attach is recorded before the guard and is detached by finally
        // before any command can execute on an expired operation.
        session = await page.context().newCDPSession(owner);
        assertCurrent();
        break;
      } catch (attachError) {
        assertCurrent();
        if (session || !String(attachError.message).includes('does not have a separate CDP session') || !owner.parentFrame()) throw attachError;
        owner = owner.parentFrame();
      }
    }
    dispatched();
    rootMarked = true;
    await checked(root.evaluate((element, attribute) => element.setAttribute(attribute, ''), rootAttribute));
    await send('DOM.getDocument', { depth: 0 });
    const search = await session.send('DOM.performSearch', { query: `[${rootAttribute}]`, includeUserAgentShadowDOM: true });
    searchId = search.searchId;
    assertCurrent();
    if (search.resultCount !== 1) throw new Error('Snapshot root changed before identity binding');
    const { nodeIds } = await send('DOM.getSearchResults', { searchId, fromIndex: 0, toIndex: 1 });
    const { node } = await send('DOM.describeNode', { nodeId: nodeIds[0] });
    const nodes = await scopedNodes(send, node.backendNodeId);
    assertCurrent();
    result = renderNativeRoleTree(nodes, node.backendNodeId, options, nextRef);
    if (options.urls) {
      const collected = await collectSnapshotUrls(frame);
      assertCurrent();
      const appended = appendSnapshotUrls(result.snapshot, collected, options.maxChars);
      result = { ...result, ...appended, truncated: result.truncated || appended.truncated };
    }
    result = appendSnapshotDeltaSummary(result, options.maxChars);
    for (const info of result.refs) {
      assertCurrent();
      if (!Number.isInteger(info.backendNodeId) || info.backendNodeId <= 0) throw new Error('Native AX reference has no DOM identity');
      const { object } = await session.send('DOM.resolveNode', { backendNodeId: info.backendNodeId });
      if (object.objectId) objects.add(object.objectId);
      assertCurrent();
      if (!object.objectId) throw new Error('Native AX reference could not be resolved');
      markedObjects.add(object.objectId);
      dispatched();
      const connected = await callObject(object.objectId, 'function(attribute, ref) { if (!this.isConnected || this.nodeType !== 1) return false; this.setAttribute(attribute, ref); return true; }', [refAttribute, info.ref]);
      if (!connected) throw new Error('Native AX reference is no longer an attached element');
      const handle = await frame.locator(`[${refAttribute}="${info.ref}"]`).elementHandle();
      if (handle) handles.set(info.ref, handle);
      assertCurrent();
      if (!handle) throw new Error('Native AX reference could not be bound to its exact element');
      await callObject(object.objectId, 'function(attribute) { this.removeAttribute(attribute); }', [refAttribute]);
      markedObjects.delete(object.objectId);
      await send('Runtime.releaseObject', { objectId: object.objectId });
      objects.delete(object.objectId);
    }
  } catch (cause) { failure = cause; }
  // Cleanup deliberately ignores the current-operation guard: old captures may
  // remove only their own random attributes, including on detached DOM objects.
  const cleanupErrors = [];
  const cleanup = async fn => { try { await fn(); } catch (cause) { cleanupErrors.push(cause); } };
  for (const objectId of markedObjects) await cleanup(() => callObject(objectId, 'function(attribute) { this.removeAttribute(attribute); }', [refAttribute], true));
  for (const objectId of objects) await cleanup(() => session.send('Runtime.releaseObject', { objectId }));
  if (searchId) await cleanup(() => session.send('DOM.discardSearchResults', { searchId }));
  if (rootMarked) await cleanup(() => root.evaluate((element, attribute) => element.removeAttribute(attribute), rootAttribute));
  if (root) await cleanup(() => root.dispose());
  if (frameElement) await cleanup(() => frameElement.dispose());
  if (session) await cleanup(() => session.detach());
  if (!failure) {
    try { assertCurrent(); } catch (cause) { failure = cause; }
  }
  if (cleanupErrors.length || failure) {
    for (const handle of handles.values()) await cleanup(() => handle.dispose());
    if (cleanupErrors.length) throw error('Native snapshot cleanup could not be confirmed', { cleanup_confirmed: false, snapshot_cleanup_confirmed: false });
    throw failure;
  }
  return { ...result, handles, refs: result.refs.map(({ backendNodeId: _identity, ...info }) => info) };
}
