import { truncateUtf16Safe } from "../../../packages/normalization-core/src/utf16-slice.mjs";
import {
  RAW_TEXT_TAGS,
  readRawTextOpenTagName,
  findRawTextOpenTagStart,
  startsLikeHtmlTag,
  readTagToken,
  readRawTextBounds,
  skipRawTextElement,
} from "../../../packages/markdown-core/src/html-scanner.mjs";
import { stripInvisibleUnicode } from "../../infra/unicode-visibility.mjs";
import { decodeHtmlEntities } from "../../shared/html-entities.mjs";
import { readHtmlAttribute } from "./web-fetch-attributes.mjs";
import { sanitizeHtml } from "./web-fetch-visibility.mjs";

                                              

const BLOCK_BREAK_TAGS = new Set([
  "p",
  "div",
  "section",
  "article",
  "header",
  "footer",
  "pre",
  "table",
  "tr",
  "ul",
  "ol",
]);
// Keep malformed nested markup from making end-of-document context unwind quadratic.
// web_fetch favors bounded, auditable text over preserving deep broken HTML structure.
const MAX_RENDER_CONTEXT_DEPTH = 32;

                    
                                     
                                      
                                                                                   
                                                       
                                          
                                     

                    
                 
                      
  

function decodeEntities(value        )         {
  // Display extraction historically accepted mixed-case &nbsp; and treats non-breaking spaces as
  // ordinary collapsible whitespace. Normalize it before the shared decoder to stay single-pass.
  return decodeHtmlEntities(value.replace(/&nbsp;/gi, "\u00a0")).replaceAll("\u00a0", " ");
}

function readAnchorHref(rawTag        )                     {
  const value = readHtmlAttribute(rawTag, "href", "render");
  return value === undefined ? undefined : decodeEntities(value);
}

function escapePreMarkerText(value        )         {
  // Internal pre markers use single NULs. Double NULs in fetched text so even
  // entity-decoded marker-like prose cannot be mistaken for a placeholder.
  return value.replaceAll("\u0000", "\u0000\u0000");
}

function appendText(stack                 , value        )       {
  const context = stack[stack.length - 1];
  context?.parts.push(context.kind === "pre" ? value : escapePreMarkerText(value));
  if (context?.kind === "anchor" && /\S/.test(value)) {
    context.hasText = true;
  }
}

function formatPreformattedMarkdown(value        )         {
  const code = value.replace(/\r\n?/g, "\n");
  let longestBacktickRun = 0;
  let currentBacktickRun = 0;
  for (const character of code) {
    if (character === "`") {
      currentBacktickRun += 1;
      longestBacktickRun = Math.max(longestBacktickRun, currentBacktickRun);
    } else {
      currentBacktickRun = 0;
    }
  }
  const fence = "`".repeat(Math.max(3, longestBacktickRun + 1));
  return `${fence}\n${code}${code.endsWith("\n") ? "" : "\n"}${fence}`;
}

function restorePreformattedMarkdown(value        , state             )         {
  return value.replace(/\0(?:\0|openclaw-pre-(\d+)\0)/g, (_match, index                    ) =>
    index === undefined ? "\0" : formatPreformattedMarkdown(state.preBlocks[Number(index)] ),
  );
}

function closeContext(context               , parent               , state             )       {
  if (context.kind === "pre") {
    const code = context.parts.join("");
    if (code.trim()) {
      const index = state.preBlocks.push(code) - 1;
      parent.parts.push(`\n\n\0openclaw-pre-${index}\0\n\n`);
    } else {
      parent.parts.push("\n");
    }
    return;
  }
  const label = normalizeWhitespace(context.parts.join(""));
  if (!label && context.kind !== "title" && !(context.kind === "anchor" && context.href)) {
    return;
  }
  if (context.kind === "title") {
    state.title ??= label || undefined;
    return;
  }
  if (parent.kind === "title") {
    parent.parts.push(label);
    return;
  }
  switch (context.kind) {
    case "root":
      return;
    case "anchor":
      parent.parts.push(
        context.href && label
          ? `[${label}](${escapePreMarkerText(context.href)})`
          : label || escapePreMarkerText(context.href || ""),
      );
      return;
    case "heading":
      if (parent.kind === "anchor") {
        parent.parts.push(label);
        parent.hasText ||= Boolean(label);
      } else {
        parent.parts.push(`\n${"#".repeat(context.level)} ${label}\n`);
      }
      return;
    case "list-item":
      if (parent.kind === "anchor") {
        parent.hasText ||= Boolean(label);
      }
      parent.parts.push(`\n- ${label}`);
  }
}

