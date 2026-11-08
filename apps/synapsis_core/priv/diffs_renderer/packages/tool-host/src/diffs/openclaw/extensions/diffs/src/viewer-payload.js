                                                    

/** Decode the typed payload emitted by renderDiffCard, not external tool input. */
export function parseViewerPayloadJson(raw        )                    {
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("Diff payload is not valid JSON.");
  }
}
