import { hasNonEmptyString } from "../../packages/normalization-core/src/string-coerce.mjs";
                                                                     

export function hasAnyNonEmptyString(value         )          {
  return Array.isArray(value) && value.some(hasNonEmptyString);
}

export async function normalizeSentMediaUrlsForDelivery(params   
                                   
                                                                         
 )                    {
  const normalizedUrls = new Set        ();
  for (const raw of params.sentMediaUrls) {
    const trimmed = raw.trim();
    if (!trimmed) {
      continue;
    }
    normalizedUrls.add(trimmed);
    if (!params.normalizeMediaPaths) {
      continue;
    }
    try {
      const normalized = await params.normalizeMediaPaths({
        mediaUrl: trimmed,
        mediaUrls: [trimmed],
      });
      for (const mediaUrl of [normalized.mediaUrl, ...(normalized.mediaUrls ?? [])]) {
        const candidate = mediaUrl?.trim();
        if (candidate) {
          normalizedUrls.add(candidate);
        }
      }
    } catch {
      // Keep the original evidence. Delivery normalization will report invalid media separately.
    }
  }
  return [...normalizedUrls];
}
