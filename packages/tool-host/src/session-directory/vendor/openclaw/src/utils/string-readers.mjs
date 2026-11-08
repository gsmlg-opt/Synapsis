import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";

                                                                     

export function isStringOption                  (
  value         ,
  options                  ,
)             {
  return (
    typeof value === "string" &&
    (Array.isArray(options)
      ? (options                     ).includes(value)
      : (options                       ).has(value))
  );
}

export function readTrimmedStringAlias(
  record                                   ,
  keys                   ,
)                     {
  return readParsedField(record, keys, normalizeOptionalString);
}

/** Reads the first parsed field, preserving order and defined falsy values. */
export function readParsedField   (
  record                                   ,
  keys                            ,
  parse                                   ,
)                {
  for (const key of typeof keys === "string" ? [keys] : keys) {
    const value = parse(record[key]);
    if (value !== undefined) {
      return value;
    }
  }
  return undefined;
}

export function stripChannelPrefix(
  value                    ,
  channelId        ,
)                     {
  if (!value) {
    return undefined;
  }
  const genericPrefixes = ["channel:", "chat:", "user:"];
  for (const prefix of genericPrefixes) {
    if (value.startsWith(prefix)) {
      return value.slice(prefix.length);
    }
  }
  const prefix = `${channelId}:`;
  return value.startsWith(prefix) ? value.slice(prefix.length) : value;
}
