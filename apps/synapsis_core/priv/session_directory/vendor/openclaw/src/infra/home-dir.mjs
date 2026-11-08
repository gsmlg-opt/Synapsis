import { AsyncLocalStorage } from "node:async_hooks";
import os from "node:os";
import path from "node:path";
import { normalizeHomeDirValue } from "../../packages/normalization-core/src/home-dir.mjs";
import { resolveEffectiveHomeDir } from "../../packages/normalization-core/src/home-dir.mjs";
import { resolveGlobalSingleton } from "../shared/global-singleton.mjs";
import { tryProcessCwd } from "./safe-cwd.mjs";
const userPathBaseDirectory = resolveGlobalSingleton(
  Symbol.for("openclaw.userPathBaseDirectory"),
  () => new AsyncLocalStorage        (),
);
export function withUserPathBaseDirectory   (cwd                    , operation         )    {
  return cwd === undefined ? operation() : userPathBaseDirectory.run(path.resolve(cwd), operation);
}
export function resolveRequiredHomeDir(
  env                    = process.env,
  homedir               = os.homedir,
)         {
  const resolved = resolveEffectiveHomeDir(env, homedir) ?? tryProcessCwd();
  if (resolved) {
    return path.resolve(resolved);
  }
  throw new Error(
    "Unable to resolve an OpenClaw home: set OPENCLAW_HOME, HOME, or USERPROFILE, or run from an existing directory.",
  );
}
export function expandHomePrefix(
  input        ,
  opts    
                  
                            
                           
   ,
)         {
  if (!input.startsWith("~")) {
    return input;
  }
  const home =
    normalizeHomeDirValue(opts?.home) ??
    resolveEffectiveHomeDir(opts?.env ?? process.env, opts?.homedir ?? os.homedir);
  if (!home) {
    return input;
  }
  return input.replace(/^~(?=$|[\\/])/, () => home);
}
function resolvePathWithHome(
  input        ,
  opts                             ,
  resolveHome                               ,
)         {
  const trimmed = input.trim();
  if (!trimmed) {
    return trimmed;
  }
  const expanded = trimmed.startsWith("~")
    ? expandHomePrefix(trimmed, {
        home: resolveHome(opts?.env ?? process.env, opts?.homedir ?? os.homedir),
        env: opts?.env,
        homedir: opts?.homedir,
      })
    : trimmed;
  const base = userPathBaseDirectory.getStore();
  return base ? path.resolve(base, expanded) : path.resolve(expanded);
}
export function resolveHomeRelativePath(input        , opts                  )         {
  return resolvePathWithHome(input, opts, resolveRequiredHomeDir);
}
export function resolveUserPath(
  input        ,
  env                    = process.env,
  homedir               = os.homedir,
)         {
  if (!input) {
    return "";
  }
  return resolveHomeRelativePath(input, { env, homedir });
}
export { resolveEffectiveHomeDir, userPathBaseDirectory, resolvePathWithHome };