import path from "node:path";
import { resolveConfigDir } from "../infra/config-dir.mjs";
export function getMediaDir() {
  return path.join(resolveConfigDir(), "media");
}