function closeTopContext(stack                 , state             )       {
  const context = stack.pop() ;
  closeContext(context, stack[stack.length - 1] , state);
}

function closeThroughContext(
  stack                 ,
  kind                       ,
  state             ,
  requireAnchorText = false,
)          {
  for (let i = stack.length - 1; i > 0; i -= 1) {
    const context = stack[i];
    if (context?.kind === kind) {
      if (requireAnchorText && context.kind === "anchor" && !context.hasText) {
        return false;
      }
      while (stack.length > i) {
        closeTopContext(stack, state);
      }
      return true;
    }
  }
  return false;
}

function pushContext(
  stack                 ,
  context                                          ,
  state             ,
)       {
  while (stack.length >= MAX_RENDER_CONTEXT_DEPTH) {
    closeTopContext(stack, state);
  }
  stack.push(context);
}

export function htmlToMarkdown(html        )                                   {
  const root                = { kind: "root", parts: [] };
  const stack                  = [root];
  const state              = { preBlocks: [] };
  const tableRowCellCounts           = [];

  for (let i = 0; i < html.length;) {
    const ch = html[i];
    if (ch !== "<") {
      const nextTag = html.indexOf("<", i);
      const end = nextTag === -1 ? html.length : nextTag;
      appendText(stack, decodeEntities(html.slice(i, end)));
      i = end;
      continue;
    }

    const rawTextTagName = readRawTextOpenTagName(html, i);
    if (rawTextTagName) {
      i = skipRawTextElement(html, i, rawTextTagName);
      continue;
    }

    if (!startsLikeHtmlTag(html, i)) {
      appendText(stack, "<");
      i += 1;
      continue;
    }

    const read = readTagToken(html, i);
    if (!read) {
      const rawTextStart = findRawTextOpenTagStart(html, i + 1, html.length);
      if (rawTextStart !== -1) {
        i = rawTextStart;
        continue;
      }
      break;
    }
    const { token, next } = read;
    i = next;
    if (!token) {
      continue;
    }

    // Within pre, tags are presentation only; their text must stay literal.
    if (stack[stack.length - 1]?.kind === "pre" && token.name !== "pre") {
      if (token.name === "br" && !token.closing) {
        appendText(stack, "\n");
      }
      continue;
    }
    const kind =
      token.name === "title"
        ? "title"
        : token.name === "pre"
          ? "pre"
          : token.name === "a"
            ? "anchor"
            : /^h[1-6]$/.test(token.name)
              ? "heading"
              : token.name === "li"
                ? "list-item"
                : undefined;
    if (token.closing) {
      if (token.name === "tr") {
        tableRowCellCounts.pop();
      }
      if (kind) {
        closeThroughContext(stack, kind, state);
      } else if (BLOCK_BREAK_TAGS.has(token.name)) {
        appendText(stack, "\n");
      }
      continue;
    }

    if (RAW_TEXT_TAGS.has(token.name)) {
      i = readRawTextBounds(html, token.name, i).end;
      continue;
    }
    if (token.name === "tr" && !token.selfClosing) {
      tableRowCellCounts.push(0);
    }
    if ((token.name === "td" || token.name === "th") && !token.selfClosing) {
      const rowIndex = tableRowCellCounts.length - 1;
      if (rowIndex >= 0) {
        const cellCount = tableRowCellCounts[rowIndex] ?? 0;
        if (cellCount > 0) {
          appendText(stack, " | ");
        }
        tableRowCellCounts[rowIndex] = cellCount + 1;
      }
    }
    if (BLOCK_BREAK_TAGS.has(token.name) && closeThroughContext(stack, "anchor", state, true)) {
      appendText(stack, " ");
    }
    if (token.name === "pre") {
      appendText(stack, "\n");
    }
    if (token.name === "br" || token.name === "hr") {
      appendText(stack, "\n");
      continue;
    }
    if (!kind || token.selfClosing) {
      continue;
    }
    if (kind !== "title") {
      closeThroughContext(stack, "anchor", state, kind !== "anchor");
    }
    const context                                           =
      kind === "anchor"
        ? { kind, href: readAnchorHref(token.raw), hasText: false, parts: [] }
        : kind === "heading"
          ? { kind, level: Number.parseInt(token.name[1] ?? "1", 10), parts: [] }
          : { kind, parts: [] };
    pushContext(stack, context, state);
  }

  while (stack.length > 1) {
    closeTopContext(stack, state);
  }

  return {
    text: restorePreformattedMarkdown(normalizeWhitespace(root.parts.join("")), state),
    title: state.title ? restorePreformattedMarkdown(state.title, state) : state.title,
  };
}

