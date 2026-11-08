export function tryProcessCwd()                     {
  try {
    return process.cwd();
  } catch {
    return undefined;
  }
}