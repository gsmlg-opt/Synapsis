import os from "node:os";
import path from "node:path";
import { normalizeProfileName } from "../cli/profile-utils.mjs";
import { resolveProfileStateDir } from "../cli/profile-utils.mjs";
import { resolveHomeRelativePath } from "../infra/home-dir.mjs";
import { resolveRequiredHomeDir } from "../infra/home-dir.mjs";
import { LruCache } from "../infra/lru-cache.mjs";
const absoluteStateDirs = new LruCache        (64);
export function resolveNewStateDir(homedir               = resolveRequiredHomeDir)         {
  return path.join(homedir(), ".openclaw");
}
export function resolveStateDir(
  env                    = process.env,
  homedir               = os.homedir,
)         {
  const override = env.OPENCLAW_STATE_DIR?.trim();
  // Startup pins this absolute override. Other forms still observe home, cwd,
  // and the updater's invocation base; Windows rooted paths can depend on a drive cwd.
  if (override && process.platform !== "win32" && path.isAbsolute(override)) {
    const cached = absoluteStateDirs.peek(override);
    if (cached !== undefined) {
      return cached;
    }
    const resolved = path.resolve(override);
    absoluteStateDirs.set(override, resolved);
    return resolved;
  }
  if (override) {
    return resolveHomeRelativePath(override, { env, homedir });
  }
  return resolveStateDirFromHome(env, () => resolveRequiredHomeDir(env, homedir));
}
export function resolveStateDirFromHome(
  env                   ,
  effectiveHomedir              ,
)         {
  const profile = normalizeProfileName(env.OPENCLAW_PROFILE);
  return profile
    ? resolveProfileStateDir(profile, env, effectiveHomedir)
    : resolveNewStateDir(effectiveHomedir);
}
export { absoluteStateDirs };