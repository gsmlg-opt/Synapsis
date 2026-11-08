export const WORKSPACE_CONFLICT_TRANSCRIPT_TYPE = "cloud-workspace-conflict";
const MAX_PROJECTED_CONFLICT_PATHS = 256;
const MAX_PROJECTED_CONFLICT_PATH_BYTES = 32 * 1024;
export function projectWorkspaceResultConflict(
  paths                   ,
  stagedResultRef        ,
  knownTotalCount         ,
)                                          {
  const uniquePaths = [...new Set(paths)].toSorted();
  const projectedPaths           = [];
  let projectedBytes = 0;
  for (const entryPath of uniquePaths) {
    const bytes = Buffer.byteLength(entryPath);
    if (
      projectedPaths.length >= MAX_PROJECTED_CONFLICT_PATHS ||
      projectedBytes + bytes > MAX_PROJECTED_CONFLICT_PATH_BYTES
    ) {
      break;
    }
    projectedPaths.push(entryPath);
    projectedBytes += bytes;
  }
  if (projectedPaths.length === 0) {
    throw new Error("Cloud workspace result conflict projection has no bounded path");
  }
  return {
    paths: projectedPaths,
    stagedResultRef,
    totalCount: Math.max(knownTotalCount ?? uniquePaths.length, uniquePaths.length),
  };
}
export { MAX_PROJECTED_CONFLICT_PATHS, MAX_PROJECTED_CONFLICT_PATH_BYTES };