// Markdown Core owns provider-tag scanning and CommonMark/GFM ownership.
import { expectDefined } from "../../normalization-core/src/index.mjs";
import { fromMarkdown,                             } from "mdast-util-from-markdown";
import { gfmTableFromMarkdown } from "mdast-util-gfm-table";
import { gfmTable } from "micromark-extension-gfm-table";
import { hasUnresolvedImageCode } from "./image-code-retention.mjs";

                                   
                                  
                                       

export const REASONING_TAG_NAMES = [
  "think",
  "thinking",
  "thought",
  "reasoning",
  "internal",
  "antthinking",
  "antml:think",
  "antml:thinking",
  "antml:thought",
  "antml:reasoning",
  "mm:think",
  "mm:thinking",
  "mm:thought",
  "mm:reasoning",
]         ;
const REASONING_TAG_NAME_SET = new Set        (REASONING_TAG_NAMES);
const DISABLE_HTML_MARKDOWN = {
  disable: { null: ["htmlFlow", "htmlText"] },
};

                          
                
               
                   
                         
                     
  

                         
                            
                        
  

/** Scans quote-aware provider reasoning tags with iterative malformed recovery. */
export function scanReasoningTags(text        , final = true)                   {
  const tags                      = [];
  let cursor = 0;
  while (cursor < text.length) {
    const start = text.indexOf("<", cursor);
    if (start === -1) {
      break;
    }
    const parsed = parseReasoningTagAt(text, start, final);
    if (parsed.kind === "tag") {
      tags.push(parsed.tag);
      cursor = parsed.tag.index + parsed.tag.text.length;
      continue;
    }
    if (parsed.kind === "pending") {
      return { tags, pendingStart: start };
    }
    cursor = parsed.next;
  }
  return { tags };
}

                         
                                           
                       
                                      

export function parseReasoningTagName(
  text        ,
  start        ,
) 
                                   
                                                                        {
  let cursor = skipTagWhitespace(text, start + 1);
  let isClose = false;
  if (text.charAt(cursor) === "/") {
    isClose = true;
    cursor = skipTagWhitespace(text, cursor + 1);
  }

  const nameStart = cursor;
  while (cursor < text.length && isTagNameCharacter(text.charCodeAt(cursor))) {
    cursor += 1;
  }
  const partialName = text.slice(nameStart, cursor).toLowerCase();
  if (!partialName) {
    return { kind: cursor === text.length ? "pending" : "invalid" };
  }
  if (!REASONING_TAG_NAME_SET.has(partialName)) {
    const canBecomeKnown = REASONING_TAG_NAMES.some((name) => name.startsWith(partialName));
    return { kind: cursor === text.length && canBecomeKnown ? "pending" : "invalid" };
  }
  if (cursor === text.length) {
    return { kind: "pending" };
  }
  const boundary = text.charAt(cursor);
  if (!isTagWhitespace(boundary) && boundary !== "/" && boundary !== ">") {
    return { kind: "invalid" };
  }
  return { kind: "name", end: cursor, isClose, isPrivate: partialName === "internal" };
}

export function parseReasoningTagAt(
  text        ,
  start        ,
  final         ,
)                     {
  const name = parseReasoningTagName(text, start);
  if (name.kind !== "name") {
    return name.kind === "pending" && !final ? { kind: "pending" } : invalidTag(text, start);
  }
  let quote                       ;
  let lastSignificant = "";
  for (let cursor = name.end; cursor < text.length; cursor += 1) {
    const char = text.charAt(cursor);
    if (quote) {
      if (char === quote) {
        quote = undefined;
      }
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === "<") {
      return invalidTag(text, start);
    }
    if (char === ">") {
      const end = cursor + 1;
      return {
        kind: "tag",
        tag: {
          index: start,
          text: text.slice(start, end),
          isClose: name.isClose,
          isSelfClosing: !name.isClose && lastSignificant === "/",
          isPrivate: name.isPrivate,
        },
      };
    }
    if (!isTagWhitespace(char)) {
      lastSignificant = char;
    }
  }
  return final ? invalidTag(text, start) : { kind: "pending" };
}

