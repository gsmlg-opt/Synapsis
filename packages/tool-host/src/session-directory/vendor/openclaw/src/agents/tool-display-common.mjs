import { asPositiveFiniteNumber } from "../../packages/normalization-core/src/number-coercion.mjs";
import { resolveOptionalIntegerOption } from "../../packages/normalization-core/src/number-coercion.mjs";
import { asOptionalObjectRecord as asRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../packages/normalization-core/src/string-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
import { sliceUtf16Safe } from "../../packages/normalization-core/src/utf16-slice.mjs";
import { isAgentPlanProgressToolName } from "../session-cards/progress-card-input.mjs";
import { dedupeByKey } from "../shared/dedupe-by-key.mjs";
import { resolveExecDetail } from "./tool-display-exec.mjs";
export function normalizeToolDisplayName(name         )         {
  return (name ?? "tool").trim();
}
export function defaultTitle(name        )         {
  const cleaned = name.replace(/_/g, " ").trim();
  if (!cleaned) {
    return "Tool";
  }
  return cleaned
    .split(/\s+/)
    .map((part) => `${part.at(0)?.toUpperCase() ?? ""}${part.slice(1)}`)
    .join(" ");
}
const TOOL_DISPLAY_ARRAY_DEPTH_LIMIT = 64;
function coerceDisplayValue(
  value         ,
  opts                            = {},
  depth = 0,
)                     {
  if (depth > TOOL_DISPLAY_ARRAY_DEPTH_LIMIT) {
    return undefined;
  }
  if (value === null || value === undefined) {
    return undefined;
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      return undefined;
    }
    const firstLine = normalizeOptionalString(trimmed.split(/\r?\n/, 1)[0]) ?? "";
    if (!firstLine) {
      return undefined;
    }
    if (firstLine.length > 160) {
      return `${sliceUtf16Safe(firstLine, 0, 79)}…${sliceUtf16Safe(firstLine, -80)}`;
    }
    return firstLine;
  }
  if (typeof value === "boolean") {
    if (!value && !opts.includeFalsy) {
      return undefined;
    }
    return value ? "true" : "false";
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      return undefined;
    }
    if (value === 0 && !opts.includeFalsy) {
      return undefined;
    }
    return String(value);
  }
  if (Array.isArray(value)) {
    const values           = [];
    for (const item of value) {
      const display = coerceDisplayValue(item, opts, depth + 1);
      if (!display) {
        continue;
      }
      // The fourth visible value determines the ellipsis; later items cannot affect the preview.
      if (values.length === 3) {
        return `${values.join(", ")}…`;
      }
      values.push(display);
    }
    return values.length > 0 ? values.join(", ") : undefined;
  }
  return undefined;
}
function lookupValueByPath(args         , path        )          {
  if (!args || typeof args !== "object") {
    return undefined;
  }
  let current          = args;
  for (const segment of path.split(".")) {
    if (!segment) {
      return undefined;
    }
    if (!current || typeof current !== "object") {
      return undefined;
    }
    const record = current                           ;
    current = record[segment];
  }
  return current;
}
export function formatDetailKey(raw        , overrides                        )         {
  const last = raw.split(".").findLast(Boolean) || raw;
  const override = overrides[last];
  if (override) {
    return override;
  }
  const cleaned = last.replace(/[_-]/g, " ");
  const spaced = cleaned.replace(/([a-z0-9])([A-Z])/g, "$1 $2");
  return normalizeLowercaseStringOrEmpty(spaced) || normalizeLowercaseStringOrEmpty(last);
}
function resolvePathArg(record                         )                     {
  for (const candidate of [record.path, record.file_path, record.filePath]) {
    const trimmed = normalizeOptionalString(candidate);
    if (trimmed) {
      return trimmed;
    }
  }
  return undefined;
}
function resolveReadDetail(record                         )                     {
  const path = resolvePathArg(record);
  if (!path) {
    return undefined;
  }

  const offset = resolveOptionalIntegerOption(record.offset, { min: 1 });
  const limit = resolveOptionalIntegerOption(record.limit, { min: 1 });

  if (offset !== undefined && limit !== undefined) {
    const unit = limit === 1 ? "line" : "lines";
    return `${unit} ${offset}-${offset + limit - 1} from ${path}`;
  }
  if (offset !== undefined) {
    return `from line ${offset} in ${path}`;
  }
  if (limit !== undefined) {
    const unit = limit === 1 ? "line" : "lines";
    return `first ${limit} ${unit} of ${path}`;
  }
  return `from ${path}`;
}
function resolveWriteDetail(toolKey        , record                         )                     {
  const path = resolvePathArg(record) ?? normalizeOptionalString(record.url);
  if (!path) {
    return undefined;
  }

  if (toolKey === "attach") {
    return `from ${path}`;
  }

  const destinationPrefix = toolKey === "edit" ? "in" : "to";
  const content =
    typeof record.content === "string"
      ? record.content
      : typeof record.newText === "string"
        ? record.newText
        : typeof record.new_string === "string"
          ? record.new_string
          : undefined;

  if (content) {
    return `${destinationPrefix} ${path} (${content.length} chars)`;
  }

  return `${destinationPrefix} ${path}`;
}
function resolveWebSearchDetail(record                         )                     {
  const queries = collectWebSearchQueries(record);
  const count =
    asPositiveFiniteNumber(record.count) ??
    asPositiveFiniteNumber(record.max_results) ??
    asPositiveFiniteNumber(record.num_results) ??
    asPositiveFiniteNumber(record.limit) ??
    asPositiveFiniteNumber(record.top_k);

  if (queries.length === 0) {
    return undefined;
  }

  const displayedQueries = queries.slice(0, 3).map((query) => `"${query}"`);
  const queryText =
    queries.length > displayedQueries.length
      ? `${displayedQueries.join(", ")}…`
      : displayedQueries.join(", ");

  return count !== undefined ? `for ${queryText} (top ${Math.floor(count)})` : `for ${queryText}`;
}
function collectWebSearchQueries(record                         )           {
  const queries = new Set        ();
  const add = (value         ) => {
    const normalized = normalizeOptionalString(value);
    if (normalized) {
      queries.add(normalized);
    }
  };

  add(record.query);
  add(record.q);
  add(record.search);
  add(record.input);
  // Parallel's `web_search` provider uses the native Parallel Search shape
  // (`objective` + `search_queries`). Surface those so CLI progress and
  // Codex activity metadata render the query context instead of a bare
  // `search`.
  add(record.objective);

  for (const key of ["search_query", "image_query", "queries", "search_queries"]) {
    const value = record[key];
    if (!Array.isArray(value)) {
      continue;
    }
    for (const entry of value) {
      if (typeof entry === "string") {
        add(entry);
        continue;
      }
      const entryRecord = asRecord(entry);
      if (!entryRecord) {
        continue;
      }
      add(entryRecord.query);
      add(entryRecord.q);
      add(entryRecord.search);
    }
  }

  return [...queries];
}
function resolveWebFetchDetail(record                         )                     {
  const url = normalizeOptionalString(record.url);
  if (!url) {
    return undefined;
  }

  const mode = normalizeOptionalString(record.extractMode);
  const maxChars = asPositiveFiniteNumber(record.maxChars);

  const suffix = [
    mode ? `mode ${mode}` : "",
    maxChars === undefined ? "" : `max ${Math.floor(maxChars)} chars`,
  ]
    .filter(Boolean)
    .join(", ");

  return suffix ? `from ${url} (${suffix})` : `from ${url}`;
}
export function resolveToolDetailForArgs(params   
                  
                 
                
                         
                                
                                  
                                  
                                           
                                            
 )                     {
  // Card arguments belong to the card renderer; generic summaries must not expose them.
  if (isAgentPlanProgressToolName(params.toolKey)) {
    return undefined;
  }
  const { toolKey, args, meta } = params;
  const record = asRecord(args);
  const action = normalizeOptionalString(record?.action);
  const { spec, fallbackDetailKeys, detailMode, toolDetailMode, detailCoerce, detailFormatKey } =
    params;
  const actionSpec = spec && action ? spec.actions?.[action] : undefined;
  let detail                    ;
  if (toolKey === "exec" || toolKey === "bash" || toolKey === "shell") {
    detail = resolveExecDetail(args, { detailMode: toolDetailMode });
  }
  if (record && !detail) {
    if (toolKey === "read") {
      detail = resolveReadDetail(record);
    } else if (toolKey === "write" || toolKey === "edit" || toolKey === "attach") {
      detail = resolveWriteDetail(toolKey, record);
    } else if (toolKey === "web_search") {
      detail = resolveWebSearchDetail(record);
    } else if (toolKey === "web_fetch") {
      detail = resolveWebFetchDetail(record);
    }
  }

  const detailKeys = actionSpec?.detailKeys ?? spec?.detailKeys ?? fallbackDetailKeys ?? [];
  if (!detail && detailKeys.length > 0) {
    const entries                                          = [];
    for (const key of detailKeys) {
      const value = lookupValueByPath(args, key);
      const display = coerceDisplayValue(value, detailCoerce);
      if (!display) {
        continue;
      }
      if (detailMode === "first") {
        detail = display;
        break;
      }
      entries.push({ label: detailFormatKey ? detailFormatKey(key) : key, value: display });
    }
    if (entries.length === 1) {
      detail = entries.at(0)?.value;
    } else if (entries.length > 1) {
      const unique = dedupeByKey(entries, (entry) => `${entry.label}:${entry.value}`);
      const parts           = [];
      for (let index = 0; index < unique.length && index < 8; index += 1) {
        const entry = unique[index];
        if (entry) {
          parts.push(`${entry.label} ${entry.value}`);
        }
      }
      detail = parts.join(", ");
    }
  }
  if (!detail && meta) {
    detail = meta;
  }
  return detail;
}
export { TOOL_DISPLAY_ARRAY_DEPTH_LIMIT, coerceDisplayValue, lookupValueByPath, resolvePathArg, resolveReadDetail, resolveWriteDetail, resolveWebSearchDetail, collectWebSearchQueries, resolveWebFetchDetail };