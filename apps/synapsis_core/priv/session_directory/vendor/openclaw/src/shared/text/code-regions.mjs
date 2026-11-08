import { expectDefined } from "../../../packages/normalization-core/src/index.mjs";
import {
  findMarkdownCodeRegions as findCodeRegions,
  parseMarkdownOwnership,
} from "../../../packages/markdown-core/src/reasoning-tags.mjs";

export { findCodeRegions };

/** Public range inputs need only offsets; parser-owned metadata belongs to discovered regions. */
                             
                
              
 

/** Index nonempty native parts using the visible text owner's newline separator. */
export function indexTextParts(parts                   ) {
  const spans                                                       = [];
  const texts           = [];
  let offset = 0;
  parts.forEach((part, index) => {
    if (!part) {
      return;
    }
    if (spans.length) {
      offset += 1;
    }
    const start = offset;
    texts.push(part);
    offset += part.length;
    spans.push({ index, start, end: offset });
  });
  return { text: texts.join("\n"), spans };
}

/** One canonical code scan for a stage's immutable native text parts. */
export function createTextPartCodeRegionResolver(parts                   ) {
  const source = indexTextParts(parts);
  const spans = new Map(source.spans.map((span) => [span.index, span]));
  let regions                                                ;
  return (index        )                                     => {
    const span = spans.get(index);
    if (!span) {
      return [];
    }
    regions ??= findCodeRegions(source.text);
    let low = 0;
    let high = regions.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (expectDefined(regions[middle], "indexed code region").end <= span.start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    const result                                     = [];
    for (let at = low; at < regions.length; at++) {
      const region = expectDefined(regions[at], "projected code region");
      if (region.start >= span.end) {
        break;
      }
      result.push({
        start: Math.max(0, region.start - span.start),
        end: Math.min(span.end, region.end) - span.start,
        block: region.block,
      });
    }
    return result;
  };
}

/** Canonical code ranges, stable-prefix boundary, and completed top-level paragraphs. */
export function findCodeOwnership(
  text        ,
  options                                               ,
) {
  const { regions, retainStart, completedParagraphs, paragraphs, definitions } =
    parseMarkdownOwnership(text, options);
  return {
    regions,
    retainStart,
    completedParagraphs,
    definitions,
    ...(paragraphs ? { paragraphs } : {}),
  };
}

export function isInsideCode(pos        , regions              )          {
  return regions.some((region) => pos >= region.start && pos < region.end);
}

/** Appends cannot revoke block code after its opening line; inline ownership can change. */
export function isInsideSettledBlockCode(
  pos        ,
  text        ,
  regions                                    ,
)          {
  return regions.some(
    (region) =>
      region.block &&
      region.start <= pos &&
      pos < region.end &&
      /[\r\n]/.test(text.slice(region.start, pos)),
  );
}

/** Removes control lines while retaining literal code and original line endings. */
export function stripLinesOutsideCode(
  text        ,
  shouldStrip                           ,
)         {
  return projectLinesOutsideCode(text, shouldStrip, 0).text;
}

export function projectLinesOutsideCode(
  text        ,
  shouldStrip                           ,
  retainStart        ,
) {
  let regions                          ;
  let retainedOutputStart = retainStart;
  const projected = text.replace(/[^\n]*(?:\n|$)/g, (raw        , offset        ) => {
    const line = raw.endsWith("\n") ? raw.slice(0, -1).replace(/\r$/, "") : raw;
    if (!shouldStrip(line) || isInsideCode(offset, (regions ??= findCodeRegions(text)))) {
      return raw;
    }
    if (offset < retainStart) {
      retainedOutputStart -= raw.length;
    }
    return "";
  });
  return { text: projected, retainStart, retainedOutputStart };
}