function invalidTag(text        , start        )                     {
  const nested = text.indexOf("<", start + 1);
  return { kind: "invalid", next: nested === -1 ? text.length : nested };
}

function skipTagWhitespace(text        , start        )         {
  let cursor = start;
  while (cursor < text.length && isTagWhitespace(text.charAt(cursor))) {
    cursor += 1;
  }
  return cursor;
}

function isTagWhitespace(char        )          {
  return /\s/u.test(char);
}

function isTagNameCharacter(code        )          {
  return (
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    code === 0x3a
  );
}

export function findNextLineEnding(text        , start        )         {
  const carriageReturn = text.indexOf("\r", start);
  const lineFeed = text.indexOf("\n", start);
  if (carriageReturn === -1) {
    return lineFeed;
  }
  return lineFeed === -1 ? carriageReturn : Math.min(carriageReturn, lineFeed);
}

                       
                
                 
                      
              
                                               
                                             
    
                              
  

                           
                
              
                 
                                
                                          
  

                                   
                
              
                                 
  

                             
                                                                           
                
                    
  

                                      
                
                    
                                                                                        
                  
                     
                  
  

                                 
                          
                                  
                        
                                
  

function appendMarkdownSource(
  source                                                 ,
  start        ,
  token                       ,
  value        ,
)       {
  // A tab partly consumed by a container contributes virtual spaces to its first source unit.
  const extra = value.length - (token.end.offset - token.start.offset);
  for (let cursor = start + source.offsets.length; cursor < token.end.offset; cursor += 1) {
    const consumed = cursor - token.start.offset;
    source.offsets.push(source.value.length + (consumed > 0 ? consumed + extra : 0));
  }
  source.value += value;
}

function captureInlineSources(text        , sources                                   )            {
  const observe         = function (token) {
    const start = this.stack.findLast((entry) => entry.type === "inlineCode")?.position?.start
      .offset;
    if (start === undefined) {
      return;
    }
    let source = sources.get(start);
    if (!source) {
      const inlineBlock = this.stack.findLast(
        (entry) => entry.type === "paragraph" || entry.type === "heading",
      );
      const begin = inlineBlock?.children[0]?.position?.start.offset;
      const containers = this.stack.filter(
        (entry) => entry.type === "listItem" || entry.type === "blockquote",
      );
      const prefixEnd = begin !== undefined && containers.length ? begin : start;
      const prefixStart = containers.length
        ? Math.max(text.lastIndexOf("\n", prefixEnd - 1), text.lastIndexOf("\r", prefixEnd - 1)) + 1
        : start;
      const prefix = containers
        .map((entry) =>
          text.slice(entry.position?.start.offset, entry.children[0]?.position?.start.offset),
        )
        .join("");
      source = {
        prefix: {
          start: prefixStart,
          end: prefixEnd,
          ownerStart: containers[0]?.position?.start.offset ?? start,
          text:
            prefix +
            (containers.length && inlineBlock?.type === "heading"
              ? text.slice(inlineBlock.position?.start.offset, begin)
              : ""),
        },
        value: "",
        offsets: [],
      };
      sources.set(start, source);
    }
    appendMarkdownSource(source, start, token, this.sliceSerialize(token));
  };
  return {
    enter: {
      codeTextData(token) {
        observe.call(this, token);
        // Preserve normal data compilation; the observation only records source/content ownership.
        expectDefined(this.config.enter.data, "Markdown data handler").call(this, token);
      },
      lineEnding: observe,
    },
  };
}

