                                                                
import {
  getFileExtension,
  kindFromMime,
  mimeTypeFromFilePath,
  normalizeMimeType,
} from "../../packages/media-core/src/mime.mjs";
import {
  asFiniteNumberInRange,
  asPositiveSafeInteger as normalizePositiveInteger,
} from "../../packages/normalization-core/src/number-coercion.mjs";
import { asNonArrayRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeOptionalString } from "../../packages/normalization-core/src/string-coerce.mjs";
                                                                     

/** One ordered runtime attachment; array position is its alignment identity. */
                         
                
               
                       
                   
                    
                                                                               
                            
                     
                      
                 
                  
                        
                     
                        
                                                                                       
                   
                                                                              
                                                                                 
                                                                                   
                                
  

                              
                                                   
  

const RUNTIME_PROMPT_MEDIA_FACTS = Symbol.for("openclaw.runtimePromptMediaFacts");

/** Attaches facts to a runtime prompt message without changing serialized/model-visible bytes. */
export function attachRuntimePromptMediaFacts                  (
  message   ,
  media                      ,
  imageOrder                                   ,
)    {
  const normalized = normalizeMediaFacts(media);
  if (imageOrder?.length) {
    Object.defineProperty(normalized, "imageOrder", { value: [...imageOrder] });
  }
  Object.defineProperty(message, RUNTIME_PROMPT_MEDIA_FACTS, {
    configurable: true,
    // Symbols survive in-memory projections without entering transcript JSON.
    enumerable: true,
    writable: true,
    value: normalized,
  });
  return message;
}

export function readRuntimePromptMediaFacts(message        )                          {
  const media = (message                                )[RUNTIME_PROMPT_MEDIA_FACTS];
  return Array.isArray(media) ? (media               ) : undefined;
}

/** Reads the canonical persisted media envelope without consulting legacy top-level fields. */
export function readPersistedMediaFacts(message        )                          {
  const media = readPersistedMediaFactInputs(message);
  return media?.map((entry, index) => normalizeMediaFact                (entry, index));
}

function readPersistedMediaFactInputs(message        )                                           {
  const metadata = asNonArrayRecord(asNonArrayRecord(message)["__openclaw"]);
  return Array.isArray(metadata.media)
    ? (metadata.media                                )
    : undefined;
}

const LEGACY_MEDIA_CONTEXT_KEYS = [
  "MediaPath",
  "MediaPaths",
  "MediaUrl",
  "MediaUrls",
  "MediaType",
  "MediaTypes",
  "MediaDir",
  "MediaTranscribedIndexes",
  "MediaStaged",
  "MediaWorkspaceDir",
]         ;
                                                                               

export const PERSISTED_LEGACY_MEDIA_KEYS = [
  "MediaPath",
  "MediaPaths",
  "MediaUrl",
  "MediaUrls",
  "MediaType",
  "MediaTypes",
  "MediaTranscribedIndexes",
  "MediaStaged",
  "MediaWorkspaceDir",
]         ;

/** Returns whether a top-level retired carrier contains an attachment fact worth migrating. */
export function hasMeaningfulRetiredMediaCarrier(message        )          {
  const record = message                           ;
  const retired                          = {};
  if (Array.isArray(record.media)) {
    retired.media = record.media;
  }
  for (const key of PERSISTED_LEGACY_MEDIA_KEYS) {
    if (Object.hasOwn(record, key)) {
      retired[key] = record[key];
    }
  }
  if (resolveMediaFacts(retired                   ).some(isMeaningfulMediaFact)) {
    return true;
  }
  const canonical = readPersistedMediaFacts(message) ?? [];
  if (canonical.length === 0) {
    return false;
  }
  const transcribedIndexes = Array.isArray(record.MediaTranscribedIndexes)
    ? record.MediaTranscribedIndexes
    : [];
  return (
    transcribedIndexes.some(
      (index) => Number.isInteger(index) && index >= 0 && index < canonical.length,
    ) ||
    Boolean(normalizeOptionalString(record.MediaWorkspaceDir)) ||
    record.MediaStaged === true
  );
}

const LEGACY_MEDIA_KINDS = new Set           ([
  "image",
  "audio",
  "video",
  "document",
  "sticker",
  "unknown",
]);

                                                             
                   
             
  

