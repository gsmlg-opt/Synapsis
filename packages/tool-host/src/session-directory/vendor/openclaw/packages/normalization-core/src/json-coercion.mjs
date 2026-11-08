import { asOptionalRecord } from "./record-coerce.mjs";

/** Parses JSON without throwing, returning undefined for invalid input. */
export function safeParseJson(value        )          {
  try {
    return JSON.parse(value)           ;
  } catch {
    return undefined;
  }
}

/** Parses JSON into a non-array record, returning undefined for every other result. */
export function safeParseJsonRecord(value        )                                      {
  return /^[\t\n\r ]*\{/.test(value) ? asOptionalRecord(safeParseJson(value)) : undefined;
}