function captureIndentedSources(
  text        ,
  sources                                     ,
  observeInlineLineEnding         ,
)            {
  const observe         = function (token) {
    if (!this.tokenStack.some(([parent]) => parent.type === "codeIndented")) {
      return;
    }
    const node = this.stack.findLast((entry) => entry.type === "code");
    const start = node?.position?.start.offset;
    if (start === undefined) {
      return;
    }
    let source = sources.get(start);
    if (!source) {
      const owner = this.stack.find(
        (entry) => entry.type === "listItem" || entry.type === "blockquote",
      );
      source = {
        value: "",
        offsets: [],
        context: text.slice(owner?.position?.start.offset ?? start, token.start.offset),
        ownerStart: owner?.position?.start.offset ?? start,
        nested: owner !== undefined,
      };
      sources.set(start, source);
    }
    appendMarkdownSource(source, start, token, this.sliceSerialize(token));
  };
  return {
    enter: {
      codeFlowValue(token) {
        observe.call(this, token);
        expectDefined(this.config.enter.data, "Markdown data handler").call(this, token);
      },
      lineEnding(token) {
        observeInlineLineEnding?.call(this, token);
        observe.call(this, token);
      },
    },
  };
}

export function parseMarkdownOwnership(text        , options                           ) {
  const paragraphs                                                    =
    options?.includeIndentedSource ? [] : undefined;
  if (!text) {
    return {
      regions: [],
      codeSpans: [],
      textSpans: [],
      retainStart: 0,
      completedParagraphs: [],
      definitions: [],
      ...(paragraphs ? { paragraphs } : {}),
    };
  }
  const sources = new Map                              ();
  const indentedSources = options?.includeIndentedSource
    ? new Map                                ()
    : undefined;
  const inlineSourceExtension = options?.includeSource
    ? captureInlineSources(text, sources)
    : undefined;
  const tables = options?.syntax !== "commonmark";
  const tree = fromMarkdown(text, {
    extensions: [DISABLE_HTML_MARKDOWN, ...(tables ? [gfmTable()] : [])],
    mdastExtensions: [
      ...(tables ? [gfmTableFromMarkdown()] : []),
      ...(inlineSourceExtension ? [inlineSourceExtension] : []),
      ...(indentedSources
        ? [captureIndentedSources(text, indentedSources, inlineSourceExtension?.enter?.lineEnding)]
        : []),
    ],
  })                  ;
  const completedParagraphs                               = [];
  const regions                       = [];
  const textSpans                          = [];
  const definitions                                                            = [];
  const blocks = tree.children ?? [];
  let retainStart = blocks.at(-1)?.position?.start?.offset ?? text.length;
  for (let index = 0; index < blocks.length; index += 1) {
    const block = expectDefined(blocks[index], "Markdown block");
    const next = blocks[index + 1]?.position?.start;
    const blockStart = block.position?.start?.offset;
    const endLine = block.position?.end?.line;
    const blockEnd = block.position?.end?.offset;
    if (
      paragraphs &&
      block.type === "paragraph" &&
      blockStart !== undefined &&
      blockEnd !== undefined
    ) {
      paragraphs.push({ start: blockStart, end: blockEnd });
    }
    let paragraph                                        ;
    if (
      block.type === "paragraph" &&
      blockStart !== undefined &&
      endLine !== undefined &&
      next?.offset !== undefined &&
      next.line !== undefined &&
      next.line > endLine + 1
    ) {
      // Include the blank separator so projections can retain the completed block boundary.
      // Unresolved reference labels can still become image alt text after a later definition.
      paragraph = {
        start: blockStart,
        end: next.offset,
        hasReferenceCandidate: false,
      };
      completedParagraphs.push(paragraph);
    }
    const pending                   = [block];
    const regionStart = regions.length;
    let hasReferenceCandidate = false;
    let hasInlineCode = false;
    while (pending.length > 0) {
      const node = expectDefined(pending.pop(), "Markdown ownership node");
      if (node.type === "text" && node.value?.includes("[")) {
        hasReferenceCandidate = true;
        if (paragraph) {
          paragraph.hasReferenceCandidate = true;
        }
      }
      hasInlineCode ||= node.type === "inlineCode";
      const start = node.position?.start?.offset;
      const end = node.position?.end?.offset;
      if (
        node.type === "definition" &&
        node.identifier !== undefined &&
        start !== undefined &&
        end !== undefined
      ) {
        definitions.push({ identifier: node.identifier, start, end });
      }
      if (
        options?.includeText &&
        node.type === "text" &&
        start !== undefined &&
        end !== undefined
      ) {
        textSpans.push([start, end]);
      }
      if (
        (node.type === "code" || node.type === "inlineCode") &&
        start !== undefined &&
        end !== undefined
      ) {
        const source = sources.get(start);
        if (source) {
          while (source.offsets.length <= end - start) {
            source.offsets.push(source.value.length);
          }
        }
        const indentedSource = indentedSources?.get(start);
        if (indentedSource) {
          indentedSource.value = node.value ?? "";
          while (indentedSource.offsets.length <= end - start) {
            indentedSource.offsets.push(indentedSource.value.length);
          }
          indentedSource.offsets.forEach((offset, sourceIndex) => {
            indentedSource.offsets[sourceIndex] = Math.min(offset, indentedSource.value.length);
          });
        }
        regions.push({
          start,
          end,
          block: node.type === "code",
          ...(source ? { source } : {}),
          ...(indentedSource ? { indentedSource } : {}),
        });
      }
      for (const child of node.children?.toReversed() ?? []) {
        pending.push(child);
      }
    }
    // A later image reference definition can turn inline code into unprotected alt text.
    if (
      hasReferenceCandidate &&
      hasInlineCode &&
      blockStart !== undefined &&
      blockEnd !== undefined &&
      hasUnresolvedImageCode(text, blockStart, blockEnd, regions, regionStart)
    ) {
      retainStart = Math.min(retainStart, blockStart);
    }
  }
  if (definitions.length) {
    // An unfinished next-line title can temporarily parse as several other blocks.
    let lastBlank = -1;
    for (const blank of text.matchAll(/(?:\r\n|\n|\r(?!\n))[ \t]*(?:\r\n|\n|\r(?!\n))/g)) {
      lastBlank = blank.index;
    }
    for (const definition of definitions) {
      if (definition.end > lastBlank) {
        retainStart = Math.min(retainStart, definition.start);
      }
    }
  }
  regions.sort((left, right) => left.start - right.start);
  return {
    regions,
    codeSpans: regions.map(({ start, end })                   => [start, end]),
    textSpans,
    retainStart,
    completedParagraphs,
    definitions,
    ...(paragraphs ? { paragraphs } : {}),
  };
}