export function normalizeWhitespace(value        )         {
  return value
    .replace(/\r/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function readBacktickRunEnd(value        , start        )         {
  let end = start + 1;
  while (value[end] === "`") {
    end += 1;
  }
  return end;
}

export function markdownToText(markdown        )         {
  const codeBlocks           = [];
  let text = "";
  let pos = 0;
  while (pos < markdown.length) {
    const open = markdown.indexOf("```", pos);
    if (open === -1) {
      text += markdown.slice(pos).replaceAll("\0", "\0\0");
      break;
    }
    text += markdown.slice(pos, open).replaceAll("\0", "\0\0");
    const afterOpen = readBacktickRunEnd(markdown, open);
    const fenceLength = afterOpen - open;
    let closingStart = afterOpen;
    let close                                            ;
    while (closingStart < markdown.length) {
      const start = markdown.indexOf("`", closingStart);
      if (start === -1) {
        break;
      }
      const end = readBacktickRunEnd(markdown, start);
      if (end - start >= fenceLength) {
        // Consume only the matching run, preserving adjacent blocks.
        close = { start, end: start + fenceLength };
        break;
      }
      closingStart = end;
    }
    const firstLineEnd = markdown.indexOf("\n", afterOpen);
    if (!close) {
      const lineStart = markdown.lastIndexOf("\n", open) + 1;
      if (firstLineEnd === -1 || !/^[ \t]*$/.test(markdown.slice(lineStart, open))) {
        text += markdown.slice(open).replaceAll("\0", "\0\0");
        break;
      }
    }
    const contentEnd = close?.start ?? markdown.length;
    const contentStart =
      firstLineEnd === -1 || firstLineEnd > contentEnd ? afterOpen : firstLineEnd + 1;
    const code = markdown.slice(contentStart, contentEnd);
    // Keep the surrounding prose connected without interpreting the code as Markdown.
    // Preserve its final line boundary for heading/list markers after the closing fence.
    const lineEnd = /[\r\n\u2028\u2029]$/.test(code) ? code.slice(-1) : "";
    const literal = code.slice(0, code.length - lineEnd.length);
    if (literal) {
      text += `\0${codeBlocks.length}\0`;
      codeBlocks.push(literal);
    }
    text += lineEnd;
    pos = close?.end ?? markdown.length;
  }
  text = text.replace(/!\[[^\]]*]\([^)]+\)/g, "");
  text = text.replace(/\[([^\]]+)]\([^)]+\)/g, "$1");
  text = text.replace(/`([^`]+)`/g, "$1");
  text = text.replace(/^#{1,6}\s+/gm, "");
  text = text.replace(/^[^\S\n]*[-*+]\s+/gm, "");
  text = text.replace(/^[^\S\n]*\d+\.\s+/gm, "");
  // Escaped input NUL pairs stay paired through prose formatting, so only our
  // single-NUL markers can restore code. Replacement output is not rescanned.
  return normalizeWhitespace(text).replace(
    /\0(?:\0|(\d+)\0)/g,
    (_match, index                    ) =>
      index === undefined ? "\0" : codeBlocks[Number(index)] ,
  );
}

export function truncateWebFetchText(
  value        ,
  maxChars        ,
)                                       {
  if (value.length <= maxChars) {
    return { text: value, truncated: false };
  }
  return { text: truncateUtf16Safe(value, maxChars), truncated: true };
}

export async function extractBasicHtmlContent(params   
               
                           
 )                                                   {
  const cleanHtml = await sanitizeHtml(params.html);
  const rendered = htmlToMarkdown(cleanHtml);
  const text =
    stripInvisibleUnicode(
      params.extractMode === "text" ? markdownToText(rendered.text) : rendered.text,
    ) ||
    stripInvisibleUnicode(rendered.title ?? "") ||
    stripInvisibleUnicode(rendered.text);
  return text ? { text, title: rendered.title } : null;
}
