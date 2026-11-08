import { resolveLanguage } from "@pierre/diffs";
                                                                                        
import { bundledLanguagesBase, bundledLanguagesInfo } from "./shiki-curated-languages.js";
                                                    

const BASE_DIFF_VIEWER_LANGUAGE_HINTS = [
  ...Object.keys(bundledLanguagesBase),
  "text",
  "ansi",
]                                                 ;

const BASE_LANGUAGE_HINTS = new Set                    (BASE_DIFF_VIEWER_LANGUAGE_HINTS);
const BASE_LANGUAGE_ALIASES = new Map                            (
  bundledLanguagesInfo.flatMap((language) => {
    const aliases = "aliases" in language ? language.aliases : [];
    return aliases.map((alias) => [alias, language.id                      ]);
  }),
);
                                                       

export async function normalizeSupportedLanguageHint(
  value         ,
  options                                      = {},
)                                          {
  // The curated viewer bundles this module outside Plugin SDK package resolution.
  if (typeof value !== "string") {
    return undefined;
  }
  const normalized = value.trim().toLowerCase();
  if (!normalized) {
    return undefined;
  }
  const baseAlias = BASE_LANGUAGE_ALIASES.get(normalized);
  if (baseAlias) {
    return baseAlias;
  }
  if (BASE_LANGUAGE_HINTS.has(normalized                      )) {
    return normalized                      ;
  }
  if (!options.languagePackAvailable) {
    return undefined;
  }
  try {
    await resolveLanguage(normalized                                                );
    return normalized                      ;
  } catch {
    return undefined;
  }
}

async function normalizeSupportedLanguageHints(
  values                  ,
  options                                     ,
)                                {
  const supported = new Set                    ();
  for (const value of values) {
    const normalized = await normalizeSupportedLanguageHint(value, options);
    if (!normalized) {
      continue;
    }
    supported.add(normalized);
  }
  return [...supported];
}

export function collectDiffPayloadLanguageHints(payload   
                              
                         
                         
 )                       {
  const langs = new Set                    ();
  if (payload.fileDiff?.lang) {
    langs.add(payload.fileDiff.lang);
  }
  if (payload.oldFile?.lang) {
    langs.add(payload.oldFile.lang);
  }
  if (payload.newFile?.lang) {
    langs.add(payload.newFile.lang);
  }
  return [...langs];
}

                                          
                                     
                                               
                                         
                                          
                                 
                                               
                                     
async function normalizeDiffPayloadFileLanguage(
  file                             ,
  options                                     ,
)                                       {
  if (!file) {
    return undefined;
  }
  if (typeof file.lang !== "string") {
    return file;
  }
  const normalized = await normalizeSupportedLanguageHint(file.lang, options);
  if (file.lang === normalized) {
    return file;
  }
  return {
    ...file,
    lang: normalized ?? "text",
  };
}

export async function normalizeDiffViewerPayloadLanguages(
  payload                   ,
  options                                      = {},
)                             {
  const [fileDiff, oldFile, newFile, payloadLangs] = await Promise.all([
    normalizeDiffPayloadFileLanguage(payload.fileDiff, options),
    normalizeDiffPayloadFileLanguage(payload.oldFile, options),
    normalizeDiffPayloadFileLanguage(payload.newFile, options),
    normalizeSupportedLanguageHints(payload.langs, options),
  ]);
  const langs = new Set                    (payloadLangs);
  for (const lang of collectDiffPayloadLanguageHints({ fileDiff, oldFile, newFile })) {
    langs.add(lang);
  }
  if (langs.size === 0) {
    langs.add("text");
  }
  return {
    ...payload,
    fileDiff,
    oldFile,
    newFile,
    langs: [...langs],
  };
}

export function isBaseDiffViewerLanguage(lang        )          {
  return BASE_LANGUAGE_HINTS.has(lang                      );
}
