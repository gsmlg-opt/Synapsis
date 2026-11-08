import { collectNestedErrorCandidates } from "../../packages/normalization-core/src/error-coercion.mjs";
import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
const STORAGE_ERRORS = [
  ["SQLITE_BUSY", "database is locked", 5],
  ["SQLITE_LOCKED", "database table is locked", 6],
  ["SQLITE_READONLY", "attempt to write a readonly database", 8],
  ["SQLITE_IOERR", "disk I/O error", 10],
  ["SQLITE_IOERR", "unable to open database file", 14],
  ["SQLITE_FULL", "database or disk is full", 13],
  ["transcript_writer_fenced", "session writer claim changed before transcript persistence", -1],
  [
    "session_actor_reconciliation",
    "Session actor requires reconciliation before another command",
    -2,
  ],
]         ;
export function classifyGatewayStorageFailure(error         )                                    {
  let reconciliation                                   ;
  for (const candidate of collectNestedErrorCandidates(error)) {
    const failure = classifyStorageFailure(candidate);
    if (failure === "session_actor_reconciliation") {
      reconciliation = failure;
    } else if (failure) {
      return failure;
    }
  }
  return reconciliation;
}
function classifyStorageFailure(error         )                                    {
  const fields = typeof error === "string" ? { message: error } : isRecord(error) ? error : {};
  const code = fields.errorCode ?? fields.code;
  if (code === "ENOSPC") {
    return "SQLITE_FULL";
  }
  if (code === "EIO") {
    return "SQLITE_IOERR";
  }
  if (
    typeof code === "string" &&
    (code === "SQLITE_CANTOPEN" || code.startsWith("SQLITE_CANTOPEN_"))
  ) {
    return "SQLITE_IOERR";
  }
  const nativeCode = fields.errcode;
  const primaryCode =
    typeof nativeCode === "number" && Number.isInteger(nativeCode) && nativeCode >= 0
      ? nativeCode & 0xff
      : undefined;
  const typed = STORAGE_ERRORS.find(
    ([name, , number]) =>
      primaryCode === number ||
      (typeof code === "string" &&
        (code === name || (name.startsWith("SQLITE_") && code.startsWith(`${name}_`)))),
  );
  return (typed ??
    STORAGE_ERRORS.find(([, message]) =>
      [fields.errstr, fields.errorMessage, fields.message].some(
        (value) => typeof value === "string" && value.trim() === message,
      ),
    ))?.[0];
}
export { STORAGE_ERRORS, classifyStorageFailure };