import { consumeResponseBytes, decodeTextPrefix } from "../../../../../normalization.mjs";
import {
  asFiniteNumber,
  asPositiveFiniteNumber,
  MAX_TIMER_TIMEOUT_SECONDS,
  resolveIntegerOption,
} from "../../../packages/normalization-core/src/number-coercion.mjs";
import { pruneMapToMaxSize } from "../../infra/map-size.mjs";
                             
           
                    
                     
  

export const DEFAULT_TIMEOUT_SECONDS = 30;
export const DEFAULT_CACHE_TTL_MINUTES = 15;
const DEFAULT_CACHE_MAX_ENTRIES = 100;

export function resolveTimeoutSeconds(value         , fallback        )         {
  return resolveIntegerOption(value, fallback, { min: 1, max: MAX_TIMER_TIMEOUT_SECONDS });
}

export function resolvePositiveTimeoutSeconds(value         , fallback        )         {
  return resolveTimeoutSeconds(asPositiveFiniteNumber(value), fallback);
}

export function resolveCacheTtlMs(value         , fallbackMinutes        )         {
  const minutes = asFiniteNumber(value);
  return Math.round((minutes === undefined ? fallbackMinutes : Math.max(0, minutes)) * 60_000);
}

export function normalizeCacheKey(value        )         {
  // Request paths and query values can be case-sensitive; only surrounding
  // whitespace is non-semantic when callers compose cache keys.
  return value.trim();
}

export function readCache   (
  cache                            ,
  key        ,
  ttlMs = Infinity,
)                                       {
  const entry = cache.get(key);
  if (!entry || ttlMs <= 0) {
    return null;
  }
  const now = Date.now();
  if (now >= entry.expiresAt) {
    cache.delete(key);
    return null;
  }
  // A caller can shorten reuse without evicting an entry still valid for others.
  return now - entry.insertedAt < ttlMs ? { value: entry.value, cached: true } : null;
}

export function writeCache   (
  cache                            ,
  key        ,
  value   ,
  ttlMs        ,
) {
  if (!Number.isSafeInteger(ttlMs) || ttlMs <= 0) {
    return;
  }
  const now = Date.now();
  pruneMapToMaxSize(cache, DEFAULT_CACHE_MAX_ENTRIES - 1);
  cache.set(key, {
    value,
    expiresAt: now + ttlMs,
    insertedAt: now,
  });
}

                               
               
                     
                    
  

const RESPONSE_CHARSET_SCAN_BYTES = 4096;
const latin1Decoder = new TextDecoder("latin1");

function normalizeCharset(value                    )                     {
  const normalized = value?.trim().replace(/^["']|["']$/g, "") ?? "";
  return normalized && normalized.length <= 64 && /^[A-Za-z0-9._:-]+$/.test(normalized)
    ? normalized
    : undefined;
}

function readCharsetParam(value                           )                     {
  const match = /(?:^|;)\s*charset\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))/i.exec(value ?? "");
  return normalizeCharset(match?.[1] ?? match?.[2] ?? match?.[3]);
}

function readAttribute(tag        , name        )                     {
  const target = name.toLowerCase();
  for (const match of tag.matchAll(
    /([A-Za-z0-9:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g,
  )) {
    if (match[1]?.toLowerCase() === target) {
      return match[2] ?? match[3] ?? match[4] ?? "";
    }
  }
  return undefined;
}

function shouldSniffDocumentCharset(contentType               )          {
  const mediaType = contentType?.split(";", 1)[0]?.trim().toLowerCase();
  if (!mediaType) {
    return true;
  }
  return (
    mediaType === "text/html" ||
    mediaType === "application/xhtml+xml" ||
    mediaType === "text/xml" ||
    mediaType === "application/xml" ||
    mediaType.endsWith("+xml")
  );
}

function sniffCharset(contentType               , bytes            )                     {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return "utf-8";
  }
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return "utf-16le";
  }
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return "utf-16be";
  }
  const declaredCharset = readCharsetParam(contentType);
  if (declaredCharset || !shouldSniffDocumentCharset(contentType)) {
    return declaredCharset;
  }
  const documentCharset = sniffDocumentCharset(bytes);
  try {
    return documentCharset && new TextDecoder(documentCharset).encoding.startsWith("utf-16")
      ? "utf-8"
      : documentCharset;
  } catch {
    return documentCharset;
  }
}

function sniffDocumentCharset(bytes            )                     {
  const head = latin1Decoder.decode(
    bytes.subarray(0, Math.min(bytes.byteLength, RESPONSE_CHARSET_SCAN_BYTES)),
  );
  const xmlEncoding = /<\?xml\s+[^>]*\bencoding\s*=\s*(?:"([^"]+)"|'([^']+)')/i.exec(head);
  if (xmlEncoding) {
    return normalizeCharset(xmlEncoding[1] ?? xmlEncoding[2]);
  }

  for (const match of head.matchAll(/<meta\b[^>]*>/gi)) {
    const tag = match[0];
    const charset = normalizeCharset(readAttribute(tag, "charset"));
    if (charset) {
      return charset;
    }
    if (/^content-type$/i.test(readAttribute(tag, "http-equiv") ?? "")) {
      const contentCharset = readCharsetParam(readAttribute(tag, "content"));
      if (contentCharset) {
        return contentCharset;
      }
    }
  }
  return undefined;
}

function decodeResponseBytes(res          , bytes            , truncated = false)         {
  const charset = sniffCharset(res.headers.get("content-type"), bytes);
  try {
    return decodeTextPrefix(bytes, { encoding: charset ?? "utf-8", truncated });
  } catch {
    return decodeTextPrefix(bytes, { encoding: "utf-8", truncated });
  }
}

export async function readResponseText(
  res          ,
  options                        ,
)                                  {
  const maxBytesRaw = asPositiveFiniteNumber(options?.maxBytes);
  const maxBytes = maxBytesRaw === undefined ? undefined : Math.floor(maxBytesRaw);

  const body = res.body;
  if (maxBytes && body) {
    const reader = body.getReader();
    let bytesRead = 0;
    let truncated = false;
    const parts               = [];

    try {
      const result = await consumeResponseBytes({
        maxBytes,
        read: () => reader.read(),
        onChunk: (chunk) => {
          // The shared size includes overflow; report only the retained bytes.
          bytesRead += chunk.byteLength;
          parts.push(chunk);
        },
        onLimit: () => undefined,
      });
      truncated = result.truncated;
    } catch {
      // Stream errors mean the accumulated bytes are only a partial body.
      truncated = true;
    } finally {
      if (truncated) {
        // Some mocked or non-compliant streams never settle cancel(); do not
        // let cleanup turn a bounded read into a hung fetch.
        void reader.cancel().catch(() => undefined);
      }
      try {
        reader.releaseLock();
      } catch {
        // The read/cancel path already produced the best-effort body result;
        // lock-release failures must not replace that outcome.
      }
    }

    const bytes =
      parts.length === 1 && parts[0]?.byteLength === bytesRead
        ? parts[0]
        : Buffer.concat(parts, bytesRead);
    return { text: decodeResponseBytes(res, bytes, truncated), truncated, bytesRead };
  }

  if (maxBytes) {
    return { text: "", truncated: false, bytesRead: 0 };
  }

  const bytes = new Uint8Array(await res.arrayBuffer());
  return {
    text: decodeResponseBytes(res, bytes),
    truncated: false,
    bytesRead: bytes.byteLength,
  };
}
