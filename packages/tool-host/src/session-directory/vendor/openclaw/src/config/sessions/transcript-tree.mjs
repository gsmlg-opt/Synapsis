import { isRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
import { readNonBlankString as readNonEmptyString } from "../../../packages/normalization-core/src/string-coerce.mjs";
function isCanonicalSessionEntryType(value         )          {
  switch (value) {
    case "message":
    case "thinking_level_change":
    case "model_change":
    case "compaction":
    case "reset":
    case "branch_summary":
    case "custom":
    case "custom_message":
    case "label":
    case "session_info":
      return true;
    default:
      return false;
  }
}
export function isCanonicalSessionTranscriptEntry(
  record         ,
)                                                {
  return isRecord(record) && isCanonicalSessionEntryType(record.type);
}
export function isSessionTranscriptLeafControl(
  record         ,
)                                                {
  return (
    isRecord(record) &&
    record.type === "leaf" &&
    parseSessionTranscriptTreeEntry(record) !== undefined
  );
}
export function parseSessionTranscriptTreeEntry(
  record         ,
)                                         {
  if (!isRecord(record) || record.type === "session" || !Object.hasOwn(record, "parentId")) {
    return undefined;
  }
  const id = readNonEmptyString(record.id);
  const parentId =
    record.parentId === null ? null : (readNonEmptyString(record.parentId) ?? undefined);
  if (!id || parentId === undefined) {
    return undefined;
  }
  if (record.type === "leaf") {
    const targetId =
      record.targetId === null ? null : (readNonEmptyString(record.targetId) ?? undefined);
    const appendParentId =
      record.appendParentId === undefined
        ? targetId
        : record.appendParentId === null
          ? null
          : (readNonEmptyString(record.appendParentId) ?? undefined);
    const appendMode =
      record.appendMode === undefined ? undefined : record.appendMode === "side" ? "side" : null;
    return targetId === undefined || appendParentId === undefined || appendMode === null
      ? undefined
      : {
          id,
          parentId: targetId,
          leafId: targetId,
          appendParentId,
          ...(appendMode ? { appendMode } : {}),
        };
  }
  return {
    id,
    parentId,
    leafId:
      isCanonicalSessionTranscriptEntry(record) && record.appendMode !== "side" ? id : undefined,
    appendParentId: id,
    ...(record.appendMode === "side" ? { appendMode: record.appendMode } : {}),
  };
}
function parseParentlessCanonicalEntry(
  record         ,
  parentId               ,
)                                         {
  if (!isCanonicalSessionTranscriptEntry(record) || Object.hasOwn(record, "parentId")) {
    return undefined;
  }
  const id = readNonEmptyString(record.id);
  return id
    ? {
        id,
        parentId,
        leafId: record.appendMode === "side" ? undefined : id,
        appendParentId: id,
        ...(record.appendMode === "side" ? { appendMode: record.appendMode } : {}),
      }
    : undefined;
}
function resolveCanonicalParentId   (
  parentId               ,
  byId                                                                ,
)                {
  let seen                         ;
  let currentId = parentId;
  while (currentId !== null) {
    if (seen?.has(currentId)) {
      return currentId;
    }
    const parent = byId.get(currentId);
    if (!parent || !isSessionTranscriptLeafControl(parent.entry)) {
      return currentId;
    }
    (seen ??= new Set()).add(currentId);
    // Leaf controls are omitted from selected paths, so descendants must point
    // through the marker to its normalized visible parent.
    currentId = parent.parentId;
  }
  return null;
}
export function scanSessionTranscriptTree   (entries             )                           {
  const nodes                                 = [];
  const byId = new Map                                      ();
  const storage                                        = {
    byId,
    addNode: (node) => nodes.push(node),
    resetDescendantIds: new Set(),
    invalidLeafControlIds: new Set(),
  };
  return { nodes, byId, ...scanSessionTranscriptNavigation(entries, storage) };
}
export function resolveSessionTranscriptActiveLeafEntryId(
  events                    ,
)                     {
  return scanSessionTranscriptTree(events).leafId ?? undefined;
}
export function scanSessionTranscriptNavigation   (
  entries             ,
  storage                                       ,
  cursor                                    ,
)                                                   {
  const { byId, resetDescendantIds, invalidLeafControlIds } = storage;
  let leafId = cursor?.leafId ?? null;
  let appendParentId = cursor?.appendParentId ?? null;
  let hasLeafControl = cursor?.hasLeafControl ?? false;
  let hasLeafUpdate = cursor?.hasLeafUpdate ?? false;
  let hasExplicitLeafUpdate = cursor?.hasExplicitLeafUpdate ?? false;
  let hasInvalidLeafControl = cursor?.hasInvalidLeafControl ?? false;
  let latestResetId = cursor?.latestResetId;

  let nextIndex = cursor?.nextIndex ?? 0;
  for (const entry of entries) {
    const index = nextIndex++;
    let explicitTreeEntry = parseSessionTranscriptTreeEntry(entry);
    const isLeafControl =
      explicitTreeEntry !== undefined && isRecord(entry) && entry.type === "leaf";
    if (
      latestResetId &&
      leafId !== null &&
      explicitTreeEntry?.leafId !== undefined &&
      isLeafControl &&
      (explicitTreeEntry.leafId === null || !resetDescendantIds.has(explicitTreeEntry.leafId))
    ) {
      explicitTreeEntry = {
        ...explicitTreeEntry,
        parentId: leafId,
        leafId,
        appendParentId: leafId,
      };
    }
    const isKnownLeafReference = (id               )          =>
      id === null || (byId.has(id) && !invalidLeafControlIds.has(id));
    const invalidLeafControl =
      explicitTreeEntry?.leafId !== undefined &&
      isLeafControl &&
      (!isKnownLeafReference(explicitTreeEntry.leafId) ||
        !isKnownLeafReference(explicitTreeEntry.appendParentId));
    if (invalidLeafControl && explicitTreeEntry) {
      hasInvalidLeafControl = true;
      invalidLeafControlIds.add(explicitTreeEntry.id);
      const rawParentId = (entry                    ).parentId                 ;
      const node                               = {
        ...explicitTreeEntry,
        parentId: rawParentId,
        leafId: undefined,
        appendParentId,
        entry,
        index,
      };
      // Invalid controls are transparent structural markers. Descendants can
      // repair through their raw parent, but navigation state does not change.
      storage.addNode(node);
      byId.set(node.id, node);
      continue;
    }
    let treeEntry                                         =
      explicitTreeEntry ?? parseParentlessCanonicalEntry(entry, leafId);
    if (treeEntry && isCanonicalSessionTranscriptEntry(entry)) {
      const canonicalParentIsStale =
        explicitTreeEntry &&
        treeEntry.parentId !== null &&
        !byId.has(treeEntry.parentId) &&
        leafId !== null;
      const crossesResetBoundary =
        latestResetId !== undefined &&
        treeEntry.appendMode !== "side" &&
        (treeEntry.parentId === null || !resetDescendantIds.has(treeEntry.parentId));
      const logicalParentId = crossesResetBoundary
        ? leafId
        : treeEntry.appendMode !== "side" && canonicalParentIsStale
          ? leafId
          : explicitTreeEntry &&
              treeEntry.appendMode !== "side" &&
              treeEntry.parentId === appendParentId &&
              leafId !== appendParentId
            ? leafId
            : treeEntry.parentId;
      const normalizedParentId = resolveCanonicalParentId(logicalParentId, byId);
      if (normalizedParentId !== treeEntry.parentId) {
        // The raw cursor can belong to plugin metadata, an inactive branch, or
        // an omitted leaf marker. Keep physical append state separate from the
        // visible ancestry consumed by context builders.
        treeEntry = { ...treeEntry, parentId: normalizedParentId };
      }
    }
    if (!treeEntry) {
      continue;
    }
    const node                               = { ...treeEntry, entry, index };
    storage.addNode(node);
    byId.set(node.id, node);
    if (isRecord(entry) && entry.type === "reset") {
      latestResetId = node.id;
      resetDescendantIds.clear();
      resetDescendantIds.add(node.id);
    } else if (
      latestResetId !== undefined &&
      node.parentId !== null &&
      resetDescendantIds.has(node.parentId)
    ) {
      resetDescendantIds.add(node.id);
    }
    appendParentId = node.appendParentId;
    if (node.leafId !== undefined) {
      leafId = node.leafId;
      hasLeafUpdate = true;
      if (explicitTreeEntry) {
        hasExplicitLeafUpdate = true;
      }
    }
    if (isLeafControl) {
      hasLeafControl = true;
    }
  }

  const navigation = {
    leafId,
    appendParentId,
    hasLeafControl,
    hasLeafUpdate,
    hasExplicitLeafUpdate,
    hasInvalidLeafControl,
  };
  if (cursor) {
    Object.assign(cursor, navigation, { latestResetId, nextIndex });
  }
  return navigation;
}
export { isCanonicalSessionEntryType, parseParentlessCanonicalEntry, resolveCanonicalParentId };