/** Canonicalizes persisted user-message media; ambiguous sparse legacy arrays are rejected. */
export function canonicalizePersistedUserMessageMedia                  (
  message   ,
)                                        {
  const record = message                           ;
  const hadLegacy = PERSISTED_LEGACY_MEDIA_KEYS.some((key) => Object.hasOwn(record, key));
  const hadTopLevelMedia = Object.hasOwn(record, "media");
  const canonical = readPersistedMediaFactInputs(message);
  if (!hadLegacy && !hadTopLevelMedia && canonical === undefined) {
    return { changed: false, message };
  }

  const topLevelMedia = Array.isArray(record.media)
    ? (record.media                             )
    : undefined;
  let source                  = {
    ...record,
    media: (canonical ?? topLevelMedia)                                         ,
  };
  const paths = Array.isArray(source.MediaPaths) ? source.MediaPaths : [];
  const urls = Array.isArray(source.MediaUrls) ? source.MediaUrls : [];
  const types = Array.isArray(source.MediaTypes) ? source.MediaTypes : [];
  const slotCount = Math.max(paths.length, urls.length);
  if (types.length > 0 && types.length < slotCount) {
    const facts = normalizeMediaFacts(source.media);
    let ambiguous = false;
    for (let index = 0; index < slotCount; index += 1) {
      const meaningful =
        normalizeOptionalString(paths[index]) ?? normalizeOptionalString(urls[index]);
      const fact = facts[index];
      if (meaningful && (!(fact?.path ?? fact?.url) || !(fact?.contentType ?? fact?.kind))) {
        ambiguous = true;
        break;
      }
    }
    if (hadLegacy && ambiguous) {
      throw new Error("legacy media arrays have ambiguous sparse positional alignment");
    }
    if (!ambiguous) {
      source = { ...source, MediaType: undefined, MediaTypes: [] };
    }
  }
  const resolvedMedia = resolveMediaFacts(source);
  const stagedMedia = source.MediaStaged === true ? resolveStagedMediaFacts(source) : undefined;
  const legacyTypes = Array.isArray(source.MediaTypes) ? source.MediaTypes : [];
  const canonicalInputs = Array.isArray(source.media) ? source.media : [];
  const media              = [];
  for (const [index, fact] of resolvedMedia.entries()) {
    const legacyType = normalizeOptionalString(
      legacyTypes[index] ?? (index === 0 ? source.MediaType : undefined),
    );
    const existing = canonicalInputs[index];
    const bareLegacyKind =
      legacyType &&
      LEGACY_MEDIA_KINDS.has(legacyType             ) &&
      !normalizeOptionalString(existing?.contentType) &&
      existing?.kind === undefined;
    const explicitKind = existing?.kind ?? (bareLegacyKind ? (legacyType             ) : undefined);
    media.push({
      ...(fact.path ? { path: fact.path } : {}),
      ...(fact.url ? { url: fact.url } : {}),
      ...(fact.contentType && !bareLegacyKind ? { contentType: fact.contentType } : {}),
      ...(explicitKind ? { kind: explicitKind } : {}),
      ...(fact.fileName ? { fileName: fact.fileName } : {}),
      ...(fact.origin ? { origin: fact.origin } : {}),
      ...(fact.sizeBytes !== undefined ? { sizeBytes: fact.sizeBytes } : {}),
      ...(fact.durationMs ? { durationMs: fact.durationMs } : {}),
      ...(fact.width ? { width: fact.width } : {}),
      ...(fact.height ? { height: fact.height } : {}),
      ...(fact.transcribed ? { transcribed: true } : {}),
      ...(fact.messageId ? { messageId: fact.messageId } : {}),
      ...(fact.workspaceDir ? { workspaceDir: fact.workspaceDir } : {}),
      ...(fact.staged || stagedMedia?.[index]?.staged ? { staged: true } : {}),
      ...(fact.hydrationSuppressed ? { hydrationSuppressed: true } : {}),
    });
  }

  const next                          = { ...record };
  delete next.media;
  for (const key of PERSISTED_LEGACY_MEDIA_KEYS) {
    delete next[key];
  }
  const openclaw = { ...asNonArrayRecord(record["__openclaw"]) };
  if (media.length > 0 || canonical !== undefined || topLevelMedia !== undefined) {
    openclaw.media = media;
  }
  if (Object.keys(openclaw).length > 0) {
    next["__openclaw"] = openclaw;
  } else {
    delete next["__openclaw"];
  }
  return {
    changed: JSON.stringify(next) !== JSON.stringify(record),
    message: next     ,
  };
}

export function stripLegacyMediaContextFields(ctx                         )       {
  for (const key of LEGACY_MEDIA_CONTEXT_KEYS) {
    delete ctx[key];
  }
}

/** Returns whether a declared MIME only describes otherwise unclassified binary bytes. */
function isGenericBinaryMediaContentType(contentType                )          {
  const normalizedContentType = normalizeMimeType(contentType);
  return (
    normalizedContentType === "application/octet-stream" ||
    normalizedContentType === "binary/octet-stream"
  );
}

