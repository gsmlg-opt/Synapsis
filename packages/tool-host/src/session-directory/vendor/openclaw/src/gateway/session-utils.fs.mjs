import { expectDefined } from "../../packages/normalization-core/src/expect.mjs";
import { jsonUtf8Bytes } from "../infra/json-utf8-bytes.mjs";
export function capArrayByJsonBytes   (
  items     ,
  maxBytes        ,
  byteLength                      = jsonUtf8Bytes,
)                                {
  if (items.length === 0) {
    return { items, bytes: 2 };
  }
  const parts = items.map(byteLength);
  let bytes = 2 + parts.reduce((a, b) => a + b, 0) + (items.length - 1);
  let start = 0;
  while (bytes > maxBytes && start < items.length - 1) {
    bytes -= expectDefined(parts[start], "parts entry at start") + 1;
    start += 1;
  }
  const next = start > 0 ? items.slice(start) : items;
  return { items: next, bytes };
}