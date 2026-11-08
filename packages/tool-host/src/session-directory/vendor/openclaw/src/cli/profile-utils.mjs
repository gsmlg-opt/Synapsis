import path from "node:path";
import { normalizeLowercaseStringOrEmpty } from "../../packages/normalization-core/src/string-coerce.mjs";
import { resolveRequiredHomeDir } from "../infra/home-dir.mjs";
const PROFILE_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/i;
export function isValidProfileName(value        )          {
  return PROFILE_NAME_RE.test(value);
}
export function normalizeProfileName(raw                )                {
  const profile = raw?.trim();
  if (!profile) {
    return null;
  }
  if (normalizeLowercaseStringOrEmpty(profile) === "default") {
    return null;
  }
  if (!isValidProfileName(profile)) {
    return null;
  }
  return profile;
}
export function resolveProfileStateDir(
  profile        ,
  env                   ,
  homedir              ,
)         {
  const trimmed = profile.trim();
  if (!isValidProfileName(trimmed)) {
    throw new Error(`Invalid profile name: ${JSON.stringify(profile)}`);
  }
  const suffix = normalizeLowercaseStringOrEmpty(trimmed) === "default" ? "" : `-${trimmed}`;
  return path.join(resolveRequiredHomeDir(env, homedir), `.openclaw${suffix}`);
}
export { PROFILE_NAME_RE };