import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalLowercaseString } from "../../packages/normalization-core/src/string-coerce.mjs";
const TOOL_RESULT_FAILURE_STATUSES = new Map                               ([
  ["error", "failed"],
  ["failed", "failed"],
  ["failure", "failed"],
  ["timeout", "timed_out"],
  ["timed_out", "timed_out"],
  ["blocked", "blocked"],
  ["denied", "blocked"],
  ["forbidden", "blocked"],
  ["unavailable", "failed"],
  ["approval-unavailable", "blocked"],
  ["disabled", "blocked"],
  ["aborted", "cancelled"],
  ["cancelled", "cancelled"],
  ["canceled", "cancelled"],
  ["killed", "cancelled"],
  ["invalid", "failed"],
]);
function readToolErrorField(error        , key        )          {
  try {
    return key in error ? (error                           )[key] : undefined;
  } catch {
    return undefined;
  }
}
export function readToolResultDetails(result         )                                      {
  if (!result || typeof result !== "object") {
    return undefined;
  }
  try {
    return asOptionalRecord(readToolErrorField(result, "details"));
  } catch {
    return undefined;
  }
}
export function isToolResultError(result         )          {
  return resolveToolResultFailureKind(result) !== undefined;
}
export function resolveToolResultFailureKind(result         )                                    {
  const details = readToolResultDetails(result);
  if (!details) {
    return undefined;
  }
  const status = normalizeOptionalLowercaseString(readToolErrorField(details, "status"));
  const statusKind = TOOL_RESULT_FAILURE_STATUSES.get(status ?? "");
  const ok = readToolErrorField(details, "ok");
  const success = readToolErrorField(details, "success");
  const timedOut = readToolErrorField(details, "timedOut") === true;
  const exitCode = readToolErrorField(details, "exitCode");
  if (
    ok !== false &&
    success !== false &&
    (!statusKind || ok === true || success === true) &&
    !timedOut &&
    !readToolErrorField(details, "error") &&
    (status === "completed" ||
      typeof exitCode !== "number" ||
      !Number.isFinite(exitCode) ||
      exitCode === 0)
  ) {
    return undefined;
  }
  if (statusKind === "blocked") {
    return "blocked";
  }
  return timedOut ? "timed_out" : (statusKind ?? "failed");
}
export { TOOL_RESULT_FAILURE_STATUSES, readToolErrorField };