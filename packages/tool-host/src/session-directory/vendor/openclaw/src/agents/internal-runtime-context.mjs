import { isRuntimeContextCarrier } from "../../packages/agent-core/src/harness/messages.mjs";
import { RUNTIME_CONTEXT_HEADER } from "../../packages/llm-core/src/types.mjs";
import { RUNTIME_CONTEXT_FOOTER } from "../../packages/llm-core/src/types.mjs";
import { RUNTIME_CONTEXT_BEGIN_MARKER } from "../../packages/llm-core/src/types.mjs";
import { RUNTIME_CONTEXT_CUSTOM_TYPE } from "../../packages/llm-core/src/types.mjs";
import { RUNTIME_CONTEXT_END_MARKER } from "../../packages/llm-core/src/types.mjs";
import { escapeRegExp } from "../shared/regexp.mjs";
export const INTERNAL_RUNTIME_CONTEXT_BEGIN = RUNTIME_CONTEXT_BEGIN_MARKER;
export const INTERNAL_RUNTIME_CONTEXT_END = RUNTIME_CONTEXT_END_MARKER;
export const OPENCLAW_RUNTIME_CONTEXT_NOTICE =
  "This context is runtime-generated, not user-authored. Keep internal details private.";
export const OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE = RUNTIME_CONTEXT_CUSTOM_TYPE;
const INTERNAL_CONTEXT_HEADER =
  ["OpenClaw runtime context (internal):", OPENCLAW_RUNTIME_CONTEXT_NOTICE, ""].join("\n") + "\n";
