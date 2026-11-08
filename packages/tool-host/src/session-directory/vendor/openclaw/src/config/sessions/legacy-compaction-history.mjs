import { asOptionalRecord } from "../../../packages/normalization-core/src/record-coerce.mjs";
export function readLegacyCompactionMetrics(entry         )                          {
  try {
    return readLegacyCompactionHistory(entry).flatMap((checkpoint) => {
      const entryId = checkpoint.postCompaction.entryId;
      return entryId
        ? [{ entryId, tokensBefore: checkpoint.tokensBefore, tokensAfter: checkpoint.tokensAfter }]
        : [];
    });
  } catch {
    // Corrupt legacy metadata cannot hide readable transcript history.
    return [];
  }
}
export function readLegacyCompactionHistory(entry         )                                     {
  const checkpoints = asOptionalRecord(entry)?.compactionCheckpoints;
  if (checkpoints == null) {
    return [];
  }
  // Malformed references must fail closed, not make protected history reclaimable.
  if (!Array.isArray(checkpoints)) {
    throw new TypeError("Invalid legacy compaction history references");
  }
  return checkpoints.map((checkpoint)                          => {
    const record = asOptionalRecord(checkpoint);
    const pre = asOptionalRecord(record?.preCompaction);
    const post = asOptionalRecord(record?.postCompaction);
    if (!record || !pre || !post) {
      throw new TypeError("Invalid legacy compaction history references");
    }
    const string = (value         )                     => {
      if (value == null) {
        return undefined;
      }
      if (typeof value !== "string") {
        throw new TypeError("Invalid legacy compaction history reference");
      }
      return value;
    };
    const number = (value         )                     =>
      typeof value === "number" && Number.isFinite(value) ? value : undefined;
    return {
      sessionId: string(record.sessionId),
      preCompaction: { sessionId: string(pre.sessionId), sessionFile: string(pre.sessionFile) },
      postCompaction: {
        sessionId: string(post.sessionId),
        sessionFile: string(post.sessionFile),
        entryId: string(post.entryId),
      },
      tokensBefore: number(record.tokensBefore),
      tokensAfter: number(record.tokensAfter),
    };
  });
}