/** Returns parser-owned CommonMark/GFM code ranges with block ownership. */
export function findMarkdownCodeRegions(
  text        ,
  options                           ,
)                       {
  return /[`~\t]| {4}/u.test(text) ? parseMarkdownOwnership(text, options).regions : [];
}

/** Returns parser-owned CommonMark/GFM code ranges, including their delimiters. */
export function findMarkdownCodeSpans(text        )                          {
  // CommonMark code needs a literal delimiter or indentation, even inside containers.
  if (!/[`~\t]| {4}/u.test(text)) {
    return [];
  }
  return parseMarkdownOwnership(text).codeSpans;
}

export function isInsideCode(index        , spans                         )          {
  let low = 0;
  let high = spans.length - 1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const span = spans[middle];
    if (!span) {
      return false;
    }
    if (index < span[0]) {
      high = middle - 1;
    } else if (index >= span[1]) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

                                                                             

                              
                
                       
             
                    
                             
                    
                            
                           
    
  

                         
                 
                            
                     
                           
                 
  

export function reduceReasoningText(
  text        ,
  codeSpans                         ,
  state                ,
  options                  ,
)                          {
  const output                          = [];
  const emit = (kind                               , value        ) => {
    if (!value) {
      return;
    }
    const previous = output.at(-1);
    if (previous?.kind === kind) {
      previous.text += value;
    } else {
      output.push({ kind, text: value });
    }
    if (kind === "text" && value.trim()) {
      state.visibleEver = true;
    }
  };
  const append = (value        ) => {
    if (!value) {
      return;
    }
    if (state.depth > 0 && state.pending) {
      state.pending.content += value;
      state.pending.protectedClose ||= scanReasoningTags(value).tags.some((tag) => tag.isClose);
    } else {
      emit("text", value);
    }
  };

  const start = options.start ?? 0;
  const scan = scanReasoningTags(text.slice(start), options.final);
  const tags                      = [];
  for (const scannedTag of scan.tags) {
    const index = scannedTag.index + start;
    if (!isInsideCode(index, codeSpans)) {
      tags.push({ ...scannedTag, index });
    }
  }
  const mustParseRemainder            = [];
  if (options.scope === "leading") {
    let mustParse = false;
    for (let index = tags.length - 1; index >= 0; index -= 1) {
      mustParse ||= tags[index]?.isPrivate === true;
      mustParseRemainder[index] = mustParse;
      mustParse ||= tags[index]?.isClose === true;
    }
  }
  let cursor = start;

  for (const [tagIndex, tag] of tags.entries()) {
    const beforeTag = text.slice(cursor, tag.index);
    append(beforeTag);
    const tagEnd = tag.index + tag.text.length;

    if (tag.isSelfClosing) {
      if (state.depth === 0 && options.scope === "leading" && state.visibleEver) {
        emit("text", text.slice(tag.index));
        cursor = text.length;
        break;
      }
      cursor = tagEnd;
      continue;
    }

    if (!tag.isClose) {
      if (
        state.depth === 0 &&
        options.scope === "leading" &&
        state.visibleEver &&
        !mustParseRemainder[tagIndex]
      ) {
        emit("text", text.slice(tag.index));
        cursor = text.length;
        break;
      }
      if (state.depth === 0) {
        state.pending = {
          content: "",
          containsPrivate: tag.isPrivate,
          openTag: tag.text,
          protectedClose: false,
          visibleBefore: state.visibleEver,
        };
      } else if (state.pending) {
        // A nested private block makes the enclosing reasoning non-emitting.
        state.pending.containsPrivate ||= tag.isPrivate;
      }
      state.depth += 1;
      cursor = tagEnd;
      continue;
    }

    if (state.depth > 0) {
      state.depth -= 1;
      if (state.depth === 0 && state.pending) {
        if (!state.pending.containsPrivate) {
          emit("thinking", state.pending.content);
        }
        state.pending = undefined;
      } else if (state.pending) {
        state.pending.protectedClose = true;
      }
      cursor = tagEnd;
      continue;
    }

    if (options.mode === "visible") {
      append(tag.text);
    } else {
      const after = text.slice(tagEnd);
      if (beforeTag.trim() && after.trim()) {
        const thinking = output.filter((delta) => delta.kind === "thinking");
        output.splice(0, output.length, ...thinking);
        state.visibleEver = false;
      }
    }
    cursor = tagEnd;
  }

  append(text.slice(cursor));
  if (options.final && state.depth > 0 && state.pending) {
    const pending = state.pending;
    if (!pending.containsPrivate) {
      const recoverAsText =
        options.mode === "static-preserve" ||
        (options.mode === "static-strict" && !pending.visibleBefore && !pending.protectedClose) ||
        (options.mode === "visible" && !pending.protectedClose);
      if (recoverAsText && options.recoverUnclosed !== false) {
        const value =
          options.mode === "visible" && pending.visibleBefore
            ? pending.openTag + pending.content
            : pending.content;
        emit("text", value);
      } else {
        emit("thinking", pending.content);
      }
    }
    state.depth = 0;
    state.pending = undefined;
  }
  return output;
}

                                 
                              
                           
                            
  

/** Strips reasoning tags using the same reducer as streamed partitioning. */
export function stripReasoningTagsFromMarkdown(
  text        ,
  options                          ,
)         {
  const state                 = { depth: 0, visibleEver: false };
  return reduceReasoningText(text, findMarkdownCodeSpans(text), state, {
    final: true,
    mode:
      options.recoverUnclosed === false
        ? "hide"
        : options.mode === "preserve"
          ? "static-preserve"
          : "static-strict",
    scope: options.scope,
  })
    .filter((delta) => delta.kind === "text")
    .map((delta) => delta.text)
    .join("");
}
