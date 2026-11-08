/** Type guard for non-array object records at browser-safe boundaries. */
export function isRecord(value         )                                   {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function isStringArray(value         )                    {
  return Array.isArray(value) && value.every((entry) => typeof entry === "string");
}

/** Coerces object-like values to records, falling back to an empty record. */
export function asRecord(value         )                          {
  return asOptionalObjectRecord(value) ?? {};
}

/** Reads a field only when it exists as a string. */
export function readStringField(
  record                                            ,
  key        ,
)                     {
  const value = record?.[key];
  return typeof value === "string" ? value : undefined;
}

/** Returns a non-array record or undefined. */
export function asOptionalRecord(value         )                                      {
  return isRecord(value) ? value : undefined;
}

/** Returns a non-array record or a fresh ordinary empty record. */
export function asNonArrayRecord(value         )                          {
  return asOptionalRecord(value) ?? {};
}

export function ensureRecord(root                         , key        )                          {
  const current = asOptionalRecord(root[key]);
  if (current) {
    return current;
  }
  const next                          = {};
  root[key] = next;
  return next;
}

/** Returns a non-array record or null. */
export function asNullableRecord(value         )                                 {
  return isRecord(value) ? value : null;
}

/** Returns any object-backed record, including arrays, or undefined. */
export function asOptionalObjectRecord(value         )                                      {
  return value && typeof value === "object" ? (value                           ) : undefined;
}

/** Returns any object-backed record, including arrays, or null. */
export function asNullableObjectRecord(value         )                                 {
  return asOptionalObjectRecord(value) ?? null;
}

/** Checks that every enumerable own value in a non-array record is a string. */
export function isStringRecord(value         )                                  {
  return isRecord(value) && Object.values(value).every((entry) => typeof entry === "string");
}

/** Removes undefined fields from a fresh projection in place, retaining its identity. */
export function omitUndefinedFields                  (fields   )    {
  for (const key in fields) {
    if (fields[key] === undefined) {
      delete fields[key];
    }
  }
  return fields;
}

/** Retains string-valued own enumerable entries from a non-array record. */
export function filterStringRecord(value         )                                     {
  if (!isRecord(value)) {
    return undefined;
  }
  const entries = Object.entries(value).filter(
    (entry)                            => typeof entry[1] === "string",
  );
  return entries.length > 0 ? Object.fromEntries(entries) : undefined;
}
