import os from "node:os";
import path from "node:path";
import { resolveStateDir } from "../config/state-dir.mjs";
import { resolveUserPath } from "./home-dir.mjs";
export function resolveConfigDir(
  env                    = process.env,
  homedir               = os.homedir,
)         {
  const override = env.OPENCLAW_STATE_DIR?.trim();
  if (override) {
    return resolveUserPath(override, env, homedir);
  }
  const configPath = env.OPENCLAW_CONFIG_PATH?.trim();
  if (configPath) {
    return path.dirname(resolveUserPath(configPath, env, homedir));
  }
  return resolveStateDir(env, homedir);
}