/** Resolves attachment kind from authoritative facts before source or filename hints. */
export function resolveMediaFactKind(fact                )                        {
  if (fact.kind && fact.kind !== "unknown") {
    return fact.kind;
  }
  const normalizedContentType = normalizeMimeType(fact.contentType);
  if (normalizedContentType && !isGenericBinaryMediaContentType(normalizedContentType)) {
    const mimeKind = kindFromMime(normalizedContentType);
    if (mimeKind) {
      return mimeKind;
    }
    // Legacy channel-mode projections persist bare image or sticker kind as MediaType.
    return LEGACY_MEDIA_KINDS.has(normalizedContentType             )
      ? (normalizedContentType             )
      : undefined;
  }
  const source = normalizeOptionalString(fact.path) ?? normalizeOptionalString(fact.url);
  if (!source) {
    return undefined;
  }
  for (const candidate of [fact.path, fact.url, fact.fileName, source]) {
    const inferredMime = mimeTypeFromFilePath(candidate);
    if (inferredMime !== undefined) {
      // A recognized source, including SVG, takes precedence over later filename hints.
      return inferredMime === "image/svg+xml" ? undefined : kindFromMime(inferredMime);
    }
    const extension = getFileExtension(candidate);
    if (extension === ".tif" || extension === ".tiff") {
      return "image";
    }
  }
  return undefined;
}

/** Returns whether a fact can produce native image input. */
export function isImageMediaFact(fact                )          {
  const kind = resolveMediaFactKind(fact);
  return kind === "image" || kind === "sticker";
}

/** Returns whether a fact can produce native video input. */
export function isVideoMediaFact(fact                )          {
  return resolveMediaFactKind(fact) === "video";
}

                                                                          
                   
                     
                        
                                                          
  

                                         
                                          
                     
                                         
                    
                                                            
                     
                                                            
                        
                                                           
                       
                                                                                 
                        
                                                               
                                     
  

                                                    
                                    
                               
                                    
  

function normalizeMediaFact                               (
  media               ,
  index        ,
  defaults                            = {},
)            {
  // Sparse arrays serialize missing attachment positions as null; persisted
  // slots must remain empty facts instead of crashing transcript hydration.
  const input = asNonArrayRecord(media)          ;
  const workspaceDir = normalizeOptionalString(input.workspaceDir) ?? defaults.workspaceDir;
  const contentType = normalizeOptionalString(input.contentType);
  const durationMs = normalizePositiveInteger(input.durationMs);
  const width = normalizePositiveInteger(input.width);
  const height = normalizePositiveInteger(input.height);
  return {
    path: normalizeOptionalString(input.path),
    url: normalizeOptionalString(input.url),
    contentType,
    kind:
      (typeof input.kind === "string" ? input.kind : undefined) ??
      defaults.kind ??
      (isGenericBinaryMediaContentType(contentType) ? undefined : kindFromMime(contentType)),
    fileName: normalizeOptionalString(input.fileName),
    ...(input.origin === "paste" || input.origin === "file" ? { origin: input.origin } : {}),
    sizeBytes: asFiniteNumberInRange(input.sizeBytes, { min: 0 }),
    ...(durationMs ? { durationMs } : {}),
    ...(width ? { width } : {}),
    ...(height ? { height } : {}),
    transcribed: input.transcribed === true || defaults.transcribed?.(input, index) === true,
    messageId: normalizeOptionalString(input.messageId) ?? defaults.messageId,
    ...(workspaceDir ? { workspaceDir } : {}),
    ...(input.staged === true ? { staged: true } : {}),
    ...(input.hydrationSuppressed === true ? { hydrationSuppressed: true } : {}),
  };
}

/** True when every path-bearing canonical fact has explicit staging proof. */
export function hasStagedMediaFacts(media                                              )          {
  const stageable = normalizeMediaFacts(media).filter((fact) => Boolean(fact.path));
  return (
    stageable.length > 0 &&
    stageable.every((fact) => Boolean(fact.workspaceDir) || fact.staged === true)
  );
}

export function normalizeMediaFacts                               (
  media                                      ,
  defaults                            = {},
)              {
  return Array.isArray(media)
    ? media.map((entry, index) => normalizeMediaFact(entry, index, defaults))
    : [];
}

// Empty slots exist only to keep legacy parallel-array positions aligned;
// presence/counting sites must ignore them or blank projections ({MediaPaths: [""]})
// route media-less messages into inbound-media handling.
export function isMeaningfulMediaFact(fact           )          {
  return Boolean(
    fact.path?.trim() ||
    fact.url?.trim() ||
    fact.contentType ||
    (fact.kind && fact.kind !== "unknown"),
  );
}

