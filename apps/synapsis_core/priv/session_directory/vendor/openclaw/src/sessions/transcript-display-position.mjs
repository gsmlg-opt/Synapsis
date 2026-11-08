import { createHash } from "node:crypto";
export function createTranscriptDisplaySource(parts                   )         {
  return createHash("sha256").update(JSON.stringify(parts)).digest("base64url");
}