import { normalizeOptionalLowercaseString, normalizeOptionalString } from "./string-coerce.mjs";

/** Detects C0 and DEL without rejecting C1 or other Unicode text. */
export function containsAsciiControlCharacter(value        )          {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x1f || code === 0x7f) {
      return true;
    }
  }
  return false;
}

/** Retains runtime string entries from arrays without normalizing their contents. */
export function filterStringEntries(value         )           {
  return Array.isArray(value)
    ? value.filter((entry)                  => typeof entry === "string")
    : [];
}

/** Coerces entries to strings, trims them, and drops empty results. */
export function normalizeStringEntries(list                         ) {
  return (list ?? []).map((entry) => String(entry).trim()).filter(Boolean);
}

/** Normalizes string entries and lowercases each retained value. */
export function normalizeStringEntriesLower(list                         ) {
  return normalizeStringEntries(list).map((entry) => entry.toLowerCase());
}

/** Returns first-seen unique values while preserving insertion order. */
export function uniqueValues   (values             )      {
  return [...new Set(values)];
}

/** Returns first-seen unique strings while preserving insertion order. */
export function uniqueStrings(values                  )           {
  return uniqueValues(values);
}

/** Returns a fresh array of unique strings in UTF-16 code-unit order. */
export function sortUniqueStrings(values                  )           {
  // oxlint-disable-next-line unicorn/no-array-sort -- uniqueStrings creates a private array.
  return uniqueStrings(values).sort();
}

/** Normalizes entries, removes duplicates, and preserves first-seen order. */
export function normalizeUniqueStringEntries(values                    )           {
  return uniqueStrings(normalizeStringEntries(values ? [...values] : undefined));
}

/** Lowercases normalized entries, removes empties/duplicates, and preserves first-seen order. */
export function normalizeUniqueStringEntriesLower(values                    )           {
  return uniqueStrings(normalizeStringEntriesLower(values ? [...values] : undefined));
}

/** Normalizes entries, removes duplicates, and returns sorted output. */
export function normalizeSortedUniqueStringEntries(values                    )           {
  return sortUniqueStrings(normalizeStringEntries(values ? [...values] : undefined));
}

/** Normalizes array-backed string lists and rejects non-array input as empty. */
export function normalizeTrimmedStringList(value         )           {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((entry) => {
    const normalized = normalizeOptionalString(entry);
    return normalized ? [normalized] : [];
  });
}

/** Normalizes an array-backed string list and removes duplicates. */
export function normalizeUniqueTrimmedStringList(value         )           {
  return uniqueStrings(normalizeTrimmedStringList(value));
}

/** Normalizes an array-backed string list, removes duplicates, and sorts it. */
export function normalizeSortedUniqueTrimmedStringList(value         )           {
  return sortUniqueStrings(normalizeTrimmedStringList(value));
}

/** Returns undefined instead of an empty normalized array-backed string list. */
export function normalizeOptionalTrimmedStringList(value         )                       {
  const normalized = normalizeTrimmedStringList(value);
  return normalized.length > 0 ? normalized : undefined;
}

/** Returns undefined for non-arrays but preserves an empty array for explicit arrays. */
export function normalizeArrayBackedTrimmedStringList(value         )                       {
  if (!Array.isArray(value)) {
    return undefined;
  }
  return normalizeTrimmedStringList(value);
}

/** Normalizes either a single string-like value or an array-backed string list. */
export function normalizeSingleOrTrimmedStringList(value         )           {
  if (Array.isArray(value)) {
    return normalizeTrimmedStringList(value);
  }
  const normalized = normalizeOptionalString(value);
  return normalized ? [normalized] : [];
}

/** Normalizes single-or-array string input and removes duplicates. */
export function normalizeUniqueSingleOrTrimmedStringList(value         )           {
  return uniqueStrings(normalizeSingleOrTrimmedStringList(value));
}

/** Parses either array entries or comma-separated string entries into trimmed values. */
export function normalizeCsvOrLooseStringList(value         )           {
  if (Array.isArray(value)) {
    return normalizeStringEntries(value);
  }
  if (typeof value === "string") {
    return normalizeStringEntries(value.split(","));
  }
  return [];
}

function normalizeSlugInput(raw                ) {
  // NFC keeps visually identical composed/decomposed Unicode labels matching the
  // same slug while preserving non-Latin channel and room names.
  return (normalizeOptionalLowercaseString(raw) ?? "").normalize("NFC");
}

/** Normalizes user-facing names into permissive lowercase slugs that may keep #/@/._+. */
export function normalizeHyphenSlug(raw                ) {
  const trimmed = normalizeSlugInput(raw);
  const dashed = trimmed.replace(/\s+/g, "-");
  const cleaned = dashed.replace(/[^\p{L}\p{M}\p{N}#@._+-]+/gu, "-");
  return cleaned.replace(/-{2,}/g, "-").replace(/^[-.]+|[-.]+$/g, "");
}

/** Normalizes @/#-prefixed channel names into strict lowercase hyphen slugs without the prefix. */
export function normalizeAtHashSlug(raw                ) {
  const trimmed = normalizeSlugInput(raw);
  const withoutPrefix = trimmed.replace(/^[@#]+/, "");
  const dashed = withoutPrefix.replace(/[\s_]+/g, "-");
  const cleaned = dashed.replace(/[^\p{L}\p{M}\p{N}-]+/gu, "-");
  return cleaned.replace(/-{2,}/g, "-").replace(/^-+|-+$/g, "");
}
