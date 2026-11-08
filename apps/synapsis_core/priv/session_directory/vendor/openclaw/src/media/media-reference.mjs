import path from "node:path";
import { safeFileURLToPath } from "../../../fs-safe/safe-file-url-to-path.mjs";
import { relativePathEscapesRoot } from "../infra/path-guards.mjs";
import { resolveUserPath } from "../infra/home-dir.mjs";
import { parseInboundMediaUri } from "./inbound-media-uri.mjs";
import { getMediaDir } from "./store.mjs";
function maybeLocalPathFromSource(source        )                {
  if (/^file:/i.test(source)) {
    try {
      return safeFileURLToPath(source);
    } catch {
      return null;
    }
  }
  if (source.startsWith("~")) {
    return resolveUserPath(source);
  }
  if (path.isAbsolute(source)) {
    return source;
  }
  return null;
}
export function buildInboundMediaUriFromPath(source        )                     {
  const localPath = maybeLocalPathFromSource(source.trim());
  if (!localPath) {
    return undefined;
  }
  const inboundDir = path.resolve(getMediaDir(), "inbound");
  const relativePath = path.relative(inboundDir, path.resolve(localPath));
  // The inbound id must be a single path component that does not escape the store bucket;
  // reject traversal, nested segments, and absolute/empty results.
  if (
    !relativePath ||
    relativePathEscapesRoot(relativePath) ||
    relativePath.includes(path.sep) ||
    relativePath.includes("\\")
  ) {
    return undefined;
  }
  try {
    const parsed = parseInboundMediaUri(`media://inbound/${relativePath}`);
    return parsed?.normalizedSource;
  } catch {
    // Malformed percent-encoded ids (e.g. a stray `%`) make the URI decoder throw;
    // redact instead of propagating the failure into the shared history projection.
    return undefined;
  }
}
export { parseInboundMediaUri, maybeLocalPathFromSource };