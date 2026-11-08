import path from "node:path";
export function relativePathEscapesRoot(relativePath        )          {
  return (
    relativePath === ".." ||
    relativePath.startsWith("../") ||
    relativePath.startsWith("..\\") ||
    path.isAbsolute(relativePath)
  );
}