function resolveMediaFactsWithPrecedence(
  source                 ,
  legacyProjectionWins         ,
)              {
  const canonical = normalizeMediaFacts(source.media);
  const paths = Array.isArray(source.MediaPaths) ? source.MediaPaths : [];
  const urls = Array.isArray(source.MediaUrls) ? source.MediaUrls : [];
  const types = Array.isArray(source.MediaTypes) ? source.MediaTypes : [];
  const count = Math.max(
    canonical.length,
    paths.length,
    urls.length,
    types.length,
    source.MediaPath || source.MediaUrl || source.MediaType ? 1 : 0,
  );
  const transcribed = new Set(source.MediaTranscribedIndexes ?? []);
  const legacyHasPath =
    Boolean(normalizeOptionalString(source.MediaPath)) ||
    paths.some((value) => Boolean(normalizeOptionalString(value)));
  return Array.from({ length: count }, (_, index) => {
    const fact = canonical[index];
    const legacyPath = paths[index] ?? (index === 0 ? source.MediaPath : undefined);
    const legacyUrl = urls[index] ?? (index === 0 ? source.MediaUrl : undefined);
    const legacyContentType =
      normalizeOptionalString(types[index]) ?? (index === 0 ? source.MediaType : undefined);
    return normalizeMediaFact(
      {
        ...fact,
        path: legacyProjectionWins
          ? (normalizeOptionalString(legacyPath) ?? fact?.path)
          : (fact?.path ?? legacyPath),
        url: legacyProjectionWins
          ? (normalizeOptionalString(legacyUrl) ?? fact?.url)
          : (fact?.url ?? legacyUrl),
        contentType: legacyProjectionWins
          ? (legacyContentType ?? fact?.contentType)
          : (fact?.contentType ?? legacyContentType),
        transcribed: legacyProjectionWins
          ? fact
            ? fact.transcribed === true
            : transcribed.has(index)
          : fact?.transcribed === true || transcribed.has(index),
        workspaceDir: fact?.workspaceDir ?? normalizeOptionalString(source.MediaWorkspaceDir),
        staged:
          fact?.staged === true ||
          (legacyProjectionWins &&
            source.MediaStaged === true &&
            (!legacyHasPath || Boolean(normalizeOptionalString(legacyPath)))),
      },
      index,
    );
  });
}

/** Normalizes canonical facts or, for compatibility callers, legacy parallel fields. */
export function resolveMediaFacts(source                 )              {
  return resolveMediaFactsWithPrecedence(source, false);
}

/** Adopts staged legacy paths positionally while retaining canonical fact metadata and count. */
export function resolveStagedMediaFacts(source                 )              {
  return resolveMediaFactsWithPrecedence(source, true);
}

function projectStrings(
  values                                  ,
  compact         ,
  preserveEmptyLists         ,
)                       {
  const projected = compact
    ? values.filter((value)                  => Boolean(value))
    : values.map((value) => value ?? "");
  if (projected.length === 0 || (!preserveEmptyLists && !projected.some(Boolean))) {
    return undefined;
  }
  return projected;
}

export function projectMediaFacts(
  media                                              ,
  mode                        = "channel",
)                            {
  const entries = Array.isArray(media) ? media : [];
  const preserveEmptyLists = mode !== "channel";
  const mediaUrl = (entry                ) =>
    (mode === "channel" ? (entry.url ?? entry.path) : entry.path) ?? undefined;
  const mediaType = (entry                ) =>
    entry.contentType ?? (mode === "channel" ? entry.kind : undefined) ?? undefined;
  const transcribedIndexes = entries.flatMap((entry, index) => (entry.transcribed ? [index] : []));
  return {
    MediaPath: entries[0]?.path ?? undefined,
    MediaUrl: entries[0] ? mediaUrl(entries[0]) : undefined,
    MediaType: entries[0] ? mediaType(entries[0]) : undefined,
    MediaPaths: projectStrings(
      entries.map((entry) => entry.path),
      false,
      preserveEmptyLists,
    ),
    MediaUrls: projectStrings(entries.map(mediaUrl), false, preserveEmptyLists),
    MediaTypes: projectStrings(entries.map(mediaType), mode === "compact", preserveEmptyLists),
    ...(mode !== "channel"
      ? {}
      : {
          MediaTranscribedIndexes: transcribedIndexes.length > 0 ? transcribedIndexes : undefined,
        }),
  };
}
