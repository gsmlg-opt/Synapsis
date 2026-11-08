/** Reads a value only when it is already a string, preserving whitespace. */
export function readStringValue(value         )                     {
  return typeof value === "string" ? value : undefined;
}

/** Trims string input and returns null for non-strings or empty strings. */
export function normalizeNullableString(value         )                {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/** Trims string input and returns undefined for non-strings or empty strings. */
export function normalizeOptionalString(value         )                     {
  return normalizeNullableString(value) ?? undefined;
}

/** Trims bounded string input and rejects blank, non-string, or overlong values. */
export function normalizeBoundedOptionalString(
  value         ,
  maxLength        ,
)                     {
  if (!Number.isInteger(maxLength) || maxLength < 0) {
    return undefined;
  }
  const normalized = normalizeOptionalString(value);
  return normalized && normalized.length <= maxLength ? normalized : undefined;
}

/** Requires non-blank string input while preserving its original whitespace. */
export function readNonBlankString(value         )                     {
  return typeof value === "string" && value.trim() ? value : undefined;
}

/** Rejects only empty or non-string values while preserving whitespace. */
export function readNonEmptyStringPreservingWhitespace(value         )                     {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Stringifies primitive ids/flags before applying optional string normalization. */
export function normalizeStringifiedOptionalString(value         )                     {
  if (typeof value === "string") {
    return normalizeOptionalString(value);
  }
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
    return normalizeOptionalString(String(value));
  }
  return undefined;
}

/** Normalizes an optional array of primitive-ish values into non-empty strings. */
export function normalizeStringifiedEntries(values                         )           {
  return (values ?? [])
    .map((entry) => normalizeStringifiedOptionalString(entry))
    .filter((entry)                  => Boolean(entry));
}

/** Lowercases a normalized optional string. */
export function normalizeOptionalLowercaseString(value         )                     {
  return normalizeOptionalString(value)?.toLowerCase();
}

/** Lowercases a normalized string or returns an empty string when absent. */
export function normalizeLowercaseStringOrEmpty(value         )         {
  return normalizeOptionalLowercaseString(value) ?? "";
}

                                                      

/** Parses loose boolean/fast-mode flags from strings or booleans. */
export function normalizeFastMode(raw          )                       {
  if (typeof raw === "boolean") {
    return raw;
  }
  const key = normalizeLowercaseStringOrEmpty(raw);
  if (["off", "false", "no", "0", "disable", "disabled", "normal"].includes(key)) {
    return false;
  }
  if (["on", "true", "yes", "1", "enable", "enabled", "fast"].includes(key)) {
    return true;
  }
  // "ultra" is input shorthand only; the canonical stored value stays "ultrafast".
  if (key === "ultrafast" || key === "ultra") {
    return "ultrafast";
  }
  if (["auto", "automatic"].includes(key)) {
    return "auto";
  }
  return undefined;
}

/** Lowercases text while intentionally preserving surrounding whitespace. */
export function lowercasePreservingWhitespace(value        )         {
  return value.toLowerCase();
}

/** Locale-aware lowercase helper that still preserves surrounding whitespace. */
export function localeLowercasePreservingWhitespace(value        )         {
  return value.toLocaleLowerCase();
}

/** Reads a string directly or from an object's `primary` field. */
export function resolvePrimaryStringValue(value         )                     {
  if (typeof value === "string") {
    return normalizeOptionalString(value);
  }
  if (!value || typeof value !== "object") {
    return undefined;
  }
  return normalizeOptionalString((value                         ).primary);
}

/** Normalizes thread ids that may be numeric or string-backed. */
export function normalizeOptionalThreadValue(value         )                              {
  if (typeof value === "number") {
    return Number.isFinite(value) ? Math.trunc(value) : undefined;
  }
  return normalizeOptionalString(value);
}

/** Normalizes a thread/id value and stringifies finite numeric ids. */
export function normalizeOptionalStringifiedId(value         )                     {
  const normalized = normalizeOptionalThreadValue(value);
  return normalized == null ? undefined : String(normalized);
}

/** Type guard for strings that remain non-empty after trimming. */
export function hasNonEmptyString(value         )                  {
  return normalizeOptionalString(value) !== undefined;
}
