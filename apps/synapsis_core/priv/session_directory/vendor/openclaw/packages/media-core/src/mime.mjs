import path from "node:path";
import { mediaKindFromMime } from "./constants.mjs";
import { extnameFromAnyPath } from "./file-name.mjs";
const EXT_BY_MIME                         = {
  "image/avif": ".avif",
  "image/heic": ".heic",
  "image/heic-sequence": ".heic",
  "image/heif": ".heif",
  "image/heif-sequence": ".heif",
  "image/bmp": ".bmp",
  "image/jpg": ".jpg",
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/svg+xml": ".svg",
  "image/webp": ".webp",
  "image/gif": ".gif",
  "audio/aiff": ".aiff",
  "audio/x-aiff": ".aiff",
  "audio/ogg": ".ogg",
  "audio/mpeg": ".mp3",
  "audio/mp3": ".mp3",
  "audio/wav": ".wav",
  "audio/wave": ".wav",
  "audio/x-wav": ".wav",
  "audio/flac": ".flac",
  "audio/aac": ".aac",
  "audio/amr": ".amr",
  "audio/opus": ".opus",
  "audio/webm": ".webm",
  "audio/x-m4a": ".m4a",
  "audio/m4a": ".m4a",
  "audio/mp4": ".m4a",
  "audio/x-caf": ".caf",
  "video/x-msvideo": ".avi",
  "video/x-m4v": ".m4v",
  "video/mp4": ".mp4",
  "video/x-matroska": ".mkv",
  "video/webm": ".webm",
  "video/x-flv": ".flv",
  "video/x-ms-wmv": ".wmv",
  "video/quicktime": ".mov",
  "application/pdf": ".pdf",
  "application/json": ".json",
  "application/yaml": ".yaml",
  "application/zip": ".zip",
  "application/gzip": ".gz",
  "application/x-tar": ".tar",
  "application/x-7z-compressed": ".7z",
  "application/vnd.rar": ".rar",
  "application/msword": ".doc",
  "application/vnd.ms-excel": ".xls",
  "application/vnd.ms-powerpoint": ".ppt",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
  "text/csv": ".csv",
  "text/plain": ".txt",
  "text/markdown": ".md",
  "text/html": ".html",
  "text/xml": ".xml",
  "text/css": ".css",
  "application/xml": ".xml",
};
const MIME_BY_EXT                         = {
  ...buildMimeByExt(),
  // Canonical extension mappings for common MIME aliases
  ".jpg": "image/jpeg",
  ".m2a": "audio/mpeg",
  ".m4b": "audio/mp4",
  ".mp3": "audio/mpeg",
  ".oga": "audio/ogg",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".aif": "audio/aiff",
  ".aifc": "audio/aiff",
  ".jpeg": "image/jpeg",
  ".cfg": "text/plain",
  ".conf": "text/plain",
  ".env": "text/plain",
  ".ini": "text/plain",
  ".js": "text/javascript",
  ".log": "text/plain",
  ".htm": "text/html",
  ".tsv": "text/tab-separated-values",
  ".xml": "text/xml",
  ".yml": "application/yaml",
};
const MIME_SYNONYMS                         = {
  "image/apng": "image/png",
  "text/yaml": "application/yaml",
  "application/x-yaml": "application/yaml",
  "application/xml": "text/xml",
  // Preserve shipped filename/header spellings for byte-detected container aliases.
  "video/vnd.avi": "video/x-msvideo",
  "video/matroska": "video/x-matroska",
};
function buildMimeByExt()                         {
  const byExt                         = {};
  for (const [mime, ext] of Object.entries(EXT_BY_MIME)) {
    byExt[ext] ??= mime;
  }
  return byExt;
}
export function normalizeMimeType(mime                )                     {
  if (!mime) {
    return undefined;
  }
  const cleaned = mime.split(";")[0]?.trim().toLowerCase();
  if (!cleaned) {
    return undefined;
  }
  // Object.hasOwn: a remote "__proto__"/"constructor" header would otherwise
  // resolve to inherited Object.prototype members and break the string contract.
  return Object.hasOwn(MIME_SYNONYMS, cleaned) ? MIME_SYNONYMS[cleaned] : cleaned;
}
export function getFileExtension(filePath                )                     {
  if (!filePath) {
    return undefined;
  }
  const url = /^https?:\/\//i.test(filePath) ? URL.parse(filePath) : null;
  if (url) {
    let filename = url.pathname.slice(url.pathname.lastIndexOf("/") + 1);
    try {
      // Decode only the URL filename while keeping encoded separators literal.
      const decodable = filename.replace(/%2f/gi, "%252F").replace(/%5c/gi, "%255C");
      filename = decodeURIComponent(decodable);
    } catch {
      // Preserve the raw filename when its own percent encoding is malformed.
    }
    return path.posix.extname(filename).toLowerCase() || undefined;
  }
  const ext = extnameFromAnyPath(filePath).toLowerCase();
  return ext || undefined;
}
export function mimeTypeFromFilePath(filePath                )                     {
  const ext = getFileExtension(filePath);
  if (!ext) {
    return undefined;
  }
  return MIME_BY_EXT[ext];
}
export function kindFromMime(mime                )                        {
  return mediaKindFromMime(normalizeMimeType(mime));
}