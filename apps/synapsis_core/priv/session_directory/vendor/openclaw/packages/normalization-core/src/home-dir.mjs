import os from "node:os";
import path from "node:path";
export function normalizeHomeDirValue(value                    )                     {
  const trimmed = value?.trim();
  return trimmed && trimmed !== "undefined" && trimmed !== "null" ? trimmed : undefined;
}
function normalizeSafe(homedir              )                     {
  try {
    return normalizeHomeDirValue(homedir());
  } catch {
    return undefined;
  }
}
function resolveTermuxHome(env                   )                     {
  const prefix = normalizeHomeDirValue(env.PREFIX);
  if (!prefix || !normalizeHomeDirValue(env.ANDROID_DATA)) {
    return undefined;
  }
  if (!/(?:^|\/)com\.termux\/files\/usr\/?$/u.test(prefix.replace(/\\/gu, "/"))) {
    return undefined;
  }
  return path.resolve(prefix, "..", "home");
}
function resolveRawOsHomeDir(env                   , homedir              )                     {
  return (
    normalizeHomeDirValue(env.HOME) ??
    normalizeHomeDirValue(env.USERPROFILE) ??
    resolveTermuxHome(env) ??
    normalizeSafe(homedir)
  );
}
export function resolveOsHomeDir(
  env                    = process.env,
  homedir               = os.homedir,
)                     {
  const raw = resolveRawOsHomeDir(env, homedir);
  return raw ? path.resolve(raw) : undefined;
}
export function resolveEffectiveHomeDir(
  env                    = process.env,
  homedir               = os.homedir,
  options                                        ,
)                     {
  const explicitHome = normalizeHomeDirValue(env.OPENCLAW_HOME);
  if (!explicitHome) {
    return resolveOsHomeDir(env, homedir);
  }
  if (explicitHome === "~" || explicitHome.startsWith("~/") || explicitHome.startsWith("~\\")) {
    const osHome = resolveRawOsHomeDir(env, homedir);
    if (!osHome) {
      return options?.preserveUnresolvedTilde ? path.resolve(explicitHome) : undefined;
    }
    return path.resolve(explicitHome.replace(/^~(?=$|[\\/])/, () => osHome));
  }
  return path.resolve(explicitHome);
}
export { normalizeSafe, resolveTermuxHome, resolveRawOsHomeDir };