const INTERNAL_EVENT_MARKER = "[Internal task completion event]";
function createDelimitedToken(token        ) {
  return {
    token,
    pattern: new RegExp(`(?:^|\\r?\\n)[ \\t]*${escapeRegExp(token)}[ \\t]*(?=\\r?\\n|$)`, "g"),
  };
}
const BEGIN_DELIMITER = createDelimitedToken(INTERNAL_RUNTIME_CONTEXT_BEGIN);
const END_DELIMITER = createDelimitedToken(INTERNAL_RUNTIME_CONTEXT_END);
const CURRENT_RUNTIME_CONTEXT_HEADER = createDelimitedToken(RUNTIME_CONTEXT_HEADER);
const CURRENT_RUNTIME_CONTEXT_FOOTER = createDelimitedToken(RUNTIME_CONTEXT_FOOTER);
function findDelimitedTokenIndex(
  text        ,
  delimiter                                         ,
  from        ,
)         {
  // Private patterns are reused synchronously; each search owns its offset so
  // nested blocks and later calls never inherit an earlier match's lastIndex.
  delimiter.pattern.lastIndex = Math.max(0, from);
  const match = delimiter.pattern.exec(text);
  if (!match) {
    return -1;
  }
  return match.index + match[0].indexOf(delimiter.token);
}
function findDelimitedTokenLinePrefixStart(text        , tokenIndex        )         {
  const lineStart = text.lastIndexOf("\n", tokenIndex - 1) + 1;
  if (lineStart === 0) {
    return 0;
  }
  return text[lineStart - 2] === "\r" ? lineStart - 2 : lineStart - 1;
}
function stripDelimitedBlocks(
  text        ,
  format                         ,
  options                                                                  = {},
)         {
  const nested = format === "protected";
  const begin = nested ? BEGIN_DELIMITER : CURRENT_RUNTIME_CONTEXT_HEADER;
  const end = nested ? END_DELIMITER : CURRENT_RUNTIME_CONTEXT_FOOTER;
  let next = text;
  for (;;) {
    const start = findDelimitedTokenIndex(next, begin, 0);
    if (start === -1) {
      return next;
    }

    let cursor = start + begin.token.length;
    let depth = 1;
    let finish = -1;
    while (depth > 0) {
      const nextBegin = nested ? findDelimitedTokenIndex(next, begin, cursor) : -1;
      const nextEnd = findDelimitedTokenIndex(next, end, cursor);
      if (nextEnd === -1) {
        break;
      }
      if (nextBegin !== -1 && nextBegin < nextEnd) {
        depth += 1;
        cursor = nextBegin + begin.token.length;
        continue;
      }
      depth -= 1;
      finish = nextEnd;
      cursor = nextEnd + end.token.length;
    }

    const blockStart = options.preserveSurroundingWhitespace
      ? findDelimitedTokenLinePrefixStart(next, start)
      : start;
    const before = options.preserveSurroundingWhitespace
      ? next.slice(0, blockStart)
      : next.slice(0, start).trimEnd();
    if (finish === -1 || depth !== 0) {
      return before;
    }
    let blockEnd = finish + end.token.length;
    while (next[blockEnd] === " " || next[blockEnd] === "\t") {
      blockEnd += 1;
    }
    if (!nested) {
      if (next[blockEnd] === "\r") {
        blockEnd += 1;
      }
      if (next[blockEnd] === "\n") {
        blockEnd += 1;
      }
    }
    const after = options.preserveSurroundingWhitespace
      ? next.slice(blockEnd)
      : next.slice(blockEnd).trimStart();
    next =
      !options.preserveSurroundingWhitespace && before && after
        ? `${before}${options.separator ?? "\n\n"}${after}`
        : `${before}${after}`;
  }
}
function stripUndelimitedInternalRuntimeContext(text        )         {
  let next = text;
  let searchFrom = 0;
  for (;;) {
    const headerStart = next.indexOf(INTERNAL_CONTEXT_HEADER, searchFrom);
    if (headerStart === -1) {
      return next;
    }

    const eventStart = headerStart + INTERNAL_CONTEXT_HEADER.length;
    if (!next.startsWith(INTERNAL_EVENT_MARKER, eventStart)) {
      searchFrom = eventStart;
      continue;
    }

    const nextParagraph = next.indexOf("\n\n", eventStart + INTERNAL_EVENT_MARKER.length);
    const blockEnd = nextParagraph === -1 ? next.length : nextParagraph;

    const before = next.slice(0, headerStart).trimEnd();
    const after = next.slice(blockEnd).trimStart();
    next = before && after ? `${before}\n\n${after}` : `${before}${after}`;
    searchFrom = Math.max(0, before.length - 1);
  }
}
const RUNTIME_CONTEXT_PROMPT_HEADERS                    = [
  "OpenClaw runtime context for the active user request in this turn. Do not reply to or describe this context. Use it to continue answering the active user request now. Do not wait for another message.",
  "OpenClaw runtime context for the immediately preceding user message.",
  "OpenClaw runtime event.",
];
const RUNTIME_CONTEXT_CARRIER_PREFIX_PATTERN = new RegExp(
  RUNTIME_CONTEXT_PROMPT_HEADERS.flatMap((header) => {
    const sentences = header.split(". ");
    return sentences.map((_, index) => sentences.slice(index).join(". "));
  })
    .map((prefix) => prefix.split(/\s+/).map(escapeRegExp).join("\\s+"))
    .join("|"),
);
const RUNTIME_CONTEXT_NOTICE_PATTERN = new RegExp(
  OPENCLAW_RUNTIME_CONTEXT_NOTICE.split(/\s+/).map(escapeRegExp).join("\\s+"),
);
const RUNTIME_CONTEXT_PREFACE_PATTERN = new RegExp(
  `^[ \\t]*(?:${RUNTIME_CONTEXT_CARRIER_PREFIX_PATTERN.source})\\s+${RUNTIME_CONTEXT_NOTICE_PATTERN.source}[ \\t]*(?:\\r?\\n|$)`,
  "gm",
);
function stripRuntimeContextPromptPreface(text        )         {
  // Each alternative has a fixed word count; unrelated lines never grow a candidate scan.
  // The notice can also occur in ordinary authored text. Avoid running the
  // large generated regexp unless a recognized carrier prefix is present.
  if (!RUNTIME_CONTEXT_CARRIER_PREFIX_PATTERN.test(text)) {
    return text;
  }
  const stripped = text.replace(RUNTIME_CONTEXT_PREFACE_PATTERN, "");
  return stripped === text ? text : stripped.replace(/\n{3,}/g, "\n\n").trim();
}
export function stripInternalRuntimeContext(
  input        ,
  options   
                                            
                       
                        
    = {},
)         {
  let text = input;
  if (options.streaming) {
    // A cumulative preview must not publish a marker before its next chunk
    // completes the delimiter. Final text still preserves literal prefixes.
    const lineStart = text.lastIndexOf("\n") + 1;
    const tail = text.slice(lineStart).trim();
    if (
      tail &&
      [INTERNAL_RUNTIME_CONTEXT_BEGIN, INTERNAL_RUNTIME_CONTEXT_END, RUNTIME_CONTEXT_HEADER].some(
        (marker) => tail.length < marker.length && marker.startsWith(tail),
      )
    ) {
      text = text.slice(0, lineStart).trimEnd();
    }
  }
  // All removable formats contain a delimiter or the whitespace-tolerant runtime notice.
  // Skip delimiter scans and line parsing for ordinary display text.
  if (
    !text.includes(INTERNAL_RUNTIME_CONTEXT_BEGIN) &&
    !text.includes(INTERNAL_RUNTIME_CONTEXT_END) &&
    !text.includes(RUNTIME_CONTEXT_HEADER) &&
    !RUNTIME_CONTEXT_NOTICE_PATTERN.test(text)
  ) {
    return text;
  }
  const withoutDelimitedBlocks = stripDelimitedBlocks(text, "protected", options).replace(
    END_DELIMITER.pattern,
    "",
  );
  return stripDelimitedBlocks(
    stripRuntimeContextPromptPreface(
      stripUndelimitedInternalRuntimeContext(withoutDelimitedBlocks),
    ),
    "current",
    options,
  );
}
export function isOpenClawRuntimeContextCustomMessage(message         )          {
  // Private transcript types stay hidden even without authority for provider replay.
  return (
    isRuntimeContextCarrier(message) ||
    (typeof message === "object" &&
      message !== null &&
      Reflect.get(message, "role") === "custom" &&
      Reflect.get(message, "customType") === OPENCLAW_RUNTIME_CONTEXT_CUSTOM_TYPE)
  );
}
export { INTERNAL_CONTEXT_HEADER, INTERNAL_EVENT_MARKER, createDelimitedToken, BEGIN_DELIMITER, END_DELIMITER, CURRENT_RUNTIME_CONTEXT_HEADER, CURRENT_RUNTIME_CONTEXT_FOOTER, findDelimitedTokenIndex, findDelimitedTokenLinePrefixStart, stripDelimitedBlocks, stripUndelimitedInternalRuntimeContext, RUNTIME_CONTEXT_PROMPT_HEADERS, RUNTIME_CONTEXT_CARRIER_PREFIX_PATTERN, RUNTIME_CONTEXT_NOTICE_PATTERN, RUNTIME_CONTEXT_PREFACE_PATTERN, stripRuntimeContextPromptPreface };